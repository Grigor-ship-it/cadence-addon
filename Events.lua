--[[
    Cadence - Events.lua
    Combat lifecycle, roster management, and segment triggering for
    WoW Midnight 12.0.5.

    Activity tracking architecture:
      * COMBAT_LOG_EVENT_UNFILTERED is dead in 12.0.5 (RegisterEvent
        silently fails).  Stripped entirely from this addon.
      * UNIT_SPELLCAST_SUCCEEDED only fires reliably for the LOCAL
        player.  We use it solely to populate the player's abilityMap
        for top-abilities display; it does NOT drive APM or uptime.
      * Per-player APM / uptime / gaps come from Polling.lua, which
        samples C_DamageMeter.Current every second and converts
        per-GUID damage+healing deltas into "active ticks".
      * Per-player interrupts / dispels / deaths / avoidable damage
        come from MeterData.EnrichSnapshots reading the matching
        C_DamageMeter session at segment boundaries.
]]

local ADDON_NAME, PC = ...

PC.Events = {}
local Events    = PC.Events
local Tracker   = PC.Tracker
local Segments  = PC.Segments
local Utils     = PC.Utils

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local inCombat            = false
local debugMode           = false
local trashPullCounter    = 0
local justEndedEncounter  = false
local knownDead           = {}
local lastInstanceID      = nil
local inArenaMatch        = false
local combatEndTimer      = nil   -- cancellable REGEN_ENABLED debounce
local segmentDirty        = false -- tracker has unsaved combat data

-- Roster
local rosterGUIDs      = {}  -- [guid] = true
local unitToCleanGUID  = {}  -- ["raid5"] = "Player-XXX"
local cleanTokenList   = {}  -- ordered list of unit tokens

-- Diagnostics (per pull)
local pollActivePerGuid = {}  -- [guid] = active poll ticks observed

-- Per-GUID throttle for high-frequency events (UNIT_POWER_UPDATE etc.).
-- We don't need millisecond resolution; one tick per ~0.5s is plenty.
local lastEventTick = {}      -- [guid] = GetTime() of last credited tick
local EVENT_TICK_THROTTLE = 0.5

-- Frames
local eventFrame = CreateFrame("Frame")

---------------------------------------------------------------------------
-- Taint sanitisers
---------------------------------------------------------------------------
local string_format = string.format
local _cleanTestTbl = {}

local function CleanString(val)
    if val == nil then return nil end
    local ok, result = pcall(string_format, "%s", val)
    if not ok then return nil end
    local ok2 = pcall(rawset, _cleanTestTbl, result, true)
    if ok2 then
        rawset(_cleanTestTbl, result, nil)
        return result
    end
    local ok3, clean = pcall(function()
        local len = #result
        if len == 0 then return "" end
        local bytes = {string.byte(result, 1, len)}
        return string.char(unpack(bytes))
    end)
    if not ok3 or not clean then return nil end
    local ok4 = pcall(rawset, _cleanTestTbl, clean, true)
    if not ok4 then return nil end
    rawset(_cleanTestTbl, clean, nil)
    return clean
end

Events._CleanString = CleanString

local function CleanNumber(val)
    if val == nil then return 0 end
    local ok, result = pcall(string_format, "%.0f", val)
    if not ok then return 0 end
    local ok2, num = pcall(tonumber, result)
    if not ok2 then return 0 end
    return num or 0
end

---------------------------------------------------------------------------
-- Roster management
---------------------------------------------------------------------------
local function RefreshRosterCache()
    local members = Utils.ScanGroupRoster()
    Utils.WipeTable(rosterGUIDs)
    Utils.WipeTable(unitToCleanGUID)
    for i = 1, #cleanTokenList do cleanTokenList[i] = nil end

    for guid in pairs(members) do
        local cleanGUID = CleanString(guid) or guid
        rosterGUIDs[cleanGUID] = true
    end

    local rawPlayerGUID = UnitGUID("player")
    local playerGUID = CleanString(rawPlayerGUID) or rawPlayerGUID
    if playerGUID then
        unitToCleanGUID["player"] = playerGUID
        cleanTokenList[#cleanTokenList + 1] = "player"
        rosterGUIDs[playerGUID] = true
    end

    local inRaid = IsInRaid()
    local groupSize = GetNumGroupMembers()
    if inRaid then
        for i = 1, groupSize do
            local token = "raid" .. i
            local rawG = UnitGUID(token)
            local g = rawG and (CleanString(rawG) or rawG) or nil
            if g then
                unitToCleanGUID[token] = g
                cleanTokenList[#cleanTokenList + 1] = token
                rosterGUIDs[g] = true
            end
        end
    else
        for i = 1, math.max(groupSize - 1, 0) do
            local token = "party" .. i
            local rawG = UnitGUID(token)
            local g = rawG and (CleanString(rawG) or rawG) or nil
            if g then
                unitToCleanGUID[token] = g
                cleanTokenList[#cleanTokenList + 1] = token
                rosterGUIDs[g] = true
            end
        end
    end

    -- Arena enemies (12.0.5: UnitGUID for arenaN may return secret strings)
    if inArenaMatch then
        for i = 1, 5 do
            local token = "arena" .. i
            local gOk, rawG = pcall(UnitGUID, token)
            if gOk and rawG then
                local g = CleanString(rawG)
                if g then
                    unitToCleanGUID[token] = g
                    cleanTokenList[#cleanTokenList + 1] = token
                    rosterGUIDs[g] = true
                    pcall(function()
                        local name, realm = UnitName(token)
                        local _, class    = UnitClass(token)
                        Utils.CacheUnit(g, name, class, realm)
                        Utils.SetRoleByGUID(g, "DAMAGER")
                    end)
                    Tracker.EnsurePlayer(g)
                    local pd = Tracker.GetPlayerData(g)
                    if pd then pd.isEnemy = true end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Cache name/class/role from a unit token (used at combat start so the
-- meter rows show real names instead of "Unknown" until enrichment runs)
---------------------------------------------------------------------------
local function CacheUnitInfoFromToken(cleanToken, cleanGUID)
    if not cleanToken or not cleanGUID then return end
    if Utils.GetNameByGUID(cleanGUID) ~= "Unknown" then return end
    pcall(function()
        if UnitExists(cleanToken) ~= true then return end
        local name, realm = UnitName(cleanToken)
        local _, class    = UnitClass(cleanToken)
        Utils.CacheUnit(cleanGUID, name, class, realm)
        local role = UnitGroupRolesAssigned(cleanToken) or "DAMAGER"
        if role == "NONE" then role = "DAMAGER" end
        Utils.SetRoleByGUID(cleanGUID, role)
    end)
end

local function CacheAllRosterInfo()
    for _, token in ipairs(cleanTokenList) do
        local g = unitToCleanGUID[token]
        if g then CacheUnitInfoFromToken(token, g) end
    end
end

---------------------------------------------------------------------------
-- Public: roster GUID set (consumed by Polling.lua)
---------------------------------------------------------------------------
function Events.GetRosterGUIDs()
    return rosterGUIDs
end

---------------------------------------------------------------------------
-- Public: credit one activity tick to a roster GUID, sharing the same
-- per-GUID throttle used by UNIT_SPELLCAST_SUCCEEDED / UNIT_POWER_UPDATE.
-- Polling.lua calls this for C_DamageMeter-derived activity so the three
-- signal channels (hardcasts / resource spend / meter delta) cannot
-- triple-count the same in-game action.
---------------------------------------------------------------------------
function Events.CreditPollActivity(guid, now)
    if not guid or not rosterGUIDs[guid] then return false end
    now = now or GetTime()
    local last = lastEventTick[guid]
    if last and (now - last) < EVENT_TICK_THROTTLE then return false end
    lastEventTick[guid] = now
    Tracker.RecordPollTick(guid, true, now)
    return true
end

---------------------------------------------------------------------------
-- Debug
---------------------------------------------------------------------------
function Events.SetDebug(on)
    debugMode = on
    if PC.Polling and PC.Polling.SetDebug then PC.Polling.SetDebug(on) end
    print("|cffffffffCad|r|cffFFD666ence|r: Debug " .. (on and "ON" or "OFF"))
end

function Events.IsDebug() return debugMode end

---------------------------------------------------------------------------
-- Credit one activity tick to a roster GUID, throttled.
-- Used by UNIT_SPELLCAST_SUCCEEDED (party units) and UNIT_POWER_UPDATE
-- to feed the same actionCount/intentActionCount channel that polling
-- writes to.  Throttle prevents rage-on-every-swing or Maelstrom-stack
-- spam from inflating APM beyond 120.
---------------------------------------------------------------------------
local function CreditActivityTick(guid, now)
    if not guid or not rosterGUIDs[guid] then return end
    local last = lastEventTick[guid]
    if last and (now - last) < EVENT_TICK_THROTTLE then return end
    lastEventTick[guid] = now
    Tracker.RecordPollTick(guid, true, now)
end

---------------------------------------------------------------------------
-- UNIT_SPELLCAST_SUCCEEDED
-- Player: record into abilityMap + classify utility + credit activity.
-- Party/raid: credit activity only (spell info for non-self is unreliable
-- and we already have throughput from C_DamageMeter).
-- Hardcast spells only -- instant-casts that never appear here are
-- caught by UNIT_POWER_UPDATE instead.
---------------------------------------------------------------------------
local function OnSpellCastSucceeded(unit, castGUID, spellID)
    if not inCombat and not inArenaMatch then return end
    unit = CleanString(unit)
    if not unit then return end

    local now = GetTime()

    if unit == "player" then
        local cleanSpellID = CleanNumber(spellID)
        if cleanSpellID == 0 then return end

        local spellName = "Unknown"
        local spellSchool = 0
        pcall(function()
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(cleanSpellID)
            if info then
                if info.name        then spellName   = info.name        end
                if info.spellSchool then spellSchool = info.spellSchool end
            end
        end)

        Tracker.RecordPlayerSpellCast(cleanSpellID, spellName, spellSchool)

        local guid = unitToCleanGUID["player"] or CleanString(UnitGUID("player"))
        if guid then
            CreditActivityTick(guid, now)

            -- Classify utility spells for the player's own card
            local SpellDB = PC.SpellDB
            local isExternal = C_Spell and C_Spell.IsExternalDefensive
                and C_Spell.IsExternalDefensive(cleanSpellID)
            if isExternal or (SpellDB and SpellDB.EXTERNAL[cleanSpellID]) then
                Tracker.RecordExternal(guid)
            elseif SpellDB then
                local cat = SpellDB.Classify(cleanSpellID)
                if cat == "RAID_CD" then
                    Tracker.RecordRaidCD(guid)
                elseif cat == "SUPPORT" then
                    Tracker.RecordSupport(guid)
                elseif cat == "CC" then
                    Tracker.RecordCC(guid)
                end
            end
        end
        return
    end

    -- Party/raid unit: credit activity only.
    local guid = unitToCleanGUID[unit]
    if not guid then
        local rawG = UnitGUID(unit)
        guid = rawG and CleanString(rawG) or nil
    end
    if guid then CreditActivityTick(guid, now) end
end

---------------------------------------------------------------------------
-- UNIT_POWER_UPDATE
-- Catches instant-cast classes (Hunter, Rogue, Feral, Fury, etc.) that
-- spend resources without ever firing UNIT_SPELLCAST_SUCCEEDED.  Any
-- power-type change while in combat = the player pressed a button.
-- Heavily throttled because rage/energy ticks fire many times a second.
---------------------------------------------------------------------------
local function OnUnitPowerUpdate(unit, powerType)
    if not inCombat and not inArenaMatch then return end
    unit = CleanString(unit)
    if not unit then return end
    -- Ignore passive regen-only types: ALTERNATE shows on bosses, COMBO_POINTS
    -- builds via casts already counted, but we accept any change as activity.
    local guid = unitToCleanGUID[unit]
    if not guid then
        local rawG = UnitGUID(unit)
        guid = rawG and CleanString(rawG) or nil
    end
    if guid then CreditActivityTick(guid, GetTime()) end
end

---------------------------------------------------------------------------
-- UNIT_FLAGS pools for death detection
---------------------------------------------------------------------------
local unitFlagsFramePool = {}

local function OnUnitFlagsPoolEvent(self, event, unit)
    if not inCombat and not inArenaMatch then return end
    if not unit then return end
    local guid = unitToCleanGUID[unit] or CleanString(UnitGUID(unit))
    if not guid or not rosterGUIDs[guid] then return end
    if UnitIsDeadOrGhost(unit) == true and not knownDead[guid] then
        knownDead[guid] = true
        Tracker.RecordDeath(guid, GetTime())
        if debugMode then
            local name = UnitName(unit) or "?"
            print("|cffFFD666PC Debug|r: DEATH recorded for " .. name)
        end
    elseif UnitIsDeadOrGhost(unit) ~= true and knownDead[guid] then
        knownDead[guid] = nil
    end
end

local function RegisterUnitFlagsPools()
    for _, f in ipairs(unitFlagsFramePool) do f:UnregisterAllEvents() end
    local tokens = {"player"}
    local inRaid = IsInRaid()
    local groupSize = GetNumGroupMembers()
    if inRaid then
        for i = 1, groupSize do tokens[#tokens + 1] = "raid" .. i end
    else
        for i = 1, math.max(groupSize - 1, 0) do tokens[#tokens + 1] = "party" .. i end
    end
    local idx = 0
    for i = 1, #tokens, 2 do
        idx = idx + 1
        local frame = unitFlagsFramePool[idx]
        if not frame then
            frame = CreateFrame("Frame")
            frame:SetScript("OnEvent", OnUnitFlagsPoolEvent)
            unitFlagsFramePool[idx] = frame
        end
        if tokens[i + 1] then
            frame:RegisterUnitEvent("UNIT_FLAGS", tokens[i], tokens[i + 1])
        else
            frame:RegisterUnitEvent("UNIT_FLAGS", tokens[i])
        end
    end
end

---------------------------------------------------------------------------
-- Per-unit registration for UNIT_POWER_UPDATE and UNIT_SPELLCAST_SUCCEEDED.
-- Without this, modern clients only deliver these events for "player".
-- Each frame can hold up to 2 unit filters, so we pool them.
---------------------------------------------------------------------------
local partyEventFramePool = {}

local function OnPartyUnitEvent(self, event, ...)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        local ok, err = pcall(OnSpellCastSucceeded, unit, castGUID, spellID)
        if not ok and debugMode then
            print("|cffff0000Cadence USCS Error|r: " .. tostring(err))
        end
    elseif event == "UNIT_POWER_UPDATE" then
        local unit, powerType = ...
        local ok, err = pcall(OnUnitPowerUpdate, unit, powerType)
        if not ok and debugMode then
            print("|cffff0000Cadence Power Error|r: " .. tostring(err))
        end
    end
end

local function RegisterPartyUnitEvents()
    for _, f in ipairs(partyEventFramePool) do f:UnregisterAllEvents() end
    local tokens = {}
    local inRaid = IsInRaid()
    local groupSize = GetNumGroupMembers()
    if inRaid then
        for i = 1, groupSize do tokens[#tokens + 1] = "raid" .. i end
    else
        for i = 1, math.max(groupSize - 1, 0) do tokens[#tokens + 1] = "party" .. i end
    end
    -- Two events per frame, two units per event filter -> pair tokens.
    local idx = 0
    for i = 1, #tokens, 2 do
        idx = idx + 1
        local frame = partyEventFramePool[idx]
        if not frame then
            frame = CreateFrame("Frame")
            frame:SetScript("OnEvent", OnPartyUnitEvent)
            partyEventFramePool[idx] = frame
        end
        local u1, u2 = tokens[i], tokens[i + 1]
        if u2 then
            frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", u1, u2)
            frame:RegisterUnitEvent("UNIT_POWER_UPDATE", u1, u2)
        else
            frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", u1)
            frame:RegisterUnitEvent("UNIT_POWER_UPDATE", u1)
        end
    end
end

---------------------------------------------------------------------------
-- Combat start / end helpers
---------------------------------------------------------------------------
local function StartCombatTracking(now, freshPull)
    RefreshRosterCache()
    RegisterUnitFlagsPools()
    CacheAllRosterInfo()

    if freshPull then
        Utils.WipeTable(knownDead)
        Utils.WipeTable(pollActivePerGuid)
        Utils.WipeTable(lastEventTick)
        Tracker.ResetAll()
        if PC.Polling and PC.Polling.Reset then PC.Polling.Reset() end
        Tracker.SetCombatStart(now)
        segmentDirty = true
    end

    -- Make sure every roster member exists in the tracker so they appear
    -- in the meter (with 0 APM) even if they never get a poll tick.
    for guid in pairs(rosterGUIDs) do
        Tracker.EnsurePlayer(guid)
    end

    if PC.Polling and PC.Polling.Start then PC.Polling.Start() end
end

---------------------------------------------------------------------------
-- Main event handler
---------------------------------------------------------------------------
local function OnEvent(self, event, ...)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        local ok, err = pcall(OnSpellCastSucceeded, unit, castGUID, spellID)
        if not ok and debugMode then
            print("|cffff0000Cadence USCS Error|r: " .. tostring(err))
        end

    elseif event == "UNIT_POWER_UPDATE" then
        local unit, powerType = ...
        local ok, err = pcall(OnUnitPowerUpdate, unit, powerType)
        if not ok and debugMode then
            print("|cffff0000Cadence Power Error|r: " .. tostring(err))
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        justEndedEncounter = false
        if combatEndTimer then combatEndTimer:Cancel(); combatEndTimer = nil end

        if inArenaMatch then
            -- Arena setup already done in PVP_MATCH_ACTIVE
            if PC.Polling and PC.Polling.Start then PC.Polling.Start() end
            return
        end

        StartCombatTracking(GetTime(), not segmentDirty)

        if debugMode then
            local memberCount = Utils.TableCount(rosterGUIDs)
            print("|cffFFD666PC Debug|r: Combat START ("
                .. memberCount .. " members, polling active)")
        end

        if PC.db and PC.db.profile and PC.db.profile.autoShowInCombat then
            if PC.UI_Meter and PC.UI_Meter.Show then PC.UI_Meter.Show() end
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        if PC.Polling and PC.Polling.Stop then PC.Polling.Stop() end

        if inArenaMatch then return end  -- arena handles its own end

        Tracker.SetCombatEnd(GetTime())

        if combatEndTimer then combatEndTimer:Cancel() end
        combatEndTimer = C_Timer.NewTimer(2.0, function()
            combatEndTimer = nil
            if inCombat then return end

            if justEndedEncounter then
                justEndedEncounter = false
                segmentDirty = false
                return
            end

            local hasData = false
            for _, pd in pairs(Tracker.GetAllPlayerData()) do
                if pd.actionCount > 0 then hasData = true; break end
            end

            if hasData then
                trashPullCounter = trashPullCounter + 1
                local segName = "Trash Pull " .. trashPullCounter
                local ok, err = pcall(Segments.CreateSnapshot, segName, "trash")
                if not ok and debugMode then
                    print("|cffff0000PC Error|r: Snapshot failed: " .. tostring(err))
                end
            end

            segmentDirty = false
        end)

    elseif event == "ENCOUNTER_START" then
        local encounterID, encounterName, difficultyID, groupSize = ...
        justEndedEncounter = false
        Segments.OnEncounterStart(encounterID, encounterName, difficultyID, groupSize)
        StartCombatTracking(GetTime(), true)

    elseif event == "ENCOUNTER_END" then
        local encounterID, encounterName, difficultyID, groupSize, success = ...
        Segments.OnEncounterEnd(encounterID, encounterName, difficultyID, groupSize, success)
        justEndedEncounter = true
        segmentDirty = false

    elseif event == "CHALLENGE_MODE_START" then
        Segments.OnChallengeModeStart()
        segmentDirty = false
        StartCombatTracking(GetTime(), true)

    elseif event == "CHALLENGE_MODE_COMPLETED" then
        Segments.OnChallengeModeComplete()
        segmentDirty = false

    elseif event == "GROUP_ROSTER_UPDATE" then
        RefreshRosterCache()
        RegisterUnitFlagsPools()
        RegisterPartyUnitEvents()

    elseif event == "PLAYER_ENTERING_WORLD" then
        RefreshRosterCache()
        RegisterUnitFlagsPools()
        RegisterPartyUnitEvents()

        local rawInInstance, rawInstanceType = IsInInstance()
        local inInstance = (rawInInstance == true) or (rawInInstance == 1)
        local instanceType = rawInstanceType and CleanString(rawInstanceType) or ""
        if inInstance and instanceType == "party" then
            Segments.SetInDungeon(true)
        elseif inInstance and instanceType == "arena" then
            Segments.SetInArena(true)
        end

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        local rawInInstance, rawInstanceType = IsInInstance()
        local inInstance = (rawInInstance == true) or (rawInInstance == 1)
        local instanceType = rawInstanceType and CleanString(rawInstanceType) or ""

        if inInstance and (instanceType == "party" or instanceType == "raid") then
            local _, _, _, _, _, _, _, rawID = GetInstanceInfo()
            local instanceID = rawID and CleanNumber(rawID) or nil
            if instanceID and instanceID ~= lastInstanceID then
                lastInstanceID = instanceID
                Tracker.ResetAll()
                if PC.Polling and PC.Polling.Reset then PC.Polling.Reset() end
                Segments.ResetAll()
                trashPullCounter = 0
                segmentDirty = false
                if debugMode then
                    print("|cffFFD666PC Debug|r: New instance detected -- data auto-cleared")
                end
            end
            if instanceType == "party" then Segments.SetInDungeon(true) end
        elseif inInstance and instanceType == "arena" then
            local _, _, _, _, _, _, _, rawID = GetInstanceInfo()
            local instanceID = rawID and CleanNumber(rawID) or nil
            if instanceID and instanceID ~= lastInstanceID then
                lastInstanceID = instanceID
                Tracker.ResetAll()
                if PC.Polling and PC.Polling.Reset then PC.Polling.Reset() end
                Segments.ResetAll()
                segmentDirty = false
            end
            Segments.SetInArena(true)
        else
            if Segments.IsInDungeon() and not Segments.IsInMythicPlus() then
                if Segments.IsAccumulating() then
                    local accSeg = Segments.BuildAccumulatedSegment()
                    if accSeg and PC.UI_Summary and PC.UI_Summary.Populate then
                        C_Timer.After(1.0, function() PC.UI_Summary.Populate(accSeg) end)
                    end
                end
            end
            Segments.SetInDungeon(false)
            Segments.SetInArena(false)
            lastInstanceID = nil
        end

    elseif event == "PVP_MATCH_ACTIVE" then
        local rawInInstance, rawInstanceType = IsInInstance()
        local instanceType = rawInstanceType and CleanString(rawInstanceType) or ""
        if instanceType ~= "arena" then return end

        inArenaMatch = true

        local _, _, diffID = GetInstanceInfo()
        local isShuffle = (diffID == 231 or (C_PvP and C_PvP.IsSoloShuffle and C_PvP.IsSoloShuffle()))

        Segments.OnArenaStart(isShuffle)
        Tracker.ResetAll()
        if PC.Polling and PC.Polling.Reset then PC.Polling.Reset() end

        local members = Utils.ScanGroupRoster()
        for guid, _ in pairs(members) do Tracker.EnsurePlayer(guid) end

        StartCombatTracking(GetTime(), false)

        C_Timer.After(2.0, function()
            if not inArenaMatch then return end
            RefreshRosterCache()
        end)

        local enemyCount = 0
        for i = 1, 5 do
            if unitToCleanGUID["arena" .. i] then enemyCount = enemyCount + 1 end
        end
        print("|cffFFD666Cadence|r: Arena match ACTIVE ("
            .. (isShuffle and "Solo Shuffle" or "Rated Arena")
            .. "), " .. enemyCount .. " opponents visible via UnitGUID")

    elseif event == "ARENA_OPPONENT_UPDATE" then
        if inArenaMatch then RefreshRosterCache() end

    elseif event == "PVP_MATCH_COMPLETE" then
        if not inArenaMatch then return end
        inArenaMatch = false
        if PC.Polling and PC.Polling.Stop then PC.Polling.Stop() end
        Tracker.SetCombatEnd(GetTime())

        local winner = GetBattlefieldWinner and GetBattlefieldWinner()
        local playerTeam = GetBattlefieldArenaFaction and GetBattlefieldArenaFaction() or 0
        local didWin = (winner ~= nil and winner == playerTeam)

        Segments.OnArenaEnd(didWin)
        justEndedEncounter = true
    end
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
function Events.Init()
    eventFrame:SetScript("OnEvent", OnEvent)

    -- Player-self spell tracker fires through eventFrame; party units use
    -- the per-unit pool registered below (RegisterUnitEvent is the only
    -- way to reliably get USCS/UNIT_POWER_UPDATE for party members).
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    eventFrame:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")

    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("ENCOUNTER_START")
    eventFrame:RegisterEvent("ENCOUNTER_END")
    eventFrame:RegisterEvent("CHALLENGE_MODE_START")
    eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("PVP_MATCH_ACTIVE")
    eventFrame:RegisterEvent("PVP_MATCH_COMPLETE")
    pcall(eventFrame.RegisterEvent, eventFrame, "ARENA_OPPONENT_UPDATE")

    RefreshRosterCache()
    RegisterUnitFlagsPools()
    RegisterPartyUnitEvents()

    print("|cffffffffCad|r|cffFFD666ence|r: Loaded. Activity: USCS+POWER events + C_DamageMeter polling")
end

---------------------------------------------------------------------------
-- Public queries
---------------------------------------------------------------------------
function Events.IsInCombat() return inCombat end
function Events.IsInArena()  return inArenaMatch end

---------------------------------------------------------------------------
-- /cad dump : per-player polling + meter report
---------------------------------------------------------------------------
function Events.DumpPullReport()
    local Tracker  = PC.Tracker
    local MeterData = PC.MeterData

    print("|cffFFD666=== Cadence Pull Report ===|r")
    print(string_format("Polling active=%s   Combat=%s",
        tostring(PC.Polling and PC.Polling.IsActive()),
        tostring(inCombat or inArenaMatch)))

    local meter = nil
    if MeterData and MeterData.GetLiveMeterData then
        meter = MeterData.GetLiveMeterData()
    end

    local rows = {}
    for guid in pairs(rosterGUIDs) do
        local pd = Tracker and Tracker.GetPlayerData and Tracker.GetPlayerData(guid)
        local name = (pd and pd.name) or Utils.GetNameByGUID(guid) or "?"
        rows[#rows + 1] = {
            name  = name,
            guid  = guid,
            acts  = (pd and pd.actionCount)       or 0,
            iacts = (pd and pd.intentActionCount) or 0,
            dmg   = (meter and meter[guid] and meter[guid].damageDone)  or 0,
            heal  = (meter and meter[guid] and meter[guid].healingDone) or 0,
        }
    end
    table.sort(rows, function(a, b) return (a.name or "") < (b.name or "") end)

    local missing = 0
    for _, r in ipairs(rows) do
        local meterSeen = (r.dmg > 0 or r.heal > 0)
        local marker = ""
        if r.acts == 0 then
            marker = "|cffff4444 NO POLL TICKS|r"
            if meterSeen then
                marker = marker .. " |cffff8800(meter saw them)|r"
            end
            missing = missing + 1
        end
        print(string_format("  %-20s ticks=%-4d intent=%-4d meter=%s%s",
            r.name, r.acts, r.iacts, meterSeen and "yes" or "no", marker))
    end

    print(string_format("|cffFFD666=== %d/%d roster members got NO poll ticks ===|r",
        missing, #rows))
end

---------------------------------------------------------------------------
-- Self-test
---------------------------------------------------------------------------
function Events.SelfTest()
    print("  Event frame: " .. (eventFrame and "OK" or "MISSING"))
    print("  USCS registered (player-self): "
        .. tostring(eventFrame:IsEventRegistered("UNIT_SPELLCAST_SUCCEEDED")))
    print("  REGEN registered: "
        .. tostring(eventFrame:IsEventRegistered("PLAYER_REGEN_DISABLED")))
    print("  C_Spell.GetSpellInfo: "
        .. (C_Spell and C_Spell.GetSpellInfo and "OK" or "|cffff0000MISSING|r"))
    print("  C_DamageMeter: " .. (C_DamageMeter and "OK" or "|cffff0000MISSING|r"))
    print("  Polling active: " .. tostring(PC.Polling and PC.Polling.IsActive()))
    print("  IsInGroup: " .. tostring(IsInGroup()))
    print("  Roster GUIDs: " .. Utils.TableCount(rosterGUIDs))
    print("  Clean tokens: " .. #cleanTokenList)
    for _, token in ipairs(cleanTokenList) do
        local g = unitToCleanGUID[token]
        local n = g and Utils.GetNameByGUID(g) or "?"
        print("    " .. token .. " -> " .. (g or "nil") .. " (" .. n .. ")")
    end
end

PC.Events = Events

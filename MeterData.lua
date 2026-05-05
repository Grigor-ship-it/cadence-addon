--[[
    Cadence - MeterData.lua
    Queries Blizzard's C_DamageMeter API (WoW 12.0 Midnight)
    to enrich player snapshots with throughput data (DPS, HPS,
    interrupts, dispels, avoidable damage, deaths).

    The C_DamageMeter API replaced CLEU damage/healing events in 12.0.
    CVar "damageMeterEnabled" must be "1" (Details auto-enables it).
]]

local ADDON_NAME, PC = ...

PC.MeterData = {}
local MeterData = PC.MeterData
local Utils = PC.Utils

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local apiAvailable = false

-- Resolved Enum values (populated in Init)
local METER_TYPE = {}       -- { DamageDone=N, HealingDone=N, ... }
local SESSION_CURRENT = nil
local SESSION_OVERALL = nil

---------------------------------------------------------------------------
-- Secret value handling
-- Blizzard's C_DamageMeter returns hardware-protected "secret" values
-- for sourceGUID, name, totalAmount, amountPerSecond during combat.
-- These values CANNOT be read, coerced, or compared while in combat —
-- any attempt returns nil/0 or throws.  They resolve to normal Lua
-- values once combat drops (player leaves combat state).
--
-- issecretvalue(val) — WoW 12.0 global, returns true if val is still
-- hardware-protected.  We use this to detect whether data is ready.
---------------------------------------------------------------------------

-- Check if C_DamageMeter data for a session is still hardware-locked.
-- Returns true if we should NOT try to read values yet.
local function IsDataSecret(sessionType)
    -- issecretvalue is a WoW 12.0 global.  If absent, assume data is ready.
    if not issecretvalue then return false end
    if not apiAvailable then return true end

    local meterType = METER_TYPE.DamageDone or METER_TYPE.HealingDone
    if meterType == nil then return true end

    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
        sessionType or SESSION_CURRENT, meterType)
    if not ok or not session or not session.combatSources then return true end

    local sources = session.combatSources
    if #sources == 0 then return false end  -- no sources = nothing secret

    local src = sources[1]
    if src.totalAmount ~= nil and issecretvalue(src.totalAmount) then
        return true
    end
    if src.sourceGUID ~= nil and issecretvalue(src.sourceGUID) then
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Enum resolution (safe against missing values)
---------------------------------------------------------------------------
local function SafeEnum(enumTable, name)
    if enumTable and enumTable[name] ~= nil then
        return enumTable[name]
    end
    return nil
end

local function ResolveEnums()
    local E = Enum and Enum.DamageMeterType
    if E then
        METER_TYPE.DamageDone           = SafeEnum(E, "DamageDone")
        METER_TYPE.HealingDone          = SafeEnum(E, "HealingDone")
        METER_TYPE.Interrupts           = SafeEnum(E, "Interrupts")
        METER_TYPE.Dispels              = SafeEnum(E, "Dispels")
        METER_TYPE.AvoidableDamageTaken = SafeEnum(E, "AvoidableDamageTaken")
                                       or SafeEnum(E, "DamageTaken")
        METER_TYPE.Deaths               = SafeEnum(E, "Deaths")
    end

    local S = Enum and Enum.DamageMeterSessionType
    if S then
        SESSION_CURRENT = SafeEnum(S, "Current")
        SESSION_OVERALL = SafeEnum(S, "Overall")
    end
end

---------------------------------------------------------------------------
-- Init — called from Core.lua on PLAYER_LOGIN
---------------------------------------------------------------------------
function MeterData.Init()
    ResolveEnums()

    apiAvailable = (C_DamageMeter ~= nil
        and C_DamageMeter.GetCombatSessionFromType ~= nil
        and SESSION_CURRENT ~= nil)

    if apiAvailable then
        -- Ensure the CVar is enabled
        local ok, val = pcall(GetCVar, "damageMeterEnabled")
        if ok and val ~= "1" then
            pcall(SetCVar, "damageMeterEnabled", "1")
        end
    end
end

function MeterData.IsAvailable()
    return apiAvailable
end

function MeterData.GetSessionCurrent()
    return SESSION_CURRENT
end

function MeterData.GetSessionOverall()
    return SESSION_OVERALL
end

---------------------------------------------------------------------------
-- Query a single meter type from a session.
-- MUST only be called when IsDataSecret() == false (values are regular).
-- Returns array of { guid, name, total, perSecond, class }
---------------------------------------------------------------------------
local function QueryMeterType(sessionType, meterType)
    if not apiAvailable or sessionType == nil or meterType == nil then
        return nil
    end
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, meterType)
    if not ok or not session then return nil end

    local sources = session.combatSources
    if not sources then return nil end

    local results = {}
    for i = 1, #sources do
        local src = sources[i]
        if src then
            -- Per-source secret-value defence: even when the bulk
            -- IsDataSecret() probe says the session is readable, a
            -- *single* late-joining source can still hold a secret
            -- totalAmount / amountPerSecond. Coerce to safe numbers.
            local guid = src.sourceGUID
            local name = src.name
            local total = src.totalAmount
            local rate  = src.amountPerSecond
            if issecretvalue then
                if total ~= nil and issecretvalue(total) then total = 0 end
                if rate  ~= nil and issecretvalue(rate)  then rate  = 0 end
            end
            results[#results + 1] = {
                guid      = (type(guid) == "string") and guid or tostring(guid or ""),
                name      = (type(name) == "string") and name or tostring(name or ""),
                total     = tonumber(total) or 0,
                perSecond = tonumber(rate)  or 0,
                class     = src.classFilename,
                isLocal   = src.isLocalPlayer or false,
            }
        end
    end
    return results
end

---------------------------------------------------------------------------
-- Match a meter source to a snapshot GUID.
-- Values are plain Lua strings at this point (secrets already resolved).
-- Priority: GUID match → isLocalPlayer → name match → class+name fuzzy.
---------------------------------------------------------------------------
-- Returns true if `s` is a plain Lua string safe to compare/operate on.
-- WoW 11.x exposes some fields (notably pet names) as "secret strings":
-- they have type "string" but any comparison taints execution and aborts
-- the surrounding loop. pcall on a trivial compare detects them safely.
local function IsSafeString(s)
    if type(s) ~= "string" then return false end
    local ok = pcall(function() return s == "" end)
    return ok
end

local function MatchSourceToGUID(src, snapshots, nameToGUID)
    -- Primary: exact GUID match
    if src.guid and src.guid ~= "" and snapshots[src.guid] then
        return src.guid
    end

    -- Pets can never match a player snapshot, and their `name` field is a
    -- secret string in 11.x — touching it taints the addon and aborts
    -- enrichment for everyone. Bail out before any name comparison.
    if src.guid and src.guid:sub(1, 4) == "Pet-" then
        return nil
    end

    -- Secondary: isLocalPlayer flag (NeverSecret — always available)
    if src.isLocal then
        local myGUID = UnitGUID("player")
        if myGUID and snapshots[myGUID] then
            return myGUID
        end
    end

    -- Tertiary: name-based match (only if name is a safe, non-secret string)
    if IsSafeString(src.name) and src.name ~= "" then
        if nameToGUID[src.name] then return nameToGUID[src.name] end
        local shortName = src.name:match("^(.+)-") or src.name
        if nameToGUID[shortName] then return nameToGUID[shortName] end

        -- Quaternary: class + name fuzzy (cross-realm name differences)
        if src.class then
            local srcShort = shortName
            for guid, snap in pairs(snapshots) do
                if snap.class == src.class and IsSafeString(snap.name) then
                    local snapShort = snap.name:match("^(.+)-") or snap.name
                    if snapShort == srcShort then
                        return guid
                    end
                end
            end
        end
    end

    return nil
end

---------------------------------------------------------------------------
-- Enrich snapshots with meter data from C_DamageMeter.
-- Called from Segments.lua at segment boundaries.
--   snapshots  : { [guid] = snapshot table }
--   sessionType: Enum.DamageMeterSessionType value (nil = Current)
-- Returns true if enrichment succeeded, false if data is still secret.
---------------------------------------------------------------------------
function MeterData.EnrichSnapshots(snapshots, sessionType)
    if not apiAvailable or not snapshots then return false end
    if sessionType == nil then sessionType = SESSION_CURRENT end
    if sessionType == nil then return false end

    -- If data is still hardware-protected, bail out immediately.
    -- Caller should use DeferredEnrichSegment to retry after combat drops.
    if IsDataSecret(sessionType) then
        return false
    end

    -- Build name→guid lookup for fallback matching
    local nameToGUID = {}
    for guid, snap in pairs(snapshots) do
        if snap.name then
            local shortName = snap.name:match("^(.+)-") or snap.name
            nameToGUID[shortName] = guid
            nameToGUID[snap.name] = guid
        end
    end

    -- Initialize meter fields on all snapshots
    for _, snap in pairs(snapshots) do
        if snap.damageDone == nil then snap.damageDone = 0 end
        if snap.dps == nil then snap.dps = 0 end
        if snap.healingDone == nil then snap.healingDone = 0 end
        if snap.hps == nil then snap.hps = 0 end
        if snap.interrupts == nil then snap.interrupts = 0 end
        if snap.dispels == nil then snap.dispels = 0 end
        if snap.avoidableDamage == nil then snap.avoidableDamage = 0 end
        if snap.meterDeaths == nil then snap.meterDeaths = 0 end
    end

    -- Query each meter type and apply to matching snapshots
    local queries = {
        { type = METER_TYPE.DamageDone,           totalField = "damageDone",      rateField = "dps" },
        { type = METER_TYPE.HealingDone,          totalField = "healingDone",     rateField = "hps" },
        { type = METER_TYPE.Interrupts,           totalField = "interrupts" },
        { type = METER_TYPE.Dispels,              totalField = "dispels" },
        { type = METER_TYPE.AvoidableDamageTaken, totalField = "avoidableDamage" },
        { type = METER_TYPE.Deaths,               totalField = "meterDeaths" },
    }

    local enrichedGUIDs = {}  -- track which players got meter data

    for _, q in ipairs(queries) do
        if q.type ~= nil then
            local sources = QueryMeterType(sessionType, q.type)
            if sources then
                for _, src in ipairs(sources) do
                    -- pcall guard: even with the Pet-prefix fast-path, a future
                    -- secret-string field could otherwise abort the whole loop
                    -- and leave most players unenriched (the "Carried" bug).
                    local ok, matched = pcall(MatchSourceToGUID, src, snapshots, nameToGUID)
                    if ok and matched then
                        local snap = snapshots[matched]
                        snap[q.totalField] = src.total
                        if q.rateField then
                            snap[q.rateField] = src.perSecond
                        end
                        enrichedGUIDs[matched] = true
                    end
                end
            end
        end
    end

    -- Diagnostic: report enrichment results
    local totalPlayers = 0
    for _ in pairs(snapshots) do totalPlayers = totalPlayers + 1 end
    local enrichedCount = 0
    for _ in pairs(enrichedGUIDs) do enrichedCount = enrichedCount + 1 end
    if totalPlayers > 0 then
        print(string.format("|cffffffffCad|r|cffFFD666ence|r: Meter enrichment: %d/%d players matched.",
            enrichedCount, totalPlayers))
        if enrichedCount == 0 then
            local testSources = QueryMeterType(sessionType, METER_TYPE.DamageDone)
            local srcCount = testSources and #testSources or 0
            print(string.format("  |cffff8888API returned %d damage sources but matched 0 players.|r", srcCount))
            if testSources and testSources[1] then
                local s = testSources[1]
                print(string.format("  |cffff8888Sample source: guid=%s name=%s class=%s total=%.0f|r",
                    tostring(s.guid or "NIL"), tostring(s.name or "NIL"),
                    tostring(s.class or "NIL"), s.total or 0))
            end
        end
    end

    return true
end

---------------------------------------------------------------------------
-- Deferred enrichment — waits for secret values to resolve post-combat,
-- then enriches the segment's player snapshots and re-scores them.
-- Models Details' approach: poll with C_Timer.NewTicker(1) checking
-- issecretvalue() until data is readable.
--
-- segment     : the segment table (has .players)
-- contentType : "raid" / "mythicplus" / "arena" (for scoring weights)
-- sessionType : Enum.DamageMeterSessionType (nil = Current)
-- onDone(ok)  : callback when enrichment finishes (true) or times out (false)
---------------------------------------------------------------------------
local function RescoreSegment(segment, contentType)
    local Scoring = PC.Scoring
    if not Scoring or not segment or not segment.players then return end
    local ctx = { difficultyID = segment.difficultyID, keystoneLevel = segment.keystoneLevel }
    for guid, snap in pairs(segment.players) do
        snap.cadenceScore = Scoring.CalcCadenceLiveScore(snap, segment.players, contentType, ctx)
    end
end

function MeterData.DeferredEnrichSegment(segment, contentType, sessionType, onDone)
    if not apiAvailable or not segment or not segment.players then
        if onDone then onDone(false) end
        return
    end
    if sessionType == nil then sessionType = SESSION_CURRENT end
    if sessionType == nil then
        if onDone then onDone(false) end
        return
    end

    -- If data is already available, enrich immediately
    if not IsDataSecret(sessionType) then
        MeterData.EnrichSnapshots(segment.players, sessionType)
        RescoreSegment(segment, contentType)
        if onDone then onDone(true) end
        return
    end

    -- Data is still secret — poll every 1s until combat drops and secrets resolve
    local attempts = 0
    local MAX_ATTEMPTS = 30  -- 30 second timeout
    local ticker
    ticker = C_Timer.NewTicker(1.0, function()
        attempts = attempts + 1

        if not IsDataSecret(sessionType) then
            ticker:Cancel()
            MeterData.EnrichSnapshots(segment.players, sessionType)
            RescoreSegment(segment, contentType)
            print(string.format(
                "|cffffffffCad|r|cffFFD666ence|r: Meter data resolved after %ds — scores updated.",
                attempts))
            if onDone then onDone(true) end
            return
        end

        if attempts >= MAX_ATTEMPTS then
            ticker:Cancel()
            print("|cffffffffCad|r|cffFFD666ence|r: |cffff8888Meter data timed out — scores are engagement-only.|r")
            if onDone then onDone(false) end
        end
    end)
end

---------------------------------------------------------------------------
-- Live meter data cache (for UI_Meter periodic refresh during combat)
---------------------------------------------------------------------------
local liveMeterCache = {}   -- [guid] = { damageDone, dps, ... }
local liveCacheTime = 0
local LIVE_CACHE_INTERVAL = 2.0

function MeterData.GetLiveMeterData()
    if not apiAvailable then return liveMeterCache end

    local now = GetTime()
    if (now - liveCacheTime) < LIVE_CACHE_INTERVAL then
        return liveMeterCache
    end
    liveCacheTime = now

    -- Wipe old data
    for k in pairs(liveMeterCache) do liveMeterCache[k] = nil end

    if SESSION_CURRENT == nil then return liveMeterCache end

    -- During combat, data is secret — we can't read numbers.
    -- Return empty cache; the real enrichment happens post-combat
    -- via DeferredEnrichSegment.
    if IsDataSecret(SESSION_CURRENT) then
        return liveMeterCache
    end

    -- Out of combat: data is readable.  Build cache from API.
    local Tracker = PC.Tracker
    local nameToRealGUID = {}
    if Tracker and Tracker.GetAllPlayerData then
        for guid, pd in pairs(Tracker.GetAllPlayerData()) do
            if pd.name then
                local shortName = pd.name:match("^(.+)-") or pd.name
                nameToRealGUID[shortName] = guid
                nameToRealGUID[pd.name] = guid
            end
        end
    end

    local queries = {
        { type = METER_TYPE.DamageDone,           totalField = "damageDone",      rateField = "dps" },
        { type = METER_TYPE.HealingDone,          totalField = "healingDone",     rateField = "hps" },
        { type = METER_TYPE.Interrupts,           totalField = "interrupts" },
        { type = METER_TYPE.Dispels,              totalField = "dispels" },
        { type = METER_TYPE.AvoidableDamageTaken, totalField = "avoidableDamage" },
        { type = METER_TYPE.Deaths,               totalField = "meterDeaths" },
    }

    for _, q in ipairs(queries) do
        if q.type ~= nil then
            local sources = QueryMeterType(SESSION_CURRENT, q.type)
            if sources then
                for _, src in ipairs(sources) do
                    local realGUID = nil

                    -- Primary: exact GUID match.
                    -- src.guid can be a tainted "secret string" out of C_DamageMeter,
                    -- which throws if you compare it directly.  Use pcall to safely
                    -- probe equality / table lookup; on failure we fall through to
                    -- the isLocal / name fallbacks below.
                    if src.guid and Tracker and Tracker.GetAllPlayerData then
                        local ok, isMatch = pcall(function()
                            return src.guid ~= "" and Tracker.GetAllPlayerData()[src.guid] ~= nil
                        end)
                        if ok and isMatch then
                            realGUID = src.guid
                        end
                    end

                    -- Secondary: isLocalPlayer
                    if not realGUID and src.isLocal then
                        local myGUID = UnitGUID("player")
                        if myGUID and Tracker and Tracker.GetAllPlayerData and Tracker.GetAllPlayerData()[myGUID] then
                            realGUID = myGUID
                        end
                    end

                    -- Tertiary: name match (also pcall-guarded — src.name can
                    -- be a tainted secret string just like src.guid).
                    if not realGUID and src.name then
                        pcall(function()
                            if src.name == "" then return end
                            if nameToRealGUID[src.name] then
                                realGUID = nameToRealGUID[src.name]
                                return
                            end
                            local shortName = src.name:match("^(.+)-") or src.name
                            if nameToRealGUID[shortName] then
                                realGUID = nameToRealGUID[shortName]
                            end
                        end)
                    end

                    if realGUID then
                        if not liveMeterCache[realGUID] then
                            liveMeterCache[realGUID] = {
                                damageDone = 0, dps = 0,
                                healingDone = 0, hps = 0,
                                interrupts = 0, dispels = 0,
                                avoidableDamage = 0, meterDeaths = 0,
                            }
                        end
                        local entry = liveMeterCache[realGUID]
                        -- Secret-value defence: a per-source totalAmount or
                        -- amountPerSecond can still be hardware-locked even
                        -- when the bulk IsDataSecret() probe (which only
                        -- inspects the first source) said the read was safe.
                        -- Storing a secret value here taints any later
                        -- comparison (e.g. table.sort on hps/dps) and aborts
                        -- the addon. Coerce to plain numbers, fall back to 0.
                        local total = src.total
                        local rate  = src.perSecond
                        if issecretvalue and total ~= nil and issecretvalue(total) then
                            total = 0
                        end
                        if issecretvalue and rate ~= nil and issecretvalue(rate) then
                            rate = 0
                        end
                        entry[q.totalField] = tonumber(total) or 0
                        if q.rateField then
                            entry[q.rateField] = tonumber(rate) or 0
                        end
                    end
                end
            end
        end
    end

    return liveMeterCache
end

function MeterData.ResetLiveCache()
    for k in pairs(liveMeterCache) do liveMeterCache[k] = nil end
    liveCacheTime = 0
end

PC.MeterData = MeterData

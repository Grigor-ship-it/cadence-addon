--[[
    Cadence - Segments.lua
    Segment creation, snapshots, history management.
    Segments are frozen copies of player data at encounter/combat boundaries.
]]

local ADDON_NAME, PC = ...

PC.Segments = {}
local Segments = PC.Segments
local Tracker = PC.Tracker
local Scoring = PC.Scoring
local Utils = PC.Utils
local MeterData = PC.MeterData

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------
local segmentHistory = {}   -- array of segment tables, most recent first
local currentSegmentName = "Current"
local currentSegmentType = "none"  -- "boss", "trash", "mythicplus", "arena", "soloshuffle", "overall"
local activeSegmentIdx = 0         -- 0 = live/current, 1+ = historical
local inMythicPlus = false          -- true while inside a M+ run (key started)
local inDungeon = false              -- true while inside any 5-player dungeon instance
local inArena = false                -- true while inside an arena instance
local isSoloShuffle = false          -- true specifically for solo shuffle arenas

-- Encounter metadata (set by Events.lua, consumed by CreateSnapshot for QR payload)
local currentEncounterID = nil       -- Blizzard encounterID from ENCOUNTER_START
local currentDifficultyID = nil      -- Blizzard difficultyID from ENCOUNTER_START/GetInstanceInfo
local currentInstanceID = nil        -- Blizzard instanceID from GetInstanceInfo
local arenaTeamSize = nil            -- 2, 3, or nil for solo shuffle
local mythicPlusStartTime = nil      -- time() when M+ key was started
local keystoneLevel = nil            -- M+ keystone level (e.g. 10 for a +10)

---------------------------------------------------------------------------
-- Persistent Accumulator
-- Merges snapshot data across pulls for a running Cadence Score.
-- Scope: "dungeon" (all pulls), "boss" (single raid boss encounter),
--        "arena"/"soloshuffle" (full match), "none" (disabled)
---------------------------------------------------------------------------
local accumulatedData = {}    -- guid -> merged data table
local accScope = "none"       -- current accumulation scope
local accScopeName = ""       -- display name for current scope
local accActive = false       -- true when actively accumulating (in-scope)

local function ResetAccumulator()
    Utils.WipeTable(accumulatedData)
end

-- Merge a single player snapshot into the accumulator
local function AccumulatePlayerSnapshot(guid, snap)
    if not guid or not snap then return end
    local acc = accumulatedData[guid]
    if not acc then
        accumulatedData[guid] = {
            guid = snap.guid,
            name = snap.name,
            class = snap.class,
            realm = snap.realm,
            role = snap.role,
            actionCount = snap.actionCount or 0,
            intentActionCount = snap.intentActionCount or 0,
            combatDuration = snap.combatDuration or 0,
            deathCount = snap.deathCount or 0,
            hasMeleeSwings = snap.hasMeleeSwings or false,
            uptime = snap.uptime or 0,
            _uptimeSum = (snap.uptime or 0) * (snap.combatDuration or 0),
            maxGap = snap.maxGap or 0,
            avgGap = snap.avgGap or 0,
            _gapSum = (snap.avgGap or 0) * (snap.combatDuration or 0),
            -- Meter data (accumulated across pulls)
            damageDone = snap.damageDone or 0,
            healingDone = snap.healingDone or 0,
            interrupts = snap.interrupts or 0,
            dispels = snap.dispels or 0,
            avoidableDamage = snap.avoidableDamage or 0,
            meterDeaths = snap.meterDeaths or 0,
            externals = snap.externals or 0,
            raidCds = snap.raidCds or 0,
            support = snap.support or 0,
            cc = snap.cc or 0,
        }
    else
        acc.name = (snap.name and snap.name ~= "Unknown") and snap.name or acc.name
        acc.class = snap.class or acc.class
        acc.realm = snap.realm or acc.realm
        acc.role = snap.role or acc.role
        acc.actionCount = acc.actionCount + (snap.actionCount or 0)
        acc.intentActionCount = (acc.intentActionCount or 0) + (snap.intentActionCount or 0)
        acc.combatDuration = acc.combatDuration + (snap.combatDuration or 0)
        acc.deathCount = acc.deathCount + (snap.deathCount or 0)
        acc.hasMeleeSwings = acc.hasMeleeSwings or (snap.hasMeleeSwings or false)
        acc._uptimeSum = acc._uptimeSum + (snap.uptime or 0) * (snap.combatDuration or 0)
        if (snap.maxGap or 0) > (acc.maxGap or 0) then
            acc.maxGap = snap.maxGap
        end
        acc._gapSum = (acc._gapSum or 0) + (snap.avgGap or 0) * (snap.combatDuration or 0)
        -- Accumulate meter data
        acc.damageDone = (acc.damageDone or 0) + (snap.damageDone or 0)
        acc.healingDone = (acc.healingDone or 0) + (snap.healingDone or 0)
        acc.interrupts = (acc.interrupts or 0) + (snap.interrupts or 0)
        acc.dispels = (acc.dispels or 0) + (snap.dispels or 0)
        acc.avoidableDamage = (acc.avoidableDamage or 0) + (snap.avoidableDamage or 0)
        acc.meterDeaths = (acc.meterDeaths or 0) + (snap.meterDeaths or 0)
        acc.externals = (acc.externals or 0) + (snap.externals or 0)
        acc.raidCds = (acc.raidCds or 0) + (snap.raidCds or 0)
        acc.support = (acc.support or 0) + (snap.support or 0)
        acc.cc = (acc.cc or 0) + (snap.cc or 0)
    end
end

-- Called after CreateSnapshot to feed the accumulator
local function MaybeAccumulate(segment)
    if accScope == "none" or not accActive then return end
    if not segment or not segment.players then return end

    local segType = segment.segType or ""

    -- For boss scope (raids), only accumulate boss segments
    if accScope == "boss" and segType ~= "boss" then return end

    for guid, snap in pairs(segment.players) do
        AccumulatePlayerSnapshot(guid, snap)
    end
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
function Segments.Init()
    -- Restore saved segments if any
    if PC.db and PC.db.segments then
        segmentHistory = PC.db.segments
    end
end

---------------------------------------------------------------------------
-- Create a new segment from current data
---------------------------------------------------------------------------
function Segments.CreateSnapshot(name, segType)
    local snapshots = Tracker.SnapshotAll()

    -- Use PvP scoring for arena / solo shuffle segments
    local effectiveType = segType or currentSegmentType
    local isPvP = (effectiveType == "arena" or effectiveType == "soloshuffle")

    -- Enrich snapshots with C_DamageMeter data BEFORE scoring.
    -- Try for every content type — meter data is just as relevant for
    -- trash pulls (M+) as it is for boss kills.  EnrichSnapshots will
    -- bail itself if data is still hardware-locked (mid-combat).
    if MeterData and MeterData.EnrichSnapshots then
        MeterData.EnrichSnapshots(snapshots, MeterData.GetSessionCurrent())
    end

    -- Compute activity scores (used as engagement component in Cadence Score)
    for guid, snap in pairs(snapshots) do
        if isPvP then
            snap.activityScore = Scoring.CalcPvPCompositeScore(guid)
        else
            snap.activityScore = Scoring.CalcCompositeScore(guid)
        end
        snap.afkFlag = Scoring.IsAFK(guid)
        snap._isPvP = isPvP or nil
    end

    -- Compute unified Cadence Score (falls back to activityScore when no meter data)
    local cadenceContentType = (effectiveType == "arena" or effectiveType == "soloshuffle") and "arena"
        or (effectiveType == "boss") and "raid" or "mythicplus"
    local scoreCtx = { difficultyID = currentDifficultyID, keystoneLevel = keystoneLevel }
    for guid, snap in pairs(snapshots) do
        snap.cadenceScore = Scoring.CalcCadenceLiveScore(snap, snapshots, cadenceContentType, scoreCtx)
        -- v9: also compute the PvP cadence score on every segment so backend has both.
        -- Only the arena weight set is meaningful in PvP; keeping a parallel value
        -- on PvE segments lets us experiment without a second pass over the data.
        snap.pvpCadenceScore = Scoring.CalcCadenceLiveScore(snap, snapshots, "arena", scoreCtx)
    end

    -- v9: tag the reporter's snapshot with their equipped item level.
    -- Other players get 0 here — backend Blizzard worker can backfill via profile API.
    local myGUID = UnitGUID("player")
    if myGUID and snapshots[myGUID] and GetAverageItemLevel then
        local _, equipped = GetAverageItemLevel()
        snapshots[myGUID].itemLevel = math.floor(equipped or 0)
    end

    local segment = {
        name = name or currentSegmentName,
        segType = segType or currentSegmentType,
        timestamp = time(),
        duration = 0,
        players = snapshots,
        -- Encounter / instance metadata for payload enrichment
        encounterID = currentEncounterID,
        difficultyID = currentDifficultyID,
        instanceID = currentInstanceID,
        -- Arena bracket info
        teamSize = arenaTeamSize,
        -- M+ keystone level
        keystoneLevel = keystoneLevel,
    }

    -- Compute max duration among players
    local maxDur = 0
    for _, snap in pairs(snapshots) do
        if snap.combatDuration and snap.combatDuration > maxDur then
            maxDur = snap.combatDuration
        end
    end
    segment.duration = maxDur

    -- Insert at front
    table.insert(segmentHistory, 1, segment)

    -- Trim history
    -- During M+ runs, keep ALL pull segments so the end-of-dungeon
    -- aggregate (_AggregateMythicPlus) can merge the full run.
    -- A typical M+ has 20-30+ pulls; trimming to 10 would discard
    -- early bosses/trash and produce an incomplete summary.
    local maxHist = 10
    if inMythicPlus then
        maxHist = 60  -- generous limit for full M+ run
    elseif PC.db and PC.db.profile then
        maxHist = PC.db.profile.maxSegmentHistory or 10
    end
    while #segmentHistory > maxHist do
        segmentHistory[#segmentHistory] = nil
    end

    -- (Meter enrichment now done before scoring above)

    -- Persist
    if PC.db then
        PC.db.segments = segmentHistory
    end

    -- Feed the persistent accumulator
    MaybeAccumulate(segment)

    return segment
end

---------------------------------------------------------------------------
-- Called on encounter start
---------------------------------------------------------------------------
function Segments.OnEncounterStart(encounterID, encounterName, difficultyID, groupSize)
    -- Auto-switch meter to live view so players see the boss name, not an old segment
    if activeSegmentIdx ~= 0 then
        activeSegmentIdx = 0
    end

    -- Snapshot any existing data as a "pre-boss" trash segment if there's data
    local hasData = false
    for _, pd in pairs(Tracker.GetAllPlayerData()) do
        if pd.actionCount > 0 then hasData = true; break end
    end

    if hasData and PC.db and PC.db.profile and PC.db.profile.autoSegmentTrash then
        Segments.CreateSnapshot("Trash", "trash")
    end

    -- In M+, do NOT reset the tracker — data must accumulate across the
    -- entire dungeon from first pull to final boss so the M+ Complete
    -- snapshot contains everything, not just the last boss.
    if not inMythicPlus then
        Tracker.ResetAll()
    end

    -- Store encounter metadata for the payload
    currentEncounterID = encounterID
    currentDifficultyID = difficultyID
    -- Also refresh instanceID from the game
    local _, _, _, _, _, _, _, instID = GetInstanceInfo()
    currentInstanceID = instID

    currentSegmentName = encounterName or ("Boss " .. (encounterID or "?"))
    currentSegmentType = "boss"

    -- Raid boss: scope persistence to this encounter
    -- (In dungeons, the dungeon scope already covers bosses)
    if not inDungeon then
        accScope = "boss"
        accScopeName = encounterName or "Boss"
        accActive = true
        ResetAccumulator()
    end
end

---------------------------------------------------------------------------
-- Called on encounter end
---------------------------------------------------------------------------
function Segments.OnEncounterEnd(encounterID, encounterName, difficultyID, groupSize, success)
    local suffix = success == 1 and " (Kill)" or " (Wipe)"
    local name = (encounterName or "Boss") .. suffix

    local segment = Segments.CreateSnapshot(name, "boss")
    -- Tag explicit success so downstream gates (QR share, summary chrome)
    -- can distinguish kills from wipes without parsing the name suffix.
    if segment then segment.success = (success == 1) end
    -- Do NOT reset tracker here — data stays visible on the meter until
    -- the next combat starts (PLAYER_REGEN_DISABLED handles the reset).
    currentSegmentName = "Current"
    currentSegmentType = inMythicPlus and "mythicplus" or "none"

    -- For raid bosses, deactivate accumulator (data stays visible until next boss)
    if accScope == "boss" then
        accActive = false
    end

    -- Deferred enrichment: ENCOUNTER_END fires while still in combat,
    -- so C_DamageMeter secrets are still hardware-locked.  We poll
    -- until they resolve, then re-enrich + re-score the segment.
    -- Summary popup is triggered by the enrichment callback so it
    -- shows real scores, not engagement-only fallbacks.
    if segment and MeterData and MeterData.DeferredEnrichSegment then
        local contentType = "raid"
        MeterData.DeferredEnrichSegment(segment, contentType, MeterData.GetSessionCurrent(), function(enriched)
            -- Show summary on boss kill (raid only — dungeon bosses wait for M+ end)
            if not inDungeon and success == 1 and PC.UI_Summary and PC.UI_Summary.Populate then
                PC.UI_Summary.Populate(segment)
            end
        end)
    elseif not inDungeon and success == 1 and segment and PC.UI_Summary and PC.UI_Summary.Populate then
        -- Fallback: no deferred enrichment available
        C_Timer.After(0.5, function()
            PC.UI_Summary.Populate(segment)
        end)
    end
end

---------------------------------------------------------------------------
-- Called on M+ start
---------------------------------------------------------------------------
function Segments.OnChallengeModeStart()
    -- Fresh M+ run: wipe all previous segments + tracker data
    Segments.ResetAll()
    Tracker.ResetAll()
    currentSegmentName = "M+ Run"
    currentSegmentType = "mythicplus"
    inMythicPlus = true
    inDungeon = true
    mythicPlusStartTime = time()
    -- Refresh instance metadata
    local _, _, diffID, _, _, _, _, instID = GetInstanceInfo()
    currentDifficultyID = diffID
    currentInstanceID = instID
    currentEncounterID = nil  -- M+ doesn't have a single encounterID
    -- Capture keystone level
    local ksLevel = C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo and C_ChallengeMode.GetActiveKeystoneInfo()
    keystoneLevel = ksLevel or nil

    -- Persistent accumulator: scope to entire M+ dungeon
    local instanceName = select(1, GetInstanceInfo()) or "M+ Run"
    accScope = "dungeon"
    accScopeName = instanceName
    accActive = true
    ResetAccumulator()
end

---------------------------------------------------------------------------
-- Called on M+ complete
---------------------------------------------------------------------------
function Segments.OnChallengeModeComplete()
    -- Use the actual dungeon name from GetInstanceInfo instead of generic "M+ Complete"
    local instanceName = select(1, GetInstanceInfo()) or "M+ Complete"

    -- ── Aggregate all boss + trash segments from this M+ run ────
    -- Per-pull tracker resets mean the live tracker only has the last
    -- pull's data.  We merge every segment created during the run to
    -- produce a single summary that covers the entire dungeon.
    local merged = Segments._AggregateMythicPlus(instanceName)

    if not merged then
        -- Fallback: snapshot current tracker (old behaviour)
        merged = Segments.CreateSnapshot(instanceName, "mythicplus")
    end

    currentSegmentName = "Current"
    currentSegmentType = "none"
    inMythicPlus = false
    mythicPlusStartTime = nil
    -- Note: inDungeon stays true until we leave the instance

    -- Deactivate accumulator AND clear its scope so the post-exit
    -- ZONE_CHANGED_NEW_AREA handler doesn't build a second
    -- duplicate dungeon segment from the still-live accumulator.
    accActive = false
    accScope = "none"
    accScopeName = nil

    -- Deferred enrichment: secrets may still be locked briefly after key completion.
    -- Poll until resolved, then show the summary with real scores.
    if merged and MeterData and MeterData.DeferredEnrichSegment then
        MeterData.DeferredEnrichSegment(merged, "mythicplus", MeterData.GetSessionOverall(), function(enriched)
            if PC.UI_Summary and PC.UI_Summary.Populate then
                PC.UI_Summary.Populate(merged)
            end
        end)
    elseif merged and PC.UI_Summary and PC.UI_Summary.Populate then
        C_Timer.After(1.0, function()
            PC.UI_Summary.Populate(merged)
        end)
    end
end

---------------------------------------------------------------------------
-- Aggregate all boss + trash segments from the current M+ run into one
-- combined segment.  Each per-pull segment captured player snapshots;
-- we merge them so the final segment represents the entire dungeon.
---------------------------------------------------------------------------
function Segments._AggregateMythicPlus(name)
    -- Collect every boss / trash segment in history (newest-first order)
    local pullSegments = {}
    for _, seg in ipairs(segmentHistory) do
        if seg.segType == "boss" or seg.segType == "trash" then
            pullSegments[#pullSegments + 1] = seg
        end
    end

    if #pullSegments == 0 then return nil end

    -- Reverse so we iterate oldest → newest (matches chronological order)
    local ordered = {}
    for i = #pullSegments, 1, -1 do
        ordered[#ordered + 1] = pullSegments[i]
    end

    -- ── Merge player data across all pulls ──────────────────
    local merged = {}  -- guid → aggregated snapshot
    local totalDuration = 0

    for _, seg in ipairs(ordered) do
        totalDuration = totalDuration + (seg.duration or 0)
        for guid, snap in pairs(seg.players or {}) do
            if not merged[guid] then
                -- First occurrence: seed with a copy
                merged[guid] = {
                    guid = snap.guid,
                    name = snap.name,
                    class = snap.class,
                    realm = snap.realm,
                    role = snap.role,
                    actionCount = snap.actionCount or 0,
                    intentActionCount = snap.intentActionCount or 0,
                    swingCount = snap.swingCount or 0,
                    combatDuration = snap.combatDuration or 0,
                    deathCount = snap.deathCount or 0,
                    maxGap = snap.maxGap or 0,
                    avgGap = snap.avgGap or 0,
                    _avgGapSum = (snap.avgGap or 0) * (snap.combatDuration or 0),
                    uptime = 0,
                    rawUptime = 0,
                    hasMeleeSwings = snap.hasMeleeSwings or false,
                    topAbilities = {},
                    _abilMap = {},    -- spellID → count (work table)
                    _uptimeSum = (snap.uptime or 0) * (snap.combatDuration or 0),
                    archetype = snap.archetype,
                    expectedAPM = snap.expectedAPM,
                    isEnemy = snap.isEnemy,
                    -- Meter data (will be overridden by Overall session later)
                    damageDone = snap.damageDone or 0,
                    healingDone = snap.healingDone or 0,
                    interrupts = snap.interrupts or 0,
                    dispels = snap.dispels or 0,
                    avoidableDamage = snap.avoidableDamage or 0,
                    meterDeaths = snap.meterDeaths or 0,
                    externals = snap.externals or 0,
                    raidCds = snap.raidCds or 0,
                    support = snap.support or 0,
                    cc = snap.cc or 0,
                    dps = snap.dps or 0,
                    hps = snap.hps or 0,
                }
                -- Seed ability map
                for _, ab in ipairs(snap.topAbilities or {}) do
                    if ab.spellID then
                        merged[guid]._abilMap[ab.spellID] = {
                            name = ab.name,
                            count = ab.count or 0,
                            school = ab.school,
                        }
                    end
                end
            else
                local m = merged[guid]
                m.actionCount     = m.actionCount + (snap.actionCount or 0)
                m.intentActionCount = (m.intentActionCount or 0) + (snap.intentActionCount or 0)
                m.swingCount      = (m.swingCount or 0) + (snap.swingCount or 0)
                m.combatDuration  = m.combatDuration + (snap.combatDuration or 0)
                m.deathCount      = m.deathCount + (snap.deathCount or 0)
                if (snap.maxGap or 0) > m.maxGap then
                    m.maxGap = snap.maxGap
                end
                m._avgGapSum = (m._avgGapSum or 0) + (snap.avgGap or 0) * (snap.combatDuration or 0)
                m._uptimeSum = m._uptimeSum + (snap.uptime or 0) * (snap.combatDuration or 0)
                m.hasMeleeSwings = m.hasMeleeSwings or (snap.hasMeleeSwings or false)
                -- Accumulate meter data (will be overridden by Overall session)
                m.damageDone = (m.damageDone or 0) + (snap.damageDone or 0)
                m.healingDone = (m.healingDone or 0) + (snap.healingDone or 0)
                m.interrupts = (m.interrupts or 0) + (snap.interrupts or 0)
                m.dispels = (m.dispels or 0) + (snap.dispels or 0)
                m.avoidableDamage = (m.avoidableDamage or 0) + (snap.avoidableDamage or 0)
                m.meterDeaths = (m.meterDeaths or 0) + (snap.meterDeaths or 0)
                m.externals = (m.externals or 0) + (snap.externals or 0)
                m.raidCds = (m.raidCds or 0) + (snap.raidCds or 0)
                m.support = (m.support or 0) + (snap.support or 0)
                m.cc = (m.cc or 0) + (snap.cc or 0)
                -- Merge abilities
                for _, ab in ipairs(snap.topAbilities or {}) do
                    if ab.spellID then
                        local existing = m._abilMap[ab.spellID]
                        if existing then
                            existing.count = existing.count + (ab.count or 0)
                        else
                            m._abilMap[ab.spellID] = {
                                name = ab.name,
                                count = ab.count or 0,
                                school = ab.school,
                            }
                        end
                    end
                end
            end
        end
    end

    -- ── Finalize: compute derived stats ─────────────────────
    for guid, m in pairs(merged) do
        -- Weighted average uptime
        if m.combatDuration > 0 then
            m.uptime = m._uptimeSum / m.combatDuration
            m.rawUptime = m.uptime
            m.apm = m.actionCount / (m.combatDuration / 60)
            m.rawApm = m.apm
            m.avgGap = (m._avgGapSum or 0) / m.combatDuration
        else
            m.uptime = 0
            m.rawUptime = 0
            m.apm = 0
            m.rawApm = 0
        end

        -- Build topAbilities list sorted by count descending
        local abils = {}
        for spellID, info in pairs(m._abilMap) do
            abils[#abils + 1] = {
                spellID = spellID,
                name = info.name,
                count = info.count,
                school = info.school,
            }
        end
        table.sort(abils, function(a, b) return a.count > b.count end)
        -- Keep top 10 + compute percent
        local top = {}
        local totalActions = m.intentActionCount or m.actionCount or 0
        for i = 1, math.min(#abils, 10) do
            local ab = abils[i]
            ab.percent = totalActions > 0 and (ab.count / totalActions * 100) or 0
            top[i] = ab
        end
        m.topAbilities = top

        -- Clean work tables
        m._abilMap = nil
        m._uptimeSum = nil
        m._avgGapSum = nil

        -- Compute activity score using the merged stats
        m.activityScore = Scoring.CalcCompositeScoreFromSnapshot(m)
    end

    -- Enrich with C_DamageMeter Overall session (full dungeon totals)
    -- This overrides any per-pull meter sums with the authoritative totals.
    -- May return false if data is still secret; caller uses DeferredEnrichSegment.
    local enriched = false
    if MeterData and MeterData.EnrichSnapshots then
        enriched = MeterData.EnrichSnapshots(merged, MeterData.GetSessionOverall())
    end

    -- Compute unified Cadence Score for each player
    local mplusCtx = { difficultyID = currentDifficultyID, keystoneLevel = keystoneLevel }
    for guid, m in pairs(merged) do
        m.cadenceScore = Scoring.CalcCadenceLiveScore(m, merged, "mythicplus", mplusCtx)
    end

    -- ── Build the segment ───────────────────────────────────
    -- Use wall-clock M+ duration if available, else sum of segment durations
    local wallDuration = mythicPlusStartTime and (time() - mythicPlusStartTime) or totalDuration

    local segment = {
        name = name or "M+ Complete",
        segType = "mythicplus",
        timestamp = time(),
        duration = wallDuration,
        players = merged,
        encounterID = nil,
        difficultyID = currentDifficultyID,
        instanceID = currentInstanceID,
        teamSize = nil,
        keystoneLevel = keystoneLevel,
    }

    -- Insert at front of history
    table.insert(segmentHistory, 1, segment)

    -- Trim
    local maxHist = 15  -- allow a few extra so M+ pulls + aggregate fit
    if PC.db and PC.db.profile then
        maxHist = PC.db.profile.maxSegmentHistory or 15
    end
    while #segmentHistory > maxHist do
        segmentHistory[#segmentHistory] = nil
    end

    if PC.db then
        PC.db.segments = segmentHistory
    end

    return segment
end

---------------------------------------------------------------------------
-- OnCombatEnd is now handled by Events.lua (PLAYER_REGEN_ENABLED)
-- Trash segments are created there with proper naming and reset.
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Segment browsing
---------------------------------------------------------------------------
function Segments.GetHistory()
    return segmentHistory
end

function Segments.GetCount()
    return #segmentHistory
end

function Segments.GetSegment(idx)
    return segmentHistory[idx]
end

function Segments.GetActiveIndex()
    return activeSegmentIdx
end

function Segments.GetCurrentName()
    return currentSegmentName
end

function Segments.SwitchTo(idx)
    if idx == 0 then
        activeSegmentIdx = 0
        print("|cffffffffCad|r|cffFFD666ence|r: Viewing live data.")
    elseif idx >= 1 and idx <= #segmentHistory then
        activeSegmentIdx = idx
        local seg = segmentHistory[idx]
        print("|cffffffffCad|r|cffFFD666ence|r: Viewing segment: " .. (seg.name or "?"))
    else
        print("|cffffffffCad|r|cffFFD666ence|r: Invalid segment index. " .. #segmentHistory .. " segments available.")
    end

    -- Force UI refresh
    if PC.UI_Meter and PC.UI_Meter.ForceRefresh then
        PC.UI_Meter.ForceRefresh()
    end
end

---------------------------------------------------------------------------
-- Reset
---------------------------------------------------------------------------
function Segments.ResetAll()
    Utils.WipeTable(segmentHistory)
    activeSegmentIdx = 0
    currentSegmentName = "Current"
    currentSegmentType = "none"
    inMythicPlus = false
    inArena = false
    isSoloShuffle = false
    currentEncounterID = nil
    currentDifficultyID = nil
    currentInstanceID = nil
    mythicPlusStartTime = nil
    keystoneLevel = nil
    -- inDungeon is NOT reset here: it tracks physical instance presence

    -- Reset persistent accumulator
    accScope = "none"
    accScopeName = ""
    accActive = false
    ResetAccumulator()

    if PC.db then
        PC.db.segments = segmentHistory
    end
end

---------------------------------------------------------------------------
-- Query: are we inside an active M+ run?
---------------------------------------------------------------------------
function Segments.IsInMythicPlus()
    return inMythicPlus
end

---------------------------------------------------------------------------
-- Current scoring context (difficulty, keystone level) — used by live
-- scorers (UI_Meter / UI_Summary) to pass tier hints to Scoring.
---------------------------------------------------------------------------
function Segments.GetCurrentScoreContext()
    return { difficultyID = currentDifficultyID, keystoneLevel = keystoneLevel }
end

---------------------------------------------------------------------------
-- Query / set dungeon state (any 5-player instance)
---------------------------------------------------------------------------
function Segments.IsInDungeon()
    return inDungeon
end

function Segments.SetInDungeon(val)
    inDungeon = val
    if val and accScope ~= "dungeon" and not inMythicPlus then
        -- Entering a non-M+ dungeon: start dungeon-wide accumulation
        local instanceName = select(1, GetInstanceInfo()) or "Dungeon"
        accScope = "dungeon"
        accScopeName = instanceName
        accActive = true
        print("|cffFFD666Cadence|r: Persistent score tracking \226\128\148 " .. instanceName)
        -- Don't reset here — ResetAll was already called on new instance
    elseif not val and accScope == "dungeon" then
        -- Leaving dungeon: deactivate (data stays for review)
        accActive = false
    end
end

---------------------------------------------------------------------------
-- Arena / Solo Shuffle support
---------------------------------------------------------------------------
function Segments.OnArenaStart(isShuffleRound)
    -- Solo Shuffle: we treat the entire 6-round match as ONE segment.
    -- If we're already inside an active shuffle, subsequent PVP_MATCH_ACTIVE
    -- pulses (between-round transitions) are no-ops here — we keep the
    -- accumulated tracker data and let Events.lua resume combat tracking.
    if isSoloShuffle and isShuffleRound then
        return
    end

    -- Fresh arena (first round of shuffle, or any 2v2/3v3): wipe tracker.
    Tracker.ResetAll()

    local _, _, diffID, _, _, _, _, instID = GetInstanceInfo()
    currentDifficultyID = diffID
    currentInstanceID = instID
    currentEncounterID = nil  -- arena has no encounterID

    -- Determine arena bracket: solo shuffle, or team size from group count
    if isShuffleRound then
        isSoloShuffle = true
        inArena = true
        arenaTeamSize = nil  -- solo shuffle doesn't use team size
        currentSegmentType = "soloshuffle"
        currentSegmentName = "Solo Shuffle Round"
    else
        inArena = true
        isSoloShuffle = false
        -- Team size: in 2v2 we have 1 party member + self = 2, in 3v3 = 3
        local groupSize = GetNumGroupMembers()
        arenaTeamSize = (groupSize > 0) and groupSize or 2
        currentSegmentType = "arena"
        currentSegmentName = "Arena Match"
    end

    -- Persistent accumulator: scope to the full arena/shuffle match
    if not isSoloShuffle or not accActive then
        accScope = isShuffleRound and "soloshuffle" or "arena"
        accScopeName = isShuffleRound and "Solo Shuffle" or "Arena"
        accActive = true
        if not isShuffleRound or not isSoloShuffle then
            ResetAccumulator()
        end
    end
end

function Segments.OnArenaEnd(winnerTeam)
    local suffix = ""
    if winnerTeam then
        -- In arena: team 0 = player's team won, 1 = lost (this varies;
        -- the Events.lua handler determines win/loss from GetBattlefieldWinner)
        suffix = winnerTeam and " (Win)" or " (Loss)"
    end

    local segType = isSoloShuffle and "soloshuffle" or "arena"
    local name = currentSegmentName .. suffix
    local segment = Segments.CreateSnapshot(name, segType)

    currentSegmentName = "Current"
    currentSegmentType = "none"

    -- Deactivate accumulator (data stays for summary)
    accActive = false

    -- Auto-show summary after arena
    if segment and PC.UI_Summary and PC.UI_Summary.Populate then
        C_Timer.After(1.0, function()
            PC.UI_Summary.Populate(segment)
        end)
    end
end

function Segments.IsInArena()
    return inArena
end

function Segments.SetInArena(val)
    inArena = val
end

function Segments.IsSoloShuffle()
    return isSoloShuffle
end

---------------------------------------------------------------------------
-- Setters for encounter metadata (called by Events.lua)
---------------------------------------------------------------------------
function Segments.SetInstanceID(id)
    currentInstanceID = id
end

function Segments.SetDifficultyID(id)
    currentDifficultyID = id
end

---------------------------------------------------------------------------
-- Persistent Accumulator — public API
---------------------------------------------------------------------------

--- Get a merged snapshot (accumulated + live) for a player.
-- During active combat, includes current pull data.
-- Between pulls, returns frozen accumulated data only.
function Segments.GetPersistentSnapshot(guid)
    if accScope == "none" then return nil end

    local acc = accumulatedData[guid]
    local hasAcc = acc and (acc.combatDuration or 0) > 0

    -- Only include live tracker data when actively in-scope
    local pd = accActive and Tracker.GetPlayerData(guid) or nil
    local hasLive = pd and pd.actionCount > 0

    if not hasAcc and not hasLive then return nil end

    local merged = {
        actionCount = 0,
        intentActionCount = 0,
        combatDuration = 0,
        deathCount = 0,
        hasMeleeSwings = false,
        role = nil,
        uptime = 0,
        _uptimeSum = 0,
        -- Meter data
        damageDone = 0,
        healingDone = 0,
        interrupts = 0,
        dispels = 0,
        avoidableDamage = 0,
        meterDeaths = 0,
    }

    if hasAcc then
        merged.actionCount = acc.actionCount
        merged.intentActionCount = acc.intentActionCount
        merged.combatDuration = acc.combatDuration
        merged.deathCount = acc.deathCount
        merged.hasMeleeSwings = acc.hasMeleeSwings
        merged.role = acc.role
        merged._uptimeSum = acc._uptimeSum
        merged.damageDone = acc.damageDone or 0
        merged.healingDone = acc.healingDone or 0
        merged.interrupts = acc.interrupts or 0
        merged.dispels = acc.dispels or 0
        merged.avoidableDamage = acc.avoidableDamage or 0
        merged.meterDeaths = acc.meterDeaths or 0
    end

    if hasLive then
        local liveDuration = Tracker.GetCombatDuration(guid)
        merged.actionCount = merged.actionCount + pd.actionCount
        merged.intentActionCount = merged.intentActionCount + pd.intentActionCount
        merged.combatDuration = merged.combatDuration + liveDuration
        merged.deathCount = merged.deathCount + (pd.deathCount or 0)
        merged.hasMeleeSwings = merged.hasMeleeSwings or pd.hasMeleeSwings
        if not merged.role then merged.role = Utils.GetRoleByGUID(guid) end

        local liveUptime = Tracker.GetIntentUptimePercent(guid)
        merged._uptimeSum = merged._uptimeSum + liveUptime * liveDuration
    end

    if merged.combatDuration <= 0 then return nil end

    merged.apm = merged.intentActionCount / (merged.combatDuration / 60)
    merged.uptime = merged._uptimeSum / merged.combatDuration
    -- Compute DPS/HPS rates from accumulated totals
    if merged.damageDone > 0 then
        merged.dps = merged.damageDone / merged.combatDuration
    else
        merged.dps = 0
    end
    if merged.healingDone > 0 then
        merged.hps = merged.healingDone / merged.combatDuration
    else
        merged.hps = 0
    end

    return merged
end

--- Compute the persistent Cadence Score for a player (accumulated + live).
function Segments.GetPersistentScore(guid)
    local snap = Segments.GetPersistentSnapshot(guid)
    if not snap then return nil end
    -- Always compute activityScore first (engagement component)
    if not snap.activityScore then
        snap.activityScore = Scoring.CalcCompositeScoreFromSnapshot(snap)
    end
    -- Gather all persistent snapshots for group-relative scoring
    local allSnaps = {}
    for g, _ in pairs(accumulatedData) do
        allSnaps[g] = Segments.GetPersistentSnapshot(g)
    end
    local contentType = (accScope == "arena" or accScope == "soloshuffle") and "arena"
        or (accScope == "boss") and "raid" or "mythicplus"
    return Scoring.CalcCadenceLiveScore(snap, allSnaps, contentType,
        { difficultyID = currentDifficultyID, keystoneLevel = keystoneLevel })
end

--- Is the accumulator active for any scope?
function Segments.IsAccumulating()
    return accScope ~= "none"
end

--- Get the current accumulation scope ("dungeon", "boss", "arena", "soloshuffle", "none").
function Segments.GetAccumulatorScope()
    return accScope
end

--- Get the display name for the current scope (instance name, boss name, etc.).
function Segments.GetAccumulatorScopeName()
    return accScopeName
end

--- Build a segment from accumulated data (for end-of-dungeon summary).
function Segments.BuildAccumulatedSegment()
    if accScope == "none" then return nil end

    local players = {}
    local maxDur = 0
    local hasAny = false

    for guid, acc in pairs(accumulatedData) do
        if (acc.combatDuration or 0) > 0 then
            hasAny = true
            local snap = {
                guid = acc.guid,
                name = acc.name,
                class = acc.class,
                realm = acc.realm,
                role = acc.role,
                actionCount = acc.actionCount or 0,
                intentActionCount = acc.intentActionCount or 0,
                combatDuration = acc.combatDuration or 0,
                deathCount = acc.deathCount or 0,
                hasMeleeSwings = acc.hasMeleeSwings or false,
                maxGap = acc.maxGap or 0,
                avgGap = (acc._gapSum and (acc.combatDuration or 0) > 0)
                    and (acc._gapSum / acc.combatDuration) or (acc.avgGap or 0),
                uptime = acc._uptimeSum and acc.combatDuration > 0
                    and (acc._uptimeSum / acc.combatDuration) or 0,
                apm = acc.intentActionCount > 0 and acc.combatDuration > 0
                    and (acc.intentActionCount / (acc.combatDuration / 60)) or 0,
                -- Meter data
                damageDone = acc.damageDone or 0,
                dps = (acc.damageDone or 0) > 0 and acc.combatDuration > 0
                    and ((acc.damageDone or 0) / acc.combatDuration) or 0,
                healingDone = acc.healingDone or 0,
                hps = (acc.healingDone or 0) > 0 and acc.combatDuration > 0
                    and ((acc.healingDone or 0) / acc.combatDuration) or 0,
                interrupts = acc.interrupts or 0,
                dispels = acc.dispels or 0,
                avoidableDamage = acc.avoidableDamage or 0,
                meterDeaths = acc.meterDeaths or 0,
            }
            snap.activityScore = Scoring.CalcCompositeScoreFromSnapshot(snap)
            players[guid] = snap
            if snap.combatDuration > maxDur then maxDur = snap.combatDuration end
        end
    end

    if not hasAny then return nil end

    -- Compute cadence score with group-relative data (scope-aware contentType)
    local accContentType = (accScope == "arena" or accScope == "soloshuffle") and "arena"
        or (accScope == "boss") and "raid" or "mythicplus"
    local accCtx = { difficultyID = currentDifficultyID, keystoneLevel = keystoneLevel }
    for guid, snap in pairs(players) do
        snap.cadenceScore = Scoring.CalcCadenceLiveScore(snap, players, accContentType, accCtx)
    end

    local segment = {
        name = accScopeName or "Dungeon",
        segType = "dungeon",
        timestamp = time(),
        duration = maxDur,
        players = players,
        difficultyID = currentDifficultyID,
        instanceID = currentInstanceID,
    }

    -- Insert into history
    table.insert(segmentHistory, 1, segment)
    if PC.db then PC.db.segments = segmentHistory end

    return segment
end

PC.Segments = Segments

--[[
    Cadence - Tracker.lua
    Per-player activity data accumulation.
    Maintains ring buffers of action timestamps, ability frequency maps,
    swing timestamps, and gap tracking.
]]

local ADDON_NAME, PC = ...

PC.Tracker = {}
local Tracker = PC.Tracker
local Utils = PC.Utils

---------------------------------------------------------------------------
-- Player data storage
-- Key: playerGUID
-- Value: { ... per-player tracking table ... }
---------------------------------------------------------------------------
local playerData = {}

-- Max timestamps to keep in the ring buffer (for rolling window calculations)
-- At 60 APM * 10 min fight = 600 entries. 1200 gives headroom.
local MAX_TIMESTAMPS = 1200
local MAX_SWING_TIMESTAMPS = 600

-- Scratch tables reused in hot-path computations to avoid GC pressure.
-- NEVER hold references to these across frames — they are wiped each call.
local _scratchSorted   = {}
local _scratchSorted2  = {}
local _scratchIntervals = {}

local function WipeScratch(t, count)
    for i = 1, count do t[i] = nil end
end

---------------------------------------------------------------------------
-- Create / get player record
---------------------------------------------------------------------------
local function CreatePlayerRecord(guid)
    return {
        guid = guid,
        name = Utils.GetNameByGUID(guid),
        class = Utils.GetClassByGUID(guid),
        realm = Utils.GetRealmByGUID(guid),

        -- Action tracking (all UNIT_SPELLCAST_SUCCEEDED events)
        actionCount = 0,
        actionTimestamps = {},  -- ring buffer of GetTime() values
        tsWriteIdx = 0,         -- next write position

        -- Intent action tracking (filtered: GCD/castTime/≥6s CD only)
        intentActionCount = 0,
        intentTimestamps = {},  -- ring buffer for intentional actions
        intentWriteIdx = 0,
        lastIntentTime = nil,
        maxIntentGap = 0,
        intentGapSum = 0,
        intentGapCount = 0,

        -- Swing tracking (melee only)
        swingCount = 0,
        swingTimestamps = {},
        swingWriteIdx = 0,

        -- Gap tracking (raw, kept for debug / AFK detection)
        lastActionTime = nil,
        maxGap = 0,
        gapSum = 0,
        gapCount = 0,

        -- Ability breakdown
        abilityMap = {},  -- [spellID] = { name=, count=, school= }

        -- Combat timing
        combatStartTime = nil,
        combatEndTime = nil,
        effectiveEndTime = nil,  -- last-action trim: real end of activity
        inCombat = false,

        -- Melee heuristic flag
        hasMeleeSwings = false,

        -- Utility tracking (classified via C_Spell.IsExternalDefensive + SpellDB)
        externalCount = 0,
        raidCdCount = 0,
        supportCount = 0,
        ccCount = 0,

        -- Death tracking
        deathCount = 0,
        deathTimestamps = {},

        -- Cached computed values (refreshed on UI update)
        _cachedScore = 0,
        _cachedAPM = 0,
        _cacheTime = 0,
    }
end

function Tracker.GetPlayerData(guid)
    return playerData[guid]
end

function Tracker.GetAllPlayerData()
    return playerData
end

function Tracker.EnsurePlayer(guid)
    if not playerData[guid] then
        playerData[guid] = CreatePlayerRecord(guid)
    end
    return playerData[guid]
end

---------------------------------------------------------------------------
-- Record an action (SPELL_CAST_SUCCESS)
---------------------------------------------------------------------------
function Tracker.RecordAction(guid, spellID, spellName, spellSchool, timestamp)
    local pd = Tracker.EnsurePlayer(guid)

    -- Update name/class/realm from cache (may not have been available at creation)
    pd.name = Utils.GetNameByGUID(guid)
    pd.class = Utils.GetClassByGUID(guid)
    pd.realm = Utils.GetRealmByGUID(guid) or pd.realm

    -- Combat start
    if not pd.combatStartTime then
        pd.combatStartTime = timestamp
    end
    pd.inCombat = true
    pd.combatEndTime = nil

    -- Action count
    pd.actionCount = pd.actionCount + 1

    -- Ring buffer timestamp
    pd.tsWriteIdx = pd.tsWriteIdx + 1
    if pd.tsWriteIdx > MAX_TIMESTAMPS then
        pd.tsWriteIdx = 1  -- wrap around
    end
    pd.actionTimestamps[pd.tsWriteIdx] = timestamp

    -- Gap tracking
    if pd.lastActionTime then
        local gap = timestamp - pd.lastActionTime
        if gap > 0 then
            if gap > pd.maxGap then
                pd.maxGap = gap
            end
            pd.gapSum = pd.gapSum + gap
            pd.gapCount = pd.gapCount + 1
        end
    end
    pd.lastActionTime = timestamp

    -- Ability breakdown (local player only — other players' spellIDs are
    -- unreliable in Midnight 12.0; USCS can report the local player's
    -- spells for group members, and CLEU spellIDs may be nil/tainted)
    if spellID and guid == UnitGUID("player") then
        local entry = pd.abilityMap[spellID]
        if not entry then
            pd.abilityMap[spellID] = {
                name = spellName or "Unknown",
                count = 1,
                school = spellSchool or 1,
            }
        else
            entry.count = entry.count + 1
        end
    end
end

---------------------------------------------------------------------------
-- Record one polling tick from Polling.lua.
-- isActive=true means this player's combined damage+healing total grew
-- in the last poll interval -> they did SOMETHING.  Counts as both an
-- action and an intent action (no need to dedup; polling already
-- aggregates everything inside one interval into one tick).
-- isActive=false means we observed them but they were idle this tick;
-- still useful for gap tracking so we don't credit silent stretches.
---------------------------------------------------------------------------
function Tracker.RecordPollTick(guid, isActive, ts)
    local pd = Tracker.EnsurePlayer(guid)

    pd.name  = Utils.GetNameByGUID(guid)
    pd.class = Utils.GetClassByGUID(guid)
    pd.realm = Utils.GetRealmByGUID(guid) or pd.realm

    -- If combat has already ended for this player (post-combat flush poll
    -- catching the last 20s of activity), do NOT reopen combat — just clamp
    -- the tick timestamp into the original combat window so the late ticks
    -- still credit toward APM/uptime without making GetCombatDuration grow
    -- forever (which would silently decay everyone's APM toward 0).
    if pd.combatEndTime then
        local clampEnd = pd.effectiveEndTime or pd.combatEndTime
        if ts > clampEnd then ts = clampEnd end
    else
        if not pd.combatStartTime then
            pd.combatStartTime = ts
        end
        pd.inCombat = true
    end

    if not isActive then return end

    -- Action count + ring buffer
    pd.actionCount = pd.actionCount + 1
    pd.tsWriteIdx = pd.tsWriteIdx + 1
    if pd.tsWriteIdx > MAX_TIMESTAMPS then pd.tsWriteIdx = 1 end
    pd.actionTimestamps[pd.tsWriteIdx] = ts

    -- Raw gap tracking
    if pd.lastActionTime then
        local gap = ts - pd.lastActionTime
        if gap > 0 then
            if gap > pd.maxGap then pd.maxGap = gap end
            pd.gapSum = pd.gapSum + gap
            pd.gapCount = pd.gapCount + 1
        end
    end
    pd.lastActionTime = ts

    -- Intent count + ring buffer (no dedup needed: 1 tick = 1 intent)
    pd.intentActionCount = pd.intentActionCount + 1
    pd.intentWriteIdx = pd.intentWriteIdx + 1
    if pd.intentWriteIdx > MAX_TIMESTAMPS then pd.intentWriteIdx = 1 end
    pd.intentTimestamps[pd.intentWriteIdx] = ts

    if pd.lastIntentTime then
        local gap = ts - pd.lastIntentTime
        if gap > pd.maxIntentGap then pd.maxIntentGap = gap end
        pd.intentGapSum = pd.intentGapSum + gap
        pd.intentGapCount = pd.intentGapCount + 1
    end
    pd.lastIntentTime = ts
end

---------------------------------------------------------------------------
-- Record one local-player spell cast for the abilityMap (top abilities).
-- Polling.lua already drives APM/uptime; this only feeds the per-player
-- spell breakdown shown on tooltips/summary.  Local player only:
-- UNIT_SPELLCAST_SUCCEEDED is unreliable for other units in 12.0.5.
---------------------------------------------------------------------------
function Tracker.RecordPlayerSpellCast(spellID, spellName, spellSchool)
    if not spellID then return end
    local guid = UnitGUID("player")
    if not guid then return end
    local pd = Tracker.EnsurePlayer(guid)

    local entry = pd.abilityMap[spellID]
    if not entry then
        pd.abilityMap[spellID] = {
            name   = spellName or "Unknown",
            count  = 1,
            school = spellSchool or 0,
        }
    else
        entry.count = entry.count + 1
    end
end

---------------------------------------------------------------------------
-- Record an external defensive cast (C_Spell.IsExternalDefensive)
---------------------------------------------------------------------------
function Tracker.RecordExternal(guid)
    local pd = Tracker.EnsurePlayer(guid)
    pd.externalCount = (pd.externalCount or 0) + 1
end

function Tracker.RecordRaidCD(guid)
    local pd = Tracker.EnsurePlayer(guid)
    pd.raidCdCount = (pd.raidCdCount or 0) + 1
end

function Tracker.RecordSupport(guid)
    local pd = Tracker.EnsurePlayer(guid)
    pd.supportCount = (pd.supportCount or 0) + 1
end

function Tracker.RecordCC(guid)
    local pd = Tracker.EnsurePlayer(guid)
    pd.ccCount = (pd.ccCount or 0) + 1
end

---------------------------------------------------------------------------
-- Record a melee swing (SWING_DAMAGE / SWING_MISSED)
---------------------------------------------------------------------------
function Tracker.RecordSwing(guid, timestamp)
    local pd = Tracker.EnsurePlayer(guid)

    pd.hasMeleeSwings = true
    pd.swingCount = pd.swingCount + 1

    pd.swingWriteIdx = pd.swingWriteIdx + 1
    if pd.swingWriteIdx > MAX_SWING_TIMESTAMPS then
        pd.swingWriteIdx = 1
    end
    pd.swingTimestamps[pd.swingWriteIdx] = timestamp
end

---------------------------------------------------------------------------
-- Record pet → owner mapping
---------------------------------------------------------------------------
function Tracker.RecordPetSummon(petGUID, ownerGUID)
    Utils.SetPetOwner(petGUID, ownerGUID)
end

---------------------------------------------------------------------------
-- Record an intentional action (passes GCD/castTime/CD filter)
---------------------------------------------------------------------------
function Tracker.RecordIntentAction(guid, timestamp)
    local pd = Tracker.EnsurePlayer(guid)

    pd.intentActionCount = pd.intentActionCount + 1

    -- Ring buffer
    pd.intentWriteIdx = pd.intentWriteIdx + 1
    if pd.intentWriteIdx > MAX_TIMESTAMPS then
        pd.intentWriteIdx = 1
    end
    pd.intentTimestamps[pd.intentWriteIdx] = timestamp

    -- Intent gap tracking
    if pd.lastIntentTime then
        local gap = timestamp - pd.lastIntentTime
        if gap > pd.maxIntentGap then
            pd.maxIntentGap = gap
        end
        pd.intentGapSum = pd.intentGapSum + gap
        pd.intentGapCount = pd.intentGapCount + 1
    end
    pd.lastIntentTime = timestamp
end

---------------------------------------------------------------------------
-- Record a player death
---------------------------------------------------------------------------
function Tracker.RecordDeath(guid, timestamp)
    local pd = playerData[guid]
    if not pd then return end
    pd.deathCount = pd.deathCount + 1
    pd.deathTimestamps[#pd.deathTimestamps + 1] = timestamp
end

function Tracker.GetDeathCount(guid)
    local pd = playerData[guid]
    if not pd then return 0 end
    return pd.deathCount
end

---------------------------------------------------------------------------
-- Combat state management
---------------------------------------------------------------------------
function Tracker.SetCombatStart(timestamp)
    for guid, pd in pairs(playerData) do
        -- Always reset combat timing for fresh pull
        pd.combatStartTime = timestamp
        pd.inCombat = true
        pd.combatEndTime = nil
        pd.effectiveEndTime = nil
    end
end

function Tracker.SetCombatEnd(timestamp)
    for guid, pd in pairs(playerData) do
        pd.inCombat = false
        pd.combatEndTime = timestamp

        -- Trim to last action: use the player's final spell cast as their
        -- effective end-of-combat rather than when WoW dropped the combat
        -- flag. This clips the idle tail where APM/uptime bleed unfairly.
        local eff = pd.lastActionTime
        if eff then
            -- Clamp: can't be before combat start or after actual end
            if pd.combatStartTime and eff < pd.combatStartTime then
                eff = pd.combatStartTime
            end
            if eff > timestamp then
                eff = timestamp
            end
            pd.effectiveEndTime = eff
        else
            -- Player never cast anything — fall back to real end
            pd.effectiveEndTime = timestamp
        end
    end
end

---------------------------------------------------------------------------
-- Query: combat duration for a player
---------------------------------------------------------------------------
function Tracker.GetCombatDuration(guid)
    local pd = playerData[guid]
    if not pd or not pd.combatStartTime then return 0 end
    -- During live combat use real time; after combat, use the effective
    -- end (trimmed to last action) to clip the idle WoW-combat-flag tail.
    local endTime
    if pd.combatEndTime then
        endTime = pd.effectiveEndTime or pd.combatEndTime
    elseif pd.inCombat then
        endTime = GetTime()
    else
        endTime = pd.combatStartTime
    end
    return math.max(endTime - pd.combatStartTime, 0.1)
end

---------------------------------------------------------------------------
-- Query: count actions in the last W seconds
---------------------------------------------------------------------------
function Tracker.CountActionsInWindow(guid, windowSec)
    local pd = playerData[guid]
    if not pd then return 0 end

    local now = GetTime()
    local cutoff = now - windowSec
    local count = 0

    -- Scan the ring buffer
    for i = 1, math.min(pd.actionCount, MAX_TIMESTAMPS) do
        local ts = pd.actionTimestamps[i]
        if ts and ts >= cutoff then
            count = count + 1
        end
    end

    return count
end

---------------------------------------------------------------------------
-- Query: rolling APM for a window
---------------------------------------------------------------------------
function Tracker.GetRollingAPM(guid, windowSec)
    local count = Tracker.CountActionsInWindow(guid, windowSec)
    return count / (windowSec / 60)
end

---------------------------------------------------------------------------
-- Query: intent-based APM (intentional actions / effective duration)
---------------------------------------------------------------------------
function Tracker.GetIntentAPM(guid)
    local pd = playerData[guid]
    if not pd or pd.intentActionCount == 0 then return 0 end
    local duration = Tracker.GetCombatDuration(guid)
    if duration < 1 then return 0 end
    return pd.intentActionCount / (duration / 60)
end

---------------------------------------------------------------------------
-- Query: intent uptime — fraction of combat with intent-action gaps ≤ threshold
---------------------------------------------------------------------------
function Tracker.GetIntentUptimePercent(guid, gapThreshold)
    local pd = playerData[guid]
    if not pd or pd.intentActionCount < 2 then return 0 end

    gapThreshold = gapThreshold or 3.0
    local duration = Tracker.GetCombatDuration(guid)
    if duration <= 0 then return 0 end

    local sorted = _scratchSorted
    local n = 0
    for i = 1, math.min(pd.intentActionCount, MAX_TIMESTAMPS) do
        local ts = pd.intentTimestamps[i]
        if ts then
            n = n + 1
            sorted[n] = ts
        end
    end
    for i = n + 1, #sorted do sorted[i] = nil end
    table.sort(sorted)

    local activeTime = 0
    for i = 2, n do
        local gap = sorted[i] - sorted[i - 1]
        activeTime = activeTime + math.min(gap, gapThreshold)
    end

    return Utils.Clamp((activeTime / duration) * 100, 0, 100)
end

---------------------------------------------------------------------------
-- Query: compute uptime percentage
-- "Active" = fraction of combat time where gap ≤ threshold
---------------------------------------------------------------------------
function Tracker.GetUptimePercent(guid, gapThreshold)
    local pd = playerData[guid]
    if not pd or pd.actionCount < 2 then return 0 end

    gapThreshold = gapThreshold or 2.5
    local duration = Tracker.GetCombatDuration(guid)
    if duration <= 0 then return 0 end

    -- Reuse scratch table to avoid GC pressure
    local sorted = _scratchSorted
    local n = 0
    for i = 1, math.min(pd.actionCount, MAX_TIMESTAMPS) do
        local ts = pd.actionTimestamps[i]
        if ts then
            n = n + 1
            sorted[n] = ts
        end
    end
    -- Clear any stale tail entries from a previous larger call
    for i = n + 1, #sorted do sorted[i] = nil end
    table.sort(sorted)

    local activeTime = 0
    for i = 2, n do
        local gap = sorted[i] - sorted[i - 1]
        activeTime = activeTime + math.min(gap, gapThreshold)
    end

    return Utils.Clamp((activeTime / duration) * 100, 0, 100)
end

---------------------------------------------------------------------------
-- Query: melee swing uptime (returns %, or nil if not melee)
---------------------------------------------------------------------------
function Tracker.GetSwingUptime(guid)
    local pd = playerData[guid]
    if not pd or not pd.hasMeleeSwings or pd.swingCount < 3 then
        return nil  -- not enough data or not melee
    end

    local duration = Tracker.GetCombatDuration(guid)
    if duration <= 0 then return nil end

    -- Reuse scratch tables to avoid GC pressure
    local sorted = _scratchSorted2
    local n = 0
    for i = 1, math.min(pd.swingCount, MAX_SWING_TIMESTAMPS) do
        local ts = pd.swingTimestamps[i]
        if ts then n = n + 1; sorted[n] = ts end
    end
    for i = n + 1, #sorted do sorted[i] = nil end
    table.sort(sorted)

    -- Compute median swing interval (reuse scratch)
    local intervals = _scratchIntervals
    local ic = 0
    for i = 2, n do
        ic = ic + 1
        intervals[ic] = sorted[i] - sorted[i - 1]
    end
    for i = ic + 1, #intervals do intervals[i] = nil end
    if ic == 0 then return nil end

    table.sort(intervals)
    local medianIdx = math.ceil(ic / 2)
    local medianInterval = intervals[medianIdx]

    if medianInterval <= 0 then return nil end

    -- Expected swings vs actual
    local expectedSwings = duration / medianInterval
    local uptime = Utils.Clamp((pd.swingCount / expectedSwings) * 100, 0, 100)
    return uptime
end

---------------------------------------------------------------------------
-- Query: average gap
---------------------------------------------------------------------------
function Tracker.GetAvgGap(guid)
    local pd = playerData[guid]
    if not pd or pd.gapCount == 0 then return 0 end
    return pd.gapSum / pd.gapCount
end

---------------------------------------------------------------------------
-- Query: longest gap
---------------------------------------------------------------------------
function Tracker.GetMaxGap(guid)
    local pd = playerData[guid]
    if not pd then return 0 end
    return pd.maxGap
end

---------------------------------------------------------------------------
-- Query: top N abilities sorted by count
---------------------------------------------------------------------------
function Tracker.GetTopAbilities(guid, n)
    local pd = playerData[guid]
    if not pd then return {} end

    n = n or 10
    local list = {}
    for spellID, data in pairs(pd.abilityMap) do
        list[#list + 1] = {
            spellID = spellID,
            name = data.name,
            count = data.count,
            school = data.school,
        }
    end

    table.sort(list, function(a, b) return a.count > b.count end)

    -- Trim to N
    while #list > n do
        list[#list] = nil
    end

    -- Add percentage
    local total = pd.actionCount
    for _, entry in ipairs(list) do
        entry.percent = total > 0 and (entry.count / total * 100) or 0
    end

    return list
end

---------------------------------------------------------------------------
-- Query: count of "long gaps" exceeding a threshold
---------------------------------------------------------------------------
function Tracker.CountLongGaps(guid, threshold)
    local pd = playerData[guid]
    if not pd or pd.actionCount < 2 then return 0 end

    threshold = threshold or 10

    -- Note: _scratchSorted may already be populated by a prior GetUptimePercent
    -- call in the same refresh cycle with the same data.  We rebuild it here
    -- because the caller order is not guaranteed.
    local sorted = _scratchSorted
    local n = 0
    for i = 1, math.min(pd.actionCount, MAX_TIMESTAMPS) do
        local ts = pd.actionTimestamps[i]
        if ts then n = n + 1; sorted[n] = ts end
    end
    for i = n + 1, #sorted do sorted[i] = nil end
    table.sort(sorted)

    local count = 0
    for i = 2, n do
        if (sorted[i] - sorted[i - 1]) > threshold then
            count = count + 1
        end
    end
    return count
end

---------------------------------------------------------------------------
-- Snapshot: produce a frozen copy of a player's data for segment storage
---------------------------------------------------------------------------
function Tracker.SnapshotPlayer(guid)
    local pd = playerData[guid]
    if not pd then return nil end

    local snapshot = {
        guid = pd.guid,
        name = pd.name,
        class = pd.class,
        realm = pd.realm,
        actionCount = pd.actionCount,
        intentActionCount = pd.intentActionCount,
        swingCount = pd.swingCount,
        maxGap = pd.maxGap,
        maxIntentGap = pd.maxIntentGap,
        avgGap = Tracker.GetAvgGap(guid),
        combatDuration = Tracker.GetCombatDuration(guid),
        rawUptime = Tracker.GetUptimePercent(guid),
        intentUptime = Tracker.GetIntentUptimePercent(guid),
        swingUptime = Tracker.GetSwingUptime(guid),
        hasMeleeSwings = pd.hasMeleeSwings,
        topAbilities = Tracker.GetTopAbilities(guid, 10),
        role = Utils.GetRoleByGUID(guid),
        deathCount = pd.deathCount or 0,
        -- v2: archetype + expected APM (for historical tooltip)
        archetype = PC.Scoring and PC.Scoring.GetArchetype and PC.Scoring.GetArchetype(guid) or nil,
        expectedAPM = PC.Scoring and PC.Scoring.GetExpectedAPM and PC.Scoring.GetExpectedAPM(guid) or nil,
        -- Utility: spell categories tracked from USCS + SpellDB
        externals = pd.externalCount or 0,
        raidCds = pd.raidCdCount or 0,
        support = pd.supportCount or 0,
        cc = pd.ccCount or 0,
        -- Arena: tag enemy players so UI/QR can distinguish teams
        isEnemy = pd.isEnemy or nil,
    }

    -- Always use intent uptime (deduped).  Raw uptime kept in snapshot
    -- as rawUptime for debug / tooltip display only.
    snapshot.uptime = snapshot.intentUptime

    -- Compute APM (intent-based only; raw fallback removed to prevent
    -- inflated display from unfiltered UNIT_SPELLCAST_SUCCEEDED events)
    if snapshot.combatDuration > 0 then
        snapshot.apm = pd.intentActionCount / (snapshot.combatDuration / 60)
        snapshot.rawApm = pd.actionCount / (snapshot.combatDuration / 60)
    else
        snapshot.apm = 0
        snapshot.rawApm = 0
    end

    return snapshot
end

---------------------------------------------------------------------------
-- Snapshot all players
---------------------------------------------------------------------------
function Tracker.SnapshotAll()
    local snapshots = {}
    for guid, _ in pairs(playerData) do
        snapshots[guid] = Tracker.SnapshotPlayer(guid)
    end
    return snapshots
end

---------------------------------------------------------------------------
-- Reset
---------------------------------------------------------------------------
function Tracker.ResetPlayer(guid)
    playerData[guid] = nil
end

function Tracker.ResetAll()
    Utils.WipeTable(playerData)
end

PC.Tracker = Tracker

--[[
    Cadence - Scoring.lua  (v3)
    Negative-exponential APM mapping, intent uptime.

    Engagement Formula (v3 — simplified, no triple-dipping):
        APMScore    = 100 * (1 - exp(-k * ratio))       k=1.6
        UptimeScore = intent uptime % (gap thresh 2.5s)
        Final       = 0.55 * APMScore + 0.45 * UptimeScore

    Cadence Score components (group-relative, negative-exponential curves):
        Output     = 100*(1-exp(-1.2 * dps/avgDps))     avg=~70
        Utility    = interrupts + dispels + externals    (neg-exp curve)
        Avoidable  = 100*exp(-0.36 * avoid/avgAvoid)    (<2% of total = 100)
        Deaths     = 100 - deaths*25                     (only place deaths scored)
        Engagement = activity score (APM + uptime only)
]]

local ADDON_NAME, PC = ...

PC.Scoring = {}
local Scoring = PC.Scoring
local Tracker = PC.Tracker
local Utils = PC.Utils

---------------------------------------------------------------------------
-- Algorithm constants (read from saved vars with fallbacks)
---------------------------------------------------------------------------
local ALGO_DEFAULTS = {
    curveK        = 1.6,    -- negative-exponential steepness
    dedupWindow   = 0.40,   -- 400ms per-unit dedup (Events.lua reads this)
    bucketSize    = 10,     -- consistency CV bucket width (seconds)
    uptimeGapMax  = 2.5,    -- max gap to count as "active" for uptime
    gapPenThresh  = 8.0,    -- gaps longer than this incur penalty
    gapPenPerSec  = 0.6,    -- penalty points per excess second
    gapPenCap     = 30,     -- maximum gap penalty
}

local WEIGHT_DEFAULTS = {
    apmWeight     = 0.55,
    uptimeWeight  = 0.45,
}

local function GetAlgo()
    -- Locked to defaults: scoring inputs must be identical across all reporters
    -- so the network-visible score derived from a kill is reproducible.
    return ALGO_DEFAULTS
end

local function GetWeights()
    -- Locked to defaults (see GetAlgo).
    return WEIGHT_DEFAULTS
end

---------------------------------------------------------------------------
-- Archetype detection: Role + Class melee heuristic
-- For ambiguous DPS classes (Druid, Shaman, Evoker), check swing events.
---------------------------------------------------------------------------
local AMBIGUOUS_DPS_CLASSES = {
    DRUID   = true,
    SHAMAN  = true,
    EVOKER  = true,
}

function Scoring.GetArchetype(guid)
    local role  = Utils.GetRoleByGUID(guid)
    local class = Utils.GetClassByGUID(guid)

    if role == "TANK"   then return "TANK" end
    if role == "HEALER" then return "HEALER" end

    -- DPS: determine melee vs ranged
    if AMBIGUOUS_DPS_CLASSES[class] then
        local pd = Tracker.GetPlayerData(guid)
        if pd and pd.hasMeleeSwings then
            return "DPS_MELEE"
        end
        return "DPS_RANGED"  -- conservative default
    end

    if PC.MELEE_CLASSES[class] then
        return "DPS_MELEE"
    end
    return "DPS_RANGED"
end

---------------------------------------------------------------------------
-- Get the expected iAPM for a player based on archetype
---------------------------------------------------------------------------
function Scoring.GetExpectedAPM(guid)
    local archetype = Scoring.GetArchetype(guid)

    -- Locked to PC.ROLE_EXPECTED_APM (defaults). SavedVariables overrides are
    -- intentionally ignored so all reporters compute APM ratios identically.
    local roleAPM = PC.ROLE_EXPECTED_APM

    if archetype == "TANK"       then return roleAPM.TANK           or 30 end
    if archetype == "HEALER"     then return roleAPM.HEALER         or 24 end
    if archetype == "DPS_MELEE"  then return roleAPM.DAMAGER_MELEE  or 34 end
    return roleAPM.DAMAGER_RANGED or 26
end

---------------------------------------------------------------------------
-- Helper: get effective action count and timestamps for scoring.
-- Always uses intent (deduped) data.  Raw actionCount is kept for
-- ability breakdown / debug only — it includes passive procs, multi-hit
-- spam, and other UNIT_SPELLCAST_SUCCEEDED noise that inflates APM.
---------------------------------------------------------------------------
local function GetEffectiveCounts(pd)
    return pd.intentActionCount, pd.intentTimestamps, pd.intentWriteIdx
end

---------------------------------------------------------------------------
-- APM Score (0–100): negative exponential of iAPM / expected
--   f(ratio) = 100 * (1 - e^(-k * ratio))
--   ratio=1.0 → 80   (at k=1.6)
--   ratio=1.5 → 91
--   ratio=2.0 → 96
---------------------------------------------------------------------------
function Scoring.CalcAPMScore(guid)
    local pd = Tracker.GetPlayerData(guid)
    if not pd then return 0 end

    local duration = Tracker.GetCombatDuration(guid)
    if duration < 5 then return 0 end

    local count = GetEffectiveCounts(pd)
    local iAPM = count / (duration / 60)
    local expected = Scoring.GetExpectedAPM(guid)
    if expected <= 0 then return 0 end

    local ratio = iAPM / expected
    local algo = GetAlgo()
    local k = algo.curveK or 1.6

    return Utils.Clamp(100 * (1 - math.exp(-k * ratio)), 0, 100)
end

---------------------------------------------------------------------------
-- Uptime Score (0–100): fraction of fight with intent-action gaps ≤ threshold
---------------------------------------------------------------------------
function Scoring.CalcUptimeScore(guid)
    local pd = Tracker.GetPlayerData(guid)
    if not pd then return 0 end

    local count = GetEffectiveCounts(pd)
    if count < 2 then return 0 end

    local duration = Tracker.GetCombatDuration(guid)
    if duration <= 0 then return 0 end

    local algo = GetAlgo()
    local gapThreshold = algo.uptimeGapMax or 2.5

    return Tracker.GetIntentUptimePercent(guid, gapThreshold)
end

---------------------------------------------------------------------------
-- Composite Activity Score (0–100) — THE public score
--
-- BaseScore = apmWeight * APMScore + uptimeWeight * UptimeScore
-- Final     = clamp(Base - GapPenalty + ConsistencyMod - DeathPen, 0, 100)
---------------------------------------------------------------------------
function Scoring.CalcCompositeScore(guid)
    local w = GetWeights()

    local apmScore    = Scoring.CalcAPMScore(guid)
    local uptimeScore = Scoring.CalcUptimeScore(guid)

    local baseScore = apmScore    * (w.apmWeight    or 0.55)
                    + uptimeScore * (w.uptimeWeight  or 0.45)

    -- v3: Engagement is purely APM + Uptime.
    -- Death penalty lives in the Cadence score's deaths component.
    -- Gap penalty and consistency mod removed — they triple-dipped with
    -- uptime, causing unfair point loss for any downtime.
    return Utils.Clamp(math.floor(baseScore), 0, 100)
end

---------------------------------------------------------------------------
-- Composite score from a pre-built snapshot table (used by M+ aggregation)
-- Works from already-computed fields (apm, uptime, deathCount) rather than
-- live Tracker data, so it can score merged cross-pull snapshots.
---------------------------------------------------------------------------
function Scoring.CalcCompositeScoreFromSnapshot(snap)
    if not snap or not snap.combatDuration or snap.combatDuration <= 0 then return 0 end

    local w = GetWeights()
    local algo = GetAlgo()

    -- APM score: same negative-exponential as CalcAPMScore
    local apm = snap.apm or 0
    -- Locked to PC.ROLE_EXPECTED_APM defaults (same reasoning as GetExpectedAPM).
    local roleAPM = PC.ROLE_EXPECTED_APM or {}
    local role = snap.role or "DAMAGER"
    local expected
    if role == "TANK" then
        expected = roleAPM.TANK or 30
    elseif role == "HEALER" then
        expected = roleAPM.HEALER or 24
    elseif snap.hasMeleeSwings then
        expected = roleAPM.DAMAGER_MELEE or 34
    else
        expected = roleAPM.DAMAGER_RANGED or 26
    end
    local ratio = (expected > 0) and (apm / expected) or 0
    local k = algo.curveK or 1.6
    local apmScore = Utils.Clamp(100 * (1 - math.exp(-k * ratio)), 0, 100)

    -- Uptime score: use the aggregated uptime directly
    local uptimeScore = Utils.Clamp(snap.uptime or 0, 0, 100)

    local baseScore = apmScore * (w.apmWeight or 0.55)
                    + uptimeScore * (w.uptimeWeight or 0.45)

    -- v3: No death penalty in engagement — handled by Cadence deaths component
    return Utils.Clamp(math.floor(baseScore), 0, 100)
end

---------------------------------------------------------------------------
-- AFK Suspicion Score (0–100) — kept for debug/tooltip
---------------------------------------------------------------------------
-- AFK flag: true if the player had any gap >= 20 seconds with zero actions.
-- This is a binary flag, not a score.  Long-gap penalties are already baked
-- into the engagement / activity scoring path.
local AFK_GAP_THRESHOLD = 20

function Scoring.IsAFK(guid)
    local pd = Tracker.GetPlayerData(guid)
    if not pd then return false end
    local maxGap = pd.maxIntentGap or pd.maxGap or 0
    return maxGap >= AFK_GAP_THRESHOLD
end

---------------------------------------------------------------------------
-- Burst vs Sustain ratio (kept for tooltip)
---------------------------------------------------------------------------
local _burstSorted = {}
local _burstBuckets = {}

function Scoring.CalcBurstSustain(guid)
    local pd = Tracker.GetPlayerData(guid)
    if not pd then return 0, 0, 1.0 end

    local count, timestamps = GetEffectiveCounts(pd)
    if count < 5 then return 0, 0, 1.0 end

    local duration = Tracker.GetCombatDuration(guid)
    if duration < 10 then return 0, 0, 1.0 end

    local sorted = _burstSorted
    local n = 0
    local maxTS = math.min(count, 1200)
    for i = 1, maxTS do
        local ts = timestamps[i]
        if ts then n = n + 1; sorted[n] = ts end
    end
    for i = n + 1, #sorted do sorted[i] = nil end
    if n < 5 then return 0, 0, 1.0 end
    table.sort(sorted)

    local bucketSize = 10
    local startTime = pd.combatStartTime or sorted[1]
    local numBuckets = math.ceil(duration / bucketSize)
    if numBuckets < 1 then return 0, 0, 1.0 end

    local buckets = _burstBuckets
    for i = 1, numBuckets do buckets[i] = 0 end
    for i = numBuckets + 1, #buckets do buckets[i] = nil end

    for j = 1, n do
        local idx = math.floor((sorted[j] - startTime) / bucketSize) + 1
        if idx >= 1 and idx <= numBuckets then
            buckets[idx] = buckets[idx] + 1
        end
    end

    local maxAPM = 0
    local sumAPM = 0
    for i = 1, numBuckets do
        local bAPM = buckets[i] * (60 / bucketSize)
        if bAPM > maxAPM then maxAPM = bAPM end
        sumAPM = sumAPM + bAPM
    end

    local avgAPM = sumAPM / numBuckets
    local ratio = avgAPM > 0 and (maxAPM / avgAPM) or 1.0

    return maxAPM, avgAPM, ratio
end

---------------------------------------------------------------------------
-- Full score report for a player (used by tooltip — debug instrumentation)
---------------------------------------------------------------------------
function Scoring.GetFullReport(guid)
    local pd = Tracker.GetPlayerData(guid)
    if not pd then return nil end

    local duration = Tracker.GetCombatDuration(guid)
    local count = GetEffectiveCounts(pd)
    local effectiveAPM = duration > 0 and (count / (duration / 60)) or 0
    local rawAPM = duration > 0 and (pd.actionCount / (duration / 60)) or 0

    local burstAPM, sustainAPM, burstRatio = Scoring.CalcBurstSustain(guid)

    -- Component scores for full debug breakdown
    local apmScore       = Scoring.CalcAPMScore(guid)
    local uptimeScore    = Scoring.CalcUptimeScore(guid)
    local w = GetWeights()
    local baseScore      = apmScore * (w.apmWeight or 0.55)
                         + uptimeScore * (w.uptimeWeight or 0.45)

    -- Compute cadenceScore from live meter data if available
    local MeterData = PC.MeterData
    local liveCadence = nil
    -- Determine context once so we can route engagement to the right composite
    local isArenaLive = PC.Events and PC.Events.IsInArena and PC.Events.IsInArena()
    local function liveEngagement(g)
        if isArenaLive and Scoring.CalcPvPCompositeScore then
            return Scoring.CalcPvPCompositeScore(g)
        end
        return Scoring.CalcCompositeScore(g)
    end
    if MeterData and MeterData.GetLiveMeterData then
        local liveMeter = MeterData.GetLiveMeterData()
        if liveMeter and liveMeter[guid] then
            -- Build a snap-like table for CalcCadenceLiveScore
            local lm = liveMeter[guid]
            local snapForCadence = {
                dps = lm.dps or 0,
                hps = lm.hps or 0,
                damageDone = lm.damageDone or 0,
                healingDone = lm.healingDone or 0,
                interrupts = lm.interrupts or 0,
                dispels = lm.dispels or 0,
                externals = pd.externalCount or 0,
                raidCds = pd.raidCdCount or 0,
                support = pd.supportCount or 0,
                cc = pd.ccCount or 0,
                avoidableDamage = lm.avoidableDamage or 0,
                deathCount = Tracker.GetDeathCount(guid),
                activityScore = liveEngagement(guid),
                role = Utils.GetRoleByGUID(guid) or "DAMAGER",
                isEnemy = false,
            }
            -- Build allSnaps from all tracked players
            local allSnaps = {}
            for g, pd in pairs(Tracker.GetAllPlayerData()) do
                local m = liveMeter[g]
                if m then
                    allSnaps[g] = {
                        dps = m.dps or 0, hps = m.hps or 0,
                        damageDone = m.damageDone or 0, healingDone = m.healingDone or 0,
                        interrupts = m.interrupts or 0, dispels = m.dispels or 0,
                        externals = pd.externalCount or 0,
                        raidCds = pd.raidCdCount or 0,
                        support = pd.supportCount or 0,
                        cc = pd.ccCount or 0,
                        avoidableDamage = m.avoidableDamage or 0,
                        deathCount = Tracker.GetDeathCount(g),
                        activityScore = liveEngagement(g),
                        role = Utils.GetRoleByGUID(g) or "DAMAGER",
                        isEnemy = pd.isEnemy or false,
                    }
                end
            end
            local isPvPCheck = isArenaLive
            local ct = isPvPCheck and "arena"
                or (PC.Segments and PC.Segments.IsInMythicPlus() and "mythicplus")
                or "raid"
            local liveCtx = (PC.Segments and PC.Segments.GetCurrentScoreContext)
                and PC.Segments.GetCurrentScoreContext() or nil
            liveCadence = Scoring.CalcCadenceLiveScore(snapForCadence, allSnaps, ct, liveCtx)
        end
    end

    return {
        -- Final composite
        activityScore     = Scoring.CalcCompositeScore(guid),
        cadenceScore      = liveCadence,
        afkFlag           = Scoring.IsAFK(guid),

        -- Raw metrics
        apm               = effectiveAPM,
        rawApm            = rawAPM,
        actionCount       = pd.actionCount,
        intentActionCount = pd.intentActionCount,
        combatDuration    = duration,
        avgGap            = Tracker.GetAvgGap(guid),
        maxGap            = Tracker.GetMaxGap(guid),
        uptime            = uptimeScore,
        swingUptime       = Tracker.GetSwingUptime(guid),
        hasMeleeSwings    = pd.hasMeleeSwings,
        swingCount        = pd.swingCount,
        archetype         = Scoring.GetArchetype(guid),
        expectedAPM       = Scoring.GetExpectedAPM(guid),

        -- Rolling APM
        rolling10         = Tracker.GetRollingAPM(guid, 10),
        rolling30         = Tracker.GetRollingAPM(guid, 30),
        rolling60         = Tracker.GetRollingAPM(guid, 60),
        rolling180        = Tracker.GetRollingAPM(guid, 180),

        -- Burst / sustain
        burstAPM          = burstAPM,
        sustainAPM        = sustainAPM,
        burstRatio        = burstRatio,
        longGaps          = Tracker.CountLongGaps(guid),
        topAbilities      = Tracker.GetTopAbilities(guid, 8),
        deathCount        = Tracker.GetDeathCount(guid),

        -- v3 score breakdown (debug instrumentation)
        _apmScore         = apmScore,
        _uptimeScore      = uptimeScore,
        _baseScore        = baseScore,
    }
end

---------------------------------------------------------------------------
-- PvP (Arena / Solo Shuffle) scoring
--
-- Arena is fundamentally different from PvE:
--   • Players get CC'd, slowed, and crowd-controlled — gap penalty is unfair
--   • Fights are inherently bursty (go/stop/CC/burst) — consistency mod is misleading
--   • Deaths are expected and don't mean "AFK" — reduced death penalty
--   • Uptime against CC is a key skill signal — uptime weight is higher
--   • APM while active still matters — keeps APM component
--
-- PvP Formula:
--   APMScore    = same negative-exponential curve as PvE
--   UptimeScore = same intent-gap based uptime, but with relaxed gap threshold
--   BaseScore   = 0.50 * APMScore + 0.50 * UptimeScore
--   (Death penalty removed from engagement — handled by Cadence deaths component)
--
-- No gap penalty (CC/slows are external forces).
-- No consistency modifier (burst windows are strategic, not lazy).
---------------------------------------------------------------------------

function Scoring.CalcPvPUptimeScore(guid)
    local pd = Tracker.GetPlayerData(guid)
    if not pd then return 0 end

    local count = GetEffectiveCounts(pd)
    if count < 2 then return 0 end

    local duration = Tracker.GetCombatDuration(guid)
    if duration <= 0 then return 0 end

    -- Relaxed gap threshold for PvP: 4s (vs 2.5s PvE) because
    -- players may be CC'd, kiting, or LoS'ing for several seconds
    return Tracker.GetIntentUptimePercent(guid, 4.0)
end

function Scoring.CalcPvPCompositeScore(guid)
    local apmScore    = Scoring.CalcAPMScore(guid)
    local uptimeScore = Scoring.CalcPvPUptimeScore(guid)

    local baseScore = apmScore * 0.50 + uptimeScore * 0.50

    -- v3: No death penalty in engagement — handled by Cadence deaths component
    return Utils.Clamp(math.floor(baseScore), 0, 100)
end

---------------------------------------------------------------------------
-- PvP full score report (used by tooltip — debug instrumentation)
---------------------------------------------------------------------------
function Scoring.GetPvPFullReport(guid)
    local pd = Tracker.GetPlayerData(guid)
    if not pd then return nil end

    local duration = Tracker.GetCombatDuration(guid)
    local count = GetEffectiveCounts(pd)
    local effectiveAPM = duration > 0 and (count / (duration / 60)) or 0
    local rawAPM = duration > 0 and (pd.actionCount / (duration / 60)) or 0

    local burstAPM, sustainAPM, burstRatio = Scoring.CalcBurstSustain(guid)

    local apmScore       = Scoring.CalcAPMScore(guid)
    local uptimeScore    = Scoring.CalcPvPUptimeScore(guid)
    local baseScore      = apmScore * 0.50 + uptimeScore * 0.50

    return {
        activityScore     = Scoring.CalcPvPCompositeScore(guid),
        afkFlag           = Scoring.IsAFK(guid),

        apm               = effectiveAPM,
        rawApm            = rawAPM,
        actionCount       = pd.actionCount,
        intentActionCount = pd.intentActionCount,
        combatDuration    = duration,
        avgGap            = Tracker.GetAvgGap(guid),
        maxGap            = Tracker.GetMaxGap(guid),
        uptime            = uptimeScore,
        swingUptime       = Tracker.GetSwingUptime(guid),
        hasMeleeSwings    = pd.hasMeleeSwings,
        swingCount        = pd.swingCount,
        archetype         = Scoring.GetArchetype(guid),
        expectedAPM       = Scoring.GetExpectedAPM(guid),

        rolling10         = Tracker.GetRollingAPM(guid, 10),
        rolling30         = Tracker.GetRollingAPM(guid, 30),
        rolling60         = Tracker.GetRollingAPM(guid, 60),
        rolling180        = Tracker.GetRollingAPM(guid, 180),

        burstAPM          = burstAPM,
        sustainAPM        = sustainAPM,
        burstRatio        = burstRatio,
        longGaps          = Tracker.CountLongGaps(guid),
        topAbilities      = Tracker.GetTopAbilities(guid, 8),
        deathCount        = Tracker.GetDeathCount(guid),

        -- PvP score breakdown
        _apmScore         = apmScore,
        _uptimeScore      = uptimeScore,
        _baseScore        = baseScore,
        _isPvP            = true,
    }
end

---------------------------------------------------------------------------
-- Cadence Live Score (0–100): group-relative composite
--
-- Combines throughput output (DPS/HPS), utility, avoidable damage,
-- death penalty, and engagement (activity score) into one number.
--
-- M+ weights:  Output 55%, Utility 10%, Avoidable 10%, Deaths 10%, Engagement 15%
-- Raid weights: Output 80%, Utility 0%, Avoidable 5%, Deaths 5%, Engagement 10%
--
-- Each component is normalized relative to the group average.
-- Falls back to engagement-only when no meter data is available.
---------------------------------------------------------------------------
-- Base weights per content type (before context-aware activation).
-- Inactive metrics have their weight redistributed proportionally to active ones.
local CADENCE_WEIGHTS = {
    mythicplus = { output = 0.45, utility = 0.15, avoidable = 0.15, deaths = 0.10, engagement = 0.15 },
    raid       = { output = 0.65, utility = 0.05, avoidable = 0.10, deaths = 0.10, engagement = 0.10 },
    arena      = { output = 0.50, utility = 0.15, avoidable = 0.10, deaths = 0.10, engagement = 0.15 },
}

-- Activation thresholds — minimum group totals for a metric to be scored
local ACTIVATION = {
    utilityInterrupts = 3,  -- total group interrupts for utility to be active
    utilityDispels    = 2,  -- total group dispels for utility to be active
}

---------------------------------------------------------------------------
-- Difficulty-aware utility tier.
--   strict  → utility is ALWAYS active. Skipping interrupts/dispels in
--             a +12 or Mythic raid or arena should hurt your score.
--   medium  → current behavior: active iff group used some utility.
--   lenient → utility is NEVER active. LFR / Normal / world content has
--             no expectation of utility usage; weight is redistributed.
-- Raid difficultyIDs: 17=LFR, 14=Normal, 15=Heroic, 16=Mythic
--                     7=LegacyLFR, 33=Timewalking, 23=MythicDungeon (5-man)
---------------------------------------------------------------------------
-- Normal (14) is MEDIUM, not lenient: if the group bothered to use
-- externals/CDs/interrupts, we should reward it. Lenient = LFR / Legacy
-- LFR / Timewalking where utility is genuinely not expected.
local LENIENT_RAID_DIFF = { [7]=true, [17]=true, [33]=true }
local MEDIUM_RAID_DIFF  = { [14]=true, [15]=true }
local STRICT_RAID_DIFF  = { [16]=true }

local function ResolveUtilityTier(contentType, ctx)
    if contentType == "arena" then return "strict" end

    if contentType == "mythicplus" then
        local k = ctx and ctx.keystoneLevel or 0
        if k >= 10 then return "strict" end
        if k >= 2  then return "medium" end
        return "lenient" -- normal/heroic 5-man, world dungeons
    end

    if contentType == "raid" then
        local d = ctx and ctx.difficultyID or 0
        if STRICT_RAID_DIFF[d]  then return "strict"  end
        if MEDIUM_RAID_DIFF[d]  then return "medium"  end
        if LENIENT_RAID_DIFF[d] then return "lenient" end
        return "medium" -- unknown raid difficulty: default to current behavior
    end

    return "medium"
end

---------------------------------------------------------------------------
-- Compute group-level stats from allPlayers table.
-- Returns a stats table used by both CalcCadenceLiveScore and Breakdown.
---------------------------------------------------------------------------
local function ComputeGroupStats(allPlayers)
    local groupDps, groupHps, groupUtility, groupAvoid = 0, 0, 0, 0
    local groupInterrupts, groupDispels, groupExternals = 0, 0, 0
    local groupRaidCds, groupSupport, groupCC = 0, 0, 0
    local groupAvoidTotal = 0
    local groupUtilityTotal = 0  -- all utility actions combined
    local dpsCount, hpsCount, count = 0, 0, 0

    if allPlayers then
        for _, p in pairs(allPlayers) do
            if not p.isEnemy then
                count = count + 1
                local pDps = p.dps or 0
                local pHps = p.hps or 0
                local role = p.role
                -- Healing/damage averages must be computed against players in
                -- that role, not anyone whose meter is non-zero. Otherwise
                -- passive sources (leech, atonement, healthstones, vampiric
                -- embrace, ret WoG, etc.) drag avgHps down by 3-5x and DPS
                -- output from healers (atonement, holy fire) drags avgDps
                -- down — both inflate ratios so everyone saturates the curve.
                --
                -- Hybrid healing tanks (Blood DK, Brewmaster) generate real
                -- HPS via Death Strike / Stagger, but it's self-healing only
                -- and not what we mean by "group healer throughput". Keep
                -- them out of avgHps.
                if role == "DAMAGER" and pDps > 0 then
                    dpsCount = dpsCount + 1
                    groupDps = groupDps + pDps
                end
                if role == "HEALER" and pHps > 0 then
                    hpsCount = hpsCount + 1
                    groupHps = groupHps + pHps
                end
                local pInt = p.interrupts or 0
                local pDisp = p.dispels or 0
                local pExt = p.externals or 0
                local pRaidCd = p.raidCds or 0
                local pSupport = p.support or 0
                local pCC = p.cc or 0
                groupInterrupts = groupInterrupts + pInt
                groupDispels = groupDispels + pDisp
                groupExternals = groupExternals + pExt
                groupRaidCds = groupRaidCds + pRaidCd
                groupSupport = groupSupport + pSupport
                groupCC = groupCC + pCC
                groupUtility = groupUtility + pInt + pDisp
                groupUtilityTotal = groupUtilityTotal + pInt + pDisp + pExt + pRaidCd + pSupport + pCC
                local pAvoid = p.avoidableDamage or 0
                groupAvoid = groupAvoid + pAvoid
                groupAvoidTotal = groupAvoidTotal + pAvoid
            end
        end
    end

    if count <= 0 then count = 1 end

    return {
        avgDps = dpsCount > 0 and (groupDps / dpsCount) or 1,
        avgHps = hpsCount > 0 and (groupHps / hpsCount) or 1,
        avgUtility = groupUtility / count,
        avgAvoid = groupAvoid / count,
        groupInterrupts = groupInterrupts,
        groupDispels = groupDispels,
        groupExternals = groupExternals,
        groupRaidCds = groupRaidCds,
        groupSupport = groupSupport,
        groupCC = groupCC,
        groupAvoidTotal = groupAvoidTotal,
        groupUtilityTotal = groupUtilityTotal,
        count = count,
    }
end

---------------------------------------------------------------------------
-- Determine which metrics are active for this segment.
-- Returns a table of booleans: { utility = bool, avoidable = bool }
-- Output, deaths, and engagement are ALWAYS active.
---------------------------------------------------------------------------
local function GetActiveMetrics(gs, utilityTier)
    local utilityActive
    if utilityTier == "strict" then
        utilityActive = true
    elseif utilityTier == "lenient" then
        utilityActive = false
    else
        utilityActive = (gs.groupInterrupts >= ACTIVATION.utilityInterrupts)
                     or (gs.groupDispels >= ACTIVATION.utilityDispels)
                     or (gs.groupExternals or 0) >= 1
                     or (gs.groupRaidCds or 0) >= 1
                     or (gs.groupSupport or 0) >= 1
                     or (gs.groupCC or 0) >= 1
    end
    return {
        utility   = utilityActive,
        avoidable = gs.groupAvoidTotal > 0,
    }
end

---------------------------------------------------------------------------
-- Build effective weights: remove inactive metrics and redistribute
-- their weight proportionally among active ones.
---------------------------------------------------------------------------
local function BuildEffectiveWeights(baseWeights, active)
    local ew = {
        output     = baseWeights.output,
        utility    = active.utility and baseWeights.utility or 0,
        avoidable  = active.avoidable and baseWeights.avoidable or 0,
        deaths     = baseWeights.deaths,
        engagement = baseWeights.engagement,
    }

    local total = ew.output + ew.utility + ew.avoidable + ew.deaths + ew.engagement
    if total <= 0 then total = 1 end

    -- Normalize so weights sum to 1.0
    ew.output     = ew.output / total
    ew.utility    = ew.utility / total
    ew.avoidable  = ew.avoidable / total
    ew.deaths     = ew.deaths / total
    ew.engagement = ew.engagement / total

    return ew
end

---------------------------------------------------------------------------
-- Compute raw component scores for a single player snapshot.
--
-- v3 changes:
--   • Output uses negative-exponential curve: avg = ~70, not 50.
--   • Utility counts ALL group contributions: interrupts, dispels,
--     externals, raid CDs, support spells, and CC (via SpellDB).
--   • Avoidable has a negligible-damage floor (<2% of group total = 100).
--   • Deaths: 100 - deaths*25 (only scored here, NOT in engagement).
---------------------------------------------------------------------------
local function ComputeComponentScores(snap, gs)
    local role = snap.role or "DAMAGER"

    -- 1. Output (negative-exponential: avg ratio=1.0 → ~85, 1.5x → ~94, 2x → ~98)
    --    f(ratio) = 100 * (1 - e^(-1.9 * ratio))
    --    Keeping up with the group means a B+ output sub-score; only meaningful
    --    underperformers (<0.75x avg) drop into "needs work" territory.
    local outputScore
    if role == "HEALER" then
        local hps = snap.hps or 0
        local ratio = gs.avgHps > 0 and (hps / gs.avgHps) or 1
        outputScore = Utils.Clamp(100 * (1 - math.exp(-1.9 * ratio)), 0, 100)
    else
        local dps = snap.dps or 0
        local ratio = gs.avgDps > 0 and (dps / gs.avgDps) or 1
        outputScore = Utils.Clamp(100 * (1 - math.exp(-1.9 * ratio)), 0, 100)
    end

    -- 2. Utility (interrupts + dispels + externals + raidCds + support + CC)
    -- All roles can contribute: DPS/tanks via kicks+dispels+CC, healers via
    -- externals and raid CDs, everyone via support spells (PI, Freedom, etc.).
    local myUtility = (snap.interrupts or 0) + (snap.dispels or 0)
                    + (snap.externals or 0) + (snap.raidCds or 0)
                    + (snap.support or 0) + (snap.cc or 0)
    local avgUtilityAll = gs.groupUtilityTotal / gs.count
    local utilityScore
    if avgUtilityAll > 0 then
        local ratio = myUtility / avgUtilityAll
        utilityScore = Utils.Clamp(100 * (1 - math.exp(-1.2 * ratio)), 0, 100)
    else
        utilityScore = myUtility > 0 and 100 or 50
    end

    -- 3. Avoidable damage (lower is better — inverted; tanks exempt)
    -- Negligible floor: if player's avoidable is <2% of group total, score = 100
    local myAvoid = snap.avoidableDamage or 0
    local avoidScore
    if role == "TANK" then
        avoidScore = 100
    elseif gs.groupAvoidTotal > 0 and myAvoid / gs.groupAvoidTotal < 0.02 then
        avoidScore = 100  -- negligible
    elseif gs.avgAvoid > 0 then
        -- Exponential: 0 damage = 100, avg damage = ~70, 2x avg = ~41
        local ratio = myAvoid / gs.avgAvoid
        avoidScore = Utils.Clamp(100 * math.exp(-0.36 * ratio), 0, 100)
    else
        avoidScore = myAvoid > 0 and 0 or 100
    end

    -- 4. Deaths (hard penalty per death — only place deaths are scored)
    local deaths = snap.deathCount or 0
    local deathScore = Utils.Clamp(100 - deaths * 25, 0, 100)

    -- 5. Engagement (existing activity score — now clean: APM + uptime only)
    local engagementScore = snap.activityScore or 50

    return outputScore, utilityScore, avoidScore, deathScore, engagementScore
end

function Scoring.CalcCadenceLiveScore(snap, allPlayers, contentType, context)
    if not snap then return 0 end

    contentType = contentType or "mythicplus"
    local baseW = CADENCE_WEIGHTS[contentType] or CADENCE_WEIGHTS.mythicplus

    -- Check if meter data is available for this player
    local hasMeterData = (snap.damageDone or 0) > 0 or (snap.healingDone or 0) > 0

    if not hasMeterData then
        return snap.activityScore or 50
    end

    -- Group stats + activation + effective weights
    local gs = ComputeGroupStats(allPlayers)
    local utilityTier = ResolveUtilityTier(contentType, context)
    local active = GetActiveMetrics(gs, utilityTier)
    local w = BuildEffectiveWeights(baseW, active)

    -- Component scores
    local outputScore, utilityScore, avoidScore, deathScore, engagementScore =
        ComputeComponentScores(snap, gs)

    -- Weighted sum (inactive metrics have weight 0, so they contribute nothing)
    local final = outputScore * w.output
                + utilityScore * w.utility
                + avoidScore * w.avoidable
                + deathScore * w.deaths
                + engagementScore * w.engagement

    return Utils.Clamp(math.floor(final), 0, 100)
end

---------------------------------------------------------------------------
-- Cadence Score Breakdown — returns per-component scores + weighted sums
-- Used by UI_Summary ("why you lost points") and UI_Tooltip (live hover).
-- Returns a table with raw component scores, weighted contributions,
-- and the points lost from each component vs a perfect 100.
---------------------------------------------------------------------------
function Scoring.CalcCadenceBreakdown(snap, allPlayers, contentType, context)
    if not snap then return nil end

    contentType = contentType or "mythicplus"
    local baseW = CADENCE_WEIGHTS[contentType] or CADENCE_WEIGHTS.mythicplus

    local hasMeterData = (snap.damageDone or 0) > 0 or (snap.healingDone or 0) > 0

    if not hasMeterData then
        local engScore = snap.activityScore or 50
        return {
            hasMeterData = false,
            cadenceScore = engScore,
            contentType = contentType,
            engagement = { raw = engScore, weighted = engScore, lost = 100 - engScore, weight = 1.0, active = true },
        }
    end

    -- Group stats + activation + effective weights
    local gs = ComputeGroupStats(allPlayers)
    local utilityTier = ResolveUtilityTier(contentType, context)
    local active = GetActiveMetrics(gs, utilityTier)
    local w = BuildEffectiveWeights(baseW, active)

    local role = snap.role or "DAMAGER"

    -- Component scores (reuse shared logic)
    local outputScore, utilityScore, avoidScore, deathScore, engagementScore =
        ComputeComponentScores(snap, gs)

    -- Weighted contributions
    local outputWeighted     = outputScore * w.output
    local utilityWeighted    = utilityScore * w.utility
    local avoidWeighted      = avoidScore * w.avoidable
    local deathWeighted      = deathScore * w.deaths
    local engagementWeighted = engagementScore * w.engagement

    local final = Utils.Clamp(math.floor(
        outputWeighted + utilityWeighted + avoidWeighted + deathWeighted + engagementWeighted
    ), 0, 100)

    -- Lost = max possible weighted contribution - actual
    return {
        hasMeterData = true,
        cadenceScore = final,
        contentType = contentType,
        output = {
            raw = outputScore,
            weighted = outputWeighted,
            lost = (100 * w.output) - outputWeighted,
            weight = w.output,
            label = role == "HEALER" and "HPS" or "DPS",
            active = true,
        },
        utility = {
            raw = utilityScore,
            weighted = utilityWeighted,
            lost = active.utility and ((100 * w.utility) - utilityWeighted) or 0,
            weight = w.utility,
            active = active.utility,
        },
        avoidable = {
            raw = avoidScore,
            weighted = avoidWeighted,
            lost = active.avoidable and ((100 * w.avoidable) - avoidWeighted) or 0,
            weight = w.avoidable,
            active = active.avoidable,
        },
        deaths = {
            raw = deathScore,
            weighted = deathWeighted,
            lost = (100 * w.deaths) - deathWeighted,
            weight = w.deaths,
            count = snap.deathCount or 0,
            active = true,
        },
        engagement = {
            raw = engagementScore,
            weighted = engagementWeighted,
            lost = (100 * w.engagement) - engagementWeighted,
            weight = w.engagement,
            active = true,
        },
    }
end

PC.Scoring = Scoring

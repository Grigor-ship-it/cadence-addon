--[[
    Cadence - UI_Tooltip.lua
    Detailed mouseover tooltip for player rows.
    Premium styling: gold-accented section headers, clean data hierarchy.
    Shows full breakdown: score components, rolling APM, top abilities,
    gap data, burst/sustain, melee metrics, AFK flags.
]]

local ADDON_NAME, PC = ...

PC.UI_Tooltip = {}
local Tooltip = PC.UI_Tooltip
local Tracker = PC.Tracker
local Scoring = PC.Scoring
local Segments = PC.Segments
local Utils = PC.Utils

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local FONT_FILE = "Fonts\\FRIZQT__.TTF"

-- Premium palette references
local C_GOLD        = { 0.85, 0.66, 0.15 }
local C_GOLD_BRIGHT = { 1.00, 0.84, 0.40 }
local C_TEXT_STD    = { 0.72, 0.72, 0.80 }
local C_TEXT_MUTED  = { 0.49, 0.49, 0.60 }
local C_SECTION     = { C_GOLD_BRIGHT[1], C_GOLD_BRIGHT[2], C_GOLD_BRIGHT[3] }

---------------------------------------------------------------------------
-- Show tooltip for a player
---------------------------------------------------------------------------
function Tooltip.Show(anchor, guid, isHistorical)
    if not guid then return end

    local report

    if isHistorical then
        local segIdx = Segments.GetActiveIndex()
        local seg = Segments.GetSegment(segIdx)
        if seg and seg.players and seg.players[guid] then
            report = Tooltip.BuildHistoricalReport(seg.players[guid])
        end
    else
        -- Use PvP report when in an active arena match
        local isPvP = PC.Events and PC.Events.IsInArena and PC.Events.IsInArena()
        if isPvP then
            report = Scoring.GetPvPFullReport(guid)
        else
            report = Scoring.GetFullReport(guid)
        end
    end

    if not report then return end

    local name = Utils.GetNameByGUID(guid)
    local class = Utils.GetClassByGUID(guid)
    local colorHex = Utils.GetClassColorHex(class)

    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT", 10, 0)
    GameTooltip:ClearLines()

    -- Header: player name (class-colored) + brand mark
    GameTooltip:AddDoubleLine(colorHex .. name .. "|r", "|cffffffffCAD|r|cffD9A826ENCE|r", 1, 1, 1, C_GOLD[1], C_GOLD[2], C_GOLD[3])
    GameTooltip:AddLine(" ")

    -- Cadence Score
    local sr, sg, sb = Utils.GetScoreColor(report.cadenceScore or report.activityScore or 0)
    GameTooltip:AddDoubleLine("|cffFFD666Cadence Score|r",
        Utils.FormatScore(report.cadenceScore or report.activityScore), C_GOLD_BRIGHT[1], C_GOLD_BRIGHT[2], C_GOLD_BRIGHT[3], sr, sg, sb)

    -- AFK flag
    if report.afkFlag then
        GameTooltip:AddDoubleLine("AFK Detected",
            "Yes", C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], 1, 0.2, 0.2)
    end

    GameTooltip:AddLine(" ")

    -------------------------------------------------------------------
    -- Core metrics
    -------------------------------------------------------------------
    GameTooltip:AddLine("|cffFFD666Core Metrics|r")
    GameTooltip:AddDoubleLine("  iAPM (intent)",
        Utils.FormatAPM(report.apm), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_TEXT_STD[1], C_TEXT_STD[2], C_TEXT_STD[3])
    if report.rawApm then
        GameTooltip:AddDoubleLine("  Raw APM (all)",
            Utils.FormatAPM(report.rawApm), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    end
    if report.expectedAPM then
        GameTooltip:AddDoubleLine("  Expected APM (" .. (report.archetype or "?") .. ")",
            Utils.FormatAPM(report.expectedAPM), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    end
    GameTooltip:AddDoubleLine("  Intent Actions",
        tostring(report.intentActionCount or report.actionCount or 0), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_TEXT_STD[1], C_TEXT_STD[2], C_TEXT_STD[3])
    GameTooltip:AddDoubleLine("  Combat Duration",
        Utils.FormatTime(report.combatDuration or 0), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_TEXT_STD[1], C_TEXT_STD[2], C_TEXT_STD[3])
    GameTooltip:AddDoubleLine("  Avg Gap",
        Utils.FormatGap(report.avgGap), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_TEXT_STD[1], C_TEXT_STD[2], C_TEXT_STD[3])
    GameTooltip:AddDoubleLine("  Longest Gap",
        Utils.FormatGap(report.maxGap), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3],
        (report.maxGap or 0) > 10 and 1 or C_TEXT_STD[1],
        (report.maxGap or 0) > 10 and 0.3 or C_TEXT_STD[2],
        (report.maxGap or 0) > 10 and 0.3 or C_TEXT_STD[3])
    GameTooltip:AddDoubleLine("  Active Uptime",
        Utils.FormatPercent(report.uptime), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_TEXT_STD[1], C_TEXT_STD[2], C_TEXT_STD[3])

    -------------------------------------------------------------------
    -- Rolling APM windows (live only)
    -------------------------------------------------------------------
    if report.rolling10 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffFFD666Rolling APM|r")
        GameTooltip:AddDoubleLine("  10s window",
            Utils.FormatAPM(report.rolling10), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_GOLD_BRIGHT[1], C_GOLD_BRIGHT[2], C_GOLD_BRIGHT[3])
        GameTooltip:AddDoubleLine("  30s window",
            Utils.FormatAPM(report.rolling30), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_GOLD_BRIGHT[1], C_GOLD_BRIGHT[2], C_GOLD_BRIGHT[3])
        GameTooltip:AddDoubleLine("  60s window",
            Utils.FormatAPM(report.rolling60), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_GOLD_BRIGHT[1], C_GOLD_BRIGHT[2], C_GOLD_BRIGHT[3])
        GameTooltip:AddDoubleLine("  3min window",
            Utils.FormatAPM(report.rolling180), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_GOLD_BRIGHT[1], C_GOLD_BRIGHT[2], C_GOLD_BRIGHT[3])
    end

    -------------------------------------------------------------------
    -- Burst vs Sustain
    -------------------------------------------------------------------
    if report.burstAPM and report.sustainAPM then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffFFD666Burst / Sustain|r")
        GameTooltip:AddDoubleLine("  Peak APM (10s bucket)",
            Utils.FormatAPM(report.burstAPM), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], 1, 0.8, 0.3)
        GameTooltip:AddDoubleLine("  Average APM (10s buckets)",
            Utils.FormatAPM(report.sustainAPM), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], 0.7, 1, 0.7)
        local ratioStr = string.format("%.2fx", report.burstRatio or 1)
        GameTooltip:AddDoubleLine("  Burst Ratio",
            ratioStr, C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_TEXT_STD[1], C_TEXT_STD[2], C_TEXT_STD[3])
    end

    -------------------------------------------------------------------
    -- Melee Swing data (informational only, no longer scored)
    -------------------------------------------------------------------
    if report.hasMeleeSwings then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffFFD666Melee Swings|r")
        GameTooltip:AddDoubleLine("  Swing Count",
            tostring(report.swingCount or 0), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_TEXT_STD[1], C_TEXT_STD[2], C_TEXT_STD[3])
        if report.swingUptime then
            GameTooltip:AddDoubleLine("  Swing Uptime",
                Utils.FormatPercent(report.swingUptime), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3],
                report.swingUptime >= 80 and 0.2 or 1,
                report.swingUptime >= 80 and 1 or 0.5,
                report.swingUptime >= 80 and 0.2 or 0.2)
        end
    end

    -------------------------------------------------------------------
    -- v2 Score Breakdown (full debug instrumentation)
    -------------------------------------------------------------------
    if report._apmScore then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffFFD666Score Breakdown (v2)|r")
        local function CompColor(val, maxVal)
            local pct = val / (maxVal or 100)
            if pct >= 0.70 then return 0.2, 1, 0.2
            elseif pct >= 0.40 then return 1, 0.8, 0.2
            else return 1, 0.3, 0.3 end
        end
        local w = PC.db and PC.db.profile and PC.db.profile.scoring or
                  { apmWeight=0.55, uptimeWeight=0.45 }

        -- APM Score
        local ar, ag, ab = CompColor(report._apmScore, 100)
        GameTooltip:AddDoubleLine(
            string.format("  APM Score (w=%.0f%%)", (w.apmWeight or 0.55) * 100),
            string.format("%.1f", report._apmScore),
            C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], ar, ag, ab)

        -- Uptime Score
        local ur, ug, ub = CompColor(report._uptimeScore, 100)
        GameTooltip:AddDoubleLine(
            string.format("  Uptime Score (w=%.0f%%)", (w.uptimeWeight or 0.45) * 100),
            string.format("%.1f%%", report._uptimeScore),
            C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], ur, ug, ub)

        -- Base Score
        if report._baseScore then
            GameTooltip:AddDoubleLine("  Base Score",
                string.format("%.1f", report._baseScore),
                C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_TEXT_STD[1], C_TEXT_STD[2], C_TEXT_STD[3])
        end

        -- Dedup ratio (raw vs intent)
        if report.actionCount and report.intentActionCount and report.actionCount > 0 then
            local dedupRatio = report.intentActionCount / report.actionCount
            GameTooltip:AddDoubleLine("  Dedup Ratio (intent/raw)",
                string.format("%.0f%%", dedupRatio * 100),
                C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
        end
    end

    -------------------------------------------------------------------
    -- Top Abilities
    -------------------------------------------------------------------
    local abilities = report.topAbilities
    if abilities and #abilities > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffFFD666Top Abilities|r")
        for i, ab in ipairs(abilities) do
            if i > 8 then break end
            local pctStr = string.format("%.1f%%", ab.percent or 0)
            GameTooltip:AddDoubleLine(
                string.format("  %s (%d)", ab.name, ab.count),
                pctStr,
                C_TEXT_STD[1], C_TEXT_STD[2], C_TEXT_STD[3], C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
        end
    end

    -------------------------------------------------------------------
    -- Long gap warnings
    -------------------------------------------------------------------
    if report.longGaps and report.longGaps > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("|cffff4444Long Inactivity Gaps|r",
            tostring(report.longGaps) .. "x",
            1, 0.3, 0.3, 1, 0.3, 0.3)
    end

    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Build a report-like table from a historical segment snapshot
-- (to match the format of Scoring.GetFullReport for live data)
---------------------------------------------------------------------------
function Tooltip.BuildHistoricalReport(snap)
    if not snap then return nil end

    return {
        activityScore  = snap.activityScore or 0,
        cadenceScore   = snap.cadenceScore or snap.activityScore or 0,
        afkFlag        = snap.afkFlag or false,
        apm            = snap.apm or 0,
        rawApm         = snap.rawApm,
        actionCount    = snap.actionCount or 0,
        intentActionCount = snap.intentActionCount or snap.actionCount or 0,
        combatDuration = snap.combatDuration or 0,
        avgGap         = snap.avgGap or 0,
        maxGap         = snap.maxGap or 0,
        uptime         = snap.uptime or 0,
        swingUptime    = snap.swingUptime,
        hasMeleeSwings = snap.hasMeleeSwings,
        swingCount     = snap.swingCount or 0,
        topAbilities   = snap.topAbilities or {},
        deathCount     = snap.deathCount or 0,
        archetype      = snap.archetype,
        expectedAPM    = snap.expectedAPM,
        -- Rolling windows not available for historical data
        rolling10  = nil,
        rolling30  = nil,
        rolling60  = nil,
        rolling180 = nil,
        burstAPM    = nil,
        sustainAPM  = nil,
        burstRatio  = nil,
        longGaps    = nil,
        -- v3 component scores not available for historical data
        _apmScore         = nil,
        _uptimeScore      = nil,
        _baseScore        = nil,
    }
end

---------------------------------------------------------------------------
-- Hide tooltip
---------------------------------------------------------------------------
function Tooltip.Hide()
    GameTooltip:Hide()
end

PC.UI_Tooltip = Tooltip

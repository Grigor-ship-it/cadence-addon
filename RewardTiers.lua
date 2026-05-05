--[[
    Cadence — RewardTiers.lua
    Display tiers for the in-game reward tooltip. Intentionally minimal:
    only the bits actually rendered by UI_RewardTooltip.lua live here.

    Anything richer (badges, achievements, contribution counts, per-role
    breakdowns, self-sufficiency, carried ratio) lives on the website
    profile page — not in this addon — to keep the seed file small and
    the tooltip uncluttered.
]]

local ADDON_NAME, PC = ...

PC.RewardTiers = {}
local RT = PC.RewardTiers

---------------------------------------------------------------------------
-- Score → color tier (used to color the score number in the tooltip).
---------------------------------------------------------------------------
RT.TITLES = {
    { minScore = 95, color = "ff8000" },  -- orange (legendary)
    { minScore = 85, color = "a335ee" },  -- purple (epic)
    { minScore = 75, color = "0070dd" },  -- blue   (rare)
    { minScore = 60, color = "1eff00" },  -- green  (uncommon)
    { minScore = 40, color = "ffffff" },  -- white  (common)
    { minScore = 0,  color = "9d9d9d" },  -- gray   (poor)
}

---------------------------------------------------------------------------
-- Confidence tiers — how reliable is this player's data?
-- Driven by total encounters analyzed on the server side.
---------------------------------------------------------------------------
RT.CONFIDENCE = {
    { minRuns = 100, label = "Very High",  color = "1eff00" },
    { minRuns = 50,  label = "High",        color = "0070dd" },
    { minRuns = 20,  label = "Moderate",    color = "ffffff" },
    { minRuns = 5,   label = "Low",         color = "ffff00" },
    { minRuns = 0,   label = "Very Low",    color = "ff4444" },
}

---------------------------------------------------------------------------
-- Lookup helpers
---------------------------------------------------------------------------

--- Get the title tier (color) for a given average score.
function RT.GetTitleForScore(score)
    for _, tier in ipairs(RT.TITLES) do
        if score >= tier.minScore then return tier end
    end
    return RT.TITLES[#RT.TITLES]
end

--- Get the confidence tier for a given number of analyzed encounters.
function RT.GetConfidenceTier(totalRuns)
    for _, tier in ipairs(RT.CONFIDENCE) do
        if totalRuns >= tier.minRuns then return tier end
    end
    return RT.CONFIDENCE[#RT.CONFIDENCE]
end

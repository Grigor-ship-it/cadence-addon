--[[
    Cadence - RegionalData.lua

    Loads after RewardsDB*.lua and ScoresDB*.lua, runs before any UI file.
    Each region file declares its own per-region global
    (`CadenceRewardsDB_us`, `CadenceRewardsDB_eu`, ...). This file picks
    the active region via `GetCurrentRegion()` and aliases the unprefixed
    `CadenceRewardsDB` / `CadenceScoresDB` consumed by tooltip / LFG /
    player-card / reward-tooltip UIs.

    Why we don't just generate a single combined file:
      * One CurseForge release for all four regions = single install link
        for the user, no manual swapping when reroll/transfer.
      * Per-region files keep the daily payload tiny — an EU client never
        loads the US scores table.
      * The chooser is a 10-line file, zero per-frame cost.

    GetCurrentRegion() id map (Blizzard, stable since Cata):
      1 = US, 2 = KR, 3 = EU, 4 = TW, 5 = CN
    If the API is unavailable (very old client / loadout glitch) we fall
    back to "us" so the addon still produces *some* data, just stale-ish
    for non-US players. This matches existing behaviour and is safer than
    nil-checks scattered across every UI file.
]]

local REGION_ID_TO_CODE = {
    [1] = "us",
    [2] = "kr",
    [3] = "eu",
    [4] = "tw",
    [5] = "cn",
}

local function ResolveRegion()
    local id = (GetCurrentRegion and GetCurrentRegion()) or 1
    return REGION_ID_TO_CODE[id] or "us"
end

local region = ResolveRegion()

-- Pick the correct rewards table. Falls back to US if the active region's
-- file is missing (e.g. CN, which the addon doesn't currently ship).
CadenceRewardsDB = _G["CadenceRewardsDB_" .. region]
                or _G.CadenceRewardsDB_us
                or {}

-- Same for scores.
CadenceScoresDB  = _G["CadenceScoresDB_"  .. region]
                or _G.CadenceScoresDB_us
                or {}

-- Match the metadata globals to the selected region so debug commands
-- and the QR payload report a consistent value across regions.
CADENCE_REWARDS_REGION = region
CADENCE_SCORES_REGION  = region

-- Free the other regions' tables — they can be ~50KB each and we never
-- read them after this file runs. Lua's GC will reclaim them on the next
-- collection cycle.
for code in pairs(REGION_ID_TO_CODE) do
    if code ~= region then
        _G["CadenceRewardsDB_" .. code] = nil
        _G["CadenceScoresDB_"  .. code] = nil
    end
end

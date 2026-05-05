--[[
    Cadence — UI_RewardTooltip.lua
    Automatically shows Cadence reward data in the native GameTooltip
    when hovering over any player.  No commands needed — just works.

    This reads from CadenceRewardsDB (daily-synced Lua file, same model
    as RaiderIO) and displays:
      • Public title + average score (color-coded)
      • Badge tier (Diamond → Unranked)
      • Confidence level (how much data we have on them)
      • Self-sufficiency stars (the "carried" detector)
      • Per-role averages (DPS / Heal / Tank)
      • Seasonal rank
      • Profile summary (one-liner)
      • Contribution badge (shows they're sharing data)
      • Achievement badges

    Separate from UI_Tooltip.lua (which shows live combat data).
    This shows historical aggregated server data for any player.
]]

local ADDON_NAME, PC = ...

PC.UI_RewardTooltip = {}
local RewardTip = PC.UI_RewardTooltip
local RT = PC.RewardTiers
local Utils = PC.Utils

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local C_BRAND   = "|cff00ccff"   -- Cadence cyan
local C_MUTED   = "|cff7a7a99"

---------------------------------------------------------------------------
-- Lookup: get reward data for a Name-Realm key
---------------------------------------------------------------------------
local function GetRewardData(name, realm)
    if not CadenceRewardsDB then return nil end
    local key = name .. "-" .. realm
    return CadenceRewardsDB[key]
end

---------------------------------------------------------------------------
-- Resolve name + realm from a unit token
---------------------------------------------------------------------------
local function GetUnitNameRealm(unit)
    local name, realm = UnitName(unit)
    if not name then return nil, nil end
    -- If realm is empty/nil, use the player's own realm
    if not realm or realm == "" then
        realm = GetNormalizedRealmName()
    end
    return name, realm
end

---------------------------------------------------------------------------
-- Main tooltip injection
---------------------------------------------------------------------------
local function OnTooltipSetUnit(tooltip, tooltipData)
    -- Bail if rewards DB not loaded
    if not CadenceRewardsDB or not next(CadenceRewardsDB) then return end

    -- Wrap everything in pcall — tooltipData fields can be Blizzard
    -- "secret" tainted values that look non-nil but explode on any
    -- string operation.  pcall lets us silently bail instead of
    -- spamming 676 errors in dungeons/delves.
    local ok, _ = pcall(function()
        local guid = tooltipData and tooltipData.guid
        if not guid then return end
        if type(guid) ~= "string" then return end

        local unitType = strsplit("-", guid)
        if unitType ~= "Player" then return end

        local _, _, _, _, _, name, realm = GetPlayerInfoByGUID(guid)
        if not name then return end
        if not realm or realm == "" then
            realm = GetNormalizedRealmName()
        end

        local data = GetRewardData(name, realm)
        if not data then return end

        -- Unpack compressed fields (schema: s, c, n, u — see backend/lua-export.js)
        local avgScore  = data.s or 0
        local totalRuns = data.n or 0

        -- Resolve display tiers
        local titleTier = RT.GetTitleForScore(avgScore)
        local confTier  = RT.GetConfidenceTier(totalRuns)

        ---------------------------------------------------------------
        -- Inject into tooltip — 2 lines, deliberately minimal.
        -- Goal: a fast "do I know this person, is the data solid"
        -- glance. Everything richer (per-role, badges, history,
        -- carried/donor stats) lives on the website profile page.
        ---------------------------------------------------------------
        tooltip:AddLine(" ")

        -- Line 1: Brand + score (color = title tier)
        tooltip:AddDoubleLine(
            C_BRAND .. "Cadence|r",
            "|cff" .. titleTier.color .. string.format("%.1f", avgScore) .. "|r"
        )

        -- Line 2: Confidence tier + encounter count
        tooltip:AddDoubleLine(
            "|cff" .. confTier.color .. confTier.label .. "|r",
            C_MUTED .. totalRuns .. " encounters|r"
        )

        tooltip:Show()
    end)
    -- If pcall failed, silently ignore — it's just a tainted tooltip field
end

---------------------------------------------------------------------------
-- Hook into the game tooltip system
-- Uses TooltipDataProcessor (Retail 10.0+)
---------------------------------------------------------------------------
local function Init()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnTooltipSetUnit)
    end
end

---------------------------------------------------------------------------
-- Data stats (debug only — not exposed to players)
---------------------------------------------------------------------------
function RewardTip.GetDBStats()
    if not CadenceRewardsDB then
        return { loaded = false, count = 0, region = "unknown", generated = 0 }
    end
    local count = 0
    for _ in pairs(CadenceRewardsDB) do count = count + 1 end
    return {
        loaded    = count > 0,
        count     = count,
        region    = CADENCE_REWARDS_REGION or "unknown",
        generated = CADENCE_REWARDS_GENERATED or 0,
        version   = CADENCE_REWARDS_VERSION or 0,
    }
end

---------------------------------------------------------------------------
-- Register on addon load
---------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self)
    Init()
    -- Fully automatic — no login spam. Data just shows up in tooltips.
    self:UnregisterAllEvents()
end)

PC.UI_RewardTooltip = RewardTip

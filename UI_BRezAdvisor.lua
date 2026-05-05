--[[
    Cadence - UI_BRezAdvisor.lua

    Attaches a small badge to Blizzard's CompactRaidFrame (raid) and
    CompactPartyFrame (party) for any dead unit, telling you whether
    they're worth the battle rez based on their current Cadence Score.

    Rules:
      * Only shows when the unit is dead OR ghost.
      * Score < threshold (default 60) -> red "DON'T REZ" badge.
      * Score >= threshold              -> green "REZ" badge.
      * Not enough combat data yet      -> neutral grey "?" badge
        (avoids judging someone who died in the first 5 seconds).
      * Hides automatically when the unit revives or frame is recycled.

    Implementation notes:
      * We hook the secure CompactUnitFrame_UpdateAll Blizzard callback
        so our badge stays attached even when the raid frame layout
        rebuilds (group join, role change, sort).
      * One badge per frame, stored in frame.cadenceBRez to avoid leaks.
      * Badge is a non-secure overlay -> safe in combat, no taint risk
        because we don't change frame anchors or click handlers.
      * Score is read from the live Tracker via Scoring.CalcCadenceLiveScore
        with the current segment's content type (raid / mythicplus / arena).
]]

local ADDON_NAME, PC = ...

PC.UI_BRezAdvisor = {}
local M = PC.UI_BRezAdvisor

local Tracker, Scoring, Segments, Utils, MeterData

---------------------------------------------------------------------------
-- Configuration helpers
---------------------------------------------------------------------------
local function GetCfg()
    if PC.db and PC.db.profile and PC.db.profile.brezAdvisor then
        return PC.db.profile.brezAdvisor
    end
    return { enabled = true, threshold = 60, minSamples = 30 }
end

---------------------------------------------------------------------------
-- Score lookup for a given GUID using the live Tracker.
-- Returns: score (0-100), hasEnoughData (bool)
---------------------------------------------------------------------------
local function GetLiveCadenceScore(guid)
    if not guid or not Tracker or not Scoring then return 0, false end
    local pd = Tracker.GetPlayerData(guid)
    if not pd then return 0, false end

    local cfg = GetCfg()
    local duration = (Tracker.GetCombatDuration and Tracker.GetCombatDuration(guid)) or 0
    if duration < (cfg.minSamples or 30) then
        return 0, false
    end

    -- Build a snapshot-shaped table for CalcCadenceLiveScore.
    -- Pull live meter data when available.
    local liveMeter = MeterData and MeterData.GetLiveMeterData and MeterData.GetLiveMeterData() or nil
    local m = liveMeter and liveMeter[guid] or {}

    local snap = {
        guid            = guid,
        role            = (Utils and Utils.GetRoleByGUID and Utils.GetRoleByGUID(guid)) or "DAMAGER",
        dps             = m.dps or 0,
        hps             = m.hps or 0,
        damageDone      = m.damageDone or 0,
        healingDone     = m.healingDone or 0,
        interrupts      = m.interrupts or 0,
        dispels         = m.dispels or 0,
        externals       = pd.externalCount or 0,
        raidCds         = pd.raidCdCount or 0,
        support         = pd.supportCount or 0,
        cc              = pd.ccCount or 0,
        avoidableDamage = m.avoidableDamage or 0,
        deathCount      = (Tracker.GetDeathCount and Tracker.GetDeathCount(guid)) or 0,
        activityScore   = Scoring.CalcCompositeScore and Scoring.CalcCompositeScore(guid) or 0,
        isEnemy         = false,
    }

    -- Build group snapshots for relative scoring
    local allSnaps = {}
    if Tracker.GetAllPlayerData then
        for g, opd in pairs(Tracker.GetAllPlayerData()) do
            local lm = liveMeter and liveMeter[g] or {}
            allSnaps[g] = {
                dps             = lm.dps or 0,
                hps             = lm.hps or 0,
                damageDone      = lm.damageDone or 0,
                healingDone     = lm.healingDone or 0,
                interrupts      = lm.interrupts or 0,
                dispels         = lm.dispels or 0,
                externals       = opd.externalCount or 0,
                raidCds         = opd.raidCdCount or 0,
                support         = opd.supportCount or 0,
                cc              = opd.ccCount or 0,
                avoidableDamage = lm.avoidableDamage or 0,
                deathCount      = (Tracker.GetDeathCount and Tracker.GetDeathCount(g)) or 0,
                activityScore   = Scoring.CalcCompositeScore and Scoring.CalcCompositeScore(g) or 0,
                role            = (Utils and Utils.GetRoleByGUID and Utils.GetRoleByGUID(g)) or "DAMAGER",
                isEnemy         = opd.isEnemy or false,
            }
        end
    end

    -- Determine content type from segments
    local contentType = "raid"
    local ctx = nil
    if Segments then
        if Segments.IsInMythicPlus and Segments.IsInMythicPlus() then
            contentType = "mythicplus"
        end
        if Segments.GetCurrentScoreContext then
            ctx = Segments.GetCurrentScoreContext()
        end
    end

    local score = Scoring.CalcCadenceLiveScore(snap, allSnaps, contentType, ctx) or 0
    return score, true
end

---------------------------------------------------------------------------
-- Badge factory: creates / reuses one badge per CompactUnitFrame.
---------------------------------------------------------------------------
local function EnsureBadge(frame)
    local b = frame.cadenceBRez
    if b then return b end

    b = CreateFrame("Frame", nil, frame)
    b:SetSize(48, 16)
    b:SetFrameStrata("HIGH")
    b:SetFrameLevel((frame:GetFrameLevel() or 1) + 5)
    b:SetPoint("CENTER", frame, "CENTER", 0, 0)

    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints(b)
    b.bg:SetColorTexture(0, 0, 0, 0.85)

    b.border = b:CreateTexture(nil, "BORDER")
    b.border:SetPoint("TOPLEFT", b, "TOPLEFT", -1, 1)
    b.border:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 1, -1)
    b.border:SetColorTexture(1, 1, 1, 0.4)

    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.text:SetTextColor(1, 1, 1, 1)

    b:Hide()
    frame.cadenceBRez = b
    return b
end

local function SetBadgeState(badge, mode, score)
    -- mode: "rez" / "norez" / "unknown" / "hide"
    if mode == "hide" then
        badge:Hide()
        return
    end
    if mode == "rez" then
        badge.bg:SetColorTexture(0.05, 0.45, 0.05, 0.90)
        badge.border:SetColorTexture(0.4, 1.0, 0.4, 0.9)
        badge.text:SetText("REZ " .. tostring(score))
        badge.text:SetTextColor(0.9, 1.0, 0.9, 1)
    elseif mode == "norez" then
        badge.bg:SetColorTexture(0.55, 0.05, 0.05, 0.92)
        badge.border:SetColorTexture(1.0, 0.3, 0.3, 1.0)
        badge.text:SetText("SKIP " .. tostring(score))
        badge.text:SetTextColor(1.0, 0.9, 0.9, 1)
    else
        badge.bg:SetColorTexture(0.20, 0.20, 0.20, 0.85)
        badge.border:SetColorTexture(0.6, 0.6, 0.6, 0.7)
        badge.text:SetText("?")
        badge.text:SetTextColor(0.85, 0.85, 0.85, 1)
    end
    badge:Show()
end

---------------------------------------------------------------------------
-- Update one CompactUnitFrame.
---------------------------------------------------------------------------
local function UpdateFrame(frame)
    if not frame or not frame.unit then return end
    local cfg = GetCfg()
    if not cfg.enabled then
        if frame.cadenceBRez then frame.cadenceBRez:Hide() end
        return
    end

    local unit = frame.unit
    -- Only party/raid units, never the player themselves (you can't BR yourself).
    if unit == "player" or unit == "vehicle" then
        if frame.cadenceBRez then frame.cadenceBRez:Hide() end
        return
    end
    if not (unit:match("^party%d") or unit:match("^raid%d")) then
        if frame.cadenceBRez then frame.cadenceBRez:Hide() end
        return
    end

    if not UnitExists(unit) then
        if frame.cadenceBRez then frame.cadenceBRez:Hide() end
        return
    end

    -- Only show on dead units
    local isDead = UnitIsDeadOrGhost(unit)
    if not isDead then
        if frame.cadenceBRez then frame.cadenceBRez:Hide() end
        return
    end

    -- BR doesn't work in arenas / battlegrounds
    local _, instanceType = IsInInstance()
    if instanceType == "arena" or instanceType == "pvp" then
        if frame.cadenceBRez then frame.cadenceBRez:Hide() end
        return
    end

    local guid = UnitGUID(unit)
    if not guid then
        if frame.cadenceBRez then frame.cadenceBRez:Hide() end
        return
    end

    local badge = EnsureBadge(frame)
    local score, hasData = GetLiveCadenceScore(guid)
    if not hasData then
        SetBadgeState(badge, "unknown")
        return
    end

    if score < (cfg.threshold or 60) then
        SetBadgeState(badge, "norez", score)
    else
        SetBadgeState(badge, "rez", score)
    end
end

---------------------------------------------------------------------------
-- Iterate every active CompactUnitFrame and update.
-- Cheap: at most 40 frames in a full raid.
---------------------------------------------------------------------------
local function UpdateAllFrames()
    local cfg = GetCfg()
    if not cfg.enabled then return end

    -- Walk both party + raid frame containers via Blizzard's helper.
    if CompactRaidFrameContainer and CompactRaidFrameContainer.flowFrames then
        for _, group in ipairs(CompactRaidFrameContainer.flowFrames) do
            if group and group.GetNumChildren then
                for i = 1, select("#", group:GetChildren()) do
                    local child = select(i, group:GetChildren())
                    if child and child.unit then
                        UpdateFrame(child)
                    end
                end
            end
        end
    end

    -- Party frames
    if CompactPartyFrame then
        for i = 1, select("#", CompactPartyFrame:GetChildren()) do
            local child = select(i, CompactPartyFrame:GetChildren())
            if child and child.unit then
                UpdateFrame(child)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Throttled refresh ticker.  Triggered by death/revive events but also
-- periodic in case we missed an event.
---------------------------------------------------------------------------
local refreshFrame = nil
local lastRefresh = 0
local REFRESH_INTERVAL = 1.0

local function ScheduleRefresh()
    local now = GetTime()
    if (now - lastRefresh) < 0.25 then return end  -- coalesce bursts
    lastRefresh = now
    UpdateAllFrames()
end

---------------------------------------------------------------------------
-- Hook Blizzard's CompactUnitFrame update so we re-attach to recycled
-- frames after layout rebuilds.  Safe (post-hook, non-secure).
---------------------------------------------------------------------------
local hooked = false
local function InstallHooks()
    if hooked then return end
    if not CompactUnitFrame_UpdateAll then return end
    hooksecurefunc("CompactUnitFrame_UpdateAll", function(frame)
        if frame and frame.unit then
            UpdateFrame(frame)
        end
    end)
    -- Also hook the death/health pipelines for snappier updates
    if CompactUnitFrame_UpdateHealth then
        hooksecurefunc("CompactUnitFrame_UpdateHealth", function(frame)
            if frame and frame.unit then UpdateFrame(frame) end
        end)
    end
    hooked = true
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
function M.Init()
    Tracker   = PC.Tracker
    Scoring   = PC.Scoring
    Segments  = PC.Segments
    Utils     = PC.Utils
    MeterData = PC.MeterData

    InstallHooks()

    if not refreshFrame then
        refreshFrame = CreateFrame("Frame")
        refreshFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
        refreshFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        refreshFrame:RegisterEvent("UNIT_HEALTH")
        refreshFrame:RegisterEvent("UNIT_FLAGS")
        refreshFrame:RegisterEvent("PLAYER_DEAD")
        refreshFrame:RegisterEvent("PLAYER_ALIVE")
        refreshFrame:RegisterEvent("PLAYER_UNGHOST")
        refreshFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
        refreshFrame:RegisterEvent("RAID_ROSTER_UPDATE")
        refreshFrame:SetScript("OnEvent", function(_, event, unit)
            if event == "UNIT_HEALTH" or event == "UNIT_FLAGS" then
                if unit and (unit:match("^party%d") or unit:match("^raid%d")) then
                    ScheduleRefresh()
                end
            else
                ScheduleRefresh()
            end
        end)

        -- Background ticker as a safety net (1Hz, skipped when disabled).
        refreshFrame:SetScript("OnUpdate", function(self, elapsed)
            self._t = (self._t or 0) + elapsed
            if self._t < REFRESH_INTERVAL then return end
            self._t = 0
            local cfg = GetCfg()
            if cfg.enabled then UpdateAllFrames() end
        end)
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function M.SetEnabled(on)
    if not (PC.db and PC.db.profile and PC.db.profile.brezAdvisor) then return end
    PC.db.profile.brezAdvisor.enabled = on and true or false
    if not on then
        -- Hide all existing badges
        if CompactRaidFrameContainer and CompactRaidFrameContainer.flowFrames then
            for _, group in ipairs(CompactRaidFrameContainer.flowFrames) do
                if group and group.GetChildren then
                    for i = 1, select("#", group:GetChildren()) do
                        local child = select(i, group:GetChildren())
                        if child and child.cadenceBRez then child.cadenceBRez:Hide() end
                    end
                end
            end
        end
        if CompactPartyFrame then
            for i = 1, select("#", CompactPartyFrame:GetChildren()) do
                local child = select(i, CompactPartyFrame:GetChildren())
                if child and child.cadenceBRez then child.cadenceBRez:Hide() end
            end
        end
    else
        UpdateAllFrames()
    end
end

function M.SetThreshold(value)
    value = tonumber(value)
    if not value then return end
    if value < 0 then value = 0 end
    if value > 100 then value = 100 end
    if PC.db and PC.db.profile and PC.db.profile.brezAdvisor then
        PC.db.profile.brezAdvisor.threshold = value
    end
    UpdateAllFrames()
end

PC.UI_BRezAdvisor = M

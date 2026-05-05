--[[
    Cadence - UI_Summary.lua
    End-of-encounter / M+ summary window.
    Premium post-encounter report — matches the cadencewow.com website aesthetic.
    Dark obsidian surfaces, gold accents, modern typographic hierarchy.
]]

local ADDON_NAME, PC = ...

PC.UI_Summary = {}
local Summary = PC.UI_Summary
local Tracker = PC.Tracker
local Scoring = PC.Scoring
local Segments = PC.Segments
local Utils = PC.Utils

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local FONT_FILE        = "Fonts\\FRIZQT__.TTF"
local FONT_FILE_HEADER = "Fonts\\MORPHEUS.TTF"

-- ── Premium color palette (matches cadencewow.com tokens) ─────
local C_VOID           = { 0.035, 0.035, 0.059, 0.98 }      -- #09090f
local C_OBSIDIAN       = { 0.067, 0.067, 0.094, 0.95 }      -- #111118
local C_SLATE          = { 0.098, 0.098, 0.133, 0.90 }      -- #191922
local C_GRAPHITE       = { 0.133, 0.133, 0.188, 0.70 }      -- #222230
local C_EDGE           = { 0.220, 0.220, 0.314, 0.50 }      -- #383850

-- Gold accent scale
local C_GOLD_BRIGHT    = { 1.00, 0.84, 0.40 }  -- #FFD666
local C_GOLD           = { 0.85, 0.66, 0.15 }  -- #D9A826
local C_GOLD_DIM       = { 0.65, 0.49, 0.10 }  -- #A67C1A
local C_GOLD_MUTED     = { 0.42, 0.31, 0.06 }  -- #6B4F0F

-- Text hierarchy
local C_TEXT_BRIGHT    = { 0.94, 0.94, 0.96 }   -- #F0F0F5
local C_TEXT_STANDARD  = { 0.72, 0.72, 0.80 }   -- #B8B8CC
local C_TEXT_MUTED     = { 0.49, 0.49, 0.60 }   -- #7E7E98
local C_TEXT_GHOST     = { 0.28, 0.28, 0.38 }   -- #484860

-- Semantic
local C_SUCCESS        = { 0.20, 0.83, 0.40 }   -- #34D399
local C_WARNING        = { 0.98, 0.75, 0.15 }   -- #FBBF24
local C_ERROR          = { 0.97, 0.44, 0.44 }   -- #F87171

-- Border (gold tinted, subtle)
local C_BORDER         = { 0.42, 0.35, 0.12, 0.60 }

local GOLD   = { r = 1.0, g = 0.84, b = 0.40 }
local SILVER = { r = 0.78, g = 0.78, b = 0.82 }
local BRONZE = { r = 0.80, g = 0.50, b = 0.20 }

local FRAME_WIDTH = 460
local CONTENT_WIDTH = FRAME_WIDTH - 50  -- scroll bar + padding

local BACKDROP_MAIN = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local summaryFrame = nil
local currentSegment = nil  -- track segment for QR sharing

-- Region pool to avoid orphan‐region memory leaks.
-- WoW UI regions (textures, font strings) can NEVER be garbage collected,
-- so we reuse them across Populate() calls instead of creating new ones.
local pool_textures = {}
local pool_fontStrings = {}
local pool_texIdx = 0
local pool_fsIdx = 0

local function PoolReset()
    -- Hide all previously used pool items
    for i = 1, pool_texIdx do
        pool_textures[i]:Hide()
        pool_textures[i]:ClearAllPoints()
    end
    for i = 1, pool_fsIdx do
        pool_fontStrings[i]:Hide()
        pool_fontStrings[i]:ClearAllPoints()
    end
    pool_texIdx = 0
    pool_fsIdx = 0
end

local function PoolTexture(parent, layer, sublevel)
    pool_texIdx = pool_texIdx + 1
    local tex = pool_textures[pool_texIdx]
    if not tex then
        tex = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel or 0)
        pool_textures[pool_texIdx] = tex
    else
        tex:SetParent(parent)
        tex:SetDrawLayer(layer or "BACKGROUND", sublevel or 0)
    end
    tex:SetTexture(nil)
    tex:Show()
    return tex
end

local function PoolFontString(parent, layer)
    pool_fsIdx = pool_fsIdx + 1
    local fs = pool_fontStrings[pool_fsIdx]
    if not fs then
        fs = parent:CreateFontString(nil, layer or "OVERLAY")
        pool_fontStrings[pool_fsIdx] = fs
    else
        fs:SetParent(parent)
    end
    fs:Show()
    return fs
end

---------------------------------------------------------------------------
-- Status label helper (match UI_Meter thresholds)
---------------------------------------------------------------------------
local STATUS_THRESHOLDS = {
    { min = 85, label = "Pumping",   r = 1.0,  g = 0.5,  b = 0.0  },
    { min = 70, label = "Active",    r = 0.2,  g = 1.0,  b = 0.2  },
    { min = 50, label = "Coasting",  r = 1.0,  g = 1.0,  b = 0.3  },
    { min = 30, label = "Slacking",  r = 1.0,  g = 0.4,  b = 0.1  },
    { min = 0,  label = "Carried",   r = 1.0,  g = 0.15, b = 0.15 },
}

local function GetStatusLabel(score)
    for _, t in ipairs(STATUS_THRESHOLDS) do
        if score >= t.min then
            return t.label, t.r, t.g, t.b
        end
    end
    return "Carried", 1.0, 0.15, 0.15
end

---------------------------------------------------------------------------
-- Build sorted player list from a segment
---------------------------------------------------------------------------
local function BuildPlayerList(segment)
    local list = {}
    if not segment or not segment.players then return list end

    for guid, snap in pairs(segment.players) do
        list[#list + 1] = {
            guid = guid,
            name = snap.name or "Unknown",
            class = snap.class or "PRIEST",
            score = snap.cadenceScore or snap.activityScore or 0,
            activityScore = snap.activityScore or 0,
            apm = snap.apm or 0,
            uptime = snap.uptime or 0,
            actionCount = snap.actionCount or 0,
            combatDuration = snap.combatDuration or 0,
            maxGap = snap.maxGap or 0,
            avgGap = snap.avgGap or 0,
            deaths = snap.deathCount or 0,
            topAbilities = snap.topAbilities or {},
            role = snap.role or "DAMAGER",
            isEnemy = snap.isEnemy or false,
            -- Meter data
            damageDone = snap.damageDone or 0,
            dps = snap.dps or 0,
            healingDone = snap.healingDone or 0,
            hps = snap.hps or 0,
            interrupts = snap.interrupts or 0,
            dispels = snap.dispels or 0,
            avoidableDamage = snap.avoidableDamage or 0,
            meterDeaths = snap.meterDeaths or 0,
        }
    end

    table.sort(list, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        -- Tiebreaker: higher throughput (role-aware) ranks higher
        local aTP = (a.role == "HEALER") and (a.hps or 0) or (a.dps or 0)
        local bTP = (b.role == "HEALER") and (b.hps or 0) or (b.dps or 0)
        return aTP > bTP
    end)
    return list
end

---------------------------------------------------------------------------
-- Award generation — fun superlatives
---------------------------------------------------------------------------
local function GenerateAwards(players)
    if #players == 0 then return {} end

    local awards = {}

    -- MVP — highest score
    local mvp = players[1]
    awards[#awards + 1] = {
        icon = "|TInterface\\Icons\\Achievement_PVP_A_01:16:16|t",
        title = "MVP",
        player = mvp.name,
        class = mvp.class,
        detail = string.format("Score: %.0f", mvp.score),
        r = GOLD.r, g = GOLD.g, b = GOLD.b,
    }

    -- Busiest Hands — highest APM
    local bestAPM = players[1]
    for _, p in ipairs(players) do
        if p.apm > bestAPM.apm then bestAPM = p end
    end
    awards[#awards + 1] = {
        icon = "|TInterface\\Icons\\Spell_Holy_SurgeOfLight:16:16|t",
        title = "Busiest Hands",
        player = bestAPM.name,
        class = bestAPM.class,
        detail = string.format("%.1f APM", bestAPM.apm),
        r = 0.4, g = 0.8, b = 1.0,
    }

    -- Iron Focus — highest uptime
    local bestUptime = players[1]
    for _, p in ipairs(players) do
        if p.uptime > bestUptime.uptime then bestUptime = p end
    end
    awards[#awards + 1] = {
        icon = "|TInterface\\Icons\\Ability_Warrior_UnrelentingAssault:16:16|t",
        title = "Iron Focus",
        player = bestUptime.name,
        class = bestUptime.class,
        detail = string.format("%.0f%% uptime", bestUptime.uptime),
        r = 0.3, g = 1.0, b = 0.5,
    }

    -- Carried Award — lowest score
    if #players >= 3 then
        local worst = players[#players]
        awards[#awards + 1] = {
            icon = "|TInterface\\Icons\\Spell_Nature_Sleep:16:16|t",
            title = "Getting Carried",
            player = worst.name,
            class = worst.class,
            detail = string.format("Score: %.0f", worst.score),
            r = 1.0, g = 0.3, b = 0.3,
        }
    end

    -- AFK Tourist — longest single gap
    local worstGap = players[1]
    for _, p in ipairs(players) do
        if p.maxGap > worstGap.maxGap then worstGap = p end
    end
    if worstGap.maxGap >= 3.0 then
        awards[#awards + 1] = {
            icon = "|TInterface\\Icons\\Ability_Mage_IncantersAbsorbtion:16:16|t",
            title = "AFK Tourist",
            player = worstGap.name,
            class = worstGap.class,
            detail = string.format("%.1fs gap", worstGap.maxGap),
            r = 0.6, g = 0.4, b = 0.8,
        }
    end

    -- Floor Inspector — most deaths
    local mostDeaths = players[1]
    for _, p in ipairs(players) do
        if p.deaths > mostDeaths.deaths then mostDeaths = p end
    end
    if mostDeaths.deaths > 0 then
        awards[#awards + 1] = {
            icon = "|TInterface\\Icons\\Ability_Rogue_FeignDeath:16:16|t",
            title = "Floor Inspector",
            player = mostDeaths.name,
            class = mostDeaths.class,
            detail = string.format("%d death%s", mostDeaths.deaths, mostDeaths.deaths > 1 and "s" or ""),
            r = 0.8, g = 0.2, b = 0.2,
        }
    end

    return awards
end

---------------------------------------------------------------------------
-- Create or refresh the summary frame
---------------------------------------------------------------------------
local function CreateSummaryFrame()
    if summaryFrame then
        summaryFrame:Show()
        return summaryFrame
    end

    local f = CreateFrame("Frame", "CadenceSummaryFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, 560)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    f:SetBackdrop(BACKDROP_MAIN)
    f:SetBackdropColor(C_VOID[1], C_VOID[2], C_VOID[3], C_VOID[4])
    f:SetBackdropBorderColor(C_GOLD_DIM[1], C_GOLD_DIM[2], C_GOLD_DIM[3], 0.35)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)

    -- Handle Escape to close
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
            self:SetPropagateKeyboardInput(false)
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    -- ── Title bar (obsidian surface) ──────────────────────────
    f.titleBg = f:CreateTexture(nil, "ARTWORK")
    f.titleBg:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    f.titleBg:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    f.titleBg:SetHeight(36)
    f.titleBg:SetColorTexture(C_OBSIDIAN[1], C_OBSIDIAN[2], C_OBSIDIAN[3], 0.95)

    -- Gold accent line under title bar
    f.titleAccent = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.titleAccent:SetPoint("BOTTOMLEFT", f.titleBg, "BOTTOMLEFT", 0, 0)
    f.titleAccent:SetPoint("BOTTOMRIGHT", f.titleBg, "BOTTOMRIGHT", 0, 0)
    f.titleAccent:SetHeight(2)
    f.titleAccent:SetColorTexture(C_GOLD[1], C_GOLD[2], C_GOLD[3], 0.60)

    -- Brand mark — "CADENCE" in white+gold
    f.brandText = f:CreateFontString(nil, "OVERLAY")
    f.brandText:SetFont(FONT_FILE, 9, "OUTLINE")
    f.brandText:SetPoint("TOPLEFT", f.titleBg, "TOPLEFT", 12, -6)
    f.brandText:SetTextColor(C_GOLD_DIM[1], C_GOLD_DIM[2], C_GOLD_DIM[3])
    f.brandText:SetText("|cffffffffCAD|r|cffFFD666ENCE|r")

    -- Title text — encounter name (larger)
    f.titleText = f:CreateFontString(nil, "OVERLAY")
    f.titleText:SetFont(FONT_FILE, 13, "OUTLINE")
    f.titleText:SetPoint("BOTTOMLEFT", f.titleBg, "BOTTOMLEFT", 12, 6)
    f.titleText:SetTextColor(C_TEXT_BRIGHT[1], C_TEXT_BRIGHT[2], C_TEXT_BRIGHT[3])

    -- ── Close button (custom × glyph) ────────────────────────
    f.closeBtn = CreateFrame("Button", nil, f)
    f.closeBtn:SetSize(26, 26)
    f.closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -8)
    f.closeBtn.text = f.closeBtn:CreateFontString(nil, "OVERLAY")
    f.closeBtn.text:SetFont(FONT_FILE, 16, "OUTLINE")
    f.closeBtn.text:SetPoint("CENTER")
    f.closeBtn.text:SetText("×")
    f.closeBtn.text:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    f.closeBtn:SetScript("OnClick", function() f:Hide() end)
    f.closeBtn:SetScript("OnEnter", function(self)
        self.text:SetTextColor(C_ERROR[1], C_ERROR[2], C_ERROR[3])
    end)
    f.closeBtn:SetScript("OnLeave", function(self)
        self.text:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    end)

    -- ── Share QR button — premium gold pill ──────────────────
    f.shareBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    f.shareBtn:SetSize(90, 24)
    f.shareBtn:SetPoint("RIGHT", f.closeBtn, "LEFT", -8, 0)
    f.shareBtn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f.shareBtn:SetBackdropColor(C_GOLD_MUTED[1], C_GOLD_MUTED[2], C_GOLD_MUTED[3], 0.40)
    f.shareBtn:SetBackdropBorderColor(C_GOLD[1], C_GOLD[2], C_GOLD[3], 0.50)
    f.shareBtn.text = f.shareBtn:CreateFontString(nil, "OVERLAY")
    f.shareBtn.text:SetFont(FONT_FILE, 10, "OUTLINE")
    f.shareBtn.text:SetPoint("CENTER", f.shareBtn, "CENTER", 0, 0)
    f.shareBtn.text:SetTextColor(C_GOLD_BRIGHT[1], C_GOLD_BRIGHT[2], C_GOLD_BRIGHT[3])
    f.shareBtn.text:SetText("Share QR")
    f.shareBtn:SetScript("OnClick", function()
        if currentSegment and PC.UI_QR and PC.UI_QR.ShowForSegment then
            PC.UI_QR.ShowForSegment(currentSegment)
        end
    end)
    f.shareBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_GOLD_DIM[1], C_GOLD_DIM[2], C_GOLD_DIM[3], 0.60)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("|cffFFD666Share QR Code|r")
        GameTooltip:AddLine("Generate a scannable QR code to\nupload this encounter to cadencewow.com", 0.72, 0.72, 0.80, true)
        GameTooltip:Show()
    end)
    f.shareBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_GOLD_MUTED[1], C_GOLD_MUTED[2], C_GOLD_MUTED[3], 0.40)
        GameTooltip:Hide()
    end)

    -- ── Scroll frame for content ─────────────────────────────
    f.scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    f.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -44)
    f.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 8)

    f.content = CreateFrame("Frame", nil, f.scroll)
    f.content:SetWidth(CONTENT_WIDTH)
    f.content:SetHeight(1)  -- dynamically set
    f.scroll:SetScrollChild(f.content)

    summaryFrame = f
    return f
end

---------------------------------------------------------------------------
-- Add a section header with accent divider
---------------------------------------------------------------------------
local rowIndex = 0  -- tracks alternating row shading

local function AddHeader(parent, yOffset, text, r, g, b)
    rowIndex = 0  -- reset row alternation per section

    -- Section background bar (slate surface)
    local bg = PoolTexture(parent, "BACKGROUND")
    bg:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset + 2)
    bg:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    bg:SetHeight(22)
    bg:SetColorTexture(C_SLATE[1], C_SLATE[2], C_SLATE[3], C_SLATE[4])

    -- Gold accent line above
    local line = PoolTexture(parent, "ARTWORK")
    line:SetPoint("TOPLEFT", bg, "TOPLEFT", 0, 0)
    line:SetPoint("TOPRIGHT", bg, "TOPRIGHT", 0, 0)
    line:SetHeight(2)
    line:SetColorTexture(C_GOLD[1], C_GOLD[2], C_GOLD[3], 0.45)

    -- Subtle bottom edge
    local bottomLine = PoolTexture(parent, "ARTWORK")
    bottomLine:SetPoint("BOTTOMLEFT", bg, "BOTTOMLEFT", 0, 0)
    bottomLine:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", 0, 0)
    bottomLine:SetHeight(1)
    bottomLine:SetColorTexture(C_EDGE[1], C_EDGE[2], C_EDGE[3], 0.30)

    local fs = PoolFontString(parent, "OVERLAY")
    fs:SetFont(FONT_FILE, 11, "OUTLINE")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yOffset - 1)
    fs:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    fs:SetTextColor(r or C_GOLD[1], g or C_GOLD[2], b or C_GOLD[3])
    return yOffset - 24
end

---------------------------------------------------------------------------
-- Add a ranking row with alternating background
---------------------------------------------------------------------------
local ROW_HEIGHT = 20

local function AddRankRow(parent, yOffset, rank, player)
    local cr, cg, cb = Utils.GetClassColor(player.class)
    local sr, sg, sb = Utils.GetScoreColor(player.score)
    local statusLabel, str, stg, stb = GetStatusLabel(player.score)

    -- Alternating row background (obsidian / void)
    rowIndex = rowIndex + 1
    local rowBg = PoolTexture(parent, "BACKGROUND")
    rowBg:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset + 1)
    rowBg:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    rowBg:SetHeight(ROW_HEIGHT)
    if rowIndex % 2 == 0 then
        rowBg:SetColorTexture(C_OBSIDIAN[1], C_OBSIDIAN[2], C_OBSIDIAN[3], 0.40)
    else
        rowBg:SetColorTexture(C_VOID[1], C_VOID[2], C_VOID[3], 0.25)
    end

    -- Medal color for top 3
    local medalColor = nil
    if rank == 1 then medalColor = GOLD
    elseif rank == 2 then medalColor = SILVER
    elseif rank == 3 then medalColor = BRONZE
    end

    -- Subtle left accent strip for top 3
    if medalColor then
        local strip = PoolTexture(parent, "ARTWORK")
        strip:SetPoint("TOPLEFT", rowBg, "TOPLEFT", 0, 0)
        strip:SetPoint("BOTTOMLEFT", rowBg, "BOTTOMLEFT", 0, 0)
        strip:SetWidth(2)
        strip:SetColorTexture(medalColor.r, medalColor.g, medalColor.b, 0.70)
    end

    -- Rank number
    local rankFS = PoolFontString(parent, "OVERLAY")
    rankFS:SetFont(FONT_FILE, 11, "OUTLINE")
    rankFS:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yOffset)
    rankFS:SetWidth(28)
    rankFS:SetJustifyH("RIGHT")
    if medalColor then
        rankFS:SetText(rank .. ".")
        rankFS:SetTextColor(medalColor.r, medalColor.g, medalColor.b)
    else
        rankFS:SetText(rank .. ".")
        rankFS:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    end

    -- Name (class colored)
    local nameFS = PoolFontString(parent, "OVERLAY")
    nameFS:SetFont(FONT_FILE, 11, "OUTLINE")
    nameFS:SetPoint("LEFT", rankFS, "RIGHT", 6, 0)
    nameFS:SetWidth(105)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    nameFS:SetText(player.name)
    nameFS:SetTextColor(cr, cg, cb)

    -- Score
    local scoreFS = PoolFontString(parent, "OVERLAY")
    scoreFS:SetFont(FONT_FILE, 11, "OUTLINE")
    scoreFS:SetPoint("LEFT", nameFS, "RIGHT", 6, 0)
    scoreFS:SetWidth(35)
    scoreFS:SetJustifyH("RIGHT")
    scoreFS:SetText(Utils.FormatScore(player.score))
    scoreFS:SetTextColor(sr, sg, sb)

    -- Status label
    local statusFS = PoolFontString(parent, "OVERLAY")
    statusFS:SetFont(FONT_FILE, 9, "OUTLINE")
    statusFS:SetPoint("LEFT", scoreFS, "RIGHT", 10, 0)
    statusFS:SetWidth(60)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetText(statusLabel)
    statusFS:SetTextColor(str, stg, stb, 0.85)

    -- APM + deaths (right-aligned)
    local detailFS = PoolFontString(parent, "OVERLAY")
    detailFS:SetFont(FONT_FILE, 10, "OUTLINE")
    detailFS:SetPoint("LEFT", statusFS, "RIGHT", 6, 0)
    detailFS:SetWidth(120)
    detailFS:SetJustifyH("LEFT")
    detailFS:SetWordWrap(false)
    local detailStr = Utils.FormatAPM(player.apm) .. " APM"
    if player.deaths > 0 then
        detailStr = detailStr .. "  |cffF87171" .. player.deaths .. "D|r"
    end
    detailFS:SetText(detailStr)
    detailFS:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])

    return yOffset - ROW_HEIGHT
end

---------------------------------------------------------------------------
-- Add an award row with alternating background
---------------------------------------------------------------------------
local function AddAwardRow(parent, yOffset, award)
    rowIndex = rowIndex + 1

    -- Card-style background
    local rowBg = PoolTexture(parent, "BACKGROUND")
    rowBg:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, yOffset + 2)
    rowBg:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
    rowBg:SetHeight(24)
    rowBg:SetColorTexture(C_SLATE[1], C_SLATE[2], C_SLATE[3], 0.40)

    -- Colored left accent strip for the award type
    local strip = PoolTexture(parent, "ARTWORK")
    strip:SetPoint("TOPLEFT", rowBg, "TOPLEFT", 0, 0)
    strip:SetPoint("BOTTOMLEFT", rowBg, "BOTTOMLEFT", 0, 0)
    strip:SetWidth(2)
    strip:SetColorTexture(award.r, award.g, award.b, 0.80)

    local classHex = Utils.GetClassColorHex(award.class)

    -- Award title (colored)
    local titleFS = PoolFontString(parent, "OVERLAY")
    titleFS:SetFont(FONT_FILE, 10, "OUTLINE")
    titleFS:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, yOffset)
    titleFS:SetWidth(110)
    titleFS:SetJustifyH("LEFT")
    titleFS:SetWordWrap(false)
    titleFS:SetText(string.format("%s |cff%02x%02x%02x%s|r",
        award.icon, award.r * 255, award.g * 255, award.b * 255, award.title))

    -- Player name (class-colored)
    local nameFS = PoolFontString(parent, "OVERLAY")
    nameFS:SetFont(FONT_FILE, 10, "OUTLINE")
    nameFS:SetPoint("LEFT", titleFS, "RIGHT", 4, 0)
    nameFS:SetWidth(100)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    nameFS:SetText(classHex .. award.player .. "|r")

    -- Detail (right-aligned, muted)
    local detailFS = PoolFontString(parent, "OVERLAY")
    detailFS:SetFont(FONT_FILE, 9, "OUTLINE")
    detailFS:SetPoint("LEFT", nameFS, "RIGHT", 4, 0)
    detailFS:SetWidth(120)
    detailFS:SetJustifyH("LEFT")
    detailFS:SetWordWrap(false)
    detailFS:SetText(award.detail)
    detailFS:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])

    return yOffset - 24
end

---------------------------------------------------------------------------
-- Add a stats line (clean label : value format)
---------------------------------------------------------------------------
local function AddStatLine(parent, yOffset, label, value, r, g, b)
    -- Label (muted text)
    local labelFS = PoolFontString(parent, "OVERLAY")
    labelFS:SetFont(FONT_FILE, 10, "OUTLINE")
    labelFS:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOffset)
    labelFS:SetWidth(140)
    labelFS:SetJustifyH("LEFT")
    labelFS:SetText(label)
    labelFS:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])

    -- Value (bright, colored)
    local valueFS = PoolFontString(parent, "OVERLAY")
    valueFS:SetFont(FONT_FILE, 10, "OUTLINE")
    valueFS:SetPoint("LEFT", labelFS, "RIGHT", 4, 0)
    valueFS:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    valueFS:SetJustifyH("LEFT")
    valueFS:SetText(tostring(value))
    valueFS:SetTextColor(r or C_TEXT_BRIGHT[1], g or C_TEXT_BRIGHT[2], b or C_TEXT_BRIGHT[3])
    return yOffset - 18
end

---------------------------------------------------------------------------
-- Populate the summary with segment data
---------------------------------------------------------------------------
function Summary.Populate(segment)
    local f = CreateSummaryFrame()
    local content = f.content

    -- Reset the region pool — hides & reuses all previously created regions
    PoolReset()

    -- Store segment for QR sharing
    currentSegment = segment

    local players = BuildPlayerList(segment)
    if #players == 0 then
        f.titleText:SetText("Cadence Summary")
        local empty = PoolFontString(content, "OVERLAY")
        empty:SetFont(FONT_FILE, 12, "OUTLINE")
        empty:SetPoint("CENTER", content, "CENTER", 0, 0)
        empty:SetText("No player data recorded.")
        empty:SetTextColor(0.6, 0.6, 0.6)
        content:SetHeight(100)
        f:Show()
        return
    end

    -- Title
    local segName = segment.name or "Encounter"
    local duration = segment.duration or 0
    f.titleText:SetText(segName)

    local y = -8

    -- Duration & overview
    y = AddHeader(content, y, "Overview", 1, 0.84, 0)
    y = y - 2

    local totalActions = 0
    local totalDeaths = 0
    local avgScore = 0
    for _, p in ipairs(players) do
        totalActions = totalActions + p.actionCount
        totalDeaths = totalDeaths + p.deaths
        avgScore = avgScore + p.score
    end
    avgScore = avgScore / #players

    y = AddStatLine(content, y, "Duration", Utils.FormatTime(duration), 1, 1, 1)
    y = AddStatLine(content, y, "Players", #players, 1, 1, 1)
    y = AddStatLine(content, y, "Total Casts", totalActions, 0.6, 0.8, 1.0)
    y = AddStatLine(content, y, "Avg Score", Utils.FormatScore(avgScore), Utils.GetScoreColor(avgScore))
    if totalDeaths > 0 then
        y = AddStatLine(content, y, "Total Deaths", totalDeaths, 1, 0.3, 0.3)
    end

    y = y - 8

    -- Rankings
    y = AddHeader(content, y, "Cadence Rankings", 1, 0.84, 0)
    y = y - 2

    for i, p in ipairs(players) do
        y = AddRankRow(content, y, i, p)
    end

    y = y - 10

    -- Awards
    local awards = GenerateAwards(players)
    if #awards > 0 then
        y = AddHeader(content, y, "Awards", 1, 0.84, 0)
        y = y - 2
        for _, award in ipairs(awards) do
            y = AddAwardRow(content, y, award)
        end
    end

    y = y - 10

    -- Per-player score breakdown — "why you didn't score 100"
    -- Determine content type for breakdown calculation
    local segType = segment.segType or "none"
    local breakdownContentType = (segType == "arena" or segType == "soloshuffle") and "arena"
        or (segType == "boss") and "raid" or "mythicplus"
    local breakdownCtx = { difficultyID = segment.difficultyID, keystoneLevel = segment.keystoneLevel }

    -- Build allPlayers lookup for group-relative scoring
    local allPlayersLookup = {}
    for _, p in ipairs(players) do
        allPlayersLookup[p.guid] = p
    end

    y = AddHeader(content, y, "Score Breakdown", 1, 0.84, 0)
    y = y - 2

    for _, p in ipairs(players) do
        local cr, cg, cb = Utils.GetClassColor(p.class)
        local classHex = Utils.GetClassColorHex(p.class)

        -- Player name sub-header with class-tinted card background
        local nameBg = PoolTexture(content, "BACKGROUND")
        nameBg:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y + 2)
        nameBg:SetPoint("RIGHT", content, "RIGHT", -2, 0)
        nameBg:SetHeight(20)
        nameBg:SetColorTexture(cr * 0.10, cg * 0.10, cb * 0.10, 0.50)

        -- Class accent strip on left
        local classStrip = PoolTexture(content, "ARTWORK")
        classStrip:SetPoint("TOPLEFT", nameBg, "TOPLEFT", 0, 0)
        classStrip:SetPoint("BOTTOMLEFT", nameBg, "BOTTOMLEFT", 0, 0)
        classStrip:SetWidth(3)
        classStrip:SetColorTexture(cr, cg, cb, 0.70)

        local hdr = PoolFontString(content, "OVERLAY")
        hdr:SetFont(FONT_FILE, 11, "OUTLINE")
        hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 12, y)
        local sr, sg, sb = Utils.GetScoreColor(p.score)
        hdr:SetText(classHex .. p.name .. "|r  " .. string.format("|cff%02x%02x%02x%d|r", sr*255, sg*255, sb*255, p.score))
        y = y - 20

        -- Compute breakdown
        local bd = Scoring.CalcCadenceBreakdown(p, allPlayersLookup, breakdownContentType, breakdownCtx)
        if not bd then
            y = AddStatLine(content, y, "  No data", "", C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
        elseif not bd.hasMeterData then
            -- Engagement-only fallback
            local lost = bd.engagement.lost
            if lost > 0.5 then
                y = AddStatLine(content, y, "  Engagement", string.format("-%.0f pts", lost), 1, 0.4, 0.2)
                if p.apm < 20 then
                    y = AddStatLine(content, y, "    \226\134\179 Low APM", Utils.FormatAPM(p.apm), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
                end
                if p.uptime < 80 then
                    y = AddStatLine(content, y, "    \226\134\179 Low uptime", Utils.FormatPercent(p.uptime), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
                end
                if p.deaths > 0 then
                    y = AddStatLine(content, y, "    \226\134\179 Deaths", tostring(p.deaths), 1, 0.3, 0.3)
                end
            else
                y = AddStatLine(content, y, "  Perfect!", "No points lost", 0.2, 1.0, 0.2)
            end
            y = AddStatLine(content, y, "  (no meter data)", "engagement only", C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
        else
            -- Full cadence breakdown — show components sorted by points lost
            local comps = {}
            local inactiveComps = {}
            local function AddComp(key, label, comp)
                if not comp then return end
                if comp.active == false then
                    inactiveComps[#inactiveComps + 1] = { key = key, label = label }
                elseif comp.weight > 0 then
                    comps[#comps + 1] = { key = key, label = label, lost = comp.lost, raw = comp.raw, weight = comp.weight }
                end
            end
            AddComp("output", bd.output.label or "Output", bd.output)
            AddComp("utility", "Utility", bd.utility)
            AddComp("avoidable", "Avoidable Dmg", bd.avoidable)
            AddComp("deaths", "Deaths", bd.deaths)
            AddComp("engagement", "Engagement", bd.engagement)

            -- Sort by points lost descending (biggest losses first)
            table.sort(comps, function(a, b) return a.lost > b.lost end)

            local totalLost = 0
            local anyShown = false
            for _, c in ipairs(comps) do
                if c.lost > 0.5 then
                    anyShown = true
                    totalLost = totalLost + c.lost
                    local pctWeight = math.floor(c.weight * 100)
                    local lostR, lostG, lostB = 1, 0.4, 0.2
                    if c.lost >= 15 then lostR, lostG, lostB = 1, 0.2, 0.2
                    elseif c.lost <= 3 then lostR, lostG, lostB = 1, 0.7, 0.3 end
                    y = AddStatLine(content, y,
                        string.format("  %s (%d%%)", c.label, pctWeight),
                        string.format("-%.0f pts  (%.0f/100)", c.lost, c.raw),
                        lostR, lostG, lostB)

                    -- Actionable hints for the biggest losses
                    if c.key == "output" and c.lost > 5 then
                        local role = p.role or "DAMAGER"
                        if role == "HEALER" then
                            y = AddStatLine(content, y, "    \226\134\179 HPS", Utils.FormatThroughput(p.hps) .. " vs group avg", C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
                        else
                            y = AddStatLine(content, y, "    \226\134\179 DPS", Utils.FormatThroughput(p.dps) .. " vs group avg", C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
                        end
                    elseif c.key == "deaths" and c.lost > 0.5 then
                        y = AddStatLine(content, y, "    \226\134\179 Died", string.format("%dx (-25 per death)", p.deaths), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
                    elseif c.key == "avoidable" and c.lost > 5 then
                        y = AddStatLine(content, y, "    \226\134\179 Took", Utils.FormatThroughput(p.avoidableDamage) .. " avoidable", C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
                    elseif c.key == "utility" and c.lost > 5 then
                        local extCount = (p.externals or 0) + (p.raidCds or 0)
                        local suppCount = p.support or 0
                        local ccCount = p.cc or 0
                        local utilTotal = (p.interrupts or 0) + (p.dispels or 0) + extCount + suppCount + ccCount
                        local parts = {}
                        if extCount > 0 then parts[#parts+1] = extCount .. " def" end
                        if suppCount > 0 then parts[#parts+1] = suppCount .. " sup" end
                        if ccCount > 0 then parts[#parts+1] = ccCount .. " cc" end
                        local hint = string.format("%d total", utilTotal)
                        if #parts > 0 then
                            hint = hint .. " (" .. table.concat(parts, ", ") .. ")"
                        end
                        y = AddStatLine(content, y, "    \226\134\179 Utility", hint, C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
                    elseif c.key == "engagement" and c.lost > 5 then
                        y = AddStatLine(content, y, "    \226\134\179 APM / Uptime", Utils.FormatAPM(p.apm) .. " / " .. Utils.FormatPercent(p.uptime), C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
                    end
                end
            end

            if not anyShown then
                y = AddStatLine(content, y, "  Perfect!", "No points lost", 0.2, 1.0, 0.2)
            end

            -- Show inactive (not-scored) metrics
            for _, ic in ipairs(inactiveComps) do
                y = AddStatLine(content, y,
                    string.format("  %s", ic.label),
                    "N/A this encounter",
                    C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
            end
        end

        y = y - 14
    end

    -- Set content height
    content:SetHeight(math.abs(y) + 20)

    f:Show()
end

---------------------------------------------------------------------------
-- Quick show from the most recent segment
---------------------------------------------------------------------------
function Summary.ShowLatest()
    local count = Segments.GetCount()
    if count == 0 then
        print("|cffffffffCad|r|cffFFD666ence|r: No segments to show.")
        return
    end
    local seg = Segments.GetSegment(1)
    if seg then
        Summary.Populate(seg)
    end
end

---------------------------------------------------------------------------
-- Show for a specific segment index
---------------------------------------------------------------------------
function Summary.ShowSegment(idx)
    local seg = Segments.GetSegment(idx)
    if seg then
        Summary.Populate(seg)
    else
        print("|cffffffffCad|r|cffFFD666ence|r: Segment " .. idx .. " not found.")
    end
end

---------------------------------------------------------------------------
-- Hide
---------------------------------------------------------------------------
function Summary.Hide()
    if summaryFrame then
        summaryFrame:Hide()
    end
end

---------------------------------------------------------------------------
-- Toggle
---------------------------------------------------------------------------
function Summary.Toggle()
    if summaryFrame and summaryFrame:IsShown() then
        Summary.Hide()
    else
        Summary.ShowLatest()
    end
end

PC.UI_Summary = Summary

--[[
    Cadence - Options.lua
    Interface options panel for WoW Midnight (12.0+).
    Uses only raw frame construction — no deprecated templates.
]]

local ADDON_NAME, PC = ...

PC.Options = {}
local Options = PC.Options
local Utils = PC.Utils

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local optionsPanel = nil

---------------------------------------------------------------------------
-- Init (deferred to avoid Midnight addon restriction taint)
---------------------------------------------------------------------------
function Options.Init()
    -- Don't create at login — create on first open to avoid taint
end

---------------------------------------------------------------------------
-- Open the options panel (standalone, no Settings API)
---------------------------------------------------------------------------
function Options.Open()
    if not optionsPanel then
        Options.CreatePanel()
    end
    if optionsPanel:IsShown() then
        optionsPanel:Hide()
    else
        optionsPanel:Show()
    end
end

---------------------------------------------------------------------------
-- UI helpers (no deprecated templates)
---------------------------------------------------------------------------
local FONT = "Fonts\\FRIZQT__.TTF"

-- ── Premium color palette (matches cadence.gg tokens) ─────
local C_VOID          = { 0.035, 0.035, 0.059 }
local C_OBSIDIAN      = { 0.067, 0.067, 0.094 }
local C_SLATE         = { 0.098, 0.098, 0.133 }
local C_GOLD_BRIGHT   = { 1.00, 0.84, 0.40 }
local C_GOLD          = { 0.85, 0.66, 0.15 }
local C_GOLD_DIM      = { 0.65, 0.49, 0.10 }
local C_TEXT_BRIGHT   = { 0.94, 0.94, 0.96 }
local C_TEXT_STD      = { 0.72, 0.72, 0.80 }
local C_TEXT_MUTED    = { 0.49, 0.49, 0.60 }
local C_ERROR         = { 0.97, 0.44, 0.44 }

local function CreateLabel(parent, text, x, y, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function CreateSectionHeader(parent, text, x, y)
    -- Section background bar
    local bg = parent:CreateTexture(nil, "ARTWORK")
    bg:SetPoint("TOPLEFT", parent, "TOPLEFT", x - 4, y + 4)
    bg:SetSize(480, 22)
    bg:SetColorTexture(C_SLATE[1], C_SLATE[2], C_SLATE[3], 0.70)

    -- Gold accent on left
    local accent = parent:CreateTexture(nil, "ARTWORK", nil, 1)
    accent:SetPoint("TOPLEFT", bg, "TOPLEFT", 0, 0)
    accent:SetSize(3, 22)
    accent:SetColorTexture(C_GOLD[1], C_GOLD[2], C_GOLD[3], 0.80)

    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, 11, "OUTLINE")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 6, y)
    fs:SetText(text)
    fs:SetTextColor(C_GOLD_BRIGHT[1], C_GOLD_BRIGHT[2], C_GOLD_BRIGHT[3])
    return fs
end

local function CreateCheckbox(parent, label, dbKey, x, y)
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    -- Textures
    cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")

    -- Label (premium text color)
    local text = cb:CreateFontString(nil, "OVERLAY")
    text:SetFont(FONT, 12, "")
    text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    text:SetText(label)
    text:SetTextColor(C_TEXT_STD[1], C_TEXT_STD[2], C_TEXT_STD[3])
    cb.labelText = text

    -- Init
    local db = PC.db and PC.db.profile
    if db then
        cb:SetChecked(db[dbKey] or false)
    end

    cb:SetScript("OnClick", function(self)
        if PC.db and PC.db.profile then
            PC.db.profile[dbKey] = self:GetChecked() and true or false
        end
    end)

    return cb
end

local function CreateSlider(parent, label, dbTable, dbKey, minVal, maxVal, step, x, y)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 50)
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    -- Label (gold tinted)
    local titleText = container:CreateFontString(nil, "OVERLAY")
    titleText:SetFont(FONT, 11, "")
    titleText:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    titleText:SetText(label)
    titleText:SetTextColor(C_GOLD_DIM[1], C_GOLD_DIM[2], C_GOLD_DIM[3])

    -- Slider
    local slider = CreateFrame("Slider", nil, container, "BackdropTemplate")
    slider:SetSize(200, 16)
    slider:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -4)
    slider:SetOrientation("HORIZONTAL")
    slider:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)

    -- Get current value
    local current = 0
    if dbTable and PC.db and PC.db.profile then
        local tbl = PC.db.profile[dbTable]
        if tbl and tbl[dbKey] ~= nil then
            current = tbl[dbKey]
        end
    elseif PC.db and PC.db.profile and PC.db.profile[dbKey] ~= nil then
        current = PC.db.profile[dbKey]
    end
    slider:SetValue(current)

    -- Min / max labels (muted)
    local minText = slider:CreateFontString(nil, "OVERLAY")
    minText:SetFont(FONT, 10, "")
    minText:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -1)
    minText:SetText(tostring(minVal))
    minText:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])

    local maxText = slider:CreateFontString(nil, "OVERLAY")
    maxText:SetFont(FONT, 10, "")
    maxText:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -1)
    maxText:SetText(tostring(maxVal))
    maxText:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])

    -- Value readout (bright text)
    local valText = container:CreateFontString(nil, "OVERLAY")
    valText:SetFont(FONT, 11, "")
    valText:SetPoint("LEFT", slider, "RIGHT", 8, 0)
    valText:SetTextColor(C_TEXT_BRIGHT[1], C_TEXT_BRIGHT[2], C_TEXT_BRIGHT[3])
    valText:SetText(string.format(step < 1 and "%.2f" or "%.0f", current))

    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value / step + 0.5) * step
        valText:SetText(string.format(step < 1 and "%.2f" or "%.0f", value))
        if PC.db and PC.db.profile then
            if dbTable then
                if PC.db.profile[dbTable] then
                    PC.db.profile[dbTable][dbKey] = value
                end
            else
                PC.db.profile[dbKey] = value
            end
        end
        -- Update runtime role baselines
        if dbTable == "roleAPM" and PC.ROLE_EXPECTED_APM then
            PC.ROLE_EXPECTED_APM[dbKey] = value
        end
    end)

    return container
end

---------------------------------------------------------------------------
-- Build the options panel
---------------------------------------------------------------------------
function Options.CreatePanel()
    local panel = CreateFrame("Frame", "CadenceOptionsPanel", UIParent, "BackdropTemplate")
    panel:SetSize(520, 600)
    panel:SetPoint("CENTER")
    panel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetBackdropColor(C_VOID[1], C_VOID[2], C_VOID[3], 0.98)
    panel:SetBackdropBorderColor(C_GOLD_DIM[1], C_GOLD_DIM[2], C_GOLD_DIM[3], 0.40)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:Hide()
    optionsPanel = panel

    -- ── Title bar (obsidian surface) ──────────────────────────
    panel.titleBg = panel:CreateTexture(nil, "ARTWORK")
    panel.titleBg:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
    panel.titleBg:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4)
    panel.titleBg:SetHeight(36)
    panel.titleBg:SetColorTexture(C_OBSIDIAN[1], C_OBSIDIAN[2], C_OBSIDIAN[3], 0.95)

    -- Gold accent line under title
    panel.titleAccent = panel:CreateTexture(nil, "ARTWORK", nil, 1)
    panel.titleAccent:SetPoint("BOTTOMLEFT", panel.titleBg, "BOTTOMLEFT", 0, 0)
    panel.titleAccent:SetPoint("BOTTOMRIGHT", panel.titleBg, "BOTTOMRIGHT", 0, 0)
    panel.titleAccent:SetHeight(2)
    panel.titleAccent:SetColorTexture(C_GOLD[1], C_GOLD[2], C_GOLD[3], 0.50)

    -- Brand mark
    panel.brandText = panel:CreateFontString(nil, "OVERLAY")
    panel.brandText:SetFont(FONT, 9, "OUTLINE")
    panel.brandText:SetPoint("TOPLEFT", panel.titleBg, "TOPLEFT", 12, -6)
    panel.brandText:SetTextColor(C_GOLD_DIM[1], C_GOLD_DIM[2], C_GOLD_DIM[3])
    panel.brandText:SetText("|cffffffffCAD|r|cffFFD666ENCE|r")

    -- Title text
    panel.titleText = panel:CreateFontString(nil, "OVERLAY")
    panel.titleText:SetFont(FONT, 13, "OUTLINE")
    panel.titleText:SetPoint("BOTTOMLEFT", panel.titleBg, "BOTTOMLEFT", 12, 6)
    panel.titleText:SetTextColor(C_TEXT_BRIGHT[1], C_TEXT_BRIGHT[2], C_TEXT_BRIGHT[3])
    panel.titleText:SetText("Options")

    -- Version badge
    panel.versionText = panel:CreateFontString(nil, "OVERLAY")
    panel.versionText:SetFont(FONT, 9, "OUTLINE")
    panel.versionText:SetPoint("BOTTOMRIGHT", panel.titleBg, "BOTTOMRIGHT", -12, 8)
    panel.versionText:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    panel.versionText:SetText("v" .. (PC.VERSION or "1.0"))

    -- ── Close button (custom ×) ──────────────────────────────
    local closeBtn = CreateFrame("Button", nil, panel)
    closeBtn:SetSize(26, 26)
    closeBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -8)
    closeBtn.text = closeBtn:CreateFontString(nil, "OVERLAY")
    closeBtn.text:SetFont(FONT, 16, "OUTLINE")
    closeBtn.text:SetPoint("CENTER")
    closeBtn.text:SetText("×")
    closeBtn.text:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    closeBtn:SetScript("OnClick", function() panel:Hide() end)
    closeBtn:SetScript("OnEnter", function(self)
        self.text:SetTextColor(C_ERROR[1], C_ERROR[2], C_ERROR[3])
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self.text:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    end)

    -- Escape closes the panel
    tinsert(UISpecialFrames, "CadenceOptionsPanel")

    -- Scroll container so all options are accessible.
    -- Anchor BELOW the title bar (titleBg inset 4 + height 36 = 40) plus a
    -- small visual gap, so scrolled content never overlaps the header.
    local scrollParent = CreateFrame("Frame", nil, panel)
    scrollParent:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -44)
    scrollParent:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
    scrollParent:SetClipsChildren(true)

    local content = CreateFrame("Frame", nil, scrollParent)
    content:SetSize(500, 1200)
    content:SetPoint("TOPLEFT", scrollParent, "TOPLEFT", 0, 0)

    -- Enable mouse wheel scrolling
    local scrollOffset = 0
    scrollParent:EnableMouseWheel(true)
    scrollParent:SetScript("OnMouseWheel", function(self, delta)
        scrollOffset = scrollOffset - delta * 30
        scrollOffset = math.max(0, math.min(scrollOffset, 900))
        content:SetPoint("TOPLEFT", scrollParent, "TOPLEFT", 0, scrollOffset)
    end)

    -------------------------------------------------------------------
    -- Title
    -------------------------------------------------------------------
    -- Title is now rendered by the premium title bar above
    -- Just a subtitle below for context
    local subtitle = content:CreateFontString(nil, "OVERLAY")
    subtitle:SetFont(FONT, 10, "")
    subtitle:SetPoint("TOPLEFT", content, "TOPLEFT", 16, -16)
    subtitle:SetText("Player activity and engagement meter")
    subtitle:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])

    local y = -44

    -------------------------------------------------------------------
    -- General
    -------------------------------------------------------------------
    CreateSectionHeader(content, "General", 16, y)
    y = y - 24
    CreateCheckbox(content, "Lock window position", "locked", 16, y)
    y = y - 28
    CreateCheckbox(content, "Auto-show in combat", "autoShowInCombat", 16, y)
    y = y - 28
    CreateCheckbox(content, "Auto-segment trash pulls", "autoSegmentTrash", 16, y)
    y = y - 28
    CreateCheckbox(content, "Show Cadence scores in Group Finder", "lfgOverlay", 16, y)
    y = y - 44

    -------------------------------------------------------------------
    -- Display
    -------------------------------------------------------------------
    CreateSectionHeader(content, "Display", 16, y)
    y = y - 28
    CreateSlider(content, "Bar Height", nil, "barHeight", 14, 30, 1, 16, y)
    y = y - 54
    CreateSlider(content, "Max Rows", nil, "maxRows", 5, 40, 1, 16, y)
    y = y - 54
    CreateSlider(content, "Font Size", nil, "fontSize", 8, 16, 1, 16, y)
    y = y - 54
    CreateSlider(content, "Update Interval (sec)", nil, "updateInterval", 0.2, 2.0, 0.1, 16, y)
    y = y - 60

    -------------------------------------------------------------------
    -- AFK Detection Thresholds
    -------------------------------------------------------------------
    CreateSectionHeader(content, "AFK Detection Thresholds", 16, y)
    y = y - 28
    CreateSlider(content, "AFK APM Threshold", "thresholds", "afkAPM", 1, 15, 1, 16, y)
    y = y - 54
    CreateSlider(content, "Warning APM Threshold", "thresholds", "warningAPM", 3, 20, 1, 16, y)
    y = y - 54
    CreateSlider(content, "Long Gap (sec)", "thresholds", "longGapSec", 3, 30, 1, 16, y)
    y = y - 54
    CreateSlider(content, "Active Gap Max (sec)", "thresholds", "activeGapMax", 1.0, 5.0, 0.5, 16, y)

end

PC.Options = Options

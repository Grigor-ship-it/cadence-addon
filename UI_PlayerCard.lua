--[[
    Cadence — UI_PlayerCard.lua
    "View Cadence" detailed player popup.

    Adds a "View Cadence" entry to player right-click menus (party, raid,
    friend list, target, focus, guild, chat) and renders a detailed card
    for that player using server-attested data from CadenceRewardsDB
    (the daily-synced Lua file, same model as RaiderIO).

    Data source: CadenceRewardsDB (local SavedVariables-style file).
    Server-attested. Unspoofable. No HTTP requests (addons can't make any).
]]

local ADDON_NAME, PC = ...

PC.UI_PlayerCard = {}
local PlayerCard = PC.UI_PlayerCard
local RT = PC.RewardTiers

---------------------------------------------------------------------------
-- Color helpers
---------------------------------------------------------------------------
local C_BRAND = "|cffd9a826"           -- Cadence gold
local C_BRAND2= "|cffffffff"
local C_MUTED = "|cff7a7a99"
local C_DIM   = "|cff9c9cb1"
local C_WHITE = "|cffffffff"
local C_GREEN = "|cff1eff00"
local C_RED   = "|cffff4444"
local C_GOLD  = "|cffffd666"

-- Convert "rrggbb" hex string into 0-1 RGB triplet.
local function HexToRGB(hex)
    if not hex or #hex < 6 then return 1, 1, 1 end
    local r = tonumber(hex:sub(1, 2), 16) or 255
    local g = tonumber(hex:sub(3, 4), 16) or 255
    local b = tonumber(hex:sub(5, 6), 16) or 255
    return r / 255, g / 255, b / 255
end

-- Try to resolve the WoW class color for a player who happens to be in
-- our roster (party / raid / friend / target).  Falls back to white.
local function GetClassColor(name, realm)
    if not name then return 1, 1, 1 end
    local fullName = realm and (name .. "-" .. realm) or name
    local _, class
    if UnitExists(name) and UnitIsPlayer(name) then
        _, class = UnitClass(name)
    elseif UnitExists(fullName) and UnitIsPlayer(fullName) then
        _, class = UnitClass(fullName)
    end
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        return c.r, c.g, c.b
    end
    return 1, 1, 1
end

---------------------------------------------------------------------------
-- Data lookup
---------------------------------------------------------------------------
local function GetData(name, realm)
    if not CadenceRewardsDB then return nil end
    if not name or name == "" then return nil end
    if not realm or realm == "" then realm = GetNormalizedRealmName() end
    -- realm in DB is the display name; try a few normalisations
    local key = name .. "-" .. realm
    local d = CadenceRewardsDB[key]
    if d then return d, key end
    -- Try collapsing spaces (Moon Guard -> MoonGuard)
    local collapsed = realm:gsub("%s+", "")
    if collapsed ~= realm then
        key = name .. "-" .. collapsed
        d = CadenceRewardsDB[key]
        if d then return d, key end
    end
    return nil
end

---------------------------------------------------------------------------
-- The popup frame (singleton, reused per lookup)
---------------------------------------------------------------------------
local card

-- Cadence palette (matches the in-game meter / summary popups)
local BG_R, BG_G, BG_B, BG_A         = 0.04, 0.04, 0.06, 0.96
local BORDER_R, BORDER_G, BORDER_B   = 0.85, 0.66, 0.15  -- Cadence gold
local TITLEBAR_R, TITLEBAR_G, TITLEBAR_B, TITLEBAR_A = 0.08, 0.08, 0.11, 1.0
local DIVIDER_R, DIVIDER_G, DIVIDER_B, DIVIDER_A     = 0.85, 0.66, 0.15, 0.35

local CARD_W, CARD_H = 380, 480
local TITLEBAR_H     = 28
local PAD_X          = 16

-- Helper: thin horizontal divider line
local function MakeDivider(parent, anchorTo, yOffset)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(DIVIDER_R, DIVIDER_G, DIVIDER_B, DIVIDER_A)
    line:SetHeight(1)
    line:SetPoint("LEFT",  parent, "LEFT",  PAD_X, 0)
    line:SetPoint("RIGHT", parent, "RIGHT", -PAD_X, 0)
    line:SetPoint("TOP",   anchorTo, "BOTTOM", 0, yOffset or -8)
    return line
end

-- Helper: small section header label
local function MakeSectionHeader(parent, text, anchorTo, yOffset)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetText(text)
    fs:SetTextColor(BORDER_R, BORDER_G, BORDER_B, 1)
    fs:SetJustifyH("LEFT")
    fs:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOffset or -8)
    return fs
end

local function EnsureCard()
    if card then return card end

    local f = CreateFrame("Frame", "CadencePlayerCard", UIParent, "BackdropTemplate")
    f:SetSize(CARD_W, CARD_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:Hide()

    -- ── Backdrop: dark panel with subtle gold border ─────────
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
            insets   = { left = 0, right = 0, top = 0, bottom = 0 },
        })
        f:SetBackdropColor(BG_R, BG_G, BG_B, BG_A)
        f:SetBackdropBorderColor(BORDER_R, BORDER_G, BORDER_B, 0.7)
    end

    -- Outer drop shadow (subtle dark glow around the panel)
    local shadow = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    shadow:SetTexture("Interface\\Buttons\\WHITE8x8")
    shadow:SetVertexColor(0, 0, 0, 0.55)
    shadow:SetPoint("TOPLEFT",     -6, 6)
    shadow:SetPoint("BOTTOMRIGHT",  6, -6)

    -- ── Title bar (compact gold underline strip) ─────────────
    local titlebar = f:CreateTexture(nil, "ARTWORK")
    titlebar:SetTexture("Interface\\Buttons\\WHITE8x8")
    titlebar:SetVertexColor(TITLEBAR_R, TITLEBAR_G, TITLEBAR_B, TITLEBAR_A)
    titlebar:SetPoint("TOPLEFT",  1, -1)
    titlebar:SetPoint("TOPRIGHT", -1, -1)
    titlebar:SetHeight(TITLEBAR_H)

    local titleUnderline = f:CreateTexture(nil, "OVERLAY")
    titleUnderline:SetTexture("Interface\\Buttons\\WHITE8x8")
    titleUnderline:SetVertexColor(BORDER_R, BORDER_G, BORDER_B, 0.6)
    titleUnderline:SetHeight(1)
    titleUnderline:SetPoint("TOPLEFT",  titlebar, "BOTTOMLEFT",  0, 0)
    titleUnderline:SetPoint("TOPRIGHT", titlebar, "BOTTOMRIGHT", 0, 0)

    local brand = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    brand:SetPoint("LEFT", titlebar, "LEFT", PAD_X, 0)
    brand:SetText(C_BRAND .. "CAD|r" .. C_BRAND2 .. "ENCE|r  " .. C_DIM .. "Player Card|r")
    f.brand = brand

    -- Allow drag from anywhere on the title bar
    local dragArea = CreateFrame("Frame", nil, f)
    dragArea:SetAllPoints(titlebar)
    dragArea:EnableMouse(true)
    dragArea:RegisterForDrag("LeftButton")
    dragArea:SetScript("OnDragStart", function() f:StartMoving() end)
    dragArea:SetScript("OnDragStop",  function() f:StopMovingOrSizing() end)

    -- Close button
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -2, -2)

    -- ── Header block: name (large, class-colored) + title tier ─────
    local nameFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    nameFS:SetPoint("TOPLEFT", PAD_X, -(TITLEBAR_H + 14))
    nameFS:SetJustifyH("LEFT")
    do
        local font, _, flags = nameFS:GetFont()
        if font then nameFS:SetFont(font, 19, flags) end
    end
    f.nameFS = nameFS

    local realmFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    realmFS:SetPoint("TOPLEFT", nameFS, "BOTTOMLEFT", 0, -1)
    realmFS:SetTextColor(0.6, 0.6, 0.7, 1)
    f.realmFS = realmFS

    local titleFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("TOPLEFT", realmFS, "BOTTOMLEFT", 0, -3)
    titleFS:SetJustifyH("LEFT")
    f.titleFS = titleFS

    -- Big score, top-right inside its own pill
    local scorePill = f:CreateTexture(nil, "ARTWORK")
    scorePill:SetTexture("Interface\\Buttons\\WHITE8x8")
    scorePill:SetVertexColor(0.10, 0.10, 0.13, 0.9)
    scorePill:SetSize(96, 64)
    scorePill:SetPoint("TOPRIGHT", -PAD_X, -(TITLEBAR_H + 10))
    f.scorePill = scorePill

    local scorePillBorder = f:CreateTexture(nil, "OVERLAY")
    scorePillBorder:SetTexture("Interface\\Buttons\\WHITE8x8")
    scorePillBorder:SetVertexColor(BORDER_R, BORDER_G, BORDER_B, 0.45)
    scorePillBorder:SetSize(96, 1)
    scorePillBorder:SetPoint("BOTTOMLEFT",  scorePill, "BOTTOMLEFT",  0, 0)
    scorePillBorder:SetPoint("BOTTOMRIGHT", scorePill, "BOTTOMRIGHT", 0, 0)

    local scoreFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    do
        local font, _, flags = scoreFS:GetFont()
        if font then scoreFS:SetFont(font, 36, flags or "OUTLINE") end
    end
    scoreFS:SetPoint("CENTER", scorePill, "CENTER", 0, 4)
    f.scoreFS = scoreFS

    local scoreLabel = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    scoreLabel:SetText("CADENCE SCORE")
    scoreLabel:SetTextColor(0.55, 0.55, 0.65, 1)
    scoreLabel:SetPoint("BOTTOM", scorePill, "BOTTOM", 0, 4)
    f.scoreLabel = scoreLabel

    -- ── Divider after header block ───────────────────────────
    local headerDivider = MakeDivider(f, titleFS, -10)
    f.headerDivider = headerDivider

    -- ── Stats section (anchored under the divider) ───────────
    local statsHeader = MakeSectionHeader(f, "PROFILE", headerDivider, -8)
    f.statsHeader = statsHeader

    local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT",  statsHeader, "BOTTOMLEFT", 0, -6)
    body:SetPoint("RIGHT", f, "RIGHT", -PAD_X, 0)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetSpacing(5)
    f.body = body

    -- ── Footer (with thin divider above) ─────────────────────
    local footerDivider = f:CreateTexture(nil, "ARTWORK")
    footerDivider:SetColorTexture(DIVIDER_R, DIVIDER_G, DIVIDER_B, DIVIDER_A)
    footerDivider:SetHeight(1)
    footerDivider:SetPoint("BOTTOMLEFT",  PAD_X, 26)
    footerDivider:SetPoint("BOTTOMRIGHT", -PAD_X, 26)

    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT",  PAD_X, 10)
    footer:SetPoint("BOTTOMRIGHT", -PAD_X, 10)
    footer:SetJustifyH("LEFT")
    footer:SetTextColor(0.55, 0.55, 0.65, 1)
    f.footer = footer

    -- ESC closes
    tinsert(UISpecialFrames, "CadencePlayerCard")

    card = f
    return f
end

---------------------------------------------------------------------------
-- Render content into the card
---------------------------------------------------------------------------
local function RenderEmpty(f, name, realm)
    local cr, cg, cb = GetClassColor(name, realm)
    f.nameFS:SetText(name or "?")
    f.nameFS:SetTextColor(cr, cg, cb, 1)
    f.realmFS:SetText(realm or "?")
    f.titleFS:SetText(C_MUTED .. "No Cadence data yet|r")
    f.scoreFS:SetText("--")
    f.scoreFS:SetTextColor(0.5, 0.5, 0.55, 1)
    f.statsHeader:SetText("WHY")
    f.body:SetText(
        C_DIM .. "We don't have any server-attested encounters for this player.|r\n\n" ..
        C_WHITE .. "How to fix it:|r\n" ..
        " " .. C_GOLD .. "•|r Ask them to scan a Cadence QR code\n" ..
        " " .. C_GOLD .. "•|r Or run a key/raid with them and submit it yourself\n\n" ..
        C_MUTED .. "Cadence only shows players whose data has been corroborated by Blizzard's API + 2+ independent reports.|r"
    )
    f.footer:SetText("Source: CadenceRewardsDB " .. ((CADENCE_REWARDS_REGION or "?")):upper() .. "  •  No record found")
end

-- Two-column "Label  ........  Value" line.
local function FmtRow(label, value)
    return ("%s%s|r   %s%s|r"):format(C_DIM, label, C_WHITE, value)
end

local function RenderData(f, name, realm, data)
    -- Only fields we actually ship in CadenceRewardsDB now: s, c, n, u.
    -- Anything richer (per-role, badges, history, contribution count,
    -- self-sufficiency, carried ratio) lives on the website profile page
    -- — keeps the addon seed file small and the UI focused.
    local avgScore  = data.s or 0
    local totalRuns = data.n or 0
    local updated   = data.u or "?"

    local titleTier = RT.GetTitleForScore(avgScore)
    local confTier  = RT.GetConfidenceTier(totalRuns)

    -- ── Header: class-colored name + realm ───────────────────
    local cr, cg, cb = GetClassColor(name, realm)
    f.nameFS:SetText(name)
    f.nameFS:SetTextColor(cr, cg, cb, 1)
    f.realmFS:SetText(realm)
    f.titleFS:SetText("")  -- no separate title row in the minimal layout

    -- ── Big score (colored by tier) ──────────────────────────
    f.scoreFS:SetText(("%.1f"):format(avgScore))
    local sr, sg, sb = HexToRGB(titleTier.color)
    f.scoreFS:SetTextColor(sr, sg, sb, 1)

    -- ── Body ─────────────────────────────────────────────────
    f.statsHeader:SetText("PROFILE")
    local lines = {}
    table.insert(lines, FmtRow("Confidence",
        ("|cff%s%s|r"):format(confTier.color, confTier.label)))
    table.insert(lines, FmtRow("Encounters analyzed", tostring(totalRuns)))
    table.insert(lines, "")
    table.insert(lines, C_DIM .. "Full breakdown — per role, history, badges,|r")
    table.insert(lines, C_DIM .. "and detailed scoring — at " .. C_BRAND .. "cadence.gg|r")
    f.body:SetText(table.concat(lines, "\n"))

    -- ── Footer ───────────────────────────────────────────────
    f.footer:SetText(("Source: CadenceRewardsDB %s  •  Updated %s  •  Server-attested"):format(
        ((CADENCE_REWARDS_REGION or "?")):upper(), updated
    ))
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function PlayerCard.Show(name, realm)
    if not name or name == "" then
        print("|cffffffffCad|r|cffFFD666ence|r: No player specified.")
        return
    end
    if not realm or realm == "" then realm = GetNormalizedRealmName() end

    local f = EnsureCard()
    local data = GetData(name, realm)
    if data then
        RenderData(f, name, realm, data)
    else
        RenderEmpty(f, name, realm)
    end
    f:Show()
    f:Raise()
end

function PlayerCard.ShowForUnit(unit)
    if not unit or not UnitExists(unit) then return end
    local _, _, _, _, _, _, classification = nil
    if not UnitIsPlayer(unit) then
        print("|cffffffffCad|r|cffFFD666ence|r: That's not a player.")
        return
    end
    local name, realm = UnitName(unit)
    if not realm or realm == "" then realm = GetNormalizedRealmName() end
    PlayerCard.Show(name, realm)
end

function PlayerCard.Hide()
    if card then card:Hide() end
end

function PlayerCard.Toggle(name, realm)
    if card and card:IsShown() then
        card:Hide()
    else
        PlayerCard.Show(name, realm)
    end
end

---------------------------------------------------------------------------
-- Right-click menu integration (retail Menu API, 11.0+)
-- Adds "View Cadence" to player unit popups: party, raid, friend, target,
-- focus, guild, chat, etc.
---------------------------------------------------------------------------
local MENU_TAGS = {
    "MENU_UNIT_PARTY",
    "MENU_UNIT_RAID_PLAYER",
    "MENU_UNIT_RAID",
    "MENU_UNIT_PLAYER",
    "MENU_UNIT_FRIEND",
    "MENU_UNIT_BN_FRIEND",
    "MENU_UNIT_GUILD",
    "MENU_UNIT_GUILD_OFFLINE",
    "MENU_UNIT_TARGET",
    "MENU_UNIT_FOCUS",
    "MENU_UNIT_SELF",
    "MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
    "MENU_UNIT_COMMUNITIES_WOW_MEMBER",
    "MENU_UNIT_CHAT_ROSTER",
    "MENU_UNIT_WHO_LIST",
}

local function AddMenuEntry(_, rootDescription, contextData)
    if not rootDescription or not rootDescription.CreateButton then return end
    if not contextData then return end

    -- Resolve name + realm from context
    local name = contextData.name
    local realm = contextData.server
    -- Some contexts use unit instead
    if (not name or name == "") and contextData.unit and UnitExists(contextData.unit) and UnitIsPlayer(contextData.unit) then
        name, realm = UnitName(contextData.unit)
    end
    if not name or name == "" then return end
    if not realm or realm == "" then realm = GetNormalizedRealmName() end

    rootDescription:CreateDivider()
    rootDescription:CreateTitle(C_BRAND .. "Cadence|r")
    rootDescription:CreateButton("View Cadence", function()
        PlayerCard.Show(name, realm)
    end)
end

local function HookMenus()
    if not Menu or not Menu.ModifyMenu then return end
    for _, tag in ipairs(MENU_TAGS) do
        -- pcall in case a tag doesn't exist on this client build
        pcall(Menu.ModifyMenu, tag, AddMenuEntry)
    end
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self)
    HookMenus()
    self:UnregisterAllEvents()
end)

PC.UI_PlayerCard = PlayerCard

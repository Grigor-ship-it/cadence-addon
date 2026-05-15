--[[
    Cadence - UI_Meter.lua
    Main meter window: bars, sorting, periodic updates.
    Premium dark theme matching cadencewow.com website aesthetic.
]]

local ADDON_NAME, PC = ...

PC.UI_Meter = {}
local UI = PC.UI_Meter
local Tracker = PC.Tracker
local Scoring = PC.Scoring
local Segments = PC.Segments
local Utils = PC.Utils

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local FONT_FILE = "Fonts\\FRIZQT__.TTF"
local BACKDROP_INFO = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local TITLE_HEIGHT = 24
local PADDING = 2

-- ── Premium color palette (matches cadencewow.com tokens) ─────
local C_VOID           = { 0.035, 0.035, 0.059, 0.98 }
local C_OBSIDIAN       = { 0.067, 0.067, 0.094, 0.95 }
local C_SLATE          = { 0.098, 0.098, 0.133, 0.90 }
local C_GOLD_BRIGHT    = { 1.00, 0.84, 0.40 }
local C_GOLD           = { 0.85, 0.66, 0.15 }
local C_GOLD_DIM       = { 0.65, 0.49, 0.10 }
local C_TEXT_BRIGHT    = { 0.94, 0.94, 0.96 }
local C_TEXT_MUTED     = { 0.49, 0.49, 0.60 }
local C_ERROR          = { 0.97, 0.44, 0.44 }
local C_SUCCESS        = { 0.20, 0.83, 0.40 }

---------------------------------------------------------------------------
-- Status label thresholds
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
-- State
---------------------------------------------------------------------------
local mainFrame = nil
local titleBar = nil
local titleText = nil
local timerText = nil
local syncText = nil
local syncTextFrame = nil
local scrollFrame = nil
local contentFrame = nil
local barRows = {}        -- array of bar row frames
local isVisible = false
local lastUpdate = 0
local sortedPlayers = {}  -- reused sort table

---------------------------------------------------------------------------
-- Init — called from Core.lua on PLAYER_LOGIN
---------------------------------------------------------------------------
function UI.Init()
    UI.CreateMainFrame()
    UI.Show()
end

---------------------------------------------------------------------------
-- Create the main meter window
---------------------------------------------------------------------------
function UI.CreateMainFrame()
    if mainFrame then return end

    local db = PC.db and PC.db.profile or {}
    local width = db.windowWidth or 280
    local height = db.windowHeight or 300
    local pos = db.windowPos or { point = "CENTER", x = 0, y = 0 }

    -- Main container — deep void background
    mainFrame = CreateFrame("Frame", "CadenceMainFrame", UIParent, "BackdropTemplate")
    mainFrame:SetSize(width, height)
    mainFrame:SetPoint(pos.point or "CENTER", UIParent, pos.point or "CENTER", pos.x or 0, pos.y or 0)
    mainFrame:SetBackdrop(BACKDROP_INFO)
    mainFrame:SetBackdropColor(C_VOID[1], C_VOID[2], C_VOID[3], C_VOID[4])
    mainFrame:SetBackdropBorderColor(C_GOLD_DIM[1], C_GOLD_DIM[2], C_GOLD_DIM[3], 0.30)
    mainFrame:SetFrameStrata("MEDIUM")
    mainFrame:SetFrameLevel(100)
    mainFrame:SetClampedToScreen(true)
    mainFrame:EnableMouse(true)
    mainFrame:SetMovable(true)
    mainFrame:SetResizable(true)

    -- Resize constraints
    if mainFrame.SetResizeBounds then
        mainFrame:SetResizeBounds(160, 100, 500, 800)
    end

    -- Drag to move
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", function(self)
        if not (PC.db and PC.db.profile and PC.db.profile.locked) then
            self:StartMoving()
        end
    end)
    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        UI.SavePosition()
    end)

    -------------------------------------------------------------------
    -- Title bar — obsidian surface with gold accent
    -------------------------------------------------------------------
    titleBar = CreateFrame("Frame", nil, mainFrame)
    titleBar:SetHeight(TITLE_HEIGHT)
    titleBar:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 3, -3)
    titleBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -3, -3)

    -- Title background
    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints(titleBar)
    titleBg:SetColorTexture(C_OBSIDIAN[1], C_OBSIDIAN[2], C_OBSIDIAN[3], 0.95)

    -- Gold accent line under title
    local titleAccent = titleBar:CreateTexture(nil, "ARTWORK", nil, 1)
    titleAccent:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    titleAccent:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    titleAccent:SetHeight(1)
    titleAccent:SetColorTexture(C_GOLD[1], C_GOLD[2], C_GOLD[3], 0.45)

    -- Title text — gold branded
    titleText = titleBar:CreateFontString(nil, "OVERLAY")
    titleText:SetFont(FONT_FILE, 10, "OUTLINE")
    titleText:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
    titleText:SetTextColor(C_GOLD_BRIGHT[1], C_GOLD_BRIGHT[2], C_GOLD_BRIGHT[3])
    titleText:SetText("Cadence")

    -- Timer / segment indicator (right side of title)
    timerText = titleBar:CreateFontString(nil, "OVERLAY")
    timerText:SetFont(FONT_FILE, 9, "OUTLINE")
    timerText:SetPoint("RIGHT", titleBar, "RIGHT", -22, 0)
    timerText:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    timerText:SetText("")

    -- Sync status badge (group-sync indicator, left of timer).
    -- Hidden when solo; shows "n/m sync" when ≥ 1 peer is running Cadence.
    -- Tooltip lists peers; click → /cadence sync printout.
    syncText = titleBar:CreateFontString(nil, "OVERLAY")
    syncText:SetFont(FONT_FILE, 9, "OUTLINE")
    syncText:SetPoint("RIGHT", timerText, "LEFT", -8, 0)
    syncText:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    syncText:SetText("")
    syncTextFrame = CreateFrame("Frame", nil, titleBar)
    syncTextFrame:SetAllPoints(syncText)
    syncTextFrame:EnableMouse(true)
    syncTextFrame:SetScript("OnEnter", function(self)
        if not PC.Comm then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        local synced, total = PC.Comm.GetSyncStatus()
        GameTooltip:AddLine("Cadence Sync", 0.95, 0.75, 0.30)
        GameTooltip:AddLine(synced .. " of " .. total .. " in this group run Cadence",
                            1, 1, 1)
        PC.Comm.ForEachPeer(function(_, p)
            GameTooltip:AddLine("  " .. (p.name or "?") .. "  v" .. (p.version or "?"),
                                0.75, 0.85, 0.95)
        end)
        if synced <= 1 then
            GameTooltip:AddLine("Group sync activates when other party/raid members install Cadence.",
                                0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end)
    syncTextFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Close button (custom × glyph)
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(16, 16)
    closeBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -5, -5)
    closeBtn.text = closeBtn:CreateFontString(nil, "OVERLAY")
    closeBtn.text:SetFont(FONT_FILE, 14, "OUTLINE")
    closeBtn.text:SetPoint("CENTER")
    closeBtn.text:SetText("×")
    closeBtn.text:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    closeBtn:SetScript("OnClick", function() UI.Hide() end)
    closeBtn:SetScript("OnEnter", function(self)
        self.text:SetTextColor(C_ERROR[1], C_ERROR[2], C_ERROR[3])
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self.text:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    end)

    -- Title bar: right-click menu
    titleBar:EnableMouse(true)
    titleBar:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" then
            UI.ShowTitleMenu()
        end
    end)

    -------------------------------------------------------------------
    -- Content area for bars (clipped)
    -------------------------------------------------------------------
    contentFrame = CreateFrame("Frame", nil, mainFrame)
    contentFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 4, -(TITLE_HEIGHT + 5))
    contentFrame:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -4, 4)
    contentFrame:SetClipsChildren(true)

    -------------------------------------------------------------------
    -- Resize grip (subtle)
    -------------------------------------------------------------------
    local resizeGrip = CreateFrame("Button", nil, mainFrame)
    resizeGrip:SetSize(14, 14)
    resizeGrip:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -2, 2)
    resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeGrip:GetNormalTexture():SetVertexColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], 0.5)
    resizeGrip:SetScript("OnMouseDown", function()
        if not (PC.db and PC.db.profile and PC.db.profile.locked) then
            mainFrame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        mainFrame:StopMovingOrSizing()
        UI.SavePosition()
        UI.UpdateLayout()
    end)

    -------------------------------------------------------------------
    -- Throttled OnUpdate for periodic refresh
    -------------------------------------------------------------------
    local gcAccum = 0                       -- accumulator for periodic GC assist
    local OOC_INTERVAL = 3                   -- out-of-combat refresh every 3 s
    local GC_STEP_INTERVAL = 15              -- GC assist every 15 s
    local GC_STEP_SIZE = 100                 -- ~100 KB worth of incremental GC work
    mainFrame:SetScript("OnUpdate", function(self, elapsed)
        lastUpdate = lastUpdate + elapsed
        gcAccum   = gcAccum + elapsed

        -- Adaptive refresh rate: fast in combat, slow out of combat
        local inCombat = PC.Events and PC.Events.IsInCombat and PC.Events.IsInCombat()
        local interval
        if inCombat then
            interval = (PC.db and PC.db.profile and PC.db.profile.updateInterval) or 0.5
        else
            interval = OOC_INTERVAL
        end

        if lastUpdate >= interval then
            lastUpdate = 0
            UI.RefreshBars()
        end

        -- Periodic incremental GC to prevent Lua memory build-up
        if gcAccum >= GC_STEP_INTERVAL then
            gcAccum = 0
            collectgarbage("step", GC_STEP_SIZE)
        end
    end)

    -- Initially hidden until we call Show
    mainFrame:Hide()
end

---------------------------------------------------------------------------
-- Save window position
---------------------------------------------------------------------------
function UI.SavePosition()
    if not mainFrame or not PC.db then return end
    local point, _, _, x, y = mainFrame:GetPoint()
    PC.db.profile.windowPos = { point = point, x = x, y = y }
    PC.db.profile.windowWidth = mainFrame:GetWidth()
    PC.db.profile.windowHeight = mainFrame:GetHeight()
end

---------------------------------------------------------------------------
-- Apply lock state
---------------------------------------------------------------------------
function UI.ApplyLock()
    -- Lock/unlock is handled dynamically in drag/resize callbacks
end

---------------------------------------------------------------------------
-- Show / Hide / Toggle
---------------------------------------------------------------------------
function UI.Show()
    if mainFrame then
        mainFrame:Show()
        isVisible = true
    end
end

function UI.Hide()
    if mainFrame then
        mainFrame:Hide()
        isVisible = false
    end
end

function UI.Toggle()
    if isVisible then
        UI.Hide()
    else
        UI.Show()
    end
end

function UI.ForceRefresh()
    lastUpdate = 999  -- triggers immediate refresh on next OnUpdate
end

---------------------------------------------------------------------------
-- Update content frame width when window resizes
---------------------------------------------------------------------------
function UI.UpdateLayout()
    if not mainFrame or not contentFrame then return end
    local w = mainFrame:GetWidth() - 30
    contentFrame:SetWidth(math.max(w, 100))
    UI.ForceRefresh()
end

---------------------------------------------------------------------------
-- Build sorted player list for display
---------------------------------------------------------------------------
local function BuildSortedPlayerList()
    Utils.WipeTable(sortedPlayers)

    local segIdx = Segments.GetActiveIndex()

    -- Always fetch live meter data for enriched scoring
    local liveMeter = nil
    local MeterData = PC.MeterData
    if MeterData and MeterData.GetLiveMeterData then
        liveMeter = MeterData.GetLiveMeterData()
    end

    if segIdx > 0 then
        -- Viewing a historical segment
        local seg = Segments.GetSegment(segIdx)
        if seg and seg.players then
            for guid, snap in pairs(seg.players) do
                sortedPlayers[#sortedPlayers + 1] = {
                    guid = guid,
                    name = snap.name or "Unknown",
                    class = snap.class or "PRIEST",
                    score = snap.cadenceScore or snap.activityScore or 0,
                    apm = snap.apm or 0,
                    actionCount = snap.actionCount or 0,
                    afkFlag = snap.afkFlag or false,
                    isHistorical = true,
                    isEnemy = snap.isEnemy or false,
                    dps = snap.dps or 0,
                    hps = snap.hps or 0,
                    damageDone = snap.damageDone or 0,
                    healingDone = snap.healingDone or 0,
                    interrupts = snap.interrupts or 0,
                    dispels = snap.dispels or 0,
                    role = snap.role or "DAMAGER",
                }
            end
        end
    else
        -- Live data — show ALL seeded players (including 0-action ones)
        local isAccumulating = Segments.IsAccumulating()

        for guid, pd in pairs(Tracker.GetAllPlayerData()) do
            local duration = Tracker.GetCombatDuration(guid)
            local intentAPM = Tracker.GetIntentAPM(guid)
            local hasActivity = pd.intentActionCount > 0 or pd.actionCount > 0

            local isPvP = PC.Events and PC.Events.IsInArena and PC.Events.IsInArena()
            local liveScore = 0
            if hasActivity then
                liveScore = isPvP and Scoring.CalcPvPCompositeScore(guid) or Scoring.CalcCompositeScore(guid)
            end

            -- Persistent score across the whole encounter/dungeon
            local persistentScore = nil
            if isAccumulating then
                persistentScore = Segments.GetPersistentScore(guid)
            end

            -- Merge live meter data
            local mDps, mHps, mDamage, mHealing, mIntrs, mDispels = 0, 0, 0, 0, 0, 0
            if liveMeter and liveMeter[guid] then
                local m = liveMeter[guid]
                mDps = m.dps or 0
                mHps = m.hps or 0
                mDamage = m.damageDone or 0
                mHealing = m.healingDone or 0
                mIntrs = m.interrupts or 0
                mDispels = m.dispels or 0
            end

            sortedPlayers[#sortedPlayers + 1] = {
                guid = guid,
                name = pd.name or "Unknown",
                class = pd.class or "PRIEST",
                score = persistentScore or liveScore,
                persistentScore = persistentScore,
                activityScore = liveScore,
                apm = intentAPM,
                actionCount = pd.intentActionCount,
                afkFlag = hasActivity and Scoring.IsAFK(guid) or false,
                isDead = Utils.IsGUIDDead(guid),
                isHistorical = false,
                isEnemy = pd.isEnemy or false,
                role = Utils.GetRoleByGUID(guid) or "DAMAGER",
                -- Meter data
                dps = mDps,
                hps = mHps,
                damageDone = mDamage,
                healingDone = mHealing,
                interrupts = mIntrs,
                dispels = mDispels,
                role = Utils.GetRoleByGUID(guid) or "DAMAGER",
            }
        end

        -- When live meter data is available, compute cadence score
        -- for each player using CalcCadenceLiveScore (group-relative)
        if liveMeter then
            -- Build a lookup of all live player entries for group-relative scoring
            local allSnaps = {}
            for _, p in ipairs(sortedPlayers) do
                if not p.isHistorical then
                    allSnaps[p.guid] = p
                end
            end
            local isPvP = PC.Events and PC.Events.IsInArena and PC.Events.IsInArena()
            local contentType = isPvP and "arena"
                or (Segments.IsInMythicPlus() and "mythicplus")
                or "raid"
            local scoreCtx = Segments.GetCurrentScoreContext and Segments.GetCurrentScoreContext() or nil
            for _, p in ipairs(sortedPlayers) do
                if not p.isHistorical and not p.persistentScore then
                    p.score = Scoring.CalcCadenceLiveScore(p, allSnaps, contentType, scoreCtx)
                end
            end
        end
    end

    -- Sort by score
    table.sort(sortedPlayers, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        -- Tiebreaker: higher throughput (role-aware) ranks higher.
        -- Defensive coercion: fields can occasionally be nil OR a tainted
        -- secret value that throws on direct comparison. Run them through
        -- tonumber + pcall to guarantee plain Lua numbers in the comparator.
        local function safeNum(v)
            if v == nil then return 0 end
            local ok, n = pcall(tonumber, v)
            if not ok or n == nil then return 0 end
            -- A secret value can survive tonumber() — probe with a no-op compare.
            local ok2 = pcall(function() return n > 0 end)
            if not ok2 then return 0 end
            return n
        end
        local aTP = (a.role == "HEALER") and safeNum(a.hps) or safeNum(a.dps)
        local bTP = (b.role == "HEALER") and safeNum(b.hps) or safeNum(b.dps)
        return aTP > bTP
    end)
end

---------------------------------------------------------------------------
-- Create or retrieve a bar row
---------------------------------------------------------------------------
local LAYOUT_VERSION = 2   -- bump to force bar recreation on hot-reload

local function GetBarRow(index)
    if barRows[index] then return barRows[index] end

    local barHeight = (PC.db and PC.db.profile and PC.db.profile.barHeight) or 20
    local fontSize = (PC.db and PC.db.profile and PC.db.profile.fontSize) or 11

    local row = CreateFrame("Frame", nil, contentFrame)
    row:SetHeight(barHeight)
    row:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 0, -(index - 1) * (barHeight + PADDING))
    row:SetPoint("RIGHT", contentFrame, "RIGHT", 0, 0)
    row:EnableMouse(true)

    -- Dark background behind the bar (alternating obsidian/void)
    row.bg = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row.bg:SetAllPoints(row)
    if index % 2 == 0 then
        row.bg:SetColorTexture(C_OBSIDIAN[1], C_OBSIDIAN[2], C_OBSIDIAN[3], 0.40)
    else
        row.bg:SetColorTexture(C_VOID[1], C_VOID[2], C_VOID[3], 0.30)
    end

    -- Background bar (status bar) — class-colored with reduced alpha
    row.bar = row:CreateTexture(nil, "BACKGROUND")
    row.bar:SetTexture(BAR_TEXTURE)
    row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.bar:SetWidth(0)

    -- Rank number
    row.rankText = row:CreateFontString(nil, "OVERLAY")
    row.rankText:SetFont(FONT_FILE, fontSize - 1, "OUTLINE")
    row.rankText:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.rankText:SetWidth(28)
    row.rankText:SetJustifyH("RIGHT")

    -- Player name
    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFont(FONT_FILE, fontSize, "OUTLINE")
    row.nameText:SetPoint("LEFT", row.rankText, "RIGHT", 4, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -172, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    -- Status label (e.g. Active, Slacking)
    row.statusText = row:CreateFontString(nil, "OVERLAY")
    row.statusText:SetFont(FONT_FILE, fontSize - 2, "OUTLINE")
    row.statusText:SetPoint("RIGHT", row, "RIGHT", -78, 0)
    row.statusText:SetWidth(58)
    row.statusText:SetJustifyH("CENTER")

    -- Score text (right side)
    row.scoreText = row:CreateFontString(nil, "OVERLAY")
    row.scoreText:SetFont(FONT_FILE, fontSize, "OUTLINE")
    row.scoreText:SetPoint("RIGHT", row, "RIGHT", -40, 0)
    row.scoreText:SetWidth(36)
    row.scoreText:SetJustifyH("RIGHT")

    -- APM text (far right)
    row.apmText = row:CreateFontString(nil, "OVERLAY")
    row.apmText:SetFont(FONT_FILE, fontSize - 1, "OUTLINE")
    row.apmText:SetPoint("RIGHT", row, "RIGHT", -3, 0)
    row.apmText:SetWidth(36)
    row.apmText:SetJustifyH("RIGHT")
    row.apmText:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])

    -- AFK warning indicator (gold dot)
    row.afkIcon = row:CreateTexture(nil, "OVERLAY")
    row.afkIcon:SetSize(6, 6)
    row.afkIcon:SetPoint("LEFT", row, "LEFT", 1, 0)
    row.afkIcon:SetColorTexture(1, 0.6, 0, 1)
    row.afkIcon:Hide()

    -- Hover highlight (subtle gold glow)
    row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.highlight:SetAllPoints(row)
    row.highlight:SetColorTexture(C_GOLD_DIM[1], C_GOLD_DIM[2], C_GOLD_DIM[3], 0.06)

    -- Mouse scripts for tooltip
    row:SetScript("OnEnter", function(self)
        if self.playerGUID and PC.UI_Tooltip and PC.UI_Tooltip.Show then
            PC.UI_Tooltip.Show(self, self.playerGUID, self.isHistorical)
        end
    end)
    row:SetScript("OnLeave", function(self)
        if PC.UI_Tooltip and PC.UI_Tooltip.Hide then
            PC.UI_Tooltip.Hide()
        end
    end)

    row._layoutVer = LAYOUT_VERSION
    barRows[index] = row
    return row
end

---------------------------------------------------------------------------
-- Refresh all bars (called on throttled timer)
---------------------------------------------------------------------------
function UI.RefreshBars()
    if not mainFrame or not mainFrame:IsShown() then return end

    -- Force bar recreation when layout code changes between /reloads
    if barRows[1] and not barRows[1]._layoutVer or (barRows[1] and barRows[1]._layoutVer ~= LAYOUT_VERSION) then
        for i, row in ipairs(barRows) do
            row:Hide()
            row:SetParent(nil)
        end
        Utils.WipeTable(barRows)
    end

    BuildSortedPlayerList()

    local maxRows = (PC.db and PC.db.profile and PC.db.profile.maxRows) or 30
    local barHeight = (PC.db and PC.db.profile and PC.db.profile.barHeight) or 20

    -- Find the highest score for bar width scaling
    local topScore = 0
    for _, p in ipairs(sortedPlayers) do
        if p.score > topScore then topScore = p.score end
    end
    if topScore <= 0 then topScore = 1 end

    -- Determine available width for bars
    local barMaxWidth = contentFrame:GetWidth()

    -- Update each row
    local displayed = math.min(#sortedPlayers, maxRows)
    for i = 1, displayed do
        local row = GetBarRow(i)
        local p = sortedPlayers[i]

        row.playerGUID = p.guid
        row.isHistorical = p.isHistorical

        -- Position
        row:SetHeight(barHeight)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 0, -(i - 1) * (barHeight + PADDING))
        row:SetPoint("RIGHT", contentFrame, "RIGHT", 0, 0)

        -- Rank (gold for #1, silver #2, bronze #3, muted rest)
        row.rankText:SetText(i .. ".")
        if i == 1 then
            row.rankText:SetTextColor(C_GOLD_BRIGHT[1], C_GOLD_BRIGHT[2], C_GOLD_BRIGHT[3])
        elseif i == 2 then
            row.rankText:SetTextColor(0.78, 0.78, 0.82)
        elseif i == 3 then
            row.rankText:SetTextColor(0.80, 0.50, 0.20)
        else
            row.rankText:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
        end

        -- Name (class colored, with enemy indicator)
        local r, g, b = Utils.GetClassColor(p.class)
        if p.isEnemy then
            row.nameText:SetText("|cffcc3333\226\151\134|r " .. p.name)
        else
            row.nameText:SetText(p.name)
        end
        row.nameText:SetTextColor(r, g, b)

        -- Score (this is the Cadence Score when meter data is available)
        local sr, sg, sb = Utils.GetScoreColor(p.score)
        row.scoreText:SetText(Utils.FormatScore(p.score))
        row.scoreText:SetTextColor(sr, sg, sb)

        -- Status label (override with DEAD if player is dead)
        if p.isDead then
            row.statusText:SetText("DEAD")
            row.statusText:SetTextColor(1.0, 0.0, 0.0)
        else
            local statusLabel, str, stg, stb = GetStatusLabel(p.score)
            row.statusText:SetText(statusLabel)
            row.statusText:SetTextColor(str, stg, stb)
        end

        -- APM (always shown on far right)
        row.apmText:SetText(Utils.FormatAPM(p.apm))

        -- Bar width proportional to score (reduced alpha for subtlety)
        local barFrac = p.score / topScore
        row.bar:SetWidth(math.max(barMaxWidth * barFrac, 1))
        row.bar:SetVertexColor(r, g, b, 0.35)

        -- AFK flag (20s+ gap)
        if p.afkFlag then
            row.afkIcon:SetColorTexture(C_ERROR[1], C_ERROR[2], C_ERROR[3], 0.9)
            row.afkIcon:Show()
        else
            row.afkIcon:Hide()
        end

        row:Show()
    end

    -- Hide unused rows
    for i = displayed + 1, #barRows do
        barRows[i]:Hide()
    end

    -- Update content frame height
    contentFrame:SetHeight(math.max(displayed * (barHeight + PADDING), 1))

    -- Update title
    UI.UpdateTitle()
end

---------------------------------------------------------------------------
-- Update title bar text
---------------------------------------------------------------------------
function UI.UpdateTitle()
    if not titleText or not timerText then return end

    -- ── Sync badge ──────────────────────────────────────────────
    -- Visible whenever ≥ 1 peer is running Cadence in our group. We do NOT
    -- show "1/1" in solo play; that would just be noise.
    if syncText then
        if PC.Comm and PC.Comm.GetSyncStatus then
            local synced, total = PC.Comm.GetSyncStatus()
            if synced >= 2 then
                syncText:SetText(string.format("%d/%d sync", synced, total))
                if synced == total then
                    syncText:SetTextColor(C_SUCCESS[1], C_SUCCESS[2], C_SUCCESS[3])
                else
                    -- Amber when partial — visually distinguishes "everyone has it"
                    -- (green) from "some still on combat-log fallback" (amber).
                    syncText:SetTextColor(C_GOLD[1], C_GOLD[2], C_GOLD[3])
                end
            else
                syncText:SetText("")
            end
        else
            syncText:SetText("")
        end
    end

    local segIdx = Segments.GetActiveIndex()

    if segIdx > 0 then
        local seg = Segments.GetSegment(segIdx)
        titleText:SetText("Cadence  \226\128\148  " .. (seg and seg.name or "Segment"))
        titleText:SetTextColor(C_TEXT_BRIGHT[1], C_TEXT_BRIGHT[2], C_TEXT_BRIGHT[3])
        timerText:SetText(seg and Utils.FormatTime(seg.duration) or "")
        timerText:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    else
        -- Show accumulator scope in title when persistent tracking is active
        local accScope = Segments.IsAccumulating() and Segments.GetAccumulatorScopeName() or nil
        local segName = Segments.GetCurrentName()

        if accScope and accScope ~= "" then
            titleText:SetText("Cadence  \226\128\148  " .. accScope)
        elseif segName ~= "Current" then
            titleText:SetText("Cadence  \226\128\148  " .. segName)
        else
            titleText:SetText("Cadence")
        end
        titleText:SetTextColor(C_GOLD_BRIGHT[1], C_GOLD_BRIGHT[2], C_GOLD_BRIGHT[3])

        -- Show combat timer if in combat
        if PC.Events and PC.Events.IsInCombat() then
            -- Find max combat duration among all tracked players
            local maxDur = 0
            local playerCount = 0
            for guid, pd in pairs(Tracker.GetAllPlayerData()) do
                local dur = Tracker.GetCombatDuration(guid)
                if dur > maxDur then maxDur = dur end
                playerCount = playerCount + 1
            end
            if playerCount > 0 and maxDur > 0.2 then
                timerText:SetText(Utils.FormatTime(maxDur))
                timerText:SetTextColor(C_SUCCESS[1], C_SUCCESS[2], C_SUCCESS[3])
            else
                timerText:SetText("")
            end
        else
            timerText:SetText("")
        end
    end
end

---------------------------------------------------------------------------
-- Simple custom right-click popup menu (no deprecated UIDropDownMenu)
---------------------------------------------------------------------------
local popupMenu = nil

local function CreatePopupMenu()
    if popupMenu then popupMenu:Hide(); return popupMenu end

    local f = CreateFrame("Frame", "CadencePopupMenu", UIParent, "BackdropTemplate")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetSize(180, 20)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(C_VOID[1], C_VOID[2], C_VOID[3], 0.98)
    f:SetBackdropBorderColor(C_GOLD_DIM[1], C_GOLD_DIM[2], C_GOLD_DIM[3], 0.40)
    f:EnableMouse(true)
    f:Hide()

    f.buttons = {}

    -- Auto-hide when clicking elsewhere
    f:SetScript("OnShow", function(self)
        self:SetScript("OnUpdate", function(self2)
            if not MouseIsOver(self2) and IsMouseButtonDown("LeftButton") then
                self2:Hide()
            end
        end)
    end)
    f:SetScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    popupMenu = f
    return f
end

local function PopulateMenu(menu, entries)
    -- Hide old buttons
    for _, btn in ipairs(menu.buttons) do btn:Hide() end

    local ROW_HEIGHT = 20
    local MENU_WIDTH = 180
    local yOff = -4

    for i, entry in ipairs(entries) do
        local btn = menu.buttons[i]
        if not btn then
            btn = CreateFrame("Button", nil, menu)
            btn:SetHeight(ROW_HEIGHT)
            btn:SetNormalFontObject("GameFontHighlightSmall")
            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.label:SetPoint("LEFT", btn, "LEFT", 8, 0)
            btn.label:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
            btn.label:SetJustifyH("LEFT")
            menu.buttons[i] = btn
        end

        btn:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, yOff)
        btn:SetPoint("RIGHT", menu, "RIGHT", -4, 0)
        btn.label:SetText(entry.text or "")

        if entry.isSeparator then
            btn.label:SetText("---")
            btn.label:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3], 0.30)
            btn:SetScript("OnClick", nil)
            btn:Disable()
        elseif entry.isHeader then
            btn.label:SetTextColor(C_GOLD[1], C_GOLD[2], C_GOLD[3])
            btn:SetScript("OnClick", nil)
            btn:Disable()
        else
            local active = entry.checked
            if active then
                btn.label:SetTextColor(C_GOLD_BRIGHT[1], C_GOLD_BRIGHT[2], C_GOLD_BRIGHT[3])
            else
                btn.label:SetTextColor(C_TEXT_BRIGHT[1], C_TEXT_BRIGHT[2], C_TEXT_BRIGHT[3])
            end
            btn:Enable()
            btn:SetScript("OnClick", function()
                menu:Hide()
                if entry.func then entry.func() end
            end)
        end

        btn:Show()
        yOff = yOff - ROW_HEIGHT
    end

    menu:SetSize(MENU_WIDTH, math.abs(yOff) + 8)
end

function UI.ShowTitleMenu()
    local menu = CreatePopupMenu()
    local entries = {}

    -- Live Data
    entries[#entries + 1] = {
        text = (Segments.GetActiveIndex() == 0) and "|cffFFD666> Live Data|r" or "Live Data",
        checked = (Segments.GetActiveIndex() == 0),
        func = function() Segments.SwitchTo(0) end,
    }

    -- Segments
    local history = Segments.GetHistory()
    if #history > 0 then
        entries[#entries + 1] = { isSeparator = true }
        entries[#entries + 1] = { text = "Segments", isHeader = true }
        for i, seg in ipairs(history) do
            local segIdx = i
            entries[#entries + 1] = {
                text = string.format("%d. %s (%s)", i, seg.name, Utils.FormatTime(seg.duration)),
                checked = (Segments.GetActiveIndex() == i),
                func = function() Segments.SwitchTo(segIdx) end,
            }
        end
    end

    entries[#entries + 1] = { isSeparator = true }

    -- Reset
    entries[#entries + 1] = {
        text = "|cffff6666Reset Data|r",
        func = function()
            Tracker.ResetAll()
            Segments.ResetAll()
            UI.ForceRefresh()
            print("|cffffffffCad|r|cffFFD666ence|r: Data reset.")
        end,
    }

    -- Lock
    local lockLabel = (PC.db and PC.db.profile and PC.db.profile.locked) and "Unlock Window" or "Lock Window"
    entries[#entries + 1] = {
        text = lockLabel,
        func = function()
            PC.db.profile.locked = not PC.db.profile.locked
        end,
    }

    -- Close
    entries[#entries + 1] = { text = "Close", func = function() end }

    PopulateMenu(menu, entries)

    -- Position at cursor
    local cx, cy = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
    menu:Show()
end

PC.UI_Meter = UI

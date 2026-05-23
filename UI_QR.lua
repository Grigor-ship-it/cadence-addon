--[[
    Cadence - UI_QR.lua
    QR code rendering in WoW UI and data payload encoding.
    Displays a scannable QR code on the summary screen that encodes
    encounter data as a URL for submission to the Cadence backend.
]]

local ADDON_NAME, PC = ...

PC.UI_QR = {}
local UIQR = PC.UI_QR
local QREncode = PC.QREncode
local Utils = PC.Utils

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
-- Production submission endpoint. Players can override at runtime with
-- `/cadence url <full-url>` (handy for self-hosted testing).
local SUBMIT_BASE_URL = "https://www.cadencewow.com/s"
local MAX_QR_PIXELS = 400   -- target max pixel size for QR code area
local QUIET_ZONE = 2        -- modules of white border around QR code
local FONT_FILE = "Fonts\\FRIZQT__.TTF"

-- Class short codes (2-letter, unique)
local CLASS_CODE = {
    WARRIOR     = "WA",
    PALADIN     = "PA",
    HUNTER      = "HU",
    ROGUE       = "RO",
    PRIEST      = "PR",
    DEATHKNIGHT = "DK",
    SHAMAN      = "SH",
    MAGE        = "MA",
    WARLOCK     = "WL",
    MONK        = "MO",
    DEMONHUNTER = "DH",
    DRUID       = "DR",
    EVOKER      = "EV",
}

local CLASS_DECODE = {}
for k, v in pairs(CLASS_CODE) do CLASS_DECODE[v] = k end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local qrFrame = nil         -- The popup frame
local qrTextures = {}       -- Pool of dark-module textures
local qrContainer = nil     -- The QR rendering sub-frame

---------------------------------------------------------------------------
-- UTF-8 safe byte truncation
-- Lua string.sub() works on bytes, so truncating at N bytes can split a
-- multi-byte UTF-8 character.  This backs up to the last complete character.
---------------------------------------------------------------------------
local function utf8sub(s, maxBytes)
    if #s <= maxBytes then return s end
    -- Walk back from the cut point to avoid splitting a multi-byte char.
    local pos = maxBytes
    while pos > 0 do
        local b = string.byte(s, pos)
        if b < 128 or b >= 192 then
            -- b < 128  → ASCII (single byte), safe boundary
            -- b >= 192 → start of a multi-byte sequence
            --   If we'd lose trailing continuation bytes, drop this char too
            --   by checking if the full sequence fits within maxBytes.
            if b >= 192 then
                local seqLen = (b < 224) and 2 or (b < 240) and 3 or 4
                if pos + seqLen - 1 > maxBytes then
                    pos = pos - 1  -- sequence doesn't fit, skip it
                else
                    return s:sub(1, pos + seqLen - 1)
                end
            else
                return s:sub(1, pos)
            end
        else
            pos = pos - 1  -- continuation byte (10xxxxxx), keep backing up
        end
    end
    return ""
end

---------------------------------------------------------------------------
-- Nonce generation — 6 hex chars from GetTime() fractional + random()
---------------------------------------------------------------------------
local nonceCounter = 0
local function GenerateNonce()
    nonceCounter = nonceCounter + 1
    -- Combine high-res time, frame counter, and math.random for uniqueness
    local t = GetTime() * 1000  -- ms precision
    local r = math.random(0, 0xFFFF)
    local val = (math.floor(t) * 65536 + r + nonceCounter) % 0xFFFFFF
    return string.format("%06x", val)
end

---------------------------------------------------------------------------
-- Payload encoding v10: segment → compact URL string
--
-- Format (pipe-delimited header, dot-delimited players):
--   v|type|realm|encounter|duration|timestamp|nonce|addonVer|claimToken|encounterID|difficultyID|instanceID|teamSize|keystoneLevel|region|player.player...
--
-- Player sub-format (underscore-delimited):
--   Name_CC_Score_APM10_Uptime_Deaths_Role_Abilities_DmgK_HealK_Dps_Hps_Intrs_Dispels_AvoidK_MDeaths_SpecID_Ilvl_PvpScore_Ext_RaidCd_Sup_CC
--
-- Abilities sub-format (plus-delimited, colon key:value):
--   spellID:count+spellID:count+...   (top 5 by cast count)
--
-- v10 adds (field 15): region (us|eu|kr|tw|cn) from GetCurrentRegion().
--   Lets the backend route character lookups to the correct regional
--   Blizzard API host (us.api.blizzard.com vs eu.api.blizzard.com etc).
--   WoW does not cross-realm across regions, so the reporter's region
--   applies to all 5 players in the group.
-- v9 adds (fields 18-23): Ilvl, PvpScore, Ext, RaidCd, Sup, CC.
--   - Ilvl: equipped iLvl, only set for the reporter (others = 0, backend backfills).
--   - PvpScore: parallel cadence score using arena weights.
--   - Ext / RaidCd / Sup / CC: per-player utility-category counts so the
--     backend can show the user *why* their utility score moved.
-- v8 adds meter data + specID per player (fields 9-17 after Abilities).
-- v7 adds keystoneLevel for M+ key level (field 14).
-- v6 adds teamSize for arena bracket (field 13).
-- v5 adds per-player top ability data (field 8).
-- v4 added encounterID, difficultyID, instanceID fields (positions 10-12).
-- Type codes: B=boss, M=mythicplus, T=trash, A=arena, S=soloshuffle
---------------------------------------------------------------------------
function UIQR.EncodePayload(segment)
    if not segment or not segment.players then return nil end

    -- Determine encounter type
    local segType = segment.segType or "trash"
    local typeCode = "T"
    if segType == "boss" then typeCode = "B"
    elseif segType == "mythicplus" then typeCode = "M"
    elseif segType == "arena" then typeCode = "A"
    elseif segType == "soloshuffle" then typeCode = "S"
    end

    -- Realm name (preserve spaces as hyphens; parser converts back).
    -- Use GetRealmName() not GetNormalizedRealmName() because the latter
    -- already strips spaces for German/French realms (e.g.
    -- "Kult der Verdammten" -> "KultderVerdammten"), which then defeats our
    -- space->hyphen conversion and produces a realm slug that doesn't match
    -- Blizzard's canonical URL slug ("kult-der-verdammten").
    local realm = GetRealmName() or GetNormalizedRealmName() or "Unknown"
    realm = utf8sub(realm:gsub("[|_.~:+]", ""):gsub("%s+", "-"), 24)

    -- Clean encounter name (strip payload delimiters, preserve UTF-8 accented chars)
    local name = segment.name or "Unknown"
    name = utf8sub(name:gsub("[|_.~:]", ""), 40)
    name = name:gsub("%s+", "-")

    -- Duration
    local dur = math.floor(segment.duration or 0)

    -- Timestamp (Unix epoch from the segment, or now)
    local ts = segment.timestamp or time()

    -- Nonce for replay protection
    local nonce = GenerateNonce()

    -- Addon version
    local ver = PC.VERSION or "0"

    -- Build player entries — compact format
    -- Reporter (the addon user) is always placed FIRST so the backend
    -- knows which player submitted this payload.
    local myGUID = UnitGUID("player")
    local reporterEntry = nil
    local playerParts = {}
    local playerCount = 0
    for _ in pairs(segment.players) do playerCount = playerCount + 1 end

    for guid, snap in pairs(segment.players) do
        -- Use realm-qualified short name: "Name~Realm" for cross-realm players
        -- Strip payload delimiter chars but preserve UTF-8 accented characters (î, ä, ü, é, etc.)
        local pName = utf8sub((snap.name or "Unknown"):gsub("[|_.~:+]", ""), 20)
        -- Per-player realm: nil means same-realm as reporter; non-nil for cross-realm.
        -- Resolve the realm from GUID first because UnitName(token) returns the
        -- realm with spaces stripped for cross-realm units ("SteamwheedleCartel"
        -- instead of "Steamwheedle Cartel"), which then yields a broken slug
        -- ("steamwheedlecartel") that 404s on Blizzard's character profile API.
        -- GetPlayerInfoByGUID preserves the spaces so our %s+ -> '-' rule below
        -- produces the correct URL slug ("steamwheedle-cartel").
        local pRealm = snap.realm
        if guid and GetPlayerInfoByGUID then
            local ok, _, _, _, _, _, _, realmFromGUID = pcall(GetPlayerInfoByGUID, guid)
            if ok and realmFromGUID and realmFromGUID ~= "" then
                pRealm = realmFromGUID
            end
        end
        if pRealm and pRealm ~= "" then
            pRealm = utf8sub(pRealm:gsub("[|_.~:+]", ""):gsub("%s+", "-"), 24)
            pName = pName .. "~" .. pRealm
        end
        local classCode = CLASS_CODE[snap.class or "PRIEST"] or "PR"
        local score = math.floor(snap.cadenceScore or snap.activityScore or 0)
        local apm = math.floor((snap.apm or 0) * 10)
        local uptime = math.floor(snap.uptime or 0)
        local deaths = snap.deathCount or 0
        local role = snap.role or "DAMAGER"
        local roleCode = role:sub(1, 1)

        -- Encode top abilities ONLY for the reporter (self) player.
        -- In WoW 12.0 (Midnight), the combat log may attribute the local
        -- player's healing spells to the targets they land on, polluting
        -- other players' ability maps with the reporter's own spells.
        -- We can only trust spell data for the self player (via USCS).
        local abilStr = ""
        if playerCount <= 5 and guid == myGUID then
            local topAbil = snap.topAbilities
            if topAbil then
                local abilParts = {}
                local maxAbil = math.min(#topAbil, 5)  -- top 5 to keep QR small
                for i = 1, maxAbil do
                    local a = topAbil[i]
                    if a and a.spellID and a.count then
                        abilParts[#abilParts + 1] = a.spellID .. ":" .. a.count
                    end
                end
                if #abilParts > 0 then
                    abilStr = table.concat(abilParts, "+")
                end
            end
        end

        -- Name_CC_Score_APM10_Uptime_Deaths_Role_Abilities_DmgK_HealK_Dps_Hps_Intrs_Dispels_AvoidK_MDeaths_SpecID_Ilvl_PvpScore_Ext_RaidCd_Sup_CC
        local dmgK = math.floor((snap.damageDone or 0) / 1000)
        local healK = math.floor((snap.healingDone or 0) / 1000)
        local dpsVal = math.floor(snap.dps or 0)
        local hpsVal = math.floor(snap.hps or 0)
        local intrs = math.floor(snap.interrupts or 0)
        local dispelsVal = math.floor(snap.dispels or 0)
        local avoidK = math.floor((snap.avoidableDamage or 0) / 1000)
        local mDeaths = math.floor(snap.meterDeaths or 0)
        local specID = Utils.GetSpecIDByGUID(guid)
        -- v9 additions
        local ilvl = math.floor(snap.itemLevel or 0)
        local pvpScore = math.floor(snap.pvpCadenceScore or 0)
        local extCnt = math.floor(snap.externals or 0)
        local raidCdCnt = math.floor(snap.raidCds or 0)
        local supCnt = math.floor(snap.support or 0)
        local ccCnt = math.floor(snap.cc or 0)

        local entry = string.format("%s_%s_%d_%d_%d_%d_%s_%s_%d_%d_%d_%d_%d_%d_%d_%d_%d_%d_%d_%d_%d_%d_%d",
            pName, classCode, score, apm, uptime, deaths, roleCode, abilStr,
            dmgK, healK, dpsVal, hpsVal, intrs, dispelsVal, avoidK, mDeaths, specID,
            ilvl, pvpScore, extCnt, raidCdCnt, supCnt, ccCnt)
        if guid == myGUID then
            reporterEntry = entry
        else
            playerParts[#playerParts + 1] = entry
        end
    end

    -- Sort non-reporter players by score descending for deterministic ordering
    table.sort(playerParts, function(a, b) return a > b end)

    -- Insert reporter at position 1 (first player = reporter)
    if reporterEntry then
        table.insert(playerParts, 1, reporterEntry)
    end

    -- Header: v|type|realm|encounter|duration|timestamp|nonce|addonVer|claimToken|encounterID|difficultyID|instanceID|teamSize|keystoneLevel|region
    -- Players: dot-separated after header, joined with a trailing pipe
    local claimToken = (PC.db and PC.db.profile and PC.db.profile.claimToken) or "0"
    local encID = tostring(segment.encounterID or 0)
    local diffID = tostring(segment.difficultyID or 0)
    local instID = tostring(segment.instanceID or 0)
    local teamSz = tostring(segment.teamSize or 0)
    local ksLvl = tostring(segment.keystoneLevel or 0)

    -- Region code: 1=US, 2=KR, 3=EU, 4=TW, 5=CN, 72=PTR.
    -- Map to lowercase 2-letter slug matching backend region columns and
    -- the {region}.api.blizzard.com subdomain convention. Default to "us"
    -- if GetCurrentRegion is unavailable or returns an unknown value.
    local REGION_CODE = { [1] = "us", [2] = "kr", [3] = "eu", [4] = "tw", [5] = "cn" }
    local regionId = (GetCurrentRegion and GetCurrentRegion()) or 1
    local regionSlug = REGION_CODE[regionId] or "us"

    local header = table.concat({
        "10",       -- payload version (v10 adds region for backend API routing)
        typeCode,
        realm,
        name,
        tostring(dur),
        tostring(ts),
        nonce,
        ver,
        claimToken,
        encID,
        diffID,
        instID,
        teamSz,
        ksLvl,
        regionSlug,
    }, "|")

    local players = table.concat(playerParts, ".")
    local data = header .. "|" .. players

    return data
end

---------------------------------------------------------------------------
-- Build the full URL from payload
---------------------------------------------------------------------------
function UIQR.BuildURL(segment)
    local payload = UIQR.EncodePayload(segment)
    if not payload then return nil end
    return SUBMIT_BASE_URL .. "?d=" .. payload
end

---------------------------------------------------------------------------
-- Set the backend URL (for testing with localhost)
---------------------------------------------------------------------------
function UIQR.SetBaseURL(url)
    SUBMIT_BASE_URL = url
end

---------------------------------------------------------------------------
-- Render a QR matrix into a WoW frame
-- Uses batched row rendering via C_Timer to avoid "script ran too long"
---------------------------------------------------------------------------
local ROWS_PER_BATCH = 20  -- render this many rows per frame tick

function UIQR.RenderQR(parent, matrix, qrSize)
    -- Compute module size to fit within target pixel area
    local effectiveModules = qrSize + QUIET_ZONE * 2
    local moduleSize = math.max(3, math.floor(MAX_QR_PIXELS / effectiveModules))

    -- Create or reuse the container
    if not qrContainer then
        qrContainer = CreateFrame("Frame", nil, parent)
    else
        qrContainer:SetParent(parent)
    end

    -- Hide all existing textures
    for _, t in ipairs(qrTextures) do
        t:Hide()
        t:ClearAllPoints()
    end

    local totalPx = effectiveModules * moduleSize
    qrContainer:SetSize(totalPx, totalPx)
    qrContainer:SetPoint("CENTER", parent, "CENTER", 0, 10)

    -- White background (quiet zone included)
    if not qrContainer.bg then
        qrContainer.bg = qrContainer:CreateTexture(nil, "BACKGROUND")
        qrContainer.bg:SetAllPoints()
        qrContainer.bg:SetColorTexture(1, 1, 1, 1)
    end
    qrContainer.bg:Show()

    -- Render dark modules using run-length encoding per row, batched to avoid timeout
    local texIdx = 0
    local offsetX = QUIET_ZONE * moduleSize
    local offsetY = QUIET_ZONE * moduleSize

    local function RenderRowBatch(startRow)
        local endRow = math.min(startRow + ROWS_PER_BATCH - 1, qrSize)
        for r = startRow, endRow do
            local c = 1
            while c <= qrSize do
                if matrix[r][c] == 1 then
                    -- Find end of contiguous dark run
                    local runStart = c
                    while c <= qrSize and matrix[r][c] == 1 do
                        c = c + 1
                    end
                    local runLen = c - runStart

                    -- Get or create a texture
                    texIdx = texIdx + 1
                    local t = qrTextures[texIdx]
                    if not t then
                        t = qrContainer:CreateTexture(nil, "ARTWORK")
                        qrTextures[texIdx] = t
                    end

                    t:SetParent(qrContainer)
                    t:SetSize(runLen * moduleSize, moduleSize)
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", qrContainer, "TOPLEFT",
                        offsetX + (runStart - 1) * moduleSize,
                        -(offsetY + (r - 1) * moduleSize))
                    t:SetColorTexture(0, 0, 0, 1)
                    t:Show()
                else
                    c = c + 1
                end
            end
        end

        -- If more rows remain, schedule next batch
        if endRow < qrSize then
            C_Timer.After(0, function() RenderRowBatch(endRow + 1) end)
        end
    end

    -- Start first batch immediately
    RenderRowBatch(1)

    qrContainer:Show()
    return qrContainer, totalPx
end

---------------------------------------------------------------------------
-- Create the QR share popup frame
---------------------------------------------------------------------------
-- ── Premium color palette (matches cadencewow.com tokens) ─────
local C_VOID          = { 0.035, 0.035, 0.059, 0.98 }
local C_OBSIDIAN      = { 0.067, 0.067, 0.094, 0.95 }
local C_GOLD_BRIGHT   = { 1.00, 0.84, 0.40 }
local C_GOLD          = { 0.85, 0.66, 0.15 }
local C_GOLD_DIM      = { 0.65, 0.49, 0.10 }
local C_GOLD_MUTED    = { 0.42, 0.31, 0.06 }
local C_TEXT_BRIGHT   = { 0.94, 0.94, 0.96 }
local C_TEXT_STD      = { 0.72, 0.72, 0.80 }
local C_TEXT_MUTED    = { 0.49, 0.49, 0.60 }
local C_TEXT_GHOST    = { 0.28, 0.28, 0.38 }
local C_ERROR         = { 0.97, 0.44, 0.44 }

local BACKDROP_QR = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function CreateQRFrame()
    if qrFrame then
        return qrFrame
    end

    local f = CreateFrame("Frame", "CadenceQRFrame", UIParent, "BackdropTemplate")
    f:SetSize(380, 460)
    f:SetPoint("CENTER", UIParent, "CENTER", 240, 30)
    f:SetBackdrop(BACKDROP_QR)
    f:SetBackdropColor(C_VOID[1], C_VOID[2], C_VOID[3], C_VOID[4])
    f:SetBackdropBorderColor(C_GOLD_DIM[1], C_GOLD_DIM[2], C_GOLD_DIM[3], 0.40)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(200)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)

    -- Escape to close
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

    -- Gold accent line under title
    f.titleAccent = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.titleAccent:SetPoint("BOTTOMLEFT", f.titleBg, "BOTTOMLEFT", 0, 0)
    f.titleAccent:SetPoint("BOTTOMRIGHT", f.titleBg, "BOTTOMRIGHT", 0, 0)
    f.titleAccent:SetHeight(2)
    f.titleAccent:SetColorTexture(C_GOLD[1], C_GOLD[2], C_GOLD[3], 0.50)

    -- Brand mark
    f.brandText = f:CreateFontString(nil, "OVERLAY")
    f.brandText:SetFont(FONT_FILE, 9, "OUTLINE")
    f.brandText:SetPoint("TOPLEFT", f.titleBg, "TOPLEFT", 12, -6)
    f.brandText:SetTextColor(C_GOLD_DIM[1], C_GOLD_DIM[2], C_GOLD_DIM[3])
    f.brandText:SetText("|cffffffffCAD|r|cffFFD666ENCE|r")

    -- Title text
    f.titleText = f:CreateFontString(nil, "OVERLAY")
    f.titleText:SetFont(FONT_FILE, 13, "OUTLINE")
    f.titleText:SetPoint("BOTTOMLEFT", f.titleBg, "BOTTOMLEFT", 12, 6)
    f.titleText:SetTextColor(C_TEXT_BRIGHT[1], C_TEXT_BRIGHT[2], C_TEXT_BRIGHT[3])
    f.titleText:SetText("Share Encounter")

    -- ── Close button (custom ×) ──────────────────────────────
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

    -- ── QR code area (below title bar) ───────────────────────
    -- Title bar bottom sits at y=-40 (inset 4 + height 36); add 18px padding
    -- so the QR matrix doesn't visually crash into the gold accent line.
    f.qrArea = CreateFrame("Frame", nil, f)
    f.qrArea:SetSize(330, 330)
    f.qrArea:SetPoint("TOP", f, "TOP", 0, -58)

    -- ── Info text below QR ───────────────────────────────────
    f.infoText = f:CreateFontString(nil, "OVERLAY")
    f.infoText:SetFont(FONT_FILE, 10, "OUTLINE")
    f.infoText:SetPoint("BOTTOM", f, "BOTTOM", 0, 48)
    f.infoText:SetWidth(350)
    f.infoText:SetJustifyH("CENTER")
    f.infoText:SetTextColor(C_TEXT_MUTED[1], C_TEXT_MUTED[2], C_TEXT_MUTED[3])
    f.infoText:SetText("Scan with your phone camera to upload\nto |cffFFD666cadencewow.com|r")

    -- Encounter summary (gold accented)
    f.encounterText = f:CreateFontString(nil, "OVERLAY")
    f.encounterText:SetFont(FONT_FILE, 10, "OUTLINE")
    f.encounterText:SetPoint("BOTTOM", f, "BOTTOM", 0, 22)
    f.encounterText:SetWidth(350)
    f.encounterText:SetJustifyH("CENTER")
    f.encounterText:SetTextColor(C_GOLD_BRIGHT[1], C_GOLD_BRIGHT[2], C_GOLD_BRIGHT[3])

    -- URL display (ghost text for debugging)
    f.urlText = f:CreateFontString(nil, "OVERLAY")
    f.urlText:SetFont(FONT_FILE, 8, "OUTLINE")
    f.urlText:SetPoint("BOTTOM", f, "BOTTOM", 0, 6)
    f.urlText:SetWidth(350)
    f.urlText:SetJustifyH("CENTER")
    f.urlText:SetTextColor(C_TEXT_GHOST[1], C_TEXT_GHOST[2], C_TEXT_GHOST[3])

    qrFrame = f
    return f
end

---------------------------------------------------------------------------
-- Show QR code for a segment
---------------------------------------------------------------------------
function UIQR.ShowForSegment(segment)
    if not segment then return end

    -- Server-side gate: wipes and follower dungeons must never reach the
    -- backend. Mirrors UI_Summary.IsShareable() so /cad qr and any future
    -- entry point can't bypass the share button's disabled state.
    if PC.UI_Summary and PC.UI_Summary.IsShareable then
        local ok, reason = PC.UI_Summary.IsShareable(segment)
        if not ok then
            if reason == "wipe" then
                print("|cffffffffCad|r|cffFFD666ence|r: QR sharing is disabled for wipes.")
            elseif reason == "follower dungeon" then
                print("|cffffffffCad|r|cffFFD666ence|r: QR sharing is disabled in follower dungeons.")
            else
                print("|cffffffffCad|r|cffFFD666ence|r: This segment can't be shared (" .. tostring(reason) .. ").")
            end
            return
        end
    end

    local url = UIQR.BuildURL(segment)
    if not url then
        print("|cffffffffCad|r|cffFFD666ence|r: Could not generate QR code — no player data.")
        return
    end

    -- Generate QR matrix (Low EC = smaller QR = easier to scan)
    local matrix, qrSize, version = QREncode.Encode(url, "L")
    if not matrix then
        print("|cffffffffCad|r|cffFFD666ence|r: QR encode failed — data too long. URL printed above.")
        return
    end

    local f = CreateQRFrame()

    -- Render the QR code into the qrArea
    local container, totalPx = UIQR.RenderQR(f.qrArea, matrix, qrSize)

    -- Resize the QR area to fit
    f.qrArea:SetSize(totalPx, totalPx)

    -- Resize the popup to fit the QR code + chrome
    local frameW = math.max(totalPx + 50, 320)
    local frameH = totalPx + 120
    f:SetSize(frameW, frameH)

    -- Update encounter info
    local playerCount = 0
    local avgScore = 0
    for _, snap in pairs(segment.players or {}) do
        playerCount = playerCount + 1
        avgScore = avgScore + (snap.cadenceScore or snap.activityScore or 0)
    end
    if playerCount > 0 then avgScore = avgScore / playerCount end

    local segName = segment.name or "Encounter"
    local dur = Utils.FormatTime(segment.duration or 0)
    f.encounterText:SetText(string.format("%s  •  %s  •  %d players  •  Avg: %.0f",
        segName, dur, playerCount, avgScore))

    -- Show URL for debugging (truncated)
    local displayURL = #url > 60 and (url:sub(1, 57) .. "...") or url
    f.urlText:SetText(displayURL)

    f:Show()

    if PC.Events and PC.Events.IsDebug and PC.Events.IsDebug() then
        print("|cffFFD666PC Debug|r: QR code generated — V" .. version ..
              " (" .. qrSize .. "x" .. qrSize .. "), URL length: " .. #url)
    end
end

---------------------------------------------------------------------------
-- Hide
---------------------------------------------------------------------------
function UIQR.Hide()
    if qrFrame then qrFrame:Hide() end
end

---------------------------------------------------------------------------
-- Show QR directly from a matrix (for diagnostic /pc tinyqr)
---------------------------------------------------------------------------
function UIQR.ShowQRDirect(matrix, qrSize, version, url)
    local f = CreateQRFrame()
    local container, totalPx = UIQR.RenderQR(f.qrArea, matrix, qrSize)
    f.qrArea:SetSize(totalPx, totalPx)
    local frameW = math.max(totalPx + 50, 320)
    local frameH = totalPx + 120
    f:SetSize(frameW, frameH)
    f.encounterText:SetText("Diagnostic QR — V" .. version ..
        " (" .. qrSize .. "x" .. qrSize .. ")")
    f.infoText:SetText("If your phone can scan this, the encoder works!")
    local displayURL = #url > 60 and (url:sub(1, 57) .. "...") or url
    f.urlText:SetText(displayURL)
    f:Show()
end

---------------------------------------------------------------------------
-- Toggle
---------------------------------------------------------------------------
function UIQR.Toggle(segment)
    if qrFrame and qrFrame:IsShown() then
        UIQR.Hide()
    else
        UIQR.ShowForSegment(segment)
    end
end

PC.UI_QR = UIQR

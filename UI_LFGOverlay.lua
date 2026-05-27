--[[
    Cadence - UI_LFGOverlay.lua
    Shows Cadence scores inside Blizzard's Group Finder (LFG list + applicants).

    Data source:  CadenceScoresDB  (populated by ScoresDB.lua, overwritten
                  daily by the backend's lua-export job).

    What we decorate:
      1. Group listings in the Premade Groups search results — we append a
         "Cdn XX" badge to the activity/leader line using the leader's score.
      2. Applicants to your own listings — we append the same badge after
         each applicant row's name.

    Safety:
      * Pure display overlay — we never alter clickability, buttons, or any
        frame that's protected during combat.
      * All hooks are no-ops if `CadenceDB.profile.lfgOverlay` is disabled.
      * A missing or empty `CadenceScoresDB` simply produces no badges.
]]

local ADDON_NAME, PC = ...
PC.UI = PC.UI or {}

local LFG = {}
PC.UI.LFG = LFG

----------------------------------------------------------------------
-- Config helpers
----------------------------------------------------------------------

local function enabled()
    local db = CadenceDB and CadenceDB.profile
    if not db then return false end
    -- Default ON: if the key hasn't been set yet, treat as enabled.
    if db.lfgOverlay == nil then return true end
    return db.lfgOverlay == true
end

----------------------------------------------------------------------
-- Score lookup
----------------------------------------------------------------------

-- Normalise a character key to match our backend export.
-- Backend stores raw name + raw realm (no hyphen stripping).
local function buildKey(name, realm)
    if not name or name == "" then return nil end
    if not realm or realm == "" then
        -- Fall back to the player's own realm when the API omits it
        -- (happens for same-realm group members).
        realm = GetRealmName()
    end
    return name .. "-" .. realm
end

-- Pick the most relevant score for a given content category.
-- category: "mplus" | "raid" | "pvp" | nil
local function scoreFor(entry, category)
    if not entry then return nil, 0 end
    if category == "mplus" and entry.m then return entry.m, entry.mn or 0 end
    if category == "raid"  and entry.r then return entry.r, entry.rn or 0 end
    if category == "pvp"   and entry.p then return entry.p, entry.pn or 0 end
    return entry.s, entry.n or 0
end

-- activityID → high-level category buckets.  Blizzard's LFG API exposes
-- activity groups via `C_LFGList.GetActivityInfoTable`; we coarse-bucket
-- them so we can show the right stat (M+ vs raid vs PvP).
local function categoryForActivity(activityID)
    if not activityID or not C_LFGList or not C_LFGList.GetActivityInfoTable then
        return nil
    end
    local info = C_LFGList.GetActivityInfoTable(activityID)
    if not info then return nil end
    local ct = info.categoryID
    -- Blizzard category IDs (stable since Legion):
    --   2 = Dungeons, 3 = Raids, 4 = Arenas,
    --   7 = RBGs, 9 = Custom, 113 = Thorghast-like, 116 = Mythic+
    if ct == 116 or ct == 2 then return "mplus" end
    if ct == 3            then return "raid"  end
    if ct == 4 or ct == 7 then return "pvp"   end
    return nil
end

-- Pick a colour for a score (0-100) using the brand performance tiers.
local function scoreColour(score)
    if not score then return 0.7, 0.7, 0.7 end
    if score >= 90 then return 1.00, 0.82, 0.00 end  -- gold
    if score >= 80 then return 0.63, 0.84, 0.38 end  -- green
    if score >= 65 then return 0.40, 0.70, 1.00 end  -- blue
    if score >= 50 then return 0.85, 0.85, 0.85 end  -- neutral
    return 0.85, 0.45, 0.45                          -- red
end

-- Format score + sample-size into a short badge string.
local function formatBadge(score, n)
    if not score then return nil end
    local r, g, b = scoreColour(score)
    local hex = string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
    if n and n > 0 then
        return string.format("  |cff%sCdn %d|r|cff808080/%d|r", hex, score, n)
    end
    return string.format("  |cff%sCdn %d|r", hex, score)
end

-- "No Cadence" placeholder badge: white N + yellow C. Kept short so it
-- doesn't crowd the row, and visually distinct from real scores so we can
-- confirm the overlay is wired up even before the scores DB is seeded.
local NC_BADGE = "  |cffffffffN|r|cffffd100C|r"

-- Pattern guard for the NC badge (plain substring search).
local function hasBadge(text)
    if not text or text == "" then return false end
    if text:find("|cff%x%x%x%x%x%xCdn ", 1, false) then return true end
    if text:find(NC_BADGE, 1, true) then return true end
    return false
end

-- Public API: return a coloured badge string for "Name-Realm".
-- Returns the NC placeholder when we have no score for the player so the
-- overlay is always visible while the scores DB is being populated.
function LFG.GetBadge(name, realm, category)
    if not enabled() then return nil end
    local key = buildKey(name, realm)
    if not key then return NC_BADGE end
    local entry = CadenceScoresDB and CadenceScoresDB[key]
    if not entry then return NC_BADGE end
    local score, n = scoreFor(entry, category)
    return formatBadge(score, n) or NC_BADGE
end

----------------------------------------------------------------------
-- Secret-string guard
--
-- Blizzard introduced a "SecureString" / "secret string" type for some
-- LFG API fields (e.g. `leaderName` for cross-faction or privacy-filtered
-- listings). Calling string methods like :match, :find, or .. on one of
-- these taints us, and the next secure call from the same execution
-- chain (right-click → OpenContextMenu → CheckInteractDistance) gets
-- blocked with ADDON_ACTION_BLOCKED.
--
-- type() returns "string" for both regular and secret strings, so we
-- use pcall on a trivial format which fails cleanly on the secret type
-- without tainting the caller. Returns a plain Lua string if the input
-- was a normal string, nil otherwise.
----------------------------------------------------------------------
local function safePlainString(val)
    if val == nil then return nil end
    if type(val) ~= "string" then return nil end
    local ok, copy = pcall(string.format, "%s", val)
    if not ok or type(copy) ~= "string" then return nil end
    -- Round-trip via string.char to detach from any secure provenance.
    local ok2, plain = pcall(function()
        local len = #copy
        if len == 0 then return "" end
        local bytes = { string.byte(copy, 1, len) }
        return string.char(unpack(bytes))
    end)
    if not ok2 or type(plain) ~= "string" then return nil end
    return plain
end

-- Split "Name-Realm" into (name, realm) without touching the original
-- string with secure-tainted methods. Returns nil if input is secret or
-- otherwise unusable.
local function splitNameRealm(raw)
    local plain = safePlainString(raw)
    if not plain or plain == "" then return nil end
    local lname, lrealm = plain:match("^(.+)%-(.+)$")
    if not lname then return plain, nil end
    return lname, lrealm
end

----------------------------------------------------------------------
-- Badge FontString helpers
--
-- Used for search-result rows where there's room to anchor a small
-- dedicated label. For applicant member rows we instead append directly
-- to the existing name FontString because the row layout has no spare
-- right-side real estate.
----------------------------------------------------------------------

local function ensureBadgeFS(parent, anchorPoint, relativeFrame, relativePoint, x, y)
    if not parent then return nil end
    if parent.CadenceBadgeFS then return parent.CadenceBadgeFS end
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetJustifyH("RIGHT")
    fs:ClearAllPoints()
    fs:SetPoint(anchorPoint, relativeFrame or parent, relativePoint or anchorPoint, x or 0, y or 0)
    parent.CadenceBadgeFS = fs
    return fs
end

local function setBadgeText(fs, badge)
    if not fs then return end
    if badge and badge ~= "" then
        -- Strip the leading double-space we use when appending to existing text.
        fs:SetText((badge:gsub("^  ", "")))
        fs:Show()
    else
        fs:SetText("")
        fs:Hide()
    end
end

-- Append the badge to an existing FontString, with a guard so we don't
-- double-decorate when the row recycles.
local function appendBadgeToText(label, badge)
    if not label or not label.GetText or not badge then return end
    local current = label:GetText() or ""
    if hasBadge(current) then return end
    label:SetText(current .. badge)
end

----------------------------------------------------------------------
-- Search results (listings of groups other players are advertising)
--
-- We append the badge to the row's *title* FontString ("+12 Competitive"
-- etc.) which is short and almost always has empty space to its right,
-- rather than to the activity-name subtitle which gets word-wrapped and
-- truncated for long dungeon names.
----------------------------------------------------------------------

local function decorateSearchEntry(frame, resultID)
    if not frame or not resultID or not enabled() then return end

    local info = C_LFGList.GetSearchResultInfo(resultID)
    if not info then return end

    -- info.leaderName can be a Blizzard "secret string" (cross-faction /
    -- privacy-filtered listings). Calling :match on one taints us and
    -- breaks every secure click handler in this frame's chain. Use the
    -- safe splitter which returns nil on secret strings.
    local lname, lrealm = splitNameRealm(info.leaderName)
    if not lname or lname == "" then return end

    local category = categoryForActivity(info.activityID)
    local badge    = LFG.GetBadge(lname, lrealm, category)
    if not badge then return end

    -- The title line (`Name`) is the short colored header at the top of
    -- each row (e.g. "+12 Competitive"). It has plenty of room.
    local titleLabel = frame.Name
    if titleLabel and titleLabel.GetText then
        appendBadgeToText(titleLabel, badge)
    end
end

local function refreshAllVisibleSearchEntries()
    if not LFGListFrame or not LFGListFrame.SearchPanel then return end
    local scroll = LFGListFrame.SearchPanel.ScrollBox
    if not scroll or not scroll.ForEachFrame then return end
    scroll:ForEachFrame(function(frame)
        local data = frame.GetElementData and frame:GetElementData()
        local resultID = data and (data.resultID or (data.GetData and data:GetData().resultID))
        if resultID then decorateSearchEntry(frame, resultID) end
    end)
end

----------------------------------------------------------------------
-- Applicants (people applying to YOUR group)
--
-- The application viewer's member row has a fixed column layout
-- (Name | Role | iLvl | Rating | accept/decline) with no spare room on
-- the right. The most reliable place to attach our badge is appended to
-- the existing Name FontString — it sits in the leftmost column and is
-- generally short.
----------------------------------------------------------------------

local function decorateApplicantMember(memberFrame, applicantID, memberIdx)
    if not memberFrame or not enabled() then return end
    if not C_LFGList or not C_LFGList.GetApplicantMemberInfo then return end

    -- IMPORTANT: GetApplicantMemberInfo returns a multi-value tuple, not a
    -- table. The first return is the player's full "Name-Realm" string,
    -- which can be a Blizzard secret string in cross-faction listings.
    local name = C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)
    local lname, lrealm = splitNameRealm(name)
    if not lname or lname == "" then return end

    local badge = LFG.GetBadge(lname, lrealm, nil)
    if not badge then return end

    -- Try the common FontString fields used across UI versions.
    local label = memberFrame.Name or memberFrame.NameText or memberFrame.Text
    appendBadgeToText(label, badge)
end

-- Fallback sweep over the application viewer's ScrollBox. Used because
-- the per-member hook function name has changed across patches; this
-- guarantees decoration as long as the panel is open and populated.
local function refreshAllVisibleApplicants()
    local panel = LFGListFrame and LFGListFrame.ApplicationViewer
    if not panel then return end
    local scroll = panel.ScrollBox
    if not scroll or not scroll.ForEachFrame then return end
    scroll:ForEachFrame(function(row)
        local data = row.GetElementData and row:GetElementData()
        local applicantID = data and (data.applicantID or (data.GetData and data:GetData().applicantID))
        if not applicantID then
            -- Some layouts stash the id directly on the frame.
            applicantID = row.applicantID
        end
        if not applicantID then return end
        if row.Members then
            for idx, memberFrame in ipairs(row.Members) do
                decorateApplicantMember(memberFrame, applicantID, idx)
            end
        else
            decorateApplicantMember(row, applicantID, 1)
        end
    end)
end

-- Hook Blizzard's per-member updater (when present) so we repaint
-- immediately on each row refresh. The fallback sweep above covers
-- versions where this function was renamed/removed.
local function installApplicantHook()
    if LFG._applicantHookInstalled then return end
    if type(LFGListApplicationViewer_UpdateApplicantMember) == "function" then
        hooksecurefunc("LFGListApplicationViewer_UpdateApplicantMember",
            function(member, appID, memberIdx)
                decorateApplicantMember(member, appID, memberIdx or 1)
            end)
        LFG._applicantHookInstalled = true
    end
end

local function installSearchHook()
    if LFG._searchHookInstalled then return end
    if type(LFGListSearchEntry_Update) == "function" then
        hooksecurefunc("LFGListSearchEntry_Update", function(self)
            if self and self.resultID then
                decorateSearchEntry(self, self.resultID)
            end
        end)
        LFG._searchHookInstalled = true
    end
end

----------------------------------------------------------------------
-- Mouseover tooltip on a search-result entry
--
-- Blizzard builds the hover tooltip via LFGListUtil_SetSearchEntryTooltip
-- which appends lines to GameTooltip. We add a Cadence line at the end
-- so users get the leader's score (or NC) without staring at the row.
----------------------------------------------------------------------

local function installTooltipHook()
    if LFG._tooltipHookInstalled then return end
    if type(LFGListUtil_SetSearchEntryTooltip) ~= "function" then return end
    hooksecurefunc("LFGListUtil_SetSearchEntryTooltip", function(tooltip, resultID)
        if not enabled() or not tooltip or not resultID then return end
        local info = C_LFGList.GetSearchResultInfo(resultID)
        if not info then return end
        local lname, lrealm = splitNameRealm(info.leaderName)
        if not lname or lname == "" then return end

        local category = categoryForActivity(info.activityID)
        local key   = buildKey(lname, lrealm)
        local entry = key and CadenceScoresDB and CadenceScoresDB[key]
        local score, n
        if entry then score, n = scoreFor(entry, category) end

        tooltip:AddLine(" ")
        if score then
            local r, g, b = scoreColour(score)
            local text = string.format("Cadence: %d", score)
            if n and n > 0 then
                text = text .. string.format("  |cff808080(n=%d)|r", n)
            end
            tooltip:AddLine(text, r, g, b)
        else
            -- "No Cadence" — keep the same N/C colouring as the row badge.
            tooltip:AddLine("Cadence: |cffffffffN|r|cffffd100C|r|cff808080  no data yet|r", 1, 1, 1)
        end
        tooltip:Show()
    end)
    LFG._tooltipHookInstalled = true
end

----------------------------------------------------------------------
-- Mouseover tooltip on an applicant member row (your own group's
-- applicants window). Blizzard's `LFGListApplicantMember_OnEnter` builds
-- the per-member tooltip; we append a Cadence line at the end.
----------------------------------------------------------------------

local function installApplicantTooltipHook()
    if LFG._applicantTooltipHookInstalled then return end
    if type(LFGListApplicantMember_OnEnter) ~= "function" then return end
    hooksecurefunc("LFGListApplicantMember_OnEnter", function(self)
        if not enabled() or not self then return end
        local applicantID = self:GetParent() and self:GetParent().applicantID
        local memberIdx   = self.memberIdx or 1
        if not applicantID then return end

        local name = C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)
        local lname, lrealm = splitNameRealm(name)
        if not lname or lname == "" then return end

        local key   = buildKey(lname, lrealm)
        local entry = key and CadenceScoresDB and CadenceScoresDB[key]
        local score, n
        if entry then score, n = scoreFor(entry, nil) end

        GameTooltip:AddLine(" ")
        if score then
            local r, g, b = scoreColour(score)
            local text = string.format("Cadence: %d", score)
            if n and n > 0 then
                text = text .. string.format("  |cff808080(n=%d)|r", n)
            end
            GameTooltip:AddLine(text, r, g, b)
        else
            GameTooltip:AddLine("Cadence: |cffffffffN|r|cffffd100C|r|cff808080  no data yet|r", 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    LFG._applicantTooltipHookInstalled = true
end

----------------------------------------------------------------------
-- Event wiring
----------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED")
eventFrame:RegisterEvent("LFG_LIST_SEARCH_RESULT_UPDATED")
eventFrame:RegisterEvent("LFG_LIST_APPLICANT_LIST_UPDATED")
eventFrame:RegisterEvent("LFG_LIST_APPLICANT_UPDATED")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == "Blizzard_GroupFinder" or arg1 == "Blizzard_PVPUI" then
            installSearchHook()
            installApplicantHook()
            installTooltipHook()
            installApplicantTooltipHook()
        end
        return
    end

    if not enabled() then return end

    if event == "PLAYER_LOGIN" then
        installSearchHook()
        installApplicantHook()
        installTooltipHook()
        installApplicantTooltipHook()
        if LFGListFrame and LFGListFrame.SearchPanel and LFGListFrame.SearchPanel.ScrollBox then
            C_Timer.After(0.1, refreshAllVisibleSearchEntries)
        end
        return
    end

    if event == "LFG_LIST_SEARCH_RESULTS_RECEIVED"
       or event == "LFG_LIST_SEARCH_RESULT_UPDATED" then
        C_Timer.After(0.05, refreshAllVisibleSearchEntries)
        return
    end

    if event == "LFG_LIST_APPLICANT_LIST_UPDATED"
       or event == "LFG_LIST_APPLICANT_UPDATED" then
        -- Two passes: immediate (catches existing rows) and short-deferred
        -- (catches rows that Blizzard repaints after our handler returns).
        refreshAllVisibleApplicants()
        C_Timer.After(0.05, refreshAllVisibleApplicants)
        C_Timer.After(0.25, refreshAllVisibleApplicants)
        return
    end
end)

----------------------------------------------------------------------
-- Slash command diagnostic: /cadence lfg <name-realm>
----------------------------------------------------------------------

function LFG.DebugLookup(key)
    if not key or key == "" then
        print("|cffffcc00Cadence:|r usage /cadence lfg Name-Realm")
        return
    end
    local entry = CadenceScoresDB and CadenceScoresDB[key]
    if not entry then
        print("|cffffcc00Cadence:|r no data for " .. key)
        return
    end
    print(string.format(
        "|cffffcc00Cadence|r %s: overall=%s m+=%s raid=%s pvp=%s (n=%d, role=%s, class=%s)",
        key, tostring(entry.s), tostring(entry.m), tostring(entry.r),
        tostring(entry.p), entry.n or 0,
        tostring(entry.ro), tostring(entry.cl)))
end

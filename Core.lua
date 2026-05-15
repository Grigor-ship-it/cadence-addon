--[[
    Cadence - Core.lua
    Addon initialization, saved variables, slash commands.
]]

local ADDON_NAME, PC = ...

PC.Core = {}
local Core = PC.Core

---------------------------------------------------------------------------
-- Defaults for SavedVariables
---------------------------------------------------------------------------
local DB_DEFAULTS = {
    profile = {
        claimToken = nil,  -- generated once on first load, persists forever
        windowPos = { point = "CENTER", x = 0, y = 0 },
        windowWidth = 220,
        windowHeight = 300,
        locked = false,
        showMinimap = true,
        barHeight = 20,
        maxRows = 30,
        barTexture = "pointed",
        fontSize = 11,
        updateInterval = 0.5,   -- UI refresh rate in seconds
        scoring = {
            apmWeight         = 0.55,
            uptimeWeight      = 0.45,
        },
        algorithm = {
            curveK            = 1.6,   -- negative-exponential steepness
            dedupWindow       = 0.40,  -- 400ms dedup per unit
            bucketSize        = 10,    -- seconds per consistency bucket
            uptimeGapMax      = 2.5,   -- max gap to count as "active"
            gapPenThresh      = 8.0,   -- gaps exceeding this incur penalty
            gapPenPerSec      = 0.6,   -- penalty points per excess second
            gapPenCap         = 30,    -- maximum gap penalty
        },
        thresholds = {
            afkAPM       = 5,   -- below this APM = suspected AFK
            longGapSec   = 10,  -- a single gap this long = flagged
            warningAPM   = 8,   -- below this = low engagement warning
            activeGapMax = 3.0, -- max seconds between actions to count as "active"
        },
        roleAPM = {
            DAMAGER_MELEE  = 34,
            DAMAGER_RANGED = 26,
            HEALER         = 24,
            TANK           = 30,
        },
        autoShowInCombat = false,
        autoSegmentTrash = true,
        maxSegmentHistory = 10,
        submitURL = "",  -- custom backend URL for QR code (empty = default)
        lfgOverlay = true,  -- show Cadence scores in Blizzard Group Finder
        brezAdvisor = {
            enabled    = true,   -- show rez-worthiness badge on raid frames
            threshold  = 60,     -- score below this = "not worth rezzing"
            minSamples = 30,     -- need this many seconds of combat data before judging
        },
    },
    segments = {},
}

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGIN")

initFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        -- Initialize SavedVariables
        if not CadenceDB then
            CadenceDB = PC.Utils.DeepCopy(DB_DEFAULTS)
        else
            -- Merge defaults for any missing keys
            Core.MergeDefaults(CadenceDB, DB_DEFAULTS)
        end
        PC.db = CadenceDB

        -- Generate claim token on first load (persists in SavedVariables)
        if not PC.db.profile.claimToken then
            local t = time()
            local r1 = math.random(0, 0xFFFFFF)
            local r2 = math.random(0, 0xFFFFFF)
            PC.db.profile.claimToken = string.format("%08x%06x%06x", t, r1, r2)
        end

        -- One-time migration: raise old maxRows=15 default so full raids show
        if PC.db.profile.maxRows and PC.db.profile.maxRows < 25 then
            PC.db.profile.maxRows = 30
        end

        -- Update role baselines from saved data
        for k, v in pairs(PC.db.profile.roleAPM) do
            PC.ROLE_EXPECTED_APM[k] = v
        end

        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGIN" then
        -- Scan initial roster
        PC.Utils.ScanGroupRoster()

        -- Initialize subsystems
        if PC.MeterData and PC.MeterData.Init then PC.MeterData.Init() end
        if PC.Polling and PC.Polling.Init then PC.Polling.Init() end
        if PC.Events and PC.Events.Init then PC.Events.Init() end
        if PC.Segments and PC.Segments.Init then PC.Segments.Init() end
        if PC.Comm and PC.Comm.Init then PC.Comm.Init() end
        if PC.UI_Meter and PC.UI_Meter.Init then PC.UI_Meter.Init() end
        if PC.Options and PC.Options.Init then PC.Options.Init() end
        if PC.UI_BRezAdvisor and PC.UI_BRezAdvisor.Init then PC.UI_BRezAdvisor.Init() end

        print("|cffffffffCad|r|cffFFD666ence|r v" .. PC.VERSION .. " loaded. Type |cffFFD666/cadence|r to toggle.")

        -- Restore custom submit URL if set
        if PC.db.profile.submitURL and PC.db.profile.submitURL ~= "" then
            if PC.UI_QR and PC.UI_QR.SetBaseURL then
                PC.UI_QR.SetBaseURL(PC.db.profile.submitURL)
                print("|cffffffffCad|r|cffFFD666ence|r: QR URL restored: |cff88ff88" .. PC.db.profile.submitURL .. "|r")
            end
        end

        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)

---------------------------------------------------------------------------
-- Deep merge defaults into existing table
---------------------------------------------------------------------------
function Core.MergeDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then
                target[k] = {}
            end
            Core.MergeDefaults(target[k], v)
        else
            if target[k] == nil then
                target[k] = v
            end
        end
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_CADENCE1 = "/cadence"
SLASH_CADENCE2 = "/cad"

SlashCmdList["CADENCE"] = function(input)
    local cmd = strtrim(input or ""):lower()

    if cmd == "" then
        -- Toggle main window
        if PC.UI_Meter and PC.UI_Meter.Toggle then
            PC.UI_Meter.Toggle()
        end

    elseif cmd == "reset" then
        if PC.Tracker and PC.Tracker.ResetAll then
            PC.Tracker.ResetAll()
        end
        if PC.Segments and PC.Segments.ResetAll then
            PC.Segments.ResetAll()
        end
        print("|cffffffffCad|r|cffFFD666ence|r: Data reset.")

    elseif cmd == "config" or cmd == "options" then
        if PC.Options and PC.Options.Open then
            PC.Options.Open()
        end

    elseif cmd == "lock" then
        PC.db.profile.locked = not PC.db.profile.locked
        if PC.UI_Meter and PC.UI_Meter.ApplyLock then
            PC.UI_Meter.ApplyLock()
        end
        local state = PC.db.profile.locked and "locked" or "unlocked"
        print("|cffffffffCad|r|cffFFD666ence|r: Window " .. state .. ".")

    elseif cmd == "debug" then
        if PC.Events and PC.Events.SetDebug then
            local isOn = PC.Events.IsDebug and PC.Events.IsDebug() or false
            PC.Events.SetDebug(not isOn)
        end
        -- Also dump current state
        local playerData = PC.Tracker and PC.Tracker.GetAllPlayerData() or {}
        local count = 0
        for guid, pd in pairs(playerData) do
            count = count + 1
            print(string.format("  Player: %s  Actions: %d  GUID: %s",
                tostring(pd.name), pd.actionCount or 0, tostring(guid)))
        end
        if count == 0 then
            print("|cffffffffCad|r|cffFFD666ence|r: No player data recorded yet.")
        end

    elseif cmd == "minimap" then
        PC.db.profile.showMinimap = not PC.db.profile.showMinimap
        print("|cffffffffCad|r|cffFFD666ence|r: Minimap icon " ..
              (PC.db.profile.showMinimap and "shown" or "hidden") .. ".")

    elseif cmd == "sync" then
        -- Show who in the party/raid is running Cadence
        if PC.Comm and PC.Comm.ShowSync then
            PC.Comm.ShowSync()
        else
            print("|cffffffffCad|r|cffFFD666ence|r: Comm module not loaded.")
        end

    elseif cmd == "dump-comm" then
        -- Debug dump of comm state + peer table
        if PC.Comm and PC.Comm.DumpDebug then
            PC.Comm.DumpDebug()
        end

    elseif cmd == "brez" or cmd:match("^brez%s") then
        local arg = cmd:match("^brez%s+(.+)")
        if not arg or arg == "" then
            -- Toggle on/off
            local cur = PC.db.profile.brezAdvisor and PC.db.profile.brezAdvisor.enabled
            if PC.UI_BRezAdvisor and PC.UI_BRezAdvisor.SetEnabled then
                PC.UI_BRezAdvisor.SetEnabled(not cur)
            end
            print("|cffffffffCad|r|cffFFD666ence|r: BRez Advisor " ..
                  ((not cur) and "ON" or "OFF") .. ".")
        else
            local n = tonumber(arg)
            if n and PC.UI_BRezAdvisor and PC.UI_BRezAdvisor.SetThreshold then
                PC.UI_BRezAdvisor.SetThreshold(n)
                print(string.format("|cffffffffCad|r|cffFFD666ence|r: BRez threshold set to %d.", n))
            else
                print("|cffffffffCad|r|cffFFD666ence|r: Usage: /cad brez (toggle) or /cad brez <0-100> (threshold).")
            end
        end

    elseif cmd:match("^segment") then
        local n = tonumber(cmd:match("(%d+)"))
        if n and PC.Segments and PC.Segments.SwitchTo then
            PC.Segments.SwitchTo(n)
        else
            print("|cffffffffCad|r|cffFFD666ence|r: Usage: /cad segment <number>")
        end

    elseif cmd == "summary" then
        if PC.UI_Summary and PC.UI_Summary.ShowLatest then
            PC.UI_Summary.ShowLatest()
        else
            print("|cffffffffCad|r|cffFFD666ence|r: No summary data available.")
        end

    elseif cmd:match("^view") then
        -- /cad view              -> show card for current target
        -- /cad view Name          -> same realm
        -- /cad view Name-Realm    -> explicit realm
        local arg = cmd:match("^view%s+(.+)")
        if not arg or arg == "" then
            if UnitExists("target") and UnitIsPlayer("target") then
                if PC.UI_PlayerCard and PC.UI_PlayerCard.ShowForUnit then
                    PC.UI_PlayerCard.ShowForUnit("target")
                end
            else
                print("|cffffffffCad|r|cffFFD666ence|r: Usage: /cad view <Name> or /cad view <Name-Realm> (or target a player).")
            end
        else
            local name, realm = arg:match("^([^-]+)-(.+)$")
            if not name then
                name = arg
                realm = GetNormalizedRealmName()
            end
            if PC.UI_PlayerCard and PC.UI_PlayerCard.Show then
                PC.UI_PlayerCard.Show(name, realm)
            end
        end

    elseif cmd == "test" then
        print("|cffffffffCad|r|cffFFD666ence Self-Test:|r")
        print("  Mode: Midnight 12.0 (UNIT_SPELLCAST_SUCCEEDED)")
        print("  C_Spell: " .. (C_Spell and C_Spell.GetSpellInfo and "OK" or "MISSING"))
        print("  C_DamageMeter: " .. (C_DamageMeter and "OK" or "not present"))
        print("  ACTION_SUB_EVENTS: " .. (PC.ACTION_SUB_EVENTS and "OK" or "MISSING"))
        print("  Tracker: " .. (PC.Tracker and PC.Tracker.RecordAction and "OK" or "MISSING"))
        print("  UnitGUID(player): " .. tostring(UnitGUID("player")))
        print("  Player name: " .. tostring(UnitName("player")))
        if PC.Events and PC.Events.SelfTest then
            PC.Events.SelfTest()
        end

    elseif cmd == "dump" then
        if PC.Events and PC.Events.DumpPullReport then
            PC.Events.DumpPullReport()
        else
            print("|cffffffffCad|r|cffFFD666ence|r: dump unavailable.")
        end

    elseif cmd:match("^url") then
        local url = cmd:match("^url%s+(.+)")
        if url and PC.UI_QR and PC.UI_QR.SetBaseURL then
            PC.UI_QR.SetBaseURL(url)
            -- Persist across reloads
            if PC.db and PC.db.profile then
                PC.db.profile.submitURL = url
            end
            print("|cffffffffCad|r|cffFFD666ence|r: QR submit URL set to: " .. url)
        else
            print("|cffffffffCad|r|cffFFD666ence|r: Usage: /cad url http://192.168.1.X:3000/s")
        end

    elseif cmd:match("^lfg") then
        local key = cmd:match("^lfg%s+(.+)")
        if PC.UI and PC.UI.LFG and PC.UI.LFG.DebugLookup then
            PC.UI.LFG.DebugLookup(key)
        else
            print("|cffffffffCad|r|cffFFD666ence|r: LFG overlay not loaded.")
        end

    elseif cmd == "qr" then
        if PC.UI_Summary and PC.UI_Summary.ShowLatest then
            PC.UI_Summary.ShowLatest()
        end
        -- Also show QR for the latest segment
        C_Timer.After(0.2, function()
            if PC.Segments and PC.Segments.GetCount() > 0 then
                local seg = PC.Segments.GetSegment(1)
                if seg and PC.UI_QR and PC.UI_QR.ShowForSegment then
                    PC.UI_QR.ShowForSegment(seg)
                end
            else
                print("|cffffffffCad|r|cffFFD666ence|r: No segment data for QR code.")
            end
        end)

    else
        print("|cffffffffCad|r|cffFFD666ence|r commands:")
        print("  /cadence     - Toggle meter window")
        print("  /cad reset   - Reset all data")
        print("  /cad config  - Open options")
        print("  /cad lock    - Lock/unlock window")
        print("  /cad summary - Show last encounter summary")
        print("  /cad qr      - Show QR code for last encounter")
        print("  /cad url <url> - Set QR backend URL (testing)")
        print("  /cad debug   - Toggle debug mode + dump state")
        print("  /cad dump    - Per-player polling + meter report (run after a pull)")
        print("  /cad minimap - Toggle minimap icon")
        print("  /cad segment N - Switch to segment N")
        print("  /cad test    - Run self-diagnostics")
    end
end

PC.Core = Core

--[[
    Cadence - Polling.lua  (v4 — live Current-session polling)

    WoW Midnight 12.0.5 killed COMBAT_LOG_EVENT_UNFILTERED for addons.
    The other two viable activity signals are:

      1. UNIT_SPELLCAST_SUCCEEDED for visible party/raid units
         (hardcasts only — feeds CreditActivityTick in Events.lua).
      2. UNIT_POWER_UPDATE — catches instant-cast specs by detecting
         resource spend (also feeds CreditActivityTick).

    Both miss certain edge cases (channeled spells, off-spec procs,
    pet-only damage windows, etc.).  This module is the third channel:

      * Every POLL_INTERVAL seconds during combat, query the rolling
        20s Current session for DamageDone + HealingDone.
      * For each non-secret source where amountPerSecond > 0, that
        player did *something* in the last 20s -> credit one tick via
        Events.CreditPollActivity which shares the same 0.5s per-GUID
        throttle as the spellcast/power channels.
      * Secret sources are skipped *individually* (not the whole read)
        so a single hardware-locked source no longer kills enrichment
        for everyone else.

    Why this is sound:
      * Three independent signals all funnel into ONE throttled tick
        channel -> no double-counting.
      * Throttle caps observed APM at 120, well above realistic play.
      * The previous v3 approach (synthetic flood: 1 tick per second of
        fight to anyone who did damage) inflated everyone to ~60+ iAPM
        baseline and pinned uptime to 100% -> engagement scores all
        clustered at 95-99 regardless of real play.  REMOVED.

    Limitations:
      * Current session's amountPerSecond reflects the rolling 20s
        window, so a single tick from polling means "active sometime
        in the last 20s" — coarse, but combined with the spellcast +
        power-update channels it's plenty accurate at the segment level.
]]

local ADDON_NAME, PC = ...

PC.Polling = {}
local Polling = PC.Polling

local Tracker
local Utils

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local POLL_INTERVAL  = 2.0   -- seconds between live in-combat polls
local FLUSH_DELAY    = 1.5   -- one extra poll this long after combat ends to catch
                              -- the final 20s window once secrets unlock

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local active     = false
local ticker     = nil
local flushTimer = nil
local debugMode  = false

-- Session-level diagnostics (per pull)
local pollStats = { polls = 0, sourcesSeen = 0, ticksCredited = 0, secretsSkipped = 0 }

---------------------------------------------------------------------------
-- Internal: poll the rolling Current session once and credit any source
-- whose amountPerSecond > 0 with a single activity tick.
-- Returns the number of ticks credited this poll.
---------------------------------------------------------------------------
local function PollCurrentOnce()
    if not Tracker then return 0 end
    if not (PC.MeterData and PC.MeterData.IsAvailable and PC.MeterData.IsAvailable()) then
        return 0
    end
    if not C_DamageMeter or not C_DamageMeter.GetCombatSessionFromType then
        return 0
    end
    local sessionType = PC.MeterData.GetSessionCurrent and PC.MeterData.GetSessionCurrent()
    if sessionType == nil then return 0 end

    local rosterGUIDs = PC.Events and PC.Events.GetRosterGUIDs and PC.Events.GetRosterGUIDs()
    if not rosterGUIDs then return 0 end

    local meterTypes = {}
    if Enum and Enum.DamageMeterType then
        if Enum.DamageMeterType.DamageDone  then meterTypes[#meterTypes + 1] = Enum.DamageMeterType.DamageDone  end
        if Enum.DamageMeterType.HealingDone then meterTypes[#meterTypes + 1] = Enum.DamageMeterType.HealingDone end
    end
    if #meterTypes == 0 then return 0 end

    local now = GetTime()
    local credited = {}        -- de-dup across DamageDone + HealingDone within one poll
    local creditedCount = 0
    local secretsSkipped = 0
    local sourcesSeen = 0

    for _, mt in ipairs(meterTypes) do
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, mt)
        if ok and session and session.combatSources then
            local sources = session.combatSources
            for i = 1, #sources do
                local src = sources[i]
                if src then
                    sourcesSeen = sourcesSeen + 1
                    local guid = src.sourceGUID
                    local aps  = src.amountPerSecond

                    -- Skip individually-secret sources (hardware-locked this tick).
                    -- Critically, do NOT abort the whole loop — other sources are
                    -- usually readable even when one isn't.
                    local guidSecret = (issecretvalue and guid ~= nil and issecretvalue(guid))
                    local apsSecret  = (issecretvalue and aps  ~= nil and issecretvalue(aps))

                    if guidSecret or apsSecret then
                        secretsSkipped = secretsSkipped + 1
                    elseif type(guid) == "string" and guid ~= ""
                       and guid:sub(1, 4) ~= "Pet-"
                       and rosterGUIDs[guid]
                       and not credited[guid] then
                        local rate = tonumber(aps) or 0
                        if rate > 0 then
                            -- Funnel through Events so the shared 0.5s throttle
                            -- prevents triple-counting with spellcast/power events.
                            if PC.Events and PC.Events.CreditPollActivity then
                                if PC.Events.CreditPollActivity(guid, now) then
                                    credited[guid] = true
                                    creditedCount = creditedCount + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    pollStats.polls = pollStats.polls + 1
    pollStats.sourcesSeen = pollStats.sourcesSeen + sourcesSeen
    pollStats.ticksCredited = pollStats.ticksCredited + creditedCount
    pollStats.secretsSkipped = pollStats.secretsSkipped + secretsSkipped

    return creditedCount
end

---------------------------------------------------------------------------
-- Public: start polling — idempotent.
---------------------------------------------------------------------------
function Polling.Start()
    if active then return end
    active = true

    pollStats.polls = 0
    pollStats.sourcesSeen = 0
    pollStats.ticksCredited = 0
    pollStats.secretsSkipped = 0

    if flushTimer then flushTimer:Cancel(); flushTimer = nil end
    if ticker then ticker:Cancel(); ticker = nil end

    -- Run one poll immediately, then every POLL_INTERVAL seconds.
    pcall(PollCurrentOnce)
    ticker = C_Timer.NewTicker(POLL_INTERVAL, function()
        if not active then return end
        pcall(PollCurrentOnce)
    end)
end

---------------------------------------------------------------------------
-- Public: stop polling.  Schedules one final poll FLUSH_DELAY seconds
-- later to catch any activity from the last few seconds of combat once
-- the post-combat secret unlock has happened.
---------------------------------------------------------------------------
function Polling.Stop()
    if not active then return end
    active = false
    if ticker then ticker:Cancel(); ticker = nil end

    if flushTimer then flushTimer:Cancel() end
    flushTimer = C_Timer.NewTimer(FLUSH_DELAY, function()
        pcall(PollCurrentOnce)
        flushTimer = nil
        if debugMode then
            print(string.format(
                "|cffFFD666Cadence Polling|r: pull complete — %d polls, %d sources seen, %d ticks credited, %d secrets skipped",
                pollStats.polls, pollStats.sourcesSeen, pollStats.ticksCredited, pollStats.secretsSkipped))
        end
    end)
end

---------------------------------------------------------------------------
-- Public: hard reset.
---------------------------------------------------------------------------
function Polling.Reset()
    if ticker then ticker:Cancel(); ticker = nil end
    if flushTimer then flushTimer:Cancel(); flushTimer = nil end
    active = false
    pollStats.polls = 0
    pollStats.sourcesSeen = 0
    pollStats.ticksCredited = 0
    pollStats.secretsSkipped = 0
end

function Polling.IsActive()
    return active
end

function Polling.SetDebug(on)
    debugMode = on
end

---------------------------------------------------------------------------
-- Init: called from Core.lua on PLAYER_LOGIN, after MeterData.Init.
---------------------------------------------------------------------------
function Polling.Init()
    Tracker = PC.Tracker
    Utils   = PC.Utils
end

PC.Polling = Polling

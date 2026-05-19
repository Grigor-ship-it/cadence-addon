-- ============================================================================
-- Comm.lua — Cadence addon-to-addon group sync (v1.1.0)
-- ============================================================================
--
-- Purpose
-- -------
-- When two or more party/raid members run Cadence, every player's addon
-- broadcasts its *own self-observed* metrics (the only data each client can
-- measure with 100% accuracy via UNIT_SPELLCAST_SUCCEEDED). Receivers store
-- peer reports in a small in-memory table keyed by GUID. This gives every
-- member of the group an identical view of everyone's numbers and removes
-- the long-standing combat-log-range divergence problem.
--
-- v1.1.0 scope (this file):
--   * Wire protocol: hello / snapshot / final messages
--   * Peer data store with TTL
--   * Sync-status query API for UI ("X/Y synced")
--   * No display integration yet — meter rows still read from local Tracker.
--     The UI badge proves the protocol works in groups; once proven we'll
--     swap meter rows to read peer.players in v1.1.1.
--
-- Wire format
-- -----------
-- Every message:  "<protocolVer>:<type>:<...payload...>"
-- protocolVer = "1"  (receivers silently ignore other versions)
-- type        = "H" hello | "S" snapshot | "F" final
--
--   H : 1:H:<addonVersion>
--       Sent on GROUP_ROSTER_UPDATE (throttled 1/30s) and on first PLAYER_LOGIN
--       after entering a group. Receiver records peer's addon version.
--
--   S : 1:S:<segId>:<elapsed>:<events>:<intentEvents>:<uptimeMs>:<apmX10>:<role>:<specId>
--       Sent every SNAPSHOT_INTERVAL seconds during combat. Self-data only.
--
--   F : 1:F:<segId>:<duration>:<events>:<intentEvents>:<uptimeMs>:<apmX10>:<role>:<specId>:<score>
--       Sent ONCE on ENCOUNTER_END / CHALLENGE_MODE_COMPLETED with the
--       finalized segment. Score is the locally-computed Cadence composite.
--
-- segId = short hash of (encounterID..segmentStart) so peers can associate
--         messages with the right pull when wipes/multi-pulls happen.
--
-- Trust ceiling
-- -------------
-- A malicious addon could send fake numbers. v1.1.0 mitigations:
--   * apmX10 capped at MAX_APM_X10 (= 2500 → 250 APM) on receive
--   * uptimeMs capped at 2× elapsed
--   * Backend already cross-checks via corroboration (Phase 1) — divergence
--     between a player's self-report and other reporters' observations of
--     them lowers reporter_trust.
--   * v1.2 will add signed messages once we have per-encounter server tokens.
-- ============================================================================

local ADDON_NAME, PC = ...
PC.Comm = {}
local Comm = PC.Comm

-- ── Constants ──────────────────────────────────────────────────────────
local PREFIX            = "Cadence"
local PROTOCOL_VERSION  = "1"
local SNAPSHOT_INTERVAL = 3.0           -- seconds between in-combat broadcasts
local HELLO_MIN_GAP     = 30            -- min seconds between hello rebroadcasts
local PEER_TTL          = 120           -- drop a peer after 2 min of silence
local MAX_APM_X10       = 2500          -- cap on accepted APM (250 APM)
local ADDON_VERSION     = "1.2.1"       -- bump on wire format change

-- ── State ──────────────────────────────────────────────────────────────
-- peers[guid] = {
--   version   = "1.1.0",
--   name      = "Devour",
--   lastSeen  = GetTime(),
--   latest    = { segId, elapsed, events, intentEvents, uptimeMs,
--                 apmX10, role, specId, isFinal, score }
-- }
local peers = {}

local commFrame      = nil  -- CHAT_MSG_ADDON listener frame
local snapshotTicker = nil  -- C_Timer ticker handle (active only during combat)
local lastHelloSent  = 0
local lastSnapshot   = nil  -- last sent payload string (skip duplicates)
local currentSegId   = nil  -- short id for the active segment
local prefixRegistered = false

-- ── Utility ────────────────────────────────────────────────────────────

local function dprint(...)
    if PC.db and PC.db.profile and PC.db.profile.debug then
        print("|cFFE0B23A[Cadence Comm]|r", ...)
    end
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function pickChannel()
    -- Cross-realm M+ groups need INSTANCE_CHAT so messages reach the realm
    -- group's instance bus rather than the home-realm party channel.
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
    return nil
end

-- Tiny stable hash for segment IDs. Same encounter on different clients
-- should produce identical IDs as long as encounterID + startTime match.
local function shortHash(s)
    s = tostring(s or "")
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 2147483647
    end
    return string.format("%x", h)
end

-- ── Outbound ───────────────────────────────────────────────────────────

local function sendRaw(payload)
    local channel = pickChannel()
    if not channel then return end
    if not prefixRegistered then return end

    -- C_ChatInfo.SendAddonMessage is rate-limited by Blizzard; payload must
    -- be ≤ 255 bytes. Our snapshots are ~60 bytes so we're well under.
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, payload, channel)
    end
end

function Comm.SendHello(force)
    local now = GetTime()
    if not force and (now - lastHelloSent) < HELLO_MIN_GAP then return end
    lastHelloSent = now
    sendRaw(string.format("%s:H:%s", PROTOCOL_VERSION, ADDON_VERSION))
    dprint("hello sent")
end

-- Build the current self-snapshot. Returns nil if nothing to send.
local function buildSelfSnapshot()
    if not PC.Tracker or not PC.Tracker.SnapshotPlayer then return nil end
    local guid = UnitGUID("player")
    if not guid then return nil end
    local snap = PC.Tracker.SnapshotPlayer(guid)
    if not snap then return nil end

    local elapsed      = snap.combatDuration or 0
    if elapsed <= 0 then return nil end

    local events       = snap.actionCount or 0
    local intentEvents = snap.intentActionCount or 0
    local apmX10       = math.floor(((snap.apm or 0) * 10) + 0.5)
    local uptimeMs     = math.floor((snap.intentUptime or snap.uptime or 0) * elapsed * 10) -- 0.1ms units
    local role         = snap.role or "DAMAGER"

    local specIndex = GetSpecialization and GetSpecialization()
    local specId    = 0
    if specIndex and GetSpecializationInfo then
        local id = GetSpecializationInfo(specIndex)
        if id then specId = id end
    end

    return {
        segId        = currentSegId or "0",
        elapsed      = math.floor(elapsed),
        events       = events,
        intentEvents = intentEvents,
        uptimeMs     = uptimeMs,
        apmX10       = clamp(apmX10, 0, MAX_APM_X10),
        role         = role,
        specId       = specId,
    }
end

function Comm.SendSnapshot()
    if not pickChannel() then return end
    local s = buildSelfSnapshot()
    if not s then return end

    local payload = string.format(
        "%s:S:%s:%d:%d:%d:%d:%d:%s:%d",
        PROTOCOL_VERSION,
        s.segId, s.elapsed, s.events, s.intentEvents,
        s.uptimeMs, s.apmX10, s.role, s.specId
    )

    -- Skip if identical to last send (saves chat bandwidth between pulls)
    if payload == lastSnapshot then return end
    lastSnapshot = payload
    sendRaw(payload)
end

function Comm.SendFinal(score)
    if not pickChannel() then return end
    local s = buildSelfSnapshot()
    if not s then return end

    score = clamp(math.floor(tonumber(score) or 0), 0, 100)
    local payload = string.format(
        "%s:F:%s:%d:%d:%d:%d:%d:%s:%d:%d",
        PROTOCOL_VERSION,
        s.segId, s.elapsed, s.events, s.intentEvents,
        s.uptimeMs, s.apmX10, s.role, s.specId, score
    )
    sendRaw(payload)
    dprint("final sent", payload)
end

-- ── Segment lifecycle (called from Events.lua) ─────────────────────────

function Comm.OnSegmentStart(encounterID, startTimestamp)
    currentSegId = shortHash(tostring(encounterID or 0) .. "-" .. tostring(startTimestamp or time()))
    lastSnapshot = nil

    if snapshotTicker then snapshotTicker:Cancel() end
    if pickChannel() and C_Timer and C_Timer.NewTicker then
        snapshotTicker = C_Timer.NewTicker(SNAPSHOT_INTERVAL, Comm.SendSnapshot)
    end
    dprint("segment start", currentSegId)
end

function Comm.OnSegmentEnd(finalScore)
    if snapshotTicker then
        snapshotTicker:Cancel()
        snapshotTicker = nil
    end
    Comm.SendFinal(finalScore)
    -- Keep segId valid for a moment so any late peer F messages line up,
    -- then clear on next segment start.
end

-- ── Inbound parser ─────────────────────────────────────────────────────

local function parseSnapshot(rest)
    -- segId:elapsed:events:intentEvents:uptimeMs:apmX10:role:specId
    local segId, elapsed, events, intent, uptime, apm, role, spec =
        strsplit(":", rest, 8)
    return {
        segId        = segId,
        elapsed      = tonumber(elapsed) or 0,
        events       = tonumber(events) or 0,
        intentEvents = tonumber(intent) or 0,
        uptimeMs     = tonumber(uptime) or 0,
        apmX10       = clamp(tonumber(apm) or 0, 0, MAX_APM_X10),
        role         = role or "DAMAGER",
        specId       = tonumber(spec) or 0,
        isFinal      = false,
    }
end

local function parseFinal(rest)
    -- segId:duration:events:intentEvents:uptimeMs:apmX10:role:specId:score
    local segId, dur, events, intent, uptime, apm, role, spec, score =
        strsplit(":", rest, 9)
    return {
        segId        = segId,
        elapsed      = tonumber(dur) or 0,
        events       = tonumber(events) or 0,
        intentEvents = tonumber(intent) or 0,
        uptimeMs     = tonumber(uptime) or 0,
        apmX10       = clamp(tonumber(apm) or 0, 0, MAX_APM_X10),
        role         = role or "DAMAGER",
        specId       = tonumber(spec) or 0,
        score        = clamp(tonumber(score) or 0, 0, 100),
        isFinal      = true,
    }
end

local function onAddonMessage(prefix, msg, _channel, sender)
    if prefix ~= PREFIX then return end
    if not msg or msg == "" then return end

    local version, mtype, rest = strsplit(":", msg, 3)
    if version ~= PROTOCOL_VERSION then return end -- silently ignore other versions

    -- Resolve sender → GUID. The sender param is "Name-Realm"; look up
    -- via UnitGUID where possible, fall back to keying on the string.
    local guid = UnitGUID(sender) or sender

    -- Filter our own echo. SendAddonMessage delivers a copy back to the
    -- sender on PARTY/RAID/INSTANCE_CHAT; without this guard we count
    -- ourselves as a peer ("2/2 sync" when solo with the addon).
    local selfGuid = UnitGUID("player")
    if selfGuid and guid == selfGuid then return end
    -- Also defend against the name-fallback case (sender == our own name).
    local selfName = UnitName("player")
    if selfName and (sender == selfName or sender:match("^([^%-]+)") == selfName) then
        if not selfGuid or guid == selfName then return end
    end

    local peer = peers[guid]
    if not peer then
        peer = { name = sender, lastSeen = 0 }
        peers[guid] = peer
    end
    peer.lastSeen = GetTime()
    peer.name = sender

    if mtype == "H" then
        peer.version = rest
        dprint("peer hello", sender, rest)
    elseif mtype == "S" and rest then
        peer.latest = parseSnapshot(rest)
        -- Sanity: cap reported uptime at 2× claimed elapsed
        if peer.latest.uptimeMs > peer.latest.elapsed * 2000 then
            peer.latest.uptimeMs = peer.latest.elapsed * 1000
        end
    elseif mtype == "F" and rest then
        peer.latest = parseFinal(rest)
    end
end

-- ── Peer query API (for UI + future MeterData integration) ─────────────

-- Returns count of peers seen within PEER_TTL seconds (excluding self).
function Comm.GetActivePeerCount()
    local now = GetTime()
    local count = 0
    for _, p in pairs(peers) do
        if (now - p.lastSeen) <= PEER_TTL then
            count = count + 1
        end
    end
    return count
end

-- Returns "synced, total" where total = group size (incl. self) and
-- synced = self + other-peers seen on the addon channel within PEER_TTL.
-- When solo (not in a party), returns (1, 1) so callers can hide the badge.
function Comm.GetSyncStatus()
    local raw = GetNumGroupMembers() or 0
    if raw <= 1 then
        return 1, 1 -- solo: nothing to sync against
    end
    local synced = Comm.GetActivePeerCount() + 1 -- +1 for self
    if synced > raw then synced = raw end
    return synced, raw
end

-- Iterate all live peers. Used by /cadence sync.
function Comm.ForEachPeer(cb)
    local now = GetTime()
    for guid, p in pairs(peers) do
        if (now - p.lastSeen) <= PEER_TTL then
            cb(guid, p)
        end
    end
end

-- Look up the latest snapshot from a specific peer GUID. Returns nil if no
-- live peer. v1.1.1 will use this in MeterData to override local observation.
function Comm.GetPeerSnapshot(guid)
    local p = peers[guid]
    if not p then return nil end
    if (GetTime() - p.lastSeen) > PEER_TTL then return nil end
    return p.latest
end

-- ── Slash command handlers ─────────────────────────────────────────────

function Comm.ShowSync()
    local synced, total = Comm.GetSyncStatus()
    print(string.format("|cFFE0B23A[Cadence]|r Sync: %d/%d running Cadence", synced, total))
    Comm.ForEachPeer(function(guid, p)
        local v = p.version or "?"
        local age = math.floor(GetTime() - p.lastSeen)
        print(string.format("  %s  (v%s, seen %ds ago)", p.name or guid, v, age))
    end)
    if synced == 1 then
        print("  (you're the only Cadence user in this group)")
    end
end

function Comm.DumpDebug()
    print("|cFFE0B23A[Cadence Comm Debug]|r")
    print("  prefixRegistered =", tostring(prefixRegistered))
    print("  channel          =", tostring(pickChannel()))
    print("  currentSegId     =", tostring(currentSegId))
    print("  ticker active    =", tostring(snapshotTicker ~= nil))
    print("  peers known      =", Comm.GetActivePeerCount())
    Comm.ForEachPeer(function(guid, p)
        print(string.format("   - %s v%s segId=%s apmX10=%d uptimeMs=%d isFinal=%s",
            p.name or guid,
            p.version or "?",
            (p.latest and p.latest.segId) or "-",
            (p.latest and p.latest.apmX10) or 0,
            (p.latest and p.latest.uptimeMs) or 0,
            tostring(p.latest and p.latest.isFinal)
        ))
    end)
end

-- ── Init ───────────────────────────────────────────────────────────────

function Comm.Init()
    if commFrame then return end -- idempotent

    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        prefixRegistered = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) and true or false
    end

    commFrame = CreateFrame("Frame", "CadenceCommFrame")
    commFrame:RegisterEvent("CHAT_MSG_ADDON")
    commFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    commFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    commFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "CHAT_MSG_ADDON" then
            onAddonMessage(...)
        elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
            -- Re-announce on roster changes / world entry (throttled internally)
            if pickChannel() then
                Comm.SendHello()
            end
        end
    end)

    -- Garbage-collect dead peers every 30s
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(30, function()
            local now = GetTime()
            for guid, p in pairs(peers) do
                if (now - p.lastSeen) > PEER_TTL then
                    peers[guid] = nil
                end
            end
        end)
    end

    dprint("init complete, prefix registered:", prefixRegistered)
end

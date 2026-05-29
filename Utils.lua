--[[
    Cadence - Utils.lua
    Shared utility functions: formatting, colors, GUID management.
]]

local ADDON_NAME, PC = ...

-- Namespace table shared across all files
PC.Utils = {}
local Utils = PC.Utils

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
-- PC.VERSION is set in Core.lua from TOC metadata. Don't hard-code here.

-- Class color fallback table (Retail provides RAID_CLASS_COLORS but we keep a safe copy)
PC.CLASS_COLORS = {}
for class, color in pairs(RAID_CLASS_COLORS) do
    PC.CLASS_COLORS[class] = { r = color.r, g = color.g, b = color.b }
end

-- Role expected iAPM baselines (intentional actions per minute, post-400ms-dedup)
PC.ROLE_EXPECTED_APM = {
    DAMAGER_MELEE  = 34,
    DAMAGER_RANGED = 26,
    HEALER         = 24,
    TANK           = 30,
}

-- Melee class lookup (used to distinguish DAMAGER_MELEE vs DAMAGER_RANGED)
PC.MELEE_CLASSES = {
    WARRIOR     = true,
    PALADIN     = true,
    ROGUE       = true,
    DEATHKNIGHT = true,
    MONK        = true,
    DEMONHUNTER = true,
}

-- Sub-event categories we consider "actions" (player-initiated casts)
PC.ACTION_SUB_EVENTS = {
    SPELL_CAST_SUCCESS = true,
    -- We do NOT count SPELL_CAST_START separately to avoid double-counting.
    -- An instant spell only fires SUCCESS. A cast-time spell fires START then SUCCESS.
    -- Counting SUCCESS alone gives us one event per completed cast.
}

PC.SWING_SUB_EVENTS = {
    SWING_DAMAGE = true,
    SWING_MISSED = true,
}

---------------------------------------------------------------------------
-- GUID → Name cache
---------------------------------------------------------------------------
local guidNameCache = {}
local guidClassCache = {}
local guidRoleCache = {}
local guidRealmCache = {}

function Utils.CacheUnit(guid, name, class, realm)
    if guid then
        guidNameCache[guid] = name or guidNameCache[guid]
        guidClassCache[guid] = class or guidClassCache[guid]
        if realm and realm ~= "" then
            guidRealmCache[guid] = realm
        end
    end
end

function Utils.GetNameByGUID(guid)
    return guidNameCache[guid] or "Unknown"
end

function Utils.GetClassByGUID(guid)
    return guidClassCache[guid] or "PRIEST" -- safe fallback for coloring
end

function Utils.GetRealmByGUID(guid)
    return guidRealmCache[guid] or nil
end

function Utils.SetRoleByGUID(guid, role)
    if guid then guidRoleCache[guid] = role end
end

function Utils.GetRoleByGUID(guid)
    return guidRoleCache[guid] or "DAMAGER"
end

---------------------------------------------------------------------------
-- Pet → Owner mapping
---------------------------------------------------------------------------
local petOwnerMap = {}

function Utils.SetPetOwner(petGUID, ownerGUID)
    if petGUID and ownerGUID then
        petOwnerMap[petGUID] = ownerGUID
    end
end

function Utils.GetPetOwner(petGUID)
    return petOwnerMap[petGUID]
end

function Utils.IsPetGUID(guid)
    if not guid then return false end
    local unitType = strsplit("-", guid)
    return unitType == "Pet" or unitType == "Creature"
end

---------------------------------------------------------------------------
-- Formatting helpers
---------------------------------------------------------------------------
function Utils.FormatAPM(apm)
    if not apm or apm ~= apm then return "0.0" end  -- NaN guard
    return string.format("%.1f", apm)
end

function Utils.FormatScore(score)
    if score == nil then return "\226\128\148" end  -- em-dash for "no data"
    if score ~= score then return "0" end           -- NaN guard
    return string.format("%.0f", score)
end

function Utils.FormatTime(seconds)
    if not seconds or seconds < 0 then return "0:00" end
    local m = math.floor(seconds / 60)
    local s = math.floor(seconds % 60)
    return string.format("%d:%02d", m, s)
end

function Utils.FormatPercent(pct)
    if not pct or pct ~= pct then return "0%" end
    return string.format("%.0f%%", pct)
end

function Utils.FormatGap(seconds)
    if not seconds then return "0.0s" end
    return string.format("%.1fs", seconds)
end

---------------------------------------------------------------------------
-- Color helpers
---------------------------------------------------------------------------
function Utils.GetClassColor(class)
    local c = PC.CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 0.6, 0.6, 0.6  -- grey fallback
end

function Utils.GetClassColorHex(class)
    local r, g, b = Utils.GetClassColor(class)
    return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
end

function Utils.GetScoreColor(score)
    -- nil = "no meter data" → muted grey so the row clearly reads as
    -- "we couldn't measure this player" instead of a real value.
    if score == nil then
        return 0.55, 0.55, 0.55
    end
    -- Green (good) → Yellow (warning) → Red (bad)
    if score >= 70 then
        return 0.2, 1.0, 0.2  -- green
    elseif score >= 40 then
        local t = (score - 40) / 30
        return 1.0, 0.5 + t * 0.5, 0.1 -- orange to yellow
    else
        return 1.0, 0.2, 0.2  -- red
    end
end

---------------------------------------------------------------------------
-- Table utilities
---------------------------------------------------------------------------
function Utils.Clamp(val, minVal, maxVal)
    if val < minVal then return minVal end
    if val > maxVal then return maxVal end
    return val
end

-- Sigmoid function: maps x through a logistic curve centered at `center`
-- k controls steepness. Returns value in (0, 1).
function Utils.Sigmoid(x, k, center)
    return 1.0 / (1.0 + math.exp(-(k or 4.0) * ((x or 0) - (center or 1.0))))
end

function Utils.WipeTable(t)
    for k in pairs(t) do
        t[k] = nil
    end
end

function Utils.TableCount(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function Utils.ShallowCopy(src)
    local dest = {}
    for k, v in pairs(src) do
        dest[k] = v
    end
    return dest
end

function Utils.DeepCopy(src)
    if type(src) ~= "table" then return src end
    local dest = {}
    for k, v in pairs(src) do
        dest[k] = Utils.DeepCopy(v)
    end
    return dest
end

---------------------------------------------------------------------------
-- Group scanning
---------------------------------------------------------------------------
function Utils.ScanGroupRoster()
    local members = {}
    local inRaid = IsInRaid()
    local groupSize = GetNumGroupMembers()

    if groupSize == 0 then
        -- Solo
        local guid = UnitGUID("player")
        local name, realm = UnitName("player")
        local _, class = UnitClass("player")
        local role = "DAMAGER"
        local specIndex = GetSpecialization()
        if specIndex then
            local specRole = select(5, GetSpecializationInfo(specIndex))
            if specRole then role = specRole end
        end
        Utils.CacheUnit(guid, name, class, realm)
        Utils.SetRoleByGUID(guid, role)
        members[guid] = { name = name, class = class, role = role, guid = guid, realm = realm }
        return members
    end

    local prefix = inRaid and "raid" or "party"
    local count = inRaid and groupSize or (groupSize - 1)

    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) then
            local rawGUID = UnitGUID(unit)
            -- Clean GUIDs to strip Blizzard taint (Midnight 12.0).
            -- Tainted GUIDs used as table keys won't match clean CLEU GUIDs.
            local guid = rawGUID
            if PC and PC.Events and PC.Events._CleanString then
                guid = PC.Events._CleanString(rawGUID) or rawGUID
            end
            local name, realm = UnitName(unit)
            local _, class = UnitClass(unit)
            local role = UnitGroupRolesAssigned(unit) or "DAMAGER"
            if role == "NONE" then role = "DAMAGER" end
            Utils.CacheUnit(guid, name, class, realm)
            Utils.SetRoleByGUID(guid, role)
            members[guid] = { name = name, class = class, role = role, guid = guid, realm = realm }
        end
    end

    -- Always include the player
    if not inRaid then
        local guid = UnitGUID("player")
        local name, realm = UnitName("player")
        local _, class = UnitClass("player")
        local role = UnitGroupRolesAssigned("player") or "DAMAGER"
        if role == "NONE" then role = "DAMAGER" end
        Utils.CacheUnit(guid, name, class, realm)
        Utils.SetRoleByGUID(guid, role)
        members[guid] = { name = name, class = class, role = role, guid = guid, realm = realm }
    end

    return members
end

---------------------------------------------------------------------------
-- Melee spec detection (approximate list for Retail Midnight)
-- These specIDs have auto-attack as a primary damage source.
---------------------------------------------------------------------------
local MELEE_SPEC_IDS = {
    -- Warrior
    [71] = true,   -- Arms
    [72] = true,   -- Fury
    [73] = true,   -- Protection
    -- Paladin
    [66] = true,   -- Protection
    [70] = true,   -- Retribution
    -- Death Knight
    [250] = true,  -- Blood
    [251] = true,  -- Frost
    [252] = true,  -- Unholy
    -- Rogue
    [259] = true,  -- Assassination
    [260] = true,  -- Outlaw
    [261] = true,  -- Subtlety
    -- Monk
    [268] = true,  -- Brewmaster
    [269] = true,  -- Windwalker
    -- Demon Hunter
    [577] = true,  -- Havoc
    [581] = true,  -- Vengeance
    -- Druid
    [103] = true,  -- Feral
    [104] = true,  -- Guardian
    -- Shaman
    [263] = true,  -- Enhancement
    -- Evoker (melee-range but caster style)
    -- [1467] = false, -- Devastation (ranged)
    -- [1468] = false, -- Preservation (healer)
    -- [1473] = false, -- Augmentation (ranged)
}

function Utils.IsMeleeSpec(specID)
    return MELEE_SPEC_IDS[specID] or false
end

-- Check if a GUID is currently dead using unit iteration
function Utils.IsGUIDDead(guid)
    if not guid then return false end
    -- Check player
    if UnitGUID("player") == guid then return UnitIsDeadOrGhost("player") end
    -- Check party/raid members
    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and GetNumGroupMembers() or (GetNumGroupMembers() - 1)
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) and UnitGUID(unit) == guid then
            return UnitIsDeadOrGhost(unit)
        end
    end
    return false
end

-- Determine melee status by inspecting spec (only reliable for player themselves)
-- For other players, we use heuristic: if they have swing events, they're melee.
function Utils.IsMeleeByGUID(guid)
    if guid == UnitGUID("player") then
        local specIndex = GetSpecialization()
        if specIndex then
            local specID = GetSpecializationInfo(specIndex)
            return Utils.IsMeleeSpec(specID)
        end
    end
    -- For others, caller should check swingTimestamps count
    return nil  -- unknown, let caller decide
end

---------------------------------------------------------------------------
-- SpecID lookup by GUID
-- Self: GetSpecialization → GetSpecializationInfo
-- Group: GetInspectSpecialization (requires cached inspect data)
---------------------------------------------------------------------------
function Utils.GetSpecIDByGUID(guid)
    if not guid then return 0 end

    -- Self
    if guid == UnitGUID("player") then
        local ok, specIndex = pcall(GetSpecialization)
        if ok and specIndex then
            local ok2, specID = pcall(GetSpecializationInfo, specIndex)
            if ok2 and specID then return specID end
        end
        return 0
    end

    -- Group members: iterate unit tokens to find matching GUID
    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and GetNumGroupMembers() or (GetNumGroupMembers() - 1)
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) and UnitGUID(unit) == guid then
            local ok, specID = pcall(GetInspectSpecialization, unit)
            if ok and specID and specID > 0 then return specID end
            break
        end
    end

    return 0
end

---------------------------------------------------------------------------
-- Format DPS/HPS for compact display (e.g. "12.3k", "1.5M")
---------------------------------------------------------------------------
function Utils.FormatThroughput(value)
    if not value or value ~= value or value <= 0 then return "0" end
    if value >= 1000000 then
        return string.format("%.1fM", value / 1000000)
    elseif value >= 1000 then
        return string.format("%.1fk", value / 1000)
    end
    return string.format("%.0f", value)
end

PC.Utils = Utils

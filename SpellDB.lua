--[[
    Cadence - SpellDB.lua
    Curated spell classification tables for utility scoring.

    Categories (sourced from LibOpenRaid / ThingsToMantain_Midnight.lua):
      EXTERNAL   – Targeted defensive cast on another player (type 3)
      RAID_CD    – Raid-wide defensive / healing cooldown (type 4)
      SUPPORT    – Group-benefiting utility: freedom, grips, PI, etc.
      CC         – Crowd control: stuns, disorients, knockbacks (type 8)

    These supplement C_Spell.IsExternalDefensive() which the native API
    provides for externals.  The tables here give us raid CDs, support,
    and CC which Blizzard doesn't expose via a single API.

    Maintenance: update when new spells are added in patches.
    Spell IDs are from Midnight (12.0) / The War Within (11.0).
]]

local ADDON_NAME, PC = ...

PC.SpellDB = {}
local SpellDB = PC.SpellDB

---------------------------------------------------------------------------
-- EXTERNAL: Targeted defensive cooldowns cast on an ally
-- These are the same spells C_Spell.IsExternalDefensive should catch,
-- but we keep a fallback table in case the API is incomplete or delayed.
---------------------------------------------------------------------------
SpellDB.EXTERNAL = {
    -- Paladin
    [6940]   = true,  -- Blessing of Sacrifice
    [1022]   = true,  -- Blessing of Protection
    [204018] = true,  -- Blessing of Spellwarding
    [633]    = true,  -- Lay on Hands

    -- Warrior
    [3411]   = true,  -- Intervene

    -- Druid
    [102342] = true,  -- Ironbark
    [203651] = true,  -- Overgrowth

    -- Priest
    [33206]  = true,  -- Pain Suppression
    [47788]  = true,  -- Guardian Spirit
    [108968] = true,  -- Void Shift

    -- Monk
    [116849] = true,  -- Life Cocoon

    -- Evoker
    [357170] = true,  -- Time Dilation
    [360827] = true,  -- Blistering Scales
    [406732] = true,  -- Spatial Paradox
    [443328] = true,  -- Engulf
}

---------------------------------------------------------------------------
-- RAID_CD: Raid-wide defensive / healing cooldowns
-- Major CDs that protect or heal the entire group.
---------------------------------------------------------------------------
SpellDB.RAID_CD = {
    -- Paladin
    [31821]  = true,  -- Aura Mastery (not in LibOpenRaid but well-known)

    -- Warrior
    [97462]  = true,  -- Rallying Cry

    -- Shaman
    [108281] = true,  -- Ancestral Guidance
    [207399] = true,  -- Ancestral Protection Totem
    [114052] = true,  -- Ascendance (Resto)
    [198838] = true,  -- Earthen Wall Totem

    -- Monk
    [322118] = true,  -- Invoke Yu'lon, the Jade Serpent
    [325197] = true,  -- Invoke Chi-Ji, the Red Crane
    [388615] = true,  -- Restoral
    [443028] = true,  -- Celestial Conduit

    -- Druid
    [197721] = true,  -- Flourish
    [33891]  = true,  -- Incarnation: Tree of Life
    [124974] = true,  -- Nature's Vigil
    [740]    = true,  -- Tranquility

    -- Priest
    [200183] = true,  -- Apotheosis
    [472433] = true,  -- Evangelism
    [265202] = true,  -- Holy Word: Salvation
    [372835] = true,  -- Lightwell
    [271466] = true,  -- Luminous Barrier
    [64843]  = true,  -- Divine Hymn
    [109964] = true,  -- Spirit Shell
    [64901]  = true,  -- Symbol of Hope
    [15286]  = true,  -- Vampiric Embrace
    [62618]  = true,  -- Power Word: Barrier
    [120517] = true,  -- Halo
    [421453] = true,  -- Ultimate Penitence

    -- Death Knight
    [51052]  = true,  -- Anti-Magic Zone

    -- Demon Hunter
    [196718] = true,  -- Darkness

    -- Evoker
    [370960] = true,  -- Emerald Communion
    [370537] = true,  -- Stasis
}

---------------------------------------------------------------------------
-- SUPPORT: Group-benefiting utility spells
-- Spells that directly help another player (not just yourself).
---------------------------------------------------------------------------
SpellDB.SUPPORT = {
    -- Paladin
    [1044]   = true,  -- Blessing of Freedom

    -- Warrior
    [1161]   = true,  -- Challenging Shout (taunt utility)

    -- Shaman
    [192077] = true,  -- Wind Rush Totem
    [8143]   = true,  -- Tremor Totem
    [16191]  = true,  -- Mana Tide Totem

    -- Monk
    [116841] = true,  -- Tiger's Lust

    -- Druid
    [29166]  = true,  -- Innervate
    [20484]  = true,  -- Rebirth (battle rez)
    [106898] = true,  -- Stampeding Roar (group movement speed)

    -- Priest
    [73325]  = true,  -- Leap of Faith
    [10060]  = true,  -- Power Infusion
    [47536]  = true,  -- Rapture

    -- Death Knight
    [108199] = true,  -- Gorefiend's Grasp
    [61999]  = true,  -- Raise Ally (battle rez)

    -- Rogue
    [114018] = true,  -- Shroud of Concealment

    -- Evoker
    [370665] = true,  -- Rescue

    -- Hunter
    [34477]  = true,  -- Misdirection
}

---------------------------------------------------------------------------
-- CC: Crowd control — stuns, disorients, knockbacks, roots
-- Only meaningful group-relevant CC (not single-target openers/combos
-- like Kidney Shot or Gouge which are rotational in PvP).
---------------------------------------------------------------------------
SpellDB.CC = {
    -- Paladin
    [115750] = true,  -- Blinding Light
    [853]    = true,  -- Hammer of Justice
    [20066]  = true,  -- Repentance

    -- Warrior
    [5246]   = true,  -- Intimidating Shout
    [46968]  = true,  -- Shockwave
    [107570] = true,  -- Storm Bolt

    -- Warlock
    [5484]   = true,  -- Howl of Terror
    [30283]  = true,  -- Shadowfury
    [6789]   = true,  -- Mortal Coil

    -- Shaman
    [192058] = true,  -- Capacitor Totem
    [51485]  = true,  -- Earthgrab Totem
    [51514]  = true,  -- Hex
    [305483] = true,  -- Lightning Lasso

    -- Monk
    [119381] = true,  -- Leg Sweep
    [116844] = true,  -- Ring of Peace
    [115078] = true,  -- Paralysis

    -- Hunter
    [109248] = true,  -- Binding Shot
    [187650] = true,  -- Freezing Trap
    [19577]  = true,  -- Intimidation
    [187698] = true,  -- Tar Trap
    [236776] = true,  -- High Explosive Trap
    [462031] = true,  -- Implosive Trap

    -- Druid
    [99]     = true,  -- Incapacitating Roar
    [132469] = true,  -- Typhoon
    [102793] = true,  -- Ursol's Vortex
    [5211]   = true,  -- Mighty Bash
    [102359] = true,  -- Mass Entanglement

    -- Death Knight
    [221562] = true,  -- Asphyxiate (Blood)
    [108194] = true,  -- Asphyxiate (Frost/Unholy)
    [207167] = true,  -- Blinding Sleet
    [49576]  = true,  -- Death Grip

    -- Demon Hunter
    [179057] = true,  -- Chaos Nova
    [217832] = true,  -- Imprison
    [202138] = true,  -- Sigil of Chains
    [207684] = true,  -- Sigil of Misery

    -- Mage
    [383121] = true,  -- Mass Polymorph
    [113724] = true,  -- Ring of Frost
    [31661]  = true,  -- Dragon's Breath
    [157981] = true,  -- Blast Wave
    [449700] = true,  -- Gravity Lapse

    -- Priest
    [8122]   = true,  -- Psychic Scream
    [64044]  = true,  -- Psychic Horror
    [108920] = true,  -- Void Tendrils

    -- Rogue
    [2094]   = true,  -- Blind

    -- Evoker
    [358385] = true,  -- Landslide
    [372048] = true,  -- Oppressing Roar
    [360806] = true,  -- Sleep Walk
}

---------------------------------------------------------------------------
-- Classification API
-- Returns: "EXTERNAL", "RAID_CD", "SUPPORT", "CC", or nil
-- Checks in priority order: external > raid_cd > support > cc
---------------------------------------------------------------------------
function SpellDB.Classify(spellID)
    if not spellID then return nil end
    if SpellDB.EXTERNAL[spellID] then return "EXTERNAL" end
    if SpellDB.RAID_CD[spellID]  then return "RAID_CD" end
    if SpellDB.SUPPORT[spellID]  then return "SUPPORT" end
    if SpellDB.CC[spellID]       then return "CC" end
    return nil
end

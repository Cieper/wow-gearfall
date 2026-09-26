local _, addon = ...

--------------------------------------------------------------------------------
-- Eligibility: "can alt X wear item Y at all?"
--
-- Static-table rules evaluated offline against cached snapshots: slot mapping,
-- armor tier, primary stat, weapon profiles, shield/offhand and weapon-set
-- rules. Decides WHETHER and INTO WHICH SLOT - never whether it is an UPGRADE;
-- the value math lives in Scoring.lua.
--
-- Public surface:
--   addon.SpecUsesItem(itemInfo, alt)  - pure <spec>/<class> question:
--     would this class (and, when known, its active spec) ever use this
--     item? Ignores level and worn gear. The alt's spec is probed through
--     the gate sequence first; on a rejection the class's other specs run
--     the SAME sequence, and any acceptor upgrades the answer to "respec".
--     -> uses, reason, why, slotID, dualSlots, respecSpecs
--       (why: "respec" | "no"; respecSpecs = sorted NAMES of the sibling
--       specs that accept the item, nil when the rejection is final)
--   addon.IsItemEligibleForAlt(itemInfo, alt) - same, PLUS the alt's state
--     (level, held weapons, slot occupancy):
--     -> verdict, reason, slotID, slotFixed, candidateSlots, respecSpecs
--     verdict: "yes" | "eventually" | "respec" | "no"
--     slotFixed       = a unique-equipped swap already pinned slotID
--     candidateSlots  = every slot the item may take (two fingers, two
--       trinkets, or either hand for dual-wield weapons); the caller in
--       Scoring.lua resolves empty-slot-first / weaker-hand choice
--   addon.GetItemMainStats(link[, bagID, slotIndex]) - {STR,AGI,INT} set or
--     nil (unavailable); addon.FormatStatSet renders that set for messages
--   addon.GetItemLevel(itemLink) - the item's power level with the detailed
--     API gated on a numeric base (see the function's comment); never the
--     equip requirement - that is GetItemInfo's minLevel
--   addon.TargetSlotFor(itemInfo) - the inventory slot the item targets
--   addon.ClassesWithoutAltUsing(itemInfo) - classes with no roster alt
--   addon.CLASS_SPECS / addon.SPEC_PRIMARY_STATS - spec maps shared with
--     ItemRoles.lua
--------------------------------------------------------------------------------

-- Blizzard's item subclass enums (always present in-game; stubbed in tests)
local WSub = Enum.ItemWeaponSubclass
local ASub = Enum.ItemArmorSubclass

-- canonical armor tiers ARE the Enum.ItemArmorSubclass values; this set only
-- marks which armor subclasses carry a tier at all (Generic, Cosmetic,
-- Shield, Libram/Relic... have none)
local ARMOR_TIER_SUBS = {
    [ASub.Cloth] = true, [ASub.Leather] = true,
    [ASub.Mail] = true, [ASub.Plate] = true,
}

-- a class's canonical armor type; candidates must match exactly (never
-- suggest off-type gear even if it would be an ilvl or Pawn upgrade)
local CLASS_ARMOR = {
    MAGE = ASub.Cloth, PRIEST = ASub.Cloth, WARLOCK = ASub.Cloth,
    DRUID = ASub.Leather, MONK = ASub.Leather,
    ROGUE = ASub.Leather, DEMONHUNTER = ASub.Leather,
    SHAMAN = ASub.Mail, EVOKER = ASub.Mail, HUNTER = ASub.Mail,
    DEATHKNIGHT = ASub.Plate, PALADIN = ASub.Plate, WARRIOR = ASub.Plate,
}

-------------------------------------------------------------------------------
-- Primary stats (main-stat gate, all gear slots)
-------------------------------------------------------------------------------

local STAT_NAMES = { STR = "Strength", AGI = "Agility", INT = "Intellect" }

-- specID -> primary stats used by that spec (pinned to Midnight 120100:
-- Guardian/Brewmaster tank on Agility, Devourer DH 1480 on Intellect)
local SPEC_PRIMARY_STATS = {
    [71] = { STR = true }, [72] = { STR = true }, [73] = { STR = true }, -- Warrior
    [250] = { STR = true }, [251] = { STR = true }, [252] = { STR = true }, -- DK
    [66] = { STR = true }, [70] = { STR = true }, -- Prot/Ret Paladin
    [259] = { AGI = true }, [260] = { AGI = true }, [261] = { AGI = true }, -- Rogue
    [577] = { AGI = true }, [581] = { AGI = true }, -- DH Havoc/Vengeance
    [253] = { AGI = true }, [254] = { AGI = true }, [255] = { AGI = true }, -- Hunter
    [103] = { AGI = true }, [104] = { AGI = true }, -- Feral/Guardian Druid
    [271] = { AGI = true }, [268] = { AGI = true }, -- WW/Brewmaster Monk
    [263] = { AGI = true }, -- Enhancement Shaman
    [65] = { INT = true }, -- Holy Paladin
    [102] = { INT = true }, [105] = { INT = true }, -- Balance/Resto Druid
    [62] = { INT = true }, [63] = { INT = true }, [64] = { INT = true }, -- Mage
    [256] = { INT = true }, [257] = { INT = true }, [258] = { INT = true }, -- Priest
    [265] = { INT = true }, [266] = { INT = true }, [267] = { INT = true }, -- Warlock
    [1467] = { INT = true }, [1468] = { INT = true }, [1473] = { INT = true }, -- Evoker
    [270] = { INT = true }, -- Mistweaver Monk
    [262] = { INT = true }, [264] = { INT = true }, -- Elem/Resto Shaman
    [1480] = { INT = true }, -- Devourer DH
}

function addon.FormatStatSet(set)
    if not set then
        return "-"
    end
    local parts = {}
    for _, stat in ipairs({ "STR", "AGI", "INT" }) do
        if set[stat] then
            parts[#parts + 1] = STAT_NAMES[stat]
        end
    end
    if #parts == 0 then
        return "-"
    end
    return table.concat(parts, " + ")
end

local PRIMARY_STAT_KEYS = {
    ITEM_MOD_STRENGTH_SHORT = "STR", ITEM_MOD_STRENGTH = "STR",
    ITEM_MOD_AGILITY_SHORT = "AGI", ITEM_MOD_AGILITY = "AGI",
    ITEM_MOD_INTELLECT_SHORT = "INT", ITEM_MOD_INTELLECT = "INT",
}

-- Stat-adjusted items only report the stat relevant to the CURRENT viewer's
-- spec through C_Item.GetItemStats; the tooltip shows every possible stat
-- (inactive ones greyed). Scan those lines so the full set is known for
-- offline alts.
local statTip

local STAT_LINE_PATTERNS = {
    { "^%+[%d,]+ Strength$", "STR" },
    { "^%+[%d,]+ Agility$", "AGI" },
    { "^%+[%d,]+ Intellect$", "INT" },
}

local function ScanTooltip(link, bagID, slotIndex, mailIndex, attachIndex)
    if not (CreateFrame and WorldFrame) then
        return nil
    end
    statTip = statTip or CreateFrame("GameTooltip", "GearFallStatTip", nil,
        "GameTooltipTemplate")
    statTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    if bagID and slotIndex then
        statTip:SetBagItem(bagID, slotIndex)
    elseif mailIndex and attachIndex and statTip.SetInboxItem then
        -- in-mailbox tooltips carry the full stat-adjusted set, same as
        -- in-bag ones
        statTip:SetInboxItem(mailIndex, attachIndex)
    else
        statTip:SetHyperlink(link)
    end
    local stats
    for i = 1, statTip:NumLines() do
        local fs = _G[statTip:GetName() .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if text then
            for _, pair in ipairs(STAT_LINE_PATTERNS) do
                if text:find(pair[1]) then
                    stats = stats or {}
                    stats[pair[2]] = true
                end
            end
        end
    end
    return stats
end

-- C_Item's view of the item's primary stats (nil = unavailable/uncached)
local function ApiMainStats(link)
    if not (link and C_Item and C_Item.GetItemStats) then
        return nil
    end
    local ok, stats = pcall(C_Item.GetItemStats, link)
    if not ok or type(stats) ~= "table" then
        return nil
    end
    local found
    for key, value in pairs(stats) do
        local stat = PRIMARY_STAT_KEYS[key]
        if stat and (type(value) ~= "number" or value > 0) then
            found = found or {}
            found[stat] = true
        end
    end
    return found
end

-- set { STR=, AGI=, INT= } of primary stats the item can grant (API +
-- tooltip union); nil = undetermined (or the item HAS no primary stats),
-- callers must treat nil as "pass"
function addon.GetItemMainStats(link, bagID, slotIndex, mailIndex, attachIndex)
    if not link then
        return nil
    end
    local found = ApiMainStats(link)
    local tipStats = ScanTooltip(link, bagID, slotIndex, mailIndex, attachIndex)
    if tipStats then
        for stat in pairs(tipStats) do
            found = found or {}
            found[stat] = true
        end
    end
    return found
end

-- cached tooltip stats per candidate (one hidden tooltip render each)
local function GetCachedTipStats(itemInfo)
    if itemInfo._tipStats == nil then
        itemInfo._tipStats = ScanTooltip(
            itemInfo.itemLink, itemInfo.bagID, itemInfo.slotIndex,
            itemInfo.mailIndex, itemInfo.attachIndex) or false
    end
    if itemInfo._tipStats == false then
        return nil
    end
    return itemInfo._tipStats
end

local function GetCachedMainStats(itemInfo)
    local found = ApiMainStats(itemInfo.itemLink)
    local tip = GetCachedTipStats(itemInfo)
    if tip then
        for stat in pairs(tip) do
            found = found or {}
            found[stat] = true
        end
    end
    return found
end

--------------------------------------------------------------------------------
-- Weapon-use profiles captured verbatim from Blizzard's own spec description
-- strings ("Preferred Weapon: ...", read back via /gear specs). SPEC_WEAPONS
-- lists the allowed MAINHAND subclasses only; the weapon-offhand styles are
-- the per-spec policy in SPEC_OFFHAND (held items have their own set, see
-- below):
--   * "shield"  - the offhand holds a shield (alongside a 1H mainhand);
--   * "dual"    - the spec dual-wields: a second ONE-HANDED weapon;
--   * "dual2H"  - Fury's Titans Grip: a second weapon that may be 2H;
--   * nil       - the mainhand weapon fills both hands (2H-only specs) or
--                 the offhand never applies (ranged-only hunters).
-- The offhand resolves per candidate KIND: shields need the "shield"
-- policy, an offhand weapon the "dual"/"dual2H" policy, and a held item an
-- entry in HOLDABLE_SPECS. In practice every holdable grants Intellect, but
-- the rule must not ride the stat gate: the stat gate passes when item
-- stats are unavailable, and it cannot tell the Intellect specs that may
-- hold a frill from those that may not (paladins are shield-only, Devourer
-- dual-wields).
-- specID -> allowed weapon subclasses.
--------------------------------------------------------------------------------

-- entries are Enum.ItemWeaponSubclass members (WSub); "Fist Weapons" is the
-- subclass Blizzard names Unarmed.
local SPEC_WEAPONS = {
    -- Death Knight
    [250] = { WSub.Axe2H, WSub.Mace2H, WSub.Sword2H, WSub.Polearm },     -- Blood
    [251] = { WSub.Axe1H, WSub.Mace1H, WSub.Sword1H, WSub.Polearm, WSub.Axe2H, WSub.Mace2H, WSub.Sword2H }, -- Frost (2H/polearm widen the "Dual Axes, Maces, Swords" flavor line)
    [252] = { WSub.Axe2H, WSub.Mace2H, WSub.Sword2H, WSub.Polearm },     -- Unholy
    -- Demon Hunter
    [577] = { WSub.Warglaive, WSub.Sword1H, WSub.Axe1H, WSub.Unarmed, WSub.Dagger },   -- Havoc
    [581] = { WSub.Warglaive, WSub.Sword1H, WSub.Axe1H, WSub.Unarmed, WSub.Dagger },   -- Vengeance
    [1480] = { WSub.Warglaive, WSub.Sword1H, WSub.Axe1H, WSub.Unarmed, WSub.Dagger }, -- Devourer
    -- Druid
    [102] = { WSub.Staff, WSub.Dagger, WSub.Mace1H },      -- Balance
    [103] = { WSub.Staff, WSub.Polearm },                  -- Feral
    [104] = { WSub.Staff, WSub.Polearm },                  -- Guardian
    [105] = { WSub.Staff, WSub.Dagger, WSub.Mace1H },      -- Restoration
    -- Evoker
    [1467] = { WSub.Staff, WSub.Sword1H, WSub.Dagger, WSub.Mace1H }, -- Devastation
    [1468] = { WSub.Staff, WSub.Sword1H, WSub.Dagger, WSub.Mace1H }, -- Preservation
    [1473] = { WSub.Staff, WSub.Sword1H, WSub.Dagger, WSub.Mace1H }, -- Augmentation
    -- Hunter
    [253] = { WSub.Bows, WSub.Crossbow, WSub.Guns },       -- Beast Mastery
    [254] = { WSub.Bows, WSub.Crossbow, WSub.Guns },       -- Marksmanship
    [255] = { WSub.Polearm, WSub.Staff, WSub.Axe2H, WSub.Sword2H, WSub.Axe1H, WSub.Sword1H, WSub.Dagger }, -- Survival
    -- Mage
    [62] = { WSub.Staff, WSub.Wand, WSub.Dagger, WSub.Sword1H },  -- Arcane
    [63] = { WSub.Staff, WSub.Wand, WSub.Dagger, WSub.Sword1H },  -- Fire
    [64] = { WSub.Staff, WSub.Wand, WSub.Dagger, WSub.Sword1H },  -- Frost
    -- Monk
    [268] = { WSub.Staff, WSub.Polearm },                  -- Brewmaster
    [269] = { WSub.Unarmed, WSub.Axe1H, WSub.Mace1H, WSub.Sword1H }, -- Windwalker
    [270] = { WSub.Staff, WSub.Mace1H, WSub.Sword1H },     -- Mistweaver
    -- Paladin
    [65] = { WSub.Sword1H, WSub.Mace1H },                  -- Holy
    [66] = { WSub.Sword1H, WSub.Mace1H, WSub.Axe1H },      -- Protection
    [70] = { WSub.Sword2H, WSub.Mace2H, WSub.Axe2H },      -- Retribution
    -- Priest
    [256] = { WSub.Staff, WSub.Wand, WSub.Dagger, WSub.Mace1H }, -- Discipline
    [257] = { WSub.Staff, WSub.Wand, WSub.Dagger, WSub.Mace1H }, -- Holy
    [258] = { WSub.Staff, WSub.Wand, WSub.Dagger, WSub.Mace1H }, -- Shadow
    -- Rogue
    [259] = { WSub.Dagger },                               -- Assassination
    [260] = { WSub.Axe1H, WSub.Mace1H, WSub.Sword1H, WSub.Unarmed }, -- Outlaw
    [261] = { WSub.Dagger },                               -- Subtlety
    -- Shaman
    [262] = { WSub.Mace1H, WSub.Dagger },                  -- Elemental
    [263] = { WSub.Axe1H, WSub.Mace1H, WSub.Unarmed },     -- Enhancement
    [264] = { WSub.Mace1H, WSub.Dagger },                  -- Restoration
    -- Warlock
    [265] = { WSub.Staff, WSub.Wand, WSub.Dagger, WSub.Sword1H }, -- Affliction
    [266] = { WSub.Staff, WSub.Wand, WSub.Dagger, WSub.Sword1H }, -- Demonology
    [267] = { WSub.Staff, WSub.Wand, WSub.Dagger, WSub.Sword1H }, -- Destruction
    -- Warrior
    [71] = { WSub.Axe2H, WSub.Mace2H, WSub.Sword2H },      -- Arms
    [72] = { WSub.Axe2H, WSub.Mace2H, WSub.Sword2H },      -- Fury (dual via dual2H)
    [73] = { WSub.Axe1H, WSub.Mace1H, WSub.Sword1H },      -- Protection
}

-- per-spec offhand policy (specID -> style); see the SPEC_WEAPONS header
local SPEC_OFFHAND = {
    [65] = "shield", [66] = "shield", [73] = "shield",
    [262] = "shield", [264] = "shield",
    [251] = "dual", [255] = "dual", [259] = "dual", [260] = "dual",
    [261] = "dual", [263] = "dual", [269] = "dual",
    [577] = "dual", [581] = "dual", [1480] = "dual",
    [72] = "dual2H",
}

local CLASS_SPECS = {
    DEATHKNIGHT = { 250, 251, 252 }, DEMONHUNTER = { 577, 581, 1480 },
    DRUID = { 102, 103, 104, 105 }, EVOKER = { 1467, 1468, 1473 },
    HUNTER = { 253, 254, 255 }, MAGE = { 62, 63, 64 },
    MONK = { 268, 269, 270 }, PALADIN = { 65, 66, 70 },
    PRIEST = { 256, 257, 258 }, ROGUE = { 259, 260, 261 },
    SHAMAN = { 262, 263, 264 }, WARLOCK = { 265, 266, 267 },
    WARRIOR = { 71, 72, 73 },
}
addon.CLASS_SPECS = CLASS_SPECS -- specID -> class lookups (ItemRoles.lua)
addon.SPEC_PRIMARY_STATS = SPEC_PRIMARY_STATS -- specID -> stat set (ItemRoles)

-- subclasses that may occupy the OFFHAND of a dual-wielding spec: the 1H
-- set for "dual", plus the 2H set for Fury's Titans Grip. Staves and
-- polearms can never sit in an offhand (no spec dual-wields them), and
-- wands are mainhand-only.
local OFFHAND_1H = {
    [WSub.Axe1H] = true, [WSub.Mace1H] = true, [WSub.Sword1H] = true,
    [WSub.Warglaive] = true, [WSub.Unarmed] = true, [WSub.Dagger] = true,
}
local OFFHAND_2H = {
    [WSub.Axe2H] = true, [WSub.Mace2H] = true, [WSub.Sword2H] = true,
}

-- specs whose offhand can hold a "Held in Off-Hand" item (frill): the
-- Intellect specs that wield a one-hander (incl. wand/dagger). Paladins are
-- shield-only and Devourer dual-wields, so neither qualifies despite being
-- Intellect-based; every other spec fills the offhand with a shield, a
-- second weapon, or nothing.
local HOLDABLE_SPECS = {
    [102] = true, [105] = true,                   -- Balance/Restoration Druid
    [62] = true, [63] = true, [64] = true,        -- Mage
    [256] = true, [257] = true, [258] = true,     -- Priest
    [262] = true, [264] = true,                   -- Elemental/Restoration Shaman
    [265] = true, [266] = true, [267] = true,     -- Warlock
    [270] = true,                                 -- Mistweaver Monk
    [1467] = true, [1468] = true, [1473] = true,  -- Evoker
}

-- the offhand policies of one class's specs: nil when nothing is known.
-- Sole consumer: the STATEFUL dual-wield offer in IsItemEligibleForAlt for
-- alts without a captured spec - the static path probes specs individually
-- and never falls back to class unions
local function ClassOffhandPolicies(classToken)
    local specIDs = CLASS_SPECS[classToken]
    if not specIDs then
        return nil
    end
    local known, shield, dual = false, false, false
    for _, specID in ipairs(specIDs) do
        local style = SPEC_OFFHAND[specID]
        if style then
            known = true
            if style == "shield" then
                shield = true
            else
                dual = true
            end
        end
    end
    if not known then
        return nil
    end
    return { shield = shield, dual = dual }
end

-- Spec-scoped gate predicates: the static question is a pure function of
-- (item, class, spec) - no alt state can enter it. An unknown specID
-- nil-passes (callers treat nil as "pass"); a known spec always answers.

local function SpecPrimaryStats(specID)
    return specID and SPEC_PRIMARY_STATS[specID] or nil
end

local function SpecOffhandPolicy(specID)
    if not specID or not SPEC_WEAPONS[specID] then
        return nil
    end
    local style = SPEC_OFFHAND[specID]
    if not style then
        -- known spec without an offhand policy: 2H-only
        return { shield = false, dual = false, dual2H = false }
    end
    return { shield = style == "shield",
        dual = (style == "dual" or style == "dual2H"),
        dual2H = style == "dual2H" }
end

local function SpecAllowsShield(specID)
    local policy = SpecOffhandPolicy(specID)
    if not policy then
        return nil
    end
    return policy.shield
end

local function ListAllows(list, value)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

local function SpecAllowsWeapon(specID, subclass)
    local list = specID and SPEC_WEAPONS[specID]
    if not list then
        return nil
    end
    return ListAllows(list, subclass)
end

-- can the spec fill the offhand with this KIND of item? "shield" needs the
-- shield policy, "weapon" a second weapon (dual policies), "holdable" an
-- entry in HOLDABLE_SPECS
local function SpecAllowsOffhandKind(specID, kind)
    if not specID or not (SPEC_WEAPONS[specID] or SPEC_OFFHAND[specID]) then
        return nil
    end
    if kind == "shield" then
        return SPEC_OFFHAND[specID] == "shield"
    elseif kind == "weapon" then
        local style = SPEC_OFFHAND[specID]
        return style == "dual" or style == "dual2H"
    end
    return HOLDABLE_SPECS[specID] and true or false
end

-- Midnight slot model: invType only says WHICH HAND an item goes in
-- (staves/greatweapons all report INVTYPE_2HWEAPON), WHAT kind of weapon it
-- is comes from the item subclass (2/10 staff, 2/5 two-handed mace, ...).
local TWO_HANDED_INV_TYPES = { INVTYPE_2HWEAPON = true }

local WEAPON_INV_TYPES = {
    INVTYPE_WEAPON = true, INVTYPE_WEAPONMAINHAND = true,
    INVTYPE_WEAPONOFFHAND = true, INVTYPE_SHIELD = true,
    INVTYPE_HOLDABLE = true, INVTYPE_2HWEAPON = true,
}

local function IsTwoHanded(invType)
    return invType ~= nil and TWO_HANDED_INV_TYPES[invType] == true
end

local function IsWeaponish(invType)
    return invType ~= nil and WEAPON_INV_TYPES[invType] == true
end

-- invTypes that target the OFFHAND slot (17): offhand-only weapons, shields
-- and holdables. Everything else of class 2 is a mainhand weapon, including
-- 2HWEAPON, WEAPON and the bows/crossbows/guns/wands.
local OFFHAND_SLOT_INV_TYPES = {
    INVTYPE_WEAPONOFFHAND = true, INVTYPE_SHIELD = true,
    INVTYPE_HOLDABLE = true,
}

local function ItemSubclassName(itemClass, sub)
    local nameFn = (C_Item and C_Item.GetItemSubClassInfo) or GetItemSubClassInfo
    if nameFn then
        local ok, name = pcall(nameFn, itemClass, sub)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end
    return ("type %s"):format(tostring(sub))
end

-- static invType -> inventory slot map; deterministic offline, no reliance on
-- GetInventorySlotInfo's bare-name argument ("HEAD", not "INVTYPE_HEAD")
local INVTYPE_TO_SLOT = {
    INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_CHEST = 5,
    INVTYPE_WAIST = 6, INVTYPE_LEGS = 7, INVTYPE_FEET = 8, INVTYPE_WRIST = 9,
    INVTYPE_HAND = 10, INVTYPE_FINGER = 11, INVTYPE_TRINKET = 13,
    INVTYPE_BACK = 15, INVTYPE_CLOAK = 15,
    -- ROBE and CHEST are both live (the split is cosmetic item shape only);
    -- robes equip to the chest slot
    INVTYPE_ROBE = 5,
}

-- Non-upgrade equip slots (shirts etc.)
local IGNORED_INV_TYPES = { INVTYPE_BODY = true, INVTYPE_TABARD = true, 
    INVTYPE_PROFESSION_GEAR = true, INVTYPE_PROFESSION_TOOL = true}

-- returns slotID (nil = not a slot we track), plus a candidate-slot list
-- for items that fit two slots (fingers, trinkets)
local function GetTargetSlots(invType, itemClass)
    if not invType or IGNORED_INV_TYPES[invType] then
        return nil
    end
    if invType == "INVTYPE_FINGER" then
        return 11, { 11, 12 }
    elseif invType == "INVTYPE_TRINKET" then
        return 13, { 13, 14 }
    end
    local slot = INVTYPE_TO_SLOT[invType]
    if slot then
        return slot
    end
    if IsWeaponish(invType) then
        if IsTwoHanded(invType) then
            return 16
        end
        if OFFHAND_SLOT_INV_TYPES[invType] then
            return 17
        end
        return 16
    end
    if itemClass == 2 then
        if OFFHAND_SLOT_INV_TYPES[invType] then
            return 17
        end
        return 16
    end
    return nil
end

-- exported for UI/ordering: which inventory slot does this item target?
function addon.TargetSlotFor(itemInfo)
    return GetTargetSlots(itemInfo.invType, itemInfo.class)
end

-- Minimal class+spec identity for the static question: the evaluator and
-- every gate see ONLY this record, so no alt state (level, slots, ...) can
-- leak into the static path. strictArmorType is whitelisted because it is a
-- gearing RULE (with per-alt overrides), not character state.
local function SpecProbe(class, specID, alt)
    -- plain local, not "x or nil": a per-alt `false` override must survive
    local rule = alt and alt.strictArmorType
    return { class = class, activeSpecID = specID,
        specName = specID and addon.SpecName(specID) or nil,
        strictArmorType = rule }
end

-- The spec-scoped evaluator: would THIS class+spec use the item at all?
-- Ignores level, worn gear, and slot occupancy. Never answers "respec" -
-- that decision belongs to the wrapper, which probes the class's other
-- specs through this same function. A nil/unknown specID nil-passes the
-- capability gates (the slot mapping still applies).
-- Returns uses, reason, why("no"|nil), slotID, dualSlots
local function SpecUsesItemOn(itemInfo, probe)
    local invType = itemInfo.invType
    if not invType then
        return false, "Unknown inventory slot", "no"
    end

    local slotID, dualSlots = GetTargetSlots(invType, itemInfo.class)
    if not slotID then
        return false, ("No inventory slot for %s"):format(invType), "no"
    end

    -- armor type: the class's canonical type only; off-type gear is never a
    -- suggestion, even if it would be an upgrade for a misgeared alt.
    -- Cloaks report as class 4 subclass "cloth" for everyone; the armor tier
    -- check is meaningless for them (same for any future all-class accessories).
    if not IsWeaponish(invType) and itemInfo.class ~= 2
        and invType ~= "INVTYPE_CLOAK" then
        local tier = itemInfo.subclass
        if ARMOR_TIER_SUBS[tier] then
            local classTier = CLASS_ARMOR[probe.class]
            if classTier and tier ~= classTier then
                -- strict (default): only the canonical tier counts. Relaxed:
                -- lighter tiers are legal to wear (leveling/transmog alts),
                -- heavier ones the class simply cannot equip
                local relaxed = not addon.SettingIsOn("strictArmorType", probe)
                if not relaxed or tier > classTier then
                    return false, ("Item is %s; %s wears %s"):format(
                        ItemSubclassName(4, tier), addon.PrettyClass(probe.class),
                        ItemSubclassName(4, classTier)), "no"
                end
            end
        end
    end

    -- main-stat gate for every gear slot (weapons, armor, trinkets); items
    -- whose stats cannot be determined pass rather than being dropped
    do
        local itemStats = GetCachedMainStats(itemInfo)
        local specStats = SpecPrimaryStats(probe.activeSpecID)
        if itemStats and specStats then
            local matched
            for stat in pairs(itemStats) do
                if specStats[stat] then
                    matched = true
                end
            end
            if not matched then
                return false, ("Item is %s; %s uses %s"):format(
                    addon.FormatStatSet(itemStats),
                    probe.specName or addon.PrettyClass(probe.class) or "alt",
                    addon.FormatStatSet(specStats)), "no"
            end
        end
    end

    -- FR-8 trinket role gate (ItemRoles.lua): a tank/heal/melee/ranged proc
    -- trinket is useless to the wrong role even when primary stats match
    if itemInfo.invType == "INVTYPE_TRINKET" then
        local rejected, reason = addon.ItemRolesGate(itemInfo, probe)
        if rejected then
            return false, reason, "no"
        end
    end

    -- weapon type gate: class-2 candidates must appear in the spec's
    -- SPEC_WEAPONS entry. The gate must not depend on class metadata: a bag
    -- item whose classID failed to resolve would otherwise skip this gate
    -- and surface as a level-blocked "future upgrade" for specs that can
    -- never wield it (a wand offered to a Protection Paladin). Mainhand
    -- weapon invTypes are gated by subclass even when the class is unknown;
    -- offhand-slot items keep their dedicated gates below. Unknown
    -- spec/class passes.
    if itemInfo.class == 2
        or (IsWeaponish(invType) and not OFFHAND_SLOT_INV_TYPES[invType]) then
        if SpecAllowsWeapon(probe.activeSpecID, itemInfo.subclass) == false then
            return false, ("%s does not use %s"):format(
                probe.specName or addon.PrettyClass(probe.class) or "?",
                ItemSubclassName(2, itemInfo.subclass)), "no"
        end
    end

    if invType == "INVTYPE_SHIELD" then
        if SpecAllowsShield(probe.activeSpecID) == false then
            return false, ("Class %s (%s) cannot use shields"):format(
                addon.PrettyClass(probe.class),
                probe.specName or "spec unknown"), "no"
        end
    end

    -- the offhand fills per the spec's KIND: a shield (shield policy), a
    -- second weapon (dual policies), or a held item (HOLDABLE_SPECS);
    -- 2H/ranged-only specs never get an offhand at all
    if slotID == 17 then
        local kind = invType == "INVTYPE_SHIELD" and "shield"
            or invType == "INVTYPE_HOLDABLE" and "holdable" or "weapon"
        if SpecAllowsOffhandKind(probe.activeSpecID, kind) == false then
            return false, ("%s has no offhand options for %s"):format(
                probe.specName or probe.class or "?",
                kind == "shield" and "a shield"
                    or kind == "holdable" and "a held item" or "a second weapon"),
                "no"
        end
    end

    return true, nil, nil, slotID, dualSlots
end

-- Static question: would this class - and, when the alt's spec is known,
-- that spec - use an item of this kind at all? Ignores level, worn gear,
-- and slot occupancy. The alt's own spec is probed first; on a rejection
-- the class's other specs run through the SAME evaluator, and any acceptor
-- upgrades the answer to "respec" carrying those specs' names - the
-- accepting spec passed EVERY gate, including stats plus weapon type. An
-- alt without a known spec asks the plain class question: any spec's
-- acceptance counts.
-- Returns uses, reason, why, slotID, dualSlots, respecSpecs
--   why = "respec" (a sibling spec accepts; respecSpecs names them) or "no"
function addon.SpecUsesItem(itemInfo, alt)
    local class = alt.class
    local classSpecs = CLASS_SPECS[class]
    if not classSpecs then
        -- unknown class: the gates nil-pass unknown identities, but the
        -- slot mapping still applies
        return SpecUsesItemOn(itemInfo, SpecProbe(class, alt.activeSpecID, alt))
    end

    if not alt.activeSpecID then
        -- class question: any spec's acceptance counts
        local firstReason
        for _, specID in ipairs(classSpecs) do
            local uses, reason, _, slotID, dualSlots =
                SpecUsesItemOn(itemInfo, SpecProbe(class, specID, alt))
            if uses then
                return true, nil, nil, slotID, dualSlots
            end
            firstReason = firstReason or reason
        end
        return false, firstReason, "no"
    end

    local uses, reason, _, slotID, dualSlots =
        SpecUsesItemOn(itemInfo, SpecProbe(class, alt.activeSpecID, alt))
    if uses then
        return true, nil, nil, slotID, dualSlots
    end

    -- the alt's own spec refuses: would any sibling take it through the
    -- same gates?
    local names
    for _, specID in ipairs(classSpecs) do
        if specID ~= alt.activeSpecID then
            local siblingUses = SpecUsesItemOn(itemInfo,
                SpecProbe(class, specID, alt))
            if siblingUses then
                names = names or {}
                names[#names + 1] = addon.SpecName(specID)
            end
        end
    end
    if names then
        table.sort(names)
        return false, reason, "respec", nil, nil, names
    end
    return false, reason, "no"
end

-- Stateful question: can THIS alt, at its captured level and with the
-- weapons it currently holds, equip this item right now? Builds on
-- SpecUsesItem and answers four ways:
--   "yes"        - wear it now (slotID/slotFixed/candidateSlots as below)
--   "eventually" - only the alt's level or current weapon load-out blocks it
--   "respec"     - the current spec would not use it, but another spec of
--                  the class would
--   "no"         - this alt could never wear it
-- slotFixed = a unique-equipped swap already pinned slotID; candidateSlots
-- = every slot the item fits (two fingers/trinkets, either hand when
-- dual-wielding); the caller in Scoring.lua resolves the choice.
function addon.IsItemEligibleForAlt(itemInfo, alt)
    -- static rules FIRST, before the level compare: a low-level Mage shown
    -- a Ret-only 2H axe must honestly answer "no", not "eventually" - the
    -- tooltip stat scan is cached per candidate anyway
    local uses, reason, why, slotID, dualSlots, respecSpecs =
        addon.SpecUsesItem(itemInfo, alt)
    if not uses then
        return why or "no", reason, nil, nil, nil, respecSpecs
    end

    if itemInfo.minLevel and alt.level and itemInfo.minLevel > 0
        and itemInfo.minLevel > alt.level then
        return "eventually", ("Requires level %d (character is %d)"):format(
            itemInfo.minLevel, alt.level)
    end

    local invType = itemInfo.invType
    local slots = alt.slots or {}

    -- Unique-Equipped items (rings etc.) cannot be worn twice; a second copy
    -- is only useful as a swap of the existing one, so target the slot that
    -- already wears the same itemID (identity = itemID, not name)
    local uniqueSwapSlot
    if dualSlots then
        local candidateID = addon.GetItemID(itemInfo.itemLink)
        if candidateID then
            for _, slot in ipairs(dualSlots) do
                local snap = slots[slot]
                if snap and snap.itemID == candidateID then
                    uniqueSwapSlot = slot
                    break
                end
            end
        end
    end

    local mainhand = slots[16]
    local offhand = slots[17]

    local function IsEquippedWeaponish(snap)
        return snap and snap.invType and IsWeaponish(snap.invType)
            and snap.invType ~= "INVTYPE_SHIELD"
    end

    -- shields / offhand weapons / holdables are distinct offhand kinds
    local function OffhandCategory(invType)
        if invType == "INVTYPE_SHIELD" then
            return "shield"
        elseif invType == "INVTYPE_HOLDABLE" then
            return "holdable"
        end
        return "weapon"
    end

    -- weapon load-out blocks are all "eventually": one vendor visit away;
    -- skippable entirely for players who mail whole load-out swap sets
    if not addon.SettingIsOn("allowWeaponLoadoutSwap", alt) then
        if IsTwoHanded(invType) then
            -- allowed when the offhand is empty or holds a weapon (dual-wield swap)
            if offhand and offhand.invType and not IsEquippedWeaponish(offhand) then
                return "eventually", "Offhand holds a shield; Item is a two-hander"
            end
        elseif slotID == 16 then
            -- one-handed mainhands (incl. wands and ranged weapons)
            if mainhand and mainhand.invType and IsTwoHanded(mainhand.invType) then
                return "eventually", "Character is currently set up with a two-handed weapon"
            end
        elseif slotID == 17 then
            if mainhand and mainhand.invType and IsTwoHanded(mainhand.invType) then
                return "eventually", "Character is currently set up with a two-handed weapon"
            end
            if offhand and offhand.invType then
                local candidateCat = OffhandCategory(invType)
                local currentCat = OffhandCategory(offhand.invType)
                if candidateCat ~= currentCat then
                    return "eventually", ("Offhand currently holds a %s; Item is a %s")
                        :format(currentCat, candidateCat)
                end
            end
        end
    end

    -- dual-wieldable weapons: offer both weapon slots per the spec's
    -- offhand policy. A 1H candidate is offered to "dual" and "dual2H"
    -- specs; a 2H candidate ONLY to "dual2H" (Fury) — Survival's 2H
    -- weapons are mainhand-only. This is the one STATEFUL policy consumer:
    -- the real (possibly spec-less) alt resolves its policy here, falling
    -- back to the class union so a spec-less DH still gets dual offers
    local dualWieldSlots
    if slotID == 16 and itemInfo.class == 2 then
        local policy = alt.activeSpecID
            and SpecOffhandPolicy(alt.activeSpecID)
            or ClassOffhandPolicies(alt.class)
        if policy and policy.dual then
            local offhandOk
            if policy.dual2H then
                offhandOk = OFFHAND_1H[itemInfo.subclass]
                    or OFFHAND_2H[itemInfo.subclass]
            else
                offhandOk = OFFHAND_1H[itemInfo.subclass]
            end
            if offhandOk then
                dualWieldSlots = { 16 }
                local category = offhand and offhand.invType
                    and OffhandCategory(offhand.invType)
                if not category or category == "weapon" then
                    dualWieldSlots[2] = 17
                end
            end
        end
    end

    -- one of the two lists is set for anything that fits multiple slots:
    -- fingers/trinkets (from GetTargetSlots) or dual-wield weapons
    return "yes", nil, uniqueSwapSlot or slotID, uniqueSwapSlot ~= nil,
        dualWieldSlots or dualSlots
end

-- "Roll one!" probe for the safe-to-destroy decision: does any class NOT
-- present on the roster have a spec that would use this item? Excluded alts
-- still own their class (the character exists), so they count as owned.
-- Returns sorted class tokens, e.g. { "DEMONHUNTER" }.
function addon.ClassesWithoutAltUsing(itemInfo)
    local owned = {}
    for _, alt in pairs(GearFallDB.alts) do
        if alt.class then
            owned[alt.class] = true
        end
    end
    local missing = {}
    for cls in pairs(CLASS_SPECS) do
        if not owned[cls] and addon.SpecUsesItem(itemInfo, { class = cls }) then
            missing[#missing + 1] = cls
        end
    end
    table.sort(missing)
    return missing
end

local _, addon = ...

-- FR-8: item role classification. C_Item.GetItemSpecInfo(itemID) returns
-- the specs of the CURRENT character's class that want the item - always
-- (calibration §9). The link form widens to cross-class lists for some
-- multi-role items but stays class-filtered for others, so the pipeline
-- stores per-class observations: every character's sighting fills its own
-- class's entry ("army of alts"), and a post-login backfill queries stored
-- itemIDs for the gaps.

-- Roles: TANK, HEAL, DPS-MELEE, DPS-RANGED (the STR/INT/AGI main-stat gate
-- runs first, so roles only split melee vs ranged within a stat family).
-- Used by the manual seed list and verdict wording, not the per-class gate.
local SPEC_ROLES = {
    TANK = { 66, 73, 250, 104, 268, 581 },
    HEAL = { 65, 105, 256, 257, 264, 270, 1468 },
    ["DPS-MELEE"] = { 71, 72, 251, 252, 70,
        259, 260, 261, 577, 103, 269, 263, 255 },
    ["DPS-RANGED"] = { 62, 63, 64, 262, 258, 265, 266, 267,
        1467, 1473, 1480, 102, 253, 254 },
}

local SPEC_ROLE_OF = {}
for role, list in pairs(SPEC_ROLES) do
    for _, specID in ipairs(list) do
        SPEC_ROLE_OF[specID] = role
    end
end

-- Display labels for the role keys used in reason strings
local ROLE_LABELS = {
    TANK = "Tanks",
    HEAL = "Healers",
    ["DPS-MELEE"] = "Melee DPS",
    ["DPS-RANGED"] = "Ranged DPS",
}
local function RoleLabel(role)
    return ROLE_LABELS[role] or role
end


-- Manual corrections, always win over accumulated data. Grow this as
-- misclassifications are reported (TRINKET_ROLES[itemID] = { "TANK" }).
addon.TRINKET_ROLES = {}

local function db()
    if type(GearFallDB) ~= "table" then
        return nil
    end
    GearFallDB.itemRoles = GearFallDB.itemRoles or {}
    return GearFallDB.itemRoles
end


-- specID -> class token, built lazily from Eligibility's CLASS_SPECS
local SPEC_CLASS_OF
local function SpecClassOf(specID)
    if not SPEC_CLASS_OF and type(addon.CLASS_SPECS) == "table" then
        SPEC_CLASS_OF = {}
        for classToken, specs in pairs(addon.CLASS_SPECS) do
            for _, specID in ipairs(specs) do
                SPEC_CLASS_OF[specID] = classToken
            end
        end
    end
    return SPEC_CLASS_OF and SPEC_CLASS_OF[specID]
end

local function AddSpec(list, specID)
    for _, existing in ipairs(list) do
        if existing == specID then
            return false
        end
    end
    list[#list + 1] = specID
    return true
end

local function ListContains(list, specID)
    for _, existing in ipairs(list) do
        if existing == specID then
            return true
        end
    end
    return false
end


-------------------------------------------------------------------------------
-- Role hypothesis: a class's COMPLETE byID view speaks about every role the
-- class possesses whose specs are stat-compatible with the item (a Holy
-- paladin cannot vote on a STR trinket's heal-ness - the stat gate would
-- block it regardless). Listed role => positive; stat-compatible but
-- unlisted role => negative. Positives and negatives accumulate across
-- classes; a role confirmed by one class and denied by another is a
-- CONFLICT - it stops gating until reviewed manually.
-------------------------------------------------------------------------------

local function RoleSpecsFor(classToken, role)
    local out = {}
    for _, specID in ipairs((addon.CLASS_SPECS or {})[classToken] or {}) do
        if SPEC_ROLE_OF[specID] == role then
            out[#out + 1] = specID
        end
    end
    return out
end

local function SpecStatCompatible(specID, itemStats)
    if not itemStats then
        return false -- unknown stats: cannot speak about roles
    end
    local specStats = addon.SPEC_PRIMARY_STATS
        and addon.SPEC_PRIMARY_STATS[specID]
    if not specStats then
        return false
    end
    for stat in pairs(specStats) do
        if itemStats[stat] then
            return true
        end
    end
    return false
end

-- Roles that vote by possession alone, no stat-compatibility needed:
-- HEAL because all heal specs share Intellect (a cross-stat vote is inert
-- behind the stat gate), and TANK because tank trinkets are Stamina-
-- flavored and stat-agnostic in practice - a paladin's Prot listing is
-- evidence for every tank spec, and the stat gate still filters true
-- AGI/STR mismatches for the candidate itself.
local POSSESSION_VOTED_ROLES = { HEAL = true, TANK = true }

local function Hypothesis(entry)
    entry.roleInference = entry.roleInference or { roles = {}, noRoles = {},
        conflicts = {}, posBy = {}, negBy = {} }
    return entry.roleInference
end

local function RoleConflict(entry, role, classToken, link)
    local hyp = Hypothesis(entry)
    if not hyp.conflicts[role] then
        hyp.conflicts[role] = GetServerTime()
        hyp.noRoles[role] = nil
        hyp.roles[role] = nil
        -- the recording is unconditional (the library grows even while the
        -- inference is opt-in); only the chat alert waits for the flag
        if addon.SettingIsOn("trinketRoleHypothesis", nil) then
            addon.Print(("Trinket role conflict: %s - role %s is both confirmed "
                .. "(%s) and denied (%s) across classes - review /gear conflicts")
                :format(addon.ClickableItemLink(entry.link, entry.id) or "a trinket", role,
                    hyp.posBy[role] or hyp.negBy[role] or "?", classToken))
        end
    end
end

local function UpdateRoleHypothesis(entry, classToken, list, itemStats, link)
    local hyp = Hypothesis(entry)
    for role in pairs(SPEC_ROLES) do
        local roleSpecs = RoleSpecsFor(classToken, role)
        if #roleSpecs > 0 then
            local anyCompatible, anyListed
            for _, specID in ipairs(roleSpecs) do
                if POSSESSION_VOTED_ROLES[role]
                    or SpecStatCompatible(specID, itemStats) then
                    anyCompatible = true
                    if ListContains(list, specID) then
                        anyListed = true
                    end
                end
            end
            if anyCompatible then
                if anyListed then
                    if hyp.noRoles[role] and not hyp.conflicts[role] then
                        -- a class the hypothesis counted as negative now
                        -- lists the role: proven otherwise
                        RoleConflict(entry, role, classToken, link)
                    end
                    if not hyp.conflicts[role] then
                        hyp.roles[role] = GetServerTime()
                        hyp.posBy[role] = classToken
                    end
                else
                    if hyp.roles[role] and not hyp.conflicts[role] then
                        RoleConflict(entry, role, classToken, link)
                    end
                    if not hyp.conflicts[role] then
                        hyp.noRoles[role] = GetServerTime()
                        hyp.negBy[role] = classToken
                    end
                end
            end
        end
    end
end

-- Record one sighting. specIDs is the byID view (complete truth for the
-- observing class: it may PASS and REJECT); wideSpecs (the byLink view) is
-- optional and contributes only POSITIVE info for other classes - its
-- foreign specs are stored as derived entries that can never reject, since
-- the link form's cross-class widening is inconsistent (calibration §9).
-- Fill-if-missing; re-sightings only add; lost specs are conflicts -
-- alerted and recorded, never auto-resolved.
function addon.ItemRolesObserve(itemID, classToken, specIDs, link, wideSpecs,
    itemStats)
    if not itemID or not classToken then
        return "skip"
    end
    local store = db()
    if not store then
        return "skip"
    end
    local now = GetServerTime()
    local entry = store[itemID]
    if not entry then
        entry = { classes = {}, t = now, link = link, id = itemID }
        store[itemID] = entry
    end
    entry.classes = entry.classes or {}
    -- entries saved by older builds may lack the link; heal on re-sighting
    if link and not entry.link then
        entry.link = link
    end
    local outcome

    -- own class: complete per-class view
    if specIDs ~= nil then
        local list = {}
        for _, specID in ipairs(specIDs) do
            list[#list + 1] = specID
        end
        local cur = entry.classes[classToken]
        if not cur then
            entry.classes[classToken] = { specs = list, t = now,
                complete = true }
            outcome = "stored"
        elseif not cur.complete then
            -- own view upgrades derived data and is authoritative; derived
            -- specs it does not confirm are contradictions
            local lost
            for _, old in ipairs(cur.specs) do
                if not ListContains(list, old) then
                    lost = true
                end
            end
            if lost then
                entry.conflicts = entry.conflicts or {}
                if not entry.conflicts[classToken] then
                    entry.conflicts[classToken] = now
                    addon.Print(("Trinket data conflict: %s no longer lists the "
                        .. "%s spec(s) it served before - review /gear conflicts")
                        :format(addon.ClickableItemLink(entry.link or link, itemID), classToken))
                end
                outcome = "conflict"
            end
            entry.classes[classToken] = { specs = list, t = now,
                complete = true }
            outcome = outcome or "updated"
        else
            -- complete re-sighting: additive growth, conflicts on losses
            local seen = {}
            local changed, lost
            for _, specID in ipairs(list) do
                if not seen[specID] then
                    seen[specID] = true
                    if AddSpec(cur.specs, specID) then
                        changed = true
                    end
                end
            end
            for _, old in ipairs(cur.specs) do
                if not seen[old] then
                    lost = true
                end
            end
            if lost then
                entry.conflicts = entry.conflicts or {}
                if not entry.conflicts[classToken] then
                    entry.conflicts[classToken] = now
                    addon.Print(("Trinket data conflict: %s no longer lists the "
                        .. "%s spec(s) it served before - review /gear conflicts")
                        :format(addon.ClickableItemLink(entry.link or link, itemID), classToken))
                end
                outcome = "conflict"
            else
                outcome = changed and "updated" or "ok"
            end
        end
        if entry.classes[classToken].complete then
            UpdateRoleHypothesis(entry, classToken, list, itemStats, link)
        end
    end

    -- foreign specs from the wide (byLink) view: positive-only, never
    -- reject, and never added to a class's own complete view (the byID
    -- negative wins over a widened foreign claim)
    if wideSpecs then
        for _, specID in ipairs(wideSpecs) do
            local foreignClass = SpecClassOf(specID)
            if foreignClass and foreignClass ~= classToken then
                local fe = entry.classes[foreignClass]
                if not fe then
                    entry.classes[foreignClass] = { specs = { specID },
                        t = now, derived = true }
                    outcome = outcome or "updated"
                elseif not fe.complete and AddSpec(fe.specs, specID) then
                    outcome = outcome or "updated"
                end
            end
        end
    end

    return outcome or "skip"
end

-- Clickable link for a stored entry, for command output
function addon.ItemRolesEntryLink(entry, itemID)
    return addon.ClickableItemLink(entry and entry.link, itemID)
end

local function SiblingVerdict(alt, classSpecIDs, hasSpec)
    for _, specID in ipairs(classSpecIDs or {}) do
        if specID ~= alt.activeSpecID and hasSpec(specID) then
            return "respec"
        end
    end
    return "no"
end

-- Cross-class role hypothesis verdict, used only when the alt's class has
-- never observed the item itself. Opt-in via trinketRoleHypothesis: the
-- inference still RECORDS while off, it just never gates.
local function HypothesisVerdict(entry, alt, classSpecIDs)
    if not addon.SettingIsOn("trinketRoleHypothesis", alt) then
        return "pass"
    end
    local hyp = entry and entry.roleInference
    local role = alt.activeSpecID and SPEC_ROLE_OF[alt.activeSpecID]
    if not hyp or not role or hyp.conflicts[role] then
        return "pass"
    end
    if hyp.roles[role] then
        return "pass"
    end
    if not hyp.noRoles[role] then
        return "pass"
    end
    local servedRoles = {}
    for servedRole in pairs(hyp.roles) do
        servedRoles[#servedRoles + 1] = RoleLabel(servedRole)
    end
    table.sort(servedRoles)
    local reason = (#servedRoles > 0)
        and ("Item is for %s; %s is %s"):format(
            table.concat(servedRoles, "/"),
            alt.specName or "this spec", RoleLabel(role))
        or ("Item is believed useless for %s (inferred from other classes)")
            :format(RoleLabel(role))
    return "reject", reason, SiblingVerdict(alt, classSpecIDs,
        function(specID)
            return hyp.roles[SPEC_ROLE_OF[specID]] ~= nil
        end)
end

-- Verdict for one trinket against one alt.
--   "pass"                     - spec matches, or nothing is known
--   "reject", reason, "respec" - wrong spec, but a sibling would use it
--   "reject", reason, "no"     - no spec of the alt's class serves it
function addon.ItemRolesCheck(itemID, alt, classSpecIDs)
    local seed = itemID and addon.TRINKET_ROLES[itemID]
    if seed then
        local role = alt.activeSpecID and SPEC_ROLE_OF[alt.activeSpecID]
        if not role then
            return "pass"
        end
        local roleSet = {}
        for _, r in ipairs(seed) do
            roleSet[r] = true
        end
        if roleSet[role] then
            return "pass"
        end
        local labels = {}
        for _, r in ipairs(seed) do
            labels[#labels + 1] = RoleLabel(r)
        end
        return "reject", ("Item is for %s; %s is %s (manually marked)"):format(
            table.concat(labels, "/"), alt.specName or "this spec",
            RoleLabel(role)),
            SiblingVerdict(alt, classSpecIDs,
                function(specID) return roleSet[SPEC_ROLE_OF[specID]] end)
    end
    local store = type(GearFallDB) == "table" and GearFallDB.itemRoles
    local entry = itemID and store and store[itemID]
    local classEntry = entry and entry.classes and entry.classes[alt.class]
    if not classEntry then
        return HypothesisVerdict(entry, alt, classSpecIDs)
    end
    local specSet = {}
    for _, specID in ipairs(classEntry.specs) do
        specSet[specID] = true
    end
    if alt.activeSpecID and specSet[alt.activeSpecID] then
        return "pass"
    end
    if not classEntry.complete then
        -- derived from another class's wide sighting: positive-only evidence,
        -- never a rejection (fail-open until this class observes it itself)
        return "pass"
    end
    local names = {}
    for _, specID in ipairs(classEntry.specs) do
        names[#names + 1] = addon.SpecName(specID)
    end
    table.sort(names)
    local reason = (#names > 0)
        and ("Item is for %s; %s is %s"):format(
            table.concat(names, ", "), alt.specName or "this spec",
            RoleLabel(SPEC_ROLE_OF[alt.activeSpecID]) or "?")
        or ("No spec of %s can use this trinket"):format(alt.class or "this class")
    return "reject", reason, SiblingVerdict(alt, classSpecIDs,
        function(specID) return specSet[specID] end)
end

-------------------------------------------------------------------------------
-- Backfill: after login, query stored items whose data lacks this class
-------------------------------------------------------------------------------

local function QueryAndStore(itemID, classToken, entry)
    local api = C_Item and C_Item.GetItemSpecInfo
    if not api then
        return false
    end
    local ok, specs = pcall(api, itemID)
    if not (ok and specs ~= nil) then
        return false
    end
    local wideSpecs
    if entry and entry.link then
        local okWide, wide = pcall(api, entry.link)
        if okWide then
            wideSpecs = wide
        end
    end
    addon.ItemRolesObserve(itemID, classToken, specs, entry and entry.link,
        wideSpecs, addon.GetItemMainStats and addon.GetItemMainStats(
            entry and entry.link or itemID))
    return true
end

function addon.ItemRolesBackfill()
    if type(UnitClass) ~= "function" then
        return
    end
    local classToken = select(2, UnitClass("player"))
    if not classToken then
        return
    end
    local store = db()
    if not store then
        return
    end
    local load = C_Item and C_Item.RequestLoadItemData
    local pending = {}
    for itemID, entry in pairs(store) do
        if not (entry.classes and entry.classes[classToken]) then
            pending[#pending + 1] = itemID
        end
    end
    table.sort(pending)
    if #pending == 0 then
        return
    end
    addon.DebugPrint(("debug: backfilling item specs for %s (%d item(s))")
        :format(classToken, #pending))
    local function RunPass(pass)
        local i = 0
        local missed = {}
        local function step()
            i = i + 1
            local itemID = pending[i]
            if not itemID then
                -- one retry pass for items whose data was still loading
                if pass == 1 and #missed > 0 then
                    pending = missed
                    C_Timer.After(3, function() RunPass(2) end)
                end
                return
            end
            local cachedInfo = C_Item and C_Item.GetItemInfo
            if load and cachedInfo and not cachedInfo(itemID) then
                pcall(load, itemID)
            end
            if not QueryAndStore(itemID, classToken, store[itemID]) then
                missed[#missed + 1] = itemID
            end
            C_Timer.After(0.1, step)
        end
        step()
    end
    RunPass(1)
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:SetScript("OnEvent", function()
    C_Timer.After(60, addon.ItemRolesBackfill)
end)

-------------------------------------------------------------------------------
-- Integration hooks: the rest of the addon touches this system only through
-- these two functions (Scan.lua captures, Eligibility.lua gates)
-------------------------------------------------------------------------------

-- Capture hook, called for every bag/equipped trinket: records the per-class
-- byID view plus the wide (byLink) foreign positives, and prints one debug
-- line per sighting
function addon.ItemRolesCapture(finalLink, itemName, bagID, slotIndex)
    local specApi = C_Item and C_Item.GetItemSpecInfo
    if not specApi or not finalLink then
        return
    end
    local finalID = addon.GetItemID(finalLink)
    local okLocal, localSpecs = pcall(specApi, finalID)
    if not okLocal then
        return
    end
    local classToken = UnitClass and select(2, UnitClass("player"))
    local okWide, wideSpecs = pcall(specApi, finalLink)
    local okObs, result = pcall(addon.ItemRolesObserve, finalID, classToken,
        localSpecs, finalLink, okWide and wideSpecs or nil,
        addon.GetItemMainStats
            and addon.GetItemMainStats(finalLink, bagID, slotIndex))
    addon.DebugPrint(("debug: trinket %s (%s) %s local=%s wide=%s -> %s"):format(
        itemName or "?", tostring(finalID), classToken or "?",
        localSpecs and ("#" .. #localSpecs) or tostring(localSpecs),
        wideSpecs and ("#" .. #wideSpecs) or tostring(wideSpecs),
        tostring(okObs and result or "pcall error")))
end

-- Gate hook: rejected (true, reason, why) or nil when the item passes or
-- the feature is disabled
function addon.ItemRolesGate(itemInfo, alt)
    if not itemInfo or not addon.SettingIsOn("trinketRoleGate", alt) then
        return nil
    end
    -- game spec info is authoritative regardless of primary stats: a
    -- stat-less (+stamina/+crit) trinket whose byID view says "Prot only"
    -- gates exactly like any other
    local itemID = itemInfo.itemLink and addon.GetItemID(itemInfo.itemLink)
    local verdict, reason, why = addon.ItemRolesCheck(itemID, alt,
        (addon.CLASS_SPECS or {})[alt.class])
    if verdict ~= "pass" then
        return true, reason, why
    end
    return nil
end

-- /gear itemspecs: human-readable dump of every saved item's role data and
-- the per-spec verdicts for one class (defaults to the current class).
-- Returns lines, or nil + badInput when the class is unknown.
-- Per-spec verdict state for one saved entry, from the class's own view
-- (on/off) with derived and hypothesis fallbacks (on*/?).
local function SpecVerdictState(entry, classToken, specID)
    local state = "?"
    local ce = entry and entry.classes and entry.classes[classToken]
    local role = SPEC_ROLE_OF[specID]
    if ce then
        if ListContains(ce.specs, specID) then
            state = ce.complete and "on" or "on*"
        else
            state = ce.complete and "off" or "?"
        end
    else
        local hyp = entry and entry.roleInference
        if hyp and role and not hyp.conflicts[role] then
            if hyp.roles[role] then
                state = "on*"
            elseif hyp.noRoles[role] then
                state = "off*"
            end
        end
    end
    return state
end

function addon.ItemRolesReport(classArg)
    local store = type(GearFallDB) == "table" and GearFallDB.itemRoles
    if not store or not next(store) then
        return { "no item role data recorded yet" }
    end
    local classToken
    if classArg and classArg:match("^%s*(.-)%s*$") ~= "" then
        classToken = classArg:match("^%s*(.-)%s*$"):gsub("%s", ""):upper()
        if not (addon.CLASS_SPECS or {})[classToken] then
            return nil, classToken
        end
    else
        classToken = UnitClass and select(2, UnitClass("player"))
    end
    local ids = {}
    local itemCount = 0
    for itemID in pairs(store) do
        ids[#ids + 1] = itemID
        itemCount = itemCount + 1
    end
    table.sort(ids)
    local lines = {
        ("item roles for %s (%d item(s))"):format(classToken or "?", itemCount),
    }
    local classSpecIDs = (addon.CLASS_SPECS or {})[classToken] or {}
    for _, itemID in ipairs(ids) do
        local entry = store[itemID]
        local seenParts = {}
        for cls, ce in pairs(entry.classes or {}) do
            seenParts[#seenParts + 1] = ("%s=%s(%d)"):format(cls,
                ce.complete and "seen" or "derived", #ce.specs)
        end
        table.sort(seenParts)
        local hyp = entry.roleInference
        local hypParts = {}
        if hyp then
            for role in pairs(hyp.roles) do
                hypParts[#hypParts + 1] = "+" .. role
            end
            for role in pairs(hyp.noRoles) do
                hypParts[#hypParts + 1] = "-" .. role
            end
            for role in pairs(hyp.conflicts) do
                hypParts[#hypParts + 1] = "?" .. role
            end
            table.sort(hypParts)
        end
        local specParts = {}
        for _, specID in ipairs(classSpecIDs) do
            local state = SpecVerdictState(entry, classToken, specID)
            specParts[#specParts + 1] = ("%s=%s"):format(addon.SpecName(specID),
                state)
        end
        lines[#lines + 1] = ("%s | seen: %s | inferred: %s | %s: %s"):format(
            addon.ItemRolesEntryLink(entry, itemID),
            #seenParts > 0 and table.concat(seenParts, " ") or "none",
            #hypParts > 0 and table.concat(hypParts, " ") or "none",
            classToken or "?",
            #specParts > 0 and table.concat(specParts, " ") or "-")
    end
    return lines
end

-- /gear itemspecs <link|ID>: everything recorded about one trinket, plus
-- the raw API answer right now (for calibration comparisons)
function addon.ItemRolesItemDetail(arg)
    local link = arg and addon.NormalizeItemLink(arg) or nil
    local itemID = (link and addon.GetItemID(link)) or tonumber(arg)
    if not itemID then
        return nil
    end
    local store = type(GearFallDB) == "table" and GearFallDB.itemRoles
    local entry = store and store[itemID]
    local lines = {}
    lines[#lines + 1] = ("trinket %d role data (%s)"):format(itemID,
        entry and "recorded" or "no data recorded - hover it in bags to observe")
    if entry then
        local seenParts = {}
        for cls, ce in pairs(entry.classes or {}) do
            local names = {}
            for _, specID in ipairs(ce.specs) do
                names[#names + 1] = addon.SpecName(specID)
            end
            table.sort(names)
            seenParts[#seenParts + 1] = ("%s=%s{%s}"):format(cls,
                ce.complete and "seen" or "derived",
                table.concat(names, ", ") or "-")
        end
        table.sort(seenParts)
        for _, part in ipairs(seenParts) do
            lines[#lines + 1] = "  " .. part
        end
        local hyp = entry.roleInference
        if hyp then
            for role in pairs(hyp.roles) do
                lines[#lines + 1] = ("  +%s (by %s)"):format(role,
                    hyp.posBy[role] or "?")
            end
            for role in pairs(hyp.noRoles) do
                lines[#lines + 1] = ("  -%s (by %s)"):format(role,
                    hyp.negBy[role] or "?")
            end
            for role in pairs(hyp.conflicts) do
                lines[#lines + 1] = ("  ?%s CONFLICT - review /gear conflicts")
                    :format(role)
            end
        end
    end
    lines[#lines + 1] = "raw API: " .. addon.DescribeItemSpecInfo(link, itemID)
    -- per-spec verdicts for the current character
    local classToken = UnitClass and select(2, UnitClass("player"))
    local classSpecIDs = (addon.CLASS_SPECS or {})[classToken]
    if classSpecIDs then
        local specParts = {}
        for _, specID in ipairs(classSpecIDs) do
            specParts[#specParts + 1] = ("%s=%s"):format(addon.SpecName(specID),
                SpecVerdictState(entry, classToken, specID))
        end
        lines[#lines + 1] = ("%s: %s"):format(classToken or "?",
            table.concat(specParts, " "))
    end
    return lines
end

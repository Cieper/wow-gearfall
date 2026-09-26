local _, addon = ...

local DB_VERSION = 1

local function InitDB()
    if type(GearFallDB) ~= "table" then
        GearFallDB = {}
    end
    local db = GearFallDB
    db.version = db.version or DB_VERSION
    db.alts = db.alts or {}
    db.sendHistory = db.sendHistory or {}
    db.settings = db.settings or {}
    if db.settings.includeBoE == nil then
        db.settings.includeBoE = true
    end
    db.settings.tags = db.settings.tags or {}
    db.__addonMarker, db.__chatMarker = nil, nil
end

local init = CreateFrame("Frame")
init:RegisterEvent("ADDON_LOADED")
init:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" and addonName == "GearFall" then
        InitDB()
    end
end)

-- Gearing-rule settings registry. Adding a setting = one entry here (plus its
-- gate, plus perAlt = true if roster rows should offer an override); the
-- Settings page and the roster dropdowns render themselves from this table.
-- Values resolve: alt[key] override -> GearFallDB.settings[key] -> default,
-- and db.settings stays UNSEEDED so untouched installs keep inheriting.
addon.SETTINGS = {
    strictArmorType = { default = true, perAlt = true, label = "Strict armor type" },
    allowWeaponLoadoutSwap = { default = false, perAlt = true, label = "Allow load-out swaps" },
    trinketRoleGate = { default = true, perAlt = false, label = "Trinket role gate" },
    trinketRoleHypothesis = { default = false, perAlt = false,
        label = "Infer trinket roles across classes" },
    draftStrategy = { type = "choice", default = "biggest", perAlt = false,
        label = "Mail strategy",
        options = {
            { key = "biggest", label = "Biggest upgrade" },
            { key = "priority", label = "Roster priority" },
        } },
}

function addon.SettingChoice(key)
    local db = GearFallDB
    if db.settings and db.settings[key] ~= nil then
        return db.settings[key]
    end
    local def = addon.SETTINGS[key]
    return def and def.default
end

function addon.SettingIsOn(key, alt)
    if alt and alt[key] ~= nil then
        return alt[key] and true or false
    end
    local db = GearFallDB
    if db.settings and db.settings[key] ~= nil then
        return db.settings[key] and true or false
    end
    local def = addon.SETTINGS[key]
    return def and def.default and true or false
end

-- Ambient/event-driven diagnostics (capture lifecycle, trinket sightings,
-- backfill summaries) go through here; they are silent unless the user has
-- enabled /gear debug. Explicit command output keeps using addon.Print.
function addon.DebugPrint(msg)
    local db = GearFallDB
    if db and db.settings and db.settings.debug then
        addon.Print(msg)
    end
end

-- Calibration helper (FR-8 groundwork): dump C_Item.GetItemSpecInfo exactly
-- as the API returns it, before any gate trusts it. nil vs {} vs spec-ID
-- list are all meaningful and must stay distinguishable in the output.
local function TrySpecInfo(api, arg)
    local ok, specs = pcall(api, arg)
    if not ok then
        return ("error(%s)"):format(tostring(specs))
    end
    if specs == nil then
        return "nil"
    end
    if type(specs) ~= "table" then
        return ("non-table(%s)"):format(type(specs))
    end
    if #specs == 0 then
        return "{}"
    end
    local names = {}
    for _, specID in ipairs(specs) do
        local okName, _, specName = pcall(GetSpecializationInfoByID, specID)
        names[#names + 1] = (okName and specName)
            and ("%d %s"):format(specID, specName) or tostring(specID)
    end
    return "{" .. table.concat(names, ", ") .. "}"
end

function addon.DescribeItemSpecInfo(link, itemID)
    local api = C_Item and C_Item.GetItemSpecInfo
    if not api then
        return "API missing"
    end
    local parts = {}
    if itemID then
        parts[#parts + 1] = "byID=" .. TrySpecInfo(api, itemID)
    end
    if link then
        parts[#parts + 1] = "byLink=" .. TrySpecInfo(api, link)
    end
    return table.concat(parts, " ")
end

local function MatchAlts(filter)
    local db = GearFallDB
    local keys = {}
    for key in pairs(db.alts) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        local aa, bb = db.alts[a], db.alts[b]
        local ae, be = (aa.excluded and 1 or 0), (bb.excluded and 1 or 0)
        if ae ~= be then
            return ae < be
        end
        local at, bt = aa.prioTier or 9999, bb.prioTier or 9999
        if at ~= bt then
            return at < bt
        end
        return a:lower() < b:lower()
    end)
    if not filter or filter == "" then
        return keys
    end
    local f = filter:lower()
    local escaped = f:gsub("[^%w%-]", "%%%1")
    local matched = {}
    for _, key in ipairs(keys) do
        local k = key:lower()
        if k == f or k:find("^" .. escaped .. "%-") then
            matched[#matched + 1] = key
        end
    end
    return matched
end

function addon.Dump(filter)
    local db = GearFallDB
    if not db then
        addon.Print("database not loaded yet")
        return
    end
    local keys = MatchAlts(filter)
    if filter and filter ~= "" and #keys == 0 then
        addon.Print(("no alt matching \"%s\""):format(filter))
        return
    end
    local version = (GetAddOnMetadata and GetAddOnMetadata("GearFall", "Version")) or "?"
    addon.Print(("dump v%s | %d alt(s) | %d send(s) | includeBoE=%s"):format(
        version, addon.CountTable(db.alts), #db.sendHistory, tostring(db.settings.includeBoE)))

    for _, key in ipairs(keys) do
        local alt = db.alts[key]
        addon.Print("---- " .. key)
        addon.Print(("  class=%s(%s) lvl=%s spec=%s(%s) role=%s avg=%s order=%s"):format(
            alt.class or "?", tostring(alt.classID or "?"), tostring(alt.level or "?"),
            tostring(alt.activeSpecID or "?"), alt.specName or "?",
            alt.role or "?", tostring(alt.avgItemLevel or "?"), tostring(alt.prioTier or "-")))
        addon.Print(("  mode=%s pawnScale=%s excluded=%s lastLogin=%s"):format(
            alt.scoringMode or "?", alt.pawnScaleName or "-", tostring(alt.excluded),
            (alt.lastLogin and alt.lastLogin > 0 and date("%Y-%m-%d %H:%M", alt.lastLogin)) or "-"))
        local tags = (alt.tags and #alt.tags > 0) and table.concat(alt.tags, ", ") or "-"
        addon.Print("  tags=" .. tags)
        for _, slot in ipairs(addon.EQUIP_SLOTS) do
            local equipped = alt.slots and alt.slots[slot]
            if equipped then
                addon.Print(("  [%02d] %-9s ilvl=%s"):format(
                    slot, addon.SLOT_NAMES[slot] or "?", tostring(equipped.itemLevel or "?")))
                DEFAULT_CHAT_FRAME:AddMessage("        " .. addon.FormatItem(equipped))
            end
        end
    end

    local keySet
    if filter and filter ~= "" then
        keySet = {}
        for _, key in ipairs(keys) do
            keySet[key:lower()] = true
        end
    end
    for i, entry in ipairs(db.sendHistory) do
        if not keySet
            or (entry.fromChar and keySet[entry.fromChar:lower()])
            or (entry.toChar and keySet[entry.toChar:lower()]) then
            addon.Print(("send #%d: %s -> %s delta=%s mode=%s date=%s"):format(
                i, entry.fromChar or "?", entry.toChar or "?", tostring(entry.scoreDelta or "?"),
                entry.scoringMode or "?", (entry.date and date("%Y-%m-%d %H:%M", entry.date)) or "?"))
        end
    end

    addon.Print("dump end")
end

function addon.CountTable(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

local function Serialize(value, depth)
    depth = depth or 0
    local t = type(value)
    if t == "table" then
        if depth >= 3 then
            return "{...}"
        end
        local parts = {}
        for k, v in pairs(value) do
            parts[#parts + 1] = ("[%s]=%s"):format(tostring(k), Serialize(v, depth + 1))
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif t == "string" then
        return ("%q"):format(value)
    end
    return tostring(value)
end

function addon.ProbeItemStats(link)
    addon.Print("stats probe: " .. tostring(link))

    addon.Print("C_Item.GetItemStats: "
        .. tostring(C_Item and C_Item.GetItemStats ~= nil))
    if C_Item and C_Item.GetItemStats then
        local ok, res = pcall(C_Item.GetItemStats, link)
        addon.Print("  statTable = " .. (ok and Serialize(res) or ("ERROR " .. tostring(res))))
    end

    addon.Print("GearFall detected: "
        .. addon.FormatStatSet(addon.GetItemMainStats(link)))
end

SLASH_GEARFALL1 = "/gearfall"
SLASH_GEARFALL2 = "/gear"

local function ReportItemScore(info, index)
    addon.Print(("%d) %s [%s/%s req=%s cls=%s/%s]"):format(
        index, addon.FormatItem(info),
        tostring(info.invType), tostring(info.itemLevel),
        tostring(info.minLevel),
        tostring(info.class), tostring(info.subclass)))
    local matches, advice = addon.FindBestAltsForItem(info)
    if #matches == 0 then
        if advice.hold then
            if advice.hold.kind == "respec" then
                addon.Print(("   ANOTHER SPEC WOULD USE THIS - %s: %s"):format(
                    advice.hold.key, advice.hold.reason or "?"))
            elseif advice.hold.kind == "newalt" then
                addon.Print(("   ROLL ONE! - %s. Keep it for that alt-to-be.")
                    :format(advice.hold.reason or "?"))
            else
                addon.Print(("   SAVE FOR LATER - %s: %s"):format(
                    advice.hold.key, advice.hold.reason or "?"))
            end
        elseif advice.usableButWorse then
            addon.Print("   fits an alt but nobody needs it - safe to sell/enchant")
        else
            addon.Print("   no alt could ever use this - safe to sell/enchant")
        end
        local keys = {}
        for key, alt in pairs(GearFallDB.alts) do
            if not alt.excluded then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys, function(a, b)
            local at = (GearFallDB.alts[a].excluded and 9000)
            or (GearFallDB.alts[a].prioTier or 9999)
        local bt = (GearFallDB.alts[b].excluded and 9000)
            or (GearFallDB.alts[b].prioTier or 9999)
        return at < bt
        end)
        for _, key in ipairs(keys) do
            local alt = GearFallDB.alts[key]
            local r = addon.ScoreItemForAlt(info, alt)
            if r.eligible then
                addon.Print(("   %s eligible, delta=%s (Item %s vs equipped %s%s)"):format(
                    key, tostring(r.delta), tostring(r.candidateValue),
                    tostring(r.equippedValue),
                    r.modeNote and (", " .. r.modeNote) or ""))
            else
                local tag = r.verdict == "eventually" and "  [eventually]"
                    or (r.verdict == "respec" and "  [if they respec]" or "")
                addon.Print(("   %s: %s%s"):format(key, r.reason or "?", tag))
            end
        end
    end
    for _, m in ipairs(matches) do
        local r = m.result
        addon.Print(("   %s #%d %s  delta=%s  mode=%s%s"):format(
            m.key, r.slotID or 0, addon.SLOT_NAMES[r.slotID] or "?",
            tostring(r.delta), r.mode,
            r.modeNote and (" (" .. r.modeNote .. ")") or ""))
    end
end

-- Shared item-argument parsing for the debug stats/score commands: accepts a
-- shift-click link, a raw item string, or a bare numeric ID.
local function ResolveItemArg(arg, label)
    if not arg or arg == "" then
        addon.Print(("usage: /gear debug %s <item link or ID>  (shift-click works)")
            :format(label))
        return nil
    end
    local link = arg:match("item:[%w:%-%+%.]+")
    if not link then
        local id = tonumber(arg)
        if not id then
            addon.Print(("usage: /gear debug %s <item link or ID>  (shift-click works)")
                :format(label))
            return nil
        end
        if C_Item and C_Item.LinkForItemID then
            link = C_Item.LinkForItemID(id)
        end
        link = link or ("item:%d:0:0:0:0:0:0:0::::0"):format(id)
    end
    return link
end

-------------------------------------------------------------------------------
-- Command surface: user-facing top level, diagnostics under /gear debug
-------------------------------------------------------------------------------

local function ShowUserHelp()
    addon.Print("GearFall commands:")
    addon.Print("  /gear - toggle the dashboard")
    addon.Print("  /gear mail - toggle the distribution window")
    addon.Print("  /gear update - manually update this character's gear into the roster")
    addon.Print("  /gear itemspecs [class or item] - browse the trinket role library (or dump one item)")
    addon.Print("  /gear itemspecs conflicts - list role data conflicts")
    addon.Print("  /gear itemspecs wipe - clear the role library (asks to confirm)")
    addon.Print("  /gear wipe - reset everything (asks to confirm)")
    addon.Print("  /gear debug help - diagnostics and debug output")
end

local function ShowDebugHelp()
    local db = GearFallDB
    local on = db and db.settings and db.settings.debug
    addon.Print(("GearFall debug commands (ambient prints currently %s):")
        :format(on and "ON" or "off"))
    addon.Print("  /gear debug - toggle ambient debug prints")
    addon.Print("  /gear debug scan bags | bag | inventory - inspect bag contents & sendability")
    addon.Print("  /gear debug scan mail - inspect inbox attachments & sendability")
    addon.Print("  /gear debug scan equipment | equipped | gear - inspect worn gear (view only, does not save)")
    addon.Print("  /gear debug stats [link|ID] - full stat breakdown of an item")
    addon.Print("  /gear debug score [link|ID] - score an item against the roster")
    addon.Print("  /gear debug dump [alt] - dump the roster database for one alt")
    addon.Print("  /gear debug specs - spec-ID calibration dump")
end

local function ConfirmAction(text, onConfirm)
    if StaticPopupDialogs and StaticPopup_Show then
        StaticPopupDialogs["GEARFALL_CONFIRM"] = {
            text = text,
            button1 = "Yes",
            button2 = "No",
            OnAccept = function()
                onConfirm()
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        StaticPopup_Show("GEARFALL_CONFIRM")
    else
        -- test environments without the popup system run immediately
        onConfirm()
    end
end

local function DebugScanBags()
    local ok, err = pcall(function()
        local results = addon.ScanEligibleItems()
        local gearCount, eligibleCount = 0, 0
        for _, info in ipairs(results) do
            if not info.cached then
                addon.Print(("%s: item not cached"):format(tostring(info.spot)))
            elseif info.isGear then
                gearCount = gearCount + 1
                addon.Print(("%s %s x%s"):format(
                    tostring(info.spot), addon.FormatItem(info),
                    tostring(info.quantity or 1)))
                addon.Print(("  bind=%s bound=%s warband=%s eligible=%s slot=%s cls=%s/%s req=%s stats=%s"):format(
                    tostring(info.itemBind), tostring(info.isBound), tostring(info.warband),
                    tostring(info.eligible), tostring(info.invType),
                    tostring(info.class), tostring(info.subclass),
                    tostring(info.minLevel),
                    addon.FormatStatSet(addon.GetItemMainStats(
                        info.itemLink, info.bagID, info.slotIndex))))
                if info.invType == "INVTYPE_TRINKET" then
                    addon.Print(("  specinfo: %s"):format(
                        addon.DescribeItemSpecInfo(info.itemLink,
                            addon.GetItemID(info.itemLink))))
                end
                if info.eligible then
                    eligibleCount = eligibleCount + 1
                end
            end
        end
        addon.Print(("scan: %d item(s), %d gear, %d eligible")
            :format(#results, gearCount, eligibleCount))
    end)
    if not ok then
        addon.Print("scan FAILED: " .. tostring(err))
    end
end

-- Standalone inbox scan with no _mailboxOpen gate: the force-check affordance
-- for calibrating the mail API without opening a mailbox first.
local function DebugScanMail()
    local ok, err = pcall(function()
        if not (GetInboxNumItems and GetInboxItem and GetInboxItemLink) then
            addon.Print("mail scan: inbox API unavailable in this client")
            return
        end
        local results = addon.ScanMailForEligibleItems()
        local gearCount, eligibleCount = 0, 0
        for _, info in ipairs(results) do
            if not info.cached then
                addon.Print(("%s: item not cached"):format(tostring(info.spot)))
            elseif info.isGear then
                gearCount = gearCount + 1
                addon.Print(("%s %s x%s"):format(
                    tostring(info.spot), addon.FormatItem(info),
                    tostring(info.quantity or 1)))
                addon.Print(("  bind=%s bound=%s warband=%s eligible=%s slot=%s cls=%s/%s req=%s stats=%s"):format(
                    tostring(info.itemBind), tostring(info.isBound),
                    tostring(info.warband), tostring(info.eligible),
                    tostring(info.invType), tostring(info.class),
                    tostring(info.subclass), tostring(info.minLevel),
                    addon.FormatStatSet(addon.GetItemMainStats(
                        info.itemLink, nil, nil,
                        info.mailIndex, info.attachIndex))))
                if info.invType == "INVTYPE_TRINKET" then
                    addon.Print(("  specinfo: %s"):format(
                        addon.DescribeItemSpecInfo(info.itemLink,
                            addon.GetItemID(info.itemLink))))
                end
                if info.eligible then
                    eligibleCount = eligibleCount + 1
                end
            end
        end
        addon.Print(("mail scan: %d attachment(s), %d gear, %d eligible")
            :format(#results, gearCount, eligibleCount))
    end)
    if not ok then
        addon.Print("mail scan FAILED: " .. tostring(err))
    end
end

local function DebugScanEquipment()
    local idFn = (C_Item and C_Item.GetInventoryItemID) or GetInventoryItemID
    addon.Print(("equipment scan (view only): viewed as %s"):format(tostring(
        select(2, UnitClass("player")) or "?")))
    for slot = 1, 23 do
        local id = idFn and idFn("player", slot)
        local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
        if id or link then
            local invType = (link or id) and C_Item
                and C_Item.GetItemInfoInstant and select(4, C_Item.GetItemInfoInstant(link or id))
            addon.Print(("[%02d] id=%s ilvl=%s invType=%s link=%s"):format(
                slot, tostring(id or "-"), tostring(addon.GetItemLevel(link or id)),
                tostring(invType or "-"), link and "yes" or "NO"))
            if invType == "INVTYPE_TRINKET" then
                addon.Print(("  specinfo: %s"):format(
                    addon.DescribeItemSpecInfo(link, id)))
            end
        end
    end
end

local function DebugSpecs()
    if not GetSpecializationInfoForSpecID then
        addon.Print("GetSpecializationInfoForSpecID missing")
        return
    end
    local rows = 0
    local dumped = false
    local specGroups = {
        { class = "DEATHKNIGHT", specs = { 250, 251, 252 } },
        { class = "DEMONHUNTER", specs = { 577, 581, 1480 } },
        { class = "DRUID", specs = { 102, 103, 104, 105 } },
        { class = "EVOKER", specs = { 1467, 1468, 1473 } },
        { class = "HUNTER", specs = { 253, 254, 255 } },
        { class = "MAGE", specs = { 62, 63, 64 } },
        { class = "MONK", specs = { 268, 270, 269 } },
        { class = "PALADIN", specs = { 65, 66, 70 } },
        { class = "PRIEST", specs = { 256, 257, 258 } },
        { class = "ROGUE", specs = { 259, 260, 261 } },
        { class = "SHAMAN", specs = { 262, 263, 264 } },
        { class = "WARLOCK", specs = { 265, 266, 267 } },
        { class = "WARRIOR", specs = { 71, 72, 73 } },
    }
    for _, group in ipairs(specGroups) do
        for _, specID in ipairs(group.specs) do
            local results = { pcall(GetSpecializationInfoForSpecID, specID) }
            local ok = table.remove(results, 1)
            local info = ok and type(results[1]) == "table" and results[1] or results
            if ok and type(info) == "table" and info[1] then
                rows = rows + 1
                if not dumped then
                    dumped = true
                    addon.Print("raw table of first spec: " .. Serialize(info))
                end
                local desc = type(info[3]) == "string"
                    and info[3]:gsub("[\r\n]+", " ") or ""
                local weapons = desc:match("Preferred Weapons?%s*:%s*(.+)")
                if weapons then
                    weapons = weapons:gsub("^%s+", ""):gsub("%s+$", "")
                else
                    weapons = "NOT FOUND: " .. desc
                end
                addon.Print(("class=%s specID=%s role=%s weapons=%s spec=%s"):format(
                    group.class, tostring(info[1] or "?"),
                    tostring(info[5] or "?"), weapons,
                    tostring(info[2] or "?")))
            else
                addon.Print(("class=%s specID=%d -> no data (%s)"):format(group.class,
                    specID, (not ok) and tostring(results[1]) or "nil"))
            end
        end
    end
    addon.Print(("specs reported: %d/%d"):format(rows, 40))
end

local function DebugStats(arg)
    local link
    if arg and arg ~= "" then
        link = ResolveItemArg(arg, "stats")
        if not link then
            return
        end
    else
        link = addon.NormalizeItemLink(GetInventoryItemLink and GetInventoryItemLink("player", 16))
        if link then
            addon.Print("no item given, probing equipped mainhand")
        end
    end
    if not link then
        addon.Print("usage: /gear debug stats [item link or ID]  (shift-click works)")
        return
    end
    local ok, err = pcall(addon.ProbeItemStats, link)
    if not ok then
        addon.Print("stats probe FAILED: " .. tostring(err))
    end
end

local function DebugScore(arg)
    if arg and arg ~= "" then
        local link = ResolveItemArg(arg, "score")
        if not link then
            return
        end
        local info = addon.GetBindInfo(link)
        if not info.cached then
            addon.Print("item not in the local tooltip cache yet - hover it once, then retry")
            return
        end
        info.itemLink = info.itemLink or link
        local ok, err = pcall(ReportItemScore, info, 1)
        if not ok then
            addon.Print("score FAILED: " .. tostring(err))
        end
        return
    end
    -- bare: score every eligible bag item against the roster
    local ok, err = pcall(function()
        local results = addon.ScanEligibleItems()
        local scored = 0
        for _, info in ipairs(results) do
            if info.eligible then
                scored = scored + 1
                ReportItemScore(info, scored)
            end
        end
        addon.Print(("score: %d eligible item(s) checked against %d alt(s)")
            :format(scored, addon.CountTable(GearFallDB.alts)))
    end)
    if not ok then
        addon.Print("score FAILED: " .. tostring(err))
    end
end

local function CmdUpdate()
    local ok, err = pcall(addon.CaptureSnapshot, "manual")
    if ok then
        addon.Print("captured: " .. tostring(addon.PlayerKey()))
    else
        addon.Print("update FAILED: " .. tostring(err))
    end
end

local function CmdWipe()
    ConfirmAction("Wipe ALL GearFall data? This deletes every captured alt "
        .. "and the item role library.", function()
        local db = GearFallDB
        if not db then
            addon.Print("database not loaded yet")
            return
        end
        local keys = {}
        for key in pairs(db.alts) do
            keys[#keys + 1] = key
        end
        for _, key in ipairs(keys) do
            db.alts[key] = nil
        end
        addon.Print(("roster wiped (%d alts removed)"):format(#keys))
        db.itemRoles = nil
        addon.Print("item role database cleared")
    end)
end

local function CmdWipeRoleData()
    local db = GearFallDB
    if not db then
        addon.Print("database not loaded yet")
        return
    end
    local count = 0
    for _ in pairs(db.itemRoles or {}) do
        count = count + 1
    end
    db.itemRoles = nil
    addon.Print(("item role database cleared (%d item(s) forgotten; "
        .. "roster untouched)"):format(count))
end

local function ShowRoleConflicts()
    local store = GearFallDB and GearFallDB.itemRoles
    local count = 0
    for itemID, entry in pairs(store or {}) do
        for classToken in pairs(entry.conflicts or {}) do
            count = count + 1
            local specs = {}
            local classEntry = entry.classes and entry.classes[classToken]
            if classEntry then
                for _, specID in ipairs(classEntry.specs) do
                    specs[#specs + 1] = tostring(specID)
                end
            end
            addon.Print(("conflict: %s class %s (specs: %s, first seen %s)")
                :format(addon.ItemRolesEntryLink(entry, itemID), classToken,
                    table.concat(specs, ",") or "-",
                    date("%Y-%m-%d", entry.conflicts[classToken])))
        end
        local hyp = entry.roleInference
        for role in pairs(hyp and hyp.conflicts or {}) do
            count = count + 1
            addon.Print(("conflict: %s role %s (inferred across classes)")
                :format(addon.ItemRolesEntryLink(entry, itemID), role))
        end
    end
    addon.Print(("item role conflicts: %d"):format(count))
end

---@param argText string?
local function CmdItemspecs(argText)
    local trimmed = argText and argText:match("^%s*(.-)%s*$") or ""
    -- an item argument (shift-click link or numeric ID) dumps that one
    -- trinket's role data; anything else is a class report
    if trimmed ~= "" and (trimmed:match("^%d+$") or trimmed:match("item:")
        or trimmed:match("|Hitem:")) then
        local lines = addon.ItemRolesItemDetail(argText)
        for _, line in ipairs(lines or {}) do
            addon.Print(line)
        end
        return
    end
    if trimmed:lower() == "conflicts" then
        ShowRoleConflicts()
        return
    end
    if trimmed:lower() == "wipe" then
        ConfirmAction("Clear the item role library? The roster is untouched.",
            CmdWipeRoleData)
        return
    end
    local lines, badInput = addon.ItemRolesReport(trimmed ~= "" and trimmed or nil)
    if not lines then
        addon.Print(("unknown class '%s' - try e.g. PALADIN, Mage or "
            .. "'Death Knight'"):format(badInput or "?"))
        return
    end
    for _, line in ipairs(lines) do
        addon.Print(line)
    end
end

---@param argText string?
local function CmdDebug(argText)
    local sub, rest
    if argText and argText ~= "" then
        sub, rest = argText:match("^(%S+)%s*(.-)%s*$")
        if sub == "" then
            sub = nil
        end
        if rest == "" then
            rest = nil
        end
    end
    if not sub then
        local db = GearFallDB
        if not db then
            addon.Print("database not loaded yet")
            return
        end
        db.settings.debug = not db.settings.debug
        addon.Print(("ambient debug prints %s"):format(
            db.settings.debug and "ENABLED" or "disabled"))
        return
    end
    sub = sub:lower()
    if sub == "help" then
        ShowDebugHelp()
        return
    end
    if sub == "scan" then
        local target = (rest or ""):lower()
        if target == "bags" or target == "bag" or target == "inventory" then
            DebugScanBags()
            return
        end
        if target == "equipment" or target == "equipped" or target == "gear" then
            DebugScanEquipment()
            return
        end
        if target == "mail" or target == "inbox" then
            DebugScanMail()
            return
        end
        addon.Print("usage: /gear debug scan bags | bag | inventory | equipment | equipped | gear | mail")
        return
    end
    if sub == "dump" then
        addon.Dump(rest)
        return
    end
    if sub == "specs" then
        DebugSpecs()
        return
    end
    if sub == "stats" then
        DebugStats(rest)
        return
    end
    if sub == "score" then
        DebugScore(rest)
        return
    end
    ShowDebugHelp()
end

function SlashCmdList.GEARFALL(msg)
    local raw = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmdWord, argText = raw:match("^(%S+)%s+(.-)%s*$")
    if not cmdWord then
        cmdWord, argText = raw, nil
    end
    local cmd = (cmdWord or ""):lower()
    if cmd == "" or cmd == "dashboard" then
        addon.ToggleDashboard()
    elseif cmd == "mail" then
        if addon.ToggleDistribution then
            addon.ToggleDistribution()
        else
            addon.Print("Distribution not loaded")
        end
    elseif cmd == "update" then
        CmdUpdate()
    elseif cmd == "itemspecs" then
        CmdItemspecs(argText)
    elseif cmd == "wipe" then
        CmdWipe()
    elseif cmd == "debug" then
        CmdDebug(argText)
    elseif cmd == "help" then
        ShowUserHelp()
    else
        ShowUserHelp()
    end
end

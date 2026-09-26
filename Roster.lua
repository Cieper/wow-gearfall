local _, addon = ...

local recaptureQueued = false
local recaptureReason

-- new characters join as their own bottom priority tier
local function NextTier()
    local maxTier = 0
    for _, alt in pairs(GearFallDB.alts) do
        if not alt.excluded and alt.prioTier and alt.prioTier > maxTier then
            maxTier = alt.prioTier
        end
    end
    return maxTier + 1
end

function addon.GetOrCreateAlt(key)
    local db = GearFallDB
    local alt = db.alts[key]
    if not alt then
        alt = {
            tags = {},
            scoringMode = "ITEMLEVEL",
            excluded = false,
            prioTier = NextTier(),
            lastLogin = 0,
        }
        db.alts[key] = alt
    end
    return alt
end

function addon.GetAltSlotIssues(alt)
    local issues = {}
    local slots = alt.slots or {}
    for _, slot in ipairs(addon.EQUIP_SLOTS) do
        local snap = slots[slot]
        if snap then
            local label = addon.SLOT_NAMES[slot] or tostring(slot)
            if not snap.itemLevel or snap.itemLevel == 0 then
                issues[#issues + 1] = ("%s: no item level logged"):format(label)
            elseif not snap.name then
                issues[#issues + 1] = ("%s: item name not cached"):format(label)
            end
        end
    end
    return issues
end

local RETRY_DELAYS = { 5, 15, 45 }
local lastCompleteAt = 0
-- key -> fingerprint of the last COMPLETE capture; identical fingerprint
-- means gear/spec/level are unchanged and the whole scan is a no-op
local lastFingerprint = {}

function addon.CaptureSnapshot(reason, attempt)
    local key = addon.PlayerKey()
    if not key then
        return
    end
    local alt = addon.GetOrCreateAlt(key)

    local _, classToken, classID = UnitClass("player")
    alt.class = classToken or alt.class
    alt.classID = classID or alt.classID
    alt.level = UnitLevel("player") or alt.level
    local specID, specName, role = addon.GetActiveSpecInfo()
    alt.activeSpecID = specID or alt.activeSpecID
    alt.specName = specName or alt.specName
    alt.role = role or alt.role
    local liveAvg = addon.GetAvgItemLevel()

    local slots = {}
    local uncached = false
    local slotCount, ilvlSum, ilvlCount = 0, 0, 0
    local fp = ("%s:%s:%s|"):format(
        tostring(alt.level), tostring(alt.activeSpecID), tostring(alt.role))
    local previous = alt.slots or {}
    local idFn = (C_Item and C_Item.GetInventoryItemID) or GetInventoryItemID
    if not idFn then
        addon.DebugPrint("debug: no GetInventoryItemID API available, cannot scan equipment")
    else
        for _, slot in ipairs(addon.EQUIP_SLOTS) do
            -- GetInventoryItemID is the only reliable "is something equipped
            -- here" test: links can read nil while the tooltip cache is cold
            local id = idFn("player", slot)
            local raw = GetInventoryItemLink
                and addon.NormalizeItemLink(GetInventoryItemLink("player", slot))
            if (not id or id <= 0) and raw then
                id = addon.GetItemID(raw)
                if id and id > 0 then
                    addon.DebugPrint(("debug: slot [%02d %s] reported no item id, recovered %d from link"):format(
                        slot, addon.SLOT_NAMES[slot] or "?", id))
                end
            end
            if id and id > 0 then
                local old = previous[slot]
                local sameOld = (old and old.itemID == id) and old or nil
                local itemName, _, itemQuality = C_Item.GetItemInfo(raw or id)
                local itemLevel = (raw and addon.GetItemLevel(raw))
                    or (sameOld and sameOld.itemLevel)
                local invType = select(4, C_Item.GetItemInfoInstant(raw or id))
                    or (sameOld and sameOld.invType)
                if not itemName or not itemLevel or not invType then
                    uncached = true
                    addon.DebugPrint(("debug: unexpected data [%02d %s] id=%s ilvl=%s invType=%s name=%s"):format(
                        slot, addon.SLOT_NAMES[slot] or "?",
                        tostring(id), tostring(itemLevel),
                        tostring(invType), tostring(itemName)))
                    if C_Item.RequestLoadItemDataByID then
                        C_Item.RequestLoadItemDataByID(id)
                    end
                end
                -- never degrade: fill gaps from a previous snapshot of the
                -- same itemID
                slots[slot] = {
                    itemID = id,
                    itemLink = raw or (sameOld and sameOld.itemLink),
                    itemLevel = itemLevel or (sameOld and sameOld.itemLevel),
                    invType = invType,
                    name = itemName or (sameOld and sameOld.name),
                    quality = itemQuality or (sameOld and sameOld.quality),
                }
                slotCount = slotCount + 1
                local finalLevel = slots[slot].itemLevel
                if finalLevel and finalLevel > 0 then
                    ilvlSum = ilvlSum + finalLevel
                    ilvlCount = ilvlCount + 1
                end
                fp = ("%s%d:%d:%s;"):format(fp, slot, id,
                    tostring(finalLevel or -1))
            elseif raw then
                uncached = true
                addon.DebugPrint(("debug: slot [%02d %s] has a link but no item id resolved"):format(
                    slot, addon.SLOT_NAMES[slot] or "?"))
            end
        end
    end
    if not uncached and slotCount > 0 and lastFingerprint[key] == fp then
        addon.DebugPrint(("debug: capture skipped [%s] (%s): gear unchanged")
            :format(key, reason or "manual"))
        return
    end
    addon.DebugPrint(("debug: gear capture start [%s] (%s)"):format(
        key, reason or "manual"))

    if slotCount == 0 and alt.slots and next(alt.slots) then
        addon.DebugPrint(("debug: empty capture result, keeping previous %d slot(s)")
            :format(addon.CountTable(alt.slots)))
    else
        alt.slots = slots
    end
    -- mailed items we projected into slots are only proven once the alt is
    -- actually played: drop the projection when the capture shows the same
    -- item (or something of at least its item level) now equipped there
    if alt.incoming then
        for slot, inc in pairs(alt.incoming) do
            local worn = alt.slots and alt.slots[slot]
            if worn and ((worn.itemLink and inc.itemLink
                    and worn.itemLink == inc.itemLink)
                or (worn.itemLevel and inc.itemLevel
                    and worn.itemLevel >= inc.itemLevel)) then
                alt.incoming[slot] = nil
                addon.DebugPrint(("debug: incoming [%s] confirmed equipped in %s")
                    :format(inc.name or "?", addon.SLOT_NAMES[slot] or "?"))
            end
        end
        if not next(alt.incoming) then
            alt.incoming = nil
        end
    end
    local avgSource
    if liveAvg then
        alt.avgItemLevel = liveAvg
        avgSource = "inspect"
    elseif ilvlCount > 0 then
        alt.avgItemLevel = ilvlSum / ilvlCount
        avgSource = "slots"
    else
        avgSource = "cached"
    end
    addon.DebugPrint(("debug: gear capture done [%s]: %d slot(s), avg slot ilvl %s, reported avg %s [%s]%s"):format(
        key, slotCount,
        ilvlCount > 0 and ("%.1f"):format(ilvlSum / ilvlCount) or "n/a",
        tostring(alt.avgItemLevel or "?"), avgSource,
        uncached and " (INCOMPLETE)" or ""))

    -- the equipment/tooltip caches may still be warming up (especially right
    -- after login); retry with backoff until the capture is complete
    if uncached or slotCount == 0 then
        lastFingerprint[key] = nil
        attempt = attempt or 0
        if attempt < #RETRY_DELAYS then
            local delay = RETRY_DELAYS[attempt + 1]
            addon.DebugPrint(("debug: incomplete capture, auto-recapture in %ds (retry %d/%d)")
                :format(delay, attempt + 1, #RETRY_DELAYS))
            C_Timer.After(delay, function()
                if GetTime() - lastCompleteAt < delay then
                    addon.DebugPrint("debug: auto-recapture skipped, a newer complete capture exists")
                    return
                end
                addon.CaptureSnapshot("retry", attempt + 1)
            end)
        else
            addon.DebugPrint("debug: capture still incomplete after retries, giving up")
        end
    else
        lastCompleteAt = GetTime()
        lastFingerprint[key] = fp
    end

    if addon.RefreshPriorityList then
        addon.RefreshPriorityList()
    end
end

local DEBOUNCED_EVENTS = {
    PLAYER_EQUIPMENT_CHANGED = true,
    PLAYER_LEVEL_UP = true,
    PLAYER_SPECIALIZATION_CHANGED = true,
    ACTIVE_TALENT_GROUP_CHANGED = true,
    -- deliberately no role events here: PLAYER_ROLES_ASSIGNED and
    -- ROLE_CHANGED_INFORM also fire for every GROUP MEMBER (a group join
    -- spams them), and role is derived from spec, which has its own events
}

local events = CreateFrame("Frame", nil, UIParent)
events:RegisterEvent("PLAYER_LOGIN")
for event in pairs(DEBOUNCED_EVENTS) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(self, event, ...)
    -- payload probe: log every argument the client hands us
    local arg1 = select(1, ...)
    local n = select("#", ...)
    if n > 0 then
        local parts = {}
        for i = 1, n do
            parts[i] = tostring(select(i, ...))
        end
        addon.DebugPrint(("debug: event %s payload: %s"):format(event, table.concat(parts, " | ")))
    else
        addon.DebugPrint(("debug: event %s (no payload)"):format(event))
    end

    if event == "PLAYER_LOGIN" then
        addon.Print(("login: %d alt(s) in saved data before capture"):format(addon.CountTable(GearFallDB.alts)))
        local key = addon.PlayerKey()
        if key then
            addon.GetOrCreateAlt(key).lastLogin = GetServerTime()
        end
    end
    if DEBOUNCED_EVENTS[event] or event == "PLAYER_LOGIN" then
        -- PLAYER_SPECIALIZATION_CHANGED carries the UNIT whose spec changed:
        -- "player" on a genuine switch, "raid6"/"partyN" when the client
        -- syncs a member's spec on group join/leave (measured in-game)
        if event == "PLAYER_SPECIALIZATION_CHANGED" and arg1 ~= "player" then
            return
        end
        if not recaptureQueued then
            recaptureQueued = true
            -- keep the event name as the capture reason: debug lines then
            -- show WHICH trigger fired (group-join noise etc.)
            recaptureReason = event
            C_Timer.After(1, function()
                recaptureQueued = false
                addon.CaptureSnapshot(recaptureReason)
            end)
        end
    end
end)

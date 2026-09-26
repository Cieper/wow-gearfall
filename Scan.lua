local addonName, addon = ...

-- Shared C_Item metadata for one link: the base info shape filled by
-- GetItemInfo (with GetItemInfoInstant fallbacks). cached=false when the
-- item is not in the local cache yet - callers decide how to treat that.
-- GetItemInfoInstant returns: itemID, itemType, itemSubType, itemEquipLoc,
-- icon, classID, subClassID (NOT the legacy global order).
function addon.GetItemLinkInfo(link)
    local _, instantType, instantSubType, itemEquipLoc, iconID, classIDInstant,
        subClassIDInstant = C_Item.GetItemInfoInstant(link)
    local isGear = (classIDInstant == 2 or classIDInstant == 4)
        and (itemEquipLoc ~= "")

    local name, cachedLink, quality, itemLevel, minLevel, itemType, itemSubType,
        stackCount, equipLoc, _, _, classID, subclassID, bindType =
        C_Item.GetItemInfo(link)
    if not name then
        return { cached = false, isGear = isGear, eligible = false,
            icon = iconID }
    end

    return {
        cached = true,
        name = name,
        quality = quality,
        itemLevel = itemLevel,
        minLevel = minLevel,
        itemType = itemType or instantType,
        itemSubType = itemSubType or instantSubType,
        class = classID or classIDInstant,
        subclass = subclassID or subClassIDInstant,
        invType = equipLoc,
        itemBind = bindType,
        icon = iconID,
        isGear = isGear,
        itemLink = addon.NormalizeItemLink(cachedLink or link),
    }
end

function addon.GetBindInfo(link, bagID, slotIndex)
    local info = addon.GetItemLinkInfo(link)
    if not info.cached then
        info.eligible = false
        return info
    end

    local isBound, warband
    if bagID and slotIndex then
        local itemLoc = ItemLocation:CreateFromBagAndSlot(bagID, slotIndex)
        isBound = C_Item.IsBound(itemLoc) and true or false
        warband = C_Item.IsBoundToAccountUntilEquip(itemLoc) and true or false
    else
        isBound = false
        warband = C_Item.IsItemBindToAccountUntilEquip and
            C_Item.IsItemBindToAccountUntilEquip(link) or false
    end

    -- Eligibility gate: C_Item.IsBound on the in-bag instance. Calibrated
    -- in-game: it is false for everything still sendable (BoE, unbound,
    -- Warband-flagged) and true only for soulbound copies - including
    -- already-soulbound BoE items, whose tooltip/bindType alone look sendable.
    info.isBound = isBound
    info.warband = warband
    info.eligible = info.isGear and (not isBound)

    -- FR-8 role learning (ItemRoles.lua): per-class byID truth + wide
    -- (byLink) foreign positives, one debug line per trinket sighting
    if info.invType == "INVTYPE_TRINKET" and addon.ItemRolesCapture then
        addon.ItemRolesCapture(info.itemLink, info.name, bagID, slotIndex)
    end

    return info
end

-- Every scanned item carries a `spot`: a namespaced location string that
-- doubles as the rowKey everywhere downstream (skip state, verdict maps).
-- Bag items and mail attachments can never collide.
function addon.ScanBagsForEligibleItems()
    local results = {}
    for bagID = 0, NUM_BAG_SLOTS do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slotIndex = 1, numSlots do
            local containerItem = C_Container.GetContainerItemInfo(bagID, slotIndex)
            if containerItem and containerItem.hyperlink then
                local info = addon.GetBindInfo(containerItem.hyperlink, bagID, slotIndex)
                info.location = "bag"
                info.bagID = bagID
                info.slotIndex = slotIndex
                -- bag spots keep the historical rowKey format; mail spots
                -- are namespaced by their "mail:" prefix
                info.spot = ("%d:%d"):format(bagID, slotIndex)
                info.quantity = containerItem.stackCount
                results[#results + 1] = info
            end
        end
    end
    return results
end

-- The character's inbox as a second inventory, scanned while a mailbox is
-- open. Every attachment is movable by construction - a soulbound item
-- cannot sit in a mailbox - so there is no bind gate here and no
-- ItemLocation (mail attachments cannot be picked up for mailing either;
-- they are scan-only candidates that would have to be claimed manually).
function addon.ScanMailForEligibleItems()
    local results = {}
    if not (GetInboxNumItems and GetInboxItem and GetInboxItemLink) then
        return results
    end
    for mailIndex = 1, GetInboxNumItems() do
        for attachIndex = 1, (ATTACHMENTS_MAX_SEND or 12) do
            -- Calibrated on client 120100: GetInboxItem does NOT return the
            -- item link (position 3 is the texture fileID), so the link comes
            -- from GetInboxItemLink; GetInboxItem only fills the stack count.
            -- Empty slots fail the link guard and stay silent. A claimed or
            -- mid-take attachment still reports its link for a moment after
            -- TakeInboxItem: HasInboxItem is the takeable gate, and without
            -- it the loot run's end-of-run refresh re-detects the just-
            -- claimed attachment and keeps its envelope alive until the
            -- server's inbox update lands.
            local count = select(4, GetInboxItem(mailIndex, attachIndex))
            local link = GetInboxItemLink(mailIndex, attachIndex)
            if type(link) == "string"
                and (link:match("^item:") or link:match("|Hitem:"))
                and (not HasInboxItem
                    or HasInboxItem(mailIndex, attachIndex)) then
                local info = addon.GetItemLinkInfo(link)
                info.location = "mail"
                info.mailIndex = mailIndex
                info.attachIndex = attachIndex
                info.spot = ("mail:%d:%d"):format(mailIndex, attachIndex)
                info.quantity = count or 1
                if info.cached then
                    info.eligible = info.isGear
                    if info.invType == "INVTYPE_TRINKET"
                        and addon.ItemRolesCapture then
                        addon.ItemRolesCapture(info.itemLink, info.name,
                            nil, nil)
                    end
                end
                results[#results + 1] = info
            end
        end
    end
    return results
end

-- Everything that could be distributed right now: bag items always, plus
-- the inbox while a mailbox is open (the Distribution window's own gate).
function addon.ScanEligibleItems()
    local results = addon.ScanBagsForEligibleItems()
    if addon._mailboxOpen then
        for _, info in ipairs(addon.ScanMailForEligibleItems()) do
            results[#results + 1] = info
        end
    end
    return results
end

local addonName, addon = ...

-- Shared C_Item metadata for one link: the base info shape filled by
-- GetItemInfo (with GetItemInfoInstant fallbacks). cached=false when the
-- item is not in the local cache yet - callers decide how to treat that.
-- GetItemInfoInstant returns: itemID, itemType, itemSubType, itemEquipLoc,
-- icon, classID, subClassID (NOT the legacy global order).

-- Unique-Equipped detection, calibrated in-game on 120100: for a plain
-- "Unique-Equipped" item C_Item.GetItemUniquenessByID returns isUnique=true
-- with NO category fields (name/count/id all nil) - the -1 pseudo-category
-- (ITEM_UNIQUE_EQUIPPED, Blizzard_FrameXMLBase Constants.lua) never shows up
-- there. A NAMED equip-limit category ("Unique-Equipped: X (2)") carries a
-- positive id and the category's cap; several copies are wearable unless
-- that cap itself is 1. Plain "Unique" (hold limit) returns the same
-- category-less shape, but a hold-limited item can never have two copies in
-- one character's bags, so flagging it has no observable effect on the
-- distribution.
local ITEM_UNIQUE_EQUIPPED = ITEM_UNIQUE_EQUIPPED or -1

local function IsUniqueEquipped(link)
    if not (C_Item and C_Item.GetItemUniquenessByID) then
        return false
    end
    local ok, isUnique, _, catCount, catID =
        pcall(C_Item.GetItemUniquenessByID, link)
    if not (ok and isUnique == true) then
        return false
    end
    if catID == nil or catID == ITEM_UNIQUE_EQUIPPED then
        return true
    end
    return catCount == 1
end

-- diagnostics export (Core /gear debug stats): the raw flag check beside
-- the API's own answer, for in-game calibration
addon.IsUniqueEquipped = IsUniqueEquipped

function addon.GetItemLinkInfo(link)
    local instantID, instantType, instantSubType, itemEquipLoc, iconID,
        classIDInstant, subClassIDInstant = C_Item.GetItemInfoInstant(link)
    local isGear = (classIDInstant == 2 or classIDInstant == 4)
        and (itemEquipLoc ~= "")

    local name, cachedLink, quality, itemLevel, minLevel, itemType, itemSubType,
        stackCount, equipLoc, _, _, classID, subclassID, bindType =
        C_Item.GetItemInfo(link)
    if not name then
        return { cached = false, isGear = isGear, eligible = false,
            icon = iconID, itemID = instantID }
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
        itemID = instantID,
        uniqueEquipped = IsUniqueEquipped(link),
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
-- Bag, mail, and bank spots can never collide.
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
                -- FR-9 per-instance identity: the client mints a GUID per
                -- item instance (stable across relog/mail/trade; changes
                -- only when the item crosses realms). Mail attachments have
                -- no ItemLocation, so "just this copy" ignores are a
                -- bag/bank concept by construction.
                info.guid = C_Item.GetItemGUID(
                    ItemLocation:CreateFromBagAndSlot(bagID, slotIndex))
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

-- The bank as a third inventory, scanned while the bank frame is open
-- (addon._bankOpen, the Distribution window's own gate). Bank tabs are
-- plain container IDs: Blizzard's own BankPanel reads them with
-- C_Container.GetContainerNumSlots / GetContainerItemInfo, so the per-slot
-- walk is the bag walk over different container IDs. Tab handles come from
-- C_Bank.FetchPurchasedBankTabData (only purchased tabs exist) and are
-- gated on C_Bank.CanViewBank - the same visibility guard Blizzard's tab
-- system uses. Character bank and Warbank (Enum.BankType.Account) are both
-- scanned; their spots are namespaced separately ("bank:tab:slot" vs
-- "wbank:tab:slot", tabIndex = position in the purchased-tab list, not the
-- client's container ID) so the shared Warbank contents can be told apart
-- from this realm's private bank downstream. The bind gate is the bag gate
-- on purpose: a bank can store soulbound items, and only movable copies
-- are distribution candidates.
local BANK_SCANS = {
    { name = "character", prefix = "bank",
        enum = function()
            return Enum and Enum.BankType and Enum.BankType.Character
        end },
    { name = "account", prefix = "wbank",
        enum = function()
            return Enum and Enum.BankType and Enum.BankType.Account
        end },
}

function addon.ScanBankForEligibleItems()
    local results = {}
    if not (C_Bank and C_Bank.FetchPurchasedBankTabData
            and C_Bank.CanViewBank and C_Container
            and C_Container.GetContainerNumSlots
            and C_Container.GetContainerItemInfo) then
        return results
    end
    for _, scan in ipairs(BANK_SCANS) do
        local bankType = scan.enum()
        if bankType and C_Bank.CanViewBank(bankType) then
            local tabs = C_Bank.FetchPurchasedBankTabData(bankType)
            for tabIndex, tabData in ipairs(tabs or {}) do
                local tabID = tabData and tabData.ID
                local numSlots = tabID
                    and C_Container.GetContainerNumSlots(tabID) or 0
                for slotIndex = 1, numSlots do
                    local containerItem =
                        C_Container.GetContainerItemInfo(tabID, slotIndex)
                    if containerItem and containerItem.hyperlink then
                        local info = addon.GetBindInfo(containerItem.hyperlink,
                            tabID, slotIndex)
                        info.location = "bank"
                        info.bankType = scan.name
                        info.tabID = tabID
                        info.slotIndex = slotIndex
                        info.spot = ("%s:%d:%d"):format(scan.prefix,
                            tabIndex, slotIndex)
                        info.quantity = containerItem.stackCount
                        -- FR-9 per-instance identity works for bank slots
                        -- the same way it does for bags: bank coordinates
                        -- are real ItemLocations
                        info.guid = C_Item.GetItemGUID(
                            ItemLocation:CreateFromBagAndSlot(tabID,
                                slotIndex))
                        results[#results + 1] = info
                    end
                end
            end
        end
    end
    return results
end

-- FR-9: is this item on an ignore list? Checked in tier order - the
-- shipped defaults win over the user's permanent itemID ignores, which win
-- over a single-copy GUID ignore. Returns the tier name for diagnostics,
-- nil when the item is a normal candidate.
function addon.IsIgnored(info)
    if info.itemID and addon.DEFAULT_ITEM_IGNORES
        and addon.DEFAULT_ITEM_IGNORES[info.itemID] then
        return "default"
    end
    local db = GearFallDB
    local ignores = db and db.ignores
    if not ignores then
        return nil
    end
    if info.itemID and ignores.items[info.itemID] then
        return "permanent"
    end
    if info.guid and info.guid ~= "" and ignores.instances[info.guid] then
        return "instance"
    end
    return nil
end

-- Everything that could be distributed right now: bag items always, plus
-- the inbox while a mailbox is open and the bank/Warbank tabs while the
-- bank frame is open (each is the Distribution window's own gate).
-- Ignored items are dropped at this single choke point - nothing
-- downstream ever sees them. The second return reports how many were
-- dropped per tier for /gear scan diagnostics.
function addon.ScanEligibleItems()
    local results = {}
    local ignored = { default = 0, permanent = 0, instance = 0 }
    local function consider(info)
        local tier = addon.IsIgnored(info)
        if tier then
            ignored[tier] = ignored[tier] + 1
        else
            results[#results + 1] = info
        end
    end
    for _, info in ipairs(addon.ScanBagsForEligibleItems()) do
        consider(info)
    end
    if addon._mailboxOpen then
        for _, info in ipairs(addon.ScanMailForEligibleItems()) do
            consider(info)
        end
    end
    if addon._bankOpen then
        for _, info in ipairs(addon.ScanBankForEligibleItems()) do
            consider(info)
        end
    end
    return results, ignored
end

local _, addon = ...

-- Equip Arrived: the claim-and-wear pipeline for upgrades this character
-- was promised and that have arrived (see the section header below for
-- the full design rationale, including why the equip goes through the
-- cursor).

-------------------------------------------------------------------------------
-- Equip arrived: one click equips the upgrades the ledger promised to the
-- current character that have already landed in their bags (the draft's
-- "Arrived - equip it" rows). Items go one at a time, and Blizzard's
-- soulbind confirm popup - whenever one is raised - stays the user's to
-- answer: the run waits it out without a cap, reads "dialog gone without
-- equipping" as a No (Blizzard's own OnHide runs CancelPendingEquip), and
-- moves on. The equip goes through the CURSOR, exactly like a manual
-- drag-to-paperdoll: PickupContainerItem puts the copy on the cursor,
-- EquipCursorItem(slotID) aims it at the slot the draft scored. Two
-- earlier software-only commands (C_Item.EquipItemByName, then
-- C_Container.UseContainerItem - the bag click) both leave the cursor
-- EMPTY while the confirm is pending, and the engine tears such a pending
-- equip down on the next cursor change: mousing over a mailbox or NPC
-- swapped the cursor and the popup vanished. Carrying the item on the
-- cursor pins it - no cursor change can fire while the popup is up - which
-- is precisely why the manual flow never had this bug. The explicit slot
-- target also matters: server-side auto-equip picks the FIRST legal slot,
-- so with a 100 + 10 ring pair an arrived 11 could displace the 100
-- instead of the 10.
-------------------------------------------------------------------------------

local EQUIP_POLL_INTERVAL = 0.25
local EQUIP_STEP_DELAY = 0.4
local EQUIP_NO_POPUP_TIMEOUT = 8
local EQUIP_LAND_GRACE = 1
-- the pre-loot claims inbox copies, but a take only proves the MAIL side:
-- the bag landing follows whenever the server round trip says so, so the
-- chain polls the bags for the claimed items instead of trusting a fixed
-- settle - POLL is the tick, TIMEOUT the give-up point at which whatever
-- already landed is equipped and the rest re-pin on their own later
local EQUIP_ARRIVAL_POLL = 0.25
local EQUIP_ARRIVAL_TIMEOUT = 8

-- the bind-confirm dialogs an equip can raise (Mainline GameDialogDefs):
-- EQUIP_BIND for plain BoEs, _REFUNDABLE when the swap would end a refund
-- window, _TRADEABLE when it would end the tradeable-soulbound window
local BIND_DIALOGS = {
    "EQUIP_BIND", "EQUIP_BIND_REFUNDABLE", "EQUIP_BIND_TRADEABLE",
}

local function BindPopupShown()
    if not StaticPopup_Visible then
        return false
    end
    for _, which in ipairs(BIND_DIALOGS) do
        if StaticPopup_Visible(which) then
            return true
        end
    end
    return false
end

-- is the very copy this entry promises already worn anywhere on the
-- paper doll? Item ID plus item level, never the link string
-- (IsArrivedIncomingItem's lesson: the same physical item renders with
-- different suffix forms across cache states, and upgrade tracks share one
-- item ID across item levels - an ilvl 619 copy worn in the slot must not
-- read as an arrived ilvl 626 one). The scan covers slots 1..19 (head..
-- tabard, both hands) even though EquipCursorItem targets one slot: it
-- doubles as the "equipped by hand between draft and click" pre-check and
-- a defensive net for any server-side placement quirk.
local function WornSomewhere(entry)
    for slotID = 1, 19 do
        local link = GetInventoryItemLink("player", slotID)
        if link and addon.GetItemID(link) == entry.itemID then
            if not entry.itemLevel or not addon.GetItemLevel
                or addon.GetItemLevel(link) == entry.itemLevel then
                return true
            end
        end
    end
    return false
end

-- the promise this entry fulfilled is proven: drop it now instead of
-- waiting on Roster's 1s-debounced capture, so the end-of-run draft reads
-- the slot as equipped rather than as still-awaiting mail. Matched by
-- IDENTITY, not by slot, so the cleanup stays honest wherever the copy
-- ended up worn (otherwise an orphaned promise would phantom-block the
-- drafted slot forever).
local function ClearArrivedPromise(entry)
    local myKey = addon.PlayerKey and addon.PlayerKey()
    local alt = myKey and GearFallDB.alts[myKey]
    if not (alt and alt.incoming) then
        return
    end
    for slot, inc in pairs(alt.incoming) do
        if inc.itemLink and addon.GetItemID(inc.itemLink) == entry.itemID
            and (not inc.itemLevel or not entry.itemLevel
                or inc.itemLevel == entry.itemLevel) then
            alt.incoming[slot] = nil
            addon.DebugPrint(("debug: incoming [%s] confirmed equipped (%s equip run)")
                :format(entry.name or "?",
                    addon.SLOT_NAMES[slot] or "?"))
        end
    end
    if not next(alt.incoming) then
        alt.incoming = nil
    end
end

-- arrival probe for the pre-loot chain: how many copies of an item
-- currently sit in the bags. A take command proves the mail side only -
-- the bag landing follows whenever the server round trip says so - so the
-- chain polls this instead of trusting a fixed settle. Deliberately no
-- draft rebuild per tick: the full rescan is reserved for the moment
-- arrival is proven. Same iteration as the bag scan (Scan.lua)
local function CountBagCopies(itemID)
    local count = 0
    for bagID = 0, NUM_BAG_SLOTS do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slotIndex = 1, numSlots do
            local containerItem = C_Container.GetContainerItemInfo(bagID, slotIndex)
            if containerItem and containerItem.hyperlink
                    and addon.GetItemID(containerItem.hyperlink) == itemID then
                count = count + 1
            end
        end
    end
    return count
end

-- first bag slot currently holding an item ID: bagID, slotIndex (the loot
-- executor's FindByItemID, bags edition). Coordinates are positions, not
-- identities, so a copy that drifted between plan and execution is
-- re-located instead of lost
local function FindBagCopy(itemID)
    for bagID = 0, NUM_BAG_SLOTS do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slotIndex = 1, numSlots do
            local containerItem = C_Container.GetContainerItemInfo(bagID, slotIndex)
            if containerItem and containerItem.hyperlink
                    and addon.GetItemID(containerItem.hyperlink) == itemID then
                return bagID, slotIndex
            end
        end
    end
end

-- the equip plan: arrived selfkeep rows whose item sits in a bag (inbox
-- attachments must be claimed first). slotID is both the draft's verdict
-- slot AND the EquipCursorItem target, so an arrived copy always
-- displaces exactly the item it was scored against; promise cleanup still
-- matches by identity so a defensive whole-doll check can never be
-- fooled. One entry per slot (rows arrive paperdoll-sorted, first wins)
function addon.BuildEquipArrivedPlan()
    local plan, seen = {}, {}
    for _, s in ipairs(addon._distSuggestions or {}) do
        if s.kind == "selfkeep" and s.arrived and s.item
                and s.item.location == "bag"
                and s.item.bagID ~= nil and s.item.slotIndex ~= nil then
            local slotID = addon.RowSlot(s)
            local itemID = s.item.itemLink and addon.GetItemID(s.item.itemLink)
            if slotID and itemID and not seen[slotID] then
                seen[slotID] = true
                plan[#plan + 1] = {
                    bagID = s.item.bagID,
                    slotIndex = s.item.slotIndex,
                    slotID = slotID,
                    itemLink = s.item.itemLink,
                    name = s.item.name,
                    itemID = itemID,
                    itemLevel = s.item.itemLevel,
                }
            end
        end
    end
    return plan
end

-- the equip chain's pre-loot: exactly the current character's arrived
-- promises still sitting in the inbox (their bag copies are equipped
-- directly; holds and other alts' rows stay out - the envelope buttons
-- already own those). Reuses the per-header claim planner, so the takes
-- ride the same identity checks, COD/GM skip and bag-full stop as Loot
-- from Mail
function addon.BuildEquipArrivedLootPlan()
    local rowKeys = {}
    for _, s in ipairs(addon._distSuggestions or {}) do
        if s.kind == "selfkeep" and s.arrived and s.item
                and s.item.location == "mail" and s.rowKey then
            rowKeys[#rowKeys + 1] = s.rowKey
        end
    end
    if #rowKeys == 0 then
        return {}
    end
    return addon.LootPlanForRows(rowKeys)
end

-- pure button state (text, disabled reason, enabled) so the equip run's
-- gating stays pinnable without a live frame. nil text = the button hides:
-- unlike the always-visible send/loot pair, this control only exists when
-- there is something arrived to equip
function addon.EquipArrivedButtonState()
    if addon._equipping then
        -- mid-run: keep the button visible in its busy state even if the
        -- plan just drained, so it never flickers off between items
        return "Equipping...", nil, false
    end
    if not (C_Container and C_Container.PickupContainerItem
            and C_Container.GetContainerItemInfo and GetInventoryItemLink
            and EquipCursorItem and GetCursorInfo and CursorHasItem
            and ClearCursor) then
        return nil
    end
    local plan = addon.BuildEquipArrivedPlan()
    local lootPlan = addon.BuildEquipArrivedLootPlan()
    -- the click acts on both: bag copies equip directly, inbox copies are
    -- claimed by the chain's pre-loot first, so both count toward N (an
    -- inbox-only state must still show the button or it could never be
    -- clicked)
    local total = #plan + #lootPlan
    if total == 0 then
        return nil
    end
    if addon._mailLooting or addon._distSending then
        return ("Equip Arrived (%d)"):format(total),
            "A mail run is in progress", false
    end
    return ("Equip Arrived (%d)"):format(total), nil, true
end

function addon.ExecuteEquipArrived(plan, onDone)
    -- one pipeline at a time: equipping changes bags and worn gear, and
    -- both feed the draft the mail pipelines work from
    if addon.MailRunActive() then
        return
    end
    local entries = {}
    for _, e in ipairs(plan or {}) do
        entries[#entries + 1] = e
    end
    local lootPlan = addon.BuildEquipArrivedLootPlan()
    if #entries == 0 and #lootPlan == 0 then
        if onDone then
            onDone(0)
        end
        return
    end

    -- the flag holds for the WHOLE chain (pre-loot + equip): event-driven
    -- rescans stand down and the buttons read busy across both phases
    addon._equipping = true
    addon.UpdateDistEquipBtn()
    addon.UpdateDistMailBtn()
    addon.UpdateDistLootBtn()

    local equipped, skipped, gone = 0, 0, 0
    local index = 1
    local step

    local function finish()
        addon._equipping = nil
        addon.UpdateDistEquipBtn()
        addon.UpdateDistMailBtn()
        addon.UpdateDistLootBtn()
        local parts = {}
        if equipped > 0 then
            parts[#parts + 1] = ("equipped %d"):format(equipped)
        end
        if skipped > 0 then
            parts[#parts + 1] = ("%d skipped"):format(skipped)
        end
        if gone > 0 then
            parts[#parts + 1] = ("%d no longer there"):format(gone)
        end
        if #parts > 0 then
            addon.Print("Equip arrived: " .. table.concat(parts, ", "))
        end
        -- the equipped items left the bags and count as worn gear now: a
        -- fresh draft re-reads the ledger (the run itself dropped the
        -- fulfilled promises), the Sendable grid shares the bag state
        addon.RefreshDistribution(true)
        if equipped > 0 then
            -- the inventory swap can land after this refresh: re-check
            -- shortly, mirroring the loot finish's re-check chain, so the
            -- window never waits for the next unrelated event to look
            -- right
            for _, delay in ipairs({ 0.5, 1.5 }) do
                C_Timer.After(delay, function()
                    if not addon.MailRunActive() then
                        addon.RefreshDistribution(true)
                    end
                end)
            end
        end
        if addon.RefreshSendableTab then
            addon.RefreshSendableTab()
        end
        if onDone then
            onDone(equipped)
        end
    end

    local function EquipEntry(entry, nextStep)
        -- is OUR copy currently riding the cursor? GetCursorInfo returns
        -- "item", itemID, ... for a carried item
        local function CursorHoldsEntry()
            local kind, cursorID = GetCursorInfo()
            return kind == "item" and cursorID == entry.itemID
        end

        -- take the copy back off the cursor and into the bags. Returns
        -- false when the cursor still holds it (bags full) - the caller
        -- must stop the run rather than leave an item stranded mid-air
        local function StowCursor()
            ClearCursor()
            return not CursorHasItem()
        end

        -- bag coordinates are positions, not identities (the loot
        -- executor's FindByItemID lesson): verify the slot still holds the
        -- promised copy, and re-locate by item ID when it drifted (a bag
        -- reshuffle between plan and execution must not cost the item) -
        -- only "nowhere in the bags" counts as gone
        local bagItem = C_Container.GetContainerItemInfo(entry.bagID,
            entry.slotIndex)
        local link = bagItem and bagItem.hyperlink
        if not link or addon.GetItemID(link) ~= entry.itemID then
            local bagID, slotIndex = FindBagCopy(entry.itemID)
            if not bagID then
                gone = gone + 1
                nextStep()
                return
            end
            entry.bagID, entry.slotIndex = bagID, slotIndex
        end
        -- equipped manually between draft and click? count it, drop the
        -- promise, move on
        if WornSomewhere(entry) then
            equipped = equipped + 1
            ClearArrivedPromise(entry)
            nextStep()
            return
        end
        -- the cursor must be EMPTY for the pickup: PickupContainerItem
        -- with a carried item SWAPS them (the user's item would land in
        -- this bag slot - a surprise relocation), and a non-item cursor
        -- (spell, money) can fail the pickup outright. Stow whatever rides
        -- it first - the same contract as the mail attach loop's
        -- ClearCursor before pickup - and refuse the entry when even that
        -- leaves the cursor loaded
        if GetCursorInfo() then
            ClearCursor()
            if GetCursorInfo() then
                addon.Print(("Cursor busy - skipped %s")
                    :format(entry.name or "item"))
                skipped = skipped + 1
                nextStep()
                return
            end
        end
        -- the manual drag-to-paperdoll flow, automated in one pass: pick
        -- the copy up (item rides the cursor, which PINS the cursor and
        -- shields the pending equip from cursor changes), then aim it at
        -- the slot the draft scored
        C_Container.PickupContainerItem(entry.bagID, entry.slotIndex)
        if not CursorHasItem() then
            gone = gone + 1
            nextStep()
            return
        end
        EquipCursorItem(entry.slotID)
        local waited, sawPopup, landed = 0, false, 0
        local function poll()
            if not addon._equipping then
                return
            end
            if WornSomewhere(entry) then
                equipped = equipped + 1
                -- the displaced worn item auto-stores to bags on confirm,
                -- but a defensive stow keeps any cursor ride-along from
                -- leaking into the next entry
                if CursorHasItem() and not StowCursor() then
                    addon.Print("Bags full - stopped equipping arrived items")
                    finish()
                    return
                end
                ClearArrivedPromise(entry)
                nextStep()
                return
            end
            if BindPopupShown() then
                sawPopup = true
                -- the soulbind confirm is the user's to answer: wait it
                -- out, however long it takes - no cap (the copy rides the
                -- cursor the whole time, exactly like the manual flow)
                C_Timer.After(EQUIP_POLL_INTERVAL, poll)
                return
            end
            if sawPopup then
                -- the dialog was up and is now gone without equipping: the
                -- user answered No (Blizzard's own OnHide ran
                -- CancelPendingEquip). The cancel leaves the copy ON the
                -- cursor - stow it back into the bags right away instead
                -- of stalling the run on the refused-equip timeout
                if CursorHasItem() and not StowCursor() then
                    addon.Print("Bags full - stopped equipping arrived items")
                    finish()
                    return
                end
                skipped = skipped + 1
                nextStep()
                return
            end
            if CursorHoldsEntry() then
                -- no dialog and the copy is still on the cursor: the
                -- equip is either in flight or the server refused it
                -- (combat for armor, weapon-set rules). Stop waiting after
                -- the timeout and stow the copy back into the bags
                waited = waited + EQUIP_POLL_INTERVAL
                if waited >= EQUIP_NO_POPUP_TIMEOUT then
                    if not StowCursor() then
                        addon.Print("Bags full - stopped equipping arrived items")
                        finish()
                        return
                    end
                    skipped = skipped + 1
                    nextStep()
                    return
                end
                C_Timer.After(EQUIP_POLL_INTERVAL, poll)
                return
            end
            -- the copy is neither worn nor on the cursor: either the slot
            -- filled in the same burst the bag emptied (checked above) or
            -- it left the bags some other way. Allow a short grace for
            -- split BAG_UPDATE/PLAYER_EQUIPMENT_CHANGED frames before
            -- calling it gone
            if landed < EQUIP_LAND_GRACE then
                landed = landed + EQUIP_POLL_INTERVAL
                C_Timer.After(EQUIP_POLL_INTERVAL, poll)
                return
            end
            gone = gone + 1
            nextStep()
        end
        C_Timer.After(EQUIP_POLL_INTERVAL, poll)
    end

    function step()
        local entry = entries[index]
        if not entry then
            finish()
            return
        end
        index = index + 1
        if equipped + skipped + gone > 0 then
            -- pacing: the previous item's bag/equip events need a beat to
            -- land before the next verify-and-equip pass reads them
            C_Timer.After(EQUIP_STEP_DELAY, function()
                EquipEntry(entry, step)
            end)
        else
            EquipEntry(entry, step)
        end
    end

    -- arrived copies still in the inbox: claim them first through the
    -- same loot sequencer the Loot from Mail button drives (bagspace
    -- permitting is its per-take rule; COD/GM letters are never taken),
    -- then poll the bags until every CLAIMED item has proven its arrival
    -- (a take only proves the mail side), rebuild the draft (the fresh
    -- copies pin as arrived-in-bags), and equip everything with the
    -- normal sequencer. A planned take that went "gone" can never stall
    -- the wait: only claimed entries feed the expected counts. At the
    -- timeout whatever already landed is equipped and the rest re-pin on
    -- their own later
    if #lootPlan > 0 and addon.MailboxOpen()
            and TakeInboxItem and HasInboxItem
            and GetInboxItemLink and GetInboxNumItems then
        addon.RunMailLoot(lootPlan, function(taken, takenEntries)
            if not addon._equipping then
                return
            end
            if taken == 0 then
                -- nothing claimed (gone, COD/GM): nothing to wait for -
                -- but the click may have started with bag copies, so hand
                -- straight back to the equip sequencer over them (an
                -- entries drain ends the run via its own finish)
                step()
                return
            end
            local expected = {}
            for _, e in ipairs(takenEntries or {}) do
                local id = addon.GetItemID(e.itemLink)
                if id then
                    expected[id] = (expected[id] or 0) + 1
                end
            end
            local waited = 0
            local function awaitArrival()
                if not addon._equipping then
                    return
                end
                local arrivedAll = true
                for id, count in pairs(expected) do
                    if CountBagCopies(id) < count then
                        arrivedAll = false
                        break
                    end
                end
                if arrivedAll or waited >= EQUIP_ARRIVAL_TIMEOUT then
                    addon.RefreshDistribution(true)
                    entries = {}
                    for _, e in ipairs(addon.BuildEquipArrivedPlan()) do
                        entries[#entries + 1] = e
                    end
                    index = 1
                    step()
                    return
                end
                waited = waited + EQUIP_ARRIVAL_POLL
                C_Timer.After(EQUIP_ARRIVAL_POLL, awaitArrival)
            end
            C_Timer.After(EQUIP_ARRIVAL_POLL, awaitArrival)
        end)
        return
    end

    if #entries == 0 then
        -- inbox-only state that could not loot (closed mailbox, missing
        -- mail APIs): nothing to equip, nothing taken
        finish()
        return
    end

    step()
end

local _, addon = ...

-- Distribution (loot): claim inbox attachments by draft stage ("Loot
-- from Mail"). The draft already classifies every attachment (Scan.lua's
-- second inventory); one click loots one stage - upgrades, then future
-- upgrades, then respec holds - putting the items in bags where the
-- normal send pipeline can mail them out. Left over attachments are
-- deliberately never looted: they stay in the mailbox and return to
-- their senders.

-- Stage order IS the button order; match() reads draft rows, and the plan
-- filter only ever passes location == "mail" rows, so bag items and
-- leftover rows can never qualify
local LOOT_STAGES = {
    { id = "upgrades", label = "Loot Upgrades",
        match = function(s)
            return s.kind == "upgrade" or s.kind == "selfkeep"
        end },
    { id = "future", label = "Loot Future Upgrades",
        match = function(s)
            return s.kind == "hold" and s.hold.kind == "eventually"
        end },
    { id = "respec", label = "Loot Respec Items",
        match = function(s)
            return s.kind == "hold"
                and (s.hold.kind == "respec" or s.hold.kind == "newalt")
        end },
}

-- Source-agnostic loot seams: the verb is "loot", the source is a
-- preposition ("loot from the mail", one day "loot from the bank").
-- Classification/recipient filters produce plans; exactly one executor
-- consumes them per source. Only code that genuinely talks to one
-- source's API keeps the source in its name (ExecuteMailLoot,
-- BuildMailLootPlan) - the seams below must never need renaming when
-- another lootable location arrives, it just grows a policy helper and
-- a branch inside ExecuteLoot.
-- the one inbox source policy: a row is takeable from the mailbox iff it
-- is still an attachment there (bag rows and unattached items never are)
local function InboxLootable(s)
    return s.item and s.item.location == "mail"
        and s.item.mailIndex ~= nil
end

-- generic planner: filter draft rows through a predicate; each entry
-- carries the take coordinates of wherever the item sits PLUS its link,
-- whose item ID is the identity that survives the index shifts a
-- vanishing mail causes mid-run (see the executor's verification note)
function addon.BuildLootPlanWhere(predicate)
    local plan = {}
    for _, s in ipairs(addon._distSuggestions or {}) do
        if s.item and predicate(s) then
            plan[#plan + 1] = {
                mailIndex = s.item.mailIndex,
                attachIndex = s.item.attachIndex,
                itemLink = s.item.itemLink,
                name = s.item.name,
            }
        end
    end
    return plan
end

-- the staged button: one draft stage per plan, composed from the same
-- generic planner plus the inbox policy (never a second walk)
function addon.BuildMailLootPlan(stageId)
    for _, stage in ipairs(LOOT_STAGES) do
        if stage.id == stageId then
            return addon.BuildLootPlanWhere(function(s)
                return InboxLootable(s) and stage.match(s)
            end)
        end
    end
    return {}
end

-- per-header claim: exactly the rows ONE draft header lists (a recipient
-- group's own upgrades/selfkeeps, a hold segment's own holds). An alt
-- with rows under other headers claims those through their own headers'
-- envelopes - the count shown on a header is always the count it claims
function addon.LootPlanForRows(rowKeys)
    local wanted = {}
    for _, key in ipairs(rowKeys or {}) do
        wanted[key] = true
    end
    return addon.BuildLootPlanWhere(function(s)
        return InboxLootable(s) and s.rowKey ~= nil
            and wanted[s.rowKey] and s.kind ~= "leftover"
    end)
end

-- per-item claim: exactly this drafted row. Leftover rows are excluded
-- by the caller-visible kind guard: junk stays in the mail and returns
-- to its senders, per the staged button's own rule
function addon.LootPlanForItem(rowKey)
    return addon.BuildLootPlanWhere(function(s)
        return InboxLootable(s) and s.rowKey == rowKey
            and s.kind ~= "leftover"
    end)
end

-- the first populated stage in button order: a click never hits an empty
-- category, so "hit it again" always advances to the next set with items
function addon.NextMailLootStage()
    for _, stage in ipairs(LOOT_STAGES) do
        local plan = addon.BuildMailLootPlan(stage.id)
        if #plan > 0 then
            return stage, plan
        end
    end
    return nil
end

-- pure button state (text, disabled reason, enabled) so the stage
-- progression stays pinnable without a live frame
function addon.MailLootButtonState()
    if addon._mailLooting then
        return "Looting...", nil, false
    end
    if addon._distSending then
        return "Loot from Mail", "A mail run is in progress", false
    end
    if addon._equipping then
        return "Loot from Mail", "Equipping arrived items is in progress",
            false
    end
    if not addon.MailboxOpen() then
        return "Loot from Mail", "Open a mailbox to loot", false
    end
    -- Blizzard_MailFrame ships in the base UI, but these guards mirror
    -- Scan.lua's inbox scan: an exotic client degrades to a disabled
    -- button instead of an error
    if not (TakeInboxItem and HasInboxItem and GetInboxItemLink) then
        return "Loot from Mail", "Mail APIs unavailable", false
    end
    local stage, plan = addon.NextMailLootStage()
    if not stage then
        return "Loot from Mail", "No attachments the draft wants looted",
            false
    end
    return ("%s (%d)"):format(stage.label, #plan), nil, true
end

local LOOT_POLL_INTERVAL = 0.15
local LOOT_TAKE_TIMEOUT = 3

-- Blizzard's own Open All button paces inbox takes exactly this way: one
-- command at a time, waited out via C_Mail.IsCommandPending (MailFrame.lua
-- OpenAllMailMixin, 0.15s between commands). Without that API we pay a
-- blind extra delay instead of racing the server.
local function MailCommandPending()
    if C_Mail and C_Mail.IsCommandPending then
        return C_Mail.IsCommandPending() and true or false
    end
    return false
end

local function FreeBagSlots()
    if C_Container and C_Container.CalculateTotalNumberOfFreeBagSlots then
        return C_Container.CalculateTotalNumberOfFreeBagSlots() or 0
    end
    return 99
end

function addon.ExecuteMailLoot(plan, onDone)
    -- one mailbox pipeline at a time: looting fills the bags the sender
    -- drains, and both drive Blizzard's mail state
    if addon.MailRunActive() then
        return
    end
    return addon.RunMailLoot(plan, onDone)
end

-- the loot sequencer proper, without the pipeline guard: the equip chain
-- drives it directly while holding the _equipping flag across both phases
-- (loot then equip) - going through the guarded entry would deadlock the
-- chain against its own flag
function addon.RunMailLoot(plan, onDone)
    if not addon.MailboxOpen() then
        addon.Print("Open a mailbox first to loot")
        if onDone then
            onDone(0)
        end
        return
    end
    local entries = {}
    for _, e in ipairs(plan or {}) do
        entries[#entries + 1] = e
    end
    if #entries == 0 then
        if onDone then
            onDone(0)
        end
        return
    end

    addon._mailLooting = true
    addon.UpdateDistLootBtn()
    addon.UpdateDistMailBtn()

    local taken, gone, skipped = 0, 0, 0
    -- which plan entries a take actually confirmed: the equip chain's
    -- arrival poll reads this (a count per item ID) so a planned entry
    -- that went "gone" can never stall the wait
    local takenEntries = {}
    local index = 1
    local step

    local function finish()
        addon._mailLooting = nil
        local parts = {}
        if taken > 0 then
            parts[#parts + 1] = ("looted %d"):format(taken)
        end
        if gone > 0 then
            parts[#parts + 1] = ("%d no longer there"):format(gone)
        end
        if skipped > 0 then
            parts[#parts + 1] = ("%d skipped"):format(skipped)
        end
        if #parts > 0 then
            addon.Print("Mail loot: " .. table.concat(parts, ", "))
        end
        addon.UpdateDistLootBtn()
        addon.UpdateDistMailBtn()
        -- a fresh draft: the looted items are bag items now and re-enter
        -- the send pipeline on their own merit; the Sendable grid shares
        -- the bag state, so it gets the same end-of-run truth. During the
        -- equip chain this refresh is SUPPRESSED: the claimed copies are
        -- in transit right now (briefly in neither the inbox nor the
        -- bags), so a rebuild here would flash the window empty - the
        -- chain's arrival poll owns the display until the bags settle and
        -- refreshes once, with the copies in them
        if not addon._equipping then
            addon.RefreshDistribution(true)
        end
        if taken > 0 then
            -- the claimed items' bag arrival (and the inbox removal) can
            -- land AFTER this refresh - the poll only confirms the mail
            -- command, not the client-side state: re-check shortly,
            -- mirroring MAIL_SHOW's guaranteed-rescan chain, so the
            -- window never waits for the next unrelated event to look
            -- right
            for _, delay in ipairs({ 0.5, 1.5 }) do
                C_Timer.After(delay, function()
                    if addon._mailboxOpen and not addon.MailRunActive() then
                        addon.RefreshDistribution(true)
                    end
                end)
            end
        end
        if addon.RefreshSendableTab then
            addon.RefreshSendableTab()
        end
        if onDone then
            onDone(taken, takenEntries)
        end
    end

    -- inbox coordinates are positions, not identities: an emptied or
    -- auto-removed mail shifts every later index. Verify before each take
    -- and re-find the item when the slot no longer matches. Identity is
    -- the ITEM ID, never the link string: the plan's link is the
    -- C_Item.GetItemInfo cached render of the attachment's link, which
    -- need not equal GetInboxItemLink's own string (suffix drift, and the
    -- display form differs across clients) - an exact-string compare
    -- failed every in-game take ("N no longer there") while the
    -- identical-string stubs stayed green
    local function FindByItemID(link)
        if not (GetInboxNumItems and GetInboxItemLink) then
            return nil
        end
        local id = addon.GetItemID(link)
        for mailIndex = 1, GetInboxNumItems() do
            for attachIndex = 1, (ATTACHMENTS_MAX_SEND or 12) do
                local here = GetInboxItemLink(mailIndex, attachIndex)
                if here and addon.GetItemID(here) == id then
                    return mailIndex, attachIndex
                end
            end
        end
    end

    local function TakeEntry(entry, nextStep)
        if not addon.MailboxOpen() then
            finish()
            return
        end
        if FreeBagSlots() == 0 then
            addon.Print("Bags full - stopped looting from the mail")
            finish()
            return
        end
        local mailIndex, attachIndex = entry.mailIndex, entry.attachIndex
        local entryID = addon.GetItemID(entry.itemLink)
        local hereID = GetInboxItemLink
            and addon.GetItemID(GetInboxItemLink(mailIndex, attachIndex))
        if not GetInboxItemLink or hereID ~= entryID then
            mailIndex, attachIndex = FindByItemID(entry.itemLink)
            if not mailIndex then
                gone = gone + 1
                nextStep()
                return
            end
        end
        -- COD and GM letters must never be auto-looted (Blizzard's Open All
        -- skips both): money confirmation and restored items need a human.
        -- Positions mirror Blizzard's own gate
        -- (OpenAllMailMixin:ShouldSkipCurrentMail, MailFrame.lua):
        -- CODAmount at 6, isGM at 13. The earlier "isGM at 12" read the
        -- canReply flag, which is truthy on every normal player mail and
        -- skipped all of them in-game
        local _, _, _, _, _, cod, _, _, _, _, _, _, isGM
            = GetInboxHeaderInfo(mailIndex)
        if (cod and cod > 0) or isGM then
            skipped = skipped + 1
            nextStep()
            return
        end
        -- the slot must still hold a take-able attachment (false while a
        -- take is in flight or already claimed)
        if not HasInboxItem(mailIndex, attachIndex) then
            gone = gone + 1
            nextStep()
            return
        end
        TakeInboxItem(mailIndex, attachIndex)
        local waited = 0
        local function poll()
            if not addon._mailLooting then
                return
            end
            waited = waited + LOOT_POLL_INTERVAL
            if not MailCommandPending() then
                taken = taken + 1
                takenEntries[#takenEntries + 1] = entry
                nextStep()
            elseif waited >= LOOT_TAKE_TIMEOUT then
                -- command never confirmed: leave the attachment alone and
                -- carry on rather than wedge the run on one stuck slot
                skipped = skipped + 1
                nextStep()
            else
                C_Timer.After(LOOT_POLL_INTERVAL, poll)
            end
        end
        C_Timer.After(LOOT_POLL_INTERVAL, poll)
    end

    function step()
        local entry = entries[index]
        if not entry then
            finish()
            return
        end
        index = index + 1
        TakeEntry(entry, step)
    end

    step()
end

-- the UI's loot entry point: dispatches a plan by where its items sit.
-- Mail is the only takeable location today; another lootable location
-- (bank...) adds its own executor and a branch here - never a new UI
-- seam and never a rename.
function addon.ExecuteLoot(plan, onDone)
    return addon.ExecuteMailLoot(plan, onDone)
end

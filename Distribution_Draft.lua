local _, addon = ...

-- Distribution (draft): the suggestion engine. One greedy pass scores
-- every scanned item against every roster alt and projects winners into a
-- simulated incoming ledger, producing the rows the Distribution window
-- renders (mail to X, keep for yourself, hold, left over) plus the
-- per-alt verdict map the Sendable tab's "view from <alt>" mode reads.
-- The shared formatting helpers (FormatDelta, ClassColor, RowSlot) and
-- the hold-kind colors live here; every other Distribution_* module and
-- the window consume them via addon.*.

addon.KIND_COLOR = {
    eventually = { 1, 1, 0.3 },
    respec = { 0.7, 0.7, 0.75 },
    newalt = { 1, 0.82, 0 },
}

-- realm-aware display names (Util.lua): same realm -> bare name
local AltDisplayName = addon.AltDisplayName

function addon.ClassColor(token)
    local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c then
        return c.r, c.g, c.b
    end
    return 0.85, 0.85, 0.85
end

-- cross-realm warband alts need the "-realm" suffix in the recipient field
function addon.MailRecipientFor(key)
    local name, realm = key:match("^([^-]+)%-?(.*)$")
    if (not realm or realm == "") or realm == GetRealmName() then
        return name or key
    end
    return name .. "-" .. realm
end

function addon.FormatDelta(result)
    local base
    if result.mode == "ITEMLEVEL" then
        base = ("%+d iLvl"):format(result.delta or 0)
    else
        base = ("%+.1f"):format(result.delta or 0)
        -- Pawn-style relative upgrade next to the absolute score difference;
        -- unavailable for empty slots (nothing to compare against)
        if result.upgradePercent then
            base = base .. (", %+.0f%%"):format(result.upgradePercent)
        end
    end
    return base
end

-- the InventorySlotID a draft row targets: the chosen slot for scored rows
-- (11/12 distinguish the two fingers, 13/14 the trinkets), the static
-- invType mapping for hold/leftover rows
function addon.RowSlot(s)
    if s.result and s.result.slotID then
        return s.result.slotID
    end
    return s.item and addon.TargetSlotFor(s.item) or nil
end

-- paper-doll display order: the character frame reads left column top-down
-- (Head..Back, Chest, Wrist) then right column (Hands..Trinket2), weapons
-- last - NOT the numeric inventory slot order (Back is 15, waist/legs/feet
-- sit at 6/7/8)
local PAPERDOLL_ORDER = {
    [1] = 1, [2] = 2, [3] = 3, [15] = 4, [5] = 5,
    [9] = 6, [10] = 7, [6] = 8, [7] = 9, [8] = 10,
    [11] = 11, [12] = 12, [13] = 13, [14] = 14,
    [16] = 15, [17] = 16,
}
local function SlotRank(slotID)
    return slotID and PAPERDOLL_ORDER[slotID] or 99
end

-- Greedy draft with a simulated ledger: pass 1 scores every bag item
-- against reality, pass 2 hands items out best-delta-first and projects
-- each assignment into a fake `incoming` slot, re-scoring the rest of the
-- bag against the projected alt. Two hats can no longer both mail to one
-- alt (the loser re-offers to the runner-up or falls to "left over"),
-- while two rings still mail: they win different slots. The sim slots use
-- the same evalSlot path as the real ledger, so Pawn math applies too.
function addon.BuildDistributionSuggestions()
    local ok, scanned = pcall(addon.ScanEligibleItems)
    local suggestions = {}
    if not ok then
        return suggestions
    end

    local function mergedIncoming(alt, simAlt)
        if not simAlt then
            return alt.incoming
        end
        local merged = {}
        if alt.incoming then
            for k, v in pairs(alt.incoming) do
                merged[k] = v
            end
        end
        for k, v in pairs(simAlt) do
            merged[k] = v
        end
        return merged
    end

    local upgradeQueue, holds = {}, {}
    -- declared before the scan loop: pinned arrivals project into the same
    -- sim ledger the queue re-scores against, so duplicate copies and later
    -- candidates see them
    local sim = {}
    local selfkeep = {}
    local myKey = addon.PlayerKey and addon.PlayerKey()
    local myAlt = myKey and GearFallDB.alts[myKey] or nil
    for _, info in ipairs(scanned) do
        if info.eligible then
            -- spot is the location stamped by the scans ("0:3" for bags,
            -- "mail:1:2" for inbox attachments, "bank:1:1"/"wbank:1:1"
            -- for bank/Warbank tabs)
            local rowKey = info.spot
                or ("%d:%d"):format(info.bagID or 0, info.slotIndex or 0)
            -- An item the ledger promised to the CURRENT character that
            -- just showed up in their own inventory (bags or inbox) is the
            -- arrival itself: pin it as "keep for yourself" instead of
            -- re-drafting. Without this, the ledger that prevents
            -- double-mailing reads the item's own arrival as "not an
            -- upgrade" and ships the promised gear to the next alt down.
            -- The pin only fires while the item is still an upgrade for
            -- them (delta > 0): if something better got equipped in the
            -- meantime, the promise is superseded and the normal draft
            -- re-offers the copy down the priority list. One copy per
            -- promise: the first pin projects into the sim ledger, so a
            -- second identical copy competes normally (Left over or the
            -- next alt wins it).
            local pinned = false
            if myAlt and myAlt.incoming then
                for _, inc in pairs(myAlt.incoming) do
                    if inc.mailIncoming
                        and addon.IsArrivedIncomingItem(info, inc) then
                        local res = addon.ScoreItemForAlt(info, myAlt)
                        if res.eligible and (res.delta or 0) > 0
                            and not (sim[myKey] and sim[myKey][res.slotID]) then
                            selfkeep[#selfkeep + 1] = {
                                kind = "selfkeep", item = info,
                                altKey = myKey, result = res,
                                rowKey = rowKey, arrived = true,
                            }
                            sim[myKey] = sim[myKey] or {}
                            sim[myKey][res.slotID] = {
                                itemLink = info.itemLink,
                                itemLevel = info.itemLevel,
                                name = info.name,
                                quality = info.quality,
                                draftIncoming = true,
                            }
                            pinned = true
                        end
                        break
                    end
                end
            end
            if not pinned then
                local matches, advice = addon.FindBestAltsForItem(info)
                -- the current character competes like any other alt: when
                -- they win under the active strategy, the item stays (equip
                -- it) instead of being mailed; when an alt out-competes
                -- them, the item is mailed there
                if matches and #matches > 0 then
                    local bestDelta = 0
                    for _, m in ipairs(matches) do
                        if (m.result.delta or 0) > bestDelta then
                            bestDelta = m.result.delta
                        end
                    end
                    upgradeQueue[#upgradeQueue + 1] = {
                        info = info, matches = matches,
                        bestDelta = bestDelta, rowKey = rowKey,
                    }
                elseif advice.hold then
                    -- rank the hold-capable alts from the verdict map
                    -- FindBestAltsForItem already produced: no second
                    -- scoring pass, and the ranking can never disagree with
                    -- the initial advice. Excluded alts are never hold
                    -- targets (FR-2) and never consume hold budget; each
                    -- candidate carries its OWN verdict so a cascade
                    -- rewrite describes the assigned alt
                    local holdAlts = {}
                    for altKey, v in pairs(advice.byAlt or {}) do
                        if altKey ~= myKey and v.verdict
                            and v.verdict ~= "no" then
                            holdAlts[#holdAlts + 1] = {
                                key = altKey,
                                tier = v.tier,
                                kind = v.verdict,
                                specs = v.respecSpecs,
                                reason = v.reason,
                            }
                        end
                    end
                    table.sort(holdAlts, function(a, b)
                        if a.tier ~= b.tier then
                            return a.tier < b.tier
                        end
                        return a.key < b.key
                    end)
                    local ranked = {}
                    for _, e in ipairs(holdAlts) do
                        ranked[#ranked + 1] = { key = e.key, kind = e.kind,
                            specs = e.specs, reason = e.reason }
                    end
                    holds[#holds + 1] = {
                        kind = "hold", item = info, hold = advice.hold,
                        holdAlts = ranked, rowKey = rowKey,
                    }
                end
                -- else: nobody can use it, nobody ever will -> stay silent,
                -- the vendor stands for "safe to destroy"
            end
        end
    end
    -- best-delta-first, with deterministic ties: equal deltas prefer the
    -- copy already in bags (a mail duplicate then falls to Left over and
    -- returns to its sender - claiming one of two identical attachments
    -- must never re-qualify the second one on the post-loot rescan), and
    -- rowKey last so the same scan always drafts the same way
    table.sort(upgradeQueue, function(a, b)
        if a.bestDelta ~= b.bestDelta then
            return a.bestDelta > b.bestDelta
        end
        local aBag = a.info.location == "bag"
        local bBag = b.info.location == "bag"
        if aBag ~= bBag then
            return aBag
        end
        return (a.rowKey or "") < (b.rowKey or "")
    end)

    local drafted, leftover = {}, {}
    local strategy = addon.SettingChoice("draftStrategy")
    local function TierOf(m)
        return (m.alt.prioTier or 9999)
    end
    for _, cand in ipairs(upgradeQueue) do
        local byDelta = {}
        for i, m in ipairs(cand.matches) do
            byDelta[i] = m
        end
        table.sort(byDelta, function(a, b)
            local ta, tb = TierOf(a), TierOf(b)
            if strategy == "priority" then
                -- roster priority: the highest tier that can use it wins;
                -- delta only breaks same-tier ties
                if ta ~= tb then
                    return ta < tb
                end
                if (a.result.delta or 0) ~= (b.result.delta or 0) then
                    return (a.result.delta or 0) > (b.result.delta or 0)
                end
                return a.key < b.key
            end
            -- biggest upgrade: deltas compete, but only within the same
            -- scoring mode (Pawn points vs item levels are incomparable);
            -- cross-mode pairs defer to tier
            if a.result.mode ~= b.result.mode then
                if ta ~= tb then
                    return ta < tb
                end
                return a.key < b.key
            end
            local ad, bd = a.result.delta or 0, b.result.delta or 0
            if ad ~= bd then
                return ad > bd
            end
            if ta ~= tb then
                return ta < tb
            end
            return a.key < b.key
        end)
        local placed
        for _, m in ipairs(byDelta) do
            local prevIncoming = m.alt.incoming
            m.alt.incoming = mergedIncoming(m.alt, sim[m.key])
            local res = addon.ScoreItemForAlt(cand.info, m.alt)
            m.alt.incoming = prevIncoming
            if res.eligible and (res.delta or 0) > 0 then
                sim[m.key] = sim[m.key] or {}
                sim[m.key][res.slotID] = {
                    itemLink = cand.info.itemLink,
                    itemLevel = cand.info.itemLevel,
                    name = cand.info.name,
                    quality = cand.info.quality,
                    draftIncoming = true,
                }
                if m.key == myKey then
                    -- the current character won the competition: the item
                    -- stays in their bags (equip it), it is never mailed
                    selfkeep[#selfkeep + 1] = {
                        kind = "selfkeep", item = cand.info,
                        altKey = myKey, result = res,
                        rowKey = cand.rowKey,
                    }
                else
                    local others = 0
                    for _, om in ipairs(cand.matches) do
                        if om.key ~= myKey and om.key ~= m.key then
                            others = others + 1
                        end
                    end
                    drafted[#drafted + 1] = {
                        kind = "upgrade", item = cand.info, altKey = m.key,
                        alt = m.alt, result = res,
                        others = others, rowKey = cand.rowKey,
                    }
                end
                placed = true
                break
            end
        end
        if not placed then
            leftover[#leftover + 1] = {
                kind = "leftover", item = cand.info, rowKey = cand.rowKey,
            }
        end
    end

    -- group by recipient so the list reads as "everything going to Mage",
    -- "everything going to Warrior", ... in roster-priority order; then the
    -- the un-mailable sections at the bottom: the hold area (split by
    -- blocker kind, segmented per alt) and Left over
    local byAlt, groups = {}, {}
    for _, d in ipairs(drafted) do
        local g = byAlt[d.altKey]
        if not g then
            g = { altKey = d.altKey, alt = d.alt, items = {}, best = 0 }
            byAlt[d.altKey] = g
            groups[#groups + 1] = g
        end
        g.items[#g.items + 1] = d
        if (d.result.delta or 0) > g.best then
            g.best = d.result.delta
        end
    end
    table.sort(groups, function(a, b)
        local ao, bo = a.alt.prioTier or 9999, b.alt.prioTier or 9999
        if ao ~= bo then
            return ao < bo
        end
        return a.best > b.best
    end)

    -- altKey = the character this header's rows belong to (recipient
    -- groups, "Keep for yourself", per-alt hold segments); section and
    -- "Left over" headers stay alt-less and never grow a mail icon.
    -- mailCount = how many of those rows are still inbox attachments -
    -- the envelope icon's count and its "anything to loot?" gate.
    -- bankCount = how many still sit in a bank/Warbank tab - the chest
    -- icon's count and its "anything to withdraw?" gate.
    local function addHeader(title, r, g, b, label, items, altKey)
        local rowKeys, mailCount, bankCount = {}, 0, 0
        for _, it in ipairs(items or {}) do
            if it.rowKey then
                rowKeys[#rowKeys + 1] = it.rowKey
            end
            if it.item and it.item.location == "mail" then
                mailCount = mailCount + 1
            elseif it.item and it.item.location == "bank" then
                bankCount = bankCount + 1
            end
        end
        suggestions[#suggestions + 1] = {
            kind = "header", title = title, r = r, g = g, b = b,
            label = label, rowKeys = rowKeys, mailCount = mailCount,
            bankCount = bankCount, altKey = altKey,
        }
    end

    for _, grp in ipairs(groups) do
        table.sort(grp.items, function(x, y)
            local sx, sy = SlotRank(addon.RowSlot(x)), SlotRank(addon.RowSlot(y))
            if sx ~= sy then
                return sx < sy
            end
            return (x.result.delta or 0) > (y.result.delta or 0)
        end)
        local cr, cg, cb = addon.ClassColor(grp.alt.class)
        local name = AltDisplayName(grp.altKey)
        addHeader(("%s  (%d)"):format(name, #grp.items),
            cr, cg, cb, name, grp.items, grp.altKey)
        for _, d in ipairs(grp.items) do
            suggestions[#suggestions + 1] = d
        end
    end
    -- Hold slot budget: an alt only needs one item per slot held for later
    -- (two for rings/trinkets), so the best copy stays a hold and the rest
    -- fall to Left over instead of repeating the same advice per copy.
    -- The budget keys on the TARGET SLOT, not the invType: a 1H mace and a
    -- 2H staff both fill the mainhand and compete for the same budget.
    -- Unique-Equipped items are wearable once per alt, so their key is the
    -- itemID with budget 1: two DIFFERENT unique trinkets still hold side
    -- by side, a duplicate never does
    local holdBudget = {}
    local keptHolds, spareHolds = {}, {}
    table.sort(holds, function(a, b)
        if (a.item.itemLevel or 0) ~= (b.item.itemLevel or 0) then
            return (a.item.itemLevel or 0) > (b.item.itemLevel or 0)
        end
        return (a.rowKey or "") < (b.rowKey or "")
    end)
    for _, s in ipairs(holds) do
        local dual = s.item.invType == "INVTYPE_FINGER"
            or s.item.invType == "INVTYPE_TRINKET"
        local budget = dual and not s.item.uniqueEquipped and 2 or 1
        local uniqueID = s.item.uniqueEquipped
            and (s.item.itemID or addon.GetItemID(s.item.itemLink)) or nil
        -- cascade: the first hold-capable alt with budget remaining gets
        -- the copy; only when every ranked alt is exhausted does it pool
        -- as a spare. Candidates carry their own verdict kind: the summary
        -- tail and row color must describe the ASSIGNED alt, not the
        -- original advice holder
        local assigned
        for _, e in ipairs(s.holdAlts
                or { { key = s.hold.key, kind = s.hold.kind,
                    specs = s.hold.respecSpecs } }) do
            local budgetKey
            if uniqueID then
                budgetKey = (e.key or "?") .. ":unique:" .. uniqueID
            else
                budgetKey = (e.key or "?") .. ":"
                    .. (addon.TargetSlotFor(s.item) or s.item.invType or "?")
            end
            holdBudget[budgetKey] = holdBudget[budgetKey] or 0
            if holdBudget[budgetKey] < budget then
                holdBudget[budgetKey] = holdBudget[budgetKey] + 1
                assigned = e
                break
            end
        end
        if assigned then
            if assigned.key ~= s.hold.key then
                s.hold.key = assigned.key
                s.hold.kind = assigned.kind or s.hold.kind
                s.hold.respecSpecs = assigned.specs
                s.hold.reason = assigned.reason or s.hold.reason
                s.hold.summary = addon.HoldSummary(assigned.key, s.hold.kind,
                    assigned.specs)
            end
            keptHolds[#keptHolds + 1] = s
        else
            spareHolds[#spareHolds + 1] = {
                kind = "leftover", item = s.item, rowKey = s.rowKey,
                dupNote = "Spare copy - a hold for this slot already exists",
            }
        end
    end
    for _, s in ipairs(spareHolds) do
        leftover[#leftover + 1] = s
    end
    holds = keptHolds

    table.sort(selfkeep, function(a, b)
        local sa, sb = SlotRank(addon.RowSlot(a)), SlotRank(addon.RowSlot(b))
        if sa ~= sb then
            return sa < sb
        end
        return (a.result.delta or 0) > (b.result.delta or 0)
    end)
    if #selfkeep > 0 then
        addHeader("Keep for yourself", 0.3, 1, 0.3, "keep for yourself",
            selfkeep, myKey)
        for _, s in ipairs(selfkeep) do
            suggestions[#suggestions + 1] = s
        end
    end
    -- hold sections: split by the assigned alt's blocker kind, then segment
    -- per alt like the mailable groups. The level-vs-load-out split reads
    -- the assigned blocker reason (same coupling as HoldFixHint); newalt
    -- rows ("roll a <class>") fold into the respec section without an alt
    -- segment of their own
    local function HoldRowLess(a, b)
        local sa, sb = SlotRank(addon.RowSlot(a)), SlotRank(addon.RowSlot(b))
        if sa ~= sb then
            return sa < sb
        end
        if (a.item.itemLevel or 0) ~= (b.item.itemLevel or 0) then
            return (a.item.itemLevel or 0) > (b.item.itemLevel or 0)
        end
        return (a.rowKey or "") < (b.rowKey or "")
    end
    local function EmitHoldSection(title, label, kind, levelOnly)
        local sectionRows, newaltRows = {}, {}
        for _, s in ipairs(holds) do
            if kind == "respec" then
                if s.hold.kind == "respec" then
                    sectionRows[#sectionRows + 1] = s
                elseif s.hold.kind == "newalt" then
                    newaltRows[#newaltRows + 1] = s
                end
            elseif s.hold.kind == "eventually"
                and addon.HoldBlockerIsLevel(s.hold.reason) == levelOnly then
                sectionRows[#sectionRows + 1] = s
            end
        end
        if #sectionRows == 0 and #newaltRows == 0 then
            return
        end
        table.sort(sectionRows, HoldRowLess)
        table.sort(newaltRows, HoldRowLess)
        local allRows = {}
        for _, s in ipairs(sectionRows) do
            allRows[#allRows + 1] = s
        end
        for _, s in ipairs(newaltRows) do
            allRows[#allRows + 1] = s
        end
        -- group by assigned alt; the alt header's envelope loots that
        -- alt's held attachments, the section header carries no envelope
        local byAlt, groups = {}, {}
        for _, s in ipairs(sectionRows) do
            local key = s.hold.key or "?"
            local grp = byAlt[key]
            if not grp then
                grp = { key = key, alt = GearFallDB.alts[key], items = {} }
                byAlt[key] = grp
                groups[#groups + 1] = grp
            end
            grp.items[#grp.items + 1] = s
        end
        table.sort(groups, function(a, b)
            local ta = a.alt and a.alt.prioTier or 9999
            local tb = b.alt and b.alt.prioTier or 9999
            if ta ~= tb then
                return ta < tb
            end
            return a.key < b.key
        end)
        local c = addon.KIND_COLOR[kind] or addon.KIND_COLOR.eventually
        addHeader(title, c[1], c[2], c[3], label, allRows)
        for _, grp in ipairs(groups) do
            local gr, gg, gb = addon.ClassColor(grp.alt and grp.alt.class)
            addHeader(("%s  (%d)"):format(AltDisplayName(grp.key), #grp.items),
                gr, gg, gb, AltDisplayName(grp.key), grp.items, grp.key)
            for _, s in ipairs(grp.items) do
                suggestions[#suggestions + 1] = s
            end
        end
        for _, s in ipairs(newaltRows) do
            suggestions[#suggestions + 1] = s
        end
    end
    EmitHoldSection("Level up required", "level-up required",
        "eventually", true)
    EmitHoldSection("Load-out swap required", "load-out swap required",
        "eventually", false)
    EmitHoldSection("Respec required", "respec required", "respec")
    table.sort(leftover, function(a, b)
        local sa, sb = SlotRank(addon.RowSlot(a)), SlotRank(addon.RowSlot(b))
        if sa ~= sb then
            return sa < sb
        end
        if (a.item.itemLevel or 0) ~= (b.item.itemLevel or 0) then
            return (a.item.itemLevel or 0) > (b.item.itemLevel or 0)
        end
        return (a.rowKey or "") < (b.rowKey or "")
    end)
    if #leftover > 0 then
        addHeader("Left over", 0.6, 0.6, 0.6, "left over", leftover)
        for _, s in ipairs(leftover) do
            suggestions[#suggestions + 1] = s
        end
    end
    -- EM omits the section gap above the first heading (Triage.lua "y > 4")
    if suggestions[1] and suggestions[1].kind == "header" then
        suggestions[1].noGap = true
    end
    return suggestions
end

-------------------------------------------------------------------------------
-- Per-alt verdicts (Sendable tab's "view from <alt>")
-------------------------------------------------------------------------------

-- Per-alt verdicts for the Sendable tab's "view from <alt>" mode: every
-- scanned bag item classified for one alt, reusing the eligibility gates'
-- own reason strings plus the draft's priority information.
local VERDICT_ORDERS = {
    planned = 1, priority = 2, hold = 3, usable = 4, blocked = 5,
    generic = 6,
}
local VERDICT_COLORS = {
    planned = { 0.3, 1, 0.3 },
    priority = { 1, 0.82, 0 },
    usable = { 0.7, 0.7, 0.75 },
    hold = { 1, 0.9, 0.4 },
    blocked = { 1, 0.45, 0.4 },
    generic = { 0.55, 0.55, 0.6 },
}

function addon.ItemVerdictsForAlt(altKey)
    local alt = altKey and GearFallDB.alts[altKey] or nil
    if altKey and not alt then
        return nil
    end
    local draft = addon.BuildDistributionSuggestions()
    local recipientOf, winnerResultOf, holdTextOf = {}, {}, {}
    for _, s in ipairs(draft) do
        if s.rowKey then
            if s.kind == "upgrade" or s.kind == "selfkeep" then
                recipientOf[s.rowKey] = s.altKey
                winnerResultOf[s.rowKey] = s.result
            elseif s.kind == "hold" then
                recipientOf[s.rowKey] = "hold"
                holdTextOf[s.rowKey] = s.hold.summary or s.hold.reason or "?"
            elseif s.kind == "leftover" then
                recipientOf[s.rowKey] = "leftover"
            end
        end
    end
    local myKey = addon.PlayerKey and addon.PlayerKey()
    local verdicts = {}
    for _, info in ipairs(addon.ScanEligibleItems()) do
        if info.cached and info.eligible and info.isGear then
            local key = info.spot
                or ("%d:%d"):format(info.bagID or 0, info.slotIndex or 0)
            local recipient = recipientOf[key]
            local bucket, text
            if not alt then
                -- "All characters" view: the draft's disposition for the
                -- item as a whole, or the generic considered-marker
                if recipient == "hold" then
                    bucket = "hold"
                    text = holdTextOf[key]
                elseif recipient == "leftover" then
                    bucket = "usable"
                    text = "Not planned (spare copy)"
                elseif recipient then
                    bucket = "planned"
                    if recipient == myKey then
                        text = "Keep: " .. addon.FormatDelta(winnerResultOf[key])
                    else
                        text = "Upgrade for " .. AltDisplayName(recipient)
                            .. " (" .. addon.FormatDelta(winnerResultOf[key]) .. ")"
                    end
                else
                    bucket = "generic"
                    text = "All characters considered"
                end
            else
                local myScore = addon.ScoreItemForAlt(info, alt)
                local myDelta = myScore.eligible and (myScore.delta or 0) or nil
                if recipient == altKey then
                    bucket = "planned"
                    text = "Planned: " .. addon.FormatDelta(myScore)
                elseif not myScore.eligible then
                    -- the viewed alt's own gates answer "why not for you"
                    if myScore.verdict == "no" then
                        bucket = "blocked"
                    else
                        -- eventually/respec: this alt is the future user
                        bucket = "hold"
                    end
                    text = myScore.reason
                        or (recipient == "hold" and holdTextOf[key]) or "?"
                elseif myDelta and myDelta <= 0 then
                    -- the direct answer for the viewed alt: wearable, but
                    -- worse than what they already have - who wins the draft
                    -- is moot
                    bucket = "usable"
                    text = ("Item is not an upgrade (%s)"):format(
                        addon.FormatDelta(myScore))
                elseif recipient == "leftover" then
                    bucket = "usable"
                    text = "Not planned (spare copy)"
                elseif recipient then
                    bucket = "priority"
                    text = ("Priority: %s gets it (%s vs your %s)"):format(
                        AltDisplayName(recipient),
                        addon.FormatDelta(winnerResultOf[key] or {}),
                        addon.FormatDelta(myScore))
                else
                    -- an upgrade, undrafted: a right-click skipped item
                    bucket = "usable"
                    text = "Usable but not planned ("
                        .. addon.FormatDelta(myScore) .. ")"
                end
            end
            local color = VERDICT_COLORS[bucket]
            verdicts[key] = {
                bucket = bucket, text = text, order = VERDICT_ORDERS[bucket],
                r = color[1], g = color[2], b = color[3],
            }
        end
    end
    return verdicts
end

-------------------------------------------------------------------------------
-- Bag tooltip advice: hovering unbound gear in any container shows the same
-- advice the Distribution window gives, so you never have to open it to know
-- what a BoE is worth
-------------------------------------------------------------------------------

if hooksecurefunc then
    hooksecurefunc(GameTooltip, "SetBagItem",
        function(tooltip, bagID, slotIndex)
        if tooltip ~= GameTooltip then
            return
        end
        -- the Sendable grid's verdict tooltips pause this generic advice:
        -- their per-alt verdict is the answer in that context
        if addon._bagAdvicePaused then
            return
        end
        local containerItem = C_Container.GetContainerItemInfo(bagID, slotIndex)
        if not containerItem or not containerItem.hyperlink then
            return
        end
        -- GetBindInfo is the sendable-scan gate: soulbound copies and
        -- non-gear stay silent here
        local info = addon.GetBindInfo(containerItem.hyperlink, bagID, slotIndex)
        if not info.eligible then
            return
        end
        local matches, advice = addon.FindBestAltsForItem(info)
        local myKey = addon.PlayerKey()
        local selfMatch, others = nil, {}
        for _, m in ipairs(matches) do
            if m.key == myKey then
                selfMatch = m
            else
                others[#others + 1] = m
            end
        end
        if selfMatch then
            GameTooltip:AddLine(("Upgrade for you  (%s)"):format(
                addon.FormatDelta(selfMatch.result)), 0.3, 1, 0.3, true)
            if #others > 0 then
                local lead = ("Also an upgrade for %s"):format(
                    AltDisplayName(others[1].key))
                if #others > 1 then
                    lead = lead .. (" and %d more"):format(#others - 1)
                end
                GameTooltip:AddLine(lead, 0.8, 0.8, 0.8, true)
            end
        elseif others[1] then
            GameTooltip:AddLine(("Upgrade for %s  (%s)"):format(
                AltDisplayName(others[1].key), addon.FormatDelta(others[1].result)),
                0.3, 1, 0.3, true)
            if #others > 1 then
                GameTooltip:AddLine(("%d other alt(s) would also upgrade")
                    :format(#others - 1), 0.8, 0.8, 0.8, true)
            end
        elseif advice.hold then
            local kind = advice.hold.kind
            if kind == "newalt" then
                GameTooltip:AddLine(advice.hold.reason
                    or "Roll one! No alt you have can use this.",
                    1, 0.82, 0, true)
            else
                -- same shape as the Distribution window's hold tooltip:
                -- the named alt's fix hint, then the concrete blocker
                local who = advice.hold.key ~= "future alt"
                    and advice.hold.key ~= "?"
                    and AltDisplayName(advice.hold.key) or nil
                local c = addon.KIND_COLOR[kind] or addon.KIND_COLOR.eventually
                GameTooltip:AddLine((who and (who .. ": ") or "")
                    .. addon.HoldFixHint(kind, advice.hold.respecSpecs,
                        advice.hold.reason) .. ".",
                    c[1], c[2], c[3], true)
                if advice.hold.reason then
                    GameTooltip:AddLine(("Blocked right now: %s")
                        :format(advice.hold.reason), 0.8, 0.8, 0.8, true)
                end
            end
        end
        -- usableButWorse / no-advice items stay silent: nothing to act on
    end)
end

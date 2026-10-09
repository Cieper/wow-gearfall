local _, addon = ...

-- Distribution: the mailbox-docked suggestion window (the EM Triage shape
-- transplanted onto GearFall's verdict engine). Left column = the sendable
-- item in our bags, right column = the advice (mail to X, hold, roll one).
-- "Mail All Upgrades" runs one Blizzard letter per recipient alt, positive
-- deltas only - "usable but not an upgrade" stays listed but never ships.

local MAIL_TIMEOUT = 5
local HISTORY_LIMIT = 200
local SUBJECT = "GearFall"

local distFrame
local distProvider

local KIND_COLOR = {
    eventually = { 1, 1, 0.3 },
    respec = { 0.7, 0.7, 0.75 },
    newalt = { 1, 0.82, 0 },
}

-------------------------------------------------------------------------------
-- Suggestions
-------------------------------------------------------------------------------

-- realm-aware display names (Util.lua): same realm -> bare name
local AltDisplayName = addon.AltDisplayName

local function ClassColor(token)
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

local function FormatDelta(result)
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
local function RowSlot(s)
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
            -- "mail:1:2" for inbox attachments)
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
    local function addHeader(title, r, g, b, label, items, altKey)
        local rowKeys, mailCount = {}, 0
        for _, it in ipairs(items or {}) do
            if it.rowKey then
                rowKeys[#rowKeys + 1] = it.rowKey
            end
            if it.item and it.item.location == "mail" then
                mailCount = mailCount + 1
            end
        end
        suggestions[#suggestions + 1] = {
            kind = "header", title = title, r = r, g = g, b = b,
            label = label, rowKeys = rowKeys, mailCount = mailCount,
            altKey = altKey,
        }
    end

    for _, grp in ipairs(groups) do
        table.sort(grp.items, function(x, y)
            local sx, sy = SlotRank(RowSlot(x)), SlotRank(RowSlot(y))
            if sx ~= sy then
                return sx < sy
            end
            return (x.result.delta or 0) > (y.result.delta or 0)
        end)
        local cr, cg, cb = ClassColor(grp.alt.class)
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
    -- 2H staff both fill the mainhand and compete for the same budget
    local holdBudget = {}
    local keptHolds, spareHolds = {}, {}
    table.sort(holds, function(a, b)
        if (a.item.itemLevel or 0) ~= (b.item.itemLevel or 0) then
            return (a.item.itemLevel or 0) > (b.item.itemLevel or 0)
        end
        return (a.rowKey or "") < (b.rowKey or "")
    end)
    for _, s in ipairs(holds) do
        local budget = (s.item.invType == "INVTYPE_FINGER"
            or s.item.invType == "INVTYPE_TRINKET") and 2 or 1
        -- cascade: the first hold-capable alt with budget remaining gets
        -- the copy; only when every ranked alt is exhausted does it pool
        -- as a spare. Candidates carry their own verdict kind: the summary
        -- tail and row color must describe the ASSIGNED alt, not the
        -- original advice holder
        local assigned
        for _, e in ipairs(s.holdAlts
                or { { key = s.hold.key, kind = s.hold.kind,
                    specs = s.hold.respecSpecs } }) do
            local budgetKey = (e.key or "?") .. ":"
                .. (addon.TargetSlotFor(s.item) or s.item.invType or "?")
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
        local sa, sb = SlotRank(RowSlot(a)), SlotRank(RowSlot(b))
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
        local sa, sb = SlotRank(RowSlot(a)), SlotRank(RowSlot(b))
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
        local c = KIND_COLOR[kind] or KIND_COLOR.eventually
        addHeader(title, c[1], c[2], c[3], label, allRows)
        for _, grp in ipairs(groups) do
            local gr, gg, gb = ClassColor(grp.alt and grp.alt.class)
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
        local sa, sb = SlotRank(RowSlot(a)), SlotRank(RowSlot(b))
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
-- Mail plan + pipeline
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
                        text = "Keep: " .. FormatDelta(winnerResultOf[key])
                    else
                        text = "Upgrade for " .. AltDisplayName(recipient)
                            .. " (" .. FormatDelta(winnerResultOf[key]) .. ")"
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
                    text = "Planned: " .. FormatDelta(myScore)
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
                        FormatDelta(myScore))
                elseif recipient == "leftover" then
                    bucket = "usable"
                    text = "Not planned (spare copy)"
                elseif recipient then
                    bucket = "priority"
                    text = ("Priority: %s gets it (%s vs your %s)"):format(
                        AltDisplayName(recipient),
                        FormatDelta(winnerResultOf[key] or {}),
                        FormatDelta(myScore))
                else
                    -- an upgrade, undrafted: a right-click skipped item
                    bucket = "usable"
                    text = "Usable but not planned ("
                        .. FormatDelta(myScore) .. ")"
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

function addon.PlanDistributionMail(suggestions)
    local byRecipient, recipients = {}, {}
    for _, s in ipairs(suggestions or {}) do
        -- mailbox attachments cannot be picked up for mailing: they are
        -- scan-only candidates the user must claim manually first
        if s.kind == "upgrade" and s.item.location ~= "mail" then
            local recipient = addon.MailRecipientFor(s.altKey)
            if not byRecipient[recipient] then
                recipients[#recipients + 1] = recipient
                byRecipient[recipient] = {}
            end
            table.insert(byRecipient[recipient], s)
        end
    end
    table.sort(recipients)
    return { recipients = recipients, byRecipient = byRecipient }
end

function addon.LogSendHistory(s, recipient)
    table.insert(GearFallDB.sendHistory, {
        t = GetServerTime(),
        name = s.item.name,
        itemLink = s.item.itemLink,
        quality = s.item.quality,
        to = recipient,
        delta = s.result and s.result.delta,
    })
    while #GearFallDB.sendHistory > HISTORY_LIMIT do
        table.remove(GearFallDB.sendHistory, 1)
    end
end

local function MailboxOpen()
    return addon._mailboxOpen == true
end

-- any mailbox pipeline in flight (the loot sequencer, a send run, or the
-- equip-arrived sequencer): event-driven rescans stand down while one is
-- active - a take per 0.15s means MAIL_INBOX_UPDATE/BAG_UPDATE_DELAYED
-- bursts, and equipping bursts BAG_UPDATE/PLAYER_EQUIPMENT_CHANGED; in all
-- cases rebuilding the whole draft mid-run is wasted work the run's own
-- final refresh makes unnecessary
function addon.MailRunActive()
    return (addon._mailLooting or addon._distSending or addon._equipping)
        and true or false
end

local function WaitForMailResult(onResult)
    local frame = CreateFrame("Frame")
    local handled = false
    local timer
    local function finish(ok)
        if handled then
            return
        end
        handled = true
        timer:Cancel()
        frame:UnregisterAllEvents()
        onResult(ok)
    end
    timer = C_Timer.NewTimer(MAIL_TIMEOUT, function() finish(false) end)
    frame:RegisterEvent("MAIL_SUCCESS")
    frame:RegisterEvent("MAIL_FAILED")
    frame:SetScript("OnEvent", function(_, event)
        finish(event == "MAIL_SUCCESS")
    end)
end

-- One Blizzard mail per batch of ATTACHMENTS_MAX_SEND (12). The attach dance
-- is the EM-proven one: PickupContainerItem + ClickSendMailItemButton works
-- even when Postal/TSM/Baganator replace MailFrame, because every call here
-- drives MAILBOX state, not any addon's frames. Do NOT gate on MailFrame.
function addon.ExecuteMailForRecipient(recipient, entries, onDone)
    local mailable = {}
    for _, s in ipairs(entries) do
        local loc = ItemLocation:CreateFromBagAndSlot(s.item.bagID, s.item.slotIndex)
        if loc and loc:IsValid() and C_Item.DoesItemExist(loc)
            and not C_Item.IsLocked(loc) then
            mailable[#mailable + 1] = s
        end
    end
    if #mailable == 0 then
        addon.Print(("Nothing mailable for %s (locked or gone)"):format(recipient))
        onDone(0)
        return
    end

    local batches, batch = {}, {}
    for _, s in ipairs(mailable) do
        batch[#batch + 1] = s
        if #batch >= (ATTACHMENTS_MAX_SEND or 12) then
            batches[#batches + 1] = batch
            batch = {}
        end
    end
    if #batch > 0 then
        batches[#batches + 1] = batch
    end

    local totalSent = 0
    local function SendNextBatch(batchIndex)
        if batchIndex > #batches then
            onDone(totalSent)
            return
        end
        if not MailboxOpen() then
            addon.Print(("Mailbox closed after %d item(s) mailed"):format(totalSent))
            onDone(totalSent)
            return
        end

        ClearSendMail()
        -- cosmetic sync with Blizzard's own send UI; nil-guarded because mail
        -- replacement addons may not keep those edit boxes alive at all
        if SendMailNameEditBox then
            SendMailNameEditBox:SetText(recipient)
        end
        if SendMailSubjectEditBox then
            SendMailSubjectEditBox:SetText(SUBJECT)
        end

        local attachedEntries = {}
        for _, s in ipairs(batches[batchIndex]) do
            -- defense in depth: the plan already filters mail attachments
            -- out (they cannot be picked up), this guard keeps a stale
            -- batch from ever trying
            if s.item.location == "mail" then
                SendNextBatch(batchIndex + 1)
                return
            end
            ClearCursor()
            C_Container.PickupContainerItem(s.item.bagID, s.item.slotIndex)
            if CursorHasItem() then
                ClickSendMailItemButton()
                if CursorHasItem() then
                    -- attach refused (full, bound raced us, wrong state):
                    -- drop it back into the bag rather than leave it on cursor
                    ClearCursor()
                else
                    attachedEntries[#attachedEntries + 1] = s
                end
            end
        end
        if #attachedEntries == 0 then
            SendNextBatch(batchIndex + 1)
            return
        end

        local hasAnyAttachment = false
        for i = 1, (ATTACHMENTS_MAX_SEND or 12) do
            if GetSendMailItem(i) then
                hasAnyAttachment = true
                break
            end
        end
        if not hasAnyAttachment then
            addon.Print(("Mail to %s aborted: nothing attached"):format(recipient))
            onDone(totalSent)
            return
        end

        WaitForMailResult(function(ok)
            if ok then
                totalSent = totalSent + #attachedEntries
                for _, s in ipairs(attachedEntries) do
                    addon.LogSendHistory(s, recipient)
                    -- the alt now has a projected upgrade in that slot that
                    -- no snapshot can see yet; score future candidates
                    -- against it until their own capture proves otherwise
                    local alt = GearFallDB.alts[s.altKey]
                    if alt and s.result and s.result.slotID then
                        alt.incoming = alt.incoming or {}
                        alt.incoming[s.result.slotID] = {
                            itemLink = s.item.itemLink,
                            itemLevel = s.item.itemLevel,
                            name = s.item.name,
                            quality = s.item.quality,
                            mailIncoming = true,
                            t = GetServerTime(),
                        }
                    end
                end
                if addon.RefreshHistoryUI then
                    addon.RefreshHistoryUI()
                end
                C_Timer.After(0.3, function()
                    SendNextBatch(batchIndex + 1)
                end)
            else
                addon.Print(("Mail to %s failed or timed out after %d item(s)")
                    :format(recipient, totalSent))
                onDone(totalSent)
            end
        end)

        SendMail(recipient, SUBJECT, "")
    end

    SendNextBatch(1)
end

-- per-recipient confirm dialog, defined below
local ShowMailPerCharDialog

function addon.MailAllUpgrades()
    if not MailboxOpen() then
        addon.Print("Open a mailbox first to send")
        return
    end
    if addon.MailRunActive() then
        return
    end
    local plan = addon.PlanDistributionMail(
        addon._distSuggestions or addon.BuildDistributionSuggestions())
    local total = 0
    for _, name in ipairs(plan.recipients) do
        total = total + #plan.byRecipient[name]
    end
    if total == 0 then
        addon.Print("No upgrades to mail")
        return
    end

    -- EM flow: one confirmation dialog per recipient, Send/Skip/Cancel each
    addon._distSending = true
    addon.UpdateDistMailBtn()
    ShowMailPerCharDialog(plan, plan.recipients, 1, 0)
end

-------------------------------------------------------------------------------
-- Per-recipient mail confirmation dialog (EM's ShowMailPerCharDialog)
-------------------------------------------------------------------------------

local function FinalizeMailRun(totalSent)
    addon._distSending = nil
    addon.UpdateDistMailBtn()
    if totalSent > 0 then
        addon.Print(("Mailed %d item(s)"):format(totalSent))
    end
    addon.RefreshDistribution(true)
    -- the sent items left the bags: the Sendable grid (if open) gets the
    -- end-of-run truth here, since its own events stood down mid-run
    if addon.RefreshSendableTab then
        addon.RefreshSendableTab()
    end
end

-- CloseSpecialWindows (ESC) hides every visible UISpecialFrames entry in one
-- pass, so while the per-recipient dialog is up the mailbox comes OFF that
-- stack; hiding the dialog puts it back, keeping ESC single-window each time
local function KeepMailboxOffEsc()
    local f = GearFallMailDialog
    local i = tIndexOf(UISpecialFrames, "MailFrame")
    if i and not f._escMailPos then
        table.remove(UISpecialFrames, i)
        f._escMailPos = i
    end
end

local function PutMailboxBackOnEsc()
    local f = GearFallMailDialog
    if f._escMailPos then
        table.insert(UISpecialFrames, f._escMailPos, "MailFrame")
        f._escMailPos = nil
    end
end

ShowMailPerCharDialog = function(plan, recipients, index, totalSent)
    local f = GearFallMailDialog
    if not f._initialized then
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)
        f.ScrollFrame:SetScrollChild(f.ScrollFrame.Content)
        -- ESC closes THIS dialog first (topmost registered frame), not the
        -- mailbox underneath; the OnHide handler finalizes the run
        if not tContains(UISpecialFrames, "GearFallMailDialog") then
            tinsert(UISpecialFrames, "GearFallMailDialog")
        end
        f._initialized = true
    end
    f.TitleText:SetText("GearFall - Mail")
    f:SetHeight(400)

    -- walked away between recipients / everything processed
    if not MailboxOpen() or index > #recipients then
        FinalizeMailRun(totalSent)
        return
    end

    local recipient = recipients[index]
    local items = plan.byRecipient[recipient]
    local count = #items

    if f._widgets then
        for _, w in ipairs(f._widgets) do
            w:Hide()
            if w.SetScript then
                w:SetScript("OnEnter", nil)
                w:SetScript("OnLeave", nil)
            end
        end
    end
    f._widgets = {}
    local function Track(obj)
        f._widgets[#f._widgets + 1] = obj
        return obj
    end

    local content = f.ScrollFrame.Content
    content:SetWidth(f.ScrollFrame:GetWidth())

    local first = items[1]
    local cr, cg, cb = ClassColor(first and first.alt and first.alt.class)
    local displayName = first and AltDisplayName(first.altKey) or recipient

    local y = 8
    local hdr = Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    hdr:SetText(("|cffffcc00Sending Mail %d of %d|r"):format(index, #recipients))
    y = y + 26

    local toFs = Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    toFs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    toFs:SetText(("|cffffffffTo:  |r|cff%02x%02x%02x%s|r"):format(
        cr * 255, cg * 255, cb * 255, displayName))
    y = y + 26 + 6

    local subFs = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
    subFs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    subFs:SetText(("%d %s:"):format(count, count == 1 and "item" or "items"))
    y = y + 18 + 4

    for _, s in ipairs(items) do
        local btn = Track(CreateFrame("Button", nil, content))
        btn:SetSize(content:GetWidth() - 16, 16)
        btn:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetAllPoints()
        fs:SetJustifyH("LEFT")
        local qc = ITEM_QUALITY_COLORS[s.item.quality]
        fs:SetText("  " .. (qc and qc.hex or "|cffffffff")
            .. (s.item.name or "?") .. "|r")
        btn:SetScript("OnEnter", function(b)
            GameTooltip:SetOwner(b, "ANCHOR_CURSOR_RIGHT")
            if s.item.itemLink then
                GameTooltip:SetHyperlink(s.item.itemLink)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        y = y + 16
    end
    content:SetHeight(y + 10)

    if f._btns then
        for _, b in ipairs(f._btns) do
            b:Hide()
        end
    end
    f._btns = {}

    local sendBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sendBtn:SetSize(100, 28)
    sendBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 14)
    sendBtn:SetText("Send")
    sendBtn:SetScript("OnClick", function()
        f._advancing = true
        f:Hide()
        -- mailbox may have closed while the dialog was up
        if not MailboxOpen() then
            FinalizeMailRun(totalSent)
            return
        end
        addon.ExecuteMailForRecipient(recipient, items, function(done)
            ShowMailPerCharDialog(plan, recipients, index + 1, totalSent + done)
        end)
    end)
    f._btns[1] = sendBtn

    local skipBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    skipBtn:SetSize(100, 28)
    skipBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    skipBtn:SetText("Skip")
    skipBtn:SetScript("OnClick", function()
        f._advancing = true
        f:Hide()
        ShowMailPerCharDialog(plan, recipients, index + 1, totalSent)
    end)
    f._btns[2] = skipBtn

    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelBtn:SetSize(100, 28)
    cancelBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function()
        f._advancing = true
        f:Hide()
        FinalizeMailRun(totalSent)
    end)
    f._btns[3] = cancelBtn

    -- X button / ESC: any hide that is not one of our own transitions
    -- finalizes the run
    f:SetScript("OnHide", function(fr)
        PutMailboxBackOnEsc()
        if fr._advancing then
            fr._advancing = nil
            return
        end
        FinalizeMailRun(totalSent)
    end)

    KeepMailboxOffEsc()
    f:Show()
end

-------------------------------------------------------------------------------
-- Mail loot: claim inbox attachments by draft stage ("Loot from Mail").
-- The draft already classifies every attachment (Scan.lua's second
-- inventory); the envelope rows just used to end at "claim it, then
-- rescan". One click loots one stage - upgrades, then future upgrades,
-- then respec holds - putting the items in bags where the normal send
-- pipeline can mail them out. Left over attachments are deliberately
-- never looted: they stay in the mailbox and return to their senders.
-------------------------------------------------------------------------------

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
    if not MailboxOpen() then
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

function addon.UpdateDistLootBtn()
    local btn = distFrame and distFrame.MailLootButton
    if not btn then
        return
    end
    local text, reason, enabled = addon.MailLootButtonState()
    btn:SetText(text)
    btn._disabledReason = reason
    if enabled then
        btn:Enable()
    else
        btn:Disable()
    end
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
    if not MailboxOpen() then
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
        if not MailboxOpen() then
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
            local slotID = RowSlot(s)
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

function addon.UpdateDistEquipBtn()
    local btn = distFrame and distFrame.EquipArrivedButton
    if not btn then
        return
    end
    local text, reason, enabled = addon.EquipArrivedButtonState()
    btn:SetShown(text ~= nil)
    if not text then
        return
    end
    btn:SetText(text)
    btn._disabledReason = reason
    if enabled then
        btn:Enable()
    else
        btn:Disable()
    end
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
    if #lootPlan > 0 and MailboxOpen()
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

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------

GearFallDistributionRowMixin = {}

function GearFallDistributionRowMixin:OnLoad()
    -- EM triage row anatomy: item name owns the left half, the advice text
    -- is left-aligned inside the right half (so both columns read from a
    -- shared midline), separated by a divider that only shows on hover
    self.nameFs = self:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.nameFs:SetPoint("LEFT", self, "LEFT", 2, 0)
    self.nameFs:SetJustifyH("LEFT")
    self.nameFs:SetWordWrap(false)
    self.nameFs:SetNonSpaceWrap(false)
    self.nameFs:SetMaxLines(1)
    self.actionFs = self:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.actionFs:SetPoint("RIGHT", self, "RIGHT", -4, 0)
    self.actionFs:SetJustifyH("LEFT")
    self.actionFs:SetWordWrap(false)
    self.actionFs:SetNonSpaceWrap(false)
    self.actionFs:SetMaxLines(1)
    -- slot column: right-aligned against the midline, between name and advice
    self.slotFs = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.slotFs:SetPoint("RIGHT", self, "CENTER", -14, 0)
    self.slotFs:SetJustifyH("RIGHT")
    self.slotFs:SetTextColor(0.65, 0.65, 0.65)
    self.slotFs:SetWordWrap(false)
    self.slotFs:SetMaxLines(1)
    -- mail badge: end-of-line marker for rows whose item is still an inbox
    -- attachment (the minimap's own envelope atlas); they cannot be attached
    -- to outgoing mail, so the user must claim them first
    self.mailIcon = self:CreateTexture(nil, "OVERLAY")
    self.mailIcon:SetSize(12, 12)
    self.mailIcon:SetPoint("RIGHT", self, "RIGHT", -4, 0)
    self.mailIcon:SetAtlas("ui-hud-minimap-mail-up")
    self.mailIcon:Hide()
    -- the envelope is also a claim button: a character header's envelope
    -- loots every attachment drafted for that character, an item row's
    -- envelope loots exactly that attachment. No loot semantics live
    -- here - the plans come from the addon namespace, and mid-run clicks
    -- are no-ops via the executor's own mutual-exclusion guard
    self.mailBtn = CreateFrame("Button", nil, self)
    self.mailBtn:SetSize(16, 16)
    self.mailBtn:SetPoint("CENTER", self.mailIcon, "CENTER", 0, 0)
    self.mailBtn:Hide()
    self.mailBtn:SetScript("OnClick", function()
        local data = self._data
        if not data or addon.MailRunActive() then
            return
        end
        local plan
        if data.kind == "header" then
            plan = data.rowKeys and #data.rowKeys > 0
                and addon.LootPlanForRows(data.rowKeys) or nil
        else
            plan = addon.LootPlanForItem(data.rowKey)
        end
        if plan and #plan > 0 then
            -- instant feedback: the envelope disappears the frame you
            -- click it, before the server confirms the takes - the run's
            -- end-of-run refresh re-renders every row anyway, and the
            -- MailRunActive guard makes a mid-run re-click a no-op
            self.mailBtn:Hide()
            self.mailIcon:Hide()
            addon.ExecuteLoot(plan)
        end
    end)
    self.mailBtn:SetScript("OnEnter", function()
        local data = self._data
        GameTooltip:SetOwner(self.mailBtn, "ANCHOR_TOP")
        if data and data.kind == "header" and data.altKey then
            -- the live plan for THIS header's rows: the same rows the
            -- header's own count refers to, never the alt's rows under
            -- other headers
            local count = #addon.LootPlanForRows(data.rowKeys)
            GameTooltip:AddLine(("Loot %s's drafted attachments (%d)")
                :format(AltDisplayName(data.altKey), count), 1, 1, 1, true)
        else
            GameTooltip:AddLine("Loot this attachment from the mail",
                1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    self.mailBtn:SetScript("OnLeave", GameTooltip_Hide)
    self.divider = self:CreateTexture(nil, "OVERLAY")
    self.divider:SetSize(1, 12)
    self.divider:SetColorTexture(1, 1, 1, 0.15)
    self.divider:SetPoint("CENTER", self, "CENTER", -8, 0)
    self.divider:Hide()
    self.headerFs = self:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.headerFs:SetPoint("LEFT", self, "LEFT", 4, 0)
    self.headerFs:SetPoint("RIGHT", self, "RIGHT", -4, 0)
    self.headerFs:SetJustifyH("CENTER")
    self.headerFs:Hide()
    -- EM section furniture: heading text, then the journeys renown divider
    -- under it tinted in the section color (gap/heading/divider heights
    -- mirrored from EM: 12 / 18 / 12, baked into the header element extent)
    self.sep = self:CreateTexture(nil, "ARTWORK")
    self.sep:SetPoint("TOP", self, "TOP", 0, -30)
    self.sep:Hide()
end

function GearFallDistributionRowMixin:Populate(data)
    self._data = data
    if data.kind == "header" then
        self.nameFs:Hide()
        self.actionFs:Hide()
        self.slotFs:Hide()
        self.divider:Hide()
        -- only headers that belong to one character grow a clickable
        -- envelope (and only when they hold inbox attachments); section
        -- and "Left over" headers stay icon-less
        local headerMail = data.altKey ~= nil and (data.mailCount or 0) > 0
        self.mailIcon:SetShown(headerMail)
        self.mailBtn:SetShown(headerMail)
        self.Stripe:SetTexture(nil)
        -- EM geometry exactly (Triage.lua y=4 start, "y > 4" gap rule): the
        -- first heading sits 4px down with no section gap (block 4+18+12),
        -- later ones get the 12px gap (block 12+18+12); the 18px band gets
        -- the renown divider directly below
        local top = data.noGap and 4 or 12
        self.headerFs:ClearAllPoints()
        self.headerFs:SetPoint("TOPLEFT", self, "TOPLEFT", 8, -top)
        self.headerFs:SetPoint("TOPRIGHT", self, "TOPRIGHT", -8, -top)
        self.headerFs:SetHeight(18)
        self.headerFs:SetJustifyV("MIDDLE")
        self.headerFs:Show()
        self.headerFs:SetText(data.title or "")
        self.headerFs:SetTextColor(data.r or 1, data.g or 1, data.b or 1)
        self.sep:ClearAllPoints()
        self.sep:SetPoint("TOP", self, "TOP", 0, -(top + 18))
        self.sep:Show()
        self.sep:SetAtlas("ui-journeys-renown-divider", true)
        self.sep:SetVertexColor(data.r or 1, data.g or 1, data.b or 1, 1.0)
        return
    end
    self.sep:Hide()
    self.headerFs:Hide()
    self.nameFs:Show()
    self.actionFs:Show()
    self.slotFs:Show()
    local nameW = (self:GetWidth() or 440) * 0.52
    self.nameFs:SetWidth(nameW - 68)
    local item = data.item
    -- rows whose item is still in the mailbox show the envelope badge
    -- trailing the advice text (anchored below, once the text is set);
    -- the advice column keeps its full width either way
    local inMail = item.location == "mail"
    self.mailIcon:SetShown(inMail)
    -- the envelope is clickable for every identified draft row; a left
    -- over attachment keeps the badge visual-only (junk is never claimed)
    self.mailBtn:SetShown(inMail and data.kind ~= "leftover")
    self.actionFs:SetWidth((self:GetWidth() or 440) - nameW - 12)

    if data.index and data.index % 2 == 0 then
        self.Stripe:SetAtlas("auctionhouse-rowstripe-1")
    else
        self.Stripe:SetTexture(nil)
    end

    local r, g, b = addon.QualityColor(item.quality)
    local icon = item.icon and
        ("|T%s:14:14:0:0:64:64:5:59:5:59|t "):format(item.icon) or ""
    local qty = (item.quantity or 1) > 1 and (" x%d"):format(item.quantity) or ""
    self.nameFs:SetText(("|cff%02x%02x%02x%s|r%s"):format(
        r * 255 + 0.5, g * 255 + 0.5, b * 255 + 0.5,
        icon .. (item.name or "?"), qty))
    local slotID = RowSlot(data)
    self.slotFs:SetText(slotID and addon.SLOT_NAMES[slotID] or "")

    if data.kind == "upgrade" then
        self.actionFs:SetText(("Upgrade for %s  (%s)"):format(
            AltDisplayName(data.altKey), FormatDelta(data.result)))
        self.actionFs:SetTextColor(0.3, 1, 0.3)
    elseif data.kind == "selfkeep" then
        if data.arrived then
            self.actionFs:SetText(("Arrived - equip it  (%s)"):format(
                FormatDelta(data.result)))
        else
            self.actionFs:SetText(("Keep - equip it  (%s)"):format(
                FormatDelta(data.result)))
        end
        self.actionFs:SetTextColor(0.3, 1, 0.3)
    elseif data.kind == "leftover" then
        self.actionFs:SetText("Left over - nobody still needs it")
        self.actionFs:SetTextColor(0.6, 0.6, 0.6)
    else
        self.actionFs:SetText(data.hold.summary
            or ("Hold: %s"):format(data.hold.reason or "?"))
        local c = KIND_COLOR[data.hold.kind] or KIND_COLOR.eventually
        self.actionFs:SetTextColor(c[1], c[2], c[3])
    end
    if inMail then
        -- trail the badge right after the advice text's last character,
        -- clamped so it can never leave the row
        local x = self.actionFs:GetStringWidth() + 4
        local maxX = (self:GetWidth() or 440) - 16
        if x > maxX then
            x = maxX
        end
        self.mailIcon:ClearAllPoints()
        self.mailIcon:SetPoint("LEFT", self.actionFs, "LEFT", x, 0)
    end
end

function GearFallDistributionRowMixin:OnClick(button)
    local data = self._data
    if not data or button == "RightButton" then
        return
    end
    if data.item and data.item.itemLink then
        HandleModifiedItemClick(data.item.itemLink)
    end
end

function GearFallDistributionRowMixin:OnEnter()
    local data = self._data
    if not data then
        return
    end
    if data.kind == "header" then
        return
    end
    if self.divider then
        self.divider:Show()
    end
    local f = distFrame
    if f and f:IsShown() then
        GameTooltip:SetOwner(f, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("TOPLEFT", f, "TOPRIGHT", 4, 0)
    else
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
    end
    GameTooltip:SetHyperlink(data.item.itemLink)
    if data.kind == "upgrade" or data.kind == "selfkeep" then
        GameTooltip:AddLine(" ")
        local eq = data.result.equippedLink and addon.FormatItem({
            itemLink = data.result.equippedLink,
            name = data.result.equippedName or "item",
            quality = data.result.equippedQuality,
        }) or "|cff808080(empty slot)|r"
        if data.kind == "selfkeep" then
            if data.arrived then
                GameTooltip:AddLine(
                    ("This is the upgrade mailed to you - equip it (%s)"):format(
                    FormatDelta(data.result)), 0.3, 1, 0.3, true)
            else
                GameTooltip:AddLine(("Keep it - equipping beats mailing (%s)")
                    :format(FormatDelta(data.result)), 0.3, 1, 0.3, true)
            end
        elseif data.result.equippedIncoming then
            GameTooltip:AddLine(("Incoming for %s: %s  %s"):format(
                AltDisplayName(data.altKey), eq, FormatDelta(data.result)),
                1, 0.82, 0, true)
        else
            GameTooltip:AddLine(("Replaces %s's %s  %s"):format(
                AltDisplayName(data.altKey), eq, FormatDelta(data.result)),
                0.3, 1, 0.3, true)
        end
        if (data.others or 0) > 0 then
            GameTooltip:AddLine(("%d other alt(s) would also upgrade, "
                .. "but gain less"):format(data.others),
                0.8, 0.8, 0.8, true)
        end
        if data.result.modeNote then
            GameTooltip:AddLine(data.result.modeNote, 1, 0.82, 0, true)
        end
    elseif data.kind == "leftover" then
        GameTooltip:AddLine(" ")
        if data.dupNote then
            GameTooltip:AddLine(data.dupNote, 1, 0.82, 0, true)
        else
            GameTooltip:AddLine(("Every alt this upgrades is already getting "
                .. "something better from this batch. Vendor, disenchant, or "
                .. "mail it yourself."))
        end
    else
        GameTooltip:AddLine(" ")
        local hold = data.hold
        local kind = hold.kind
        -- lead with the hold target's name so the "Blocked right now" line
        -- below reads as THAT character's blocker, not the viewer's
        local who = hold.key ~= "future alt" and hold.key ~= "?"
            and AltDisplayName(hold.key) or nil
        if kind == "newalt" then
            GameTooltip:AddLine(hold.reason
                or "Roll one! No alt you have can use this.", 1, 0.82, 0, true)
        elseif kind == "respec" then
            GameTooltip:AddLine((who and (who .. ": ") or "")
                .. addon.HoldFixHint("respec", hold.respecSpecs) .. ".",
                0.7, 0.7, 0.75, true)
            if hold.reason then
                GameTooltip:AddLine(("Blocked right now: %s"):format(hold.reason),
                    0.8, 0.8, 0.8, true)
            end
        else
            GameTooltip:AddLine((who and (who .. ": ") or "")
                .. addon.HoldFixHint(kind, hold.respecSpecs, hold.reason) .. ".",
                1, 1, 0.3, true)
            if hold.reason then
                GameTooltip:AddLine(("Blocked right now: %s"):format(hold.reason),
                    0.8, 0.8, 0.8, true)
            end
        end
    end
    -- the envelope badge's own explanation, for every kind: mail
    -- attachments cannot be picked up for mailing, the user must claim
    -- them first
    if data.item.location == "mail" then
        GameTooltip:AddLine("In your mailbox - claim it, then rescan to "
            .. "mail it. GearFall cannot attach mail attachments.",
            1, 0.82, 0, true)
    end
    GameTooltip:Show()
end

function GearFallDistributionRowMixin:OnLeave()
    GameTooltip:Hide()
    if self.divider then
        self.divider:Hide()
    end
end

local function DetachToUIParent(f)
    local left, top = f:GetLeft(), f:GetTop()
    if not left or not top then
        return false
    end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    return true
end

function addon.ClampDistributionToScreen()
    if not distFrame then
        return
    end
    local screenH = (UIParent and UIParent:GetHeight()) or 768
    local maxH = math.max(300, math.floor(screenH - 120))
    if distFrame:GetHeight() > maxH then
        distFrame:SetHeight(maxH)
    end
end

-- EM's docking order, trimmed to our one use case: sit right of the mailbox
-- at equal height, then immediately detach to absolute coords. Leaving the
-- relative anchor in place produces the sticky-resize bug (the mail frame
-- reflows mid-drag and yanks us along).
function addon.AnchorDistributionOverlay()
    if not distFrame then
        return
    end
    if addon._distUserMoved then
        addon.ClampDistributionToScreen()
        return
    end
    if MailFrame and MailFrame:IsShown() then
        local screenH = (UIParent and UIParent:GetHeight()) or 768
        local maxH = math.max(300, math.floor(screenH - 120))
        distFrame:SetHeight(math.min(MailFrame:GetHeight(), maxH))
        distFrame:ClearAllPoints()
        distFrame:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 2, 0)
    end
    DetachToUIParent(distFrame)
end

function addon.UpdateDistMailBtn()
    local btn = distFrame and distFrame.MailButton
    if not btn then
        return
    end
    local count = 0
    for _, s in ipairs(addon._distSuggestions or {}) do
        if s.kind == "upgrade" then
            count = count + 1
        end
    end
    if addon._distSending then
        btn:SetText("Mailing...")
        btn._disabledReason = nil
        btn:Disable()
    elseif addon._mailLooting then
        btn:SetText("Mail All Upgrades")
        btn._disabledReason = "Looting the mailbox is in progress"
        btn:Disable()
    elseif addon._equipping then
        btn:SetText("Mail All Upgrades")
        btn._disabledReason = "Equipping arrived items is in progress"
        btn:Disable()
    elseif not MailboxOpen() then
        btn:SetText("Mail All Upgrades")
        btn._disabledReason = "Open a mailbox to send"
        btn:Disable()
    elseif count == 0 then
        btn:SetText("Mail All Upgrades")
        btn._disabledReason = "No upgrades found"
        btn:Disable()
    else
        btn:SetText(("Mail All Upgrades (%d)"):format(count))
        btn._disabledReason = nil
        btn:Enable()
    end
end

-- the window's one-line draft summary: how many upgrades were found and
-- for how many characters (keep-for-yourself rows count - the current
-- character is a roster alt too), and how many are future upgrades
-- (level/load-out/respec holds). Left over rows are deliberately not
-- billed in the headline - the Left over section lists them; they only
-- matter here for the nothing-to-show case. Pure and pinnable.
function addon.DistributionSummaryText(suggestions)
    local upgrades, future, leftover, alts = 0, 0, 0, {}
    for _, s in ipairs(suggestions or {}) do
        if s.kind == "upgrade" or s.kind == "selfkeep" then
            upgrades = upgrades + 1
            if s.altKey then
                alts[s.altKey] = true
            end
        elseif s.kind == "hold" then
            future = future + 1
        elseif s.kind == "leftover" then
            leftover = leftover + 1
        end
    end
    if upgrades == 0 and future == 0 and leftover == 0 then
        return "|cff808080Nothing sendable wants a home right now|r"
    end
    local altCount = 0
    for _ in pairs(alts) do
        altCount = altCount + 1
    end
    local parts = {}
    if upgrades > 0 then
        parts[#parts + 1] = ("|cff66cc66%d upgrade%s|r for %d alt%s found")
            :format(upgrades, upgrades == 1 and "" or "s",
                altCount, altCount == 1 and "" or "s")
    else
        parts[#parts + 1] = "|cff808080No upgrades found|r"
    end
    if future > 0 then
        parts[#parts + 1] = ("|cffffd100%d future upgrade%s|r")
            :format(future, future == 1 and "" or "s")
    end
    return table.concat(parts, ". ")
end

function addon.RefreshDistribution(force)
    addon._distSuggestions = addon.BuildDistributionSuggestions()
    addon.UpdateDistMailBtn()
    addon.UpdateDistLootBtn()
    addon.UpdateDistEquipBtn()
    if not (distFrame and distFrame:IsShown()) then
        return
    end
    distProvider:Flush()
    for i, s in ipairs(addon._distSuggestions) do
        s.index = i
        distProvider:Insert(s)
    end
    distFrame.SummaryBar.SummaryLabel:SetText(
        addon.DistributionSummaryText(addon._distSuggestions))
end

function addon.CreateDistributionFrame()
    if distFrame then
        return distFrame
    end
    local f = _G["GearFallDistributionFrame"]
    if not f then
        return nil
    end
    distFrame = f

    f:SetTitle("GearFall - Distribution")
    if f.SetPortraitToAsset then
        f:SetPortraitToAsset("Interface\\Icons\\inv_misc_enggizmos_30")
    end

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(frame)
        frame:StartMoving()
        GameTooltip:Hide()
    end)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
    end)
    f:HookScript("OnDragStart", function()
        addon._distUserMoved = true
    end)
    f:HookScript("OnHide", function()
        GameTooltip:Hide()
        -- a deliberate close while the mailbox is still open dismisses the
        -- auto-open for this mailbox session: the guaranteed-rescan chain
        -- (and MAIL_INBOX_UPDATE rescans) must not yank the window back up
        if addon._mailboxOpen then
            addon._distDismissed = true
        end
    end)
    f.CloseButton:SetScript("OnClick", function()
        GameTooltip:Hide()
        f:Hide()
    end)
    if not tContains(UISpecialFrames, "GearFallDistributionFrame") then
        table.insert(UISpecialFrames, "GearFallDistributionFrame")
    end

    -- everything below is created once and reused after /reload: the named
    -- XML frame outlives our module-local distFrame, so anything not guarded
    -- would be re-created on top of the previous session's widgets
    if not f.gfBuilt then
        local grip = CreateFrame("Button", nil, f)
        grip:SetSize(16, 16)
        grip:SetPoint("BOTTOMRIGHT", -4, 4)
        grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
        grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
        grip:SetScript("OnMouseDown", function()
            if DetachToUIParent(f) then
                addon._distUserMoved = true
            end
            f:StartSizing("BOTTOMRIGHT")
        end)
        grip:SetScript("OnMouseUp", function()
            f:StopMovingOrSizing()
            addon.ClampDistributionToScreen()
            addon.RefreshDistribution()
        end)

        -- EM's inset look: a darkened tooltip panel hosts the list, with the
        -- scrollbar parked just outside its right edge
        local listPanel = CreateFrame("Frame", nil, f, "TooltipBackdropTemplate")
        listPanel:SetPoint("TOPLEFT", f.SummaryBar, "BOTTOMLEFT", 0, -2)
        listPanel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 52)
        if listPanel.SetBackdropBorderColor then
            listPanel:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.9)
        end
        if listPanel.SetBackdropColor then
            listPanel:SetBackdropColor(0.133, 0.125, 0.114, 0.95)
        end

        -- the scrollbox/scrollbar pair must be built in Lua at runtime (like
        -- every other GearFall list): the same pair declared in XML never
        -- gets its mixin OnLoad pass, and InitScrollBoxListWithScrollBar then
        -- trips over a missing callback registry
        local scrollBox = CreateFrame("Frame", nil, listPanel, "WowScrollBoxList")
        scrollBox:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 6, -6)
        scrollBox:SetPoint("BOTTOMRIGHT", listPanel, "BOTTOMRIGHT", -22, 6)
        local scrollBar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar")
        scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 9, 0)
        scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 9, 4)

        local view = CreateScrollBoxListLinearView()
        view:SetElementInitializer("GearFallDistributionRowTemplate",
            function(row, elementData)
                row:Populate(elementData)
            end)
        view:SetElementExtentCalculator(function(_, elementData)
            -- EM header block: first heading 4 pad + 18 + 12, later ones
            -- 12 gap + 18 + 12 (EM starts content at y=4, gap only if y > 4)
            if elementData and elementData.kind == "header" then
                if elementData.noGap then
                    return 34
                end
                return 42
            end
            return 20
        end)
        ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
        distProvider = CreateDataProvider()
        scrollBox:SetDataProvider(distProvider)

        local rescanBtn = CreateFrame("Button", nil, f, "RefreshButtonTemplate")
        rescanBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -26)
        rescanBtn:SetScript("OnClick", function()
            addon.RefreshDistribution(true)
        end)
        rescanBtn:SetScript("OnEnter", function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_TOP")
            GameTooltip:SetText("Rescan")
            GameTooltip:AddLine("Re-scan bags and re-run every verdict",
                1, 1, 1, true)
            GameTooltip:Show()
        end)
        rescanBtn:SetScript("OnLeave", GameTooltip_Hide)

        local mailBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        mailBtn:SetSize(170, 24)
        mailBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 20)
        mailBtn:SetText("Mail All Upgrades")
        mailBtn._disabledReason = "Open a mailbox to send"
        mailBtn:Disable()
        mailBtn:SetScript("OnClick", function()
            addon.MailAllUpgrades()
        end)
        -- the reason a disabled send button is disabled is the one tooltip
        -- that matters here, so it must show while disabled
        mailBtn:SetMotionScriptsWhileDisabled(true)
        mailBtn:SetScript("OnEnter", function(btn)
            if btn._disabledReason and not btn:IsEnabled() then
                GameTooltip:SetOwner(btn, "ANCHOR_TOP")
                GameTooltip:AddLine(btn._disabledReason, 1, 1, 1, true)
                GameTooltip:Show()
            end
        end)
        mailBtn:SetScript("OnLeave", GameTooltip_Hide)
        f.MailButton = mailBtn

        -- the staged loot button: one click claims one draft stage's
        -- inbox attachments into the bags, so the normal send pipeline
        -- (and the vendor) can take over from there
        local lootBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        lootBtn:SetSize(170, 24)
        lootBtn:SetPoint("BOTTOMRIGHT", mailBtn, "BOTTOMLEFT", -8, 0)
        lootBtn:SetText("Loot from Mail")
        lootBtn._disabledReason = "Open a mailbox to loot"
        lootBtn:Disable()
        lootBtn:SetScript("OnClick", function()
            local stage, plan = addon.NextMailLootStage()
            if stage then
                addon.ExecuteMailLoot(plan)
            end
        end)
        -- same tooltip contract as the send button: a disabled reason is
        -- the one message that matters, so it shows while disabled
        lootBtn:SetMotionScriptsWhileDisabled(true)
        lootBtn:SetScript("OnEnter", function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_TOP")
            if btn._disabledReason and not btn:IsEnabled() then
                GameTooltip:AddLine(btn._disabledReason, 1, 1, 1, true)
            else
                GameTooltip:AddLine("Claims this stage's inbox attachments "
                    .. "into your bags", 1, 1, 1, true)
                GameTooltip:AddLine("One stage per click: upgrades, then "
                    .. "future upgrades, then respec holds. Left over items "
                    .. "stay in the mail and return to their senders.",
                    0.8, 0.8, 0.8, true)
            end
            GameTooltip:Show()
        end)
        lootBtn:SetScript("OnLeave", GameTooltip_Hide)
        f.MailLootButton = lootBtn

        -- the conditional equip button: opposite corner from the send/
        -- loot pair (their row is full), and hidden entirely unless the
        -- draft holds arrived upgrades for the current character with the
        -- item already in bags - it is the only action here that needs no
        -- mailbox, so it works after "Loot from Mail" has closed it
        local equipBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        equipBtn:SetSize(150, 24)
        equipBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 20)
        equipBtn:SetText("Equip Arrived")
        equipBtn:Hide()
        equipBtn:SetScript("OnClick", function()
            addon.ExecuteEquipArrived(addon.BuildEquipArrivedPlan())
        end)
        -- same tooltip contract as the send button: a disabled reason is
        -- the one message that matters, so it shows while disabled
        equipBtn:SetMotionScriptsWhileDisabled(true)
        equipBtn:SetScript("OnEnter", function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_TOP")
            if btn._disabledReason and not btn:IsEnabled() then
                GameTooltip:AddLine(btn._disabledReason, 1, 1, 1, true)
            else
                GameTooltip:AddLine("Equips the upgrades mailed to you, one "
                    .. "at a time, into the slot the draft scored them for.",
                    1, 1, 1, true)
                GameTooltip:AddLine("Blizzard's soulbind confirmation stays "
                    .. "yours to click - GearFall waits for your answer, "
                    .. "then continues.", 0.8, 0.8, 0.8, true)
            end
            GameTooltip:Show()
        end)
        equipBtn:SetScript("OnLeave", GameTooltip_Hide)
        f.EquipArrivedButton = equipBtn

        -- the XML frame survives /reload while module locals do not: reuse
        -- the pieces instead of layering duplicate buttons on top
        f.gfBuilt = true
        f.gfProvider = distProvider
    else
        distProvider = f.gfProvider
    end

    return f
end

function addon.ToggleDistribution(force)
    local f = addon.CreateDistributionFrame()
    if not f then
        return
    end
    if f:IsShown() and force ~= true then
        f:Hide()
        return
    end
    if f:IsShown() then
        return
    end
    addon.AnchorDistributionOverlay()
    f:Show()
    addon.RefreshDistribution()
end

-------------------------------------------------------------------------------
-- Mailbox events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("MAIL_SHOW")
events:RegisterEvent("MAIL_CLOSED")
events:RegisterEvent("MAIL_INBOX_UPDATE")
-- the window docks to the mailbox and drafts from the bags: bag changes
-- (a loot take's claimed item landing, vendor, equip) must coalesce-rescan
-- it exactly like the Sendable tab, or a just-claimed attachment's arrival
-- lands with no event the window hears and it goes stale until a manual
-- rescan
events:RegisterEvent("BAG_UPDATE_DELAYED")
-- inbox updates can burst (one per read mail); coalesce the rescans
local inboxRescanPending

-- should the Distribution window pop open right now? The draft decides:
-- mailable upgrades in the bags (the original trigger), or gear inbound in
-- the mail - GearFall-routed copies promised to this character that are
-- still sitting in the inbox ("Arrived - equip it" rows). Unplanned gear
-- mailed manually never triggers the pop; the mail is the user's to open.
local function AutoOpenWanted()
    for _, s in ipairs(addon._distSuggestions or {}) do
        if s.kind == "upgrade"
            or (s.kind == "selfkeep" and s.arrived
                and s.item and s.item.location == "mail") then
            return true
        end
    end
    return false
end

-- attempt the auto-open, guarded: only while a mailbox is open, never
-- mid-pipeline (a run's own refresh speaks last), never after the user
-- dismissed the window during this mailbox session. Called at MAIL_SHOW
-- and after every draft rebuild the mailbox events schedule - the inbox
-- payload often lands after the frame opens, so the rescan chain is what
-- makes the trigger reliable
function addon.AttemptDistributionAutoOpen()
    if not addon._mailboxOpen or addon.MailRunActive()
        or addon._distDismissed then
        return
    end
    if not AutoOpenWanted() then
        return
    end
    local f = addon.CreateDistributionFrame()
    if f then
        addon.AnchorDistributionOverlay()
        if not f:IsShown() then
            f:Show()
        end
        addon.RefreshDistribution()
    end
end

events:SetScript("OnEvent", function(_, event)
    if event == "MAIL_SHOW" then
        addon._mailboxOpen = true
        addon._distDismissed = nil
        addon.RefreshDistribution(true)
        -- the inbox payload often arrives after the frame opens and the
        -- initial fill does not reliably fire MAIL_INBOX_UPDATE: schedule a
        -- guaranteed rescan chain that runs while the mailbox stays open
        for _, delay in ipairs({ 0.5, 1.5, 3 }) do
            C_Timer.After(delay, function()
                -- a run does its own single end-of-run refresh
                if addon._mailboxOpen and not addon.MailRunActive() then
                    addon.RefreshDistribution(true)
                    -- the late payload may have just made the gear inbound
                    addon.AttemptDistributionAutoOpen()
                end
            end)
        end
        addon.AttemptDistributionAutoOpen()
    elseif event == "MAIL_INBOX_UPDATE" then
        -- only while the mailbox is open; the flag gates the mail scan
        if not addon._mailboxOpen then
            return
        end
        -- a run fires one update per take (~0.15s apart): the 0.5s
        -- coalescer would still rebuild the draft ~once per two takes,
        -- all of it wasted while the sequencer works from its own plan
        -- snapshot - stand down, the run's final refresh speaks last
        if addon.MailRunActive() then
            return
        end
        if inboxRescanPending then
            return
        end
        inboxRescanPending = true
        C_Timer.After(0.5, function()
            inboxRescanPending = nil
            if addon._mailboxOpen then
                addon.RefreshDistribution(true)
                -- a fresh inbox payload just landed: gear may be inbound now
                addon.AttemptDistributionAutoOpen()
            end
        end)
    elseif event == "BAG_UPDATE_DELAYED" then
        -- same contract as the Sendable tab: bag changes while the
        -- mailbox is open coalesce-rescan the window (its own stand-down
        -- covers the per-take bursts; the run's final refresh speaks
        -- last for those). Deliberately NO auto-open attempt here: bag
        -- changes are not mail, and a claimed attachment only ever
        -- REDUCES what is inbound
        if not addon._mailboxOpen or addon.MailRunActive() then
            return
        end
        if inboxRescanPending then
            return
        end
        inboxRescanPending = true
        C_Timer.After(0.5, function()
            inboxRescanPending = nil
            if addon._mailboxOpen then
                addon.RefreshDistribution(true)
            end
        end)
    else
        addon._mailboxOpen = false
        addon._distDismissed = nil
        addon.UpdateDistMailBtn()
        addon.UpdateDistLootBtn()
        addon.UpdateDistEquipBtn()
    end
end)

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
                FormatDelta(selfMatch.result)), 0.3, 1, 0.3, true)
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
                AltDisplayName(others[1].key), FormatDelta(others[1].result)),
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
                local c = KIND_COLOR[kind] or KIND_COLOR.eventually
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

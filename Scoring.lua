local _, addon = ...

-------------------------------------------------------------------------------
-- Scoring: given an item an alt MAY wear (Eligibility.lua answers that), is
-- it an upgrade, and by how much? A provider scores candidate vs equipped.
--
-- A provider is a table:
--   key           unique id stored in alt.scoringMode
--   name          display name
--   IsAvailable()  global availability (addon loaded etc.)
--   GetScore(item, alt, slotID) -> number or nil, errMsg
--     item is { itemLink = ..., itemLevel = ... } for both candidates and the
--     alt's cached equipped snapshots, so every provider must accept a bare
--     cached link. slotID is the inventory slot being scored (Pawn weighs
--     mainhand vs offhand weapons differently; slot-agnostic providers like
--     ITEMLEVEL ignore it). Scores are only ever compared within one alt +
--     one mode.
-------------------------------------------------------------------------------

local providers = {}

function addon.RegisterScoringProvider(provider)
    providers[provider.key] = provider
end

addon.RegisterScoringProvider({
    key = "ITEMLEVEL",
    name = "Item level",
    IsAvailable = function() return true end,
    GetScore = function(item) return tonumber(item.itemLevel) or 0 end,
})

local function PawnScaleExists(name)
    local scales = name and addon.PawnScales()
    return scales and scales[name] ~= nil
end

-- Pawn's public API, via _G so linters without Pawn stubs stay quiet; the
-- wrappers yield nil whenever Pawn is not loaded
local function FindScaleForSpec(classID, specID)
    local f = _G.PawnFindScaleForSpec
    return f and f(classID, specID)
end

local function StatsForItemLink(link, scaleName, isWeapon)
    local f = _G.PawnGetStatsForItemLink
    return f and f(link, scaleName, isWeapon)
end

local function GetItemValue(stats)
    local f = _G.PawnGetItemValue
    return f and f(stats)
end

function addon.ResolvePawnScale(alt)
    if alt.pawnScaleName and PawnScaleExists(alt.pawnScaleName) then
        return alt.pawnScaleName
    end
    if alt.pawnScaleName then
        return nil, ("Scale \"%s\" is not available in Pawn"):format(alt.pawnScaleName)
    end
    if alt.classID then
        local scaleName = FindScaleForSpec(alt.classID, alt.activeSpecID)
        if scaleName and PawnScaleExists(scaleName) then
            return scaleName, nil, true
        end
        if scaleName then
            return nil, ("Suggested Pawn scale \"%s\" no longer exists"):format(scaleName)
        end
    end
    return nil, "No Pawn scale assigned to this character"
end

addon.RegisterScoringProvider({
    key = "PAWN",
    name = "Pawn",
    IsAvailable = function()
        return _G.PawnGetStatsForItemLink ~= nil and _G.PawnGetItemValue ~= nil
    end,
    GetScore = function(item, alt, slotID)
        if not item.itemLink then
            return nil, "No item link to score"
        end
        local scaleName, err = addon.ResolvePawnScale(alt)
        if not scaleName then
            return nil, err
        end
        -- slot 16 is mainhand by construction; the flag only affects the
        -- weapon DPS/spell-DPS lines, so it is inert for every other slot
        local stats = StatsForItemLink(item.itemLink, scaleName, slotID == 16)
        if not stats then
            return nil, "Pawn could not score this item (uncached?)"
        end
        local value = GetItemValue(stats)
        if not value then
            return nil, "Pawn returned no value for this item"
        end
        return value
    end,
})


-- UI accessors. The mode chooser must also show an UNavailable provider
-- when an alt is already set to it (so a stale mode stays fixable, not
-- silently hidden), hence availability travels with the entry.
function addon.GetScoringProviderList()
    local list = {}
    for _, p in pairs(providers) do
        list[#list + 1] = {
            key = p.key, name = p.name,
            available = p.IsAvailable() and true or false,
        }
    end
    table.sort(list, function(a, b) return a.key < b.key end)
    return list
end

function addon.GetScoringProviderInfo(key)
    for _, p in ipairs(addon.GetScoringProviderList()) do
        if p.key == key then
            return p
        end
    end
end

-------------------------------------------------------------------------------
-- Engine
-------------------------------------------------------------------------------

-- The comparison target for a slot is the BETTER of what the alt wears and
-- what we mailed but they have not equipped yet. A mailed upgrade lives in
-- their mailbox (or their bags) but is invisible to every API we have from
-- here; without this ledger we would happily mail a second, weaker upgrade
-- into the same slot. Note there is no {worn, incoming} list iterated with
-- ipairs here: a nil first element truncates that table, which would make
-- incoming-on-an-empty-slot invisible. Returns candValue, eqValue, eqSnap,
-- nil, blocked on success (blocked = statless quality gate, see
-- StatlessBlocked) or nil, nil, nil, err on failure.
-- Statless quality gate (Enum.ItemQuality: Poor=0, Common=1, Uncommon=2).
-- Poor/Common items carry no stats, so they can never beat an Uncommon+
-- item in game no matter what raw item level claims - the ITEMLEVEL
-- provider would otherwise suggest exactly that. Engine-level (both
-- providers): a statless candidate stays a legal fill for an EMPTY slot
-- and still compares against other statless items, but any Uncommon+
-- snapshot in the slot (worn OR incoming) blocks it. Snapshot quality is
-- captured at login; legacy snapshots without one fail open (nil passes,
-- like every other gate).
local function StatlessBlocked(candidateQuality, snaps)
    if not candidateQuality or candidateQuality > Enum.ItemQuality.Common then
        return false
    end
    for _, s in ipairs(snaps) do
        if s.quality and s.quality >= Enum.ItemQuality.Uncommon then
            return true
        end
    end
    return false
end

local function evalSlot(provider, itemInfo, alt, slot)
    local candValue, err = provider.GetScore(itemInfo, alt, slot)
    if candValue == nil then
        return nil, nil, nil, err
    end
    local eqValue, eqSnap = 0, nil
    local snaps = {}
    local worn = (alt.slots or {})[slot]
    if worn then
        snaps[#snaps + 1] = worn
    end
    local incoming = alt.incoming and alt.incoming[slot]
    if incoming then
        snaps[#snaps + 1] = incoming
    end
    for _, s in ipairs(snaps) do
        local v, e = provider.GetScore(s, alt, slot)
        if v == nil then
            return nil, nil, nil, e
        end
        if not eqSnap or v > eqValue then
            eqValue, eqSnap = v, s
        end
    end
    return candValue, eqValue, eqSnap, nil,
        StatlessBlocked(itemInfo.quality, snaps)
end

-- Returns result:
--   eligible, reason, slotID, mode, modeNote, delta, candidateValue,
--   equippedValue, equippedItemLevel, upgradePercent
function addon.ScoreItemForAlt(itemInfo, alt)
    local result = { eligible = false, mode = alt.scoringMode or "ITEMLEVEL" }

    local verdict, reason, slotID, slotFixed, candidateSlots, respecSpecs =
        addon.IsItemEligibleForAlt(itemInfo, alt)
    if verdict ~= "yes" then
        result.reason = reason
        result.verdict = verdict
        result.respecSpecs = respecSpecs
        return result
    end
    result.eligible = true
    result.slotID = slotID

    -- resolve the provider before comparing anything, so every slot is
    -- measured against the same yardstick
    local provider = providers[result.mode] or providers["ITEMLEVEL"]
    if provider ~= providers[result.mode] then
        result.modeNote = ("Unknown scoring mode \"%s\", using Item Level"):format(
            tostring(alt.scoringMode))
        result.mode = provider.key
    elseif not provider.IsAvailable() then
        result.modeNote = ("Scoring mode \"%s\" is not available, using Item Level"):format(
            provider.key)
        provider = providers["ITEMLEVEL"]
        result.mode = provider.key
    end

    -- Evaluate the candidate against EVERY slot it fits and keep the best
    -- delta. "Weakest equipped" must be measured by the ACTIVE provider, not
    -- raw item level (under Pawn a lower-ilvl ring with better stats can
    -- outscore a higher-ilvl one), and Pawn scores the same weapon
    -- differently per hand, so dual-wield offers need true per-slot math.
    local targetSlots = (candidateSlots and not slotFixed)
        and candidateSlots or { slotID }
    local evals, evalErr
    for _ = 1, 2 do
        evals, evalErr = {}, nil
    for _, slot in ipairs(targetSlots) do
        local candValue, eqValue, snap, err, blocked =
            evalSlot(provider, itemInfo, alt, slot)
        if candValue == nil then
            evals, evalErr = nil, err
            break
        end
        local delta = candValue - eqValue
        if blocked then
            -- a statless item over an Uncommon+ is not a real upgrade:
            -- clamp the delta so this slot can never win best-pick nor
            -- register as a match (matches require delta > 0)
            delta = math.min(delta, 0)
        end
        evals[#evals + 1] = {
            slot = slot, snap = snap, blocked = blocked,
            candidateValue = candValue, equippedValue = eqValue,
            delta = delta,
        }
    end
        if evals or provider == providers["ITEMLEVEL"] then
            break
        end
        -- a score failed on the real provider: redo the whole comparison
        -- with item level so the note and the numbers stay consistent
        result.modeNote = ("Pawn fallback: %s"):format(evalErr or "unknown error")
        provider = providers["ITEMLEVEL"]
        result.mode = provider.key
    end
    if not evals or #evals == 0 then
        result.reason = evalErr or "Cannot score item"
        result.eligible = false
        return result
    end

    local best = evals[1]
    for i = 2, #evals do
        if evals[i].delta > best.delta then
            best = evals[i]
        end
    end
    result.slotID = best.slot
    result.candidateValue = best.candidateValue
    result.equippedValue = best.equippedValue
    result.equippedItemLevel = best.snap and best.snap.itemLevel
    -- the mail flow phrases its advice as "replaces <alt>'s <item>", which
    -- needs the displaced item itself, not just its numbers
    result.equippedLink = best.snap and best.snap.itemLink
    result.equippedName = best.snap and best.snap.name
    result.equippedQuality = best.snap and best.snap.quality
    result.equippedIncoming = best.snap and best.snap.mailIncoming or nil
    result.delta = best.delta
    if best.blocked then
        -- the win came from a statless-vs-Uncommon+ slot: nothing ships,
        -- but say WHY the numbers read "no upgrade" (debug score print,
        -- tooltips)
        result.modeNote = result.modeNote
            and (result.modeNote
                .. "; Poor/Common item: not an upgrade over Uncommon+")
            or "Poor/Common item: not an upgrade over Uncommon+"
    end
    -- relative upgrade in the provider's own units (Pawn shows upgrades as
    -- a percentage): only meaningful when there is something to compare
    -- against, so empty slots carry no percentage
    if not best.blocked and best.equippedValue and best.equippedValue > 0 then
        result.upgradePercent = best.delta / best.equippedValue * 100
    end
    if best.snap and (not best.snap.itemLevel or best.snap.itemLevel == 0) then
        result.modeNote = result.modeNote
            and (result.modeNote .. "; equipped item level unknown")
            or "Equipped item level unknown"
    end
    return result
end

-- localised-ish display name for a class token, for advice strings
local function PrettyClass(token)
    return addon.PrettyClass(token)
end

-- Single source of truth for hold wording. Every surface that renders a
-- hold (row text, cascade rewrite, both tooltips) derives its sentences
-- from these helpers - never re-format kind strings inline.
local function JoinSpecNames(specs)
    if not specs or #specs == 0 then
        return nil
    end
    local names = {}
    for i, name in ipairs(specs) do
        if i > 3 then
            names[#names + 1] = ("+%d more"):format(#specs - 3)
            break
        end
        names[#names + 1] = name
    end
    return table.concat(names, " or ")
end

-- the summary tail after "Future upgrade for <alt> - "
function addon.HoldSpecTail(kind, specs)
    if kind == "respec" then
        local joined = JoinSpecNames(specs)
        return joined and ("needs a " .. joined .. " respec") or "needs a respec"
    end
    return "not equippable yet"
end

function addon.HoldSummary(key, kind, specs)
    return ("Future upgrade for %s - %s"):format(
        addon.AltDisplayName(key), addon.HoldSpecTail(kind, specs))
end

-- Does this hold reason describe a LEVEL blocker (vs a load-out swap)?
-- Shared by the fix hint and the Distribution window's section split; the
-- "Requires level" prefix is the level gate's own reason format
-- (Eligibility.lua) - the two must stay in sync. Pattern-mode find: with
-- plain=true the caret would be searched for literally and never match
function addon.HoldBlockerIsLevel(reason)
    return reason ~= nil and reason:find("^Requires level") ~= nil
end

-- the tooltip's fix-hint sentence for one hold kind. Level-blocked holds
-- quote the requirement Blizzard-style ("Item Requires Level 90")
function addon.HoldFixHint(kind, specs, reason)
    if kind == "respec" then
        local joined = JoinSpecNames(specs)
        return joined and (joined .. " could use this - keep it until you respec")
            or "Another spec could use this - keep it until you respec"
    end
    if addon.HoldBlockerIsLevel(reason) then
        local level = tonumber(reason:match("^Requires level (%d+)"))
        return ("Not equippable yet - Item Requires Level %d"):format(level or 0)
    end
    return "Not equippable yet - a load-out change fixes it"
end

-- Ranked suggestions for one scanned item, best first.
-- Returns list of { key, alt, result } (eligible and delta > 0 only) plus
-- advice for the empty-list case:
--   advice.hold = { key, reason, kind } - some alt COULD still get use out
--     of this: kind "eventually" (level / current load-out blocks it) beats
--     kind "respec" (another spec of the class would use it) beats kind
--     "newalt" (no alt CAN use it, but a class that isn't on the roster at
--     all could - "roll one"); the highest-priority alt within the best
--     kind wins. SAVE the item.
--   advice.usableButWorse = someone could wear it but nobody needs it now
--     or later - safe to sell/enchant
--   neither              = no alt can ever use it, and no missing class
--     could either - safe to destroy
function addon.FindBestAltsForItem(itemInfo)
    local matches = {}
    local advice = {}
    -- every alt's verdict from this single scoring pass; the draft's hold
    -- cascade consumes it instead of re-scoring the roster
    local byAlt = {}
    local anyUsable, considered = false, 0
    for key, alt in pairs(GearFallDB.alts) do
        if not alt.excluded then
            considered = considered + 1
            local result = addon.ScoreItemForAlt(itemInfo, alt)
            byAlt[key] = { verdict = result.verdict,
                respecSpecs = result.respecSpecs, reason = result.reason,
                tier = alt.prioTier or 9999 }
            if result.eligible then
                anyUsable = true
                if (result.delta or 0) > 0 then
                    matches[#matches + 1] = { key = key, alt = alt, result = result }
                end
            elseif result.verdict == "eventually" or result.verdict == "respec" then
                local rank = result.verdict == "eventually" and 1 or 2
                local cur = advice.hold
                if not cur or rank < cur.rank
                    or (rank == cur.rank and (alt.prioTier or 9999) < (cur.prioTier or 9999)) then
                    advice.hold = {
                        key = key, prioTier = alt.prioTier, reason = result.reason,
                        respecSpecs = result.respecSpecs,
                        kind = result.verdict, rank = rank,
                        summary = addon.HoldSummary(key, result.verdict,
                            result.respecSpecs),
                    }
                end
            end
        end
    end
    advice.byAlt = byAlt
    -- match ranking follows the draft strategy: "Roster priority" hands the
    -- item to the highest tier that can use it (delta breaks same-tier
    -- ties); "Biggest upgrade" gives the largest delta the win, with tier
    -- as the tiebreak and as the arbiter across scoring modes (Pawn points
    -- and item levels are not comparable)
    local byPriority = addon.SettingChoice
        and addon.SettingChoice("draftStrategy") == "priority"
    table.sort(matches, function(a, b)
        local ta, tb = a.alt.prioTier or 9999, b.alt.prioTier or 9999
        if byPriority then
            if ta ~= tb then
                return ta < tb
            end
            if (a.result.delta or 0) ~= (b.result.delta or 0) then
                return (a.result.delta or 0) > (b.result.delta or 0)
            end
            return a.key < b.key
        end
        if a.result.mode ~= b.result.mode then
            if ta ~= tb then
                return ta < tb
            end
            return a.key < b.key
        end
        if (a.result.delta or 0) ~= (b.result.delta or 0) then
            return (a.result.delta or 0) > (b.result.delta or 0)
        end
        if ta ~= tb then
            return ta < tb
        end
        return a.key < b.key
    end)
    if considered == 0 then
        -- an empty or fully-excluded roster must never advise destroying
        advice.hold = {
            key = "?", reason = "no alts captured yet", kind = "eventually",
            summary = "Capture alts to score this",
        }
    elseif advice.hold then
        advice.hold.rank = nil
    elseif anyUsable then
        advice.usableButWorse = true
    else
        -- nobody can use it TODAY: would a class the player doesn't have
        -- want it? (warglaives rotting in the bank because there is no DH on
        -- the account is exactly what this catches)
        local missing = addon.ClassesWithoutAltUsing(itemInfo)
        if #missing > 0 then
            local names = {}
            for i, cls in ipairs(missing) do
                names[i] = PrettyClass(cls)
            end
            if #names > 3 then
                names = { table.concat({ names[1], names[2], names[3] }, ", ")
                    .. (" (+%d more)"):format(#names - 3) }
            end
            advice.hold = {
                key = "future alt",
                kind = "newalt",
                reason = ("no alt can use this, but a %s could"):format(
                    table.concat(names, " or a ")),
                summary = ("Future upgrade for a %s you don't have yet"):format(
                    table.concat(names, " or a ")),
            }
        end
    end
    return matches, advice
end

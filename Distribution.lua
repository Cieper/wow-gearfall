local _, addon = ...

-- Distribution (window): the mailbox-docked suggestion window itself -
-- the EM Triage shape transplanted onto GearFall's verdict engine. Rows,
-- frame lifecycle, the send/loot/equip button wiring, the summary bar,
-- and the mailbox event frame that rescans the draft and auto-opens the
-- window when gear is inbound. All the machinery it wires up lives in
-- the sibling Distribution_* modules and is reached via addon.*.

local distFrame
local distProvider

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
                :format(addon.AltDisplayName(data.altKey), count), 1, 1, 1, true)
        else
            GameTooltip:AddLine("Loot this attachment from the mail",
                1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    self.mailBtn:SetScript("OnLeave", GameTooltip_Hide)
    -- bank badge: same role as the envelope, for rows whose item still
    -- sits in a bank/Warbank tab - a chest (the banker gossip icon) that
    -- is also a withdraw button: an item row's chest withdraws exactly
    -- that item, a character header's chest withdraws every drafted bank
    -- item for that character. The plan comes from the addon namespace and
    -- ExecuteLoot dispatches by source, so mid-run clicks are no-ops via
    -- the executor's own mutual-exclusion guard
    self.bankIcon = self:CreateTexture(nil, "OVERLAY")
    self.bankIcon:SetSize(12, 12)
    self.bankIcon:SetPoint("RIGHT", self, "RIGHT", -4, 0)
    self.bankIcon:SetTexture("Interface\\GossipFrame\\BankerGossipIcon")
    self.bankIcon:Hide()
    self.bankBtn = CreateFrame("Button", nil, self)
    self.bankBtn:SetSize(16, 16)
    self.bankBtn:SetPoint("CENTER", self.bankIcon, "CENTER", 0, 0)
    self.bankBtn:Hide()
    self.bankBtn:SetScript("OnClick", function()
        local data = self._data
        if not data or addon.MailRunActive() then
            return
        end
        local plan
        if data.kind == "header" then
            plan = data.rowKeys and #data.rowKeys > 0
                and addon.WithdrawPlanForRows(data.rowKeys) or nil
        else
            plan = addon.WithdrawPlanForItem(data.rowKey)
        end
        if plan and #plan > 0 then
            -- instant feedback: the chest disappears the frame you click
            -- it, before the moves confirm - the run's end-of-run refresh
            -- re-renders every row anyway, and the MailRunActive guard
            -- makes a mid-run re-click a no-op
            self.bankBtn:Hide()
            self.bankIcon:Hide()
            addon.ExecuteLoot(plan)
        end
    end)
    self.bankBtn:SetScript("OnEnter", function()
        local data = self._data
        GameTooltip:SetOwner(self.bankBtn, "ANCHOR_TOP")
        if data and data.kind == "header" and data.altKey then
            -- the live plan for THIS header's rows: the same rows the
            -- header's own count refers to, never the alt's rows under
            -- other headers
            local count = #addon.WithdrawPlanForRows(data.rowKeys)
            GameTooltip:AddLine(("Withdraw %s's drafted bank items (%d)")
                :format(addon.AltDisplayName(data.altKey), count), 1, 1, 1, true)
        else
            GameTooltip:AddLine("Withdraw this item from the bank",
                1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    self.bankBtn:SetScript("OnLeave", GameTooltip_Hide)
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
        -- badge (and only when they hold rows from that source): a
        -- character header's envelope loots its inbox attachments, its
        -- chest withdraws its bank items; section and "Left over" headers
        -- stay icon-less
        local headerMail = data.altKey ~= nil and (data.mailCount or 0) > 0
        self.mailIcon:SetShown(headerMail)
        self.mailBtn:SetShown(headerMail)
        local headerBank = data.altKey ~= nil and (data.bankCount or 0) > 0
        self.bankIcon:SetShown(headerBank)
        self.bankBtn:SetShown(headerBank)
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
    -- rows whose item is still in the mailbox show the envelope badge,
    -- rows still in a bank/Warbank tab show the chest badge (both trail
    -- the advice text, anchored below once the text is set; the advice
    -- column keeps its full width either way, and one item can only sit
    -- in one place so the badges are mutually exclusive)
    local inMail = item.location == "mail"
    local inBank = item.location == "bank"
    self.mailIcon:SetShown(inMail)
    -- the envelope is clickable for every identified draft row; a left
    -- over attachment keeps the badge visual-only (junk is never claimed)
    self.mailBtn:SetShown(inMail and data.kind ~= "leftover")
    self.bankIcon:SetShown(inBank)
    self.bankBtn:SetShown(inBank and data.kind ~= "leftover")
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
    local slotID = addon.RowSlot(data)
    self.slotFs:SetText(slotID and addon.SLOT_NAMES[slotID] or "")

    if data.kind == "upgrade" then
        self.actionFs:SetText(("Upgrade for %s  (%s)"):format(
            addon.AltDisplayName(data.altKey), addon.FormatDelta(data.result)))
        self.actionFs:SetTextColor(0.3, 1, 0.3)
    elseif data.kind == "selfkeep" then
        if data.arrived then
            self.actionFs:SetText(("Arrived - equip it  (%s)"):format(
                addon.FormatDelta(data.result)))
        else
            self.actionFs:SetText(("Keep - equip it  (%s)"):format(
                addon.FormatDelta(data.result)))
        end
        self.actionFs:SetTextColor(0.3, 1, 0.3)
    elseif data.kind == "leftover" then
        self.actionFs:SetText("Left over - nobody still needs it")
        self.actionFs:SetTextColor(0.6, 0.6, 0.6)
    else
        self.actionFs:SetText(data.hold.summary
            or ("Hold: %s"):format(data.hold.reason or "?"))
        local c = addon.KIND_COLOR[data.hold.kind] or addon.KIND_COLOR.eventually
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
    if inBank then
        -- the chest trails the advice text exactly like the envelope
        local x = self.actionFs:GetStringWidth() + 4
        local maxX = (self:GetWidth() or 440) - 16
        if x > maxX then
            x = maxX
        end
        self.bankIcon:ClearAllPoints()
        self.bankIcon:SetPoint("LEFT", self.actionFs, "LEFT", x, 0)
    end
end

-- FR-9 context menu, data-only so the harness can pin the option set per
-- location: bag rows (with a GUID) get both tiers, mail rows only the
-- permanent one (attachments have no ItemLocation, hence no GUID)
function addon.IgnoreMenuEntries(item)
    local entries = {}
    if not item or not item.itemID then
        return entries
    end
    entries[#entries + 1] = {
        text = "Ignore permanently (all copies, all characters)",
        permanent = true,
    }
    if item.location == "bag" and item.guid and item.guid ~= "" then
        entries[#entries + 1] = {
            text = "Ignore just this copy",
            once = true,
        }
    end
    return entries
end

function GearFallDistributionRowMixin:OnClick(button)
    local data = self._data
    if not data then
        return
    end
    if button == "RightButton" then
        if data.item and data.item.itemID and MenuUtil
            and MenuUtil.CreateContextMenu
            and addon.IgnoreMenuEntries then
            -- Blizzard's generator convention (Menu.PopulateDescription):
            -- generator(ownerRegion, rootDescription) - the owner region is
            -- the FIRST argument, the root description the second
            MenuUtil.CreateContextMenu(self, function(_, root)
                root:CreateTitle(data.item.name or "Item")
                for _, entry in ipairs(addon.IgnoreMenuEntries(data.item)) do
                    root:CreateButton(entry.text, function()
                        if entry.permanent then
                            addon.IgnoreItemPermanently(data.item.itemID,
                                data.item.itemLink)
                        elseif entry.once then
                            addon.IgnoreItemCopy(data.item.guid,
                                data.item.itemID, data.item.bagID,
                                data.item.slotIndex, data.item.name)
                        end
                    end)
                end
            end)
        end
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
                    addon.FormatDelta(data.result)), 0.3, 1, 0.3, true)
            else
                GameTooltip:AddLine(("Keep it - equipping beats mailing (%s)")
                    :format(addon.FormatDelta(data.result)), 0.3, 1, 0.3, true)
            end
        elseif data.result.equippedIncoming then
            GameTooltip:AddLine(("Incoming for %s: %s  %s"):format(
                addon.AltDisplayName(data.altKey), eq, addon.FormatDelta(data.result)),
                1, 0.82, 0, true)
        else
            GameTooltip:AddLine(("Replaces %s's %s  %s"):format(
                addon.AltDisplayName(data.altKey), eq, addon.FormatDelta(data.result)),
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
            and addon.AltDisplayName(hold.key) or nil
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
    -- the badges' own explanation, for every kind: mail attachments
    -- cannot be picked up for mailing, and bank items cannot be attached
    -- to a letter either - both must be claimed into the bags first
    if data.item.location == "mail" then
        GameTooltip:AddLine("In your mailbox - claim it, then rescan to "
            .. "mail it. GearFall cannot attach mail attachments.",
            1, 0.82, 0, true)
    elseif data.item.location == "bank" then
        if data.item.bankType == "account" then
            GameTooltip:AddLine("In your Warbank - withdraw it to mail it "
                .. "(any realm's bank can withdraw, so alts on other "
                .. "realms can too).", 1, 0.82, 0, true)
        else
            GameTooltip:AddLine("In your bank - withdraw it, then rescan "
                .. "to mail it. GearFall cannot attach bank items.",
                1, 0.82, 0, true)
        end
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

-- EM's docking order, trimmed to our two use cases: sit right of the
-- mailbox (or the bank frame, whichever is the host), then immediately
-- detach to absolute coords. Leaving the relative anchor in place
-- produces the sticky-resize bug (the host frame reflows mid-drag and
-- yanks us along).
function addon.AnchorDistributionOverlay()
    if not distFrame then
        return
    end
    if addon._distUserMoved then
        addon.ClampDistributionToScreen()
        return
    end
    local host
    if MailFrame and MailFrame:IsShown() then
        host = MailFrame
    elseif BankFrame and BankFrame:IsShown() then
        host = BankFrame
    end
    if host then
        local screenH = (UIParent and UIParent:GetHeight()) or 768
        local maxH = math.max(300, math.floor(screenH - 120))
        distFrame:SetHeight(math.min(host:GetHeight(), maxH))
        distFrame:ClearAllPoints()
        distFrame:SetPoint("TOPLEFT", host, "TOPRIGHT", 2, 0)
    end
    DetachToUIParent(distFrame)
end

-- the Update*Btn trio lives here rather than beside its state function:
-- each one wires a state read onto THIS window's button, and distFrame is
-- window-local. The state functions (MailLootButtonState,
-- EquipArrivedButtonState) stay with their features.
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
    elseif not addon.MailboxOpen() then
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

-- the bank claim button's state, fifth member of the Update*Btn family:
-- visible only while a bank is open (its rows only exist then), stacked
-- above the loot/send pair - the list panel lifts its bottom edge while
-- the button is shown so the extra row never overlaps it. Same contract
-- as the trio - safe with no frame, called from every RefreshDistribution
function addon.UpdateDistBankBtn()
    local btn = distFrame and distFrame.BankLootButton
    if not btn then
        return
    end
    local bankOpen = addon._bankOpen == true
    btn:SetShown(bankOpen)
    local listPanel = distFrame.gfListPanel
    if listPanel then
        listPanel:ClearAllPoints()
        listPanel:SetPoint("TOPLEFT", distFrame.SummaryBar, "BOTTOMLEFT", 0, -2)
        listPanel:SetPoint("BOTTOMRIGHT", distFrame, "BOTTOMRIGHT", -12,
            bankOpen and 78 or 52)
    end
    if not bankOpen then
        return
    end
    local text, reason, enabled = addon.BankLootButtonState()
    btn:SetText(text)
    btn._disabledReason = reason
    if enabled then
        btn:Enable()
    else
        btn:Disable()
    end
end

-- the alert icon's state, fourth member of the Update*Btn family: visible
-- only when the current character's ledger holds promises the fresh draft
-- cannot see anywhere. Same contract as the trio - safe with no frame,
-- called from every RefreshDistribution (which builds _distSuggestions
-- first, so the verdict the icon reads is always the one on screen)
function addon.UpdateDistStaleAlert()
    local btn = distFrame and distFrame.StaleIncomingButton
    if not btn then
        return
    end
    local myKey = addon.PlayerKey and addon.PlayerKey()
    local myAlt = myKey and GearFallDB.alts[myKey] or nil
    local unseen = addon.UnseenIncoming(myAlt, addon._distSuggestions)
    btn._unseen = unseen
    btn:SetShown(#unseen > 0)
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
    addon.UpdateDistBankBtn()
    addon.UpdateDistStaleAlert()
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

        -- the stale-promise alert: lights up when the current character's
        -- incoming ledger holds promises the fresh draft cannot see
        -- anywhere (bags or inbox) - the mailed upgrade is either still in
        -- transit or was returned and will never arrive. The tooltip lists
        -- what was promised; the right-click offers the flush (the shared
        -- action confirms, so a stray click costs nothing)
        local staleBtn = CreateFrame("Button", nil, f)
        staleBtn:SetSize(16, 16)
        staleBtn:SetPoint("RIGHT", rescanBtn, "LEFT", -6, 0)
        staleBtn:SetNormalAtlas("transmog-icon-warning-small")
        staleBtn:SetHighlightAtlas("transmog-icon-warning-small", "ADD")
        staleBtn:RegisterForClicks("RightButtonUp")
        staleBtn:Hide()
        staleBtn:SetScript("OnEnter", function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_TOP")
            GameTooltip:SetText("Promised upgrades not in sight", 1, 1, 1)
            for _, e in ipairs(btn._unseen or {}) do
                GameTooltip:AddLine(("%s - %s (promised %s ago)"):format(
                    addon.SLOT_NAMES[e.slot] or ("slot " .. e.slot),
                    e.inc.name or "?", addon.IncomingAgeText(e.inc.t)),
                    1, 0.82, 0, true)
            end
            GameTooltip:AddLine("The mail may still be in transit - or it "
                .. "was returned and will never arrive.", 0.8, 0.8, 0.8, true)
            GameTooltip:AddLine("Right-click to clear the promise(s).",
                1, 1, 1, true)
            GameTooltip:Show()
        end)
        staleBtn:SetScript("OnLeave", GameTooltip_Hide)
        staleBtn:SetScript("OnClick", function(btn, button)
            if button ~= "RightButton" or not (MenuUtil
                    and MenuUtil.CreateContextMenu) then
                return
            end
            local myKey = addon.PlayerKey and addon.PlayerKey()
            if not (myKey and GearFallDB.alts[myKey]) then
                return
            end
            MenuUtil.CreateContextMenu(btn, function(_, root)
                root:CreateTitle("Promised upgrades not in sight")
                root:CreateButton(("Clear the promise(s) (%d)"):format(
                    #(btn._unseen or {})), function()
                    addon.FlushIncomingLedger({ myKey })
                end)
            end)
        end)
        f.StaleIncomingButton = staleBtn

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

        -- the staged withdraw button: bank counterpart of the staged loot
        -- button, visible only while a bank is open and stacked above the
        -- loot/send pair (their row is full; the list panel lifts its own
        -- bottom edge while this is shown, see UpdateDistBankBtn)
        local bankBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        bankBtn:SetSize(170, 24)
        bankBtn:SetPoint("BOTTOMRIGHT", lootBtn, "TOPRIGHT", 0, 4)
        bankBtn:SetText("Withdraw from Bank")
        bankBtn._disabledReason = "Open a bank to withdraw"
        bankBtn:Disable()
        bankBtn:SetScript("OnClick", function()
            local stage, plan = addon.NextBankWithdrawStage()
            if stage then
                addon.ExecuteLoot(plan)
            end
        end)
        -- same tooltip contract as the send button: a disabled reason is
        -- the one message that matters, so it shows while disabled
        bankBtn:SetMotionScriptsWhileDisabled(true)
        bankBtn:SetScript("OnEnter", function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_TOP")
            if btn._disabledReason and not btn:IsEnabled() then
                GameTooltip:AddLine(btn._disabledReason, 1, 1, 1, true)
            else
                GameTooltip:AddLine("Withdraws this stage's bank and "
                    .. "Warbank items into your bags", 1, 1, 1, true)
                GameTooltip:AddLine("One stage per click: upgrades, then "
                    .. "future upgrades, then respec holds. Left over items "
                    .. "stay put.", 0.8, 0.8, 0.8, true)
            end
            GameTooltip:Show()
        end)
        bankBtn:SetScript("OnLeave", GameTooltip_Hide)
        f.BankLootButton = bankBtn

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
        f.gfListPanel = listPanel
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
-- the bank as a third scan source: BANKFRAME_OPENED/CLOSED gate the bank
-- scan (bank tab data only exists while the frame is open), the per-slot
-- tab events coalesce-rescan the draft, and BANK_TABS_CHANGED covers a
-- tab purchased mid-session
events:RegisterEvent("BANKFRAME_OPENED")
events:RegisterEvent("BANKFRAME_CLOSED")
events:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
events:RegisterEvent("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED")
events:RegisterEvent("BANK_TABS_CHANGED")
-- the window docks to the mailbox and drafts from the bags: bag changes
-- (a loot take's claimed item landing, a withdraw's arrival, vendor,
-- equip) must coalesce-rescan it exactly like the Sendable tab, or a
-- just-claimed attachment's arrival lands with no event the window hears
-- and it goes stale until a manual rescan
events:RegisterEvent("BAG_UPDATE_DELAYED")
-- inbox updates can burst (one per read mail); coalesce the rescans
local inboxRescanPending

-- should the Distribution window pop open right now? The draft decides:
-- mailable upgrades in the bags or the bank (the original trigger), or
-- gear inbound in the mail - GearFall-routed copies promised to this
-- character that are still sitting in the inbox ("Arrived - equip it"
-- rows). Unplanned gear mailed manually never triggers the pop; the mail
-- is the user's to open.
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

-- attempt the auto-open, guarded: only while a mailbox or a bank is open,
-- never mid-pipeline (a run's own refresh speaks last), never after the
-- user dismissed the window during this session. Called at MAIL_SHOW,
-- BANKFRAME_OPENED, and after every draft rebuild the mailbox/bank events
-- schedule - the inbox payload often lands after the frame opens, so the
-- rescan chain is what makes the trigger reliable
function addon.AttemptDistributionAutoOpen()
    if not (addon._mailboxOpen or addon._bankOpen)
        or addon.MailRunActive() or addon._distDismissed then
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
        -- mailbox or bank is open coalesce-rescan the window (its own
        -- stand-down covers the per-take bursts; the run's final refresh
        -- speaks last for those). Deliberately NO auto-open attempt here:
        -- bag changes are not mail, and a claimed attachment only ever
        -- REDUCES what is inbound
        if not (addon._mailboxOpen or addon._bankOpen)
            or addon.MailRunActive() then
            return
        end
        if inboxRescanPending then
            return
        end
        inboxRescanPending = true
        C_Timer.After(0.5, function()
            inboxRescanPending = nil
            if addon._mailboxOpen or addon._bankOpen then
                addon.RefreshDistribution(true)
            end
        end)
    elseif event == "BANKFRAME_OPENED" then
        addon._bankOpen = true
        addon._distDismissed = nil
        addon.RefreshDistribution(true)
        -- the tab contents often arrive after the frame opens (mirroring
        -- the mailbox's late inbox payload): schedule a guaranteed rescan
        -- chain that runs while the bank stays open
        for _, delay in ipairs({ 0.5, 1.5, 3 }) do
            C_Timer.After(delay, function()
                -- a run does its own single end-of-run refresh
                if addon._bankOpen and not addon.MailRunActive() then
                    addon.RefreshDistribution(true)
                    -- the late payload may have just made something draftable
                    addon.AttemptDistributionAutoOpen()
                end
            end)
        end
        addon.AttemptDistributionAutoOpen()
    elseif event == "PLAYERBANKSLOTS_CHANGED"
        or event == "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED"
        or event == "BANK_TABS_CHANGED" then
        -- only while the bank is open; the flag gates the bank scan
        if not addon._bankOpen then
            return
        end
        -- slot events can burst (one per moved item): coalesce the rescans
        if inboxRescanPending then
            return
        end
        inboxRescanPending = true
        C_Timer.After(0.5, function()
            inboxRescanPending = nil
            if addon._bankOpen then
                addon.RefreshDistribution(true)
            end
        end)
    elseif event == "MAIL_CLOSED" then
        addon._mailboxOpen = false
        addon._distDismissed = nil
        addon.UpdateDistMailBtn()
        addon.UpdateDistLootBtn()
        addon.UpdateDistEquipBtn()
    else
        -- BANKFRAME_CLOSED
        addon._bankOpen = false
        addon._distDismissed = nil
        addon.UpdateDistMailBtn()
        addon.UpdateDistLootBtn()
        addon.UpdateDistEquipBtn()
        addon.UpdateDistBankBtn()
    end
end)

local _, addon = ...

-- Distribution (send): the outbound mail pipeline. "Mail All Upgrades"
-- runs one Blizzard letter per recipient alt, positive deltas only -
-- "usable but not an upgrade" stays listed but never ships - confirmed
-- per recipient through the EM-style Send/Skip/Cancel dialog. This module
-- also owns the mailbox pipeline state every other Distribution_* module
-- reads: addon.MailboxOpen / addon.MailRunActive.

local MAIL_TIMEOUT = 5
local HISTORY_LIMIT = 200
local SUBJECT = "GearFall"

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

function addon.MailboxOpen()
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
        if not addon.MailboxOpen() then
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
    if not addon.MailboxOpen() then
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
    if not addon.MailboxOpen() or index > #recipients then
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
    local cr, cg, cb = addon.ClassColor(first and first.alt and first.alt.class)
    local displayName = first and addon.AltDisplayName(first.altKey) or recipient

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
        if not addon.MailboxOpen() then
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

local _, addon = ...

-- Sendable tab: toy-box-style grid of the current bag scan's eligible
-- items. Only scans while this tab is open (FR-3).

local itemScrollBox
local itemProvider
local itemEmptyText
local itemPager
local itemScanResults = {}
local itemPage = 1
local ITEMS_PER_PAGE = 15

-- "View for <alt>" mode: when set, the grid sorts by verdict and each
-- button shows why the item does or does not go to that alt. Session-only.
local sendableViewKey
local sendableViewDropDown
local RebuildItemsTab

local function SendableViewName(key)
    return key and (key:match("^([^-]+)") or key) or "All characters"
end

local function RefreshSendableViewLabel()
    if sendableViewDropDown then
        UIDropDownMenu_SetText(sendableViewDropDown,
            SendableViewName(sendableViewKey))
    end
end

local function SetSendableView(key)
    sendableViewKey = key
    RefreshSendableViewLabel()
    RebuildItemsTab()
end

local function InitializeSendableViewDropDown(dropDown, level)
    local all = UIDropDownMenu_CreateInfo()
    all.text = "All characters"
    all.checked = not sendableViewKey
    all.func = function()
        SetSendableView(nil)
    end
    UIDropDownMenu_AddButton(all, level)

    -- group the roster by tier so the menu mirrors the priority list's
    -- order: tiers in sequence, alphabetical within a tier, never-send last
    local tiers, excluded = {}, {}
    for key, alt in pairs(GearFallDB.alts) do
        if alt.excluded then
            excluded[#excluded + 1] = { key = key, class = alt.class }
        else
            local t = alt.prioTier or 9999
            tiers[t] = tiers[t] or {}
            tiers[t][#tiers[t] + 1] = { key = key, class = alt.class }
        end
    end
    local tierKeys = {}
    for t in pairs(tiers) do
        tierKeys[#tierKeys + 1] = t
    end
    table.sort(tierKeys)

    local function AddAltEntry(e)
        local cr, cg, cb = addon.ClassColor(e.class)
        local info = UIDropDownMenu_CreateInfo()
        info.text = SendableViewName(e.key)
        info.r, info.g, info.b = cr, cg, cb
        info.checked = sendableViewKey == e.key
        info.func = function()
            SetSendableView(e.key)
        end
        UIDropDownMenu_AddButton(info, level)
    end

    for _, t in ipairs(tierKeys) do
        local header = UIDropDownMenu_CreateInfo()
        header.text = ("Priority %d"):format(t)
        header.isTitle = true
        header.notCheckable = true
        header.disabled = true
        UIDropDownMenu_AddButton(header, level)
        local list = tiers[t]
        table.sort(list, function(a, b)
            return a.key:lower() < b.key:lower()
        end)
        for _, e in ipairs(list) do
            AddAltEntry(e)
        end
    end
    if #excluded > 0 then
        local header = UIDropDownMenu_CreateInfo()
        header.text = "Never send"
        header.isTitle = true
        header.notCheckable = true
        header.disabled = true
        UIDropDownMenu_AddButton(header, level)
        table.sort(excluded, function(a, b)
            return a.key:lower() < b.key:lower()
        end)
        for _, e in ipairs(excluded) do
            AddAltEntry(e)
        end
    end
    -- the box text re-syncs on every open: unnamed/legacy dropdowns reset it
    UIDropDownMenu_SetText(dropDown, SendableViewName(sendableViewKey))
end

GearFallItemButtonMixin = {}

function GearFallItemButtonMixin:OnLoad()
    -- CollectionsSpellButtonTemplate is 50x50 with the name label anchored to
    -- the button edge; widen the frame for grid layout and re-anchor the
    -- toy-box pieces against the icon instead.
    self:SetSize(200, 52)
    self:SetChecked(false)
    -- the base template's OnShow/OnEvent call self.updateFunction(self)
    self.updateFunction = function() end
    self.iconTexture:ClearAllPoints()
    self.iconTexture:SetPoint("CENTER", self, "LEFT", 28, 0)
    self.slotFrameCollected:ClearAllPoints()
    self.slotFrameCollected:SetPoint("CENTER", self.iconTexture, "CENTER", 0, 0)
    -- button state textures default to frame-center, which lands on the label
    for _, texture in ipairs({ self:GetHighlightTexture(), self:GetPushedTexture(),
        self:GetCheckedTexture() }) do
        if texture then
            texture:ClearAllPoints()
            texture:SetPoint("CENTER", self.iconTexture, "CENTER", 0, 1)
        end
    end
    self.name:ClearAllPoints()
    self.name:SetPoint("LEFT", self.iconTexture, "RIGHT", 12, 0)
    self.name:SetWidth(140)
    self.name:SetMaxLines(1)
    -- verdict line for the Sendable tab's "view for <alt>" mode
    self.verdictText = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.verdictText:SetPoint("TOP", self.name, "BOTTOM", 0, -1)
    self.verdictText:SetWidth(140)
    self.verdictText:SetJustifyH("LEFT")
    self.verdictText:SetMaxLines(1)
    self.verdictText:Hide()
end

function GearFallItemButtonMixin:Populate(data)
    self.itemData = data
    if data.icon then
        self.iconTexture:SetTexture(data.icon)
    else
        self.iconTexture:SetTexture(136248)
    end
    self.iconTexture:Show()
    self.iconTextureUncollected:Hide()

    local quality = data.quality or 1
    local r, g, b = addon.QualityColor(quality)
    self.name:SetTextColor(r, g, b)
    self.name:SetText(data.name or "")
    if data._verdict then
        self.verdictText:Show()
        self.verdictText:SetText(data._verdict.text)
        self.verdictText:SetTextColor(data._verdict.r, data._verdict.g,
            data._verdict.b)
    else
        self.verdictText:Hide()
    end
end

function GearFallItemButtonMixin:OnEnter()
    if not self.itemData then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_NONE")
    GameTooltip:SetPoint("BOTTOMLEFT", self.iconTexture, "TOPRIGHT", 12, 0)
    -- whenever the grid shows a verdict line, it replaces the generic bag
    -- advice (which answers a different, account-wide question)
    addon._bagAdvicePaused = (self.itemData._verdict ~= nil) or nil
    if self.itemData.bagID then
        GameTooltip:SetBagItem(self.itemData.bagID, self.itemData.slotIndex)
    elseif self.itemData.mailIndex and GameTooltip.SetInboxItem then
        GameTooltip:SetInboxItem(self.itemData.mailIndex,
            self.itemData.attachIndex)
    else
        GameTooltip:SetHyperlink(self.itemData.itemLink)
    end
    addon._bagAdvicePaused = nil
    if self.itemData._verdict then
        local v = self.itemData._verdict
        GameTooltip:AddLine(v.text, v.r, v.g, v.b, true)
    end
    GameTooltip:Show()
end

function GearFallItemButtonMixin:OnLeave()
    GameTooltip:Hide()
end

local function RenderItemsPage()
    if not itemProvider then
        return
    end
    local total = #itemScanResults
    local pages = math.max(1, math.ceil(total / ITEMS_PER_PAGE))
    itemPage = math.min(math.max(1, itemPage), pages)

    itemProvider:Flush()
    local first = (itemPage - 1) * ITEMS_PER_PAGE + 1
    local last = math.min(total, first + ITEMS_PER_PAGE - 1)
    for i = first, last do
        itemProvider:Insert(itemScanResults[i])
    end
    itemEmptyText:SetShown(total == 0)

    local showPager = pages > 1
    itemPager:SetShown(showPager)
    if showPager then
        itemPager:SetMaxPages(pages)
        itemPager:SetCurrentPage(itemPage)
    end
end

RebuildItemsTab = function()
    if not itemProvider or not GearFallDB then
        return
    end
    local items = {}
    local ok, scanned = pcall(addon.ScanEligibleItems)
    if ok and scanned then
        for _, info in ipairs(scanned) do
            if info.eligible then
                items[#items + 1] = info
            end
        end
    end
    if addon.ItemVerdictsForAlt then
        local verdicts = addon.ItemVerdictsForAlt(sendableViewKey)
        if verdicts then
            for _, info in ipairs(items) do
                info._verdict = verdicts[info.spot
                    or ("%d:%d"):format(info.bagID or 0,
                        info.slotIndex or 0)]
            end
            table.sort(items, function(a, b)
                local oa = a._verdict and a._verdict.order or 99
                local ob = b._verdict and b._verdict.order or 99
                if oa ~= ob then
                    return oa < ob
                end
                return (a.itemLevel or 0) > (b.itemLevel or 0)
            end)
        end
    else
        for _, info in ipairs(items) do
            info._verdict = nil
        end
    end
    itemScanResults = items
    itemPage = 1
    RenderItemsPage()
end

-- cross-module surface (the addon namespace is the only way other modules
-- may reach this tab): the mail loot/send runs stand this tab's own event
-- refreshes down mid-run, so their end-of-run refresh calls in here to
-- give an open grid the final bag + inbox state. No-op while not built
-- or not visible.
function addon.RefreshSendableTab()
    if RebuildItemsTab and itemScrollBox and itemScrollBox:IsVisible() then
        RebuildItemsTab()
    end
end

-- The Toy Box pager template ships in the load-on-demand Blizzard_Collections
-- addon: a session that never opened the journal has no such XML node, and
-- one failed CreateFrame killed the whole dashboard build (reported by a
-- fresh install). Load the addon on demand and fall back to a minimal
-- lookalike if the template is still unavailable (e.g. combat lockdown
-- blocks loading).
local function CreateItemsPager(parent, name)
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    local loadAddOn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if isLoaded and loadAddOn and not isLoaded("Blizzard_Collections") then
        pcall(loadAddOn, "Blizzard_Collections")
    end
    local ok, pager = pcall(CreateFrame, "Frame", name, parent,
        "CollectionsPagingFrameTemplate")
    if ok and pager then
        return pager
    end

    -- minimal stand-in: prev/next buttons + page text with the same tiny
    -- API the tab needs (SetShown/SetMaxPages/SetCurrentPage/
    -- GetCurrentPage). OnPageChanged fires on user flips only, like the
    -- real widget - SetCurrentPage must NOT fire it or the tab's render
    -- path (which calls SetCurrentPage) would recurse.
    pager = CreateFrame("Frame", name, parent)
    pager:SetSize(240, 30)
    local pageText = pager:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pageText:SetPoint("CENTER")
    local prevBtn = CreateFrame("Button", nil, pager, "UIPanelButtonTemplate")
    prevBtn:SetSize(26, 24)
    prevBtn:SetPoint("RIGHT", pageText, "LEFT", -14, 0)
    prevBtn:SetText("<")
    local nextBtn = CreateFrame("Button", nil, pager, "UIPanelButtonTemplate")
    nextBtn:SetSize(26, 24)
    nextBtn:SetPoint("LEFT", pageText, "RIGHT", 14, 0)
    nextBtn:SetText(">")

    local page, maxPages = 1, 1
    local function RefreshPager()
        pageText:SetText(("Page %d / %d"):format(page, maxPages))
        prevBtn:SetEnabled(page > 1)
        nextBtn:SetEnabled(page < maxPages)
    end
    local function FlipPage(delta)
        local newPage = page + delta
        if newPage < 1 or newPage > maxPages then
            return
        end
        page = newPage
        RefreshPager()
        if pager.OnPageChanged then
            pager:OnPageChanged()
        end
    end
    prevBtn:SetScript("OnClick", function() FlipPage(-1) end)
    nextBtn:SetScript("OnClick", function() FlipPage(1) end)
    function pager:GetCurrentPage()
        return page
    end
    function pager:SetCurrentPage(newPage)
        page = math.max(1, math.min(newPage or 1, maxPages))
        RefreshPager()
    end
    function pager:SetMaxPages(newMax)
        maxPages = math.max(1, newMax or 1)
        page = math.min(page, maxPages)
        RefreshPager()
    end
    function pager:SetShown(shown)
        if shown then
            pager:Show()
        else
            pager:Hide()
        end
    end
    RefreshPager()
    return pager
end

function addon.BuildItemsPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetPoint("TOPLEFT", 4, -32)
    page:SetPoint("BOTTOMRIGHT", -6, 5)
    page:Hide()

    local inset = CreateFrame("Frame", nil, page, "CollectionsBackgroundTemplate")
    inset:SetPoint("TOPLEFT", 0, -34)
    inset:SetPoint("BOTTOMRIGHT", -20, 0)

    -- "view for <alt>" selector: a standard Blizzard dropdown picking whose
    -- verdicts the grid shows
    local viewLabel = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    viewLabel:SetPoint("TOPLEFT", page, "TOPLEFT", 120, -10)
    viewLabel:SetText("View for:")
    sendableViewDropDown = CreateFrame("Frame", "GearFallSendableViewDropDown",
        page, "UIDropDownMenuTemplate")
    sendableViewDropDown:SetPoint("TOPLEFT", page, "TOPLEFT", 185, -6)
    UIDropDownMenu_SetWidth(sendableViewDropDown, 150)
    UIDropDownMenu_Initialize(sendableViewDropDown, InitializeSendableViewDropDown)
    RefreshSendableViewLabel()

    local scrollBox = CreateFrame("Frame", nil, inset, "WowScrollBoxList")
    scrollBox:SetAllPoints(inset)

    -- Toy Box grid: 208px column pitch, rows start 53px in and step 16px,
    -- first button inset 40px from the left edge of the panel
    local view = CreateScrollBoxListGridView(3, 53, 53, 40, 40, 8, 14)
    view:SetElementSize(200, 52)
    view:SetElementInitializer("GearFallItemButtonTemplate", function(button, elementData)
        button:Populate(elementData)
    end)
    scrollBox:Init(view)

    itemScrollBox = scrollBox
    itemProvider = CreateDataProvider()
    scrollBox:SetDataProvider(itemProvider)
    if scrollBox.SetScrollAllowed then
        scrollBox:SetScrollAllowed(false)
    end

    itemEmptyText = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    itemEmptyText:SetPoint("CENTER", inset, "CENTER", 0, 40)
    itemEmptyText:SetText("No sendable items in your bags.")
    itemEmptyText:SetTextColor(0.6, 0.6, 0.6)

    -- the Toy Box pager: the exact Collections widget (arrows, page text,
    -- and the page-state mixin), wired through OnPageChanged. The callback
    -- is wired on the pager itself (the widget's own contract) and on the
    -- inset as before, so either lookup finds it.
    itemPager = CreateItemsPager(inset, "GearFallSendablePagingFrame")
    itemPager:SetPoint("BOTTOM", inset, "BOTTOM", 0, 30)
    local function OnPagerPageChanged()
        itemPage = itemPager:GetCurrentPage()
        RenderItemsPage()
    end
    itemPager.OnPageChanged = OnPagerPageChanged
    inset.OnPageChanged = OnPagerPageChanged

    -- live refresh while the tab is open: BAG_UPDATE_DELAYED covers loot,
    -- vendor, delete, trade, and mail; UNIT_INVENTORY_CHANGED covers equips;
    -- MAIL_SHOW/MAIL_INBOX_UPDATE cover the inbox second-inventory while a
    -- mailbox is open. Bursts fire these repeatedly, so a short timer
    -- coalesces them.
    local rescanPending
    page:SetScript("OnEvent", function(self, event, unit)
        if event == "UNIT_INVENTORY_CHANGED" and unit ~= "player" then
            return
        end
        if (event == "MAIL_SHOW" or event == "MAIL_INBOX_UPDATE")
            and not addon._mailboxOpen then
            return
        end
        -- a mail loot/send run changes bags and the inbox once per take:
        -- the coalescer would still rebuild the grid every ~0.3s mid-run,
        -- all of it thrown away - the run's end-of-run refresh speaks last
        if addon.MailRunActive and addon.MailRunActive() then
            return
        end
        if rescanPending then
            return
        end
        rescanPending = true
        C_Timer.After(0.3, function()
            rescanPending = nil
            if self:IsVisible() then
                RebuildItemsTab()
            end
        end)
    end)
    page:SetScript("OnShow", function(self)
        self:RegisterEvent("BAG_UPDATE_DELAYED")
        self:RegisterEvent("UNIT_INVENTORY_CHANGED")
        self:RegisterEvent("MAIL_SHOW")
        self:RegisterEvent("MAIL_INBOX_UPDATE")
        RebuildItemsTab()
    end)
    page:SetScript("OnHide", function(self)
        self:UnregisterEvent("BAG_UPDATE_DELAYED")
        self:UnregisterEvent("UNIT_INVENTORY_CHANGED")
        self:UnregisterEvent("MAIL_SHOW")
        self:UnregisterEvent("MAIL_INBOX_UPDATE")
    end)

    return page
end

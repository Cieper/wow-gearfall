local _, addon = ...

-- Settings tab: the drag-reorderable priority list (FR-2) with per-alt
-- tags, scoring mode, gearing-rule overrides, and the global rule
-- checkboxes.

local PRIORITY_COLUMNS = {
    { key = "hash",    width = 30,  label = "#",     justify = "CENTER" },
    { key = "name",    width = 190, label = "Alt (drag to re-tier)", justify = "LEFT", padLeft = 6 },
    { key = "level",   width = 40,  label = "Lvl",   justify = "CENTER" },
    { key = "spec",    width = 105, label = "Spec",  justify = "LEFT" },
    { key = "tags",    width = 180, label = "Tags" },
    { key = "scoring", width = 120, label = "Scoring" },
    { key = "rules",   width = 105, label = "Rules" },
}

local priorityScrollBox
local priorityProvider
local priorityEntries = {}
-- the alt currently being dragged (captured at drag start; PersistPriorityOrder
-- only re-tiers this one alt, so drops can never reorder anyone else)
local dragKey
-- set by the drop predicate: the final hovered destination was inside the
-- never-send region (the zone row or an excluded alt's row)
local lastDropExcluded

local tagDropDown

local function ToggleAltTag(key, tagName)
    local alt = GearFallDB and GearFallDB.alts[key]
    if not alt then
        return
    end
    alt.tags = alt.tags or {}
    for i, tag in ipairs(alt.tags) do
        if tag == tagName then
            table.remove(alt.tags, i)
            addon.RefreshPriorityList()
            addon.RefreshPriorityList()
            return
        end
    end
    table.insert(alt.tags, tagName)
    addon.RefreshPriorityList()
    addon.RefreshPriorityList()
end

local function InitializeTagDropDown(dropDown, level)
    local alt = GearFallDB and GearFallDB.alts[dropDown.altKey]
    local assigned = {}
    if alt and alt.tags then
        for _, tag in ipairs(alt.tags) do
            assigned[tag] = true
        end
    end
    for _, tag in ipairs((GearFallDB and GearFallDB.settings and GearFallDB.settings.tags) or {}) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = tag.name
        -- no interactive swatch here: a dropdown swatch without a swatchFunc
        -- crashes ColorPickerFrame on confirm; the label carries the color
        info.r = tag.r or 1
        info.g = tag.g or 1
        info.b = tag.b or 1
        info.checked = assigned[tag.name] or nil
        info.keepShownOnClick = true
        info.func = function()
            ToggleAltTag(dropDown.altKey, tag.name)
        end
        UIDropDownMenu_AddButton(info, level)
    end
    local spacer = UIDropDownMenu_CreateInfo()
    spacer.text = " "
    spacer.disabled = true
    spacer.notClickable = true
    UIDropDownMenu_AddButton(spacer, level)
    local manage = UIDropDownMenu_CreateInfo()
    manage.text = "Manage tags..."
    manage.notCheckable = true
    manage.func = function()
        CloseDropDownMenus()
        addon.ShowTagManager()
    end
    UIDropDownMenu_AddButton(manage, level)
end

local function OpenTagDropDown(key)
    if not tagDropDown then
        tagDropDown = CreateFrame("Frame", nil, UIParent, "UIDropDownMenuTemplate")
        tagDropDown.displayMode = "MENU"
    end
    tagDropDown.altKey = key
    UIDropDownMenu_Initialize(tagDropDown, InitializeTagDropDown, "MENU")
    ToggleDropDownMenu(1, nil, tagDropDown, "cursor", 0, 0)
end

-- scoring-mode dropdown: one entry per provider; Pawn expands to an
-- Auto/per-spec + installed-scales submenu, so the scale override does not
-- need its own control per row. The submenu uses the level-aware init
-- pattern (hasArrow + value, same initializer builds level 2) - passing a
-- static info.menuList table re-runs this function and recurses forever.
local modeDropDown

local function SetAltScoringMode(key, mode, scaleName)
    local alt = GearFallDB and GearFallDB.alts[key]
    if not alt then
        return
    end
    alt.scoringMode = mode
    if mode == "PAWN" then
        alt.pawnScaleName = scaleName
    end
    addon.RefreshPriorityList()
end

-- what Pawn itself would call a scale: the raw key is e.g.
-- "\"MrRobot\": PALADIN2", the user-facing label is LocalizedName
local function ScaleDisplayText(name)
    local scales = addon.PawnScales()
    local s = scales and scales[name]
    return (s and s.LocalizedName) or name
end

local function ScoringModeLabel(alt)
    if alt.scoringMode == "PAWN" then
        return "Pawn: " .. (alt.pawnScaleName and ScaleDisplayText(alt.pawnScaleName) or "auto")
    end
    local info = addon.GetScoringProviderInfo(alt.scoringMode or "ITEMLEVEL")
    if info then
        return info.name .. (info.available and "" or " (off)")
    end
    return (alt.scoringMode or "?") .. " (unknown)"
end

-- scales carry ClassID/SpecID (parsed from the scale XML header); ClassID
-- 0/-1 means a generic all-class scale. Filter to the alt's class and sort:
-- its own spec first, then class-generic, then its other specs' scales.
local function PawnScaleNamesFor(alt)
    local list = {}
    local scales = addon.PawnScales()
    if not scales then
        return list
    end
    for name, s in pairs(scales) do
        local classID = type(s.ClassID) == "number" and s.ClassID or 0
        local specID = type(s.SpecID) == "number" and s.SpecID or 0
        if classID <= 0 or not alt.classID or s.ClassID == alt.classID then
            list[#list + 1] = {
                name = name,
                text = s.LocalizedName or name,
                spec = specID,
                specMatch = alt.activeSpecID ~= nil and specID == alt.activeSpecID,
            }
        end
    end
    table.sort(list, function(a, b)
        if a.specMatch ~= b.specMatch then
            return a.specMatch
        end
        local ag, bg = a.spec == 0, b.spec == 0
        if ag ~= bg then
            return ag
        end
        return a.name < b.name
    end)
    return list
end

local function InitializeModeDropDown(dropDown, level)
    -- UIDropDownMenu_Initialize calls this once with no level for MENU
    -- display-mode sizing; only UIDropDownMenu_Show passes real levels
    level = level or 1
    local alt = GearFallDB and GearFallDB.alts[dropDown.altKey]
    if not alt then
        return
    end

    if level > 1 then
        if level == 2 and UIDROPDOWNMENU_MENU_VALUE == "PWNSCALE" then
            local isPawn = alt.scoringMode == "PAWN"
            UIDropDownMenu_AddButton({
                text = "Auto (per spec)",
                checked = (isPawn and not alt.pawnScaleName) or nil,
                func = function()
                    SetAltScoringMode(dropDown.altKey, "PAWN", nil)
                end,
            }, level)
            local scales = PawnScaleNamesFor(alt)
            local storedKnown = alt.pawnScaleName == nil
                or alt.pawnScaleName == ""
            for _, entry in ipairs(scales) do
                if entry.name == alt.pawnScaleName then
                    storedKnown = true
                end
                UIDropDownMenu_AddButton({
                    text = entry.text,
                    checked = (isPawn and alt.pawnScaleName == entry.name) or nil,
                    func = function()
                        SetAltScoringMode(dropDown.altKey, "PAWN", entry.name)
                    end,
                }, level)
            end
            if alt.pawnScaleName and alt.pawnScaleName ~= "" and not storedKnown then
                -- stored scale vanished or belongs to another class: listed
                -- so the row label explains itself, clicking resets to Auto
                local scales = addon.PawnScales()
                local stillExists = scales
                    and scales[alt.pawnScaleName] ~= nil
                UIDropDownMenu_AddButton({
                    text = ("%s (%s - reset to auto)"):format(alt.pawnScaleName,
                        stillExists and "not this class" or "missing"),
                    checked = isPawn or nil,
                    func = function()
                        SetAltScoringMode(dropDown.altKey, "PAWN", nil)
                    end,
                }, level)
            end
        end
        return
    end

    for _, p in ipairs(addon.GetScoringProviderList()) do
        local isCurrent = alt.scoringMode == p.key
        local info = UIDropDownMenu_CreateInfo()
        info.checked = isCurrent or nil
        info.disabled = (not p.available and not isCurrent) or nil
        if p.key == "PAWN" and p.available then
            info.text = p.name .. (isCurrent
                and (": " .. (alt.pawnScaleName and ScaleDisplayText(alt.pawnScaleName) or "auto"))
                or "")
            info.hasArrow = true
            info.value = "PWNSCALE"
        else
            info.text = p.name .. (p.available and "" or " (not available)")
            info.func = function()
                SetAltScoringMode(dropDown.altKey, p.key, alt.pawnScaleName)
            end
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

local function OpenModeDropDown(key)
    if not modeDropDown then
        modeDropDown = CreateFrame("Frame", nil, UIParent, "UIDropDownMenuTemplate")
        modeDropDown.displayMode = "MENU"
    end
    modeDropDown.altKey = key
    UIDropDownMenu_Initialize(modeDropDown, InitializeModeDropDown, "MENU")
    ToggleDropDownMenu(1, nil, modeDropDown, "cursor", 0, 0)
end

-- Per-alt gearing-rule overrides. One shared menu, entries generated from
-- the SETTINGS registry (perAlt = true), checkmark = effective value.
-- Clicking flips the effective value; picking the value that matches the
-- global default clears the override so the row keeps showing "(Default)".
local function ToggleAltRule(key, settingKey)
    local alt = GearFallDB.alts[key]
    if not alt then
        return
    end
    local newValue = not addon.SettingIsOn(settingKey, alt)
    if newValue == addon.SettingIsOn(settingKey, nil) then
        alt[settingKey] = nil
    else
        alt[settingKey] = newValue
    end
    addon.RefreshPriorityList()
end

local rulesDropDown

local function InitializeRulesDropDown(dropDown, level)
    local alt = GearFallDB.alts[dropDown.altKey]
    if not alt then
        return
    end
    for settingKey, def in pairs(addon.SETTINGS) do
        if def.perAlt then
            local info = UIDropDownMenu_CreateInfo()
            info.text = ("%s: %s"):format(def.label,
                addon.SettingIsOn(settingKey, alt) and "On" or "Off")
            info.checked = addon.SettingIsOn(settingKey, alt)
            info.isNotRadio = true
            info.func = function()
                ToggleAltRule(dropDown.altKey, settingKey)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end
end

local function OpenRulesDropDown(key)
    if not rulesDropDown then
        rulesDropDown = CreateFrame("Frame", nil, UIParent, "UIDropDownMenuTemplate")
        rulesDropDown.displayMode = "MENU"
    end
    rulesDropDown.altKey = key
    UIDropDownMenu_Initialize(rulesDropDown, InitializeRulesDropDown, "MENU")
    ToggleDropDownMenu(1, nil, rulesDropDown, "cursor", 0, 0)
end

local PersistPriorityOrder

GearFallPriorityRowMixin = {}

function GearFallPriorityRowMixin:OnLoad()
    self.cells = {}
    local xOffset = 0
    for _, col in ipairs(PRIORITY_COLUMNS) do
        if col.key == "hash" or col.key == "name" or col.key == "level"
            or col.key == "spec" then
            local fs = self:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            fs:SetJustifyH(col.justify)
            fs:SetHeight(24)
            fs:SetWidth(col.width - 4 - (col.padLeft or 0))
            fs:SetPoint("LEFT", self, "LEFT", xOffset + 2 + (col.padLeft or 0), 0)
            self.cells[col.key] = fs
        end
        xOffset = xOffset + col.width
    end

    self.TagsText = self.TagsButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.TagsText:SetPoint("LEFT", self.TagsButton, "LEFT", 4, 0)
    self.TagsText:SetPoint("RIGHT", self.TagsButton, "RIGHT", -4, 0)
    self.TagsText:SetJustifyH("LEFT")

    self.TagsButton:SetScript("OnClick", function()
        OpenTagDropDown(self._key)
    end)

    self.ScoreText = self.ScoreButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.ScoreText:SetPoint("LEFT", self.ScoreButton, "LEFT", 4, 0)
    self.ScoreText:SetPoint("RIGHT", self.ScoreButton, "RIGHT", -4, 0)
    self.ScoreText:SetJustifyH("LEFT")
    self.ScoreButton:SetScript("OnClick", function()
        OpenModeDropDown(self._key)
    end)

    self.RulesText = self.RulesButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.RulesText:SetPoint("LEFT", self.RulesButton, "LEFT", 4, 0)
    self.RulesText:SetPoint("RIGHT", self.RulesButton, "RIGHT", -4, 0)
    self.RulesText:SetJustifyH("LEFT")
    self.RulesButton:SetScript("OnClick", function()
        OpenRulesDropDown(self._key)
    end)

    -- hover: the full alt picture (slots, ilvls, capture warnings)
    self:SetScript("OnEnter", function(row)
        if row._key then
            addon.ShowAltTooltip(row._key)
        end
    end)
    self:SetScript("OnLeave", function()
        GameTooltip_Hide()
    end)

    -- tier divider furniture (also hosts the virtual bottom-tier drop row)
    self.DividerFs = self:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.DividerFs:SetPoint("CENTER", 0, 4)
    self.DividerFs:Hide()
    self.DividerLine = self:CreateTexture(nil, "ARTWORK")
    self.DividerLine:SetHeight(6)
    self.DividerLine:SetPoint("BOTTOMLEFT", 8, 2)
    self.DividerLine:SetPoint("BOTTOMRIGHT", -8, 2)
    self.DividerLine:Hide()
end

local function SetRowDividerMode(row, data)
    -- divider rows, the new-tier drop strip, and the exclusion marker all
    -- render as bare furniture (no alt cells); missing a kind here leaves
    -- the previous occupant's cells visible on the pooled frame
    local furniture = data.kind == "divider" or data.kind == "excludedzone"
        or data.kind == "newtierspace"
    row.cells.hash:SetShown(not furniture)
    row.cells.name:SetShown(not furniture)
    row.cells.level:SetShown(not furniture)
    row.cells.spec:SetShown(not furniture)
    row.TagsButton:SetShown(not furniture)
    row.ScoreButton:SetShown(not furniture)
    row.RulesButton:SetShown(not furniture)
    row.Stripe:SetTexture(nil)
    if data.kind == "excludedzone" then
        row.DividerFs:SetText("Never send upgrades - drop an alt here")
        row.DividerFs:SetTextColor(1, 0.45, 0.4)
        row.DividerFs:Show()
        row.DividerLine:Show()
        row.DividerLine:SetAtlas("ui-journeys-renown-divider", true)
        row.DividerLine:SetVertexColor(0.8, 0.35, 0.3, 0.9)
        return
    end
    if data.kind == "newtierspace" then
        -- the drop strip between the new-tier divider and the exclusion
        -- row: intentionally blank so the region reads as open space
        row.DividerFs:Hide()
        row.DividerLine:Hide()
        return
    end
    if furniture then
        if data.virtual then
            row.DividerFs:SetText("New priority tier - drop an alt in this section")
            row.DividerFs:SetTextColor(0.6, 0.6, 0.65)
        else
            row.DividerFs:SetText(("Priority %d"):format(data.tier))
            row.DividerFs:SetTextColor(0.5, 0.75, 1)
        end
        row.DividerFs:Show()
        row.DividerLine:Show()
        row.DividerLine:SetAtlas("ui-journeys-renown-divider", true)
        row.DividerLine:SetVertexColor(0.5, 0.6, 0.8, 0.9)
    else
        row.DividerFs:Hide()
        row.DividerLine:Hide()
    end
end

function GearFallPriorityRowMixin:Populate(data)
    self._key = nil
    SetRowDividerMode(self, data)
    if data.kind ~= "alt" then
        -- dividers and the exclusion zone carry no alt state; drop-into-tier
        -- is the only drag gesture, so no per-row click handlers here
        self:SetScript("OnClick", nil)
        return
    end
    local alt = GearFallDB.alts[data.key]
    if not alt then
        return
    end
    self._key = data.key

    if data.index % 2 == 0 then
        self.Stripe:SetAtlas("auctionhouse-rowstripe-1")
    else
        self.Stripe:SetAtlas("auctionhouse-rowstripe-2")
    end

    self.cells.hash:SetText((not alt.excluded and alt.prioTier)
        and tostring(alt.prioTier) or "-")
    self.cells.hash:SetTextColor(1, 1, 1)

    local r, g, b = addon.ClassColor(alt.class)
    if alt.excluded then
        r, g, b = r * 0.45, g * 0.45, b * 0.45
    end
    self.cells.name:SetText(addon.AltDisplayName(data.key))
    self.cells.name:SetTextColor(r, g, b)

    self.cells.level:SetText(alt.level and tostring(alt.level) or "?")
    self.cells.level:SetTextColor(0.9, 0.9, 0.9)
    self.cells.spec:SetText(alt.specName or "?")
    self.cells.spec:SetTextColor(0.9, 0.9, 0.9)
    if alt.excluded then
        self.cells.level:SetTextColor(0.45, 0.45, 0.45)
        self.cells.spec:SetTextColor(0.45, 0.45, 0.45)
    end

    local chips = addon.FormatTagChips(alt.tags)
    self.TagsText:SetText(chips ~= "" and chips or "|cff808080+ tags|r")
    self.ScoreText:SetText(ScoringModeLabel(alt))
    local modeInfo = addon.GetScoringProviderInfo(alt.scoringMode or "ITEMLEVEL")
    if modeInfo and not modeInfo.available then
        self.ScoreText:SetTextColor(1, 0.45, 0.4)
    else
        self.ScoreText:SetTextColor(1, 1, 1)
    end
    -- "(Default)" marks inherited values; an asterisk means this row
    -- overrides at least one rule
    local overridden
    for settingKey in pairs(addon.SETTINGS) do
        if alt[settingKey] ~= nil then
            overridden = true
        end
    end
    self.RulesText:SetText(overridden and "Rules*" or "Rules (Default)")
    self.RulesText:SetTextColor(overridden and 1 or 0.8, overridden and 0.82 or 0.8, overridden and 0.4 or 0.8)
    if alt.excluded then
        -- click an excluded alt to restore it as a new bottom tier
        self:SetScript("OnClick", function(row)
            local a = GearFallDB.alts[row._key]
            if not a or not a.excluded then
                return
            end
            a.excluded = false
            local maxTier = 0
            for _, other in pairs(GearFallDB.alts) do
                if not other.excluded and other.prioTier
                    and other.prioTier > maxTier then
                    maxTier = other.prioTier
                end
            end
            a.prioTier = maxTier + 1
            addon.RefreshPriorityList()
        end)
    else
        self:SetScript("OnClick", nil)
    end
end

-- Compact priority tiers: empty tiers collapse and numbers stay
-- contiguous (1..N). Excluded alts are untouched.
function addon.CompactPrioTiers()
    local db = GearFallDB
    if not db then
        return
    end
    local seen = {}
    for _, alt in pairs(db.alts) do
        if not alt.excluded and alt.prioTier then
            seen[alt.prioTier] = true
        end
    end
    local ordered = {}
    for t in pairs(seen) do
        ordered[#ordered + 1] = t
    end
    table.sort(ordered)
    local remap = {}
    for i, t in ipairs(ordered) do
        remap[t] = i
    end
    for _, alt in pairs(db.alts) do
        if not alt.excluded and alt.prioTier then
            alt.prioTier = remap[alt.prioTier]
        end
    end
end

PersistPriorityOrder = function()
    -- drop-into-tier only: the drag's internal reordering is discarded.
    -- The drop destination decides: inside the never-send region (the zone
    -- row or an excluded alt's row) the dragged alt is excluded; anywhere
    -- else it joins the tier whose divider sits above its landing
    -- position. Every other alt keeps its tier, so swaps are impossible.
    local alt = dragKey and GearFallDB.alts[dragKey]
    if dragKey and alt then
        if lastDropExcluded then
            alt.excluded = true
            alt.prioTier = nil
        else
            local landedTier
            for _, entry in priorityProvider:EnumerateEntireRange() do
                if entry.kind == "divider" then
                    landedTier = entry.tier
                elseif entry.key == dragKey then
                    break
                end
            end
            if landedTier then
                alt.excluded = false
                alt.prioTier = landedTier
                addon.CompactPrioTiers()
            end
        end
        lastDropExcluded = nil
        dragKey = nil
    end
    addon.RefreshPriorityList()
end

function addon.RefreshPriorityList()
    if not priorityProvider or not GearFallDB then
        return
    end
    local actives, excluded = {}, {}
    for key, alt in pairs(GearFallDB.alts) do
        local entry = priorityEntries[key]
        if not entry then
            entry = { key = key }
            priorityEntries[key] = entry
        end
        if alt.excluded then
            excluded[#excluded + 1] = entry
        else
            actives[#actives + 1] = entry
        end
    end
    -- tiers are equality groups: within a tier alts read alphabetically
    local byTierThenName = function(a, b)
        local at = (GearFallDB.alts[a.key].prioTier or 9999)
        local bt = (GearFallDB.alts[b.key].prioTier or 9999)
        if at ~= bt then
            return at < bt
        end
        return a.key:lower() < b.key:lower()
    end
    table.sort(actives, byTierThenName)
    table.sort(excluded, byTierThenName)

    local savedOffset = priorityScrollBox:GetDataProvider() and priorityScrollBox:GetScrollPercentage()
    -- rebuild the provider as flat rows: a divider opens each tier, the
    -- trailing virtual divider is the drop target for a new bottom tier,
    -- and the red exclusion zone pins the never-send section
    priorityProvider:Flush()
    local index = 0
    local lastTier
    for _, entry in ipairs(actives) do
        local tier = GearFallDB.alts[entry.key].prioTier or 9999
        if tier ~= lastTier then
            lastTier = tier
            index = index + 1
            priorityProvider:Insert({ kind = "divider", tier = tier })
        end
        index = index + 1
        entry.kind = "alt"
        entry.index = index
        priorityProvider:Insert(entry)
    end
    index = index + 1
    priorityProvider:Insert({ kind = "divider", tier = (lastTier or 0) + 1,
        virtual = true })
    -- the new-tier region needs its own row: without it, drops in the gap
    -- resolve against the exclusion row below and read as "exclude"
    index = index + 1
    priorityProvider:Insert({ kind = "newtierspace" })
    index = index + 1
    priorityProvider:Insert({ kind = "excludedzone" })
    for _, entry in ipairs(excluded) do
        index = index + 1
        entry.kind = "alt"
        entry.index = index
        priorityProvider:Insert(entry)
    end
    if savedOffset and savedOffset >= 0 then
        C_Timer.After(0, function()
            if priorityProvider:GetSize() > 0 then
                priorityScrollBox:SetScrollPercentage(savedOffset)
            end
        end)
    end
end

function addon.BuildPriorityPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetPoint("TOPLEFT", 4, -32)
    page:SetPoint("BOTTOMRIGHT", -6, 5)
    page:Hide()

    local inset = CreateFrame("Frame", nil, page)
    inset:SetPoint("TOPLEFT", 0, -34)
    inset:SetPoint("BOTTOMRIGHT", -20, 0)

    local bg = inset:CreateTexture(nil, "BACKGROUND")
    bg:SetAtlas("auctionhouse-background-index")
    bg:SetPoint("TOPLEFT", 3, -22)
    bg:SetPoint("BOTTOMRIGHT", -3, 3)

    local nineSlice = CreateFrame("Frame", nil, inset, "NineSlicePanelTemplate")
    nineSlice:SetPoint("TOPLEFT", 0, -19)
    nineSlice:SetPoint("BOTTOMRIGHT")

    local headerContainer = CreateFrame("Frame", nil, inset)
    headerContainer:SetHeight(19)
    headerContainer:SetPoint("TOPLEFT", 4, -1)
    headerContainer:SetPoint("TOPRIGHT", -4, -1)
    local xOffset = 0
    for _, col in ipairs(PRIORITY_COLUMNS) do
        local btn = CreateFrame("Button", nil, headerContainer, "ColumnDisplayButtonShortTemplate")
        btn:SetSize(col.width, 19)
        btn:SetPoint("LEFT", headerContainer, "LEFT", xOffset, 0)
        btn:SetText(col.label)
        btn:SetNormalFontObject(GameFontHighlightSmall)
        btn:GetFontString():SetJustifyH(col.justify or "LEFT")
        btn:SetEnabled(false)
        xOffset = xOffset + col.width
    end

    local scrollBox = CreateFrame("Frame", nil, inset, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", headerContainer, "BOTTOMLEFT", 0, -6)
    scrollBox:SetPoint("RIGHT", headerContainer, "RIGHT")
    scrollBox:SetPoint("BOTTOM", inset, "BOTTOM", 0, 3)

    local scrollBar = CreateFrame("EventFrame", nil, inset, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 9, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 9, 4)

    local view = CreateScrollBoxListLinearView()
    view:SetElementInitializer("GearFallPriorityRowTemplate", function(row, elementData)
        row:Populate(elementData)
    end)
    view:SetElementExtent(24)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    priorityScrollBox = scrollBox
    priorityProvider = CreateDataProvider()
    scrollBox:SetDataProvider(priorityProvider)

    local dragBehavior = ScrollUtil.InitDefaultLinearDragBehavior(scrollBox)
    dragBehavior:SetReorderable(true)
    dragBehavior:SetDragPredicate(function(_frame, elementData)
        -- every alt row is draggable (excluded alts too: drag one back into
        -- a tier to restore it); dividers and the exclusion zone are not.
        -- The dragged key is remembered: PersistPriorityOrder only re-tiers
        -- this one alt, so drops can never reorder anyone else.
        local draggable = elementData.kind == "alt"
            and GearFallDB.alts[elementData.key] ~= nil
        if draggable then
            dragKey = elementData.key
        end
        return draggable
    end)
    dragBehavior:SetDropPredicate(function(_sourceElementData, intersectData)
        -- record the final hovered destination: drops onto the zone row or
        -- an excluded alt's row mean "never send", regardless of whether
        -- the resolver inserts the row above or below it
        local dest = intersectData and intersectData.elementData
        if dest then
            if dest.kind == "excludedzone" then
                lastDropExcluded = true
            else
                local destAlt = GearFallDB.alts[dest.key]
                lastDropExcluded = (destAlt ~= nil and destAlt.excluded) or nil
            end
        end
        return true
    end)
    dragBehavior:SetPostDrop(function()
        PersistPriorityOrder()
    end)

    return page
end

-- The Settings tab keeps the global gearing-rule band (checkboxes, the
-- strategy dropdown, the Tags manager entry); the priority list itself
-- lives on the Roster tab (BuildPriorityPage).
function addon.BuildSettingsPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetPoint("TOPLEFT", 4, -32)
    page:SetPoint("BOTTOMRIGHT", -6, 5)
    page:Hide()

    local manageButton = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    manageButton:SetSize(80, 19)
    manageButton:SetText("Tags")
    -- sits in the reserved band above the list, EM-style, clear of
    -- the frame border
    manageButton:SetPoint("TOPRIGHT", page, "TOPRIGHT", -6, -2)
    manageButton:SetScript("OnClick", function()
        addon.ShowTagManager()
    end)

    -- global gearing-rule defaults, one checkbox per boolean registry entry,
    -- in a stable (sorted) order; per-alt overrides live on the priority rows.
    -- choice-type entries render as dropdowns instead.
    local ruleChecks = {}
    local choiceSyncs = {}
    local orderedSettings = {}
    for settingKey in pairs(addon.SETTINGS) do
        orderedSettings[#orderedSettings + 1] = settingKey
    end
    table.sort(orderedSettings)
    -- clear of the portrait-frame corner art that overlaps the page's top
    -- band on the left (the alphabetically-first checkbox lands at x=0
    -- otherwise, hidden behind the logo); rows stack vertically downward
    local checkX = 120
    local checkY = -2
    for _, settingKey in ipairs(orderedSettings) do
        local def = addon.SETTINGS[settingKey]
        if def.type == "choice" then
            local dd = CreateFrame("Frame", "GearFallSetting" .. settingKey
                .. "DropDown", page, "UIDropDownMenuTemplate")
            dd:SetPoint("TOPLEFT", page, "TOPLEFT", checkX, checkY)
            UIDropDownMenu_SetWidth(dd, 150)
            local function initDrop(d, level)
                for _, opt in ipairs(def.options) do
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = opt.label
                    info.checked = addon.SettingChoice(settingKey) == opt.key
                    info.func = function()
                        GearFallDB.settings[settingKey] = opt.key
                        addon.RefreshPriorityList()
                        local df = _G.GearFallDistributionFrame
                        if df and df.IsShown and df:IsShown() then
                            addon.RefreshDistribution(true)
                        end
                        UIDropDownMenu_SetText(dd, opt.label)
                    end
                    UIDropDownMenu_AddButton(info, level)
                end
                -- re-assert the box text on every open
                local current = addon.SettingChoice(settingKey)
                for _, opt in ipairs(def.options) do
                    if opt.key == current then
                        UIDropDownMenu_SetText(dd, opt.label)
                    end
                end
            end
            UIDropDownMenu_Initialize(dd, initDrop)
            choiceSyncs[#choiceSyncs + 1] = function()
                local current = addon.SettingChoice(settingKey)
                for _, opt in ipairs(def.options) do
                    if opt.key == current then
                        UIDropDownMenu_SetText(dd, opt.label)
                    end
                end
            end
            checkY = checkY - 46
        else
            local cb = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
            cb:SetPoint("TOPLEFT", page, "TOPLEFT", checkX, checkY)
            cb._gfSetting = settingKey
            if cb.Text then
                cb.Text:SetText(def.label)
            end
            ruleChecks[#ruleChecks + 1] = cb
            cb:SetScript("OnClick", function(self)
                GearFallDB.settings[settingKey] = self:GetChecked() and true or false
                addon.RefreshPriorityList()
                local df = _G.GearFallDistributionFrame
                if df and df.IsShown and df:IsShown() then
                    addon.RefreshDistribution(true)
                end
            end)
            checkY = checkY - 30
        end
    end
    local function SyncRuleChecks()
        for _, cb in ipairs(ruleChecks) do
            cb:SetChecked(addon.SettingIsOn(cb._gfSetting, nil))
        end
        for _, sync in ipairs(choiceSyncs) do
            sync()
        end
    end
    SyncRuleChecks()
    page:SetScript("OnShow", SyncRuleChecks)

    return page
end

local _, addon = ...

-- Tag manager popup: registry editing (create/recolor/delete tags) shared by
-- the Settings tab's Tags button and every priority row's tag dropdown.

local tagManager
local tagManagerRows = {}
local TAG_PALETTE = {
    { 0.9, 0.3, 0.3 }, { 0.3, 0.8, 0.3 }, { 0.4, 0.6, 1.0 },
    { 1.0, 0.8, 0.2 }, { 0.8, 0.4, 1.0 }, { 1.0, 0.5, 0.2 },
    { 0.2, 0.8, 0.8 }, { 1.0, 0.4, 0.7 },
}
local pendingAddColor = { r = TAG_PALETTE[1][1], g = TAG_PALETTE[1][2], b = TAG_PALETTE[1][3] }

local function refreshAddSwatch()
    if tagManager and tagManager.AddSwatch then
        tagManager.AddSwatch.Fill:SetColorTexture(
            pendingAddColor.r or 1, pendingAddColor.g or 1, pendingAddColor.b or 1)
    end
end
pendingAddColor.refresh = refreshAddSwatch

local OpenColorPicker
local RebuildTagManager

local function applyAfterColorChange(holder)
    RebuildTagManager()
    if holder.refresh then
        holder.refresh()
    end
    addon.RefreshPriorityList()
    addon.RefreshPriorityList()
end

RebuildTagManager = function()
    if not tagManager then
        return
    end
    local tags = GearFallDB.settings.tags
    for _, row in ipairs(tagManagerRows) do
        row:Hide()
    end
    for i, tag in ipairs(tags) do
        local row = tagManagerRows[i]
        if not row then
            row = CreateFrame("Frame", nil, tagManager)
            row:SetHeight(22)
            row.Swatch = CreateFrame("Button", nil, row)
            row.Swatch:SetSize(18, 18)
            row.Swatch:SetPoint("LEFT", 12, 0)
            row.Swatch.Border = row.Swatch:CreateTexture(nil, "BORDER")
            row.Swatch.Border:SetColorTexture(0, 0, 0, 1)
            row.Swatch.Border:SetAllPoints()
            row.Swatch.Fill = row.Swatch:CreateTexture(nil, "OVERLAY")
            row.Swatch.Fill:SetPoint("TOPLEFT", 1, -1)
            row.Swatch.Fill:SetPoint("BOTTOMRIGHT", -1, 1)
            row.Swatch:SetScript("OnClick", function(swatch)
                local bound = swatch:GetParent().tag
                if bound then
                    OpenColorPicker(bound)
                end
            end)
            row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.Name:SetPoint("LEFT", row.Swatch, "RIGHT", 8, 0)
            row.Delete = CreateFrame("Button", nil, row, "UIPanelCloseButton")
            row.Delete:SetSize(20, 20)
            row.Delete:SetPoint("RIGHT", -4, 0)
            row.Delete:SetScript("OnClick", function(btn)
                local bound = btn:GetParent().tag
                if bound then
                    addon.DeleteTag(bound.name)
                end
            end)
            tagManagerRows[i] = row
        end
        row.tag = tag
        row.Name:SetText(tag.name)
        row.Swatch.Fill:SetColorTexture(tag.r or 1, tag.g or 1, tag.b or 1)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 8, -40 - (i - 1) * 24)
        row:SetPoint("TOPRIGHT", -20, -40 - (i - 1) * 24)
        row:Show()
    end
    tagManager:SetHeight(100 + #tags * 24)
end

OpenColorPicker = function(holder)
    ColorPickerFrame:SetupColorPickerAndShow({
        r = holder.r or 1,
        g = holder.g or 1,
        b = holder.b or 1,
        hasOpacity = false,
        swatchFunc = function()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            holder.r, holder.g, holder.b = r, g, b
            applyAfterColorChange(holder)
        end,
        cancelFunc = function(previous)
            holder.r, holder.g, holder.b = previous.r, previous.g, previous.b
            applyAfterColorChange(holder)
        end,
    })
end

function addon.DeleteTag(name)
    local tags = GearFallDB.settings.tags
    for i, tag in ipairs(tags) do
        if tag.name == name then
            table.remove(tags, i)
            break
        end
    end
    for _, alt in pairs(GearFallDB.alts) do
        if alt.tags then
            for i = #alt.tags, 1, -1 do
                if alt.tags[i] == name then
                    table.remove(alt.tags, i)
                end
            end
        end
    end
    RebuildTagManager()
    addon.RefreshPriorityList()
    addon.RefreshPriorityList()
end

function addon.AddTag(name)
    name = (name or ""):match("^%s*(.-)%s*$")
    if name == "" then
        return
    end
    local tags = GearFallDB.settings.tags
    for _, tag in ipairs(tags) do
        if tag.name == name then
            return
        end
    end
    local pick = TAG_PALETTE[(#tags % #TAG_PALETTE) + 1]
    table.insert(tags, { name = name, r = pendingAddColor.r, g = pendingAddColor.g, b = pendingAddColor.b })
    pendingAddColor.r, pendingAddColor.g, pendingAddColor.b = pick[1], pick[2], pick[3]
    refreshAddSwatch()
    RebuildTagManager()
    addon.RefreshPriorityList()
    addon.RefreshPriorityList()
end

local function BuildTagManager()
    tagManager = CreateFrame("Frame", "GearFallTagManager", UIParent,
        "BackdropTemplate")
    tagManager:SetSize(300, 148)
    tagManager:SetPoint("CENTER")
    tagManager:SetFrameStrata("DIALOG")
    tagManager:SetToplevel(true)
    tagManager:SetMovable(true)
    tagManager:EnableMouse(true)
    tagManager:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    tagManager:SetBackdropColor(0.06, 0.06, 0.09, 0.95)
    tagManager:RegisterForDrag("LeftButton")
    tagManager:SetScript("OnDragStart", tagManager.StartMoving)
    tagManager:SetScript("OnDragStop", tagManager.StopMovingOrSizing)
    tagManager:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    local title = tagManager:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", tagManager, "TOP", 0, -24)
    title:SetText("Tags")

    local close = CreateFrame("Button", nil, tagManager, "UIPanelCloseButton")
    close:SetSize(26, 26)
    close:SetPoint("TOPRIGHT", tagManager, "TOPRIGHT", -2, -2)

    tagManager.AddSwatch = CreateFrame("Button", nil, tagManager)
    tagManager.AddSwatch:SetSize(18, 18)
    tagManager.AddSwatch:SetPoint("BOTTOMLEFT", 14, 18)
    tagManager.AddSwatch.Border = tagManager.AddSwatch:CreateTexture(nil, "BORDER")
    tagManager.AddSwatch.Border:SetColorTexture(0, 0, 0, 1)
    tagManager.AddSwatch.Border:SetAllPoints()
    tagManager.AddSwatch.Fill = tagManager.AddSwatch:CreateTexture(nil, "OVERLAY")
    tagManager.AddSwatch.Fill:SetPoint("TOPLEFT", 1, -1)
    tagManager.AddSwatch.Fill:SetPoint("BOTTOMRIGHT", -1, 1)
    tagManager.AddSwatch:SetScript("OnClick", function()
        OpenColorPicker(pendingAddColor)
    end)
    refreshAddSwatch()

    tagManager.AddBox = CreateFrame("EditBox", nil, tagManager, "InputBoxTemplate")
    tagManager.AddBox:SetSize(160, 20)
    tagManager.AddBox:SetPoint("LEFT", tagManager.AddSwatch, "RIGHT", 10, 0)
    tagManager.AddBox:SetAutoFocus(false)
    tagManager.AddBox:SetMaxLetters(32)
    tagManager.AddBox:SetScript("OnEnterPressed", function(edit)
        addon.AddTag(edit:GetText())
        edit:SetText("")
        edit:ClearFocus()
    end)

    local addButton = CreateFrame("Button", nil, tagManager, "UIPanelButtonTemplate")
    addButton:SetSize(70, 22)
    addButton:SetPoint("LEFT", tagManager.AddBox, "RIGHT", 8, 0)
    addButton:SetText("Add")
    addButton:SetScript("OnClick", function()
        addon.AddTag(tagManager.AddBox:GetText())
        tagManager.AddBox:SetText("")
    end)

    tagManager:SetScript("OnShow", RebuildTagManager)
end

function addon.ShowTagManager()
    if not tagManager then
        BuildTagManager()
    end
    RebuildTagManager()
    tagManager:Show()
    tagManager:Raise()
end

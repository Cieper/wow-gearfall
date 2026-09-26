local _, addon = ...

-- History tab: chronological log of everything mailed, newest first.

local historyProvider
local historyEmptyText

function addon.RefreshHistoryUI()
    if not historyProvider then
        return
    end
    historyProvider:Flush()
    local hist = GearFallDB and GearFallDB.sendHistory or {}
    for i = #hist, 1, -1 do
        local e = hist[i]
        historyProvider:Insert({
            text = ("%s  %s  ->  %s"):format(
                date("%b %d %H:%M", e.t or 0),
                addon.FormatItem(e), e.to or "?"),
        })
    end
    if historyEmptyText then
        historyEmptyText:SetShown(#hist == 0)
    end
end

function addon.BuildHistoryPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetPoint("TOPLEFT", 4, -32)
    page:SetPoint("BOTTOMRIGHT", -6, 5)
    page:Hide()

    local inset = CreateFrame("Frame", nil, page)
    inset:SetPoint("TOPLEFT", 8, -8)
    inset:SetPoint("BOTTOMRIGHT", -8, 0)

    local nineSlice = CreateFrame("Frame", nil, inset, "NineSlicePanelTemplate")
    nineSlice:SetPoint("TOPLEFT", 0, -19)
    nineSlice:SetPoint("BOTTOMRIGHT")

    local header = inset:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", 8, -4)
    header:SetText("Sent items")

    local scrollBox = CreateFrame("Frame", nil, inset, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", 4, -24)
    scrollBox:SetPoint("BOTTOMRIGHT", -22, 3)

    local scrollBar = CreateFrame("EventFrame", nil, inset, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)

    local view = CreateScrollBoxListLinearView()
    view:SetElementInitializer("GearFallHistoryRowTemplate", function(row, elementData)
        row.Text:SetText(elementData.text)
    end)
    view:SetElementExtent(20)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    historyProvider = CreateDataProvider()
    scrollBox:SetDataProvider(historyProvider)

    historyEmptyText = inset:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    historyEmptyText:SetPoint("CENTER", inset, "CENTER", 0, 40)
    historyEmptyText:SetText("Nothing mailed yet.\nOpen a mailbox with sendable upgrades to get started.")

    return page
end

local _, addon = ...

-- Dashboard assembler: builds the frame, wires the four tab pages (built by
-- their own modules) and the tab-callback refreshes. Per-tab code lives in
-- UI_Shared / UI_Roster / UI_Sendable / UI_Priority / UI_Tags / UI_History.

local dashboard

function addon.BuildDashboard()
    local f = CreateFrame("Frame", "GearFallFrame", UIParent, "PortraitFrameTemplate")
    f:SetSize(800, 538)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.SetTitle then
        f:SetTitle("GearFall")
    end
    if f.SetPortraitToAsset then
        f:SetPortraitToAsset("Interface\\Icons\\inv_misc_enggizmos_30")
    end
    tinsert(UISpecialFrames, f:GetName())

    local tabSystem = CreateFrame("Frame", nil, f, "TabSystemTemplate")
    tabSystem:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 11, 2)
    Mixin(f, TabSystemOwnerMixin)
    TabSystemOwnerMixin.OnLoad(f)
    f:SetTabSystem(tabSystem)

    local rosterPage = addon.BuildPriorityPage(f)
    local itemsPage = addon.BuildItemsPage(f)
    local settingsPage = addon.BuildSettingsPage(f)
    local historyPage = addon.BuildHistoryPage(f)

    f.tabIDs = {
        roster = f:AddNamedTab("Roster", rosterPage),
        items = f:AddNamedTab("Sendable", itemsPage),
        history = f:AddNamedTab("History", historyPage),
        settings = f:AddNamedTab("Settings", settingsPage),
    }
    f:SetTabCallback(f.tabIDs.roster, function()
        addon.RefreshPriorityList()
    end)
    f:SetTabCallback(f.tabIDs.history, function()
        addon.RefreshHistoryUI()
    end)

    local priorOnShow = f:GetScript("OnShow")
    f:SetScript("OnShow", function(self)
        if priorOnShow then
            priorOnShow(self)
        end
        if not self.defaultTabApplied then
            self.defaultTabApplied = true
            self:SetTab(self.tabIDs.roster)
        end
        addon.RefreshPriorityList()
    end)
    f:Hide()

    return f
end

function addon.ToggleDashboard()
    if not dashboard then
        local ok, err = pcall(function()
            dashboard = addon.BuildDashboard()
        end)
        if not ok or not dashboard then
            addon.Print("dashboard build FAILED: " .. tostring(err))
            return
        end
    end
    if dashboard:IsShown() then
        dashboard:Hide()
    else
        dashboard:Show()
    end
end

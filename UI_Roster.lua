local _, addon = ...

-- Roster tab helpers. The tab itself is the priority list (UI_Priority.lua);
-- this file only keeps the shared alt tooltip.

function addon.ShowAltTooltip(key)
    local alt = GearFallDB and GearFallDB.alts[key]
    if not alt then
        return
    end
    GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
    local r, g, b = addon.ClassColor(alt.class)
    GameTooltip:AddLine(addon.AltDisplayName(key), r, g, b)
    GameTooltip:AddLine(("Level %d %s %s (%s)"):format(
        alt.level or 0, alt.specName or "?", alt.class or "?", alt.role or "?"), 1, 1, 1)
    if alt.avgItemLevel then
        GameTooltip:AddLine(("Average item level: %.1f"):format(alt.avgItemLevel), 1, 1, 1)
    end
    if alt.slots then
        GameTooltip:AddLine(" ")
        for _, slot in ipairs(addon.EQUIP_SLOTS) do
            local equipped = alt.slots[slot]
            if equipped then
                GameTooltip:AddLine(("  %-9s %3d  %s"):format(
                    addon.SLOT_NAMES[slot] or "?", equipped.itemLevel or 0,
                    addon.FormatItem(equipped)), 1, 1, 1, true)
            end
        end
    end
    local issues = addon.GetAltSlotIssues(alt)
    if #issues > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Data problems (relog the alt to recapture):", 1, 0.4, 0.4)
        for _, line in ipairs(issues) do
            GameTooltip:AddLine(("  |cffff6060!|r %s"):format(line), 1, 1, 1)
        end
    end
    GameTooltip:Show()
end

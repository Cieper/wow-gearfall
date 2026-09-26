local _, addon = ...

-- Shared UI helpers used by more than one tab module. Everything crossing
-- tab boundaries must live here or hang off `addon` - the tab files keep
-- their per-tab state file-local.

function addon.ClassColor(classToken)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if c then
        return c.r, c.g, c.b
    end
    return 1, 1, 1
end

function addon.GetTagRGB(name)
    local registry = GearFallDB and GearFallDB.settings and GearFallDB.settings.tags
    if registry then
        for _, tag in ipairs(registry) do
            if tag.name == name then
                return tag.r or 1, tag.g or 1, tag.b or 1
            end
        end
    end
end

function addon.FormatTagChips(tags)
    if not tags or #tags == 0 then
        return ""
    end
    local parts = {}
    for _, name in ipairs(tags) do
        local r, g, b = addon.GetTagRGB(name)
        if r then
            parts[#parts + 1] = ("|cff%02x%02x%02x[%s]|r"):format(
                math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5),
                name)
        end
    end
    return table.concat(parts, " ")
end

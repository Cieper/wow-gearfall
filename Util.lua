local _, addon = ...

addon.EQUIP_SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 }

addon.SLOT_NAMES = {
    [1] = "HEAD", [2] = "NECK", [3] = "SHOULDER", [5] = "CHEST", [6] = "WAIST",
    [7] = "LEGS", [8] = "FEET", [9] = "WRISTS", [10] = "HANDS", [11] = "FINGER1",
    [12] = "FINGER2", [13] = "TRINKET1", [14] = "TRINKET2", [15] = "BACK",
    [16] = "MAINHAND", [17] = "OFFHAND",
}

-- realm-aware alt display name: "Mage-Stormrage" shows as "Mage" when we
-- are logged in on Stormrage and keeps the realm suffix for alts from other
-- realms; keys without a realm pass through untouched
function addon.AltDisplayName(key)
    if not key then
        return "?"
    end
    local name, realm = key:match("^([^-]+)%-(.+)$")
    if not name then
        return key
    end
    local here = GetRealmName and GetRealmName()
    if realm and here and realm ~= here then
        return name .. "-" .. realm
    end
    return name
end

function addon.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffb347GearFall|r: " .. tostring(msg))
end

function addon.PlayerKey()
    local name = UnitName("player")
    if not name then
        return nil
    end
    if name:find("-", 1, true) then
        return name
    end
    local realm = GetRealmName and GetRealmName()
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

function addon.GetActiveSpecInfo()
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization and C_SpecializationInfo.GetSpecializationInfo then
        local index = C_SpecializationInfo.GetSpecialization()
        if index then
            local specID, name, _, _, role = C_SpecializationInfo.GetSpecializationInfo(index)
            if role == "DAMAGER" then
                role = "DPS"
            end
            return specID, name, role
        end
    end
end

-- only the integer inspect level is trustworthy; the legacy
-- GetAverageItemLevel returns garbage fractions mid-load
function addon.GetAvgItemLevel()
    if C_PaperDollInfo and C_PaperDollInfo.GetInspectItemLevel then
        local level = C_PaperDollInfo.GetInspectItemLevel("player")
        if level and level > 0 then
            return level
        end
    end
end

-- itemLevel embedded in the link's 4th field; fallback when the item detail
-- API is still uncached
local function GetCachedItemLevel(link)
    if type(link) == "string" then
        return tonumber(link:match("item:%d+:%d+:%d+:(%d+)"))
    end
end

-- The DETAILED level API can answer with garbage for some scaling items:
-- "Band of Twisted Bark" (Midnight 120100) reports actual=548 while the
-- tooltip and C_Item.GetItemInfo say 79, and its base return is `false`.
-- A numeric base means the API understood the item (Heirlooms, upgrade
-- tracks, normal gear) and actual is trustworthy; anything else falls
-- through to the static sources.
function addon.GetItemLevel(itemLink)
    if not itemLink then
        return nil
    end
    local fn = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo
    if fn then
        local actual, base = fn(itemLink)
        if type(actual) == "number" and actual > 0
            and type(base) == "number" then
            return actual
        end
    end
    if C_Item and C_Item.GetItemInfo then
        -- GetItemInfo order: name, link, quality, itemLevel (see SRS §9)
        local ok, _, _, _, itemLevel = pcall(C_Item.GetItemInfo, itemLink)
        if ok and type(itemLevel) == "number" and itemLevel > 0 then
            return itemLevel
        end
    end
    return GetCachedItemLevel(itemLink)
end

-- Canonical storage format is the raw "item:..." link. The client hands out
-- either exactly that (containers) or the display form
-- ("|cnIQ3:|Hitem:123:...|h[Name]|h"); anything else is not an item link.
function addon.NormalizeItemLink(link)
    if type(link) ~= "string" then
        return nil
    end
    if link:find("^item:") then
        return link
    end
    return link:match("|H(item:[^|]+)|h")
end

-- The item's ID from any link form: canonical storage is the raw
-- "item:..." string, but links also arrive display-rendered
-- ("|cnIQ3:|Hitem:123:...|h[Name]|h|r" - chat args, API re-renders), so
-- read the ID from either. Identity keys (roster slots, loot plans) must
-- never depend on the link's suffix/form surviving a round-trip.
function addon.GetItemID(link)
    if type(link) ~= "string" then
        return nil
    end
    return tonumber(link:match("^item:(%d+)"))
        or tonumber(link:match("|Hitem:(%d+)"))
end

-- Pawn's addon namespace, read via _G so linters without third-party stubs
-- stay quiet; nil whenever Pawn is not installed
function addon.PawnScales()
    local pawn = _G.PawnCommon
    return pawn and pawn.Scales or nil
end

-- "WARRIOR" -> "Warrior" (localized full name when available)
function addon.PrettyClass(token)
    if not token or type(token) ~= "string" then
        return "?"
    end
    -- via _G so linters without full Blizzard stubs stay quiet
    local names = _G.LOCALIZED_CLASS_NAMES_ENGLISH
    local name = names and names[token]
    if name then
        return name
    end
    return token:sub(1, 1) .. token:sub(2):lower()
end

-- Quality color without the deprecated GetItemQualityColor global;
-- ITEM_QUALITY_COLORS is the FrameXML table the modern client maintains
function addon.QualityColor(quality)
    local c = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if c then
        return c.r, c.g, c.b
    end
    return 1, 1, 1
end

-- Localized spec name for a specID (raw ID fallback when unresolvable)
function addon.SpecName(specID)
    local ok, _, name = pcall(GetSpecializationInfoByID, specID)
    return (ok and name) and name or tostring(specID)
end

-- Clickable chat link from a raw link or bare itemID, even when the item is
-- not in the local cache: GetItemInfo first, then GetItemNameByID, then a
-- label-shell hyperlink (still clickable, triggers a fetch). Raw links are
-- plain text in chat, so user-facing messages must always use this.
function addon.ClickableItemLink(link, itemID)
    local query = link or (itemID and itemID > 0 and ("item:" .. itemID) or nil)
    if query then
        if C_Item and C_Item.GetItemInfo then
            local ok, name, _, quality = pcall(C_Item.GetItemInfo, query)
            if ok and name then
                return addon.FormatItem({ itemLink = query, name = name,
                    quality = quality })
            end
        end
        if C_Item and C_Item.GetItemNameByID and itemID then
            local ok, name = pcall(C_Item.GetItemNameByID, itemID)
            if ok and name then
                return ("|cff9d9d9d|H%s|h[%s]|h|r"):format(query, name)
            end
        end
        if itemID and C_Item and C_Item.RequestLoadItemData then
            pcall(C_Item.RequestLoadItemData, itemID)
        end
        return ("|cff9d9d9d|H%s|h[item %d]|h|r"):format(query, itemID or 0)
    end
    return "item " .. tostring(itemID)
end

-- Renders a stored slot/candidate snapshot ({itemLink, name, quality}) as a
-- colored clickable link.
function addon.FormatItem(item)
    if not item or not item.itemLink or not item.name then
        return "|cff808080(uncached)|r"
    end
    local r, g, b = addon.QualityColor(item.quality)
    return ("|cff%02x%02x%02x|H%s|h[%s]|h|r"):format(
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5), item.itemLink, item.name)
end

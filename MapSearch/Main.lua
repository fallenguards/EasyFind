local _, ns = ...

local MapSearch = {}
ns.MapSearch = MapSearch

local Utils     = ns.Utils
local pairs, ipairs, type = Utils.pairs, Utils.ipairs, Utils.type
local tinsert, tremove = Utils.tinsert, Utils.tremove
local sfind = Utils.sfind
local MapSearchData = ns.MapSearchData
local CATEGORY_ICONS = MapSearchData.CATEGORY_ICONS
local CATEGORIES = MapSearchData.CATEGORIES



local function GetMapPinKey(data)
    if data.isZone and data.zoneMapID then
        return "zone:" .. data.zoneMapID
    end
    return (data.category or "unknown") .. ":" .. (data.name or "") .. ":" .. (data.mapID or "")
end

local function CleanForStorage(data)
    local clean = {}
    for k, v in pairs(data) do
        local t = type(v)
        if t == "string" or t == "number" or t == "boolean" then
            clean[k] = v
        end
    end
    return clean
end

local function IsMapItemPinned(data)
    local key = GetMapPinKey(data)
    for _, pin in ipairs(EasyFind.db.pinnedMapItems) do
        if GetMapPinKey(pin) == key then return true end
    end
    return false
end

local function PinMapItem(data)
    if IsMapItemPinned(data) then return end
    local clean = CleanForStorage(data)
    clean.isPinned = true
    -- Default freshly-pinned parent to collapsed; user toggles write back
    -- to this same entry so state survives map close, /reload, and logout.
    if data.isZone and data.zoneMapID and clean.collapsed == nil then
        clean.collapsed = true
    end
    tinsert(EasyFind.db.pinnedMapItems, clean)
end

local function UnpinMapItem(data)
    local key = GetMapPinKey(data)
    local items = EasyFind.db.pinnedMapItems
    for i = #items, 1, -1 do
        if GetMapPinKey(items[i]) == key then
            tremove(items, i)
            return
        end
    end
end

MapSearch.GetMapPinKey  = function(_, data) return GetMapPinKey(data) end
MapSearch.IsMapItemPinned = function(_, data) return IsMapItemPinned(data) end
MapSearch.PinMapItem   = function(_, data) return PinMapItem(data) end
MapSearch.UnpinMapItem = function(_, data) return UnpinMapItem(data) end

local function GetCategoryIcon(category)
    return CATEGORY_ICONS[category] or CATEGORY_ICONS.unknown
end

ns.MapSearch = ns.MapSearch or MapSearch
ns.MapSearch.GetCategoryIcon = GetCategoryIcon

local function GetFilterBucket(data)
    if not data then return "other" end
    -- Dungeons/raids/delves carry isZone=true; check category first.
    local cat = data.category
    if cat == "dungeon" or cat == "raid" or cat == "delve" then return "instances" end
    if data.isZone then return "zones" end
    if not cat then return "other" end
    if cat == "rare" then return "rares" end
    if cat == "npc" then return "npcs" end
    local parent = CATEGORIES[cat] and CATEGORIES[cat].parent
    if parent == "instance" then return "instances" end
    if parent == "travel" then return "travel" end
    if parent == "service" or cat == "service" then return "services" end
    -- StaticLocations subcategories (classtrainer_*, prof_*, etc.) bucket here.
    if sfind(cat, "^classtrainer_") or sfind(cat, "^prof_") then return "services" end
    if cat == "guildbank" or cat == "guildservices" or cat == "trainingdummy" then return "services" end
    return "other"
end
ns.MapSearch.GetFilterBucket = GetFilterBucket

-- Fine-grained sub-buckets within a parent bucket. A result must pass BOTH its
-- parent bucket and its sub-bucket. Categories with no entry have no sub-filter.
-- flightmaster now buckets to "travel" (flights sub), folding the old separate
-- "flightpath" bucket into travel alongside boats and portals.
local SUBBUCKET = {
    raid = "raid", dungeon = "dungeon", delve = "delve",
    flightmaster = "flights", boat = "boats", zeppelin = "boats",
    portal = "portals", tram = "portals",
    bank = "banks", guildbank = "banks",
    auctionhouse = "auction",
    innkeeper = "inns",
    mailbox = "mail",
    trainer = "trainers",
    vendor = "vendors", pvpvendor = "vendors", quartermaster = "vendors",
    repairvendor = "vendors", upgradevendor = "vendors",
    tradingpost = "vendors", decor = "vendors",
    transmogrifier = "appearance", barber = "appearance",
}
ns.MapSearch.SUBBUCKET = SUBBUCKET

-- bucket is optional (computed when absent). Trainer subcategories match by
-- prefix; any other category bucketing to services lands in the catch-all.
local function GetSubBucket(data, bucket)
    local cat = data and data.category
    if not cat then return nil end
    local sub = SUBBUCKET[cat]
    if sub then return sub end
    if not bucket then bucket = GetFilterBucket(data) end
    if bucket == "services" then
        if sfind(cat, "^classtrainer_") or sfind(cat, "^prof_") then return "trainers" end
        return "otherservices"
    end
    return nil
end
ns.MapSearch.GetSubBucket = GetSubBucket

-- Single owner for "does this result pass the given filter table": parent
-- bucket must be enabled AND, if the category has a sub-bucket, that sub too.
local function PassesFilter(data, filters)
    if not filters then return true end
    local bucket = GetFilterBucket(data)
    if filters[bucket] == false then return false end
    local sub = GetSubBucket(data, bucket)
    if sub and filters[sub] == false then return false end
    return true
end
ns.MapSearch.PassesFilter = PassesFilter

function MapSearch:Initialize()
    self:CreateHighlightFrame()
    self:CreateZoneHighlightFrame()
    self:HookWorldMap()
    if Utils.SafeAfter then
        Utils.SafeAfter(0.8, function()
            if MapSearch.WarmUISearchCaches then MapSearch:WarmUISearchCaches() end
        end)
    end
end


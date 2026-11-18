local _, ns = ...

-- Where an item comes from, as a page in the bar: who sells it (the GPS
-- extension's vendors, nearest first), which bosses drop it, and what the
-- extensions add (EasyFind.API.RegisterItemSources). A click on an item
-- row opens it (Gestures: sources); typing narrows the rows.
local ItemSources = {}
ns.ItemSources = ItemSources

local L, Utils = ns.L, ns.Utils
local ipairs, type = Utils.ipairs, Utils.type
local slower, sformat, sfind = Utils.slower, Utils.sformat, Utils.sfind

local added = {}
local itemLoads = CreateFrame("Frame")
local refreshPending = false
local tsort = table.sort

local function ItemName(id)
    local name = C_Item.GetItemNameByID(id)
    if type(name) == "string" and name ~= "" then return name end
    return nil
end

-- An extension's sources: its rows under a heading of its name.
function ItemSources.Register(id, label, fn)
    for i = 1, #added do
        if added[i].id == id then
            added[i].label, added[i].fn = label, fn
            return
        end
    end
    added[#added + 1] = { id = id, label = label, fn = fn }
end

function ItemSources.Available(data)
    return data ~= nil and data.itemID ~= nil and type(data.name) == "string"
end

-- The boss rows of the search data: by encounter, and the instances that
-- have any (a dungeon row offers its bosses only then).
local bossByEnc, bossInstances, bossFrom, bossFromN
local function BossIndex()
    local list = ns.Database and ns.Database.uiSearchData
    if not list then return nil end
    if bossFrom ~= list or bossFromN ~= #list then
        bossFrom, bossFromN, bossByEnc, bossInstances = list, #list, {}, {}
        for i = 1, #list do
            local d = list[i]
            if d.category == "Boss" and d.encounterID then
                if not bossByEnc[d.encounterID] then bossByEnc[d.encounterID] = d end
                local inst = d.instanceNameLower or (d.instanceName and slower(d.instanceName))
                if inst then bossInstances[inst] = true end
            end
        end
    end
    return bossByEnc
end

local function BossRow(enc)
    local byEnc = enc and BossIndex()
    return byEnc and byEnc[enc] or nil
end

function ItemSources.InstanceHasBosses(name)
    return type(name) == "string" and BossIndex() ~= nil and bossInstances[slower(name)] == true
end

local function Holds(items, id)
    for i = 1, items and #items or 0 do
        if items[i] == id then return true end
    end
    return false
end

-- The bosses that drop the item: the static loot tables', and the loot
-- row's own.
local function Bosses(item, out)
    local seen = {}
    local function Add(enc)
        local row = not seen[enc] and BossRow(enc)
        if row then
            seen[enc] = true
            out[#out + 1] = row
        end
    end
    for _, boss in ipairs(ns.STATIC_LOOT or {}) do
        if Holds(boss.items, item.itemID) or Holds(boss.heroic, item.itemID) then Add(boss.enc) end
    end
    if item.encounterID then Add(item.encounterID) end
end

local waiting = {}                      -- the page's items whose names are not in yet

local function MapRow(poi)
    local MapSearch = ns.MapSearch
    return MapSearch and MapSearch.UIRowOf and MapSearch.UIRowOf(poi) or poi
end

local function ItemRow(id, fallback)
    local name = ItemName(id)
    if not name then
        waiting[id] = true
        C_Item.RequestLoadItemDataByID(id)
        itemLoads:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    end
    name = name or fallback or ""
    local quality = C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
    return { itemID = id, catalogItem = true, lookupRow = true, category = "Item", name = name,
             nameLower = slower(name), quality = quality, noPin = true }
end

-- A place on the map at its spot nearest the player.
local function PlaceRow(spec)
    local list, s = {}, spec.spots
    for k = 1, #s - 2, 3 do
        if type(s[k]) == "number" then list[#list + 1] = { mapID = s[k], x = s[k + 1], y = s[k + 2] } end
    end
    if #list == 0 then return nil end
    local near = ns.MapSearch and ns.MapSearch.NearestSpot and ns.MapSearch.NearestSpot(list) or list[1]
    local info = C_Map.GetMapInfo(near.mapID)
    return MapRow({ name = spec.name, category = spec.kind or "treasure", icon = spec.icon, mapID = near.mapID,
                    coordMapID = near.mapID, x = near.x, y = near.y, zoneName = info and info.name or nil,
                    allInstances = list })
end

-- An extension's row named by what it is (API MINOR 13): { creature = id }
-- EasyFind's creature row, { item = id } its item row, { spots = { mapID,
-- x, y, ... } } a place at its nearest spot, { name, note } a line of
-- text; note is its subtext, name stands in where EasyFind has none.
-- Any other row stands as given.
local function Resolve(spec)
    if type(spec) ~= "table" then return nil end
    if not (spec.creature or spec.item or spec.spots or spec.note) then return spec end
    local row
    if spec.creature then
        local poi = ns.Npcs and ns.Npcs.RowOfID and ns.Npcs.RowOfID(spec.creature)
        row = poi and MapRow(poi)
    elseif spec.item then
        row = ItemRow(spec.item, spec.name)
    elseif spec.spots then
        row = spec.name and PlaceRow(spec)
    end
    if row then
        if spec.label then row.name, row.nameLower = spec.label, slower(spec.label) end
        if row.mapSearchResult then row.matchNote = spec.note else row.sourceNote = spec.note end
        return row
    end
    if type(spec.name) ~= "string" then return nil end
    return { name = spec.label or spec.name, icon = spec.icon, category = "Item", sourceNote = spec.note,
             lookupRow = true, noPin = true, noLearn = true, noMenu = true }
end

local function AddSection(out, label, rows, key)
    local list = {}
    for i = 1, #rows do
        local row = Resolve(rows[i])
        if row then list[#list + 1] = row end
    end
    if #list == 0 then return end
    for i = 1, #out do
        if key and out[i].key == key then
            for j = 1, #list do out[i].rows[#out[i].rows + 1] = list[j] end
            return
        end
    end
    out[#out + 1] = { label = label, rows = list, key = key }
end

-- An extension gives rows under its name, or sections of its own
-- ({ sections = { { label, rows, key }, ... } }); a section keyed "sold"
-- or "dropped" joins EasyFind's own.
local function AddExtension(out, label, given)
    if type(given) ~= "table" then return end
    if type(given.sections) ~= "table" then return AddSection(out, label, given) end
    for _, section in ipairs(given.sections) do
        if type(section) == "table" and type(section.rows) == "table" then
            AddSection(out, section.label or label, section.rows, section.key)
        end
    end
end

local function Sections(item)
    local out = {}
    if ns.Npcs and ns.Npcs.Sellers then
        local rows = ns.Npcs.Sellers({}, item.name)
        if type(rows) == "table" and #rows > 0 then
            for i = 1, #rows do rows[i] = MapRow(rows[i]) end
            out[#out + 1] = { label = L["SOURCES_SOLD_BY"], rows = rows, key = "sold" }
        end
    end
    local bosses = {}
    Bosses(item, bosses)
    if #bosses > 0 then out[#out + 1] = { label = L["SOURCES_DROPPED_BY"], rows = bosses, key = "dropped" } end
    for i = 1, #added do
        local ok, given = ns.Extensions.Run(added[i].fn, item.itemID, item.name)
        if ok then AddExtension(out, added[i].label, given) end
    end
    return out
end

-- The page's pill: the item's name as its token; its rows are built when
-- first shown and kept while it is up.
local def = { key = "itemSources", canonical = "sources", token = "", label = "", nestedParent = true,
              categoryLookup = {}, bucketLookup = {} }
local entries, words = {}, {}

local function SetEntry(n, data)
    local e = entries[n] or {}
    entries[n] = e
    e.name, e.depth, e.isPathNode, e.isMatch, e.isPinned, e.isFlat, e.data = data.name, 0, false, true, false, true, data
    e.isSectionHeader = false
end

local function SetHeader(n, name)
    local e = entries[n] or {}
    entries[n] = e
    e.name, e.depth, e.isPathNode, e.isMatch, e.isPinned, e.isFlat, e.data = name, 0, false, false, false, true, nil
    e.isSectionHeader = true
end

function ItemSources:Show(data)
    def.sourcesItem = { itemID = data.itemID, name = data.name, encounterID = data.encounterID }
    def.sections = nil
    def.token = "@" .. data.name
    def.label = data.name
    ns.Filters:ApplyQuickFilter(def, "")
end

local function Matches(row)
    if #words == 0 then return true end
    local low = row.nameLower or slower(row.name or "")
    local note = row.matchNote or row.sourceNote
    note = note and slower(note)
    for w = 1, #words do
        local word = words[w]
        if not (sfind(low, word, 1, true) or (note and sfind(note, word, 1, true))) then return false end
    end
    return true
end

-- The sections' rows the typed words keep, each section under its heading,
-- from entry n + 1; "No known source" when none is kept.
local function Fill(sections, n, itemName)
    local start = n
    for _, section in ipairs(sections) do
        local headed = false
        for _, row in ipairs(section.rows) do
            if Matches(row) then
                if not headed then
                    headed = true
                    n = n + 1
                    SetHeader(n, section.label)
                end
                n = n + 1
                SetEntry(n, row)
            end
        end
    end
    if n == start then
        n = n + 1
        SetEntry(n, { name = sformat(L["SOURCES_NONE"], itemName), category = "Item", noPin = true, noLearn = true,
                      noMenu = true, lookupRow = true })
    end
    for i = n + 1, #entries do entries[i] = nil end
    ns.Results:ShowHierarchicalResults(entries)
end

function ItemSources:ShowView(view, text)
    local item = view.sourcesItem
    if not item then return end
    if not view.sections then view.sections = Sections(item) end
    for w = #words, 1, -1 do words[w] = nil end
    for word in slower(text or ""):gmatch("%S+") do words[#words + 1] = word end
    Fill(view.sections, 0, item.name)
end

-- ==== "copper ore sources" typed ===========================================
-- A last word asking for sources: the other words are searched, and the
-- item they name shows its page's rows under its own row, the text kept.

local SOURCE_WORDS = { sources = true, source = true }
SOURCE_WORDS[slower(L["HINT_SOURCES"])] = true
local TYPED_FRESH = 5                   -- seconds its sections stand while typed
local typed = { at = 0 }                -- the typed item: itemID, sections, at

-- The words before a last "sources"; nil when the text asks for none.
function ItemSources.SourcesQuery(text)
    if type(text) ~= "string" then return nil end
    local rest, last = text:match("^%s*(.-)%s+(%S+)%s*$")
    if not (rest and rest ~= "" and SOURCE_WORDS[slower(last)]) then return nil end
    return rest
end

-- The item rows' one named exactly so, else the first: { data } entries.
function ItemSources.PickItem(list, query)
    local want, first = slower(query), nil
    for i = 1, #list do
        local d = list[i] and list[i].data
        if ItemSources.Available(d) then
            if (d.nameLower or slower(d.name)) == want then return d end
            first = first or d
        end
    end
    return first
end

function ItemSources:ShowTyped(data)
    local now = GetTime()
    if typed.itemID ~= data.itemID or now - typed.at > TYPED_FRESH then
        typed.itemID, typed.at = data.itemID, now
        typed.sections = Sections({ itemID = data.itemID, name = data.name, encounterID = data.encounterID })
    end
    for w = #words, 1, -1 do words[w] = nil end
    SetEntry(1, data)
    Fill(typed.sections, 1, data.name)
end

-- ==== a vendor's wares =====================================================
-- What a vendor sells, as a page in the bar the way a boss's Shift lists its
-- drops: every item the catalog has it selling (Npcs.Wares), armor too, its
-- name and icon from the client. Typing narrows the rows.

local waresDef = { key = "vendorWares", canonical = "wares", token = "", label = "", nestedParent = true,
                   categoryLookup = {}, bucketLookup = {} }
local loadingIDs = {}                   -- the page's items not in yet

-- How many items a vendor row's creature sells; nil when none is known.
function ItemSources.WareCount(data)
    local Npcs = ns.Npcs
    return data and data.npcID and Npcs and Npcs.WareCount and Npcs.WareCount(data.npcID) or nil
end

-- By name, the ones still loading last; one name's items by id.
local function WareLess(a, b)
    if a.loading ~= b.loading then return not a.loading end
    if a.nameLower ~= b.nameLower then return a.nameLower < b.nameLower end
    return a.itemID < b.itemID
end

local function WareRows(npcID)
    local rows, loading = {}, false
    wipe(loadingIDs)
    for _, id in ipairs(ns.Npcs.Wares(npcID) or {}) do
        local name = ItemName(id)
        if not name then
            loading = true
            loadingIDs[id] = true
            C_Item.RequestLoadItemDataByID(id)
        end
        rows[#rows + 1] = { itemID = id, catalogItem = true, lookupRow = true, category = "Item",
                            name = name or "", nameLower = name and slower(name) or "", loading = not name or nil,
                            quality = C_Item.GetItemQualityByID(id) }
    end
    tsort(rows, WareLess)
    return rows, loading
end

function ItemSources:ShowWares(data)
    waresDef.vendorWares = { npcID = data.npcID, name = data.name }
    waresDef.rows = nil
    waresDef.token = "@" .. data.name
    waresDef.label = data.name
    ns.Filters:ApplyQuickFilter(waresDef, "")
end

function ItemSources:ShowWaresView(view, text)
    local vendor = view.vendorWares
    if not vendor then return end
    if not view.rows then
        local loading
        view.rows, loading = WareRows(vendor.npcID)
        if loading then itemLoads:RegisterEvent("ITEM_DATA_LOAD_RESULT") end
    end
    for w = #words, 1, -1 do words[w] = nil end
    for word in slower(text or ""):gmatch("%S+") do words[#words + 1] = word end
    local n = 0
    for _, row in ipairs(view.rows) do
        if Matches(row) then
            n = n + 1
            SetEntry(n, row)
        end
    end
    for i = n + 1, #entries do entries[i] = nil end
    ns.Results:ShowHierarchicalResults(entries)
end

-- An item the page waits on is in: named, and the page drawn again once
-- the burst of answers settles.
local function NameSourceRows(sections, itemID, name)
    if not (sections and name) then return false end
    for _, section in ipairs(sections) do
        for _, row in ipairs(section.rows) do
            if row.catalogItem and row.itemID == itemID then row.name, row.nameLower = name, slower(name) end
        end
    end
    return true
end

-- The typed sources still under the bar.
local function TypedUp()
    local Search = ns.Search
    local text = typed.sections and Search and Search.GetTypedQuery and Search:GetTypedQuery()
    return text ~= nil and ItemSources.SourcesQuery(text) ~= nil
end

itemLoads:SetScript("OnEvent", function(self, _, itemID, ok)
    local sourced = false
    if waiting[itemID] then
        local name = ok and ItemName(itemID)
        local onPage = NameSourceRows(def.sections, itemID, name)
        sourced = NameSourceRows(typed.sections, itemID, name) or onPage
    end
    waiting[itemID] = nil
    local rows = loadingIDs[itemID] and waresDef.rows
    loadingIDs[itemID] = nil
    if rows then
        for _, row in ipairs(rows) do
            if row.loading and row.itemID == itemID then
                local name = ok and ItemName(itemID)
                row.name, row.nameLower, row.loading = name or "", name and slower(name) or "", nil
            end
        end
    end
    if next(loadingIDs) == nil and next(waiting) == nil then self:UnregisterEvent("ITEM_DATA_LOAD_RESULT") end
    if not (rows or sourced) or refreshPending then return end
    refreshPending = true
    C_Timer.After(0.3, function()
        refreshPending = false
        local shown = ns.Filters:GetQuickFilter()
        if shown == waresDef and waresDef.rows then tsort(waresDef.rows, WareLess) end
        if (shown == waresDef or shown == def or (shown == nil and TypedUp())) and ns.Search then
            ns.Search:RefreshActiveSearch(true)
        end
    end)
end)

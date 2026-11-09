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

local function Sections(item)
    local out = {}
    if ns.Npcs and ns.Npcs.Sellers then
        local rows = ns.Npcs.Sellers({}, item.name)
        if type(rows) == "table" and #rows > 0 then out[#out + 1] = { label = L["SOURCES_SOLD_BY"], rows = rows } end
    end
    local bosses = {}
    Bosses(item, bosses)
    if #bosses > 0 then out[#out + 1] = { label = L["SOURCES_DROPPED_BY"], rows = bosses } end
    for i = 1, #added do
        local ok, rows = ns.Extensions.Run(added[i].fn, item.itemID, item.name)
        if ok and type(rows) == "table" and #rows > 0 then out[#out + 1] = { label = added[i].label, rows = rows } end
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
    local note = row.matchNote and slower(row.matchNote)
    for w = 1, #words do
        local word = words[w]
        if not (sfind(low, word, 1, true) or (note and sfind(note, word, 1, true))) then return false end
    end
    return true
end

function ItemSources:ShowView(view, text)
    local item = view.sourcesItem
    if not item then return end
    if not view.sections then view.sections = Sections(item) end
    for w = #words, 1, -1 do words[w] = nil end
    for word in slower(text or ""):gmatch("%S+") do words[#words + 1] = word end
    local n = 0
    for _, section in ipairs(view.sections) do
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
    if n == 0 then
        n = 1
        SetEntry(1, { name = sformat(L["SOURCES_NONE"], item.name), category = "Item", noPin = true, noLearn = true,
                      noMenu = true, lookupRow = true })
    end
    for i = n + 1, #entries do entries[i] = nil end
    ns.Results:ShowHierarchicalResults(entries)
end

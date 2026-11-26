local _, ns = ...

-- Where an item comes from, as a page in the bar: who sells it (nearest
-- first), which bosses drop it, this client's source data (EasyFind_Sources,
-- read in on the first page) and what the extensions add
-- (EasyFind.API.RegisterItemSources). A click on an item row opens it
-- (Gestures: sources). Each section shows its first rows and asks before
-- showing more; a click on its heading folds it. Typing narrows the rows
-- by name, note, place (westfall, ek) or heading (reagent).
local ItemSources = {}
ns.ItemSources = ItemSources

local L, Utils = ns.L, ns.Utils
local ipairs, type = Utils.ipairs, Utils.type
local slower, sformat, sfind, mmin = Utils.slower, Utils.sformat, Utils.sfind, Utils.mmin

local FIRST_SHOWN = 8                   -- a section's rows before it asks
local MORE_STEP = 10                    -- rows each ask adds
local PLACE_WORD_MIN = 3                -- letters before a typed word may be part of a place's name

local added = {}
local itemLoads = CreateFrame("Frame")
local refreshPending = false
local tsort, tconcat = table.sort, table.concat

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
        -- A note that counts the player's own (a reagent's): Owned adds the alts.
        if spec.ownCounted then row.ownCounted = true end
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
    local crafters = ns.Characters and ns.Characters.CrafterRows and ns.Characters.CrafterRows(item.itemID, item.name)
    if crafters and #crafters > 0 then
        out[#out + 1] = { label = L["SOURCES_CRAFTED_BY"], rows = crafters, key = "crafted" }
    end
    local data = ns.RequestSourceData and ns.RequestSourceData() and ns.SourceData
    local known = data and data.Sections(item.itemID)
    if known then AddExtension(out, nil, { sections = known }) end
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
    e.section, e.toggle, e.collapsed = nil, nil, nil
end

local ToggleSection

-- A heading folds its section: the list draws the toggle and runs it on a
-- click or Enter (entry.toggle, entry.collapsed).
local function SetHeader(n, name, section)
    local e = entries[n] or {}
    entries[n] = e
    e.name, e.depth, e.isPathNode, e.isMatch, e.isPinned, e.isFlat, e.data = name, 0, false, false, false, true, nil
    e.isSectionHeader = true
    e.section, e.toggle, e.collapsed = section, ToggleSection, section.collapsed == true
end

function ItemSources:Show(data)
    def.sourcesItem = { itemID = data.itemID, name = data.name, encounterID = data.encounterID }
    def.sections = nil
    def.token = "@" .. data.name
    def.label = data.name
    ns.Filters:ApplyQuickFilter(def, "")
end

-- A row's place as the words it answers to: its zone, the maps over it
-- and their short names (westfall, eastern kingdoms, ek), one list per map
-- it has a spot on.
local placesOf = setmetatable({}, { __mode = "k" })
local function PlacesOf(row)
    local places = placesOf[row]
    if places == nil then
        places = false
        local ZoneWords = ns.MapUtils and ns.MapUtils.ZoneWords
        if ZoneWords then
            local spots = row.allInstances
            if type(spots) == "table" and #spots > 0 then
                local seen = {}
                places = {}
                for i = 1, #spots do
                    local m = spots[i].mapID
                    if m and not seen[m] then
                        seen[m] = true
                        places[#places + 1] = ZoneWords(m)
                    end
                end
            elseif row.mapID or row.coordMapID then
                places = { ZoneWords(row.mapID or row.coordMapID) }
            end
        end
        placesOf[row] = places
    end
    return places or nil
end

-- A short name whole (ek), or a part of a longer one (westf).
local function InPlace(places, word)
    local part = #word >= PLACE_WORD_MIN
    for i = 1, #places do
        local list = places[i]
        for k = 1, #list do
            if list[k] == word or (part and sfind(list[k], word, 1, true)) then return true end
        end
    end
    return false
end

-- Each typed word is in the row's name, its note, its place or its
-- section's heading.
local function Matches(row, heading)
    if #words == 0 then return true end
    local low = row.nameLower or slower(row.name or "")
    local note = row.matchNote or row.sourceNote
    note = note and slower(note)
    local places = PlacesOf(row)
    for w = 1, #words do
        local word = words[w]
        if not (sfind(low, word, 1, true) or (note and sfind(note, word, 1, true))
                or (heading and sfind(heading, word, 1, true)) or (places and InPlace(places, word))) then
            return false
        end
    end
    return true
end

local ShowMore
local EXPAND_ART = ns.ART and ns.ART.questlog_expand
local MORE_ICON = EXPAND_ART and { file = EXPAND_ART.tex, coords = EXPAND_ART.coords } or nil

-- The row that asks: "Show 10 more", how many are not shown under it.
local function MoreRow(section, hidden)
    local row = section.more
    if not row then
        row = { category = "Item", icon = MORE_ICON, lookupRow = true, noPin = true, noLearn = true, noMenu = true,
                pageAction = ShowMore, section = section }
        section.more = row
    end
    row.name = sformat(L["SOURCES_SHOW_MORE_FMT"], mmin(MORE_STEP, hidden))
    row.nameLower = slower(row.name)
    row.sourceNote = hidden > MORE_STEP and sformat(L["SOURCES_NOT_SHOWN_FMT"], hidden) or nil
    return row
end

local kept = {}                         -- a section's rows the typed words keep
local drawn = {}                        -- the last fill: sections, n, itemName, first

-- The sections' rows the typed words keep, each section under its heading
-- (its count beside it while rows are out of sight), from entry n + 1;
-- "No known source" when none is kept. keep: the list stays scrolled.
local function Fill(sections, n, itemName, keep)
    drawn.sections, drawn.n, drawn.itemName = sections, n, itemName
    local start = n
    for _, section in ipairs(sections) do
        local heading = section.heading
        if not heading then
            heading = slower(section.label or "")
            section.heading = heading
        end
        local count = 0
        for _, row in ipairs(section.rows) do
            if Matches(row, heading) then
                count = count + 1
                kept[count] = row
            end
        end
        for i = #kept, count + 1, -1 do kept[i] = nil end
        if count > 0 then
            local limit = section.shown or FIRST_SHOWN
            if count <= limit + 1 then limit = count end
            local folded = section.collapsed == true
            n = n + 1
            SetHeader(n, (folded or count > limit) and sformat("%s (%d)", section.label, count) or section.label, section)
            if not folded then
                for i = 1, limit do
                    n = n + 1
                    SetEntry(n, kept[i])
                end
                if count > limit then
                    n = n + 1
                    SetEntry(n, MoreRow(section, count - limit))
                end
            end
        end
    end
    if n == start then
        n = n + 1
        SetEntry(n, { name = sformat(L["SOURCES_NONE"], itemName), category = "Item", noPin = true, noLearn = true,
                      noMenu = true, lookupRow = true })
    end
    for i = n + 1, #entries do entries[i] = nil end
    ns.Results:ShowHierarchicalResults(entries, keep)
end

-- The page again where it stands, after a fold or a "show more": the
-- same rows above, the selection where it was.
local function Refill()
    if not drawn.sections then return end
    local Search = ns.Search
    local selected = Search and Search.GetSelectedIndex and Search:GetSelectedIndex() or 0
    Fill(drawn.sections, drawn.n, drawn.itemName, true)
    if selected > 0 then
        Search:SetSelectedIndex(selected)
        if ns.Results.UpdateSelectionHighlight then ns.Results:UpdateSelectionHighlight() end
    end
end

function ToggleSection(entry)
    local section = entry.section
    if not section then return end
    section.collapsed = not section.collapsed
    Refill()
end

function ShowMore(row)
    local section = row.section
    section.shown = (section.shown or FIRST_SHOWN) + MORE_STEP
    Refill()
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
-- The word sources after an item's name: the words before it are searched,
-- and the item they name shows its page's rows under its own row, the text
-- kept. Words after it narrow the rows as on the page ("linen cloth
-- sources reagent", "copper ore sources ek").

local SOURCE_WORDS = { sources = true, source = true }
SOURCE_WORDS[slower(L["HINT_SOURCES"])] = true
local TYPED_FRESH = 5                   -- seconds its sections stand while typed
local typed = { at = 0 }                -- the typed item: itemID, sections, at

-- The words before the last "sources", and the ones after it ("" when
-- none); nil when the text asks for no sources.
function ItemSources.SourcesQuery(text)
    if type(text) ~= "string" then return nil end
    local low = slower(text)
    local at, stop, from = nil, nil, 1
    while true do
        local s, e = low:find("%S+", from)
        if not s then break end
        if s > 1 and SOURCE_WORDS[low:sub(s, e)] then at, stop = s, e end
        from = e + 1
    end
    if not at then return nil end
    local rest = text:sub(1, at - 1):match("^%s*(.-)%s*$")
    if rest == "" then return nil end
    return rest, low:sub(stop + 1):match("^%s*(.-)%s*$")
end

-- The item rows' one named exactly so, else the first (none when only an
-- exact name will do): { data } entries.
function ItemSources.PickItem(list, query, exactOnly)
    local want, first = slower(query), nil
    for i = 1, #list do
        local d = list[i] and list[i].data
        if ItemSources.Available(d) then
            if (d.nameLower or slower(d.name)) == want then return d end
            first = first or d
        end
    end
    if exactOnly then return nil end
    return first
end

-- ==== an item and the words that narrow, no "sources" typed ================
-- "linen cloth reagent", "ek linen cloth": words at either end that name a
-- place or a heading, the rest an item's name. Tried only after the text
-- as typed found nothing (Search/Query.lua), each way as a search of the
-- item's words: the item must be named exactly and keep a row under them.

local HEADING_KEYS = { "SOURCES_SOLD_BY", "SOURCES_DROPPED_BY", "SOURCES_CRAFTED_BY", "SOURCES_GATHERED",
                       "SOURCES_SKINNED", "SOURCES_FISHED", "SOURCES_PICKPOCKETED", "SOURCES_FOUND_IN",
                       "SOURCES_CONTAINED", "SOURCES_QUEST_REWARD", "SOURCES_STARTS_QUEST", "SOURCES_TEACHES",
                       "SOURCES_REAGENT_FOR", "SOURCES_NEEDED_FOR", "MATS_REAGENTS" }
local HEADING_WORD_MIN = 4              -- letters before a typed word may start a heading's word
local PEEL_MAX = 3                      -- words an end may give up
local headingWords
local peel = {}                         -- the typed words
-- The ways to read the text: item[i] and narrow[i], n of them, at the one
-- being tried; armed until the search takes it.
local implied = { item = {}, narrow = {}, n = 0, at = 0 }

local function HeadingWord(word)
    if #word < HEADING_WORD_MIN then return false end
    if not headingWords then
        headingWords = {}
        for i = 1, #HEADING_KEYS do
            for part in slower(L[HEADING_KEYS[i]]):gmatch("%S+") do
                if #part >= HEADING_WORD_MIN then headingWords[#headingWords + 1] = part end
            end
        end
    end
    for i = 1, #headingWords do
        if sfind(headingWords[i], word, 1, true) == 1 then return true end
    end
    return false
end

local function PlaceWord(text)
    local MapSearch = ns.MapSearch
    return MapSearch ~= nil and MapSearch.ZonesNamed ~= nil and MapSearch:ZonesNamed(text) ~= nil
end

-- How many words an end gives up: its run of words that each name a place
-- or start a heading's word, or more that name a place together ("eastern
-- kingdoms"). One word at least stays for the item.
local function Narrowing(n, fromEnd)
    local singles, best = 0, 0
    for k = 1, mmin(PEEL_MAX, n - 1) do
        local word = fromEnd and peel[n - k + 1] or peel[k]
        if singles == k - 1 and (HeadingWord(word) or PlaceWord(word)) then singles = k end
        if singles == k then
            best = k
        elseif k > 1 then
            local together = fromEnd and tconcat(peel, " ", n - k + 1, n) or tconcat(peel, " ", 1, k)
            if PlaceWord(together) then best = k end
        end
    end
    return best
end

local function AddWay(from, to, n)
    if from > to then return end
    local item = tconcat(peel, " ", from, to)
    for i = 1, implied.n do
        if implied.item[i] == item then return end
    end
    local narrow = from > 1 and tconcat(peel, " ", 1, from - 1) or ""
    if to < n then narrow = (narrow ~= "" and narrow .. " " or "") .. tconcat(peel, " ", to + 1, n) end
    implied.n = implied.n + 1
    implied.item[implied.n], implied.narrow[implied.n] = item, narrow
end

-- The text as typed found nothing: whether it reads as an item and words
-- that narrow. True arms the first way for the search's next pass.
function ItemSources.ImpliedFirst(text)
    implied.text, implied.n, implied.at, implied.armed = text, 0, 0, false
    local n = 0
    for word in slower(text or ""):gmatch("%S+") do
        n = n + 1
        peel[n] = word
    end
    for i = #peel, n + 1, -1 do peel[i] = nil end
    if n < 2 then return false end
    local tail, head = Narrowing(n, true), Narrowing(n, false)
    if tail > 0 then AddWay(1, n - tail, n) end
    if head > 0 then AddWay(head + 1, n, n) end
    if tail > 0 and head > 0 then AddWay(head + 1, n - tail, n) end
    return ItemSources.ImpliedAfterMiss(text)
end

-- The way tried named no item, or kept no row: true arms the next.
function ItemSources.ImpliedAfterMiss(text)
    if implied.text ~= text or implied.at >= implied.n then return false end
    implied.at, implied.armed = implied.at + 1, true
    return true
end

-- The armed way for this text, taken once: the item's words and the words
-- that narrow.
function ItemSources.ImpliedTry(text)
    if not implied.armed or implied.text ~= text then return nil end
    implied.armed = false
    return implied.item[implied.at], implied.narrow[implied.at]
end

-- A section folded or grown stays so when its rows are read again.
local function CarryView(old, new)
    for _, was in ipairs(old or {}) do
        if was.collapsed or was.shown then
            for _, now in ipairs(new) do
                if now.label == was.label then now.collapsed, now.shown = was.collapsed, was.shown end
            end
        end
    end
end

-- Whether any row stands under the typed words.
local function Keeps(sections)
    for _, section in ipairs(sections) do
        local heading = section.heading
        if not heading then
            heading = slower(section.label or "")
            section.heading = heading
        end
        for _, row in ipairs(section.rows) do
            if Matches(row, heading) then return true end
        end
    end
    return false
end

-- The item's row and its sections under the bar, the rows narrowed by the
-- words after "sources", or by the ones given (no "sources" typed).
-- mustKeep: nothing is shown, and false returned, when no row stands.
function ItemSources:ShowTyped(data, narrow, mustKeep)
    local now = GetTime()
    if typed.itemID ~= data.itemID or now - typed.at > TYPED_FRESH then
        local fresh = Sections({ itemID = data.itemID, name = data.name, encounterID = data.encounterID })
        if typed.itemID == data.itemID then CarryView(typed.sections, fresh) end
        typed.itemID, typed.at, typed.sections = data.itemID, now, fresh
    end
    for w = #words, 1, -1 do words[w] = nil end
    local Search = ns.Search
    local text = Search and Search.GetTypedQuery and Search:GetTypedQuery()
    if narrow == nil then
        local _, after = ItemSources.SourcesQuery(text)
        narrow = after
    end
    for word in (narrow or ""):gmatch("%S+") do words[#words + 1] = word end
    if mustKeep and not Keeps(typed.sections) then return false end
    typed.text = text
    SetEntry(1, data)
    Fill(typed.sections, 1, data.name)
    return true
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
    return text ~= nil and (text == typed.text or ItemSources.SourcesQuery(text) ~= nil)
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

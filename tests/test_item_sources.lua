-- Search/ItemSources.lua: an item's sources page, its sections (who sells
-- it, which bosses drop it, what the extensions add), the typed narrowing
-- and the pill it opens.
local H = require("Harness")

local function fresh(opts)
    opts = opts or {}
    local env = H.newEnv()
    local shown, applied = nil, nil
    -- The stand-in API after newNs: with EasyFind set first, the harness loads the real one over it.
    local ns = H.newNs(env)
    env.EasyFind = { API = {} }
    -- The creature catalog's vendors of an item (MapSearch/Npcs.lua).
    ns.Npcs = opts.sellers and { Sellers = function(_, itemName) return opts.sellers(itemName) end } or nil
    ns.Extensions = { Run = function(fn, ...) return pcall(fn, ...) end }
    ns.Filters = { ApplyQuickFilter = function(_, def, text) applied = { def = def, text = text } end }
    ns.Results = { ShowHierarchicalResults = function(_, entries)
        shown = {}
        for i = 1, #entries do shown[i] = { name = entries[i].name, header = entries[i].isSectionHeader, data = entries[i].data } end
    end }
    ns.STATIC_LOOT = opts.loot
    ns.Database.uiSearchData = opts.rows or {}
    if opts.items then
        env.C_Item = opts.items
        env.CreateFrame = function() local f = H.newFrame() opts.frames[#opts.frames + 1] = f return f end
        env.C_Timer = { After = function(_, fn) opts.later[#opts.later + 1] = fn end }
    end
    H.loadModule("Search/ItemSources.lua", env, ns)
    return ns.ItemSources, function() return shown end, function() return applied end, ns
end

local tests = {}

local vendor = { name = "Eleanor Rusk", nameLower = "eleanor rusk", matchNote = "Sells Simple Wood", category = "npc" }
local boss = { name = "Edwin VanCleef", nameLower = "edwin vancleef", category = "Boss", encounterID = 1588, instanceName = "The Deadmines" }
local other = { name = "Mr. Smite", nameLower = "mr. smite", category = "Boss", encounterID = 1589, instanceName = "The Deadmines" }

function tests.aClickOpensThePillNamedForTheItem()
    local Sources, _, applied = fresh()
    Sources:Show({ itemID = 2589, name = "Linen Cloth", catalogItem = true })
    local got = applied()
    H.assertEq(got.def.token, "@Linen Cloth")
    H.assertEq(got.def.sourcesItem.itemID, 2589)
    H.assertEq(got.text, "")
    H.assertTrue(Sources.Available({ itemID = 1, name = "x" }))
    H.assertFalse(Sources.Available({ name = "x" }), "no item id: no page")
end

function tests.thePageListsSellersBossesAndTheExtensions()
    local Sources, shown, _, ns = fresh({
        sellers = function() return { vendor } end,
        loot = { { inst = 36, enc = 1588, items = { 2589, 100 } }, { inst = 36, enc = 1589, heroic = { 2589 } } },
        rows = { boss, other, { name = "Linen Cloth", category = "Item" } },
    })
    local quest = { name = "Cloth for the Guard", nameLower = "cloth for the guard", category = "ext:quests" }
    Sources.Register("questie", "Questie", function(itemID) return itemID == 2589 and { quest } or nil end)
    local view = { sourcesItem = { itemID = 2589, name = "Linen Cloth" } }
    Sources:ShowView(view, "")
    local rows = shown()
    H.assertEq(#rows, 7)
    H.assertEq(rows[1].name, "SOURCES_SOLD_BY")
    H.assertTrue(rows[1].header)
    H.assertEq(rows[2].data, vendor)
    H.assertEq(rows[3].name, "SOURCES_DROPPED_BY")
    H.assertEq(rows[4].data, boss)
    H.assertEq(rows[5].data, other, "a heroic drop counts")
    H.assertEq(rows[6].name, "Questie")
    H.assertEq(rows[7].data, quest)
    H.assertNotNil(view.sections, "built once, kept while the page is up")
    Sources:ShowView(view, "smite")
    rows = shown()
    H.assertEq(#rows, 2, "typing narrows the rows, headers follow")
    H.assertEq(rows[2].data, other)
    Sources:ShowView(view, "simple")
    H.assertEq(shown()[2].data, vendor, "a vendor answers to what it sells")
    ns.Extensions.Run = function() return false end
    view.sections = nil
    Sources:ShowView(view, "")
    H.assertEq(#shown(), 5, "a failing extension adds nothing")
end

-- Who on the account can make it (2026-11-19).
function tests.thePageListsTheCharactersWhoCanCraftIt()
    local Sources, shown, _, ns = fresh({ sellers = function() return { vendor } end })
    local crafter = { name = "Jaina", category = "Character", searchCommandDesc = "Tailoring", sourceNote = "Tailoring" }
    ns.Characters = { CrafterRows = function(itemID) return itemID == 2996 and { crafter } or {} end }
    local view = { sourcesItem = { itemID = 2996, name = "Bolt of Linen Cloth" } }
    Sources:ShowView(view, "")
    local rows = shown()
    H.assertEq(rows[3].name, "SOURCES_CRAFTED_BY", "after who sells it")
    H.assertTrue(rows[3].header)
    H.assertEq(rows[4].data, crafter)
    Sources:ShowView(view, "tailor")
    H.assertEq(shown()[2].data, crafter, "found by the profession too")
    view = { sourcesItem = { itemID = 5, name = "Nothing" } }
    Sources:ShowView(view, "")
    for _, row in ipairs(shown()) do H.assertTrue(row.name ~= "SOURCES_CRAFTED_BY", "no crafter, no section") end
end

function tests.noSourceSaysSo()
    local Sources, shown = fresh()
    Sources:ShowView({ sourcesItem = { itemID = 7, name = "Hearthstone" } }, "")
    local rows = shown()
    H.assertEq(#rows, 1)
    H.assertEq(rows[1].name, "SOURCES_NONE")
    H.assertTrue(rows[1].data.noPin and rows[1].data.lookupRow)
end

function tests.aLootRowsOwnBossCounts()
    local Sources, shown = fresh({ rows = { boss } })
    Sources:ShowView({ sourcesItem = { itemID = 5, name = "Cruel Barb", encounterID = 1588 } }, "")
    H.assertEq(shown()[2].data, boss)
end

function tests.anInstanceHasBossesWhenTheSearchDataHoldsOne()
    local Sources = fresh({ rows = { boss } })
    H.assertTrue(Sources.InstanceHasBosses("The Deadmines"))
    H.assertTrue(Sources.InstanceHasBosses("the deadmines"), "by name, any case")
    H.assertFalse(Sources.InstanceHasBosses("Ruins of Lordaeron"), "no boss rows: none offered")
    H.assertFalse(Sources.InstanceHasBosses(nil))
end

-- An extension's sections and the rows it names (API MINOR 13): EasyFind
-- draws its own creature, item and place rows for them, clicked as they
-- are anywhere; "dropped" joins EasyFind's own Dropped by.
local function namedWorld(opts)
    local Sources, shown, _, ns = fresh(opts)
    ns.Npcs = ns.Npcs or {}
    ns.Npcs.RowOfID = function(id)
        if id == 589 then return { name = "Defias Pillager", category = "npc", npcID = 589, mapID = 1436, x = 0.4, y = 0.5 } end
    end
    ns.MapSearch = {
        UIRowOf = function(r) return { name = r.name, nameLower = r.name:lower(), npcID = r.npcID, mapID = r.mapID,
                                       x = r.x, y = r.y, category = r.category, mapSearchResult = true } end,
        NearestSpot = function(list) return list[2] end,
    }
    return Sources, shown, ns
end

function tests.anExtensionsSections_nameEasyFindsOwnRows()
    local Sources, shown = namedWorld({ rows = { boss }, loot = { { inst = 36, enc = 1588, items = { 2589 } } } })
    Sources.Register("itemsource", "Item Source", function()
        return { sections = {
            { key = "dropped", rows = { { creature = 589, note = "12%" }, { creature = 4, name = "Gone Kobold", note = "3%" },
                                        { creature = 5, note = "no name: left out" },
                                        { name = "World drop", note = "Creatures of level 30 to 40" } } },
            { label = "Gathered from", rows = { { spots = { 1429, 0.1, 0.2, 1436, 0.5, 0.6 }, name = "Copper Vein",
                                                  kind = "treasure", note = "Mining" } } },
        } }
    end)
    Sources:ShowView({ sourcesItem = { itemID = 2589, name = "Linen Cloth" } }, "")
    local rows = shown()
    H.assertEq(rows[1].name, "SOURCES_DROPPED_BY")
    H.assertEq(rows[2].data, boss)
    H.assertEq(rows[3].data.npcID, 589, "the creature joins EasyFind's own Dropped by")
    H.assertTrue(rows[3].data.mapSearchResult, "a bar row: clicked as a map row, its GPS too")
    H.assertEq(rows[3].data.matchNote, "12%")
    H.assertEq(rows[4].name, "Gone Kobold", "a creature the catalog lacks keeps the extension's name")
    H.assertEq(rows[4].data.sourceNote, "3%")
    H.assertTrue(rows[4].data.noPin)
    H.assertEq(rows[5].name, "World drop", "no creature 5 and no name: left out; a line of text stays")
    H.assertEq(rows[5].data.sourceNote, "Creatures of level 30 to 40")
    H.assertTrue(rows[5].data.noPin and rows[5].data.lookupRow)
    H.assertEq(rows[6].name, "Gathered from")
    H.assertEq(rows[7].data.name, "Copper Vein")
    H.assertEq(rows[7].data.mapID, 1436, "the spot nearest the player")
    H.assertEq(rows[7].data.matchNote, "Mining")
end

function tests.anItemNamedByID_isEasyFindsItemRow_namedWhenItArrives()
    local names, asked, frames, later = {}, {}, {}, {}
    local Sources, shown, ns = namedWorld({ frames = frames, later = later, items = {
        GetItemNameByID = function(id) return names[id] end, GetItemQualityByID = function() return 2 end,
        RequestLoadItemDataByID = function(id) asked[#asked + 1] = id end } })
    local refreshed, page = 0, nil
    ns.Search = { RefreshActiveSearch = function() refreshed = refreshed + 1 end }
    ns.Filters.GetQuickFilter = function() return page end
    Sources.Register("itemsource", "Item Source", function()
        return { sections = { { label = "Reagent for", rows = { { item = 2581, note = "First Aid 40, 2 needed" } } } } }
    end)
    ns.Filters.ApplyQuickFilter = function(_, d) page = d end
    Sources:Show({ itemID = 2589, name = "Linen Cloth" })
    Sources:ShowView(page, "")
    local row = shown()[2].data
    H.assertTrue(row.catalogItem, "EasyFind's item row: its click opens that item's page")
    H.assertEq(row.itemID, 2581)
    H.assertEq(row.sourceNote, "First Aid 40, 2 needed")
    H.assertEq(asked[1], 2581, "its name asked for")
    names[2581] = "Heavy Linen Bandage"
    local loads = frames[1]
    loads:GetScript("OnEvent")(loads, "ITEM_DATA_LOAD_RESULT", 2581, true)
    H.assertEq(row.name, "Heavy Linen Bandage", "named as it arrives")
    H.assertEq(#later, 1, "one redraw once the answers settle")
    later[1]()
    H.assertEq(refreshed, 1, "the page drawn again while it is up")
end

-- A vendor's wares (Forever, 2026-11-15: Kelm Hargunth's row showed where
-- he stands, never what he sells): Shift on its row opens a page of every
-- item it sells, armor too, by name, the ones the client is still loading
-- last and named as they arrive; typing narrows the rows.
local function waresWorld()
    local env = H.newEnv()
    local shown, applied, frames = nil, nil, {}
    local ns = H.newNs(env)
    env.EasyFind = { API = {} }
    local names = { [100] = "Warsong Gulch Runecloth Bandage", [200] = "Outrider's Bow", [300] = "Sentinel's Leather Pants" }
    local asked = {}
    env.C_Item = {
        GetItemNameByID = function(id) return names[id] end,
        GetItemQualityByID = function(id) return id == 200 and 3 or 1 end,
        RequestLoadItemDataByID = function(id) asked[#asked + 1] = id end,
    }
    env.CreateFrame = function() local f = H.newFrame() frames[#frames + 1] = f return f end
    local later = {}
    env.C_Timer = { After = function(_, fn) later[#later + 1] = fn end }
    ns.Npcs = {
        Wares = function(id) return id == 14754 and { 100, 200, 300, 400 } or nil end,
        WareCount = function(id) return id == 14754 and 4 or nil end,
    }
    ns.Filters = { ApplyQuickFilter = function(_, def, text) applied = { def = def, text = text } end,
                   GetQuickFilter = function() return applied and applied.def end }
    local refreshed = 0
    ns.Search = { RefreshActiveSearch = function() refreshed = refreshed + 1 end }
    ns.Results = { ShowHierarchicalResults = function(_, entries)
        shown = {}
        for i = 1, #entries do shown[i] = entries[i].data end
    end }
    H.loadModule("Search/ItemSources.lua", env, ns)
    return {
        Sources = ns.ItemSources, shown = function() return shown end, applied = function() return applied end,
        names = names, asked = asked, later = later, refreshed = function() return refreshed end,
        loads = function() local f = frames[#frames] return function(...) return f:GetScript("OnEvent")(f, ...) end end,
    }
end

function tests.aVendorsShift_listsEveryItemItSells()
    local w = waresWorld()
    local S = w.Sources
    local kelm = { name = "Kelm Hargunth", npcID = 14754, mapSearchResult = true }
    H.assertEq(S.WareCount(kelm), 4)
    H.assertNil(S.WareCount({ name = "Hogger", npcID = 448 }), "no wares: no page offered")
    S:ShowWares(kelm)
    local def = w.applied().def
    H.assertEq(def.token, "@Kelm Hargunth")
    H.assertEq(def.vendorWares.npcID, 14754)
    S:ShowWaresView(def, "")
    local rows = w.shown()
    H.assertEq(#rows, 4, "armor too: every item")
    H.assertEq(rows[1].name, "Outrider's Bow", "by name")
    H.assertEq(rows[2].name, "Sentinel's Leather Pants")
    H.assertEq(rows[3].name, "Warsong Gulch Runecloth Bandage")
    H.assertEq(rows[4].itemID, 400, "the one the client is still loading: last")
    H.assertTrue(rows[1].catalogItem and rows[1].itemID == 200 and rows[1].quality == 3, "an item row, its quality")
    H.assertEq(table.concat(w.asked, ","), "400", "the client asked for the unknown one")
    S:ShowWaresView(def, "bandage")
    H.assertEq(#w.shown(), 1, "typing narrows")
    H.assertEq(w.shown()[1].itemID, 100)
end

function tests.aWareArriving_namesItsRow_othersItemsIgnored()
    local w = waresWorld()
    local S = w.Sources
    S:ShowWares({ name = "Kelm Hargunth", npcID = 14754 })
    local def = w.applied().def
    S:ShowWaresView(def, "")
    local onEvent = w.loads()
    onEvent("ITEM_DATA_LOAD_RESULT", 999, true)
    H.assertEq(#w.later, 0, "another addon's item: nothing")
    w.names[400] = "Advisor's Gnarled Staff"
    onEvent("ITEM_DATA_LOAD_RESULT", 400, true)
    H.assertEq(#w.later, 1, "drawn again once the answers settle")
    w.later[1]()
    H.assertEq(w.refreshed(), 1)
    S:ShowWaresView(def, "")
    H.assertEq(w.shown()[1].name, "Advisor's Gnarled Staff", "named and sorted in")
end

-- "copper ore sources" typed: the words before a last sources word.
function tests.aLastSourcesWord_asksForTheOthersSources()
    local Sources = fresh()
    H.assertEq(Sources.SourcesQuery("copper ore sources"), "copper ore")
    H.assertEq(Sources.SourcesQuery("  Copper Ore Source "), "Copper Ore")
    H.assertNil(Sources.SourcesQuery("sources"), "the word alone names no item")
    H.assertNil(Sources.SourcesQuery("sources copper ore"), "only the last word asks")
    H.assertNil(Sources.SourcesQuery("copper ore"))
    H.assertNil(Sources.SourcesQuery(nil))
end

function tests.theItemPicked_isTheOneNamedSo_elseTheFirstItem()
    local Sources = fresh()
    local quest = { data = { name = "Copper Ore", category = "Quest" } }
    local bar = { data = { itemID = 2840, name = "Copper Bar", category = "Bag" } }
    local ore = { data = { itemID = 2770, name = "Copper Ore", category = "Bank" } }
    H.assertEq(Sources.PickItem({ quest, bar, ore }, "copper ore"), ore.data, "its own name first")
    H.assertEq(Sources.PickItem({ quest, bar, ore }, "copper"), bar.data, "else the first item row")
    H.assertNil(Sources.PickItem({ quest }, "copper ore"), "no item row: nothing picked")
end

function tests.typedSources_showTheItemsRowThenItsSections()
    local Sources, shown = fresh({ sellers = function(name) return name == "Copper Ore" and { vendor } or {} end })
    local ore = { itemID = 2770, name = "Copper Ore", category = "Bank" }
    Sources:ShowTyped(ore)
    local rows = shown()
    H.assertEq(#rows, 3)
    H.assertEq(rows[1].data, ore, "the item it names, its own row")
    H.assertEq(rows[2].name, "SOURCES_SOLD_BY")
    H.assertEq(rows[3].data, vendor)
    Sources:ShowTyped({ itemID = 6948, name = "Hearthstone" })
    rows = shown()
    H.assertEq(#rows, 2)
    H.assertEq(rows[2].name, "SOURCES_NONE", "nothing known: says so under it")
end

local pass, fail, failures = H.runSuite("ItemSources", tests)
return { pass = pass, fail = fail, failures = failures }

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

local pass, fail, failures = H.runSuite("ItemSources", tests)
return { pass = pass, fail = fail, failures = failures }

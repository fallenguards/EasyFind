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
    env.EasyFind = {
        API = {
            HasAction = function(id, name) return id == "gps" and name == "sellers" and opts.sellers ~= nil end,
            CallAction = function(id, name, itemName)
                if id == "gps" and name == "sellers" then return opts.sellers(itemName) end
            end,
        },
    }
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

local pass, fail, failures = H.runSuite("ItemSources", tests)
return { pass = pass, fail = fail, failures = failures }

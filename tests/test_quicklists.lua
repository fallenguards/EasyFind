-- Tests for Apps/Quicklists/Store.lua: lists, their keys and rows, and the
-- share-code rows in and out.
local H = require("Harness")

local function fresh()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.EasyFindDB = {}
    env.EasyFind.db = env.EasyFindDB
    ns.Aliases = { GetEntryKey = function(_, data) return data.key end }
    ns.UIPins = { CleanForStorage = function(data) return { name = data.name, category = data.category } end }
    H.loadModule("Apps/Quicklists/Store.lua", env, ns)
    H.assertNotNil(ns.QuicklistStore, "Store.lua must populate ns.QuicklistStore")
    return env, ns.QuicklistStore
end

local function row(name, key)
    return { name = name, key = key, category = "Mount" }
end

local tests = {}

function tests.create_cleansNamesAndNumbersIds()
    local _, Store = fresh()
    local a = Store.Create("  Zones\n")
    local b = Store.Create("Mounts")
    H.assertEq(a.name, "Zones")
    H.assertEq(b.id, a.id + 1)
    H.assertNil(Store.Create("   "), "blank name refused")
    H.assertEq(Store.FindByName("zones"), a, "case-insensitive lookup")
    H.assertEq(#Store.All(), 2)
end

function tests.rows_addRemoveCapAndOrder()
    local _, Store = fresh()
    local list = Store.Create("Zones")
    H.assertTrue(Store.Add(list.id, row("Orgrimmar", "map:1")))
    H.assertTrue(Store.Add(list.id, row("Dalaran", "map:2")))
    H.assertTrue(not Store.Add(list.id, row("Orgrimmar", "map:1")), "no duplicates")
    H.assertTrue(not Store.Add(list.id, { name = "No key" }), "rows without a key stay out")
    H.assertTrue(Store.Has(list.id, "map:2"))
    H.assertEq(list.items[1].d.name, "Orgrimmar", "snapshot kept")
    H.assertTrue(Store.MoveItem(list.id, 2, -1))
    H.assertEq(list.items[1].k, "map:2")
    H.assertTrue(not Store.MoveItem(list.id, 1, -1), "already first")
    H.assertTrue(Store.Remove(list.id, "map:1"))
    H.assertEq(#list.items, 1)
    for i = 1, Store.ITEMS_MAX do Store.Add(list.id, row("r" .. i, "k:" .. i)) end
    H.assertEq(#list.items, Store.ITEMS_MAX, "capped")
end

function tests.keys_belongToOneList()
    local _, Store = fresh()
    local a = Store.Create("A")
    local b = Store.Create("B")
    Store.SetKey(a.id, "CTRL-1")
    Store.SetKey(b.id, "CTRL-1")
    H.assertNil(a.key, "the key moved off A")
    H.assertEq(Store.KeyOwner("CTRL-1"), b)
    Store.SetKey(b.id, "")
    H.assertNil(b.key, "an empty combo clears")
    Store.SetHold(b.id, true)
    H.assertEq(b.hold, true)
    Store.SetHold(b.id, false)
    H.assertNil(b.hold)
end

function tests.lists_moveRenameDelete()
    local _, Store = fresh()
    local a = Store.Create("A")
    local b = Store.Create("B")
    H.assertTrue(Store.Move(b.id, -1))
    H.assertEq(Store.All()[1], b)
    H.assertTrue(not Store.Move(b.id, -1), "already first")
    H.assertTrue(Store.Rename(a.id, "Alpha"))
    H.assertEq(Store.FindByName("alpha"), a)
    H.assertTrue(Store.Delete(a.id))
    H.assertNil(Store.Get(a.id))
    H.assertTrue(not Store.Delete(a.id), "gone already")
end

function tests.export_carriesKeysNotSnapshots()
    local _, Store = fresh()
    local a = Store.Create("Zones")
    Store.SetKey(a.id, "ALT-Z")
    Store.SetHold(a.id, true)
    Store.Add(a.id, row("Orgrimmar", "map:1"))
    local out = Store.ExportList()
    H.assertEq(#out, 1)
    H.assertEq(out[1].key, "ALT-Z")
    H.assertEq(out[1].hold, true)
    H.assertEq(out[1].items[1].k, "map:1")
    H.assertEq(out[1].items[1].n, "Orgrimmar")
    H.assertNil(out[1].items[1].d, "no snapshot in a code")
end

function tests.import_replacesOrKeepsByName()
    local env, Store = fresh()
    local a = Store.Create("Zones")
    Store.Add(a.id, row("Old", "map:9"))
    local rows = {
        { name = "Zones", key = "ALT-Z", hold = true, items = { { k = "map:1", n = "Orgrimmar" } } },
        { name = "Mounts", items = { { k = "mount:5", n = "Pony" }, { k = 7 } } },
        { name = "" },
        "junk",
    }
    H.assertEq(Store.ImportList(rows, true), 1, "existing list kept with skip")
    H.assertEq(a.items[1].k, "map:9")
    H.assertEq(Store.ImportList(rows, false), 2, "both land on replace")
    H.assertEq(a.items[1].k, "map:1", "replaced rows")
    H.assertEq(a.key, "ALT-Z")
    local m = Store.FindByName("Mounts")
    H.assertEq(#m.items, 1, "a row without a string key is dropped")
    H.assertEq(#env.EasyFindDB.quicklists, 2)
    Store.ClearAll()
    H.assertEq(#Store.All(), 0)
end

local pass, fail, failures = H.runSuite("Quicklists", tests)
return { pass = pass, fail = fail, failures = failures }

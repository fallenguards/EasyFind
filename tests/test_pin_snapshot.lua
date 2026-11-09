-- Shared/UIPins.lua: what a pin stores of an extension's row, and the
-- live row an extension's pin shows when its provider has rows.
local H = require("Harness")

local function fresh()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind = { db = { pinnedUIItems = {} } }
    env.UnitName = function() return "Tester" end
    env.GetRealmName = function() return "Realm" end
    ns.Extensions = { ProviderOf = function(data) return data and data.category == "ext:quests" and {} or nil end }
    H.loadModule("Shared/UIPins.lua", env, ns)
    return env, ns
end

local tests = {}

function tests.anExtensionRowKeepsItsOwnPlainFields()
    local _, ns = fresh()
    local clean = ns.UIPins.CleanForStorage({
        name = "The Wrath of Rath'mael", category = "ext:quests", questId = 1234, inLog = true, mapID = 1421,
        searchCommandDesc = "Available: Level 22", onClick = function() end, spots = { 1, 2 },
        _gpsPlaceAt = 12.5, keywords = { "quest" },
    })
    H.assertEq(clean.questId, 1234, "the provider's own id")
    H.assertEq(clean.inLog, true, "the provider's own flag")
    H.assertEq(clean.mapID, 1421, "the listed field")
    H.assertEq(clean.searchCommandDesc, "Available: Level 22", "the subtext")
    H.assertNil(clean.onClick, "no functions")
    H.assertNil(clean.spots, "no tables beyond the listed ones")
    H.assertNil(clean._gpsPlaceAt, "no scratch fields")
    H.assertEq(clean.keywords[1], "quest", "the listed table")
end

function tests.aCoreRowKeepsOnlyTheListedFields()
    local _, ns = fresh()
    local clean = ns.UIPins.CleanForStorage({ name = "Swift Zulian Tiger", category = "Mount", mountID = 100, spare = 3 })
    H.assertEq(clean.mountID, 100)
    H.assertNil(clean.spare, "an unlisted field of a core row stays out")
end

function tests.aPinShowsItsLiveRowAndRefreshesTheStoredCopy()
    local env, ns = fresh()
    local live = { name = "The Wrath of Rath'mael", category = "ext:quests", questId = 1234, inLog = true }
    local tiger = { name = "Swift Zulian Tiger", category = "Mount", mountID = 100, isCollected = true }
    local rows = { ["ext:ext:quests:The Wrath of Rath'mael"] = live, ["mount:100"] = tiger }
    ns.Aliases.GetEntryKey = function(_, data)
        return data.mountID and "mount:" .. data.mountID or "ext:" .. data.category .. ":" .. data.name
    end
    ns.Aliases.LiveEntryByKey = function(_, key) return rows[key] end
    local pins = env.EasyFind.db.pinnedUIItems
    pins[1] = { name = "The Wrath of Rath'mael", category = "ext:quests", isPinned = true }
    pins[2] = { name = "A Frightened Request", category = "ext:quests", isPinned = true }
    local charPins = { { name = "Swift Zulian Tiger", category = "Mount", mountID = 100, isPinned = true } }
    env.EasyFind.db.pinnedUIItemsPerChar = { ["Tester-Realm"] = charPins }
    H.assertEq(ns.UIPins.LiveRow(pins[1]), live, "the live row stands in for the pin")
    H.assertEq(pins[1].questId, 1234, "the stored copy learned the live row's fields")
    H.assertEq(pins[1].isPinned, true, "and stays a pin")
    H.assertEq(#pins, 2, "in its place")
    local old = pins[2]
    H.assertEq(ns.UIPins.LiveRow(old), old, "no live row: the stored copy")
    H.assertEq(ns.UIPins.LiveRow(charPins[1]), tiger, "a collection pin's live row stands in too")
    H.assertEq(charPins[1].isCollected, true, "and refreshes its copy in the character's list")
    H.assertEq(#charPins, 1)
    rows["ext:ext:quests:The Wrath of Rath'mael"] = { name = "The Wrath of Rath'mael", category = "ext:quests", questId = 1234, inLog = false }
    ns.UIPins.LiveRow(pins[1])
    H.assertEq(pins[1].inLog, false, "a new live row refreshes the copy again")
end

local pass, fail, failures = H.runSuite("PinSnapshot", tests)
return { pass = pass, fail = fail, failures = failures }

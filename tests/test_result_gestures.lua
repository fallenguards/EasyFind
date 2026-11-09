-- Tests for Search/Results/Gestures.lua: what a click, Alt and Ctrl do on
-- a kind of result, the user's choice over the default, an action the row
-- cannot do giving way, and the hint built from the mapping.

local H = require("Harness")

local held = {}

local function Load(db)
    local env = H.newEnv()
    env.IsAltKeyDown = function() return held.alt == true end
    env.IsControlKeyDown = function() return held.ctrl == true end
    env.IsShiftKeyDown = function() return held.shift == true end
    env.EasyFind = { db = db or { resultClicks = {} } }
    env.C_Item = { GetItemInfoInstant = function() return 1, nil, nil, "INVTYPE_HEAD" end }
    local ns = H.newNs(env)
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    ns.ResultIcons = {
        IsMountSummonable = function(_, d) return d.summonable ~= false end,
        IsPetSummonable = function() return true end,
        IsSpellbookOnlyAbility = function() return false end,
    }
    ns.ResultHandlers = { GetBagItemActionKind = function(_, d) return d.bagKind or "use" end }
    ns.ResultShortcuts = {}
    H.loadModule("Search/Results/Gestures.lua", env, ns)
    return ns.ResultGestures, env, ns
end

local tests = {}

function tests.defaultsAreTheOldGestures()
    local G = Load()
    local mount = { mountID = 5 }
    H.assertEq(G.ActionFor(mount, "click"), "summon")
    H.assertEq(G.ActionFor(mount, "alt"), "journal")
    H.assertEq(G.ActionFor(mount, "ctrl"), "preview")
    H.assertEq(G.ActionFor(mount, "shift"), "drag")
    H.assertEq(G.Hint(mount), "HINT_CLICK: Summon | Alt: Journal | Ctrl: Preview | Shift: Drag")
end

function tests.aChoiceMovesTheDeedToAnotherKey()
    local G = Load({ resultClicks = { mount = { click = "journal", ctrl = "summon" } } })
    local mount = { mountID = 5 }
    H.assertEq(G.ActionFor(mount, "click"), "journal")
    H.assertEq(G.ActionFor(mount, "ctrl"), "summon")
    held.ctrl = true
    H.assertFalse(G.WantsSource(mount), "Ctrl summons now")
    held.ctrl = nil
    H.assertTrue(G.WantsSource(mount), "a plain click opens the journal now")
    H.assertEq(G.Hint(mount), "HINT_CLICK: Journal | Alt: Journal | Ctrl: Summon | Shift: Drag")
end

function tests.aStrayValueFallsBackToTheDefault()
    local G = Load({ resultClicks = { mount = { alt = "fly" } } })
    H.assertEq(G.ActionFor({ mountID = 5 }, "alt"), "journal")
end

function tests.noneBlocksTheGesture()
    local G = Load({ resultClicks = { ability = { alt = "none" } } })
    local spell = { spellID = 9, category = "Ability" }
    held.alt = true
    H.assertTrue(G.Blocked(spell))
    H.assertFalse(G.WantsSource(spell))
    held.alt = nil
    H.assertFalse(G.Blocked(spell))
    H.assertEq(G.Hint(spell), "HINT_CLICK: HINT_CAST | Shift: Drag")
end

function tests.aDeedTheRowCannotDoGivesWayToItsHome()
    local G = Load()
    local grounded = { mountID = 5, summonable = false }
    H.assertEq(G.ActionFor(grounded, "click"), "journal")
    H.assertEq(G.Hint(grounded), "HINT_CLICK: Journal | Alt: Journal | Ctrl: Preview | Shift: Drag")
    local potion = { itemID = 3, category = "Bag", bagKind = "use" }
    H.assertNil(G.ActionFor(potion, "ctrl"), "no dressing room for a potion")
    H.assertEq(G.Hint(potion), "HINT_CLICK: Use | Alt: Bags | Shift: Drag")
end

function tests.shiftStaysTheDragWhereAKindHasOne()
    local G = Load({ resultClicks = { mount = { shift = "summon" }, settingPress = { shift = "settings" } } })
    H.assertEq(G.ActionFor({ mountID = 5 }, "shift"), "drag")
    H.assertTrue(G.ShiftFixed("mount") and not G.ShiftFixed("settingPress"))
    H.assertEq(#G.SettableFor("mount"), 3)
    H.assertEq(#G.SettableFor("settingPress"), 4)
    H.assertNil(G.ShiftChosen({ mountID = 5 }), "the drag is no choice")
    local press = { settingPress = true }
    H.assertEq(G.ActionFor(press, "shift"), "settings", "a kind with no drag takes the Shift choice")
    H.assertEq(G.ShiftChosen(press), "settings")
    H.assertEq(G.Hint(press), "HINT_CLICK: HINT_RUN | Alt: Settings | Shift: Settings")
end

-- An item's click shows where it comes from; Shift sends its link.
function tests.anItemOpensItsSourcesAndShiftSendsItsLink()
    local G, _, ns = Load()
    ns.ItemSources = { Available = function(d) return d.itemID ~= nil end }
    local item = { catalogItem = true, itemID = 2589, name = "Linen Cloth" }
    H.assertEq(G.ActionFor(item, "click"), "sources")
    H.assertEq(G.ActionFor(item, "shift"), "sendLink")
    H.assertEq(G.ActionFor(item, "ctrl"), "dressroom")
    H.assertTrue(G.ShiftFixed("catalog"), "Shift stays the link")
    held.shift = true
    H.assertTrue(G.Does(item, "sendLink"))
    held.shift = nil
    H.assertTrue(G.Does(item, "sources"))
    H.assertEq(G.Hint(item), "HINT_CLICK: HINT_SOURCES | Ctrl: Dressing Room | Shift: CTX_SEND_LINK")
    local drop = { itemID = 2589, category = "Loot", name = "Linen Cloth" }
    H.assertEq(G.ActionFor(drop, "click"), "sources")
    H.assertEq(G.ActionFor(drop, "alt"), "encounter")
    H.assertEq(G.ActionFor(drop, "shift"), "sendLink")
    ns.ItemSources = nil
    H.assertNil(G.ActionFor(item, "click"), "no sources page: the click does nothing yet")
    local choices = {}
    for _, c in ipairs(G.Choices(G.Kind("catalog"))) do choices[c.value] = true end
    H.assertTrue(choices.sendLink, "the link stays a choice for the other keys")
    H.assertNil(choices.drag)
end

-- A dungeon row: the GPS goes, Ctrl lists its bosses, Shift opens the map;
-- without the GPS the click opens the map.
function tests.aDungeonGoesByGPSOrOpensTheMap()
    local G, env, ns = Load()
    local dungeon = { isDungeonEntrance = true, category = "dungeon", name = "Ruins of Lordaeron", mapID = 1420, x = 0.6, y = 0.7 }
    H.assertEq(G.KindOf(dungeon), "instance")
    H.assertNil(G.KindOf({ isDungeonEntrance = true, category = "delve", name = "A delve" }), "a delve stays a map row")
    H.assertEq(G.ActionFor(dungeon, "click"), "openMap", "no GPS: the map")
    H.assertNil(G.ActionFor(dungeon, "ctrl"), "no bosses known for it")
    H.assertEq(G.ActionFor(dungeon, "shift"), "openMap")
    env.EasyFind.API = {
        HasAction = function(id, name) return id == "gps" and name == "navigate" end,
        CallAction = function(id, name) return id == "gps" and name == "canNavigate" end,
    }
    ns.ItemSources = { InstanceHasBosses = function(name) return name == "Ruins of Lordaeron" end }
    H.assertEq(G.ActionFor(dungeon, "click"), "gps")
    H.assertEq(G.ActionFor(dungeon, "ctrl"), "bosses")
    H.assertNil(G.ActionFor({ isDungeonEntrance = true, category = "raid", name = "Onyxia's Lair" }, "ctrl"),
        "a raid with no bosses known offers none")
    H.assertEq(G.Hint(dungeon), "HINT_CLICK: APP_GPS | Ctrl: Bosses | Shift: HINT_OPEN_MAP")
end

function tests.setWritesOnlyWhatDiffersFromTheDefault()
    local G, env = Load()
    G.Set("mount", "click", "summon")
    H.assertNil(env.EasyFind.db.resultClicks.mount, "the default stores nothing")
    G.Set("mount", "click", "journal")
    H.assertEq(env.EasyFind.db.resultClicks.mount.click, "journal")
    H.assertEq(G.Get("mount", "click"), "journal")
    G.Reset()
    H.assertEq(G.Get("mount", "click"), "summon")
end

local pass, fail, failures = H.runSuite("ResultGestures", tests)
return { pass = pass, fail = fail, failures = failures }

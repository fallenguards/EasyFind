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
    return ns.ResultGestures, env
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

function tests.shiftIsNeverRemapped()
    local G = Load({ resultClicks = { mount = { shift = "summon" } } })
    H.assertEq(G.ActionFor({ mountID = 5 }, "shift"), "drag")
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

-- Tests for Apps/GPS/Jumps.lua: what lets a character land from any height,
-- and how a walk that jumps says so.

local H = require("Harness")

local function Load(opts)
    local env = H.newEnv()
    env._G = env
    local known, items, worn, cooldown = opts.known or {}, opts.items or {}, opts.worn or {}, opts.cooldown or {}
    env.IsPlayerSpell = function(id) return known[id] == true end
    env.C_Spell = {
        GetSpellCooldown = function(id) return { startTime = cooldown[id] and 100 or 0, duration = cooldown[id] or 0 } end,
        GetSpellName = function(id) return "spell " .. id end,
    }
    env.C_Item = {
        GetItemCount = function(id) return items[id] or 0 end,
        IsEquippedItem = function(id) return worn[id] == true end,
        GetItemNameByID = function(id) return "item " .. id end,
    }
    env.C_Container = { GetItemCooldown = function() return 0, 0, 1 end }
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { forever = opts.forever }
    ns.GPSNav = { DropHeights = function() if opts.noData then return nil end return 12.4, 20 end }
    ns.L.GPS_JUMP_FULL_FMT = "full %d"
    ns.L.GPS_JUMP_HELPER_FMT = "use %s %d"
    ns.L.GPS_JUMP_WEAR_FMT = "wear %s %d"
    ns.L.GPS_JUMP_FULL_AT_FMT = "full at %s %d"
    ns.L.GPS_JUMP_HELPER_AT_FMT = "use %s at %s %d"
    ns.L.GPS_JUMP_WEAR_AT_FMT = "wear %s at %s %d"
    H.loadModule("Apps/GPS/Jumps.lua", env, ns)
    return ns.GPSJumps, ns, env
end

local tests = {}

function tests.slowFall_needsItsFeatherOnForever()
    H.assertNil(Load({ forever = true, known = { [130] = true } }).Helper(), "no Light Feather")
    local h = Load({ forever = true, known = { [130] = true }, items = { [17056] = 3 } }).Helper()
    H.assertEq(h and h.kind, "spell")
    H.assertEq(Load({ known = { [130] = true } }).Helper().kind, "spell", "retail asks no reagent")
end

function tests.wornItem_saysToPutItOn()
    local h = Load({ items = { [260810] = 1 } }).Helper()
    H.assertEq(h.kind, "item")
    H.assertTrue(h.wear, "a cloak in the bags goes on first")
    H.assertNil(Load({ items = { [260810] = 1 }, worn = { [260810] = true } }).Helper().wear)
end

function tests.immunity_onlyOffCooldown()
    H.assertEq(Load({ known = { [11958] = true } }).Helper().kind, "immune")
    H.assertNil(Load({ known = { [11958] = true }, cooldown = { [11958] = 300 } }).Helper())
end

function tests.limit_byWhatTheCharacterHas()
    H.assertEq(Load({ known = { [642] = true } }).Limit(0), math.huge, "lands safely from any height")
    H.assertEq(Load({}).Limit(0), 20, "else what a full-health character survives")
    H.assertNil(Load({ noData = true }).Limit(0), "no drops in the data")
end

function tests.stepText_saysHowToJump()
    local J = Load({})
    H.assertNil(J.StepText({ text = "Walk" }), "no jump, nothing to say")
    H.assertEq(J.StepText({ jumps = { { h = 14.6 }, { h = 17.2 } } }), "full 17", "the highest, at full health")
    J = Load({ items = { [260810] = 1 } })
    H.assertEq(J.StepText({ jumps = { { h = 30 } } }), "wear item 260810 30", "past survival: the helper, put on first")
    H.assertEq(J.StepText({ jumps = { { h = 15 } } }), "full 15", "survivable needs no helper")
end

-- The step's button: a teleport's spell or item, and at a ledge past what
-- full health survives, what lands the character (2026-10-27: "Use Slow
-- Fall" with no icon to press).
function tests.stepCast_whatTheButtonPresses()
    local J = Load({ known = { [130] = true } })
    H.assertEq(J.StepCast({ kind = "teleport", spellID = 3561 }), 3561, "a teleport's spell")
    local _, item = J.StepCast({ kind = "teleport", itemID = 6948 })
    H.assertEq(item, 6948)
    H.assertEq(J.StepCast({ jumps = { { h = 30 } } }), 130, "a ledge past survival: Slow Fall")
    H.assertNil(J.StepCast({ jumps = { { h = 15 } } }), "a survivable ledge: nothing to press")
    H.assertNil(J.StepCast({ text = "Walk" }))
    H.assertTrue(J.HasCast({ jumps = { { h = 30 } } }))
    H.assertFalse(J.HasCast({ jumps = { { h = 15 } } }))
    J = Load({ items = { [260810] = 1 } })
    local spell, parachute = J.StepCast({ jumps = { { h = 30 } } })
    H.assertNil(spell)
    H.assertEq(parachute, 260810, "an item in the bags: the item")
    H.assertNil(Load({}).StepCast({ jumps = { { h = 30 } } }), "nothing that lands: no button")
end

-- Where the ledge is (2026-10-26, "no idea what ledge"): the nearest area
-- of its zone, else a landmark beside it (a city has no areas), else the
-- zone. Map 1 is 1000 yd a side on continent 0; the zone stand-in is it.
local function Placed(ns, areas, statics)
    ns.GPS = { ZoneAt = function() return 1, "Stormwind City" end }
    ns.GPSRoute = { WorldPos = function(_, x, y) return 0, x * 1000, y * 1000 end }
    ns.GPSData = { areas = { [1] = areas } }
    ns.STATIC_LOCATIONS = { [1] = statics }
end

function tests.stepText_namesWhereTheLedgeIs()
    local J, ns, env = Load({})
    env.C_Map = { GetAreaInfo = function(id) return id == 7 and "Valley of Heroes" or nil end }
    Placed(ns, { 7, 0.5, 0.5 }, {})
    local step = { arrive = { ci = 0 }, jumps = { { h = 12, x = 100, y = 100 }, { h = 23, x = 520, y = 480 } } }
    H.assertEq(J.StepText(step), "full at Valley of Heroes 23", "the highest one's place")
    Placed(ns, {}, { { name = "Bank", category = "bank", x = 0.55, y = 0.5 }, { name = "Alchemy", category = "prof_alchemy", x = 0.52, y = 0.48 } })
    H.assertEq(J.StepText({ arrive = { ci = 0 }, jumps = { { h = 23, x = 520, y = 480 } } }), "full at Bank 23",
        "a city: a landmark, not a trainer")
    Placed(ns, {}, {})
    H.assertEq(J.StepText({ arrive = { ci = 0 }, jumps = { { h = 23, x = 520, y = 480 } } }), "full at Stormwind City 23")
    ns.GPS = nil
    H.assertEq(J.StepText({ arrive = { ci = 0 }, jumps = { { h = 23, x = 520, y = 480 } } }), "full 23", "nowhere to name")
end

function tests.any_findsAStepThatJumps()
    local J = Load({})
    H.assertFalse(J.Any({ {}, { text = "x" } }))
    H.assertTrue(J.Any({ {}, { jumps = { { h = 14 } } } }))
end

local pass, fail, failures = H.runSuite("GPSJumps", tests)
return { pass = pass, fail = fail, failures = failures }

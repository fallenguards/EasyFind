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
    H.loadModule("Apps/GPS/Jumps.lua", env, ns)
    return ns.GPSJumps
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

function tests.any_findsAStepThatJumps()
    local J = Load({})
    H.assertFalse(J.Any({ {}, { text = "x" } }))
    H.assertTrue(J.Any({ {}, { jumps = { { h = 14 } } } }))
end

local pass, fail, failures = H.runSuite("GPSJumps", tests)
return { pass = pass, fail = fail, failures = failures }

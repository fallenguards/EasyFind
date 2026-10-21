-- Tests for the ClassicUI Forever windows beyond the micro buttons: spell
-- rows light the spell in its book, and the Who, guild and quest log
-- keybinding rows open its versions. When a window is not replaced, the
-- client's path runs as before.
local H = require("Harness")

local function fakeApi(on)
    local api = { version = 1, opened = {}, lookups = 0, shown = false }
    local book = { IsShown = function() return api.shown end }
    api.button = { IsVisible = function() return true end }
    api.showing = { [api.button] = 133 }
    function api.SpellOnButton(button) return api.showing[button] end
    function api.IsOn(name) return on[name] == true end
    function api.Open(name, arg)
        api.opened[#api.opened + 1] = { name = name, arg = arg }
        if name == "spellBook" then api.shown = true end
        return name ~= "whoList" or not api.inCombat
    end
    function api.GetFrame(name, part)
        if name ~= "spellBook" or not api.shown then return nil end
        if part == nil then return book end
        api.lookups = api.lookups + 1
        return part == "spell:133" and api.button or nil
    end
    return api
end

local function loadSpellbook(api)
    local env = H.newEnv()
    env._G = env
    env.ClassicUIForeverAPI = api
    env.Enum = { SpellBookSpellBank = { Player = 0, Pet = 1 } }
    env.SpellbookMicroButton = { IsShown = function() return true end }
    local ns = H.newNs(env)
    H.loadModule("Search/Openers.lua", env, ns)
    local lit = {}
    local highlight = {
        HighlightSpellbookSpell = function(_, btn, validator) lit[#lit + 1] = { btn = btn, validator = validator } end,
        HighlightFrame = function(_, frame) lit[#lit + 1] = { btn = frame } end,
    }
    ns.RequestGuide = function() return highlight end
    H.loadModule("Search/Results/Handlers/Spellbook.lua", env, ns)
    return ns.ResultHandlers, env, lit
end

local function loadBindings(api, calls)
    local env = H.newEnv()
    env._G = env
    env.ClassicUIForeverAPI = api
    env.FRIEND_TAB_WHO = 2
    env.ToggleFriendsFrame = function(tab) calls[#calls + 1] = "friends:" .. tostring(tab) end
    env.ToggleGuildFrame = function() calls[#calls + 1] = "guild" end
    env.ToggleQuestLog = function() calls[#calls + 1] = "questlog" end
    local ns = H.newNs(env)
    ns.Database.uiSearchData = {}
    env.EasyFind._ns = ns
    H.loadModule("Search/Openers.lua", env, ns)
    H.loadModule("Apps/Settings/BlizzSearch.lua", env, ns)
    return ns.BlizzOptionsSearch
end

-- The clock schedules a timer set while it fires from the new time, so
-- chained retries need small steps.
local function run(env, seconds)
    for _ = 1, math.floor((seconds or 1) / 0.05) do env._clock:advance(0.05) end
end

local tests = {}

function tests.bookNotReplaced_leavesTheApiAlone()
    local api = fakeApi({})
    local Handlers, env = loadSpellbook(api)
    Handlers:OpenAbilityInSpellbook({ spellID = 133 }, false)
    run(env)
    H.assertEq(#api.opened, 0)
end

function tests.whoBinding_opensTheReplacement()
    local calls = {}
    local api = fakeApi({ whoList = true })
    local Blizz = loadBindings(api, calls)
    H.assertTrue(Blizz:PerformBinding("TOGGLEWHOTAB"))
    H.assertEq(api.opened[1] and api.opened[1].name, "whoList")
    H.assertEq(#calls, 0, "the client's social window is not opened")
end

function tests.whoBinding_inCombatReportsNotOpened()
    local calls = {}
    local api = fakeApi({ whoList = true })
    api.inCombat = true
    local Blizz = loadBindings(api, calls)
    H.assertFalse(Blizz:PerformBinding("TOGGLEWHOTAB"))
    H.assertEq(#calls, 0)
end

function tests.guildAndQuestBindings_followTheToggles()
    local calls = {}
    local api = fakeApi({ guildRoster = true })
    local Blizz = loadBindings(api, calls)
    H.assertTrue(Blizz:PerformBinding("TOGGLEGUILDTAB"))
    H.assertTrue(Blizz:PerformBinding("TOGGLEQUESTLOG"))
    H.assertEq(api.opened[1] and api.opened[1].name, "guildRoster")
    H.assertEq(calls[1], "questlog", "the quest log is not replaced here, so the client's opens")
end

function tests.noApi_bindingsOpenTheClients()
    local calls = {}
    local Blizz = loadBindings(nil, calls)
    H.assertTrue(Blizz:PerformBinding("TOGGLEWHOTAB"))
    H.assertEq(calls[1], "friends:2")
end

local pass, fail, failures = H.runSuite("CuifReplacements", tests)
return { pass = pass, fail = fail, failures = failures }

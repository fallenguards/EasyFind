-- Tests for Search/Openers.lua: a window ClassicUI Forever replaces opens
-- through its public API, never through the client's button; when the API
-- is absent, says the window is not replaced, or errors, the client's
-- button opens as before.
local H = require("Harness")

local function fresh(api)
    local env = H.newEnv()
    local ns = H.newNs(env)
    local clicked = {}
    ns.Utils.ClickButton = function(btn) clicked[#clicked + 1] = btn return true end
    ns.Utils.SecureCall = function(fn, ...) return fn(...) end
    ns.Utils.GetFrameByPath = function(path) return env[path] end
    env.GuildMicroButton = { name = "GuildMicroButton" }
    env.QuestLogMicroButton = { name = "QuestLogMicroButton" }
    env.ClassicUIForeverAPI = api
    H.loadModule("Search/Openers.lua", env, ns)
    return ns.SearchOpeners, clicked
end

local function fakeApi(on, openResult)
    local api = { version = 1, opened = {} }
    function api.IsOn(name) return on[name] == true end
    function api.Open(name) api.opened[#api.opened + 1] = name return openResult end
    return api
end

local tests = {}

function tests.replacedWindow_opensThroughTheApi()
    local api = fakeApi({ guildRoster = true }, true)
    local Openers, clicked = fresh(api)
    H.assertTrue(Openers:OpenButtonFrame("GuildMicroButton"))
    H.assertEq(api.opened[1], "guildRoster")
    H.assertEq(#clicked, 0, "the client's guild button is never pressed")
end

function tests.replacedWindowThatCannotOpenNow_stillSkipsTheClient()
    local api = fakeApi({ questLog = true }, false)
    local Openers, clicked = fresh(api)
    H.assertFalse(Openers:OpenButtonFrame("QuestLogMicroButton"), "in combat: not shown now")
    H.assertEq(#clicked, 0, "the client's quest log is not opened instead")
end

function tests.windowNotReplaced_opensTheClients()
    local api = fakeApi({}, true)
    local Openers, clicked = fresh(api)
    Openers:OpenButtonFrame("GuildMicroButton")
    H.assertEq(#api.opened, 0)
    H.assertEq(clicked[1] and clicked[1].name, "GuildMicroButton")
end

function tests.noApi_opensTheClients()
    local Openers, clicked = fresh(nil)
    Openers:OpenButtonFrame("QuestLogMicroButton")
    H.assertEq(clicked[1] and clicked[1].name, "QuestLogMicroButton")
end

function tests.apiError_fallsBackToTheClient()
    local api = { version = 1, IsOn = function() error("boom") end, Open = function() return true end }
    local Openers, clicked = fresh(api)
    Openers:OpenButtonFrame("GuildMicroButton")
    H.assertEq(clicked[1] and clicked[1].name, "GuildMicroButton")
end

local pass, fail, failures = H.runSuite("OpenersReplacement", tests)
return { pass = pass, fail = fail, failures = failures }

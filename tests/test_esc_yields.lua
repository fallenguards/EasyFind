-- A background window of ours (the chat) lets a game window that is open
-- take Escape first (2026-10-27: Escape closed the chat before the
-- talents). Its Esc entry yields while the panel manager or the game's
-- Escape list shows a window; every other entry is unchanged.
local H = require("Harness")

local function Load(env)
    local f = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("do\n    local PANEL_SIDES", 1, true) or src:find("do\r\n    local PANEL_SIDES", 1, true))
    local e1 = assert(src:find("\nend\r?\n", s))
    local w = assert(src:find("function Utils.EscEntryWants(entry)", 1, true))
    local _, e2 = assert(src:find("\nend\r?\n", w))
    local chunk = src:sub(s, e1 + 4) .. "\n" .. src:sub(w, e2)
    local ns, Utils = {}, {}
    env.ns, env.Utils = ns, Utils
    env._G = env
    assert(load(chunk, "=Utils.lua esc", "t", setmetatable(env, { __index = _G })))()
    return ns, Utils
end

local function shown(v) return { IsShown = function() return v end } end

local tests = {}

function tests.aGameWindowOpen_theChatYields()
    local panel
    local ns, Utils = Load({ GetUIPanel = function(side) return side == "left" and panel or nil end })
    local chat = { yields = true }
    local menu = {}
    H.assertTrue(Utils.EscEntryWants(chat), "nothing of the game's open: the chat takes Escape")
    panel = {}
    H.assertTrue(ns.GamePanelOpen())
    H.assertFalse(Utils.EscEntryWants(chat), "talents open: the game's Escape first")
    H.assertTrue(Utils.EscEntryWants(menu), "an entry that does not yield is unchanged")
end

function tests.theGamesEscapeListCounts()
    local ns, Utils = Load({ UISpecialFrames = { "SomeWindow" }, SomeWindow = shown(true) })
    H.assertTrue(ns.GamePanelOpen())
    H.assertFalse(Utils.EscEntryWants({ yields = true }))
end

function tests.aHiddenFrameNeverTakesEscape()
    local _, Utils = Load({})
    H.assertFalse(Utils.EscEntryWants({ frame = shown(false) }), "an entry left behind by a wiped OnHide hook")
    H.assertTrue(Utils.EscEntryWants({ frame = shown(true) }))
end

function tests.aPredicateStillDecides()
    local _, Utils = Load({})
    H.assertFalse(Utils.EscEntryWants({ shouldEat = function() return false end }))
    H.assertFalse(Utils.EscEntryWants({ shouldEat = function() error("x") end }), "fail-open: a broken predicate lets go")
end

local pass, fail, failures = H.runSuite("EscYields", tests)
return { pass = pass, fail = fail, failures = failures }

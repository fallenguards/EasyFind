-- Tests for cursor menus at combat start (Shared/Utils.lua): an open
-- cascade gives the keyboard back before lockdown, since propagation
-- cannot change in a fight, so a menu left open never eats W/A/S/D.

local H = require("Harness")

local function Source()
    local fh = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = fh:read("*a")
    fh:close()
    return src
end

-- CursorMenuOnEvent's head, through its combat branch, run alone.
local function OnEvent()
    local src = Source()
    local s = assert(src:find("\nlocal function CursorMenuOnEvent(self, event)", 1, true), "CursorMenuOnEvent")
    local e = assert(src:find('\n    if event ~= "GLOBAL_MOUSE_DOWN"', s, true), "its mouse branch")
    local Utils = { SafeCallMethod = function(obj, method, ...) return obj[method](obj, ...) end }
    local chunk = assert(load("local Utils = ...\n" .. src:sub(s, e) .. "end\nreturn CursorMenuOnEvent",
        "=CursorMenuOnEvent", "t", _G))
    return chunk(Utils)
end

local function Menu()
    local m = { keyboard = true, propagate = false }
    function m:EnableKeyboard(on) self.keyboard = on end
    function m:SetPropagateKeyboardInput(on) self.propagate = on end
    return m
end

local tests = {}

function tests.combatStartReleasesTheWholeCascade()
    local handler = OnEvent()
    local root, sub = Menu(), Menu()
    root._openSubmenu = sub
    handler(root, "PLAYER_REGEN_DISABLED")
    for _, m in ipairs({ root, sub }) do
        H.assertFalse(m.keyboard, "no keyboard in the fight")
        H.assertTrue(m.propagate, "keys reach the game")
    end
end

function tests.theRootListensForCombatWhileShown()
    local src = Source()
    local show = src:match("\nlocal function CursorMenuOnShow%(self%)(.-)\nend\n")
    local hide = src:match("\nlocal function CursorMenuOnHide%(self%)(.-)\nend\n")
    H.assertTrue(show and show:find('self:RegisterEvent("PLAYER_REGEN_DISABLED")', 1, true) ~= nil, "shown: listens")
    H.assertTrue(hide and hide:find('self:UnregisterEvent("PLAYER_REGEN_DISABLED")', 1, true) ~= nil, "hidden: stops")
end

local pass, fail, failures = H.runSuite("Menu combat", tests)
return { pass = pass, fail = fail, failures = failures }

-- A hint tooltip whose side had no room was clamped back over its owner,
-- covering the very row it explained (2026-10-26): Utils.HintSide picks a
-- side with room.
local H = require("Harness")

local function LoadHintSide()
    local f = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function Utils.HintSide(", 1, true))
    local e = select(2, assert(src:find("\nend\r?\n", s)))
    local env = setmetatable({ Utils = {} }, { __index = _G })
    assert(load(src:sub(s, e), "=Utils.lua HintSide", "t", env))()
    return env.Utils.HintSide
end

local SUBMENU = { "ANCHOR_LEFT", "ANCHOR_TOP", "ANCHOR_BOTTOM" }
local SCREEN_W, SCREEN_H, GAP = 1000, 700, 7

local tests = {}

function tests.aSideWithRoomIsKept()
    local HintSide = LoadHintSide()
    -- A menu row at x 500: 280 wide fits on its left.
    H.assertEq(HintSide(SUBMENU, 500, 400, 230, 26, 280, 90, GAP, SCREEN_W, SCREEN_H), "ANCHOR_LEFT")
end

function tests.noRoomLeftGoesAboveNeverOverTheRow()
    local HintSide = LoadHintSide()
    -- The menu near the screen's left edge (the screenshot): left has 330,
    -- the panel is 380 wide, the submenu holds the right: above it goes.
    H.assertEq(HintSide(SUBMENU, 330, 290, 230, 26, 380, 100, GAP, SCREEN_W, SCREEN_H), "ANCHOR_TOP")
    -- Near the top as well: below.
    H.assertEq(HintSide(SUBMENU, 330, 640, 230, 26, 380, 100, GAP, SCREEN_W, SCREEN_H), "ANCHOR_BOTTOM")
end

function tests.aRowWithoutSubmenuTriesItsMirrorFirst()
    local HintSide = LoadHintSide()
    local order = { "ANCHOR_RIGHT", "ANCHOR_LEFT", "ANCHOR_TOP", "ANCHOR_BOTTOM" }
    H.assertEq(HintSide(order, 800, 300, 180, 22, 280, 80, GAP, SCREEN_W, SCREEN_H), "ANCHOR_LEFT")
end

function tests.theMenuRowTooltipChoosesItsSide()
    local f = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = f:read("*a")
    f:close()
    H.assertTrue(src:find("side = Utils.HintSide(order,", 1, true) ~= nil, "ShowHintTooltip picks a side")
    H.assertTrue(src:find("row._submenuRows and MenuTip.SUBMENU_SIDES", 1, true) ~= nil, "a submenu row's sides")
end

local pass, fail, failures = H.runSuite("HintSide", tests)
return { pass = pass, fail = fail, failures = failures }

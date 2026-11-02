-- A cursor menu's leave delay counts the flyout a swap just closed as
-- inside, and a press outside while a cursor menu is up closes that menu
-- and nothing under it. The cascade closed 0.45 s after a narrower flyout
-- replaced the one the pointer was heading for, and the click that
-- followed found no menu and took the bar (retail, 2026-11-02, the
-- clickwatch recording: cascade hidden from the menu's OnUpdate at +7.57,
-- bar hidden by its outside-click closer at +10.40).
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local tests = {}

function tests.theClosedFlyoutStaysInsideForTheLeaveDelay()
    local utils = Read("Shared/Utils.lua")
    local close = assert(utils:find("local function CursorMenuCloseSubmenu(menu)", 1, true))
    local body = utils:sub(close, assert(utils:find("\nend\n", close, true)))
    H.assertTrue(body:find("root._closedFlyout = { left = left, right = left + width, bottom = bottom, top = bottom + height,", 1, true) ~= nil,
        "the flyout's rectangle is kept before it hides")
    H.assertTrue(body:find("if child then child:Hide() end", body:find("root._closedFlyout", 1, true), true) ~= nil, "kept first, hidden after")
    H.assertTrue(utils:find("self._closedFlyout = nil", 1, true) ~= nil, "dropped with the menu")
    local pin = Read("Search/Results/PinPopup.lua")
    H.assertNil(pin:find("stayOpen = true", 1, true), "the result menu keeps its leave-close")
end

-- The chain test itself over a kept rectangle, cut from the file: inside
-- it counts, past its edge not, and the delay forgets it.
function tests.aPointerInTheKeptFlyoutCountsAsInside()
    local utils = Read("Shared/Utils.lua")
    local s = assert(utils:find("local function CursorMenuChainHasMouse(menu)", 1, true))
    local e = assert(utils:find("\nend\n", s, true))
    local now, cursor = 100, { 0, 0 }
    local env = { GetTime = function() return now end, GetCursorPosition = function() return cursor[1], cursor[2] end,
        CursorMenuHasMouse = function() return false end }
    local Chain = assert(load(utils:sub(s, e + 4) .. "\nreturn CursorMenuChainHasMouse", "=Utils chain", "t", env))()
    local root = { outsideDelay = 0.45, IsShown = function() return true end,
        _closedFlyout = { left = 1220, right = 1493, bottom = 449, top = 530, scale = 0.5, at = 100 } }
    cursor = { 1400 * 0.5, 480 * 0.5 }
    H.assertTrue(Chain(root), "inside the kept flyout, in its own scale")
    cursor = { 1600 * 0.5, 480 * 0.5 }
    H.assertFalse(Chain(root), "past its right edge")
    cursor = { 1400 * 0.5, 480 * 0.5 }
    now = 100.5
    H.assertFalse(Chain(root), "forgotten after the leave delay")
    H.assertNil(root._closedFlyout)
end

function tests.aPressOutsideAMenuClosesTheMenuOnly()
    local utils = Read("Shared/Utils.lua")
    H.assertTrue(utils:find("function Utils.IsCursorMenuShown()", 1, true) ~= nil)
    for _, path in ipairs({ "Search/SearchBar.lua", "Search/Results/ResultsFrame.lua" }) do
        local src = Read(path)
        local over = assert(src:find("if Utils.IsCursorMenuMouseOver() then return end", 1, true), path .. " counts the menu as inside")
        local shown = assert(src:find("if Utils.IsCursorMenuShown() then return end", over, true), path .. " leaves the press to the menu")
        H.assertTrue(shown - over < 200, path .. ": the two checks sit together")
    end
end

local pass, fail, failures = H.runSuite("MenuClickAway", tests)
return { pass = pass, fail = fail, failures = failures }

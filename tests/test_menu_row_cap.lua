-- No menu runs off the screen (2026-10-26: the checklist's Track > An item
-- count listed every bag item past the bottom edge). A menu or flyout with
-- more rows than Utils.MENU_MAX_ROWS scrolls unless it names its own cap.
local H = require("Harness")

-- Utils.ShowCursorMenu up to its row cap, run on its own.
local function Opener()
    local fh = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = fh:read("*a")
    fh:close()
    local s = assert(src:find("Utils.MENU_MAX_ROWS = ", 1, true), "no menu row cap in Utils.lua")
    local open = assert(src:find("function Utils.ShowCursorMenu(", s, true), "the cap is not before ShowCursorMenu")
    local _, e = src:find("\n    end\r?\n", open)
    local Utils = {}
    local chunk = src:sub(s, e) .. "    return opts\nend\n"
    assert(load(chunk, "=Utils.lua ShowCursorMenu", "t", setmetatable({ Utils = Utils }, { __index = _G })))()
    return Utils
end

local function Rows(n)
    local rows = {}
    for i = 1, n do rows[i] = { text = "Row " .. i } end
    return rows
end

local tests = {}

function tests.aLongMenuScrolls()
    local Utils = Opener()
    local opts = Utils.ShowCursorMenu("M", Rows(60))
    H.assertEq(opts.maxRows, Utils.MENU_MAX_ROWS)
end

function tests.aShortMenuShowsEveryRow()
    local Utils = Opener()
    H.assertEq(Utils.ShowCursorMenu("M", Rows(Utils.MENU_MAX_ROWS)).maxRows, nil)
end

function tests.aMenuKeepsItsOwnCap()
    local Utils = Opener()
    H.assertEq(Utils.ShowCursorMenu("M", Rows(60), { maxRows = 10 }).maxRows, 10)
end

local pass, fail, failures = H.runSuite("MenuRowCap", tests)
return { pass = pass, fail = fail, failures = failures }

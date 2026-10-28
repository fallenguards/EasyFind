-- A menu flyout closed under the cursor resting on its row (2026-10-26,
-- /efd subclose): a brush over a plain row armed a 0.4 s close for the open
-- flyout, the cursor went on to another flyout row, and the pooled frame
-- came back as that row's flyout, so the timer closed it. Closing a flyout
-- now cancels its pending close.
local H = require("Harness")

local function Load()
    local fh = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = fh:read("*a")
    fh:close()
    local parts = {}
    for _, head in ipairs({ "local function CursorMenuCloseSubmenu(", "local function CursorMenuRowEntered(" }) do
        local s = assert(src:find(head, 1, true), head)
        local e = select(2, assert(src:find("\nend\r?\n", s)))
        parts[#parts + 1] = src:sub(s, e)
    end
    local timers = {}
    -- One pooled flyout frame, as ShowCursorMenu hands back per depth.
    local flyout = { shown = false }
    function flyout:Hide() self.shown = false end
    function flyout:IsShown() return self.shown end
    function flyout:Raise() end
    local env = setmetatable({
        SUBMENU_GLOBAL = "EasyFindCursorSubmenu",
        CursorMenuHasMouse = function() return false end,
        Utils = {
            SafeAfter = function(_, fn) timers[#timers + 1] = fn end,
            ShowCursorMenu = function() flyout.shown = true return flyout end,
            RaiseMenu = function(f) f:Raise() end,
        },
    }, { __index = _G })
    local RowEntered = assert(load(table.concat(parts, "\n") .. "\nreturn CursorMenuRowEntered",
        "=Utils.lua cursor menu", "t", env))()
    return RowEntered, flyout, timers
end

local function Row(name, submenu)
    return { name = name, _submenuRows = submenu and { { text = "x" } } or nil }
end

local tests = {}

function tests.aBrushBeforeAnotherFlyoutRowNeverClosesThatRowsFlyout()
    local RowEntered, flyout, timers = Load()
    local menu = { GetScale = function() return 1 end, GetFrameStrata = function() return "DIALOG" end,
        GetFrameLevel = function() return 1 end }
    local add, pin, remove = Row("Add", true), Row("Pin"), Row("Remove", true)
    RowEntered(menu, remove)
    H.assertEq(menu._openSubmenuRow, remove)
    RowEntered(menu, pin)
    H.assertEq(#timers, 1, "the brush armed a close")
    RowEntered(menu, add)
    H.assertEq(menu._openSubmenuRow, add, "Add's flyout opened in the pooled frame")
    timers[1]()
    H.assertTrue(flyout:IsShown(), "the old timer left Add's flyout open")
    H.assertEq(menu._openSubmenuRow, add)
end

function tests.aBrushStillClosesTheFlyoutItWasFor()
    local RowEntered, flyout, timers = Load()
    local menu = { GetScale = function() return 1 end, GetFrameStrata = function() return "DIALOG" end,
        GetFrameLevel = function() return 1 end }
    local remove, pin = Row("Remove", true), Row("Pin")
    RowEntered(menu, remove)
    RowEntered(menu, pin)
    timers[1]()
    H.assertFalse(flyout:IsShown(), "the cursor never reached it")
    H.assertEq(menu._openSubmenuRow, nil)
end

-- The highlight follows the cursor at once: the flyout's row lets go the
-- moment another row is entered, while the flyout itself waits; reaching
-- the flyout lights its row again (2026-10-26: the old row stayed lit for
-- the whole wait, two rows lit, the menu felt laggy).
local function LitRow(name, submenu)
    local row = Row(name, submenu)
    function row:SetMenuHighlightFocused(on) self.lit = on end
    return row
end

function tests.theHighlightLeavesTheFlyoutsRowAtOnce_theFlyoutWaits()
    local RowEntered, flyout, timers = Load()
    local menu = { GetScale = function() return 1 end, GetFrameStrata = function() return "DIALOG" end,
        GetFrameLevel = function() return 1 end }
    local show, close = LitRow("Show", true), LitRow("Close")
    RowEntered(menu, show)
    H.assertTrue(show.lit, "lit while its flyout opens")
    RowEntered(menu, close)
    H.assertFalse(show.lit, "let go at once")
    H.assertTrue(flyout:IsShown(), "the flyout waits")
    H.assertEq(#timers, 1)
end

function tests.reachingTheFlyout_lightsItsRowAgain()
    local RowEntered, flyout = Load()
    local menu = { GetScale = function() return 1 end, GetFrameStrata = function() return "DIALOG" end,
        GetFrameLevel = function() return 1 end }
    local show, close = LitRow("Show", true), LitRow("Close")
    RowEntered(menu, show)
    RowEntered(menu, close)
    flyout._parentMenu = menu
    RowEntered(flyout, LitRow("Recent searches"))
    H.assertTrue(show.lit, "its row is the way back")
    RowEntered(menu, show)
    H.assertTrue(show.lit and flyout:IsShown(), "back on its row: still open and lit")
end

-- The per-frame pass lights a row by its lock or the cursor alone: it also
-- lit the row whose flyout was open, so the old row stayed lit for the whole
-- wait after the lock let go (2026-10-26, the Notes menu's Trash).
function tests.theHighlightPass_anOpenFlyoutAloneLightsNothing()
    local fh = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = fh:read("*a")
    fh:close()
    local s = assert(src:find("local function CursorMenuDriveRowHighlights(", 1, true))
    local e = select(2, assert(src:find("\nend\r?\n", s)))
    local lit = {}
    local env = setmetatable({ Utils = { UpdateRoundedRowWash = function(row, on) lit[row.name] = on end } },
        { __index = _G })
    local Drive = assert(load(src:sub(s, e) .. "\nreturn CursorMenuDriveRowHighlights", "=Utils.lua drive", "t", env))()
    local function Row(name, mouse)
        return { name = name, _efMenuRowHighlightInstalled = true, _efWashActive = true,
                 IsShown = function() return true end, IsMouseOver = function() return mouse end }
    end
    local trash, delete = Row("Trash", false), Row("Delete note", true)
    local menu = { rows = { trash, delete }, _openSubmenuRow = trash }
    Drive(menu, false)
    H.assertFalse(lit.Trash, "its flyout waits to close, its row lets go")
    H.assertTrue(lit["Delete note"], "the hovered row is the one lit")
    trash._efWashFocused = true
    Drive(menu, false)
    H.assertTrue(lit.Trash, "the lock lights it: the cursor is in its flyout")
end

local pass, fail, failures = H.runSuite("SubmenuStaleClose", tests)
return { pass = pass, fail = fail, failures = failures }

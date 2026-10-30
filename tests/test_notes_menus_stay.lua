-- A notes menu worked in (toggle rows, a search, flyouts) stays until a
-- click outside or Esc; one closing when the cursor drifted off it for a
-- third of a second went mid-use (Era, 2026-10-30). A plain action menu
-- still closes when the mouse leaves it.
local H = require("Harness")

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Notes/Notes.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local s = assert(src:find("function UI:ShowEasyNotesMenu(name, rows, opts)", 1, true))
    local _, e = src:find("\nend\n", s)
    local shown
    local env = setmetatable({
        UI = {},
        Utils = { ShowCursorMenu = function(_, _, opts) shown = opts return true end },
        NormalizeDB = function() return {} end,
        UI_SCALE_DEFAULT = 1,
        GameFontHighlightSmall = {},
    }, { __index = _G })
    assert(load(src:sub(s, e), "=Notes.lua ShowEasyNotesMenu", "t", env))()
    return env.UI, function() return shown end
end

local tests = {}

function tests.toggleRowsKeepTheMenuUntilAClickOutside()
    local UI, shown = Load()
    UI:ShowEasyNotesMenu("m", { { text = "Open", keepOpen = true }, { text = "Remove" } })
    H.assertTrue(shown().stayOpen == true, "a toggle row")
    UI:ShowEasyNotesMenu("m", { { text = "Auto-show", submenu = function() end } })
    H.assertTrue(shown().stayOpen == true, "a flyout")
    UI:ShowEasyNotesMenu("m", { { text = "x" } }, { rowsProvider = function() end })
    H.assertTrue(shown().stayOpen == true, "rows that come again after a click")
end

function tests.aPlainActionMenuStillClosesOnLeave()
    local UI, shown = Load()
    UI:ShowEasyNotesMenu("m", { { text = "Open" }, { text = "Delete" } })
    H.assertTrue(shown().stayOpen == false)
    UI:ShowEasyNotesMenu("m", { { text = "Open", keepOpen = true } }, { stayOpen = false })
    H.assertTrue(shown().stayOpen == false, "a caller's own word stands")
end

local pass, fail, failures = H.runSuite("NotesMenusStay", tests)
return { pass = pass, fail = fail, failures = failures }

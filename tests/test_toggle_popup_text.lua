-- Toggle popups (Shared/TogglePopup.lua, the app flyouts of the
-- extensions menu): every row label wears the theme's text color on every
-- show. A pooled row made on a later open took its font object's own gold
-- from SetFontObject, and the menu panel's refill on show (StyleMenuPanel)
-- repaints only after a theme change, so "Add shortkey" read white in one
-- flyout and gold in the next (2026-10-30).
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local tests = {}

function tests.everyShowRetintsTheLabels()
    local src = Read("Shared/TogglePopup.lua")
    local s = assert(src:find("function ns.ShowTogglePopup(name, anchor, defs, opts)", 1, true))
    local body = src:sub(s)
    local retint = assert(body:find("ns.RetintMenuText(popup)", 1, true), "the labels are retinted on show")
    local show = assert(body:find("popup:Show()", 1, true))
    H.assertTrue(retint < show, "before the popup shows")
    H.assertTrue(body:find("popup.MenuFont(row.label)", 1, true) < retint, "after every row took its font")
end

-- The pooled rows never color themselves: the one owner stays the retint.
function tests.rowsOwnNoColor()
    local src = Read("Shared/TogglePopup.lua")
    local s = assert(src:find("local function MakePlainRow(popup)", 1, true))
    local e = assert(src:find("\nend\n", s, true))
    H.assertNil(src:sub(s, e):find("SetTextColor", 1, true))
    H.assertNil(src:sub(s, e):find("_efOwnColor", 1, true))
end

local pass, fail, failures = H.runSuite("TogglePopupText", tests)
return { pass = pass, fail = fail, failures = failures }

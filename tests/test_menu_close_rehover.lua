-- A result row's right-click menu closing with the cursor back on a row
-- (2026-10-26) cleared that row's hover subtext: no OnEnter came, as the
-- cursor never left it. The menu's close runs the hovered row's OnEnter.
local H = require("Harness")

local tests = {}

function tests.theMenusCloseRehoversTheRowUnderTheCursor()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Rows/ResultContextMenu.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("extra.onHide = function()", 1, true), "the menu's close")
    local e = assert(src:find("\n    end\r?\n", s), "its end")
    local body = src:sub(s, e)
    local selection = assert(body:find("UpdateSelectionHighlight", 1, true), "the selection refresh")
    local rehover = body:find('GetScript("OnEnter")', 1, true)
    H.assertTrue(rehover ~= nil, "the row under the cursor takes its hover")
    H.assertTrue(rehover > selection, "after the selection refresh, which clears the hint")
    H.assertTrue(body:find("IsMouseOver()", 1, true) ~= nil, "only the row under the cursor")
end

local pass, fail, failures = H.runSuite("MenuCloseRehover", tests)
return { pass = pass, fail = fail, failures = failures }

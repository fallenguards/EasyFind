-- A button style's repaint (RefreshVisual in Shared/Utils.lua) leaves the
-- label alone under the Classic skin: the skin's paint sets it (gold at
-- rest), and a repaint that set the theme's color after it left the label
-- grey until a hover painted the skin's again (/efd btncolor, 2026-10-25).
local H = require("Harness")

local tests = {}

function tests.aRepaintNeverColorsASkinnedLabel()
    local f = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local bad, seen = {}, 0
    for _, body in src:gmatch("\n(%s*)[%w_%.]+%.RefreshVisual = function%(self%)(.-)\n%1end") do
        seen = seen + 1
        if body:find("_label:SetTextColor", 1, true) and not body:find("_efRedOn", 1, true) then
            bad[#bad + 1] = body:sub(1, 80)
        end
    end
    H.assertTrue(seen >= 2, "found the button styles' repaints")
    H.assertEq(table.concat(bad, " | "), "", "repaints that color the label under the Classic skin")
end

local pass, fail, failures = H.runSuite("ButtonSkinLabels", tests)
return { pass = pass, fail = fail, failures = failures }

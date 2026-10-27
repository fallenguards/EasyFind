-- Picking a Classic background repaints everything at once (2026-10-27: the
-- chat and menus kept the old background until a reload). The pick goes
-- through the whole theme's application, as a theme change does: the theme
-- generation, open menus, theme callbacks (extensions too), text shading.
local H = require("Harness")

local tests = {}

function tests.aBackgroundPickAppliesTheWholeTheme()
    local f = assert(io.open(H.ADDON_ROOT .. "/Core/SettingsRows.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local body = src:match("function SettingsRows%.RedressClassic%(%)(.-)\nend")
    H.assertTrue(body ~= nil, "RedressClassic is there")
    H.assertTrue(body:find("ns.ApplyUITheme(theme)", 1, true) ~= nil, "it applies the theme again")
end

function tests.theThemesApplicationRepaintsEveryone()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Theme.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local body = src:match("function ns%.ApplyUITheme%(themeName, skipRepaint%)(.-)\nend\n")
    H.assertTrue(body ~= nil)
    for _, call in ipairs({ "ns.uiThemeGeneration = ", "ns.RestyleShownMenuPanels()", "ns.ShadeTextEverywhere()",
                            "ns.FireThemeCallbacks()" }) do
        H.assertTrue(body:find(call, 1, true) ~= nil, call)
    end
end

local pass, fail, failures = H.runSuite("ClassicBackgroundSwitch", tests)
return { pass = pass, fail = fail, failures = failures }

-- Two map search findings from an extension's spots (Era, 2026-10-30):
-- a pin of a cluster clicked kept no icon and drew the question mark (an
-- extension's category is not in CATEGORY_ICONS), and "Show me how" sat
-- on the menus of extension spots and creature rows, which have no window
-- of their own to lead to.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Chunk(path, from, to, ret, env)
    local src = Read(path)
    local s = assert(src:find(from, 1, true), from)
    local e = assert(src:find(to, s, true), to)
    return assert(load(src:sub(s, e - 1) .. "\nreturn " .. ret, "=" .. path, "t", setmetatable(env, { __index = _G })))()
end

local function Icons()
    return Chunk("MapSearch/Main.lua", "local function GetCategoryIcon(category)", "local function GetFilterBucket(data)",
        "{ icon = GetCategoryIcon, guide = GuideAllowed }", {
            CATEGORY_ICONS = { unknown = "?", inn = "bed" }, MapSearch = {},
            ns = { Extensions = { Providers = { byCategory = { fishing = { icon = 136245 } } } } },
        })
end

local tests = {}

function tests.anExtensionsCategoryDrawsItsProvidersGlyph()
    local fns = Icons()
    H.assertEq(fns.icon("inn"), "bed", "the game's categories as before")
    H.assertEq(fns.icon("fishing"), 136245, "an extension's category: its provider's icon")
    H.assertEq(fns.icon("nothing"), "?", "a category no one knows")
end

function tests.aClusterPinClickedKeepsItsOwnLook()
    local src = Read("MapSearch/Navigation.lua")
    H.assertTrue(src:find("pin.waypointIcon = instance.icon", 1, true) ~= nil, "each pin keeps its icon")
    H.assertTrue(src:find("pin.waypointDisplayID = instance.displayID", 1, true) ~= nil, "and its face")
    H.assertTrue(src:find("ShowWaypointAt(x, y, self.waypointIcon or (sel and sel.icon), cat, nil, self.waypointDisplayID)", 1, true) ~= nil,
        "the click passes them on")
end

function tests.noGuideForExtensionSpotsOrCreatures()
    local fns = Icons()
    H.assertFalse(fns.guide({ providerRow = {} }), "an extension's spot")
    H.assertFalse(fns.guide({ placeOf = function() end }), "an extension's place")
    H.assertFalse(fns.guide({ npcID = 5 }), "a creature")
    H.assertFalse(fns.guide({ category = "npc" }), "a creature row")
    H.assertTrue(fns.guide({ category = "inn" }), "an inn keeps Show me how")
    H.assertTrue(Read("Search/Results/Rows/ResultContextMenu.lua"):find("ns.MapSearch.GuideAllowed(pinData)", 1, true) ~= nil,
        "the main bar's menu asks")
    local tab = Read("MapSearch/MapTab.lua")
    H.assertTrue(tab:find("MapSearch.GuideAllowed(data) and function()", 1, true) ~= nil, "the map tab's row menu asks")
    H.assertTrue(tab:find("MapSearch.GuideAllowed(navigateData) and function()", 1, true) ~= nil, "and its header menu")
end

local pass, fail, failures = H.runSuite("MapGuideRows", tests)
return { pass = pass, fail = fail, failures = failures }

-- Which side tab of the world map shows selected (RefreshSelectGlows in
-- MapSearch/MapTab.lua): the map search tab stays lit while its GPS page
-- shows, a page with no tab of its own; a page with its own tab lights that.
local H = require("Harness")

local function Tab()
    local glow = { shown = false }
    function glow:SetShown(v) self.shown = v and true or false end
    local icon = {}
    function icon:SetVertexColor() end
    return { _efSelectGlow = glow, _efIcon = icon }
end

local function Load(selectedIsOurs, activePage)
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/MapTab.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local function RefreshSelectGlows()", 1, true))
    local _, e = assert(src:find("\nend\r?\n", s))
    local search, legend, notes = Tab(), Tab(), Tab()
    local env = setmetatable({
        Host = function() return { MapLegendTab = legend } end,
        tabFrame = search, backTab = nil, extraTabs = { notes = notes },
        selectedIsOurs = selectedIsOurs, activePage = activePage,
        pages = { gps = { id = "gps", noTab = true }, notes = { id = "notes" } },
        Utils = { RGB = function() return 1, 1, 1 end },
        TAB_ICON_GOLD = {}, TAB_ICON_DIM = {},
        FindAtlasTexture = function() return nil end, SIDE_TAB_SELECT = "x",
    }, { __index = _G })
    assert(load(src:sub(s, e) .. "\nreturn RefreshSelectGlows", "=MapTab.lua glows", "t", env))()()
    return search._efSelectGlow.shown, notes._efSelectGlow.shown
end

local tests = {}

function tests.theGpsPage_keepsTheSearchTabLit()
    local search, notes = Load(true, "gps")
    H.assertTrue(search, "navigating, still on the map search tab")
    H.assertFalse(notes)
end

function tests.theResults_lightTheSearchTab()
    H.assertTrue((Load(true, nil)))
end

function tests.aPageWithItsOwnTab_lightsThatOne()
    local search, notes = Load(true, "notes")
    H.assertFalse(search)
    H.assertTrue(notes)
end

function tests.anotherTabSelected_lightsNeither()
    local search, notes = Load(false, "gps")
    H.assertFalse(search)
    H.assertFalse(notes)
end

local pass, fail, failures = H.runSuite("MapTabGlow", tests)
return { pass = pass, fail = fail, failures = failures }

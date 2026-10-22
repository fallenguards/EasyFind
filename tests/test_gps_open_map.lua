-- GPS:Open (Apps/GPS/GPS.lua): the map's GPS page, or on a map with no
-- side panel to hold it (Era, Anniversary) the map alone, so a step click
-- still shows that step's preview on it.
local H = require("Harness")

local function loadOpen(pageOpens, mapShown)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function GPS:Open()", 1, true), "GPS:Open not found")
    local _, e = src:find("\nend\r?\n", s)
    local GPS = {}
    local shown = false
    local env = setmetatable({
        GPS = GPS,
        WorldMapFrame = { IsShown = function() return shown end },
        ns = { MapTab = { ShowPage = function()
            -- The opener shows the map first, then the page if it can.
            shown = mapShown
            return pageOpens
        end } },
    }, { __index = _G })
    assert(load(src:sub(s, e), "=GPS.lua Open", "t", env))()
    return GPS
end

local tests = {}

function tests.thePageOpens()
    H.assertTrue(loadOpen(true, true):Open())
end

function tests.aMapWithNoPanelOpensAlone()
    H.assertTrue(loadOpen(false, true):Open(), "Era and Anniversary: the step shows on the map")
end

function tests.nothingOpenedIsNotOpen()
    H.assertFalse(loadOpen(false, false):Open(), "map search off: the opener opened nothing")
end

local pass, fail, failures = H.runSuite("GPSOpenMap", tests)
return { pass = pass, fail = fail, failures = failures }

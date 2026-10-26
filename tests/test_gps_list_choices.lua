-- The GPS search lists' choices (Apps/GPS/GPS.lua GPS.LIST_CHOICES): each
-- surface keeps its own, the page beside the map shares the map tab's.
-- Parent zones start off in the window and the section (only the
-- matches), on beside the map; the rest start on everywhere.
local H = require("Harness")

local function Load(db)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("GPS.LIST_CHOICES = {", 1, true), "GPS.LIST_CHOICES")
    local e = assert(src:find("function GPS.ListChoiceRow", s, true), "GPS.ListChoiceRow after it")
    local GPS = {}
    local env = setmetatable({ GPS = GPS, DB = function() return db end }, { __index = _G })
    assert(load(src:sub(s, e - 1), "=GPS.lua ListChoice", "t", env))()
    return GPS
end

local WINDOW, SECTION, MAP_PAGE = { isPopout = true }, {}, { mapFont = true }

local tests = {}

function tests.parentZonesStartOffInTheGPSOwnWindows()
    local GPS = Load({})
    H.assertFalse(GPS.ListChoice(WINDOW, "parents"), "the window: only the matches")
    H.assertFalse(GPS.ListChoice(SECTION, "parents"), "the section: only the matches")
    H.assertTrue(GPS.ListChoice(MAP_PAGE, "parents"), "beside the map, as the map tab")
    for _, which in ipairs({ "recent", "expand" }) do
        for _, frame in ipairs({ WINDOW, SECTION, MAP_PAGE }) do
            H.assertTrue(GPS.ListChoice(frame, which), which .. " starts on")
        end
    end
end

function tests.eachSurfaceKeepsItsOwn()
    local db = { gpsPopoutShowParents = true, gpsDockShowRecent = false, mapTabAutoExpand = false }
    local GPS = Load(db)
    H.assertTrue(GPS.ListChoice(WINDOW, "parents"))
    H.assertFalse(GPS.ListChoice(SECTION, "parents"), "the section's own, untouched")
    H.assertFalse(GPS.ListChoice(SECTION, "recent"))
    H.assertTrue(GPS.ListChoice(WINDOW, "recent"), "the window's own, untouched")
    H.assertFalse(GPS.ListChoice(MAP_PAGE, "expand"), "the page beside the map reads the map tab's")
    H.assertTrue(GPS.ListChoice(WINDOW, "expand"))
end

local pass, fail, failures = H.runSuite("GPSListChoices", tests)
return { pass = pass, fail = fail, failures = failures }

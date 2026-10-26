-- The pop-outs' settings cog (Apps/GPS/GPS.lua): on unless the GPS setting
-- turns it off; off, a pop-out's search cog hides and its box takes the
-- room. The map page's cog, a surface with no menu of its own, stays.
local H = require("Harness")

local function Load(db)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function GPS.SearchRight", 1, true))
    local at = assert(src:find("function GPS.ApplyCogs", s, true))
    local _, e = assert(src:find("\nend\r?\n", at))
    local GPS = { searchFrames = {} }
    local refreshed = 0
    local env = setmetatable({ GPS = GPS, DB = function() return db end, ns = {},
        Refresh = function() refreshed = refreshed + 1 end }, { __index = _G })
    assert(load(src:sub(s, e), "=GPS.lua cogs", "t", env))()
    return GPS, function() return refreshed end
end

local function Surface(withMenu)
    local cog = { shown = true }
    function cog:SetShown(v) self.shown = v and true or false end
    function cog:IsShown() return self.shown end
    local box = { right = nil }
    function box:SetPoint(point, _, _, x) if point == "RIGHT" then self.right = x end end
    return { searchCog = cog, search = box, searchPad = 10, ShowMenu = withMenu and function() end or nil }
end

local tests = {}

function tests.onUnlessTurnedOff()
    H.assertTrue((Load({})).CogsShown())
    H.assertTrue((Load(nil)).CogsShown())
    H.assertFalse((Load({ gpsCog = false })).CogsShown())
end

function tests.turnedOff_thePopoutsCogHides_andTheBoxTakesItsRoom()
    local db = { gpsCog = false }
    local GPS, refreshed = Load(db)
    local popout, page = Surface(true), Surface(false)
    GPS.searchFrames = { popout, page }
    GPS.ApplyCogs()
    H.assertFalse(popout.searchCog.shown)
    H.assertEq(popout.search.right, -10, "the box runs to the edge")
    H.assertTrue(page.searchCog.shown, "the map page keeps its cog")
    H.assertEq(refreshed(), 1, "the window's own cog follows on the redraw")
    db.gpsCog = nil
    GPS.ApplyCogs()
    H.assertTrue(popout.searchCog.shown)
    H.assertEq(popout.search.right, -31, "room again for the cog")
end

local pass, fail, failures = H.runSuite("GPSCogSetting", tests)
return { pass = pass, fail = fail, failures = failures }

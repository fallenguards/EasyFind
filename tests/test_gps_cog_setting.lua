-- The pop-outs' settings cog (Apps/GPS/GPS.lua): seen on hover by default
-- (2026-10-27), shown always or hidden by the GPS setting; hidden, a
-- pop-out's search cog goes and its box takes the room. The map page's cog,
-- a surface with no menu of its own, stays.
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
    local Utils = { SafeOnUpdate = function(frame, fn) frame.update = fn end }
    local env = setmetatable({ GPS = GPS, DB = function() return db end, ns = {}, Utils = Utils,
        Refresh = function() refreshed = refreshed + 1 end }, { __index = _G })
    assert(load(src:sub(s, e), "=GPS.lua cogs", "t", env))()
    return GPS, function() return refreshed end
end

local function Surface(withMenu)
    local cog = { shown = true, alpha = 1 }
    function cog:SetShown(v) self.shown = v and true or false end
    function cog:IsShown() return self.shown end
    function cog:SetAlpha(a) self.alpha = a end
    local box = { right = nil }
    function box:SetPoint(point, _, _, x) if point == "RIGHT" then self.right = x end end
    return { searchCog = cog, search = box, searchPad = 10, ShowMenu = withMenu and function() end or nil,
        over = false, IsMouseOver = function(self) return self.over end }
end

local tests = {}

function tests.hoverUnlessSetOtherwise()
    H.assertEq((Load({})).CogMode(), "hover")
    H.assertEq((Load(nil)).CogMode(), "hover")
    H.assertEq((Load({ gpsCog = "show" })).CogMode(), "show")
    H.assertEq((Load({ gpsCog = "hide" })).CogMode(), "hide")
    H.assertEq((Load({ gpsCog = false })).CogMode(), "hide", "the old off switch")
    H.assertFalse((Load({ gpsCog = "hide" })).CogsShown())
end

function tests.onHover_theCogShowsWhileTheCursorIsOnTheWindow()
    local GPS = Load({})
    local popout = Surface(true)
    GPS.searchFrames = { popout }
    GPS.ApplyCogs()
    local cog = popout.searchCog
    H.assertTrue(cog.shown, "it keeps its place")
    H.assertEq(cog.alpha, 0, "unseen away from the window")
    popout.over = true
    cog.update(cog, 1)
    H.assertEq(cog.alpha, 1, "seen on the window")
    popout.over = false
    cog.update(cog, 1)
    H.assertEq(cog.alpha, 0)
end

function tests.shown_theCogStaysSeen()
    local GPS = Load({ gpsCog = "show" })
    local popout = Surface(true)
    GPS.searchFrames = { popout }
    GPS.ApplyCogs()
    H.assertEq(popout.searchCog.alpha, 1)
    H.assertEq(popout.searchCog.update, nil, "nothing watches the cursor")
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

-- Every mark EasyFind puts on the world map is cleared by a right-click
-- (2026-10-27: the route's end emblem took no mouse at all). Our location
-- pin clears the search and the route ending there; the route preview's
-- end mark clears the route.
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.theRoutesEndMarkClearsTheRoute()
    local src = Read("Apps/GPS/Preview.lua")
    local hit = src:match('local hit = CreateFrame%("Button".-marks%.hit = hit')
    H.assertTrue(hit ~= nil, "a button over the end mark")
    H.assertTrue(hit:find('RegisterForClicks%("RightButtonUp"%)') ~= nil, "it takes a right-click")
    H.assertTrue(hit:find("GPS:Clear()", 1, true) ~= nil, "which ends the route")
    H.assertTrue(src:find("marks.hit:SetAllPoints(mark)", 1, true) ~= nil, "laid over whichever end mark shows")
end

function tests.theLocationPinClearsOnRightClick()
    local src = Read("MapSearch/Navigation.lua")
    local click = src:match("local function PinClick%(self, button%)(.-)\nend")
    H.assertTrue(click and click:find('button == "RightButton"', 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("MapMarksClear", tests)
return { pass = pass, fail = fail, failures = failures }

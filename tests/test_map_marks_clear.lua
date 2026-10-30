-- Every mark EasyFind puts on the world map is cleared by a right-click
-- (2026-10-27: the route's end emblem took no mouse at all). Our location
-- pin clears the search and the route ending there; the GPS extension's
-- end mark is its own repo's test.
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.theLocationPinClearsOnRightClick()
    local src = Read("MapSearch/Navigation.lua")
    local click = src:match("local function PinClick%(self, button%)(.-)\nend")
    H.assertTrue(click and click:find('button == "RightButton"', 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("MapMarksClear", tests)
return { pass = pass, fail = fail, failures = failures }

-- The arrival line sat on the time line's row and ran under "Clear route"
-- (2026-10-27). With the trip's fields (Apps/GPS/Trip.lua) it hangs where
-- the steps start: the same drop below the fields as the step list.
local H = require("Harness")

local function Drop(src, what)
    local y = src:match(what .. ':SetPoint%("TOPLEFT", ed, "BOTTOMLEFT", [^,]+, (%-%b())%)')
    return y
end

local tests = {}

function tests.arrivalLineStartsWhereTheStepsDo()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/Trip.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local list, empty = Drop(src, "frame%.list"), Drop(src, "frame%.empty")
    H.assertTrue(list ~= nil, "the step list hangs from the fields")
    H.assertEq(empty, list, "the arrival line drops as far as the steps")
end

local pass, fail, failures = H.runSuite("GPSArrivalLine", tests)
return { pass = pass, fail = fail, failures = failures }

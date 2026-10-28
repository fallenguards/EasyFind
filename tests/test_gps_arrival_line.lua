-- The arrival line sat on the time line's row and ran under "Clear route"
-- (2026-10-27). With the trip's fields (Apps/GPS/Trip.lua) it hangs where
-- the steps start: the same drop below the fields as the step list.
local H = require("Harness")

local tests = {}

function tests.arrivalLineStartsWhereTheStepsDo()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/Trip.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local list = src:match('frame%.list:SetPoint%("TOPLEFT", ed, "BOTTOMLEFT", [^,]+, (%-%b())%)')
    H.assertTrue(list ~= nil, "the step list hangs from the fields")
    -- The drop the arrival line takes (Trip.PlaceEmpty with the steps' place).
    local empty = src:match("ed%.emptyX, ed%.emptyStepsY = [^,]+, (%-%b())")
    H.assertEq(empty, list, "the arrival line drops as far as the steps")
end

local pass, fail, failures = H.runSuite("GPSArrivalLine", tests)
return { pass = pass, fail = fail, failures = failures }

-- The GPS search boxes carry the map tab's gear after them (2026-10-26):
-- every layout that moves a box's right end leaves the gear its room, so
-- none may anchor the box's right end itself; GPS.SearchRight does.
local H = require("Harness")

local tests = {}

function tests.everyRightAnchorOfTheBoxLeavesTheGearRoom()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local bare, through = {}, 0
    for line in src:gmatch("[^\n]+") do
        if line:find('%.search:SetPoint%("RIGHT"') and not line:find("GPS.SearchRight", 1, true)
            and not line:find("x %- %(f%.searchCog") then
            bare[#bare + 1] = line:match("^%s*(.-)%s*$")
        end
        if line:find("GPS.SearchRight(f,", 1, true) then through = through + 1 end
    end
    H.assertEq(table.concat(bare, " | "), "", "use GPS.SearchRight, which leaves the gear its 21 px")
    H.assertTrue(through >= 4, "the window's, the banner's, the Era look's and the section's layouts: " .. through)
end

function tests.theGearOpensTheMapTabsShowChoices()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    H.assertTrue(src:find("MapTab.CreateFilterCog(box)", 1, true) ~= nil, "built on the box, hidden with it")
    H.assertTrue(src:find("local defs = MapTab.ShowDefs()", 1, true) ~= nil, "the map tab's own Show choices")
end

local pass, fail, failures = H.runSuite("GPSSearchCog", tests)
return { pass = pass, fail = fail, failures = failures }

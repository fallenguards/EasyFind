-- A "show me how" to a zone (its outline and arrow on the map) went away
-- as the cursor left the row (2026-10-28): the row's hover preview had
-- claimed the map's outline and cleared it on its end. A guide under way
-- marks itself; the hover preview then leaves the outline alone, and the
-- mark goes only with the guide (the map change, the search box's X).
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.aGuideMarksItselfAndTheHoverLeavesTheOutlineToIt()
    H.assertTrue(Read("MapSearch/Zones/Navigation.lua"):find("self%._zoneGuide = targetMapID") ~= nil, "the guide marks itself")
    H.assertTrue(Read("MapSearch/Preview.lua"):find("and self%.PreviewZoneHighlight and not self%._zoneGuide then") ~= nil,
        "no hover outline while a guide holds it")
end

function tests.theMarkSurvivesTheGuidesOwnClearsAndGoesWithTheGuide()
    local hl = Read("MapSearch/Zones/Highlight.lua")
    H.assertTrue(hl:find("local savedPending, savedGuide = self%.pendingZoneHighlight, self%._zoneGuide") ~= nil
        and hl:find("self%.pendingZoneHighlight, self%._zoneGuide = savedPending, savedGuide") ~= nil,
        "the zone outline's own clear keeps it")
    H.assertTrue(hl:find("self%.pendingZoneHighlight = nil%s+self%._zoneGuide = nil%s+end") ~= nil,
        "gone with the breadcrumb guide")
    local bc = Read("MapSearch/Zones/Breadcrumbs.lua")
    H.assertTrue(bc:find("local guide = self%._zoneGuide%s+self:ClearZoneHighlight%(%)%s+self%._zoneGuide = guide") ~= nil,
        "the breadcrumb guide's own clear keeps it")
end

function tests.theSearchBoxesXEndsTheGuide()
    H.assertTrue(Read("MapSearch/MapTab.lua"):find("if ns%.MapSearch and ns%.MapSearch%.ClearZoneHighlight then ns%.MapSearch:ClearZoneHighlight%(%) end") ~= nil)
end

local pass, fail, failures = H.runSuite("ZoneGuideHover", tests)
return { pass = pass, fail = fail, failures = failures }

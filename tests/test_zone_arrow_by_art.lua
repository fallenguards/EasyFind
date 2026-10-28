-- A zone guide's arrow and click box go by the highlight art the player
-- sees, not the API's rectangle: on Era's world map the rectangle for a
-- continent lies elsewhere, and the arrow pointed at the other continent
-- while the outline was right (2026-10-28). MapSearch/Zones/Highlight.lua.
local H = require("Harness")

local tests = {}

function tests.theArrowFollowsTheHighlightArt()
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Zones/Highlight.lua", "rb"))
    local src = f:read("*a")
    f:close()
    H.assertTrue(src:find("if not isAtlas then%s+zoneLeftPx, zoneTopPx = pixelPosX, pixelPosY%s+"
        .. "zoneRightPx, zoneBottomPx = pixelPosX %+ pixelWidth, pixelPosY %+ pixelHeight%s+"
        .. "zoneCenterPxX, zoneCenterPxY = pixelPosX %+ pixelWidth / 2, pixelPosY %+ pixelHeight / 2") ~= nil,
        "the art's box stands in for the rectangle where the art is a file")
    local override = src:find("if not isAtlas then%s+zoneLeftPx, zoneTopPx")
    local arrow = src:find("if zoneHighlightFrame%.indicator then", 1, false)
    H.assertTrue(override ~= nil and arrow ~= nil and override < arrow, "before the arrow is placed")
end

-- Era's world map art for a continent is padded far past the land (the
-- probe read Kalimdor's box at -0.19 to 0.63 of the map, and the map's
-- position answers reach as far): a box past the map's edge or over a
-- third of it takes the map's own world region for the continent.
function tests.aPaddedContinentBoxTakesTheMapsRegion()
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Zones/Highlight.lua", "rb"))
    local src = f:read("*a")
    f:close()
    H.assertTrue(src:find("local l, r, t, b = posX, posX %+ texWidth, posY, posY %+ texHeight%s+"
        .. "if l < 0 or r > 1 or t < 0 or b > 1 or %(r %- l%) %* %(b %- t%) > 0%.3 then%s+"
        .. "local sL, sR, sT, sB = RegionBoundsOnMap%(mapID, parentMapID, l, r, t, b%)") ~= nil)
    H.assertTrue(src:find("local instance = GetWorldPos%(targetMapID, CreateVector2D%(0%.5, 0%.5%)%)") ~= nil
        and src:find("if GetWorldPos%(viewMapID, pos%) == instance then") ~= nil,
        "the region: where the shown map's positions land in the target's world")
end

-- The arrow beside a zone faced away from it: SetRotation turns
-- counter-clockwise, so a quarter turn on from down points right.
function tests.theArrowBesideAZoneFacesIt()
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Indicators.lua", "rb"))
    local src = f:read("*a")
    f:close()
    H.assertTrue(src:find('elseif direction == "right" then%s+return baseDown %+ mpi / 2%s+elseif direction == "left" then%s+return baseDown %- mpi / 2') ~= nil)
end

local pass, fail, failures = H.runSuite("ZoneArrowByArt", tests)
return { pass = pass, fail = fail, failures = failures }

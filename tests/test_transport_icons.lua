-- The ways of travel wear the map's own glyphs on every client
-- (2026-10-28): retail's square icons (an airship achievement, the
-- Dalaran portal spell, a gear) and classic's stand-ins are gone. Each
-- glyph is in every client's current build (wago.tools
-- UiTextureAtlasMember: retail, Forever, Mists, Anniversary, Era).
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local GLYPH = {
    flightmaster = "atlas:FlightMaster",
    zeppelin = "atlas:Vehicle-Air-Horde",
    skyship = "atlas:Vehicle-Air-Alliance",
    boat = "atlas:Ships_CargoShip-Map",
    tram = "atlas:Vehicle-AllianceCart",
}

local tests = {}

function tests.eachWayOfTravelWearsItsGlyph()
    local src = Read("MapSearch/Categories.lua")
    for key, glyph in pairs(GLYPH) do
        H.assertTrue(src:find(key .. ' = "' .. glyph:gsub("%-", "%%-") .. '"', 1, false) ~= nil, key .. " wears " .. glyph)
    end
    H.assertTrue(src:find('portal = playerFaction == "Horde" and "atlas:MagePortalHorde" or "atlas:MagePortalAlliance"') ~= nil,
        "the portal in the player's faction")
    H.assertTrue(src:find("icons%.zeppelin = ") == nil and src:find("icons%.portal = ") == nil and src:find("icons%.boat = ") == nil,
        "no classic stand-in for a way of travel")
end

function tests.theScannerTakesTheCategoryGlyph()
    local scan = Read("MapSearch/Search/Scanners.lua")
    H.assertTrue(scan:find("icon = CATEGORY_ICONS%.flightmaster,") ~= nil, "the flight master scan takes the category's glyph")
    H.assertTrue(scan:find("TaxiNode_Neutral") == nil, "the old node glyph is gone from the scan")
end

local pass, fail, failures = H.runSuite("TransportIcons", tests)
return { pass = pass, fail = fail, failures = failures }

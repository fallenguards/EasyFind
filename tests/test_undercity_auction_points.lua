-- Undercity's auction house on the classic clients is no hall: its eight
-- auctioneers stand in pairs on the four sides of the ring around the bank,
-- about 50 yards out (VMaNGOS spawns). A point beside the bankers sent
-- "Walk to Auction House" to the bank (2026-11-04).
local H = require("Harness")

-- The auctioneers' spots on map 1458, from their world positions.
local AUCTIONEERS = {
    { 0.6441, 0.5242 }, { 0.6755, 0.5243 }, { 0.6765, 0.3590 }, { 0.6439, 0.3581 },
    { 0.7151, 0.4191 }, { 0.7142, 0.4669 }, { 0.6049, 0.4176 }, { 0.6047, 0.4645 },
}
local BANK = { 0.6597, 0.4408 }
local FILES = { "Database/StaticLocations_Era.lua", "Database/StaticLocations_TBC.lua", "Database/StaticLocations_Forever.lua" }

local function UndercityPoints(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("[1458] = {", 1, true), path .. ": no Undercity")
    local e = src:find("\n    },", s, true) or #src
    local points = {}
    for x, y in src:sub(s, e):gmatch('POIName%("Auction House"%)[^\n]-x = ([%d.]+), y = ([%d.]+)') do
        points[#points + 1] = { tonumber(x), tonumber(y) }
    end
    return points
end

local function Near(a, b, d)
    return math.abs(a[1] - b[1]) <= d and math.abs(a[2] - b[2]) <= d
end

local tests = {}

function tests.everyAuctionHousePoint_standsAtAnAuctioneer()
    for _, path in ipairs(FILES) do
        local points = UndercityPoints(path)
        H.assertTrue(#points >= 1, path .. ": an auction house")
        for _, p in ipairs(points) do
            local at = false
            for _, a in ipairs(AUCTIONEERS) do at = at or Near(p, a, 0.003) end
            H.assertTrue(at, ("%s: %.4f, %.4f is at no auctioneer"):format(path, p[1], p[2]))
            H.assertFalse(Near(p, BANK, 0.03), path .. ": a point beside the bankers")
        end
    end
end

local pass, fail, failures = H.runSuite("UndercityAuctionPoints", tests)
return { pass = pass, fail = fail, failures = failures }

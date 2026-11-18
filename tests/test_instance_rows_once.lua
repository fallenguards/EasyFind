-- "wailing caverns" in the Barrens listed it twice (Forever, 2026-11-17):
-- once from the player's zone ("Dungeon: The Barrens") and once from the
-- world's list ("Dungeon: Kalimdor"), which was checked against zone names
-- only. The zone's own entrance now stands for the world's row of it.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Cut(src, from, to)
    local s = assert(src:find(from, 1, true), from)
    local e = assert(src:find(to, s, true), to)
    return src:sub(s, e - 1)
end

local function Load(world)
    local chunk = table.concat({
        "local GetNameLower = function(p) return p.name:lower() end",
        "local GetNameNorm = function(p) return p.name:lower():gsub('[^%w]', '') end",
        "local ClearPerQueryResultState = function() end",
        "local SuppressCoveredDungeonZones, EnrichZoneSearchResults = function() end, function() end",
        "local BuildPromotedInstanceCache = function() return WORLD end",
        Cut(Read("MapSearch/Search/Sources.lua"), "local function AppendPromotedInstanceResults",
            "-- Legacy PvP vendors live in the faction capitals"),
        "return AppendGlobalInstanceSearchSources",
    }, "\n")
    local env = setmetatable({ WORLD = world }, { __index = _G })
    return assert(load(chunk, "=Sources.lua instances", "t", env))()
end

local self = { GetGlobalInstanceCache = function() return {} end }

local function World()
    return { { name = "Wailing Caverns", pathPrefix = "Kalimdor" }, { name = "Razorfen Kraul", pathPrefix = "Kalimdor" } }
end

local tests = {}

function tests.thisZonesEntrance_standsForTheWorldsRow()
    local Append = Load(World())
    local out = { { name = "Wailing Caverns", pathPrefix = "The Barrens" } }
    Append(self, out, {}, {}, { ["wailing caverns"] = true })
    local n = 0
    for _, p in ipairs(out) do
        if p.name == "Wailing Caverns" then n = n + 1 end
    end
    H.assertEq(n, 1, "one Wailing Caverns")
    H.assertEq(out[1].pathPrefix, "The Barrens", "the zone's own row, kept")
    H.assertEq(out[2].name, "Razorfen Kraul", "the world's other rows still come")
end

function tests.awayFromIt_theWorldsRowComes()
    local Append = Load(World())
    local out = {}
    Append(self, out, {}, {}, {})
    H.assertEq(#out, 2)
end

function tests.theBar_passesItsZonesEntrances()
    local src = Read("MapSearch/Search/Results.lua")
    H.assertTrue(src:find("local entrances = AppendLocalSearchSources(self, pois, existingNames, nil, searchMapID, false)", 1, true) ~= nil)
    H.assertTrue(src:find("AppendGlobalInstanceSearchSources(self, pois, zoneNames, fresh, reuseUIHereEntrances)", 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("InstanceRowsOnce", tests)
return { pass = pass, fail = fail, failures = failures }

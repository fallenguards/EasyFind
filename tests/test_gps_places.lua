-- Tests for the places the GPS offers for a typed name (Apps/GPS/GPS.lua
-- WithTowns): the data's towns beside the map search's results (which
-- carry the subzones), a town the map search listed left out.
local H = require("Harness")

local function Load(data)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("\nlocal towns\n", 1, true), "towns not in GPS.lua")
    local e = assert(src:find("-- Places for a typed name", s, true), "end of WithTowns not found")
    local names = { [1637] = "Orgrimmar", [392] = "Ratchet" }
    local maps = { [1445] = { name = "Dustwallow Marsh" }, [1413] = { name = "The Barrens" } }
    local env = setmetatable({
        ns = { GPSData = data },
        C_Map = { GetAreaInfo = function(id) return names[id] or ("Town " .. id) end, GetMapInfo = function(m) return maps[m] end },
        wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
    }, { __index = _G })
    return assert(load(src:sub(s + 1, e - 1) .. "\nreturn WithTowns", "=GPS.lua WithTowns", "t", env))()
end

local tests = {}

function tests.towns_areOfferedBesideTheSearchResults()
    local WithTowns = Load({ binds = { [1637] = { m = 1413, x = 0.5, y = 0.1 }, [392] = { m = 1413, x = 0.6, y = 0.3 } } })
    local hits = WithTowns("org", nil)
    H.assertEq(#hits, 1)
    H.assertEq(hits[1].name, "Orgrimmar")
    H.assertEq(hits[1].mapID, 1413)
    H.assertEq(hits[1].x, 0.5)
    H.assertEq(hits[1].zoneName, "The Barrens")
    hits = WithTowns("rat", { { name = "Ratchet" } })
    H.assertEq(#hits, 1, "a place the map search found is not listed twice")
end

function tests.aNameTypedMidWord_followsTheSearchResults()
    local WithTowns = Load({ binds = { [392] = { m = 1413, x = 0.6, y = 0.3 } } })
    local hits = WithTowns("chet", { { name = "Chet's Hut" } })
    H.assertEq(hits[1].name, "Chet's Hut")
    H.assertEq(hits[2].name, "Ratchet")
end

-- Every keystroke merges every town against the map search's results:
-- a lookup, never a scan, or a one-letter query stalls the client.
function tests.thousandsOfTowns_mergeInATick()
    local binds, results = {}, {}
    for i = 1, 3400 do binds[10000 + i] = { m = 1445, x = 0.5, y = 0.5 } end
    local WithTowns = Load({ binds = binds })
    for i = 1, 2500 do results[i] = { name = "Result " .. i } end
    local started = os.clock()
    WithTowns("t", results)
    H.assertTrue(os.clock() - started < 0.25, "the merge took " .. (os.clock() - started) .. " s")
end

local pass, fail, failures = H.runSuite("GPSPlaces", tests)
return { pass = pass, fail = fail, failures = failures }

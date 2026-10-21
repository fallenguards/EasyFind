-- Tests for the places the GPS offers for a typed name (Apps/GPS/GPS.lua
-- WithTowns): the data's towns, every subzone the map draws, the zone's
-- own name and a town's second listing left out.
local H = require("Harness")

local function Load(data)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("\nlocal towns\n", 1, true), "towns not in GPS.lua")
    local e = assert(src:find("-- Places for a typed name", s, true), "end of WithTowns not found")
    local names = { [513] = "Theramore Isle", [1637] = "Orgrimmar", [392] = "Ratchet", [17] = "The Barrens" }
    local maps = { [1445] = { name = "Dustwallow Marsh" }, [1413] = { name = "The Barrens" } }
    local env = setmetatable({
        ns = { GPSData = data },
        C_Map = { GetAreaInfo = function(id) return names[id] or ("Area " .. id) end, GetMapInfo = function(m) return maps[m] end },
        wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
    }, { __index = _G })
    return assert(load(src:sub(s + 1, e - 1) .. "\nreturn WithTowns", "=GPS.lua WithTowns", "t", env))()
end

local tests = {}

function tests.subzones_areOfferedWithTheTowns()
    local WithTowns = Load({
        binds = { [1637] = { m = 1413, x = 0.5, y = 0.1 } },
        areas = { [1445] = { 513, 0.672, 0.501 }, [1413] = { 392, 0.6, 0.3, 1637, 0.52, 0.12, 17, 0.5, 0.5 } },
    })
    local hits = WithTowns("thera", nil)
    H.assertEq(#hits, 1)
    H.assertEq(hits[1].name, "Theramore Isle")
    H.assertEq(hits[1].mapID, 1445)
    H.assertEq(hits[1].x, 0.672)
    H.assertEq(hits[1].zoneName, "Dustwallow Marsh")
    hits = WithTowns("org", nil)
    H.assertEq(#hits, 1, "a town with a bind spot is listed once, at that spot")
    H.assertEq(hits[1].x, 0.5)
    H.assertEq(#WithTowns("barrens", nil), 0, "a zone's own name is no subzone")
    hits = WithTowns("rat", { { name = "Ratchet" } })
    H.assertEq(#hits, 1, "a place the map search found is not listed twice")
end

function tests.aNameTypedMidWord_followsTheSearchResults()
    local WithTowns = Load({ areas = { [1445] = { 513, 0.672, 0.501 } } })
    local hits = WithTowns("isle", { { name = "Isle of Dread" } })
    H.assertEq(hits[1].name, "Isle of Dread")
    H.assertEq(hits[2].name, "Theramore Isle")
end

-- Every keystroke merges every subzone against the map search's results:
-- a lookup, never a scan, or a one-letter query stalls the client.
function tests.thousandsOfSubzones_mergeInATick()
    local areas, results = {}, {}
    local lst = {}
    for i = 1, 3400 do
        lst[#lst + 1] = 10000 + i
        lst[#lst + 1] = 0.5
        lst[#lst + 1] = 0.5
    end
    areas[1445] = lst
    local WithTowns = Load({ areas = areas })
    for i = 1, 2500 do results[i] = { name = "Result " .. i } end
    local started = os.clock()
    WithTowns("a", results)
    H.assertTrue(os.clock() - started < 0.25, "the merge took " .. (os.clock() - started) .. " s")
end

local pass, fail, failures = H.runSuite("GPSPlaces", tests)
return { pass = pass, fail = fail, failures = failures }

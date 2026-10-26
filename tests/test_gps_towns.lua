-- The GPS search's towns (Apps/GPS/GPS.lua WithTowns), 2026-10-26 on TBC:
-- rows with no category drew the "?" icon. Each comes as a subzone, so the
-- place list draws the map's subzone art for the client.
local H = require("Harness")

local function Load(binds, areas)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("\nlocal towns\r?\n"), "the towns cache")
    local fs = assert(src:find("local function WithTowns(q, results)", s, true))
    local _, e = src:find("\nend\r?\n", fs)
    local env = setmetatable({
        ns = { GPSData = { binds = binds } },
        C_Map = {
            GetAreaInfo = function(area) return areas[area] end,
            GetMapInfo = function(m) return { name = "Map " .. m } end,
        },
        wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
    }, { __index = _G })
    return assert(load(src:sub(s, e) .. "return WithTowns", "=GPS.lua towns", "t", env))()
end

local tests = {}

function tests.townsComeAsSubzones()
    local WithTowns = Load({ [1] = { m = 1456, x = 0.5, y = 0.5 }, [2] = { m = 1949, x = 0.5, y = 0.5 } },
        { [1] = "Thunder Bluff", [2] = "Thunderlord Stronghold" })
    local hits = WithTowns("unde", { { name = "Undercity", category = "zone" } })
    H.assertEq(#hits, 3, "the map row and both towns")
    for i = 1, #hits do
        H.assertTrue(hits[i].icon ~= nil or hits[i].category ~= nil, hits[i].name .. " has art")
    end
    H.assertEq(hits[2].category, "subzone")
end

function tests.aTownTheMapListsIsNotAddedAgain()
    local WithTowns = Load({ [1] = { m = 1456, x = 0.5, y = 0.5 } }, { [1] = "Thunder Bluff" })
    local hits = WithTowns("thunder", { { name = "Thunder Bluff", category = "zone" } })
    H.assertEq(#hits, 1)
end

local pass, fail, failures = H.runSuite("GPSTowns", tests)
return { pass = pass, fail = fail, failures = failures }

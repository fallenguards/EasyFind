-- Zephras Isle's services in what ships for Forever: the catalog's rows and
-- the map's places. The isle's creatures come from database pages; their
-- titles once all read blank, so "innkeeper" found none there (2026-11-20).
local H = require("Harness")

local ISLE = 2521
local INNKEEPERS = { "Coriella Calmbreeze", "Donaal Downbreeze" }

local function Catalog()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { forever = true, instanceTable = true }
    local function vec(x, y) return { x = x, y = y, GetXY = function(self) return self.x, self.y end } end
    env.CreateVector2D = vec
    env.C_Item = { GetItemSubClassInfo = function() return nil end }
    env.C_Map = {
        GetBestMapForUnit = function() return ISLE end,
        GetPlayerMapPosition = function() return vec(0.45, 0.36) end,
        GetWorldPosFromMapPos = function(_, v) return 2991, vec(v.x * 1000, v.y * 1000) end,
        GetMapInfo = function(m) return { name = "Map " .. m } end,
    }
    ns.MapSearch = {}
    ns.MapSearchSearch = { PreparePOI = function(p) p.nameLower = string.lower(p.name) return p end }
    ns.FOREVER_INSTANCES = {}
    env.EasyFind.db = {}
    H.loadModule("Database/Npcs_Forever.lua", env, ns)
    H.loadModule("MapSearch/Npcs.lua", env, ns)
    ns.Npcs.Load()
    return ns.MapSearch.AppendNpcRows
end

local function Named(rows, name)
    for _, row in ipairs(rows) do
        if row.name == name then return row end
    end
end

local function Places()
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/StaticLocations_Forever.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("[" .. ISLE .. "] = {", 1, true), "no Zephras Isle places")
    local block = src:sub(s, src:find("\n    },", s, true))
    local count = {}
    for category in block:gmatch('category = "([%w_]+)"') do count[category] = (count[category] or 0) + 1 end
    return count, block
end

local tests = {}

function tests.innkeeperTypedOnTheIsle_findsItsTwo()
    local append = Catalog()
    local rows = {}
    append(rows, {}, "innkeeper", ISLE)
    for _, name in ipairs(INNKEEPERS) do
        local row = Named(rows, name)
        H.assertTrue(row ~= nil, name .. " among " .. #rows .. " rows")
        H.assertEq(row.mapID, ISLE, name .. " stands on the isle")
    end
end

function tests.theIslesOtherServices_byTheirWord()
    local append = Catalog()
    for word, name in pairs({ bank = "Baelann Favorbreeze", auction = "Zelena Favorbreeze", stable = "Genn Fairweather" }) do
        local rows = {}
        append(rows, {}, word, ISLE)
        H.assertTrue(Named(rows, name) ~= nil, word .. " finds " .. name .. " among " .. #rows .. " rows")
    end
end

function tests.theIslesMap_placesItsServices()
    local count, block = Places()
    H.assertEq(count.innkeeper, 2, "both inns")
    for _, category in ipairs({ "bank", "auctionhouse", "stablemaster" }) do
        H.assertTrue((count[category] or 0) >= 1, "a " .. category)
    end
    -- Named for the service as every zone's are, so they fold with the other
    -- inns and the nearest stands for the row; at the innkeepers' own spots.
    for _, spot in ipairs({ "x = 0.4305, y = 0.4329", "x = 0.6218, y = 0.7268" }) do
        local row = 'POIName("Innkeeper"), category = "innkeeper", ' .. spot
        H.assertTrue(block:find(row, 1, true) ~= nil, "an Innkeeper place at " .. spot)
    end
end

local pass, fail, failures = H.runSuite("ForeverIsleServices", tests)
return { pass = pass, fail = fail, failures = failures }

-- An extension's rows in the map tab (Questie's quests, or GPS's own when
-- Questie is absent) are a bucket of their own (MapSearch/Main.lua
-- GetFilterBucket) with a check in the tab's cog menu after NPCs
-- (MapSearch/MapTab.lua PlacedDefs). Before, they bucketed as "other",
-- which no menu row reaches, so quests could not be hidden.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Chunk(path, from, to, ret, env)
    local src = Read(path)
    local s = assert(src:find(from, 1, true), from)
    local e = assert(src:find(to, s, true), to)
    return assert(load(src:sub(s, e - 1) .. "\nreturn " .. ret, "=" .. path, "t", setmetatable(env, { __index = _G })))()
end

local QUESTS = { key = "questie", category = "questie", label = "Quests", place = function() end }
local LIST = { key = "auctionator", category = "auctionator", label = "Shopping lists" }
local EXT = { Providers = { byKey = { questie = QUESTS, auctionator = LIST },
                            byCategory = { questie = QUESTS, auctionator = LIST } } }

local function Bucket()
    return Chunk("MapSearch/Main.lua", "local function GetFilterBucket", "ns.MapSearch.GetFilterBucket =",
        "GetFilterBucket", { ns = { Extensions = EXT }, CATEGORIES = {}, sfind = string.find })
end

local tests = {}

function tests.anExtensionsRowsAreTheirOwnBucket()
    local bucket = Bucket()
    H.assertEq(bucket({ category = "questie", placeOf = QUESTS.place }), "questie")
    H.assertEq(bucket({ category = "npc" }), "npcs", "the built-in buckets stay")
    H.assertEq(bucket({ category = "somethingelse" }), "other")
end

function tests.theCogListsEachPlacedExtensionAfterTheBuckets()
    local filters, changed = {}, {}
    local placed = Chunk("MapSearch/MapTab.lua", "local function PlacedDefs", "local function MapOptionsDefs",
        "PlacedDefs", { ns = { Extensions = EXT }, Filters = function() return filters end })
    local defs = {}
    placed(defs, function(key, v) changed[#changed + 1] = key .. "=" .. tostring(v) end)
    H.assertEq(#defs, 1, "only the provider that places its rows")
    H.assertEq(defs[1].label, "Quests")
    H.assertTrue(defs[1].get(), "shown until turned off")
    defs[1].set(false)
    H.assertEq(filters.questie, false)
    H.assertFalse(defs[1].get())
    H.assertEq(changed[1], "questie=false", "the tab searches again")
end

function tests.theCogMenuCallsIt()
    local src = Read("MapSearch/MapTab.lua")
    local s = assert(src:find("local function MapOptionsDefs", 1, true))
    H.assertTrue(src:find("PlacedDefs(defs, onChanged)", s, true) ~= nil)
end

local pass, fail, failures = H.runSuite("MapPlacedFilter", tests)
return { pass = pass, fail = fail, failures = failures }

-- "wailing caverns" in the Barrens drew two rows (Forever, 2026-11-18):
-- the pick remembered from the Kalimdor row (map 1414) and the Barrens
-- row (map 1413). The bar drops a natural row only when its name and map
-- match the pick, so the same place on another map stayed. The search's
-- own row of the place now stands for the pick.
local H = require("Harness")

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Query.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local MapRow = {}", 1, true), "the row key")
    local e = assert(src:find("-- end of the map row identity", s, true), "its end")
    local chunk = "local slower = string.lower\n" .. src:sub(s, e - 1) .. "\nreturn MapRow.Key, MapRow.SamePlace"
    return assert(load(chunk, "=Query.lua map row identity", "t", setmetatable({}, { __index = _G })))()
end

local function Rows(...)
    local out = {}
    for i, d in ipairs({ ... }) do out[i] = { data = d } end
    return out
end

local tests = {}

function tests.aPickFromAnotherMap_isThisSearchsRow()
    local MapRowKey, SamePlaceRow = Load()
    local pick = { name = "Wailing Caverns", nameLower = "wailing caverns", category = "dungeon", mapID = 1414 }
    local barrens = { name = "Wailing Caverns", nameLower = "wailing caverns", category = "dungeon", mapID = 1413 }
    H.assertTrue(MapRowKey(pick) ~= MapRowKey(barrens), "the old key missed it")
    local loot = { name = "Wailing Caverns", nameLower = "wailing caverns", category = "loot", mapID = 1413 }
    H.assertEq(SamePlaceRow(pick, Rows(loot, barrens)), barrens, "the place, not another kind of row")
end

function tests.aCreature_isOneOfAKind()
    local _, SamePlaceRow = Load()
    local pick = { nameLower = "thrall", category = "npc", npcID = 4949, mapID = 85 }
    local other = { nameLower = "thrall", category = "npc", npcID = 17876, mapID = 85 }
    H.assertNil(SamePlaceRow(pick, Rows(other)), "another Thrall is another creature")
end

function tests.noRowOfIt_keepsThePick()
    local _, SamePlaceRow = Load()
    H.assertNil(SamePlaceRow({ nameLower = "wailing caverns", category = "dungeon" }, Rows()))
    H.assertNil(SamePlaceRow({ nameLower = "wailing caverns", category = "dungeon" }, nil))
end

local pass, fail, failures = H.runSuite("LearnedMapRow", tests)
return { pass = pass, fail = fail, failures = failures }

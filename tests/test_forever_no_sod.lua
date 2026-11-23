-- WoW Forever's client tables carry Season of Discovery's items and
-- recipes, which its server never serves: their rows stuck on "Retrieving
-- item information" and its recipes doubled the classic ones (2026-11-23).
-- The Forever builders leave them out by one rule (dev/tools
-- forever_sod.py); the items Forever itself reuses stay.
local H = require("Harness")

local function read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local catalog = read("Apps/Items/Data_Forever.lua")
local professions = read("Database/ProfessionData.lua")
local sources = read("Apps/Sources/Data_Forever.lua")

local function InCatalog(id) return catalog:find("\t" .. id .. "\t", 1, true) ~= nil end

local function ForeverRecipes()
    local at = professions:find("WoW Forever's own professions", 1, true)
    local block = professions:sub(at, professions:find("\n    return\nend", at, true))
    local set = {}
    for list in block:gmatch('recipesByPage = {%s*%[%d+%] = "([%d,]*)"') do
        for n in list:gmatch("%d+") do set[tonumber(n)] = true end
    end
    return set
end

local tests = {}

function tests.theCatalog_hasNoSeasonOfDiscoveryCopies()
    H.assertFalse(InCatalog(228267), "Season of Discovery's Gutgore Ripper")
    H.assertFalse(InCatalog(229372), "and its other one")
    H.assertTrue(InCatalog(17071), "the classic Gutgore Ripper")
    H.assertTrue(InCatalog(288907), "Forever's own")
end

function tests.itemsForeverReuses_stay()
    H.assertTrue(InCatalog(220606), "Idol of the Dream, made by Forever's own enchanting recipe")
end

function tests.recipes_haveNoSeasonOfDiscoveryDoubles()
    local recipes = ForeverRecipes()
    H.assertTrue(recipes[28243], "the classic Icebane Gauntlets")
    H.assertNil(recipes[1223789], "Season of Discovery's Icebane Gauntlets")
    H.assertNil(recipes[1213638], "Smelt Obsidian-Infused Thorium Bar")
    H.assertTrue(recipes[1249128], "Forever's own Idol of the Dream")
    H.assertTrue(recipes[1294289], "Forever's own Centaur Hoofwarmers")
end

function tests.aClassicRecipe_makesTheClassicItem()
    H.assertTrue(sources:find('\n    %[14810%] = "333,%d+,11290,') ~= nil,
        "Greater Mystic Wand makes the classic wand, not Season of Discovery's copy")
    H.assertNil(sources:find('\n    [1223789] = "', 1, true), "no source names a Season of Discovery recipe")
end

local pass, fail, failures = H.runSuite("ForeverNoSeasonOfDiscovery", tests)
return { pass = pass, fail = fail, failures = failures }

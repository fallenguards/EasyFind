-- Shipped loot (the clients with no journal) in the loot filter pass: the
-- class and difficulty chosen in the filter menu apply to it. A TBC mage
-- searching Illidan saw his leather and plate, and TBC's heroic loot was
-- one list with its normal (2026-10-29).
local H = require("Harness")

local function slice(path, from, to)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find(from, 1, true), from .. " not found")
    local e = assert(src:find(to, s, true), to .. " not found")
    return src:sub(s, e - 1)
end

local MAGE, WARRIOR = 8, 1
local CLOTH, LEATHER, PLATE = 1, 2, 3
local USES = { [CLOTH] = { [MAGE] = true }, [LEATHER] = {}, [PLATE] = { [WARRIOR] = true } }

-- The pass's own check, cut from Database/Main.lua, for a mage.
local function Wanted(lootFilter, difficulty, offered)
    local env = setmetatable({
        EasyFind = { db = { lootDifficulty = difficulty } },
        ns = { Caps = { lootDifficulties = offered } },
        UnitClass = function() return "Mage", "MAGE", MAGE end,
    }, { __index = _G })
    env.Database = {
        LootForClass = function(itemID, classID) return USES[itemID][classID] == true end,
    }
    assert(load(slice("Database/Main.lua", "-- The chosen loot difficulty where this client has it",
        "\nfunction Database:GetEJDifficultyID"), "=Main.lua LootDifficulty", "t", env))()
    local src = "local lootFilter, wantAll, wantSpec = ...\n"
        .. slice("Database/Main.lua", "    local wantDiff = Database.LootDifficulty()",
            "    -- Corpus rows filter on transient scratch decodes")
        .. "\nreturn wanted"
    return assert(load(src, "=Main.lua wanted", "t", env))(lootFilter, lootFilter == "all", {})
end

local ANY = { "*" }
local TBC = { "normal", "heroic" }

local tests = {}

function tests.theCharactersClassByDefault()
    local wanted = Wanted(nil, "normal", TBC)
    H.assertTrue(wanted(ANY, ANY, CLOTH))
    H.assertFalse(wanted(ANY, ANY, LEATHER), "no leather for a mage")
    H.assertFalse(wanted(ANY, ANY, PLATE))
end

function tests.aChosenClassOrAll()
    local wanted = Wanted({ classID = WARRIOR }, "normal", TBC)
    H.assertTrue(wanted(ANY, ANY, PLATE))
    H.assertFalse(wanted(ANY, ANY, CLOTH))
    wanted = Wanted("all", "normal", TBC)
    H.assertTrue(wanted(ANY, ANY, LEATHER), "every class")
end

function tests.aHeroicModesLootApart()
    local wanted = Wanted(nil, "normal", TBC)
    H.assertTrue(wanted(ANY, { "normal" }, CLOTH))
    H.assertFalse(wanted(ANY, { "heroic" }, CLOTH))
    H.assertTrue(wanted(ANY, ANY, CLOTH), "a boss with one mode shows on either")
    wanted = Wanted(nil, "heroic", TBC)
    H.assertTrue(wanted(ANY, { "heroic" }, CLOTH))
    H.assertFalse(wanted(ANY, { "normal" }, CLOTH))
end

-- A difficulty the client lacks (Raid Finder saved on retail) reads as Normal.
function tests.aMissingDifficultyReadsAsNormal()
    local wanted = Wanted(nil, "lfr", TBC)
    H.assertTrue(wanted(ANY, { "normal" }, CLOTH))
    H.assertFalse(wanted(ANY, { "lfr" }, CLOTH))
end

local function LoadLoot(file, caps)
    local ns = { Caps = caps }
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/" .. file, "rb"))
    local src = f:read("*a")
    f:close()
    assert(load(src, "=" .. file, "t", setmetatable({}, { __index = _G })))("EasyFind", ns)
    local byName = {}
    for _, boss in ipairs(ns.STATIC_LOOT) do byName[boss.boss] = boss end
    return byName, ns.STATIC_LOOT
end

function tests.tbcHeroicDungeonsListTheirOwnLoot()
    local byName = LoadLoot("Loot_TBC.lua", { tbc = true })
    local keli = assert(byName["Keli'dan the Breaker"])
    H.assertTrue(keli.heroic ~= nil and #keli.heroic > 0, "heroic Blood Furnace")
    H.assertNil(byName["Illidan Stormrage"].heroic, "a raid has one mode")
end

function tests.eraHasNoHeroicLoot()
    local _, all = LoadLoot("Loot_Era.lua", { era = true })
    for _, boss in ipairs(all) do H.assertNil(boss.heroic, boss.boss) end
end

local pass, fail, failures = H.runSuite("ShippedLoot", tests)
return { pass = pass, fail = fail, failures = failures }

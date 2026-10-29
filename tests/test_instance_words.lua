-- Database/InstanceWords.lua: the shorthands players name instances by
-- ("sm", "smgy", "stocks"), the words that load loot and bosses, and the
-- armor type and class words scored against a loot row's own item
-- ("sm cloth", "sm rogue"; Era, 2026-10-28).
local H = require("Harness")

local function Load(caps, classMasks)
    local ns = {
        Database = {}, SearchText = { Normalize = string.lower }, Caps = caps or { era = true },
        STATIC_LOOT_CLASSES = classMasks,
        FOREVER_INSTANCES = { { id = 34, n = "Stormwind Stockade" } },
        STATIC_LOOT = { { inst = 189, enc = 1, boss = "Houndmaster Loksey", items = {} } },
    }
    local items = {}   -- itemID -> { classID, subclassID }
    local env = setmetatable({
        C_Item = { GetItemInfoInstant = function(id)
            local it = items[id] or {}
            return id, nil, nil, nil, nil, it[1], it[2]
        end },
        LOCALIZED_CLASS_NAMES_MALE = { ROGUE = "Rogue", PRIEST = "Priest", WARRIOR = "Warrior" },
        LOCALIZED_CLASS_NAMES_FEMALE = { ROGUE = "Schurkin" },
        bit = { band = function(a, b)
            local r, p = 0, 1
            while a > 0 and b > 0 do
                if a % 2 == 1 and b % 2 == 1 then r = r + p end
                a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
            end
            return r
        end },
    }, { __index = _G })
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/InstanceWords.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local chunk = assert(load(src, "=InstanceWords.lua", "t", env))
    chunk("EasyFind", ns)
    return ns.Database, items
end

local tests = {}

function tests.abbrs_byTheClientsOwnName_prefixAndTheDropped()
    local D = Load()
    H.assertEq(D.InstanceAbbrs("scarlet monastery")[1], "sm")
    H.assertEq(D.InstanceAbbrs("coilfang: the slave pens")[1], "sp")
    H.assertEq(D.InstanceAbbrs("the stockade")[1], "stocks")
    H.assertEq(D.InstanceAbbrs("hellfire citadel: ramparts")[1], "ramps")
    H.assertEq(D.InstanceAbbrs("nowhere"), nil)
end

function tests.queryWords_shorthandsWingsNamesAndBosses()
    local D = Load()
    H.assertTrue(D:QueryNamesAnInstance("sm cloth"))
    H.assertTrue(D:QueryNamesAnInstance("smgy"))
    H.assertTrue(D:QueryNamesAnInstance("stockades"))
    H.assertTrue(D:QueryNamesAnInstance("loksey"))
    H.assertTrue(not D:QueryNamesAnInstance("boots of the"))
    H.assertTrue(D:IsInstanceSearchWord("stockade"))
    D.AddInstanceSearchWords("Karazhan", "Moroes")
    H.assertTrue(D:IsInstanceSearchWord("moroes"))
end

function tests.gearWords_armorTypeAndClass_onTheOldRules()
    local D, items = Load({ era = true })
    items[1], items[2], items[3], items[4] = { 4, 1 }, { 4, 2 }, { 2, 1 }, { 4, 0 }
    H.assertEq(D.LootWordScore({ itemID = 1 }, "cloth"), 140)
    H.assertEq(D.LootWordScore({ itemID = 2 }, "cloth"), 0)
    H.assertEq(D.LootWordScore({ itemID = 2 }, "rogue"), 110)
    H.assertEq(D.LootWordScore({ itemID = 2 }, "schurkin"), 110)
    H.assertEq(D.LootWordScore({ itemID = 3 }, "rogue"), 0, "no axes for rogues before Wrath")
    H.assertEq(D.LootWordScore({ itemID = 3 }, "warrior"), 110)
    H.assertEq(D.LootWordScore({ itemID = 1 }, "priest"), 110)
    H.assertEq(D.LootWordScore({ itemID = 4 }, "priest"), 110, "a ring is everyone's")
    H.assertEq(D.LootWordScore({ itemID = 1 }, "boots"), nil, "not a gear word")
end

function tests.gearWords_theItemsOwnClassRestrictionWins()
    local D, items = Load({ era = true }, { [7] = 2 ^ 3 + 2 ^ 1 })   -- rogue and paladin
    items[7] = { 15, 0 }
    H.assertEq(D.LootWordScore({ itemID = 7 }, "rogue"), 110)
    H.assertEq(D.LootWordScore({ itemID = 7 }, "priest"), 0)
    H.assertEq(D.LootWordScore({ itemID = 7, _cachedSpecs = { "5-256" } }, "priest"), 0, "the mask first")
end

function tests.gearWords_theJournalsClassList()
    local D, items = Load({})
    items[9] = { 4, 2 }
    H.assertEq(D.LootWordScore({ itemID = 9, _cachedSpecs = { "4-259", "4-260" } }, "rogue"), 110)
    H.assertEq(D.LootWordScore({ itemID = 9, _cachedSpecs = { "4-259" } }, "priest"), 0)
    H.assertEq(D.LootWordScore({ itemID = 9, _cachedSpecs = { "*" } }, "rogue"), 110, "no list: the rules")
end

local pass, fail, failures = H.runSuite("InstanceWords", tests)
return { pass = pass, fail = fail, failures = failures }

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
    local items = {}   -- itemID -> { classID, subclassID, equipLoc }
    local env = setmetatable({
        C_Item = { GetItemInfoInstant = function(id)
            local it = items[id] or {}
            return id, nil, nil, it[3], nil, it[1], it[2]
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

-- A cloak is cloth everyone wears: "sm rogue" kept no cloak (2026-10-29).
function tests.gearWords_aCloakIsEveryones()
    local D, items = Load({ era = true })
    items[11] = { 4, 1, "INVTYPE_CLOAK" }
    H.assertEq(D.LootWordScore({ itemID = 11 }, "rogue"), 110)
    H.assertEq(D.LootWordScore({ itemID = 11 }, "cloth"), 140)
end

-- Shipped loot by the filter menu's class: a TBC mage searching Illidan
-- saw his leather and plate (2026-10-29).
function tests.lootForClass_wearsAndWields()
    local WARRIOR, PALADIN, MAGE = 1, 2, 8
    local D, items = Load({ tbc = true }, { [20] = 1160 })
    items[12] = { 4, 1 }                       -- cloth helm
    items[13] = { 4, 2 }                       -- leather helm
    items[14] = { 4, 4 }                       -- plate helm
    items[15] = { 4, 1, "INVTYPE_CLOAK" }
    items[16] = { 4, 7 }                       -- libram
    items[17] = { 4, 0, "INVTYPE_FINGER" }
    items[18] = { 2, 19 }                      -- wand
    items[19] = { 2, 1 }                       -- two-handed axe
    items[20] = { 15, 0 }                      -- Vanquisher token: rogue, mage, druid
    items[21] = { 10, 0 }                      -- a badge
    H.assertTrue(D.LootForClass(12, MAGE))
    H.assertFalse(D.LootForClass(13, MAGE), "no leather for a mage")
    H.assertFalse(D.LootForClass(14, MAGE))
    H.assertTrue(D.LootForClass(14, WARRIOR))
    H.assertTrue(D.LootForClass(15, WARRIOR), "a cloak is everyone's")
    H.assertFalse(D.LootForClass(16, MAGE))
    H.assertTrue(D.LootForClass(16, PALADIN))
    H.assertTrue(D.LootForClass(17, WARRIOR))
    H.assertTrue(D.LootForClass(18, MAGE))
    H.assertFalse(D.LootForClass(18, WARRIOR))
    H.assertFalse(D.LootForClass(19, MAGE))
    H.assertTrue(D.LootForClass(20, MAGE), "the token's own classes")
    H.assertFalse(D.LootForClass(20, WARRIOR))
    H.assertTrue(D.LootForClass(21, WARRIOR))
end

local pass, fail, failures = H.runSuite("InstanceWords", tests)
return { pass = pass, fail = fail, failures = failures }

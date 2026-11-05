-- @upgrades (2026-11-05): per gear slot, the dungeon and raid drops that
-- beat what a character wears and that it can equip at its level, from
-- the shipped drop facts (Database/LootGear_*.lua), never the item cache.
local H = require("Harness")

local function Source(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

-- dev/tools/loot_gear.py's packing.
local INV = { head = 1, neck = 2, chest = 5, finger = 11, weapon = 13, shield = 14, cloak = 16, twoHand = 17,
              offHand = 22, holdable = 23, wand = 26 }
local function Pack(ilvl, req, kinds, inv, cls, sub, quality)
    return ilvl + 256 * req + 32768 * kinds + 4194304 * inv + 134217728 * sub + 4294967296 * cls
        + 34359738368 * (quality or 3)
end
local STR, INT, SPI = 1, 4, 8

local function World(opts)
    local env = H.newEnv()
    local ns = H.newNs(env)
    ns.Caps = { era = true, Has = function() return true end }
    ns.SearchText = ns.SearchText or {}
    ns.SearchText.Normalize = ns.SearchText.Normalize or string.lower
    H.loadModule("Database/InstanceWords.lua", env, ns)
    local items = opts.items
    ns.STATIC_LOOT_GEAR, ns.STATIC_LOOT_NAMES, ns.STATIC_LOOT_CLASSES = {}, {}, opts.classes or {}
    local byInst = {}
    for id, it in pairs(items) do
        ns.STATIC_LOOT_GEAR[id] = Pack(it.ilvl, it.req, it.kinds or 0, it.inv, it.cls or 4, it.sub or 0, it.q)
        ns.STATIC_LOOT_NAMES[id] = it.name
        local inst = it.inst or 36
        if not it.heroicOnly then
            byInst[inst] = byInst[inst] or {}
            table.insert(byInst[inst], id)
        end
    end
    ns.STATIC_LOOT = {}
    for inst, list in pairs(byInst) do
        table.sort(list)
        ns.STATIC_LOOT[#ns.STATIC_LOOT + 1] = { inst = inst, enc = inst * 10, boss = "Boss " .. inst, items = list }
    end
    if opts.heroic then ns.STATIC_LOOT[#ns.STATIC_LOOT + 1] = { inst = 36, enc = 999, boss = "Twin", items = {},
                                                              heroic = opts.heroic } end
    ns.FOREVER_INSTANCES = { { id = 36, n = "Deadmines", raid = false }, { id = 409, n = "Molten Core", raid = true } }
    env.GetRealZoneText = function() return nil end
    local instant = {}
    env.C_Item = { GetItemNameByID = function() return nil end, GetItemIconByID = function(id) return id end,
                   GetItemInfoInstant = function(x) local r = instant[x] if r then return table.unpack(r) end end }
    env.GetItemInfoInstant = env.C_Item.GetItemInfoInstant
    env.ITEM_QUALITY_COLORS = { [3] = { hex = "|cff0070dd" }, [4] = { hex = "|cffa335ee" } }
    env._G = env
    env.HEADSLOT, env.CHESTSLOT, env.BACKSLOT, env.MAINHANDSLOT = "Head", "Chest", "Back", "Main Hand"
    env.SECONDARYHANDSLOT, env.INVTYPE_FINGER = "Off Hand", "Finger"
    local levels = {}
    ns.CharacterData = { Fold = string.lower, ItemLevel = function(link) return levels[link] end }
    ns.L.ITEM_GRID_NO_GEAR = "Nothing recorded yet"
    ns.L.UPGRADES_EMPTY = "empty"
    ns.L.UPGRADES_NONE_FMT = "None at level %d."
    H.loadModule("Search/Upgrades.lua", env, ns)
    -- Worn: { [slot] = { itemID, level, inv } } as links the fakes read back.
    local worn = {}
    for slot, w in pairs(opts.worn or {}) do
        local link = "|Hitem:" .. w.id .. ":|h[" .. (w.name or ("Worn " .. w.id)) .. "]|h"
        worn[slot] = link
        levels[link] = w.level
        if w.inv then
            local token = ({ [13] = "INVTYPE_WEAPON", [17] = "INVTYPE_2HWEAPON", [14] = "INVTYPE_SHIELD",
                             [22] = "INVTYPE_WEAPONOFFHAND" })[w.inv]
            instant[link] = { w.id, nil, nil, token, nil, w.cls or 2, w.sub or 0 }
        end
    end
    local entry = { name = "Thrall", class = opts.class or "WARRIOR", level = opts.level or 60, gear = worn, gearLevel = {} }
    return ns, entry, env
end

local function Names(rows)
    local out = {}
    for _, r in ipairs(rows) do
        if not r.upgradeHeader then out[#out + 1] = r.name end
    end
    return table.concat(out, ",")
end

local tests = {}

function tests.armor_theTypeTheClassWearsByThen()
    local items = {
        [1] = { name = "Mail Vest", ilvl = 30, req = 30, inv = INV.chest, sub = 3 },
        [2] = { name = "Plate Vest", ilvl = 45, req = 40, inv = INV.chest, sub = 4 },
        [3] = { name = "Leather Vest", ilvl = 31, req = 30, inv = INV.chest, sub = 2 },
        [4] = { name = "Plate Helm", ilvl = 32, req = 30, inv = INV.head, sub = 4 },
    }
    local ns, entry = World({ items = items, level = 35 })
    H.assertEq(Names(ns.Upgrades.Rows(entry)), "Mail Vest", "a warrior before 40: mail, nothing above his level")
    ns, entry = World({ items = items, level = 45 })
    H.assertEq(Names(ns.Upgrades.Rows(entry)), "Plate Helm,Plate Vest", "from 40: plate only")
end

function tests.stats_onlyThoseThatSuitTheClass()
    local items = {
        [1] = { name = "Caster Cloak", ilvl = 30, req = 25, inv = INV.cloak, sub = 1, kinds = INT + SPI },
        [2] = { name = "Stamina Cloak", ilvl = 29, req = 25, inv = INV.cloak, sub = 1 },
        [3] = { name = "Strength Cloak", ilvl = 28, req = 25, inv = INV.cloak, sub = 1, kinds = STR },
    }
    local ns, entry = World({ items = items, level = 30 })
    H.assertEq(Names(ns.Upgrades.Rows(entry)), "Stamina Cloak,Strength Cloak", "a warrior: no intellect and spirit")
    ns, entry = World({ items = items, level = 30, class = "MAGE" })
    H.assertEq(Names(ns.Upgrades.Rows(entry)), "Caster Cloak,Stamina Cloak", "a mage: no strength")
end

function tests.aDropMustBeatWhatIsWorn_aPairItsWeaker()
    local items = {
        [1] = { name = "Old Helm", ilvl = 20, req = 15, inv = INV.head, sub = 3 },
        [2] = { name = "Ring A", ilvl = 26, req = 20, inv = INV.finger },
    }
    local ns, entry = World({ items = items, level = 30, worn = {
        [1] = { id = 50, level = 25 }, [11] = { id = 51, level = 30 }, [12] = { id = 52, level = 24 } } })
    local rows = ns.Upgrades.Rows(entry)
    H.assertEq(Names(rows), "Ring A", "the helm is worse than the worn one; the ring beats the weaker ring")
    H.assertEq(rows[2].upgradeGain, 2, "measured against the weaker")
    H.assertEq(rows[1].name, "Finger: Worn 51 (30), Worn 52 (24)", "the header names both")
end

function tests.wornItems_andTheirTwins_areNotListed()
    local items = { [50] = { name = "Same Helm", ilvl = 40, req = 15, inv = INV.head, sub = 3 } }
    local ns, entry = World({ items = items, level = 30, worn = { [1] = { id = 50, level = 10 } } })
    H.assertEq(ns.Upgrades.Rows(entry)[1].name, "None at level 30.", "the item already worn")
end

function tests.weapons_twoHandForTwoHand_noOffHandBehindIt()
    local items = {
        [1] = { name = "Big Axe", ilvl = 35, req = 30, inv = INV.twoHand, cls = 2, sub = 1 },
        [2] = { name = "Small Axe", ilvl = 36, req = 30, inv = INV.weapon, cls = 2, sub = 0 },
        [3] = { name = "Buckler", ilvl = 37, req = 30, inv = INV.shield, sub = 6 },
    }
    local ns, entry = World({ items = items, level = 30, worn = { [16] = { id = 60, level = 20, inv = 17, sub = 1 } } })
    H.assertEq(Names(ns.Upgrades.Rows(entry)), "Big Axe", "a two-hander worn: two-handers only, no off hand")
end

function tests.offHandWeapons_onlyForDualWielders()
    local items = { [1] = { name = "Dirk", ilvl = 30, req = 25, inv = INV.offHand, cls = 2, sub = 15 } }
    local ns, entry = World({ items = items, level = 30, class = "ROGUE" })
    H.assertEq(Names(ns.Upgrades.Rows(entry)), "Dirk")
    ns, entry = World({ items = items, level = 30, class = "PRIEST" })
    H.assertEq(ns.Upgrades.Rows(entry)[1].name, "None at level 30.", "a priest wields no off-hand dagger")
    items[1].req = 10
    ns, entry = World({ items = items, level = 15, class = "WARRIOR" })
    H.assertEq(ns.Upgrades.Rows(entry)[1].name, "None at level 15.", "a warrior before 20")
end

function tests.classRestrictedDrops_onlyForTheirClasses()
    local items = { [1] = { name = "Mage Helm", ilvl = 30, req = 25, inv = INV.head, sub = 1, kinds = INT } }
    local ns, entry = World({ items = items, level = 30, class = "MAGE", classes = { [1] = 2 ^ (5 - 1) } })
    H.assertEq(ns.Upgrades.Rows(entry)[1].name, "None at level 30.", "a priest-only helm")
end

function tests.rows_areLootRows_dungeonsFirst_capped()
    local items = {}
    for i = 1, 6 do items[i] = { name = "D" .. i, ilvl = 40 + i, req = 30, inv = INV.head, sub = 4 } end
    for i = 7, 10 do items[i] = { name = "R" .. i, ilvl = 70 + i, req = 60, inv = INV.head, sub = 4, inst = 409, q = 4 } end
    local ns, entry = World({ items = items, level = 60 })
    local rows = ns.Upgrades.Rows(entry)
    H.assertTrue(rows[1].upgradeHeader, "a header first")
    H.assertEq(rows[1].name, "Head: empty")
    H.assertEq(rows[2].name, "D6", "dungeons first, the best first")
    local raidRow = rows[8]
    H.assertEq(raidRow.name, "R7", "then raids, the next step up first")
    H.assertEq(raidRow.category, "Loot")
    H.assertEq(raidRow.lootSourceType, "Raid")
    H.assertEq(raidRow.lootInstanceName, "Molten Core")
    H.assertEq(raidRow.instanceID, 409, "a click leads to its entrance")
    H.assertEq(raidRow.nameHex, "|cffa335ee", "in its quality's color")
    local shown = ns.Upgrades.Visible(rows, {}, function() return false end)
    H.assertEq(Names(shown), "D6,D5,D4,D3,R7,R8", "four dungeon drops and two raid drops a slot")
    local function Has(folded, words)
        for _, w in ipairs(words) do if not folded:find(w, 1, true) then return false end end
        return true
    end
    shown = ns.Upgrades.Visible(rows, { "molten" }, Has)
    H.assertEq(Names(shown), "R7,R8,R9,R10", "a word narrows to that raid, past the cap")
    H.assertTrue(shown[1].upgradeHeader, "its slot's header kept")
end

function tests.heroicDrops_sayHeroic_aDropListedOnce()
    local items = { [1] = { name = "Helm", ilvl = 30, req = 25, inv = INV.head, sub = 4 },
                    [2] = { name = "Heroic Ring", ilvl = 31, req = 25, inv = INV.finger, heroicOnly = true } }
    local ns, entry = World({ items = items, level = 60, heroic = { 1, 2 } })
    local names = {}
    for _, r in ipairs(ns.Upgrades.Rows(entry)) do if r.lootSourceName then names[#names + 1] = r.lootSourceName end end
    H.assertEq(table.concat(names, ","), "Boss 36,Twin (Heroic)", "the helm once, from its first boss")
end

-- A world boss (no entrance), an in-season hat, a row with no required level.
function tests.dropsThatAreNoRealUpgrade_leftOut()
    local items = {
        [1] = { name = "World Helm", ilvl = 70, req = 60, inv = INV.head, sub = 4, inst = 2791 },
        [2] = { name = "Winter Hat", ilvl = 1, req = 0, inv = INV.head, sub = 1 },
        [3] = { name = "Odd Helm", ilvl = 83, req = 0, inv = INV.head, sub = 3 },
        [4] = { name = "Low Helm", ilvl = 12, req = 0, inv = INV.head, sub = 3 },
    }
    local ns, entry = World({ items = items, level = 25 })
    H.assertEq(Names(ns.Upgrades.Rows(entry)), "Low Helm", "a row with no level reads as 5 below its item level")
end

function tests.anAltWithNoGearOnRecord_saysSo()
    local ns, entry = World({ items = {}, level = 30 })
    entry.gear = nil
    H.assertEq(ns.Upgrades.Rows(entry)[1].name, "Nothing recorded yet")
end

-- Each client's shipped facts are for its own shipped drops.
function tests.eachGearTable_coversItsClientsDrops()
    local function Ids(src)
        local ids = {}
        for block in src:gmatch("items = {([^}]*)}") do
            for id in block:gmatch("%d+") do ids[tonumber(id)] = true end
        end
        for block in src:gmatch("heroic = {([^}]*)}") do
            for id in block:gmatch("%d+") do ids[tonumber(id)] = true end
        end
        return ids
    end
    for _, c in ipairs({ { "Era", "era" }, { "TBC", "tbc" }, { "Forever", "forever" } }) do
        local drops = Ids(Source("Database/Loot_" .. c[1] .. ".lua"):match("^(.-)ns%.STATIC_LOOT_NAMES"))
        local gear = Source("Database/LootGear_" .. c[1] .. ".lua")
        H.assertTrue(gear:find("ns.Caps." .. c[2] .. ") then return end", 1, true) ~= nil, c[1] .. ": its client only")
        local n = 0
        for id, v in gear:gmatch("%[(%d+)%] = (%d+)") do
            n = n + 1
            id, v = tonumber(id), tonumber(v)
            H.assertTrue(drops[id], c[1] .. ": " .. id .. " is a shipped drop")
            local ilvl, inv = v % 256, math.floor(v / 4194304) % 32
            H.assertTrue(ilvl > 0 and inv > 0, c[1] .. ": " .. id .. " has a level and a slot")
        end
        H.assertTrue(n > 200, c[1] .. ": " .. n .. " drops")
    end
end

function tests.eachGearTable_loadsOnItsClientOnly()
    for _, c in ipairs({ { "Era", "era" }, { "TBC", "tbc" }, { "Forever", "forever" } }) do
        local env = H.newEnv()
        local ns = H.newNs(env)
        ns.Caps = { [c[2]] = true }
        H.loadModule("Database/LootGear_" .. c[1] .. ".lua", env, ns)
        H.assertNotNil(ns.STATIC_LOOT_GEAR, c[1])
        local other = H.newNs(H.newEnv())
        other.Caps = { retail = true }
        H.loadModule("Database/LootGear_" .. c[1] .. ".lua", H.newEnv(), other)
        H.assertNil(other.STATIC_LOOT_GEAR, c[1] .. ": nothing elsewhere")
    end
end

function tests.toc_loadsEachTableOnItsClient_andThePage()
    local toc = Source("EasyFind.toc")
    H.assertTrue(toc:find("Database/LootGear_Era.lua [AllowLoadGameType vanilla]", 1, true) ~= nil)
    H.assertTrue(toc:find("Database/LootGear_TBC.lua [AllowLoadGameType tbc]", 1, true) ~= nil)
    H.assertTrue(toc:find("Database/LootGear_Forever.lua [AllowLoadGameType camelot]", 1, true) ~= nil)
    H.assertTrue(toc:find("Search/Upgrades.lua", 1, true) ~= nil)
end

-- Retail and MoP Classic: the journal's dungeons scale to the player.
function tests.onlyTheClientsWithShippedDrops()
    local caps = Source("Shared/Caps.lua")
    H.assertTrue(caps:find("Caps.upgrades = (Caps.forever or Caps.era or Caps.tbc) and not Caps.journal", 1, true) ~= nil)
    H.assertTrue(caps:find('upgrades = "upgrades"', 1, true) ~= nil, "the filter is pruned elsewhere")
end

local pass, fail, failures = H.runSuite("Upgrades", tests)
return { pass = pass, fail = fail, failures = failures }

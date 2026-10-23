-- Tests for the classic clients' spellbook in search (Database/Main.lua
-- PopulateDynamicAbilities): Era and Anniversary have no C_SpellBook skill
-- lines; their abilities are read tab by tab, each spell once at its
-- highest rank, unlearned slots left out.
local H = require("Harness")

-- The collector alone, sliced from the file, with what it calls.
local function loadCollector(spellbook, noTabs)
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/Main.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function Database:PopulateDynamicAbilities()", 1, true), "collector not found")
    local e = assert(src:find("\n-- Dungeon/raid initialisms", s, true), "end of the collector not found")
    local data = {}
    local Database = {}
    local tabs, slots = spellbook.tabs, spellbook.slots
    local env = setmetatable({
        Database = Database, uiSearchData = data,
        RemoveEntriesByCategory = function(cat)
            for i = #data, 1, -1 do if data[i].category == cat then table.remove(data, i) end end
        end,
        slower = string.lower,
        Utils = { SliceCheckpoint = function() end },
        ns = {},
        C_SpellBook = {},
        GetNumSpellTabs = not noTabs and function() return #tabs end or nil,
        GetSpellTabInfo = function(i) local t = tabs[i] return t.name, 1, t.offset, t.num end,
        GetSpellBookItemInfo = function(slot, book)
            local sl = book == "spell" and slots[slot]
            if sl then return sl.type or "SPELL", sl.id end
        end,
        GetSpellBookItemName = function(slot, book)
            local sl = book == "spell" and slots[slot]
            if sl then return sl.name, sl.rank, sl.id end
        end,
        GetSpellBookItemTexture = function(slot) return 1000 + slot end,
        IsPassiveSpell = function(slot) return slots[slot] and slots[slot].passive or false end,
    }, { __index = _G })
    env._G = env
    assert(load(src:sub(s, e - 1), "=Main.lua PopulateDynamicAbilities", "t", env))()
    return Database, data
end

local BOOK = {
    tabs = { { name = "General", offset = 0, num = 2 }, { name = "Fire", offset = 2, num = 4 } },
    slots = {
        { name = "Attack", id = 6603 },
        { name = "Defense", id = 204, passive = true },
        { name = "Fireball", rank = "Rank 1", id = 133 },
        { name = "Fireball", rank = "Rank 2", id = 143 },
        { name = "Fire Blast", rank = "Rank 1", id = 2136 },
        { name = "Pyroblast", type = "FUTURESPELL", id = 11366 },
    },
}

local tests = {}

function tests.abilitiesComeFromTheTabs()
    local Database, data = loadCollector(BOOK)
    H.assertTrue(Database:PopulateDynamicAbilities(), "read without the skill line API")
    local byName, n = {}, 0
    for _, entry in ipairs(data) do
        if entry.category == "Ability" then
            byName[entry.spellName] = entry
            n = n + 1
        end
    end
    H.assertEq(n, 4, "each spell once, the unlearned one left out")
    H.assertEq(byName.Attack.treeName, "General")
    H.assertEq(byName.Fireball.spellID, 143, "the highest rank")
    H.assertEq(byName.Fireball.name, "Fireball (Rank 2)")
    H.assertEq(byName.Fireball.spellBookIndex, 4)
    H.assertEq(byName.Fireball.spellBookBank, "spell")
    H.assertEq(byName.Fireball.icon, 1004)
    H.assertTrue(byName.Defense.isPassive and byName.Defense.isSpellbookOnly, "a passive opens the spellbook")
    H.assertNil(byName.Pyroblast, "not learned yet")
end

function tests.noSpellbookAPI_readsNothing()
    local Database, data = loadCollector(BOOK, true)
    H.assertFalse(Database:PopulateDynamicAbilities())
    H.assertEq(#data, 0)
end

local pass, fail, failures = H.runSuite("ClassicSpellbook", tests)
return { pass = pass, fail = fail, failures = failures }

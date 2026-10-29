-- Profession actions in search (Database/Main.lua PopulateDynamicAbilities):
-- Fishing, Survey, Cooking Fire live in the professions book, outside the
-- spellbook's skill lines. Each profession's first castable slot opens its
-- window and stays the profession row; the others become ability rows that
-- cast by spell ID.
local H = require("Harness")

local SPELL, FLYOUT = 1, 4

local function loadCollector(book)
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/Main.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("Corpora.ABILITY_MT", 1, true), "collector not found")
    local e = assert(src:find("\n-- Dungeon/raid initialisms", s, true), "end of the collector not found")
    local data = {}
    local Database = {}
    local env = setmetatable({
        Database = Database, uiSearchData = data,
        RemoveEntriesByCategory = function(cat)
            for i = #data, 1, -1 do if data[i].category == cat then table.remove(data, i) end end
        end,
        slower = string.lower,
        Utils = { SliceCheckpoint = function() end },
        Corpora = {},
        ns = {},
        Enum = { SpellBookSpellBank = { Player = 0 }, SpellBookItemType = { Spell = SPELL, Flyout = FLYOUT } },
        C_SpellBook = {
            GetNumSpellBookSkillLines = function() return #book.lines end,
            GetSpellBookSkillLineInfo = function(i) return book.lines[i] end,
            GetSpellBookItemInfo = function(slot) return book.slots[slot] end,
        },
        GetProfessions = book.professions and function() return book.professions() end or nil,
        GetProfessionInfo = function(i)
            local p = book.profInfo[i]
            return p.name, 1, 1, 100, p.num, p.offset, p.skillLine
        end,
    }, { __index = _G })
    env._G = env
    local uf = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local usrc = uf:read("*a")
    uf:close()
    local us = assert(usrc:find("function Utils.LeanRowMT", 1, true))
    local ue = assert(usrc:find("\n-- Our own functions are post-hooked", us, true))
    assert(load(usrc:sub(us, ue - 1), "=Utils.lua LeanRowMT", "t", env))()
    assert(load(src:sub(s, e - 1), "=Main.lua PopulateDynamicAbilities", "t", env))()
    return Database, data
end

local function Slot(name, id, passive)
    return { name = name, itemType = SPELL, actionID = id, spellID = id, iconID = id, isPassive = passive or false }
end

local BOOK = {
    lines = { { name = "General", itemIndexOffset = 0, numSpellBookItems = 1 } },
    slots = {
        [1] = Slot("Auto Attack", 6603),
        [11] = Slot("Cooking", 2550), [12] = Slot("Cooking Fire", 818),
        [21] = Slot("Fishing Journal", 271990), [22] = Slot("Fishing", 131474),
        [31] = Slot("Herbalism Journal", 2366), [32] = Slot("Herb Gathering", 2368, true),
        [41] = Slot("Not Archaeology's", 1),
    },
    -- herbalism, no second profession, archaeology, fishing, cooking
    professions = function() return 3, nil, 4, 2, 1 end,
    profInfo = {
        { name = "Cooking", offset = 10, num = 2, skillLine = 185 },
        { name = "Fishing", offset = 20, num = 2, skillLine = 356 },
        { name = "Herbalism", offset = 30, num = 2, skillLine = 182 },
        { name = "Archaeology", offset = 40, num = 0, skillLine = 794 },
    },
}

local function Abilities(data)
    local byName = {}
    for _, entry in ipairs(data) do
        if entry.category == "Ability" then byName[entry.name] = entry end
    end
    return byName
end

local tests = {}

function tests.professionActionsAreAbilities()
    local Database, data = loadCollector(BOOK)
    H.assertTrue(Database:PopulateDynamicAbilities())
    local byName = Abilities(data)
    H.assertTrue(byName["Auto Attack"] ~= nil, "the skill lines still read")
    H.assertTrue(byName["Cooking Fire"] ~= nil, "Cooking Fire")
    local fishing = byName["Fishing"]
    H.assertTrue(fishing ~= nil, "the Fishing cast")
    H.assertEq(fishing.spellID, 131474)
    H.assertNil(fishing.spellName, "cast by ID, never by the shared name")
    H.assertTrue(fishing.professionAbility, "marked: the spellbook does not hold it")
    H.assertEq(fishing.treeName, "Fishing")
    H.assertEq(fishing.spellBookIndex, 22)
end

function tests.theWindowOpenersAndPassivesStayOut()
    local Database, data = loadCollector(BOOK)
    Database:PopulateDynamicAbilities()
    local byName = Abilities(data)
    H.assertNil(byName["Cooking"], "the opener is the profession row")
    H.assertNil(byName["Fishing Journal"], "the opener is the profession row")
    H.assertNil(byName["Herbalism Journal"], "the opener is the profession row")
    H.assertNil(byName["Herb Gathering"], "a passive casts nothing")
    H.assertNil(byName["Not Archaeology's"], "no abilities: the slots past it are another's")
end

local pass, fail, failures = H.runSuite("ProfessionAbilities", tests)
return { pass = pass, fail = fail, failures = failures }

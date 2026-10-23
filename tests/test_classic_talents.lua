-- Tests for the classic clients' talents in search (Database/Main.lua
-- PopulateDynamicTalents): Era and Anniversary have no trait configs; their
-- talents are read tab by tab through C_SpecializationInfo.GetTalentInfo.
local H = require("Harness")

-- The reader alone, sliced from the file, with what it calls.
local function loadReader(trees)
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/Main.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function Database:PopulateDynamicTalents()", 1, true), "reader not found")
    local e = assert(src:find("\n-- A cached row keeps whatever icon", s, true), "end of the reader not found")
    local data, Database, queries = {}, {}, {}
    local env = setmetatable({
        Database = Database, uiSearchData = data,
        RemoveEntriesByCategory = function(cat)
            for i = #data, 1, -1 do if data[i].category == cat then table.remove(data, i) end end
        end,
        slower = string.lower, select = select, type = type, pcall = pcall,
        Utils = { SliceCheckpoint = function() end },
        GetNumTalentTabs = function() return #trees end,
        GetNumTalents = function(tab) return #trees[tab].talents end,
        C_SpecializationInfo = {
            GetActiveSpecGroup = function() return 1 end,
            GetSpecializationInfo = function(tab) return tab * 100, trees[tab].name end,
            GetTalentInfo = function(q)
                queries[#queries + 1] = q
                local t = trees[q.specializationIndex].talents[q.talentIndex]
                return t and { name = t.name, icon = t.icon, rank = t.rank, maxRank = t.maxRank, spellID = t.spellID } or nil
            end,
        },
    }, { __index = _G })
    env._G = env
    assert(load(src:sub(s, e - 1), "=Main.lua PopulateDynamicTalents", "t", env))()
    return Database, data, queries
end

local TREES = {
    { name = "Arcane", talents = {
        { name = "Arcane Subtlety", icon = 1, rank = 2, maxRank = 2, spellID = 11210 },
        { name = "Arcane Focus", icon = 2, rank = 0, maxRank = 5, spellID = 11222 } } },
    { name = "Fire", talents = { { name = "Improved Fireball", icon = 3, rank = 5, maxRank = 5, spellID = 12341 } } },
}

local tests = {}

function tests.talentsComeFromTheTabs()
    local Database, data, queries = loadReader(TREES)
    H.assertTrue(Database:PopulateDynamicTalents(), "read without trait configs")
    H.assertEq(#data, 3)
    local subtlety, focus, fireball = data[1], data[2], data[3]
    H.assertEq(subtlety.name, "Arcane Subtlety")
    H.assertEq(subtlety.category, "Talent")
    H.assertTrue(subtlety.talentIsAllocated, "points in it")
    H.assertFalse(focus.talentIsAllocated, "none in it: shown dimmed")
    H.assertEq(fireball.talentTab, 2)
    H.assertEq(fireball.talentIndex, 1)
    H.assertEq(fireball.path[2], "Fire")
    H.assertEq(fireball.buttonFrame, "TalentMicroButton")
    H.assertEq(queries[1].groupIndex, 1, "the active talent group")
    local hasTree = false
    for _, k in ipairs(focus.keywords) do if k == "arcane" then hasTree = true end end
    H.assertTrue(hasTree, "found by its tree's name")
end

local pass, fail, failures = H.runSuite("ClassicTalents", tests)
return { pass = pass, fail = fail, failures = failures }

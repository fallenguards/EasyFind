-- Tests for the classic clients' talents in search (Database/Main.lua
-- PopulateDynamicTalents): Era and Anniversary have no trait configs; their
-- talents are read tab by tab through C_SpecializationInfo.GetTalentInfo,
-- MoP Classic's tier by tier.
local H = require("Harness")

-- The reader alone, sliced from the file, with what it calls.
local function loadReader(trees, tiers)
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/Main.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function Database:PopulateDynamicTalents()", 1, true), "reader not found")
    local e = assert(src:find("\n-- A cached row keeps whatever icon", s, true), "end of the reader not found")
    local data, Database, queries = {}, {}, {}
    local env = setmetatable({
        Database = Database, uiSearchData = data,
        ns = { Caps = { talentTrees = trees ~= nil, talentTiers = tiers ~= nil } },
        MAX_NUM_TALENT_TIERS = tiers and #tiers or nil,
        GetTalentTierInfo = function(tier) return true, 0, tier * 15 end,
        RemoveEntriesByCategory = function(cat)
            for i = #data, 1, -1 do if data[i].category == cat then table.remove(data, i) end end
        end,
        slower = string.lower, select = select, type = type, pcall = pcall,
        Utils = { SliceCheckpoint = function() end },
        GetNumTalentTabs = function() return trees and #trees or 0 end,
        GetNumTalents = function(tab) return #trees[tab].talents end,
        C_SpecializationInfo = {
            GetActiveSpecGroup = function() return 1 end,
            GetSpecializationInfo = function(tab) return tab * 100, trees[tab].name, "", tab * 10 end,
            GetTalentInfo = function(q)
                queries[#queries + 1] = q
                if q.tier then
                    local t = tiers[q.tier][q.column]
                    return t and { name = t.name, icon = 1, selected = t.selected, spellID = t.spellID,
                                   talentID = t.spellID + 1, tier = q.tier, column = q.column } or nil
                end
                local t = trees[q.specializationIndex].talents[q.talentIndex]
                return t and { name = t.name, icon = t.icon, rank = t.rank, maxRank = t.maxRank, spellID = t.spellID,
                               talentID = t.spellID + 1 } or nil
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

local function Named(data, name)
    for _, row in ipairs(data) do if row.name == name then return row end end
end

function tests.talentsComeFromTheTabs()
    local Database, data, queries = loadReader(TREES)
    H.assertTrue(Database:PopulateDynamicTalents(), "read without trait configs")
    H.assertEq(#data, 5, "three talents and their two trees")
    local subtlety, focus, fireball = Named(data, "Arcane Subtlety"), Named(data, "Arcane Focus"),
        Named(data, "Improved Fireball")
    H.assertEq(subtlety.name, "Arcane Subtlety")
    H.assertEq(subtlety.category, "Talent")
    H.assertTrue(subtlety.talentIsAllocated, "points in it")
    H.assertFalse(focus.talentIsAllocated, "none in it: shown dimmed")
    H.assertEq(fireball.talentTab, 2)
    H.assertEq(fireball.talentIndex, 1)
    H.assertEq(fireball.path[2], "Fire")
    H.assertEq(fireball.buttonFrame, "TalentMicroButton")
    H.assertEq(fireball.talentID, 12342, "for the talent's own tooltip")
    H.assertEq(fireball.talentGroup, 1)
    H.assertEq(queries[1].groupIndex, 1, "the active talent group")
    local hasTree = false
    for _, k in ipairs(focus.keywords) do if k == "arcane" then hasTree = true end end
    H.assertTrue(hasTree, "found by its tree's name")
end

-- Searching "Fire" finds the Fire tree itself, not only talents filed under it.
function tests.eachTreeIsARowOfItsOwn()
    local Database, data = loadReader(TREES)
    Database:PopulateDynamicTalents()
    local fire = Named(data, "Fire")
    H.assertNotNil(fire, "the tree's own row")
    H.assertEq(fire.category, "Talent")
    H.assertEq(fire.talentTab, 2, "opens the window on its tree")
    H.assertNil(fire.talentIndex, "no one talent to light")
    H.assertEq(fire.icon, 20, "the tree's icon")
    H.assertEq(#fire.path, 1, "under Talents")
end

-- The row's tooltip: the talent's own, with its ranks, on classic rows only.
function tests.classicRowsShowTheTalentTooltip()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Tooltips.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function Tooltips:SetClassicTalent", 1, true), "SetClassicTalent not found")
    local _, e = src:find("\nend\r?\n", s)
    local Tooltips = {}
    assert(load(src:sub(s, e), "=Tooltips.lua SetClassicTalent", "t", { Tooltips = Tooltips }))()
    local args
    local tooltip = { SetTalent = function(_, ...) args = { ... } end }
    H.assertTrue(Tooltips:SetClassicTalent(tooltip, { talentTab = 2, talentID = 12342, talentGroup = 1 }))
    H.assertEq(args[1], 12342)
    H.assertEq(args[2], false, "not inspecting")
    H.assertEq(args[3], false, "not the pet's")
    H.assertEq(args[4], 1, "the active group")
    H.assertFalse(Tooltips:SetClassicTalent(tooltip, { talentNodeID = 5, spellID = 1 }), "retail rows keep the spell tooltip")
    H.assertTrue(Tooltips:SetClassicTalent(tooltip, { talentTab = 2, talentTier = 1, talentID = 19, talentGroup = 2 }))
    H.assertEq(args[2], false, "MoP: not inspecting")
    H.assertEq(args[3], 2, "MoP's call takes the group third")
    H.assertNil(args[4])
end

-- MoP Classic: a talent per tier and column, on the window's Talents tab.
function tests.mistsTalentsComeFromTheTiers()
    local TIERS = {
        { { name = "Celerity", spellID = 115173, selected = true }, { name = "Tiger's Lust", spellID = 116841 },
          { name = "Momentum", spellID = 115174 } },
        { { name = "Chi Wave", spellID = 115098 }, { name = "Zen Sphere", spellID = 124081 },
          { name = "Chi Burst", spellID = 123986 } },
    }
    local Database, data, queries = loadReader(nil, TIERS)
    H.assertTrue(Database:PopulateDynamicTalents(), "read by tier")
    H.assertEq(#data, 6)
    local celerity, burst = data[1], data[6]
    H.assertEq(celerity.name, "Celerity")
    H.assertTrue(celerity.talentIsAllocated, "the tier's pick")
    H.assertFalse(data[2].talentIsAllocated, "not picked: shown dimmed")
    H.assertEq(burst.talentTier, 2)
    H.assertEq(burst.talentColumn, 3)
    H.assertEq(burst.talentTab, 2, "the window's Talents tab")
    H.assertEq(burst.path[2], "Level 30", "the tier's level")
    H.assertEq(queries[1].groupIndex, 1, "the active talent group")
    H.assertNil(burst.talentRank, "a pick, not ranks: no bar")
end

local pass, fail, failures = H.runSuite("ClassicTalents", tests)
return { pass = pass, fail = fail, failures = failures }

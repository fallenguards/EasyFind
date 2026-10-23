-- Tests for MoP Classic's systems in search: its currency list read through
-- the old GetCurrencyListInfo (Shared/Caps.lua), the currency and heirloom
-- readers (Database/Main.lua) and the character window's sidebars.
local H = require("Harness")

-- MoP Classic's currency list: rows under a collapsed header are not listed.
local function currencyTree()
    return {
        { id = "pvp", name = "Player vs. Player", isHeader = true },
        { parent = "pvp", name = "Honor Points", id = 392, count = 1250, icon = 1 },
        { parent = "pvp", name = "Conquest Points", id = 390, count = 300, icon = 2 },
        { id = "dungeon", name = "Dungeon and Raid", isHeader = true, collapsed = true },
        { parent = "dungeon", name = "Justice Points", id = 395, count = 2000, icon = 3 },
    }
end

local function mistsEnv(tree)
    local env = H.newEnv()
    env._G = env
    env.WOW_PROJECT_CLASSIC, env.WOW_PROJECT_BURNING_CRUSADE_CLASSIC, env.WOW_PROJECT_MISTS_CLASSIC = 2, 5, 19
    env.WOW_PROJECT_ID = 19
    env.GetBuildInfo = function() return "5.5.4", "70531", "", 50504 end
    env.GetNumBindings = function() return 0 end
    env.CHARACTERFRAME_SUBFRAMES = { "PaperDollFrame", "PetPaperDollFrame", "ReputationFrame", "TokenFrame" }
    env.PAPERDOLL_SIDEBARS = { { name = "Character Stats" }, { name = "Titles" }, { name = "Equipment Manager" } }
    env.PAPERDOLL_SIDEBAR_STATS, env.PAPERDOLL_SIDEBAR_TITLES = "Character Stats", "Titles"
    env.PAPERDOLL_EQUIPMENTMANAGER = "Equipment Manager"
    env.C_EquipmentSet = { GetEquipmentSetIDs = function() return {} end }
    local byID = {}
    for _, row in ipairs(tree or {}) do if row.isHeader then byID[row.id] = row end end
    local function visible()
        local rows = {}
        for _, row in ipairs(tree or {}) do
            if not (row.parent and byID[row.parent].collapsed) then rows[#rows + 1] = row end
        end
        return rows
    end
    env.C_CurrencyInfo = {
        GetCurrencyInfo = function() end,
        GetCurrencyListLink = function(i)
            local r = visible()[i]
            return r and not r.isHeader and ("|cff00aa00|Hcurrency:" .. r.id .. "|h[" .. r.name .. "]|h|r") or nil
        end,
    }
    env.GetCurrencyListSize = function() return #visible() end
    env.GetCurrencyListInfo = function(i)
        local r = visible()[i]
        if not r then return nil end
        return r.name, r.isHeader or false, not r.collapsed, false, false, r.count or 0, r.icon
    end
    env.ExpandCurrencyList = function(i, expand) visible()[i].collapsed = (expand == 0) end
    local ns = H.newNs(env)
    H.loadModule("Shared/Caps.lua", env, ns)
    return env, ns
end

local function slice(name, endMarker)
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/Main.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function Database:" .. name .. "()", 1, true), name .. " not found")
    local _, e = src:find(endMarker or "\nend\r?\n", s)
    assert(e, "end of " .. name .. " not found")
    return src:sub(s, e)
end

local tests = {}

function tests.currencyListReadsInRetailFields()
    local _, ns = mistsEnv(currencyTree())
    local Caps = ns.Caps
    H.assertTrue(Caps.currencies, "MoP's character window has the currency tab")
    H.assertEq(Caps.NumCurrencies(), 4, "the collapsed header's row is not listed")
    local honor = Caps.CurrencyAt(2)
    H.assertEq(honor.name, "Honor Points")
    H.assertEq(honor.currencyID, 392, "the id from the row's link")
    H.assertEq(honor.quantity, 1250)
    H.assertEq(honor.iconFileID, 1)
    H.assertFalse(Caps.CurrencyAt(4).isHeaderExpanded, "Dungeon and Raid is collapsed")
    Caps.SetCurrencyHeaderExpanded(4, true)
    H.assertEq(Caps.NumCurrencies(), 5, "expanded through the classic call")
end

function tests.readerListsMistsCurrencies()
    local tree = currencyTree()
    local env, ns = mistsEnv(tree)
    local data, Database = {}, {}
    local readerEnv = setmetatable({
        Database = Database, uiSearchData = data, ns = ns, slower = string.lower, wipe = function(t)
            for k in pairs(t) do t[k] = nil end
        end,
        knownCurrencyIDs = {}, L = setmetatable({}, { __index = function() return "" end }),
        RemoveEntriesByCategory = function() end,
        Utils = { SliceCheckpoint = function() end, DebugPrint = function() end },
    }, { __index = env })
    function Database:IsCurrencyAccountTransferable() return false end
    assert(load(slice("PopulateDynamicCurrencies"), "=Main.lua PopulateDynamicCurrencies", "t", readerEnv))()
    H.assertTrue(Database:PopulateDynamicCurrencies(), "read without C_CurrencyInfo's list")
    local byName = {}
    for _, e in ipairs(data) do byName[e.name] = e end
    H.assertTrue(byName["Justice Points"] ~= nil, "under a header the reader opened")
    H.assertEq(byName["Justice Points"].currencyID, 395)
    H.assertEq(byName["Honor Points"].steps[2].tabIndex, 3, "the currency tab")
    H.assertTrue(tree[4].collapsed, "the header it opened is closed again")
end

function tests.heirloomsComeFromTheJournalList()
    local data, Database = {}, {}
    local ids = { 122349, 122350 }
    local env = setmetatable({
        Database = Database, uiSearchData = data, slower = string.lower, setmetatable = setmetatable,
        RemoveEntriesByCategory = function() end, HEIRLOOM_MT = {},
        C_Heirloom = {
            GetNumDisplayedHeirlooms = function() return #ids end,
            GetHeirloomItemIDFromDisplayedIndex = function(i) return ids[i] end,
            GetHeirloomInfo = function(id) return "Heirloom " .. id, nil, nil, 1, nil, 1, false end,
            PlayerHasHeirloom = function() return true end,
        },
    }, { __index = _G })
    function Database:SyncHeirloomJournalFilter() end
    function Database:HeirloomPassesSearchFilters() return true end
    assert(load(slice("PopulateDynamicHeirlooms"), "=Main.lua PopulateDynamicHeirlooms", "t", env))()
    H.assertTrue(Database:PopulateDynamicHeirlooms(), "read without GetHeirloomItemIDs")
    H.assertEq(#data, 2)
    H.assertEq(data[2].heirloomItemID, 122350)
end

function tests.sidebarsResolveOnMists()
    local _, ns = mistsEnv()
    H.assertEq(ns.Caps.CharacterSidebarSlot(2), 2, "Titles")
    H.assertEq(ns.Caps.CharacterSidebarSlot(3), 3, "Equipment Manager")
    H.assertTrue(ns.Caps.gearSets, "gear sets: MoP has the Equipment Manager")
end

local pass, fail, failures = H.runSuite("MistsSystems", tests)
return { pass = pass, fail = fail, failures = failures }

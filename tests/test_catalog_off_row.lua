-- Every search category is on for a new save, the General Catalog too
-- (2026-11-07); older saves keep their filters, as the defaults fill only
-- keys a save lacks. With the catalog
-- off and few or no item rows found, the list ends with a row that turns
-- it on and runs the typed search again (Search/Query.lua CatalogOffRow,
-- Filters:TurnOnFilter, Results:ActivateResultRow).
local H = require("Harness")

local function Source(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local tests = {}

function tests.everyCategory_isOnForANewSave()
    local main = Source("Core/Main.lua")
    local block = main:match("uiSearchFilters = {(.-)\n    },")
    H.assertNotNil(block, "the filter defaults")
    for key in block:gmatch("\n%s+(%w+)%s+= ") do
        H.assertTrue(block:find(key .. "%s+= true") ~= nil, key .. " on by default")
    end
    H.assertTrue(block:find("catalog%s+= true") ~= nil, "the General Catalog")
    -- Only keys a save lacks are filled: an older save keeps its filters.
    H.assertTrue(main:find("if db[k][sk] == nil then\n                    db[k][sk] = CloneDefaultValue(sv)", 1, true) ~= nil,
        "sub-keys filled only when missing")
end

function tests.theOffer_joinsWhenTheCatalogIsOffAndItemRowsAreFew()
    local src = Source("Search/Query.lua")
    local offer = assert(src:find("ns.CategoryMap.IsProviderFilterOff(filters, \"catalog\") then\n"
        .. "        local itemRows = 0", 1, true), "gated on the catalog filter")
    H.assertTrue(src:find("if itemRows < 3 then combined[#combined + 1] = { score = 1, data = CatalogOffRow() } end",
        offer, true) ~= nil, "under three item rows, scored last")
    H.assertTrue(offer < assert(src:find("Mark(\"joins\")", 1, true)), "before the cap, so it competes like any row")
    H.assertTrue(src:find("not quickFilter and not calculatorData and not calculatorLauncher and #text >= 3\n"
        .. "       and ns.Caps.itemCatalog", 1, true) ~= nil, "no quick filter, a real query, a client with a catalog")
    H.assertTrue(src:find('turnOnFilter = "catalog"', 1, true) ~= nil, "the row turns the filter on")
end

function tests.theOffersClick_turnsTheFilterOnAndSearchesAgain()
    local src = Source("Search/Results/Navigation.lua")
    local turn = assert(src:find("if resultRow.data.turnOnFilter then\n        ns.Filters:TurnOnFilter(resultRow.data.turnOnFilter)", 1, true))
    H.assertTrue(turn < assert(src:find("if resultRow.data.searchCommand then", 1, true)),
        "before the paths that clear the search")
end

local function LoadFilters()
    local env = H.newEnv()
    local ns = H.newNs(env)
    ns.Filters.GetUIBucket = function() return nil end
    ns.Search.SetQuickFilterPillFill = function() end
    ns.Search.GetSelectedIndex = function() return 0 end
    ns.Search.GetResultButtons = function() return {} end
    ns.Search.GetSearchFrame = function() return nil end
    ns.Filters.HideResults = function() end
    ns.Filters.ShowHierarchicalResults = function() end
    ns.Filters.OnSearchTextChanged = function() end
    ns.Filters.IsGuildAchievementData = function() return false end
    H.loadModule("Shared/CategoryMap.lua", env, ns)
    local Filters = H.loadModule("Search/Filters/QuickFilter.lua", env, ns)
    return Filters, env
end

function tests.turnOnFilter_theFilterAndThoseOverIt_thenTheSearchAgain()
    local Filters, env = LoadFilters()
    env.EasyFind.db = { uiSearchFilters = { items = false, catalog = false, bags = true } }
    local reran, resynced = 0, 0
    Filters.RerunActiveSearch = function() reran = reran + 1 end
    Filters.ResyncShownOptionPopups = function() resynced = resynced + 1 end
    Filters:TurnOnFilter("catalog")
    local filters = env.EasyFind.db.uiSearchFilters
    H.assertTrue(filters.catalog, "the catalog")
    H.assertTrue(filters.items, "and the Items switch over it")
    H.assertTrue(filters.bags, "nothing else touched")
    H.assertEq(reran, 1, "the typed search run again")
    H.assertEq(resynced, 1, "open menus resynced")
end

function tests.parentOf_walksTheFilterTree()
    local env = H.newEnv()
    local ns = H.newNs(env)
    H.loadModule("Shared/CategoryMap.lua", env, ns)
    H.assertEq(ns.CategoryMap.ParentOf("catalog"), "items")
    H.assertNil(ns.CategoryMap.ParentOf("items"), "the top")
    H.assertNil(ns.CategoryMap.ParentOf("nothing"))
end

local pass, fail, failures = H.runSuite("CatalogOffRow", tests)
return { pass = pass, fail = fail, failures = failures }

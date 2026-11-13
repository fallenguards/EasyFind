-- Every search category is on for a new save, the General Catalog too
-- (2026-11-07); older saves keep their filters, as the defaults fill only
-- keys a save lacks. With the catalog
-- off and few or no item rows found, the list ends with a row that turns
-- it on and closes the bar (Search/Query.lua CatalogOffRow,
-- Filters:TurnOnFilter, Handlers:SelectResult).
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

-- A mouse click and Enter both end in Handlers:SelectResult: the offer
-- turns its filter on there. Enter alone knew the row; a click closed
-- the bar with the catalog still off (2026-11-13). It is no toggle: the
-- bar closes as after any action, before the filter turns on, so no
-- search runs under a bar going away.
function tests.theOffer_turnsTheFilterOnAndClosesTheBar()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.InCombatLockdown = function() return false end
    ns.ResultGestures = { Blocked = function() return false end }
    local steps = {}
    ns.Filters.TurnOnFilter = function(_, key) steps[#steps + 1] = "on:" .. tostring(key) end
    H.loadModule("Search/Results/Handlers/Selection.lua", env, ns)
    local Handlers = ns.ResultHandlers
    Handlers.FinishResultSelection = function() steps[#steps + 1] = "closed" end
    Handlers:SelectResult({ name = "offer", noLearn = true, turnOnFilter = "catalog" })
    H.assertEq(table.concat(steps, " "), "closed on:catalog")
end

-- Enter runs Results:ActivateResultRow, a mouse click the row's PostClick,
-- and both end in Handlers:SelectResult. A row kind Enter answers before
-- that call must be one the click path knows too.
local KEYBOARD_ONLY = {
    -- Its app entry's run is swapped in by SelectResult (ApplicationEntryID).
    calculatorLauncher = true,
}

function tests.everyRowKindEnterAnswers_aClickAnswersToo()
    local nav = Source("Search/Results/Navigation.lua")
    local from = assert(nav:find("function Results:ActivateResultRow(", 1, true))
    local to = assert(nav:find("\nend\n", from, true))
    local shared = Source("Search/Results/Handlers/Selection.lua")
    shared = shared:sub((assert(shared:find("function Handlers:SelectResult(", 1, true))))
    local click = Source("Search/Results/Rows/Interactions.lua")
    local seen = 0
    for field in nav:sub(from, to):gmatch("resultRow%.data%.([%a_]+)") do
        seen = seen + 1
        if not KEYBOARD_ONLY[field] then
            H.assertTrue(shared:find("data%." .. field .. "%f[%W]") ~= nil or click:find("data%." .. field .. "%f[%W]") ~= nil,
                field .. ": Enter answers this row kind, a mouse click does not (put it in Handlers:SelectResult)")
        end
    end
    H.assertTrue(seen >= 8, "the row kinds read off ActivateResultRow: " .. seen)
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

-- Tests for MapSearch:PlacesForQuery (MapSearch/Search/Results.lua): the
-- search bar's place rows, which the GPS window's search lists too, kept by
-- the map tab's choices (2026-10-26: the bar's leave creatures out).

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)
ns.MapSearchSearch = ns.MapSearchSearch or {}
H.loadModule("MapSearch/Search/Results.lua", env, ns)
local MapSearch = ns.MapSearch

local tests = {}

local function Row(name, mapID, category)
    return { name = name, nameLower = name:lower(), mapID = mapID, category = category }
end

-- The bar's pass (pooled rows) and its nearest-of-a-category lookup, stood in for.
local function WithBar(pass, nearest, fn)
    local saved = { MapSearch.SearchForUI, MapSearch.GetCategoryResultsForUI, ns.MapSearchData }
    MapSearch.SearchForUI = function(_, _, filters)
        pass.filters = filters
        local out = {}
        for i, r in ipairs(pass) do out[i] = { data = r, score = 100 - i } end
        return out
    end
    MapSearch.GetCategoryResultsForUI = function(_, category, maxN, respectFilters, localOnly)
        -- A lookup may run a pass of its own, rewriting the pooled rows.
        for _, r in ipairs(pass) do r.name = "overwritten" end
        return nearest(category, maxN, respectFilters, localOnly)
    end
    ns.MapSearchData = { KEYWORD_TO_CATEGORY = { ["herbalism trainer"] = "prof_herbalism" } }
    fn()
    MapSearch.SearchForUI, MapSearch.GetCategoryResultsForUI, ns.MapSearchData = saved[1], saved[2], saved[3]
end

function tests.placesForQuery_nearestOfTheKindFirstThenThePass()
    env.EasyFind.db.mapCategoryScope = nil
    local tabFilters = { npcs = true }
    env.EasyFind.db.mapTabFilters = tabFilters
    local trainer = Row("Herbalism Trainer", 84, "prof_herbalism")
    local pass = { Row("Telurinon Moonshadow", 56, "npc"), Row("Herbalism Trainer", 84, "prof_herbalism") }
    WithBar(pass,
        function(category, maxN, respectFilters)
            H.assertEq(category, "prof_herbalism")
            H.assertEq(maxN, 3)
            H.assertTrue(respectFilters == tabFilters, "the map tab's choices, not the bar's")
            return { trainer }
        end,
        function()
            local rows = MapSearch:PlacesForQuery("Herbalism Trainer")
            H.assertEq(#rows, 2, "the trainer once, the NPC after it")
            H.assertEq(rows[1].name, "Herbalism Trainer")
            H.assertEq(rows[2].name, "Telurinon Moonshadow", "the pass is copied before the lookup reuses it")
            assert(rows[1] ~= trainer, "rows are copies")
            H.assertTrue(pass.filters == tabFilters, "the pass kept by the map tab's choices")
        end)
    env.EasyFind.db.mapTabFilters = nil
end

function tests.placesForQuery_localScopeKeepsTheKindToThisZone()
    env.EasyFind.db.mapCategoryScope = "local"
    WithBar({ Row("Herbalism Trainer", 1, "prof_herbalism"), Row("Herbalist", 84, "vendor") },
        function(_, maxN, _, localOnly)
            H.assertEq(maxN, 8)
            H.assertEq(localOnly, true)
            return { Row("Herbalism Trainer", 84, "prof_herbalism") }
        end,
        function()
            local rows = MapSearch:PlacesForQuery("herbalism trainer")
            H.assertEq(#rows, 2, "the other zone's trainer stays out")
            H.assertEq(rows[1].mapID, 84)
            H.assertEq(rows[2].name, "Herbalist")
        end)
    env.EasyFind.db.mapCategoryScope = nil
end

function tests.placesForQuery_plainQueryIsThePass()
    WithBar({ Row("Stormwind City", 84, "zone") }, function() error("no category named") end, function()
        local rows = MapSearch:PlacesForQuery("stormwind")
        H.assertEq(#rows, 1)
        H.assertEq(rows[1].name, "Stormwind City")
    end)
end

-- The GPS window lists the bar's places, never a search of its own.
function tests.gpsSearch_usesTheBarsPlaces()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "r"))
    local src = f:read("*a")
    f:close()
    local body = src:match("function GPS%.SearchPlaces%(q%)(.-)\nend")
    assert(body, "GPS.SearchPlaces not found")
    assert(body:find("PlacesForQuery", 1, true), "GPS.SearchPlaces must list MapSearch:PlacesForQuery's rows")
    assert(not body:find("BuildResults", 1, true), "GPS.SearchPlaces runs a search of its own")
end

local pass, fail, failures = H.runSuite("GPS search places", tests)
return { pass = pass, fail = fail, failures = failures }

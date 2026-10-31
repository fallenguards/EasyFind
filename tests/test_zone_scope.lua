-- "This zone only" per map category (MapSearch/Main.lua ZoneOnly over
-- EasyFind.db.mapZoneOnly; the Map flyout's scope rows in
-- Search/Filters/Config.lua and Dropdown.lua; the bar's places from every
-- zone in MapSearch/Search/Results.lua). The one checkbox narrowed only
-- the category-word boost, and the bar searched the player's zone's places
-- whatever it said: "sword trainer" from Westfall found no Stormwind master.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Chunk(path, from, to, ret, env)
    local src = Read(path)
    local s = assert(src:find(from, 1, true), from)
    local e = assert(src:find(to, s, true), to)
    return assert(load(src:sub(s, e - 1) .. "\nreturn " .. ret, "=" .. path, "t", setmetatable(env, { __index = _G })))()
end

local CATEGORIES = { bank = { parent = "service" }, innkeeper = { parent = "service" },
                     mailbox = { parent = "service" }, vendor = { parent = "service" },
                     trainer = { parent = "service" }, flightmaster = { parent = "travel" } }

local function Scope(only)
    local env = { ns = { Extensions = { Providers = { byCategory = {} } }, MapSearch = {} },
                  CATEGORIES = CATEGORIES, sfind = string.find, EasyFind = { db = { mapZoneOnly = only } } }
    return Chunk("MapSearch/Main.lua", "local function GetFilterBucket", "\nfunction MapSearch:Initialize",
        "ns.MapSearch.ZoneOnly, ns.MapSearch.ZoneOnlyForCategory", env)
end

local tests = {}

function tests.nothingSet_everyPlaceIsSearchedEverywhere()
    local zoneOnly = Scope({})
    H.assertTrue(not zoneOnly({ category = "bank" }))
    H.assertTrue(not zoneOnly({ category = "trainer" }))
end

function tests.theSwitchForEveryCategory_keepsAllButZonesHome()
    local zoneOnly = Scope({ all = true })
    H.assertTrue(zoneOnly({ category = "bank" }))
    H.assertTrue(zoneOnly({ category = "dungeon", isZone = true }), "an instance is a place")
    H.assertTrue(not zoneOnly({ category = "zone", isZone = true }), "a zone is a zone wherever you stand")
end

function tests.aCategorysSwitch_keepsThatCategoryHome()
    local zoneOnly, forCategory = Scope({ banks = true, trainers = true })
    H.assertTrue(zoneOnly({ category = "bank" }))
    H.assertTrue(zoneOnly({ category = "trainer" }), "the weapon master")
    H.assertTrue(zoneOnly({ category = "prof_fishing" }), "a profession trainer")
    H.assertTrue(zoneOnly({ category = "classtrainer_mage" }), "a class trainer")
    H.assertTrue(not zoneOnly({ category = "innkeeper" }))
    H.assertTrue(not zoneOnly({ category = "vendor" }))
    H.assertTrue(forCategory("bank"))
    H.assertTrue(not forCategory("innkeeper"))
end

function tests.aParentBucketsSwitch_coversItsChildren()
    local zoneOnly = Scope({ services = true })
    H.assertTrue(zoneOnly({ category = "innkeeper" }))
    H.assertTrue(zoneOnly({ category = "mailbox" }))
    H.assertTrue(not zoneOnly({ category = "flightmaster" }))
end

function tests.theMapFlyout_hasAScopeRowPerCategory()
    local config = Read("Search/Filters/Config.lua")
    H.assertTrue(config:find('key = "all", label = L["FILTER_MAP_SCOPE_LOCAL"], dbTable = "mapZoneOnly", scope = true', 1, true) ~= nil,
        "the switch for every category")
    H.assertTrue(config:find('leaves[#leaves + 1] = { key = leaf.key, label = leaf.label, dbTable = "mapZoneOnly", scope = true }', 1, true) ~= nil,
        "one per category, the flyout's own leaves")
    H.assertTrue(config:find('if sub.key ~= "zones" then', 1, true) ~= nil, "zones aside")
    local dropdown = Read("Search/Filters/Dropdown.lua")
    H.assertTrue(dropdown:find("if not sub.scope and target[sub.key] ~= false then", 1, true) ~= nil
        and dropdown:find("if not sub.scope then target[sub.key] = allUnchecked end", 1, true) ~= nil,
        "the flyout's Toggle All leaves the scope rows alone")
    H.assertTrue(dropdown:find("if def.scope then return target[def.key] == true end", 1, true) ~= nil,
        "a scope row is off unless set")
end

function tests.theBar_searchesEveryZonesPlaces()
    local results = Read("MapSearch/Search/Results.lua")
    H.assertTrue(results:find("AppendLocalSearchSources(self, pois, existingNames, nil, searchMapID, false)", 1, true) ~= nil,
        "static names unmarked, so same-named places fold after scoring")
    H.assertTrue(results:find("AppendWorldStaticLocations(self, pois, existingNames, searchMapID)", 1, true) ~= nil,
        "every other zone's places join")
    H.assertTrue(results:find("not (scoped and ZoneOnly(r) and not InZone(r, searchMapID))", 1, true) ~= nil,
        "a category switched home stays home")
    H.assertTrue(results:find("local src = NearestInstance(r)", 1, true) ~= nil, "the nearest of a folded place is the row")
    local scanners = Read("MapSearch/Search/Scanners.lua")
    local _, copies = scanners:gsub("teaches = loc%.teaches", "")
    H.assertEq(copies, 2, "a weapon master's weapons ride along on both lists")
end

function tests.theOldSwitch_isGoneFromEveryShippedFile()
    local left = {}
    local seen = {}
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            if not seen[rel] then
                seen[rel] = true
                local f = io.open(H.ADDON_ROOT .. "/" .. rel, "rb")
                if f then
                    local src = f:read("*a")
                    f:close()
                    if src:find("mapCategoryScope", 1, true) and rel ~= "Core/Main.lua" then left[#left + 1] = rel end
                end
            end
        end
    end
    H.assertEq(table.concat(left, ", "), "", "mapCategoryScope read outside its migration")
    H.assertTrue(Read("Core/Main.lua"):find("mapZoneOnly = {},", 1, true) ~= nil, "the per-category table is the default")
end

local pass, fail, failures = H.runSuite("ZoneScope", tests)
return { pass = pass, fail = fail, failures = failures }

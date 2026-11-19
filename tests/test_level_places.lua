-- "level 25" (2026-11-19): the zones and dungeons that fit a level, not
-- creatures. Zones by the shipped ranges (the game's own call answers
-- 0-0 for a zone on Forever, seen 2026-11-20), dungeons by what their
-- bosses' drops ask for; only on the clients whose zones keep a level.
local H = require("Harness")

local function Pack(ilvl, req) return ilvl + 256 * req end

local function World(caps)
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    ns.Caps = caps or { forever = true }
    ns.L.LEVEL_RANGE_FMT, ns.L.CHAR_LEVEL_FMT = "Levels %d-%d", "Level %d"
    env.Enum = { UIMapType = { Zone = 3, Continent = 2 } }
    ns.ZONE_LEVELS = { [1] = { 10, 20 }, [2] = { 20, 30 }, [3] = { 25, 35 }, [6] = { 20, 30 } }
    -- The game's own call, as Forever answers it.
    env.C_Map = { GetMapLevels = function() return 0, 0 end,
                  GetMapInfo = function(m) return { name = "Map " .. m } end }
    local t = { zones = {
        { mapID = 1, name = "Westfall", mapType = 3, parentName = "Eastern Kingdoms" },
        { mapID = 3, name = "Thousand Needles", mapType = 3, parentName = "Kalimdor" },
        { mapID = 2, name = "Ashenvale", mapType = 3, parentName = "Kalimdor" },
        { mapID = 6, name = "Ashenvale", mapType = 3, parentName = "Kalimdor" },
        { mapID = 4, name = "Stormwind City", mapType = 3 },
        { mapID = 5, name = "Kalimdor", mapType = 2 },
    } }
    ns.MapSearch = {
        BuildWorldZoneCache = function() return t.zones end,
        UIRowOf = function(poi)
            local d = {}
            for k, v in pairs(poi) do d[k] = v end
            d.mapSearchResult = true
            return d
        end,
    }
    ns.Upgrades = { Gear = function(id)
        local v = ns.STATIC_LOOT_GEAR[id]
        if v then return v % 256, math.floor(v / 256) % 128 end
    end }
    ns.STATIC_LOOT_GEAR = { [100] = Pack(20, 15), [101] = Pack(25, 20), [200] = Pack(30, 24), [201] = Pack(34, 0),
                            [300] = Pack(66, 60), [400] = Pack(28, 22) }
    ns.STATIC_LOOT = {
        { inst = 36, enc = 1, items = { 100, 101 } },
        { inst = 48, enc = 2, items = { 200 }, heroic = { 201 } },
        { inst = 409, enc = 3, items = { 300 } },
        { inst = 2959, enc = 4, items = {} },
    }
    ns.FOREVER_INSTANCES = {
        { id = 36, n = "Deadmines", raid = false, m = 1436, x = 0.38, y = 0.77 },
        { id = 48, n = "Blackfathom Deeps", raid = false, m = 1440, x = 0.16, y = 0.11 },
        { id = 48, n = "Blackfathom Deeps", raid = false, m = 1441, x = 0.5, y = 0.5 },
        { id = 409, n = "Molten Core", raid = true, m = 1428, x = 0.26, y = 0.24 },
        { id = 2959, n = "City of Dalaran", raid = false, m = 1416, x = 0.2, y = 0.6 },
    }
    env.GetRealZoneText = function(id) return id == 36 and "Die Todesminen" or "" end
    local shown = {}
    ns.Results.ShowHierarchicalResults = function(_, entries)
        for i = #shown, 1, -1 do shown[i] = nil end
        for i, e in ipairs(entries) do shown[i] = { name = e.name, header = e.isSectionHeader, data = e.data } end
    end
    H.loadModule("Search/LevelPlaces.lua", env, ns)
    return ns.LevelPlaces, shown, t, ns
end

local function Names(shown)
    local out = {}
    for i, e in ipairs(shown) do out[i] = (e.header and "[" .. e.name .. "]" or e.name) end
    return table.concat(out, ", ")
end

local tests = {}

function tests.theText_isTheWordLevelAndANumber()
    local Places = World()
    H.assertEq(Places.Query("level 25"), 25)
    H.assertEq(Places.Query(" Lvl 8 "), 8)
    H.assertNil(Places.Query("level"), "no number")
    H.assertNil(Places.Query("level 25 dungeons"), "more words: a search")
    H.assertNil(Places.Query("25"), "a number alone")
    H.assertNil(Places.Query("level 0"))
    H.assertNil(Places.Query("level 200"))
end

function tests.onlyWhereZonesKeepALevel()
    H.assertNil((World({ retail = true })).Query("level 25"), "retail's zones scale")
    H.assertEq((World({ era = true })).Query("level 25"), 25)
    H.assertEq((World({ tbc = true })).Query("level 25"), 25)
end

function tests.zonesByTheirShippedRange_dungeonsByTheirDrops()
    local Places, shown = World()
    Places:Show(25)
    H.assertEq(Names(shown), "[Zones], Ashenvale, Thousand Needles, [Dungeons], Blackfathom Deeps",
        "the lower zone first, a zone once, no city, no continent; a dungeon once")
    H.assertEq(shown[2].data.matchNote, "Levels 20-30")
    H.assertEq(shown[2].data.zoneMapID, 2)
    H.assertEq(shown[2].data.pathPrefix, "Kalimdor")
    local bfd = shown[5].data
    H.assertEq(bfd.matchNote, "Levels 24-29", "a drop asking no level counts five under its item level")
    H.assertEq(bfd.category, "dungeon")
    H.assertEq(bfd.entranceMapID, 1440, "at its first door")
    H.assertTrue(bfd.noPin and bfd.mapSearchResult)
end

function tests.aDungeonStillFits_aFewLevelsPastItsLastDrop()
    local Places, shown = World()
    Places:Show(23)
    H.assertTrue(Names(shown):find("Die Todesminen", 1, true) ~= nil, "20 + 3, by the client's name for it: " .. Names(shown))
    Places:Show(24)
    H.assertNil(Names(shown):find("Die Todesminen", 1, true))
end

function tests.raidsUnderTheirOwnHeading_andNothingSaysSo()
    local Places, shown = World()
    Places:Show(60)
    H.assertEq(Names(shown), "[Raids], Molten Core")
    H.assertEq(shown[2].data.matchNote, "Level 60", "one level, not a range")
    Places:Show(70)
    H.assertEq(#shown, 1)
    H.assertFalse(shown[1].header, "a plain line saying nothing was found")
end

function tests.theLists_areWhatThePageShows()
    local Places = World()
    local zones, dungeons, raids = Places.Lists(25)
    H.assertEq(#zones, 2)
    H.assertEq(#dungeons, 1)
    H.assertEq(#raids, 0)
end

-- Each client's shipped ranges, as the toc loads them.
local SHIPPED = {
    { "Database/ZoneLevels_Forever.lua", "camelot", 2521, 1, 12, "forever" },
    { "Database/ZoneLevels_Era.lua", "vanilla", 1436, 9, 18, "era" },
    { "Database/ZoneLevels_TBC.lua", "tbc", 1944, 58, 62, "tbc" },
}

function tests.eachClientShipsItsZones_withSaneRanges()
    local fh = assert(io.open(H.ADDON_ROOT .. "/EasyFind.toc", "rb"))
    local toc = fh:read("*a")
    fh:close()
    for _, shipped in ipairs(SHIPPED) do
        local file, gameType, mapID, lo, hi = shipped[1], shipped[2], shipped[3], shipped[4], shipped[5]
        H.assertTrue(toc:find(file .. " [AllowLoadGameType " .. gameType .. "]", 1, true) ~= nil, file .. " is not in the toc")
        local env = H.newEnv()
        local ns = H.newNs(env)
        ns.Caps = { retail = true }
        H.loadModule(file, env, ns)
        H.assertNil(ns.ZONE_LEVELS, file .. " loads on another client")
        ns.Caps = { [shipped[6]] = true }
        H.loadModule(file, env, ns)
        local count = 0
        for id, range in pairs(ns.ZONE_LEVELS) do
            count = count + 1
            H.assertTrue(range[1] >= 1 and range[1] <= range[2] and range[2] <= 70, file .. " map " .. id)
        end
        H.assertTrue(count >= 39, file .. " holds " .. count .. " zones")
        H.assertEq(ns.ZONE_LEVELS[mapID][1], lo, file)
        H.assertEq(ns.ZONE_LEVELS[mapID][2], hi, file)
        H.assertNil(ns.ZONE_LEVELS[1453], "a city has no range")
        -- A starting zone begins at 1 though its first valley carries no level.
        H.assertEq(ns.ZONE_LEVELS[1420][1], 1, "Tirisfal Glades")
        -- Razorfen Downs' door does not stretch the Barrens.
        H.assertEq(ns.ZONE_LEVELS[1413][2], 25, "The Barrens")
    end
end

function tests.aClientWithoutRanges_showsTheDungeons()
    local Places, shown, _, ns = World()
    ns.ZONE_LEVELS = nil
    Places:Show(25)
    H.assertEq(Names(shown), "[Dungeons], Blackfathom Deeps")
end

function tests.theZoneListStillBuilding_showsTheDungeons()
    local Places, shown, t = World()
    t.zones = nil
    Places:Show(25)
    H.assertEq(Names(shown), "[Dungeons], Blackfathom Deeps")
end

local pass, fail, failures = H.runSuite("LevelPlaces", tests)
return { pass = pass, fail = fail, failures = failures }

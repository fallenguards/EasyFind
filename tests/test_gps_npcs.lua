-- Tests for Apps/GPS/Npcs.lua: the creature catalog read back, matched by
-- name or title in either language, each row on the right spot.
local H = require("Harness")

local function varints(list)
    local out = {}
    for _, v in ipairs(list) do
        while v >= 128 do
            out[#out + 1] = string.char(v % 128 + 128)
            v = math.floor(v / 128)
        end
        out[#out + 1] = string.char(v)
    end
    return table.concat(out)
end

local function xy(x, y) return math.floor(x * 4095 + 0.5) * 4096 + math.floor(y * 4095 + 0.5) end

-- Four creatures in id order (6, 448, 639, 1076), each id as a delta.
local ROWS = varints({
    4,
    -- id, level, span, flags, kind (type | expansion + 1 << 4 | roles << 8), display, title, spots
    6, 1, 1, 80, 7 + 16, 327, 0, 2, 1429, xy(0.5, 0.5), 10, 1433, xy(0.1, 0.1), 3,  -- Kobold Vermin, hostile to both
    442, 11, 0, 17, 1 + 16, 384, 0, 1, 1429, xy(0.3, 0.4), 1,                       -- Hogger, beast, elite
    191, 25, 0, 0, 7 + 16 + 256, 0, 0, 1, 0, 36, 1,                                 -- Edwin VanCleef, quests, no model
    437, 30, 0, 0, 7 + 32 + 512, 2160, 1, 1, 1426, xy(0.2, 0.3), 1,                 -- Brog Hamfist, vendor, TBC
})

-- Two tiles on continent 0: tile 3100 hostile from level 20 to the
-- Alliance and 0 (none) to the Horde, tile 3105 from level 60 to both.
local DANGER = varints({ 2, 3100, 20, 0, 5, 60, 60 })

local function fresh(localNames, rows, names, goods, noLoad)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { forever = true }
    local function vec(x, y) return { x = x, y = y, GetXY = function(self) return self.x, self.y end } end
    env.CreateVector2D = vec
    env.C_EncodingUtil = { DecodeBase64 = function(s) return s end, DecompressString = function(s) return s end }
    env.C_Item = { GetItemSubClassInfo = function(c, s) return c == 2 and ({ [2] = "Bows", [18] = "Crossbows" })[s] end }
    env.C_Map = {
        GetBestMapForUnit = function() return 1429 end,
        GetPlayerMapPosition = function() return vec(0.31, 0.41) end,
        GetWorldPosFromMapPos = function(m, v) return (m == 1433 or m == 1429 or m == 1426) and 0 or 1, vec(v.x * 1000 + m, v.y * 1000) end,
        GetMapInfo = function(m) return { name = "Map " .. m } end,
    }
    ns.MapSearch = {}
    ns.MapSearchSearch = { PreparePOI = function(p) p.nameLower = string.lower(p.name) return p end }
    ns.FOREVER_INSTANCES = { { id = 36, n = "Deadmines", m = 1436, x = 0.38, y = 0.77, ci = 0, wx = -11208, wy = 1681 } }
    ns.NPC_DATA = { rows = rows or ROWS, names = names or "Kobold Vermin\nHogger\nEdwin VanCleef\nBrog Hamfist",
                    titles = "General Supplies", localNames = localNames, danger = { [0] = DANGER },
                    types = { [1] = "Beast", [7] = "Humanoid" },
                    goods = goods and goods.blob, goodsNames = goods and goods.names,
                    localGoods = goods and goods.localNames }
    env.EasyFind.db = {}
    ns.L.NPC_SELLS = "Sells %s"
    H.loadModule("Apps/GPS/Npcs.lua", env, ns)
    -- As if the first-focus warm had landed: typing never decodes.
    if not noLoad then ns.GPSNpcs.Load(); ns.GPSNpcs.LoadGoods() end
    return ns.MapSearch.AppendNpcRows, ns.GPSNpcs, env
end

-- Vendors around a player standing at 0.31, 0.41 of map 1429, the
-- Alliance: count repairers named "Arnold N" far off, one named
-- "Bea Longername" beside the player, "Cid" repairing for the Horde only,
-- and "Dana" selling food.
local REPAIR = 7 + 16 + (2 + 256) * 256
local function vendors(count)
    local list, names = { count + 2 }, {}
    local function add(name, flags, kind, x, y)
        for _, v in ipairs({ 1, 10, 0, flags, kind, 0, 0, 1, 1429, xy(x, y), 1 }) do list[#list + 1] = v end
        names[#names + 1] = name
    end
    for k = 1, count - 1 do add("Arnold " .. k, 0, REPAIR, 0.9, 0.9) end
    add("Bea Longername", 0, REPAIR, 0.32, 0.42)
    add("Cid", 2 * 8, REPAIR, 0.31, 0.41)
    add("Dana", 0, 7 + 16 + (2 + 512) * 256, 0.5, 0.5)
    local append, _, env = fresh(nil, varints(list), table.concat(names, "\n"))
    env.UnitFactionGroup = function() return "Alliance" end
    return append
end

local function named(rows, name)
    for _, r in ipairs(rows) do if r.name == name then return r end end
    return nil
end

local function find(append, query, onlyMap)
    local out = {}
    append(out, {}, query, onlyMap)
    return out
end

local tests = {}

function tests.typingNeverDecodes_theWarmDoes()
    local append, N, env = fresh(nil, nil, nil, nil, true)
    H.assertEq(#find(append, "hogger"), 0, "no creatures before the catalog is in")
    H.assertTrue(N.n == nil, "the keystroke did not decode")
    env._clock:advance(0.1)
    H.assertTrue(N.n and N.n > 0, "the warm decoded it")
    H.assertEq(#find(append, "hogger"), 1, "found once it is in")
end

function tests.nameFindsTheCreatureOnItsSpot()
    local rows = find(fresh(), "hog")
    H.assertEq(#rows, 1)
    H.assertEq(rows[1].name, "Hogger")
    H.assertEq(rows[1].category, "npc")
    H.assertEq(rows[1].mapID, 1429)
    H.assertTrue(math.abs(rows[1].x - 0.3) < 0.001 and math.abs(rows[1].y - 0.4) < 0.001)
    H.assertEq(rows[1].npcID, 448)
    H.assertEq(rows[1].displayID, 384)
    H.assertEq(find(fresh(), "vancleef")[1].displayID, nil)
end

-- Along a route: each creature at its spot least out of the way, those
-- with none on it left out.
function tests.alongARouteTheSpotOnTheWay()
    local append = fresh()
    local function along(ci, x) if ci == 0 and x < 1600 then return 42 end return nil end
    local out = {}
    append(out, nil, "kobold", nil, nil, along)
    H.assertEq(#out, 1)
    H.assertEq(out[1].mapID, 1433, "the spot on the way, not the one nearest the player")
    out = {}
    append(out, nil, "hogger", nil, nil, along)
    H.assertEq(#out, 0, "no spot on the way")
end

function tests.dungeonCreatureStandsAtTheEntrance()
    local rows = find(fresh(), "vancleef")
    H.assertEq(rows[1].mapID, 1436)
    H.assertEq(rows[1].zoneName, "Deadmines")
end

function tests.titleMatchesToo()
    local rows = find(fresh(), "general supplies")
    H.assertEq(#rows, 1)
    H.assertEq(rows[1].name, "Brog Hamfist")
end

function tests.nearestSpotOnThisContinent_orTheZoneAsked()
    local append = fresh()
    H.assertEq(find(append, "kobold")[1].mapID, 1429, "the player's zone holds the nearest")
    local there = find(append, "kobold", 1433)[1]
    H.assertEq(there.mapID, 1433, "a zone's own search shows its spot")
    H.assertEq(#find(append, "hogger", 1433), 0, "a creature not on that map is left out")
end

function tests.localNamesShow_andEnglishStillFinds()
    local append = fresh("Koboldungeziefer\n\n\n")
    local rows = find(append, "vermin")
    H.assertEq(rows[1].name, "Koboldungeziefer", "the client's language shows")
    H.assertEq(find(append, "ungez")[1].name, "Koboldungeziefer")
    H.assertEq(find(append, "hogger")[1].name, "Hogger", "a blank line falls back to English")
end

function tests.dangerTiles_byLevelAndFaction()
    local _, Npcs = fresh()
    local low = Npcs.DangerTiles(15, "Alliance")[0]
    H.assertTrue(low[3100] and low[3105], "level 15: both tiles con orange or red")
    local mid = Npcs.DangerTiles(18, "Alliance")[0]
    H.assertNil(mid[3100], "level 18: 20 is only yellow")
    H.assertTrue(mid[3105])
    H.assertNil(Npcs.DangerTiles(15, "Horde")[0][3100], "nothing there is hostile to the Horde")
    H.assertNil(Npcs.DangerTiles(60, "Horde")[0][3105], "at 60 nothing is")
end

function tests.filtersLeaveOutWhatIsUnchecked()
    local append, _, env = fresh()
    local f = {}
    env.EasyFind.db.npcFilters = f
    env.UnitFactionGroup = function() return "Alliance" end
    f.type = { [1] = false }
    H.assertEq(#find(append, "hogger"), 0, "beasts off")
    f.type = nil
    f.expansion = { [1] = false }
    H.assertEq(#find(append, "brog"), 0, "the second expansion off")
    H.assertEq(#find(append, "hogger"), 1, "the first stays")
    f.expansion = nil
    f.role = { other = false }
    H.assertEq(#find(append, "kobold"), 0, "creatures with no role off")
    H.assertEq(#find(append, "brog"), 1, "a vendor stays")
    f.role = { vendor = false }
    H.assertEq(#find(append, "brog"), 0, "vendors off")
    f.role = nil
    f.reaction = { [2] = false }
    H.assertEq(#find(append, "hogger"), 0, "hostile off")
    H.assertEq(#find(append, "brog"), 1, "friendly stays")
end

function tests.filterChoicesListWhatTheCatalogHolds()
    local _, Npcs = fresh()
    local c = Npcs.FilterChoices()
    H.assertEq(#c.types, 2)
    H.assertEq(c.types[1].name, "Beast")
    H.assertDeepEq(c.expansions, { 0, 1 })
end

function tests.shortQueriesFindNothing()
    H.assertEq(#find(fresh(), "ho"), 0)
end

-- "repair" finds who repairs, whatever they are called, and only those
-- who will serve the player.
function tests.aServiceWordFindsWhoOffersIt()
    local rows = find(vendors(3), "repair")
    H.assertEq(#rows, 3, "the two Arnolds and Bea")
    H.assertNil(named(rows, "Cid"), "repairs for the other faction only")
    H.assertNil(named(rows, "Dana"))
    local kw = table.concat(named(rows, "Bea Longername").keywords, ",")
    H.assertTrue(kw:find("repair", 1, true) ~= nil, "the word rides along for the map search: " .. kw)
    H.assertEq(find(vendors(3), "food")[1].name, "Dana", "what a vendor sells counts too")
    H.assertEq(#find(vendors(3), "rep"), 3, "found while typing")
end

-- More matches than are handed over: the nearest of equal ones get in,
-- not the shortest names.
function tests.pastTheCapTheNearestGetIn()
    local rows = find(vendors(80), "repair")
    H.assertEq(#rows, 60)
    H.assertEq(rows[1].name, "Bea Longername")
end

-- Two items (159 water, 2515 arrows) on one shared list, sold by the
-- Kobold Vermin (row 0, hostile to the Alliance) and Brog Hamfist (row 3).
local GOODS = {
    blob = varints({ 2, 159, 2356, 0, 0, 1, 2, 0, 1, 2, 0, 0, 3, 0 }),
    names = "Refreshing Spring Water\nSharp Arrow",
}

function tests.anItemFindsWhoSellsIt()
    local append = fresh(nil, nil, nil, GOODS)
    local rows = find(append, "sharp arrow")
    H.assertEq(#rows, 1, "the kobold sells it too, but will not serve the Alliance")
    H.assertEq(rows[1].name, "Brog Hamfist")
    H.assertEq(rows[1].matchNote, "Sells Sharp Arrow")
    H.assertEq(rows[1].keywords[1], "Sharp Arrow", "the item rides along for the map search")
    H.assertEq(find(append, "water")[1].matchNote, "Sells Refreshing Spring Water")
    H.assertEq(find(append, "brog")[1].matchNote, nil, "found by name, no note")
    H.assertTrue(not table.concat(find(append, "brog")[1].keywords, ","):find("Arrow", 1, true),
        "and the item's keyword is gone")
    H.assertEq(#find(append, "sharp", 1433), 0, "a zone's own search keeps its own vendors")
end

-- A creature named for the query still says what it sells that matches,
-- when a word of the item starts with the query.
function tests.aNameMatchAlsoNamesWhatItSells()
    local append = fresh(nil, nil, nil, { blob = GOODS.blob, names = "Refreshing Spring Water\nBrog Arrow" })
    local rows = find(append, "brog")
    H.assertEq(rows[1].name, "Brog Hamfist")
    H.assertEq(rows[1].soldName, "Brog Arrow", "found by name, and the item named")
    H.assertEq(#rows, 1, "the kobold sells it too, but only an item match would bring it and it will not serve")
    H.assertNil(find(append, "rog")[1].soldName, "inside a word of the item: no note")
end

-- Water and a Worn Shortbow (bows, subclass 2) sold by Brog Hamfist (row
-- 3), a Light Crossbow (subclass 18) by Edwin VanCleef (row 2).
local WEAPONS = {
    blob = varints({ 3, 159, 2345, 3, 0, 3, 19, 2, 2, 0, 1, 1, 2, 2, 2, 1, 1, 0 }),
    names = "Refreshing Spring Water\nWorn Shortbow\nLight Crossbow",
}

function tests.aWeaponFindsByItsType()
    local append = fresh(nil, nil, nil, WEAPONS)
    local rows = find(append, "bow")
    H.assertEq(#rows, 1, "a crossbow is not a bow")
    H.assertEq(rows[1].name, "Brog Hamfist")
    H.assertEq(rows[1].soldName, "Bows", "the type, as the client names it")
    H.assertEq(rows[1].keywords[1], "Bows", "the type rides along for the map search")
    H.assertEq(find(append, "bows")[1].soldName, "Bows")
    H.assertEq(find(append, "shortbow")[1].soldName, "Worn Shortbow", "the item's own name, when it is typed")
    rows = find(append, "crossbow")
    H.assertEq(#rows, 1)
    H.assertEq(rows[1].name, "Edwin VanCleef")
    H.assertEq(rows[1].matchNote, "Sells Crossbows")
end

-- Found by their stock alone, vendors score alike: each carries the best
-- item matched and no title, so the map search puts the nearest first.
function tests.vendorsFoundByStockScoreAlike()
    local append = fresh(nil, nil, nil, { blob = WEAPONS.blob,
                                          names = "Refreshing Spring Water\nWorn Shortbow\nShortbow of Light" })
    local rows = find(append, "shortbow")
    local brog, edwin = named(rows, "Brog Hamfist"), named(rows, "Edwin VanCleef")
    H.assertEq(brog.soldName, "Worn Shortbow", "each says what it sells")
    H.assertEq(edwin.soldName, "Shortbow of Light")
    H.assertEq(table.concat(brog.keywords, ","), "Shortbow of Light", "scored as the best item, no title")
    H.assertEq(table.concat(edwin.keywords, ","), "Shortbow of Light")
    H.assertTrue(table.concat(find(append, "brog")[1].keywords, ","):find("General Supplies", 1, true),
        "found by name: the title is back")
end

function tests.anItemFindsInEitherLanguage()
    local append = fresh(nil, nil, nil, { blob = GOODS.blob, names = GOODS.names,
                                          localNames = "Erfrischendes Quellwasser\nScharfer Pfeil" })
    local rows = find(append, "pfeil")
    H.assertEq(rows[1].matchNote, "Sells Scharfer Pfeil", "the client's language shows")
    H.assertEq(find(append, "sharp")[1].name, "Brog Hamfist", "English still finds")
end

-- Repairers on two maps, an innkeeper, a grunt named after Orgrimmar and
-- a vendor on a third map; "org" names map 1433, Auberdine's inn is where
-- Bea stands.
local INN = 7 + 16 + 16 * 256
local function places()
    local list, names = { 5 }, {}
    local function add(name, kind, m, x, y)
        for _, v in ipairs({ 1, 10, 0, 0, kind, 0, 0, 1, m, xy(x, y), 1 }) do list[#list + 1] = v end
        names[#names + 1] = name
    end
    add("Arnold", REPAIR, 1429, 0.9, 0.9)
    add("Bea", REPAIR, 1433, 0.1, 0.1)
    add("Dana", INN, 1433, 0.12, 0.1)
    add("Orgrimmar Grunt", 7 + 16, 1429, 0.5, 0.5)
    add("Ed", 7 + 16 + 2 * 256, 1426, 0.5, 0.5)
    local append, _, env = fresh(nil, varints(list), table.concat(names, "\n"))
    env.UnitFactionGroup = function() return "Alliance" end
    local ns = env.EasyFind._ns
    ns.MapSearch.ZonesNamed = function(_, word)
        if word == "org" then return { { mapID = 1433, name = "Orgrimmar", nameLower = "orgrimmar" } } end
        return nil
    end
    ns.GPSData = { binds = { [1] = { m = 1433, x = 0.1, y = 0.1, ci = 0, wx = 1533, wy = 100 } } }
    env.C_Map.GetAreaInfo = function(a) return a == 1 and "Auberdine" or nil end
    return function(query, onlyMap, nearMap)
        local out = {}
        append(out, {}, query, onlyMap, nearMap)
        return out
    end
end

function tests.servicesAloneStayOnThePlayersMap()
    local find = places()
    local rows = find("repair", nil, 1429)
    H.assertEq(#rows, 1)
    H.assertEq(rows[1].name, "Arnold")
    H.assertEq(#find("repair", nil, 1426), 2, "none on that map: everywhere")
    H.assertEq(#find("repair"), 2, "no map given: everywhere")
end

function tests.aZoneWordNarrowsToIt()
    local find = places()
    local rows = find("org repair")
    H.assertEq(#rows, 1)
    H.assertEq(rows[1].name, "Bea")
    H.assertTrue(table.concat(rows[1].keywords, ","):find("org", 1, true) ~= nil, "the word rides along")
    H.assertEq(find("repair org")[1].name, "Bea", "in either order")
    H.assertEq(#find("org repair", nil, 1429), 1, "the place beats the player's map")
    H.assertEq(find("org")[1].name, "Orgrimmar Grunt", "alone it is a name")
    local grunt = find("org grunt")
    H.assertEq(grunt[1].name, "Orgrimmar Grunt", "beside a plain name word it is a name")
    H.assertEq(grunt[1].mapID, 1429)
end

function tests.aTownWordNarrowsToItsInn()
    local find = places()
    local rows = find("auberdine repair")
    H.assertEq(#rows, 1)
    H.assertEq(rows[1].name, "Bea")
    H.assertEq(find("auberdine inn")[1].name, "Dana", "inn is a service word")
    H.assertEq(#find("aube inn"), 1, "a prefix names it")
end

local pass, fail, failures = H.runSuite("GPSNpcs", tests)
return { pass = pass, fail = fail, failures = failures }

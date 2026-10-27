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

-- Numbers as little-endian strings of width bytes each.
local function bytes(width, list)
    local out = {}
    for _, v in ipairs(list) do
        for _ = 1, width do
            out[#out + 1] = string.char(v % 256)
            v = math.floor(v / 256)
        end
    end
    return table.concat(out)
end

-- Numbers as width byte planes: every low byte, then every next one.
local function planes(width, list)
    local out = {}
    for b = 0, width - 1 do
        for _, v in ipairs(list) do out[#out + 1] = string.char(math.floor(v / 256 ^ b) % 256) end
    end
    return table.concat(out)
end

local function lines(text)
    local out = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    return out
end

local function sortedKeys(set)
    local out = {}
    for key in pairs(set) do out[#out + 1] = key end
    table.sort(out)
    return out
end

-- Count lines as shipped: between newlines, with their starts; a line
-- left blank in own shows english's.
local function shipped(english, count, own)
    local en, mine, out = lines(english), own and lines(own) or {}, {}
    for i = 1, count do out[i] = (mine[i] and mine[i] ~= "") and mine[i] or en[i] or "" end
    local text, at = "\n" .. table.concat(out, "\n") .. "\n", { 2 }
    for i = 1, count do at[i + 1] = at[i] + #out[i] + 1 end
    return text, bytes(3, at)
end

-- What dev/tools/npc_plain.py marks a class's title by: the English class
-- names (and the client's own, none in these tests).
local CLASS_NAMES = { "warrior", "paladin", "hunter", "rogue", "priest", "shaman", "mage", "warlock", "druid",
                      "death knight", "monk", "demon hunter", "evoker" }

-- The catalog as dev/tools/npc_plain.py ships it, from creatures listed
-- as { id, flags, kind (type | expansion + 1 << 4 | roles << 8), display,
-- title, { map, xy, spawns per spot } }; the records in byte planes.
local function catalog(creatures, names, titles, localNames, localTitles)
    local spots, kinds, titleIdx, byTitle, byRole, types, expansions = {}, {}, {}, {}, {}, {}, {}
    local ids, flags, displays, firsts, counts = {}, {}, {}, {}, {}
    for i, c in ipairs(creatures) do
        local kind, title, sp = c[3], c[5], c[6]
        ids[i], flags[i], displays[i], firsts[i], counts[i] = c[1], c[2], c[4], #spots + 1, #sp / 3
        for s = 1, #sp, 3 do spots[#spots + 1] = bytes(2, { sp[s] }) .. bytes(3, { sp[s + 1] }) .. bytes(2, { sp[s + 2] }) end
        kinds[i], titleIdx[i] = kind, title
        if title > 0 then
            byTitle[title] = byTitle[title] or {}
            table.insert(byTitle[title], i)
        end
        local roles, role = math.floor(kind / 256), 1
        while role <= roles do
            if math.floor(roles / role) % 2 == 1 then
                byRole[role] = byRole[role] or {}
                table.insert(byRole[role], i)
            end
            role = role * 2
        end
        types[kind % 16] = true
        expansions[math.floor(kind / 16) % 16 - 1] = true
    end
    local rec = planes(3, ids) .. planes(1, flags) .. planes(3, displays) .. planes(3, firsts) .. planes(2, counts)
    local at, titled, titleCount = {}, {}, #lines(titles)
    for t = 1, titleCount do
        at[t] = #titled
        for _, i in ipairs(byTitle[t] or {}) do titled[#titled + 1] = i end
    end
    at[titleCount + 1] = #titled
    local data = { rec = rec, spots = table.concat(spots), kinds = bytes(3, kinds),
                   titleIdx = bytes(2, titleIdx), titleAt = bytes(3, at), titleCreatures = bytes(3, titled),
                   roles = {}, kindTypes = sortedKeys(types), kindExpansions = sortedKeys(expansions),
                   titleName = lines(titles), classTitle = {} }
    for t, title in ipairs(data.titleName) do
        for _, class in ipairs(CLASS_NAMES) do
            if title:lower():find(class, 1, true) then data.classTitle[t] = true end
        end
    end
    if localTitles then data.localTitleName = lines(localTitles) end
    for role, list in pairs(byRole) do data.roles[role] = bytes(3, list) end
    data.names, data.nameAt = shipped(names, #creatures)
    if localNames then
        data.localNames, data.localNameAt = shipped(names, #creatures, localNames)
    end
    return data
end

-- What vendors sell, as shipped, from per item its weapon type + 1 (0
-- none), the stock lists (items) and per creature the list it sells.
local function addGoods(data, goods, count)
    local items, listsOf, at, ids = #goods.types, {}, {}, {}
    for l, list in ipairs(goods.lists) do
        for _, j in ipairs(list) do
            listsOf[j] = listsOf[j] or {}
            table.insert(listsOf[j], l)
        end
    end
    for j = 1, items do
        at[j] = #ids
        for _, l in ipairs(listsOf[j] or {}) do ids[#ids + 1] = l end
    end
    at[items + 1] = #ids
    local types, typeIds, sells, vendors = {}, {}, {}, {}
    for j, t in ipairs(goods.types) do
        types[j] = string.char(t)
        if t > 0 then typeIds[t - 1] = true end
    end
    for i = 1, count do
        sells[i] = goods.sells[i] or 0
        if goods.sells[i] then vendors[#vendors + 1] = i end
    end
    data.goodsTypes, data.goodsTypeIds = table.concat(types), sortedKeys(typeIds)
    data.goodsListAt, data.goodsLists = bytes(3, at), bytes(2, ids)
    data.sells, data.vendors = bytes(2, sells), bytes(3, vendors)
    data.goodsNames, data.goodsNameAt = shipped(goods.names, items)
    if goods.localNames then
        data.localGoods, data.localGoodsAt = shipped(goods.names, items, goods.localNames)
    end
end

-- Four creatures in id order.
local CREATURES = {
    { 6, 80, 7 + 16, 327, 0, { 1429, xy(0.5, 0.5), 10, 1433, xy(0.1, 0.1), 3 } },  -- Kobold Vermin, hostile to both
    { 448, 17, 1 + 16, 384, 0, { 1429, xy(0.3, 0.4), 1 } },                        -- Hogger, beast, elite
    { 639, 0, 7 + 16 + 256, 0, 0, { 0, 36, 1 } },                                  -- Edwin VanCleef, quests, no model
    { 1076, 0, 7 + 32 + 512, 2160, 1, { 1426, xy(0.2, 0.3), 1 } },                 -- Brog Hamfist, vendor, TBC
}

-- Two danger cells (a quarter tile a side) on continent 0, the walking
-- tiles 2079 and 2080: cell 32894 hostile from level 60 to both factions,
-- cell 32896 from level 20 to the Alliance and 0 (none) to the Horde.
local DANGER = varints({ 2, 32894, 60, 60, 2, 20, 0 })

local function fresh(localNames, creatures, names, goods, noLoad, titles, localTitles)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { forever = true }
    local function vec(x, y) return { x = x, y = y, GetXY = function(self) return self.x, self.y end } end
    env.CreateVector2D = vec
    env.unpacked = 0
    env.C_EncodingUtil = { DecodeBase64 = function(s) return s end,
                           DecompressString = function(s) env.unpacked = env.unpacked + 1 return s end }
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
    creatures = creatures or CREATURES
    ns.NPC_DATA = catalog(creatures, names or "Kobold Vermin\nHogger\nEdwin VanCleef\nBrog Hamfist",
                          titles or "General Supplies", localNames, localTitles)
    ns.NPC_DATA.danger = { [0] = DANGER }
    ns.NPC_DATA.types = { [1] = "Beast", [7] = "Humanoid" }
    if goods then addGoods(ns.NPC_DATA, goods, #creatures) end
    env.EasyFind.db = {}
    ns.L.NPC_SELLS = "Sells %s"
    H.loadModule("Apps/GPS/Npcs.lua", env, ns)
    if not noLoad then ns.GPSNpcs.Load(); ns.GPSNpcs.LoadGoods() end
    return ns.MapSearch.AppendNpcRows, ns.GPSNpcs, env
end

-- Vendors around a player standing at 0.31, 0.41 of map 1429, the
-- Alliance: count repairers named "Arnold N" far off, one named
-- "Bea Longername" beside the player, "Cid" repairing for the Horde only,
-- and "Dana" selling food.
local REPAIR = 7 + 16 + (2 + 256) * 256
local function vendors(count, extra)
    local list, names = {}, {}
    local function add(name, flags, kind, x, y)
        list[#list + 1] = { #list + 1, flags, kind, 0, 0, { 1429, xy(x, y), 1 } }
        names[#names + 1] = name
    end
    for k = 1, count - 1 do add("Arnold " .. k, 0, REPAIR, 0.9, 0.9) end
    add("Bea Longername", 0, REPAIR, 0.32, 0.42)
    add("Cid", 2 * 8, REPAIR, 0.31, 0.41)
    add("Dana", 0, 7 + 16 + (2 + 512) * 256, 0.5, 0.5)
    for _, name in ipairs(extra or {}) do add(name, 0, 7 + 16, 0.31, 0.41) end
    local append, _, env = fresh(nil, list, table.concat(names, "\n"))
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

-- Each spot map's world plane (npc_planes.py) stands in for the client's
-- map to world call: the same rows, and no call per spot (the first
-- "vendor" made 1175 of them).
function tests.spotPlanes_sameRowsWithoutAClientCallPerSpot()
    local function run(withPlanes)
        local list, names = {}, {}
        for k = 1, 12 do
            list[k] = { k, 0, REPAIR, 0, 0, { 1429, xy(0.05 * k, 0.9 - 0.05 * k), 1 } }
            names[k] = "Smith " .. k
        end
        local append, N, env = fresh(nil, list, table.concat(names, "\n"), nil, true)
        env.UnitFactionGroup = function() return "Alliance" end
        local calls = 0
        -- The client's axes: world x from the map's y, world y from its x.
        env.C_Map.GetWorldPosFromMapPos = function(_, v)
            calls = calls + 1
            return 0, env.CreateVector2D(500 - 2000 * v.y, 900 - 3000 * v.x)
        end
        if withPlanes then env.EasyFind._ns.NPC_DATA.planes = { [1429] = { 0, 500, -2000, 900, -3000 } } end
        N.Load()
        N.LoadGoods()
        local out = {}
        append(out, nil, "repair", nil, 1429)
        local seen = {}
        for i, r in ipairs(out) do seen[i] = r.name end
        return table.concat(seen, ","), calls
    end
    local client, clientCalls = run(false)
    local planed, planedCalls = run(true)
    H.assertEq(planed, client, "the same rows in the same order")
    H.assertTrue(clientCalls > 10, "without planes a call per spot: " .. clientCalls)
    H.assertEq(planedCalls, 1, "with planes only the player's own position")
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
    H.assertTrue(low[2080] and low[2079], "level 15: both tiles con orange or red")
    local mid = Npcs.DangerTiles(18, "Alliance")[0]
    H.assertNil(mid[2080], "level 18: 20 is only yellow")
    H.assertTrue(mid[2079])
    H.assertNil(Npcs.DangerTiles(15, "Horde")[0][2080], "nothing there is hostile to the Horde")
    H.assertNil(Npcs.DangerTiles(60, "Horde")[0][2079], "at 60 nothing is")
end

-- A walk 400 yd north across the world origin: cell 32896 (Alliance
-- threat 20) its first 133 yd, an unlisted cell next, cell 32894 (60) its
-- last 133. Red from five levels under a threat, skull from ten; read
-- every 16 yd or so.
function tests.deadlyAlong_redAndSkullStretches()
    local _, Npcs = fresh()
    local function walk() return { pts = { -133, 0, 267, 0 }, cum = { 0, 400 }, len = 400 } end
    H.assertEq(Npcs.CellOf(-100, 0), 32896)
    H.assertEq(Npcs.CellOf(200, 0), 32894)
    local d = Npcs.DeadlyAlong(walk(), 0, 15, "Alliance")
    H.assertEq(d.n, 4, "two stretches")
    H.assertEq(d[1], 0)
    H.assertTrue(math.abs(d[2] - 133) < 16 and math.abs(d[3] - 267) < 16, d[2] .. ", " .. d[3])
    H.assertEq(d[4], 400)
    H.assertTrue(math.abs(d.skull - 267) < 16 and math.abs(d.sx - 133) < 16, "the skull met at the second")
    d = Npcs.DeadlyAlong(walk(), 0, 18, "Alliance")
    H.assertEq(d.n, 2, "at 18 the first is only orange")
    d = Npcs.DeadlyAlong(walk(), 0, 52, "Alliance")
    H.assertEq(d.n, 2)
    H.assertNil(d.skull, "at 52 nothing is ten above")
    local path = walk()
    H.assertTrue(Npcs.DeadlyAlong(path, 0, 15, "Alliance") == Npcs.DeadlyAlong(path, 0, 15, "Alliance"), "kept on the walk")
    H.assertNil(Npcs.DeadlyAlong(walk(), 1, 15, "Alliance"), "no danger map for that continent")
end

-- Guards hostile to a faction (2026-10-26, a Horde walk through
-- Stormwind drawn safe): their cell is red at any level and met as guard
-- ground, never walked around.
function tests.deadlyAlong_enemyGuardsAtAnyLevel()
    local _, Npcs, env = fresh()
    env.EasyFind._ns.NPC_DATA.guards = { [0] = varints({ 1, 32896, 2 }) }
    local function walk() return { pts = { -133, 0, 267, 0 }, cum = { 0, 400 }, len = 400 } end
    local d = Npcs.DeadlyAlong(walk(), 0, 70, "Horde")
    H.assertEq(d.n, 2, "the guarded cell is red at 70")
    H.assertEq(d[1], 0)
    H.assertTrue(math.abs(d[2] - 133) < 16, tostring(d[2]))
    H.assertTrue(d.guard ~= nil and d.guard < 16, "met at the start")
    H.assertNil(d.skull)
    local a = Npcs.DeadlyAlong(walk(), 0, 70, "Alliance")
    H.assertNil(a.guard, "its own faction's guards")
    H.assertEq(a.n, 0)
    H.assertNil(Npcs.DangerTiles(70, "Horde")[0][2080], "never walked around")
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

function tests.aServiceWordWantsWhoOffersIt_notANameHoldingIt()
    local rows = find(vendors(3, { "Repaired Bomber" }), "repair")
    H.assertNil(named(rows, "Repaired Bomber"), "does not repair, so not for repair")
    H.assertEq(#rows, 3, "the repairers")
    H.assertEq(find(vendors(3, { "Repaired Bomber" }), "repaired bomber")[1].name, "Repaired Bomber",
        "its own name still finds it")
end

-- More matches than are handed over: the nearest of equal ones get in,
-- not the shortest names.
function tests.pastTheCapTheNearestGetIn()
    local rows = find(vendors(80), "repair")
    H.assertEq(#rows, 60)
    H.assertEq(rows[1].name, "Bea Longername")
end

-- Water and arrows on one shared list, sold by the Kobold Vermin (hostile
-- to the Alliance) and Brog Hamfist.
local GOODS = {
    types = { 0, 0 }, lists = { { 1, 2 } }, sells = { [1] = 1, [4] = 1 },
    names = "Refreshing Spring Water\nSharp Arrow",
}
-- Nothing to unpack: the first query reads the catalog where it ships.
function tests.theFirstQueryFindsWithNothingUnpacked()
    local append, N, env = fresh(nil, nil, nil, GOODS, true)
    H.assertTrue(N.n == nil, "nothing read before a query")
    H.assertEq(#find(append, "hogger"), 1, "found on the first query")
    H.assertEq(#find(append, "sharp arrow"), 1, "and what vendors sell")
    H.assertEq(env.unpacked, 0, "nothing unpacked")
end

local function goodsNamed(names, localNames)
    return { types = GOODS.types, lists = GOODS.lists, sells = GOODS.sells, names = names, localNames = localNames }
end

-- The lowercase texts and English titles are made at load, not shipped.
function tests.localTitlesFind_andEnglishTitlesStillFind()
    local goods = goodsNamed(GOODS.names, "Quellwasser\n")
    local append, N = fresh("Koboldungeziefer\n\n\n", nil, nil, goods, nil, "General Supplies", "Gemischtwaren")
    H.assertEq(N.titleName[1], "Gemischtwaren")
    H.assertEq(N.titleLow[1], "gemischtwaren")
    H.assertEq(N.titleEnglish[1], "General Supplies")
    H.assertEq(N.titleLowEnglish[1], "general supplies")
    H.assertEq(N.low, "\nkoboldungeziefer\nhogger\nedwin vancleef\nbrog hamfist\n")
    H.assertEq(N.enLow, "\nkobold vermin\nhogger\nedwin vancleef\nbrog hamfist\n")
    H.assertEq(N.goodsLow, "\nquellwasser\nsharp arrow\n")
    H.assertEq(N.goodsEnLow, "\nrefreshing spring water\nsharp arrow\n")
    H.assertEq(find(append, "gemischt")[1].name, "Brog Hamfist", "the client's title finds")
    H.assertEq(find(append, "general supplies")[1].name, "Brog Hamfist", "and the English one")
end

-- The line-start tables are made at load from the names' newlines, the
-- same bytes the catalog used to ship (2026-10-27: 1.6 MiB zipped over
-- the clients): names, local names and goods all find without them.
function tests.lineStartsMadeAtLoad_findTheSameRows()
    local append, Npcs, env = fresh("Koboldungeziefer\n\n\n", nil, nil, GOODS, true)
    local data = env.EasyFind._ns.NPC_DATA
    local shippedAt, shippedGoodsAt = data.nameAt, data.goodsNameAt
    data.nameAt, data.localNameAt, data.goodsNameAt, data.localGoodsAt = nil, nil, nil, nil
    H.assertTrue(Npcs.Load() and Npcs.LoadGoods(), "binds with no tables shipped")
    H.assertEq(find(append, "hog")[1].npcID, 448)
    H.assertEq(find(append, "vermin")[1].name, "Koboldungeziefer", "the client's language shows")
    H.assertEq(find(append, "hogger")[1].name, "Hogger", "a blank local line falls back to English")
    H.assertEq(find(append, "sharp arrow")[1].matchNote, "Sells Sharp Arrow", "goods find too")
    -- The same bytes as shipped, so every reader of them is unchanged.
    local N = env.EasyFind._ns.GPSNpcs
    H.assertTrue(N.LineStarts ~= nil, "exposed for this check")
    H.assertEq(N.LineStarts(data.names), shippedAt)
    H.assertEq(N.LineStarts(data.goodsNames), shippedGoodsAt)
end

-- The login warm fills the tables before any query, the same bytes; a
-- catalog already bound is left alone.
function tests.loginWarm_fillsTheTablesAhead()
    local append, Npcs, env = fresh("Koboldungeziefer\n\n\n", nil, nil, GOODS, true)
    local data = env.EasyFind._ns.NPC_DATA
    local shippedAt, shippedLocalAt, shippedGoodsAt = data.nameAt, data.localNameAt, data.goodsNameAt
    data.nameAt, data.localNameAt, data.goodsNameAt, data.localGoodsAt = nil, nil, nil, nil
    Npcs.Warm()
    H.assertEq(data.nameAt, shippedAt, "English names")
    H.assertEq(data.localNameAt, shippedLocalAt, "the client's names")
    H.assertEq(data.goodsNameAt, shippedGoodsAt, "goods")
    H.assertTrue(Npcs.Load() and Npcs.LoadGoods())
    H.assertEq(find(append, "vermin")[1].name, "Koboldungeziefer")
end

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
    local append = fresh(nil, nil, nil, goodsNamed("Refreshing Spring Water\nBrog Arrow"))
    local rows = find(append, "brog")
    H.assertEq(rows[1].name, "Brog Hamfist")
    H.assertEq(rows[1].soldName, "Brog Arrow", "found by name, and the item named")
    H.assertEq(#rows, 1, "the kobold sells it too, but only an item match would bring it and it will not serve")
    H.assertNil(find(append, "rog")[1].soldName, "inside a word of the item: no note")
end

-- Water and a Worn Shortbow (bows, subclass 2) sold by Brog Hamfist, a
-- Light Crossbow (subclass 18) by Edwin VanCleef.
local WEAPONS = {
    types = { 0, 3, 19 }, lists = { { 1, 2 }, { 3 } }, sells = { [3] = 2, [4] = 1 },
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
    local append = fresh(nil, nil, nil, { types = WEAPONS.types, lists = WEAPONS.lists, sells = WEAPONS.sells,
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
    local append = fresh(nil, nil, nil, goodsNamed(GOODS.names, "Erfrischendes Quellwasser\nScharfer Pfeil"))
    local rows = find(append, "pfeil")
    H.assertEq(rows[1].matchNote, "Sells Scharfer Pfeil", "the client's language shows")
    H.assertEq(find(append, "sharp")[1].name, "Brog Hamfist", "English still finds")
end

-- Repairers on two maps, an innkeeper, a grunt named after Orgrimmar and
-- a vendor on a third map; "org" names map 1433, Auberdine's inn is where
-- Bea stands.
local INN = 7 + 16 + 16 * 256
local function places()
    local list, names = {}, {}
    local function add(name, kind, m, x, y)
        list[#list + 1] = { #list + 1, 0, kind, 0, 0, { m, xy(x, y), 1 } }
        names[#names + 1] = name
    end
    add("Arnold", REPAIR, 1429, 0.9, 0.9)
    add("Bea", REPAIR, 1433, 0.1, 0.1)
    add("Dana", INN, 1433, 0.12, 0.1)
    add("Orgrimmar Grunt", 7 + 16, 1429, 0.5, 0.5)
    add("Ed", 7 + 16 + 2 * 256, 1426, 0.5, 0.5)
    local append, _, env = fresh(nil, list, table.concat(names, "\n"))
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

-- A trainer titled after a class is a class trainer, whatever its name;
-- a cooking trainer is not.
function tests.classTrainersByTheirTitle()
    local trainer = 7 + 16 + 4 * 256
    local append = fresh(nil, { { 1, 0, trainer, 0, 1, { 1429, xy(0.3, 0.4), 1 } },
                                { 2, 0, trainer, 0, 2, { 1429, xy(0.5, 0.5), 1 } } },
                         "Jennea\nBob", nil, nil, "Mage Trainer\nCooking Trainer")
    local rows = find(append, "class")
    H.assertEq(#rows, 1)
    H.assertEq(rows[1].name, "Jennea")
    H.assertEq(#find(append, "class trainer"), 1)
    H.assertEq(find(append, "cooking trainer")[1].name, "Bob")
end

-- Every shipped catalog file is in the form read where it ships
-- (dev/tools/npc_plain.py): no base64 part a first query would unpack.
function tests.shippedCatalog_readInPlace()
    local names = {}
    for _, flavor in ipairs({ "Retail", "Era", "TBC", "Forever" }) do
        names[#names + 1] = flavor
        for _, loc in ipairs({ "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }) do
            names[#names + 1] = flavor .. "_" .. loc
        end
    end
    for _, name in ipairs(names) do
        local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/Npcs_" .. name .. ".lua", "rb"))
        local src = f:read("*a")
        f:close()
        local isBase = not name:find("_")
        for _, field in ipairs(isBase and { "names = \"", "titleName = {", "classTitle = {", "planes = { [" }
                               or { "data.localNames = \"", "data.localTitleName = {", "data.classTitle = {" }) do
            H.assertTrue(src:find(field, 1, true) ~= nil, name .. " carries " .. field)
        end
        -- Made by Npcs.lua at load (npc_plain.py DERIVED_*): never shipped.
        for _, field in ipairs({ "Low = ", "titleEnglish = ", "data.titleName = " }) do
            H.assertNil(src:find(field, 1, true), name .. " ships " .. field)
        end
        for line in src:gmatch("[^\n]+") do
            local field = line:match('^%s*[%w%.]+ = "[%w+/=]+",?$')
            H.assertNil(field, name .. " ships a packed part: " .. line:sub(1, 40))
        end
    end
end

local pass, fail, failures = H.runSuite("GPSNpcs", tests)
return { pass = pass, fail = fail, failures = failures }

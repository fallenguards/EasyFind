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
    -- id, level, span, flags, kind (type | expansion + 1 << 4 | roles << 8), title, spots
    6, 1, 1, 80, 7 + 16, 0, 2, 1429, xy(0.5, 0.5), 10, 1433, xy(0.1, 0.1), 3,  -- Kobold Vermin, hostile to both
    442, 11, 0, 17, 1 + 16, 0, 1, 1429, xy(0.3, 0.4), 1,                       -- Hogger, beast, elite
    191, 25, 0, 0, 7 + 16 + 256, 0, 1, 0, 36, 1,                               -- Edwin VanCleef, quests
    437, 30, 0, 0, 7 + 32 + 512, 1, 1, 1426, xy(0.2, 0.3), 1,                  -- Brog Hamfist, vendor, TBC
})

-- Two tiles on continent 0: tile 3100 hostile from level 20 to the
-- Alliance and 0 (none) to the Horde, tile 3105 from level 60 to both.
local DANGER = varints({ 2, 3100, 20, 0, 5, 60, 60 })

local function fresh(localNames)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { forever = true }
    local function vec(x, y) return { x = x, y = y, GetXY = function(self) return self.x, self.y end } end
    env.CreateVector2D = vec
    env.C_EncodingUtil = { DecodeBase64 = function(s) return s end, DecompressString = function(s) return s end }
    env.C_Map = {
        GetBestMapForUnit = function() return 1429 end,
        GetPlayerMapPosition = function() return vec(0.31, 0.41) end,
        GetWorldPosFromMapPos = function(m, v) return (m == 1433 or m == 1429 or m == 1426) and 0 or 1, vec(v.x * 1000 + m, v.y * 1000) end,
        GetMapInfo = function(m) return { name = "Map " .. m } end,
    }
    ns.MapSearch = {}
    ns.MapSearchSearch = { PreparePOI = function(p) p.nameLower = string.lower(p.name) return p end }
    ns.FOREVER_INSTANCES = { { id = 36, n = "Deadmines", m = 1436, x = 0.38, y = 0.77, ci = 0, wx = -11208, wy = 1681 } }
    ns.NPC_DATA = { rows = ROWS, names = "Kobold Vermin\nHogger\nEdwin VanCleef\nBrog Hamfist",
                    titles = "General Supplies", localNames = localNames, danger = { [0] = DANGER },
                    types = { [1] = "Beast", [7] = "Humanoid" } }
    env.EasyFind.db = {}
    H.loadModule("Apps/GPS/Npcs.lua", env, ns)
    return ns.MapSearch.AppendNpcRows, ns.GPSNpcs, env
end

local function find(append, query, onlyMap)
    local out = {}
    append(out, {}, query, onlyMap)
    return out
end

local tests = {}

function tests.nameFindsTheCreatureOnItsSpot()
    local rows = find(fresh(), "hog")
    H.assertEq(#rows, 1)
    H.assertEq(rows[1].name, "Hogger")
    H.assertEq(rows[1].category, "npc")
    H.assertEq(rows[1].mapID, 1429)
    H.assertTrue(math.abs(rows[1].x - 0.3) < 0.001 and math.abs(rows[1].y - 0.4) < 0.001)
    H.assertEq(rows[1].npcID, 448)
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

local pass, fail, failures = H.runSuite("GPSNpcs", tests)
return { pass = pass, fail = fail, failures = failures }

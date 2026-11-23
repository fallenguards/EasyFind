-- A map place built from several NPCs of one kind sits on one of them
-- (2026-11-22): Thunder Bluff's Priest Trainer place was the middle point
-- of its three trainers, a spot in the Pools of Vision's rock where nobody
-- stands, and a route to it ended on the Spirit Rise above the cave.
local H = require("Harness")

local THUNDER_BLUFF = 1456
local ON_IT = 0.003    -- of the map: about three yards on Thunder Bluff's

local function Catalog()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { forever = true, instanceTable = true }
    local function vec(x, y) return { x = x, y = y, GetXY = function(self) return self.x, self.y end } end
    env.CreateVector2D = vec
    env.C_Item = { GetItemSubClassInfo = function() return nil end }
    -- Thunder Bluff's trainers serve the Horde only.
    env.UnitFactionGroup = function() return "Horde" end
    env.C_Map = {
        GetBestMapForUnit = function() return THUNDER_BLUFF end,
        GetPlayerMapPosition = function() return vec(0.5, 0.5) end,
        GetWorldPosFromMapPos = function(_, v) return 1, vec(v.x * 1000, v.y * 1000) end,
        GetMapInfo = function(m) return { name = "Map " .. m } end,
    }
    ns.MapSearch = {}
    ns.MapSearchSearch = { PreparePOI = function(p) p.nameLower = string.lower(p.name) return p end }
    ns.FOREVER_INSTANCES = {}
    env.EasyFind.db = {}
    H.loadModule("Database/Npcs_Forever.lua", env, ns)
    H.loadModule("MapSearch/Npcs.lua", env, ns)
    ns.Npcs.Load()
    return ns.MapSearch.AppendNpcRows
end

-- A category's place on a map in Forever's places: x, y.
local function Place(map, category)
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/StaticLocations_Forever.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("[" .. map .. "] = {", 1, true), "no places on map " .. map)
    local block = src:sub(s, src:find("\n    },", s, true))
    local x, y = block:match('category = "' .. category .. '", x = ([%d.]+), y = ([%d.]+)')
    return tonumber(x), tonumber(y)
end

local tests = {}

function tests.thunderBluffsClassTrainerPlaces_standOnATrainer()
    local append = Catalog()
    for _, class in ipairs({ "priest", "mage" }) do
        local px, py = Place(THUNDER_BLUFF, "classtrainer_" .. class)
        H.assertNotNil(px, class .. " trainer place")
        local rows = {}
        append(rows, {}, class .. " trainer", THUNDER_BLUFF)
        H.assertTrue(#rows >= 2, class .. ": several trainers there, " .. #rows .. " found")
        local nearest = math.huge
        for _, row in ipairs(rows) do
            if row.mapID == THUNDER_BLUFF then
                nearest = math.min(nearest, ((row.x - px) ^ 2 + (row.y - py) ^ 2) ^ 0.5)
            end
        end
        H.assertTrue(nearest <= ON_IT, ("%s trainer place at %.4f, %.4f is %.4f of the map from the nearest trainer")
            :format(class, px or 0, py or 0, nearest))
    end
end

local pass, fail, failures = H.runSuite("PlacesOnTheirNpcs", tests)
return { pass = pass, fail = fail, failures = failures }

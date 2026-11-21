-- A spawn in the world database can be one of several creatures. The
-- catalog once read only the first of them, so the others were in no list
-- (252 creatures, 2026-11-21).
local H = require("Harness")

local function Catalog()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { forever = true, instanceTable = true }
    local function vec(x, y) return { x = x, y = y, GetXY = function(self) return self.x, self.y end } end
    env.CreateVector2D = vec
    env.C_Item = { GetItemSubClassInfo = function() return nil end }
    env.C_Map = {
        GetBestMapForUnit = function() return 1434 end,
        GetPlayerMapPosition = function() return vec(0.5, 0.5) end,
        GetWorldPosFromMapPos = function(_, v) return 0, vec(v.x * 1000, v.y * 1000) end,
        GetMapInfo = function(m) return { name = "Map " .. m } end,
    }
    ns.MapSearch = {}
    ns.MapSearchSearch = { PreparePOI = function(p) p.nameLower = string.lower(p.name) return p end }
    ns.FOREVER_INSTANCES = {}
    env.EasyFind.db = {}
    H.loadModule("Database/Npcs_Forever.lua", env, ns)
    H.loadModule("MapSearch/Npcs.lua", env, ns)
    ns.Npcs.Load()
    return ns.Npcs
end

local tests = {}

function tests.aCreatureSharingItsSpawn_isListedWhereItStands()
    local N = Catalog()
    H.assertTrue(N.NamedOn("Bloodscalp Headhunter", { [1434] = true }) ~= nil, "in Stranglethorn Vale")
    H.assertTrue(N.NamedOn("Defias Looter", { [1436] = true }) ~= nil, "in Westfall")
    H.assertTrue(N.NamedOn("Cursed Mage", { [1423] = true }) ~= nil, "in the Eastern Plaguelands")
end

local pass, fail, failures = H.runSuite("ForeverSharedSpawns", tests)
return { pass = pass, fail = fail, failures = failures }

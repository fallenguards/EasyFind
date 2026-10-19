-- The developer docs stay true: every public function of EasyFind.API is
-- in the guide (API/README.md) and the editor annotations
-- (API/EasyFind_API.lua), and the guide's example extension runs.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local tests = {}

function tests.everyFunction_isInTheGuideAndAnnotations()
    local api, guide, meta = Read("Core/API.lua"), Read("API/README.md"), Read("API/EasyFind_API.lua")
    local missing = {}
    for name in api:gmatch("\nfunction API%.(%w+)%(") do
        local inGuide = guide:find("`" .. name .. "(", 1, true) or guide:find("### " .. name .. "(", 1, true)
        if not inGuide then missing[#missing + 1] = name .. " (guide)" end
        if not meta:find("function API." .. name .. "(", 1, true) then missing[#missing + 1] = name .. " (annotations)" end
    end
    H.assertEq(table.concat(missing, ", "), "", "documented")
end

-- The example, loaded on the real API with a player standing in a zone.
local function LoadExample()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.InCombatLockdown = function() return false end
    env.geterrorhandler = function() return function(e) error(e) end end
    local captured = {}
    ns.Database.AddDynamicProvider = function(_, p) captured.provider = p end
    ns.Database.ReplaceCategoryEntries = function(_, _, rows)
        captured.rows = rows
        return rows ~= nil
    end
    env.C_Map = {
        GetBestMapForUnit = function() return 1429 end,
        GetPlayerMapPosition = function() return { GetXY = function() return 0.42, 0.65 end } end,
        GetMapInfo = function() return { name = "Elwynn Forest" } end,
    }
    env.GetZoneText = function() return "Elwynn Forest" end
    env.GetSubZoneText = function() return "Goldshire" end
    local printed = {}
    env.print = function(s) printed[#printed + 1] = s end
    H.loadModule("API/example/EasyFind_Bookmarks/Bookmarks.lua", env, ns)
    return env, ns, env.EasyFind.API, captured, printed
end

function tests.example_registersAndWorks()
    local _, ns, API, captured, printed = LoadExample()
    H.assertTrue(API.IsExtensionRegistered("bookmarks"))
    H.assertEq(ns.Extensions.Get("bookmarks").scope, "bookmarks")
    local mark = API.CallAction("bookmarks", "add", "Home")
    H.assertEq(mark.name, "Home")
    H.assertTrue(captured.provider.fn(ns.Database))
    H.assertEq(captured.rows[1].name, "Home")
    H.assertEq(captured.rows[1].nameLower, "home", "searchable")
    local went
    API.RegisterAction("gps", "navigate", function(dest) went = dest end)
    ns.Extensions.SelectRow(captured.rows[1], function() end)
    H.assertEq(went and went.mapID, 1429, "a click asks the GPS")
    API.Fire("gps", "arrived", { name = "Home", mapID = 1429 })
    H.assertTrue((printed[1] or ""):find("Home", 1, true) ~= nil, "it hears the GPS arrive")
end

local pass, fail, failures = H.runSuite("APIDocs", tests)
return { pass = pass, fail = fail, failures = failures }

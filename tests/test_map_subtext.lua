-- Tests for a map row's subtext (Search/Results/RowText.lua): its kind, then
-- the place it is in.

local H = require("Harness")
local env = H.newEnv()
env._G = env
env.ZONE, env.CONTINENT, env.LFG_TYPE_DUNGEON, env.WORLD_MAP = "Zone", "Continent", "Dungeon", "Map"
env.MINIMAP_TRACKING_FLIGHTMASTER = "Flight Master"
env.Enum = env.Enum or {}
env.Enum.UIMapType = env.Enum.UIMapType or { Continent = 2, Zone = 3 }
local ns = H.newNs(env)
ns.Utils.sformat = ns.Utils.sformat or string.format
H.loadModule("Search/Results/RowText.lua", env, ns)
local Text = ns.ResultText

local tests = {}

function tests.mapRows_leadWithTheirKind()
    H.assertEq(Text:GetFlatSubtext({ mapSearchResult = true, category = "npc", zoneName = "Elwynn Forest" }),
        "MAP_KIND_NPC: Elwynn Forest")
    H.assertEq(Text:GetFlatSubtext({ mapSearchResult = true, category = "zone", pathPrefix = "Azeroth > Eastern Kingdoms" }),
        "Zone: Eastern Kingdoms")
    H.assertEq(Text:GetFlatSubtext({ mapSearchResult = true, category = "dungeon", zoneName = "Westfall" }),
        "Dungeon: Westfall")
    H.assertEq(Text:GetFlatSubtext({ mapSearchResult = true, category = "flightmaster", zoneName = "Stormwind City" }),
        "Flight Master: Stormwind City")
    H.assertEq(Text:GetFlatSubtext({ mapSearchResult = true, category = "prof_blacksmithing", zoneName = "Ironforge" }),
        "MAP_KIND_PROF_TRAINER: Ironforge")
end

function tests.mapRows_withoutAPlace_showTheKindAlone()
    H.assertEq(Text:GetFlatSubtext({ mapSearchResult = true, category = "zone", zoneMapType = 2 }), "Continent")
    H.assertEq(Text:GetFlatSubtext({ mapSearchResult = true, category = "npc" }), "MAP_KIND_NPC")
end

function tests.mapRows_ofAnUnnamedKind_keepThePlace()
    H.assertEq(Text:GetFlatSubtext({ mapSearchResult = true, category = "lorewalker", zoneName = "Valdrakken" }),
        "Valdrakken")
end

local pass, fail, failures = H.runSuite("MapSubtext", tests)
return { pass = pass, fail = fail, failures = failures }

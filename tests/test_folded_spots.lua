-- A folded map row (one name, several places: a flight master scanned at
-- continent and zone level) pins only its spots on the viewed map
-- (MapSearch.SpotsOnMap, MapSearch/Navigation.lua). Drawn whole, each
-- spot's x and y from another map landed on the viewed one. Creatures no
-- longer fold at all (test_creature_rows_apart).
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function SpotsOnMap()
    local src = Read("MapSearch/Navigation.lua")
    local s = assert(src:find("function MapSearch.SpotsOnMap", 1, true), "SpotsOnMap")
    local e = select(2, assert(src:find("\nend\n", s, true)))
    local env = setmetatable({ MapSearch = {} }, { __index = _G })
    assert(load(src:sub(s, e), "=Navigation.lua SpotsOnMap", "t", env))()
    return env.MapSearch.SpotsOnMap
end

local tests = {}

function tests.onlyTheViewedMapsSpots()
    local here = { x = 0.4, y = 0.5, coordMapID = 51 }
    local away = { x = 0.6, y = 0.2, coordMapID = 17 }
    local spots = SpotsOnMap()({ away, here }, 51)
    H.assertEq(#spots, 1)
    H.assertEq(spots[1], here)
end

function tests.aSpotWithNoMapIsTheViewedOnes()
    local local1 = { x = 0.1, y = 0.1 }
    local entrance = { x = 0.3, y = 0.3, entranceMapID = 51, coordMapID = 17 }
    local spots = SpotsOnMap()({ local1, entrance }, 51)
    H.assertEq(#spots, 2, "the entrance's map decides, as the preview's did")
end

function tests.noneHereGivesNone()
    local spots = SpotsOnMap()({ { x = 0.5, y = 0.5, coordMapID = 17 }, { x = 0.2, y = 0.9, coordMapID = 85 } }, 51)
    H.assertEq(#spots, 0)
end

-- The click and the hover preview narrow through it; nothing hands a
-- folded set to the multi-pin drawer whole.
function tests.everyFoldedSetIsNarrowedBeforeItIsDrawn()
    local nav, preview = Read("MapSearch/Navigation.lua"), Read("MapSearch/Preview.lua")
    H.assertTrue(nav:find("MapSearch.SpotsOnMap(spots, WorldMapFrame:GetMapID())", 1, true) ~= nil, "the click narrows")
    H.assertTrue(preview:find("MapSearch.SpotsOnMap(data.allInstances, currentMapID)", 1, true) ~= nil, "the preview narrows")
    local p = assert(io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "*.lua"'))
    local bad = {}
    for path in p:lines() do
        if not (path:find("^tests/") or path:find("^dev/")) then
            local n = 0
            for line in Read(path):gmatch("([^\n]*)\n?") do
                n = n + 1
                local code = line:gsub("%-%-.*$", "")
                if code:find("ShowMultipleWaypoints%([%w_.:]*allInstances") or code:find("GetNearestInstance%([%w_.:]*allInstances") then
                    bad[#bad + 1] = path .. ":" .. n .. ": " .. line:gsub("^%s+", "")
                end
            end
        end
    end
    p:close()
    H.assertEq(#bad, 0, "narrow a folded set with MapSearch.SpotsOnMap first:\n  " .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("FoldedSpots", tests)
return { pass = pass, fail = fail, failures = failures }

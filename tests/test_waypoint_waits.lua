-- The game's waypoint and super-track, changed from our code only with the
-- world map closed (MapSearch.WaypointChange, MapSearch/Navigation.lua).
-- Under an open map the client rebuilds its waypoint pin inside our call, in
-- our name, and then refuses the pin's Shift-click share (CopyToClipboard,
-- blamed on EasyFind_GPS, 2026-10-26).
local H = require("Harness")

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Navigation.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local WAYPOINT_WAIT_ORDER", 1, true))
    local at = assert(src:find("local function RunWaypointWaits", s, true))
    local _, e = assert(src:find("\nend\r?\n", at))
    local map = { shown = false }
    function map:IsShown() return self.shown end
    local MapSearch = {}
    local env = setmetatable({ WorldMapFrame = map, MapSearch = MapSearch }, { __index = _G })
    local run = assert(load(src:sub(s, e) .. "\nreturn RunWaypointWaits", "=Navigation.lua waits", "t", env))()
    return MapSearch, map, run
end

local tests = {}

function tests.mapClosed_aChangeHappensAtOnce()
    local MS = Load()
    local done = false
    MS.WaypointChange("place", function() done = true end)
    H.assertTrue(done)
end

function tests.mapOpen_changesWaitForItToClose_inOrder_latestOfEach()
    local MS, map, run = Load()
    map.shown = true
    local log = {}
    MS.WaypointChange("track", function() log[#log + 1] = "track on" end)
    MS.WaypointChange("place", function() log[#log + 1] = "place A" end)
    MS.WaypointChange("place", function() log[#log + 1] = "place B" end)
    MS.WaypointChange("quest", function() log[#log + 1] = "quest" end)
    H.assertEq(#log, 0, "nothing under the open map")
    map.shown = false
    run()
    H.assertEq(table.concat(log, ", "), "place B, quest, track on")
    run()
    H.assertEq(#log, 3, "each once")
end

function tests.aDroppedPlacement_neverLands()
    local MS, map, run = Load()
    map.shown = true
    local placed = false
    MS.WaypointChange("place", function() placed = true end)
    MS.DropWaypointChange("place")
    map.shown = false
    run()
    H.assertFalse(placed, "a route cleared under the map leaves no pin behind")
end

-- Every call that changes the game's waypoint or super-track goes through
-- the waits; the one inside them is the only bare call.
local CALLS = { "SetUserWaypoint%(", "SetSuperTracked%w*%(", "ClearAllSuperTrackedVignettes%(" }
local ALLOWED = { ["MapSearch/Navigation.lua:        SetUserWaypoint(point)"] = true }

function tests.noBareWaypointChangesOutsideTheWaits()
    local p = assert(io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "*.lua"'))
    local bad = {}
    for path in p:lines() do
        if not (path:find("^tests/") or path:find("^dev/") or path:find("^API/example/")) then
            local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
            local n = 0
            for line in f:read("*a"):gmatch("([^\n]*)\n?") do
                n = n + 1
                line = line:gsub("\r$", "")
                local code = line:gsub("%-%-.*$", "")
                for _, call in ipairs(CALLS) do
                    if code:find(call) and not code:find("WaypointChange%(") and not code:find("GamePinChange%(")
                        and not code:find("^%s*local ") and not ALLOWED[path .. ":" .. line] then
                        bad[#bad + 1] = path .. ":" .. n .. ": " .. line:gsub("^%s+", "")
                    end
                end
            end
            f:close()
        end
    end
    p:close()
    H.assertEq(#bad, 0, "change the game's waypoint through MapSearch.WaypointChange:\n  " .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("WaypointWaits", tests)
return { pass = pass, fail = fail, failures = failures }

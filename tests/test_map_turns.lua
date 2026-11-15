-- The world map turned only through MapSearch.TurnMap (MapSearch/Navigation.lua):
-- the client's own C_Map.OpenWorldMap where it exists. A bare SetMapID from
-- addon code leaves the map's zone the addon's for the session, and the map's
-- own open then runs as the addon's from the compare: PerformEmote refused on
-- every map key press, the pins' SetPassThroughButtons in a fight, the
-- waypoint pin's share (Forever, 2026-11-09; /efd mapopen proved the door, and
-- that the client refuses the open in a fight: the turn waits for its end).
-- Opening it is the client's open too (MapSearch.OpenMap): a bare
-- ToggleWorldMap from addon code built the waypoint pin in the addon's name
-- and its Shift-click share was refused (Forever, 2026-11-15).
local H = require("Harness")

local function Load(openWorldMap)
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Navigation.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local OpenWorldMap = C_Map.OpenWorldMap", 1, true))
    local at = assert(src:find("fightWatch:SetScript(\"OnEvent\"", s, true))
    local _, e = assert(src:find("\nend%)\r?\n", at))
    local t = { log = {}, fighting = false, shown = true, events = {}, mapID = 1411 }
    local map = {}
    function map:SetMapID(id) t.log[#t.log + 1] = "set " .. id; t.mapID = id end
    function map:IsShown() return t.shown end
    function map:GetMapID() return t.mapID end
    local watch = {}
    function watch:RegisterEvent(ev) t.events[ev] = true end
    function watch:UnregisterEvent(ev) t.events[ev] = nil end
    function watch:SetScript(_, fn) t.onEvent = fn end
    local MapSearch = {}
    local env = setmetatable({
        WorldMapFrame = map, MapSearch = MapSearch,
        CreateFrame = function() return watch end,
        InCombatLockdown = function() return t.fighting end,
        ToggleWorldMap = function() t.log[#t.log + 1] = "toggle"; t.shown = not t.shown end,
        -- From a timer the client's open leaves a shut map shut (/efd mapopen).
        C_Map = { OpenWorldMap = openWorldMap and function(id)
            t.log[#t.log + 1] = "open " .. tostring(id)
            if t.shown or not t.noKeyPress then t.shown, t.mapID = true, id or t.mapID end
        end or nil },
    }, { __index = _G })
    assert(load(src:sub(s, e), "=Navigation.lua TurnMap", "t", env))()
    t.MapSearch = MapSearch
    t.fightEnds = function() t.onEvent(watch, "PLAYER_REGEN_ENABLED") end
    return t
end

local tests = {}

function tests.theClientsOwnOpenWhereItHasOne()
    local t = Load(true)
    H.assertTrue(t.MapSearch.TurnMap(1458))
    H.assertEq(table.concat(t.log, ", "), "open 1458")
end

function tests.setMapIDOnlyWhereTheClientHasNoOpen()
    local t = Load(false)
    H.assertTrue(t.MapSearch.TurnMap(1458))
    H.assertEq(table.concat(t.log, ", "), "set 1458")
end

function tests.noMapNoTurn()
    local t = Load(true)
    H.assertFalse(t.MapSearch.TurnMap(nil))
    H.assertEq(#t.log, 0)
end

-- In a fight nothing is called (the client refuses the open, blamed on the
-- caller); the latest turn asked for runs as the fight ends, the map still up.
function tests.inAFight_theTurnWaitsForItsEnd()
    local t = Load(true)
    t.fighting = true
    H.assertFalse(t.MapSearch.TurnMap(1458))
    H.assertFalse(t.MapSearch.TurnMap(1411))
    H.assertEq(#t.log, 0, "nothing in the fight")
    H.assertTrue(t.events.PLAYER_REGEN_ENABLED, "listening for the fight's end")
    t.fighting = false
    t.fightEnds()
    H.assertEq(table.concat(t.log, ", "), "open 1411", "the latest turn, once")
    H.assertNil(t.events.PLAYER_REGEN_ENABLED, "the listener is gone")
end

function tests.aMapClosedDuringTheFight_isLeftAlone()
    local t = Load(false)
    t.fighting = true
    t.MapSearch.TurnMap(1458)
    t.fighting = false
    t.shown = false
    t.fightEnds()
    H.assertEq(#t.log, 0)
end

function tests.open_theClientsOwnOpen_onTheMapAskedFor()
    local t = Load(true)
    t.shown = false
    H.assertTrue(t.MapSearch.OpenMap(1458))
    H.assertEq(table.concat(t.log, ", "), "open 1458")
    t.log = {}
    H.assertTrue(t.MapSearch.OpenMap(1458))
    H.assertEq(#t.log, 0, "open on that map already: nothing")
end

function tests.open_withNoKeyPressBehindIt_theToggleOpensIt()
    local t = Load(true)
    t.shown, t.noKeyPress = false, true
    H.assertTrue(t.MapSearch.OpenMap(1458))
    H.assertEq(table.concat(t.log, ", "), "open 1458, toggle, open 1458", "the shut map toggled open, then turned")
end

function tests.open_inAFight_theToggle_theTurnWaits()
    local t = Load(true)
    t.shown, t.fighting = false, true
    t.MapSearch.OpenMap(1458)
    H.assertEq(table.concat(t.log, ", "), "toggle")
    H.assertTrue(t.events.PLAYER_REGEN_ENABLED)
end

function tests.open_onAClassicClient_theToggleThenTheTurn()
    local t = Load(false)
    t.shown = false
    t.MapSearch.OpenMap(1458)
    H.assertEq(table.concat(t.log, ", "), "toggle, set 1458")
end

-- Every turn of the world map goes through the door; the one inside it is
-- the only bare call.
local ALLOWED = { ["MapSearch/Navigation.lua:        WorldMapFrame:SetMapID(mapID)"] = true }

-- Every open goes through MapSearch.OpenMap; a toggle stays only as its
-- fallback and to close an open map.
local TOGGLES = {
    ["MapSearch/Navigation.lua:        ToggleWorldMap()"] = true,
    ["Apps/Settings/BlizzSearch.lua:                ToggleWorldMap()"] = true,
}

function tests.noBareMapOpensOutsideTheDoor()
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
                if code:find("ToggleWorldMap%s*%(") and not TOGGLES[path .. ":" .. line] then
                    bad[#bad + 1] = path .. ":" .. n .. ": " .. line:gsub("^%s+", "")
                end
            end
            f:close()
        end
    end
    p:close()
    H.assertEq(#bad, 0, "open the map through MapSearch.OpenMap:\n  " .. table.concat(bad, "\n  "))
end

function tests.noBareMapTurnsOutsideTheDoor()
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
                if (code:find("SetMapID%s*%(") or code:find("SetMapID%s*,")) and not code:find("hooksecurefunc")
                    and not ALLOWED[path .. ":" .. line] then
                    bad[#bad + 1] = path .. ":" .. n .. ": " .. line:gsub("^%s+", "")
                end
            end
            f:close()
        end
    end
    p:close()
    H.assertEq(#bad, 0, "turn the map through MapSearch.TurnMap (extensions: EasyFind.API.OpenMap):\n  " .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("MapTurns", tests)
return { pass = pass, fail = fail, failures = failures }

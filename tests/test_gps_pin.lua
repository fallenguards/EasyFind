-- Guardrail: the GPS puts the game's pin on the current step's end and
-- nowhere else. One place call in all its files, inside TrackStep, at the
-- point WaypointPoint gives for that step.
local H = require("Harness")

local PLACES = { "SetUserWaypoint%(", "PlaceUserWaypoint%(", "SetSuperTrackedUserWaypoint%(%s*true" }

local tests = {}

function tests.thePinGoesOnlyOnTheCurrentStepsEnd()
    local bad, placed, checked = {}, 0, 0
    for _, rel in ipairs((H.TocFiles("Apps/GPS/EasyFind_GPS.toc"))) do
        local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
        if fh then
            local n, inTrack, pointed = 0, false, false
            for line in fh:lines() do
                n = n + 1
                if line:find("^TrackStep = function%(index%)") then inTrack = true
                elseif inTrack and line:find("^end") then inTrack = false end
                local code = line:gsub("%-%-.*$", "")
                if inTrack and code:find("WaypointPoint%(step%)") then pointed = true end
                for _, pattern in ipairs(PLACES) do
                    if code:find(pattern) and not code:find("^%s*function") then
                        if rel == "Apps/GPS/GPS.lua" and inTrack and pointed then
                            if pattern == "PlaceUserWaypoint%(" then placed = placed + 1 end
                        else
                            bad[#bad + 1] = rel .. ":" .. n .. ": " .. line:match("^%s*(.-)%s*$")
                        end
                    end
                end
            end
            fh:close()
            checked = checked + 1
        end
    end
    H.assertTrue(checked >= 5, "expected the GPS files, read " .. checked)
    H.assertEq(#bad, 0, "a pin placed off the current step's end:\n  " .. table.concat(bad, "\n  "))
    H.assertEq(placed, 1, "one pin, placed in TrackStep")
end

-- WaypointPoint cut from GPS.lua: a step ending just past its map's edge
-- (Stormwind City left at its gate) is pinned on the map around it, as the
-- game refuses a point off its map.
function tests.pointPastItsMapsEdge_goesOnTheMapAround()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local function WaypointPoint(step)", 1, true), "WaypointPoint not in GPS.lua")
    local _, e = src:find("\nend\r?\n", s)
    local vec = function(x, y) return { x = x, y = y, GetXY = function(v) return v.x, v.y end } end
    local env = setmetatable({
        CreateVector2D = vec,
        C_Map = {
            CanSetUserWaypointOnMap = function() return true end,
            GetMapInfo = function(m) return { parentMapID = m == 1453 and 1429 or nil } end,
            GetMapPosFromWorldPos = function(_, _, m) return m, vec(0.3, 0.4) end,
        },
    }, { __index = _G })
    local WaypointPoint = assert(load(src:sub(s, e):gsub("^local function", "function") .. "\nreturn WaypointPoint",
        "=GPS.lua WaypointPoint", "t", env))()
    local m, x, y = WaypointPoint({ mapID = 1453, x = 1.03, y = 0.5, arrive = { ci = 0, wx = -9000, wy = 400 } })
    H.assertEq(m, 1429, "Elwynn Forest, around the city")
    H.assertEq(x, 0.3)
    H.assertEq(y, 0.4)
    H.assertEq((WaypointPoint({ mapID = 1453, x = 0.5, y = 0.5 })), 1453, "a point on its map stays there")
end

local pass, fail, failures = H.runSuite("GPSPin", tests)
return { pass = pass, fail = fail, failures = failures }

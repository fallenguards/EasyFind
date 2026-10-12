-- Guardrail: the GPS guides with its own arrow and map line, never the
-- game's pin. No GPS file places a user waypoint or turns its tracking on.
local H = require("Harness")

local PLACES = { "SetUserWaypoint", "PlaceUserWaypoint", "SetSuperTrackedUserWaypoint%(%s*true" }

local tests = {}

function tests.noGpsFilePlacesTheGamesPin()
    local bad, checked = {}, 0
    for _, rel in ipairs((H.TocFiles("Apps/GPS/EasyFind_GPS.toc"))) do
        local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
        if fh then
            local n = 0
            for line in fh:lines() do
                n = n + 1
                local code = line:gsub("%-%-.*$", "")
                for _, pattern in ipairs(PLACES) do
                    if code:find(pattern) then bad[#bad + 1] = rel .. ":" .. n .. ": " .. line:match("^%s*(.-)%s*$") end
                end
            end
            fh:close()
            checked = checked + 1
        end
    end
    H.assertTrue(checked >= 5, "expected the GPS files, read " .. checked)
    H.assertEq(#bad, 0, "the GPS places the game's pin:\n  " .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("GPSNoPins", tests)
return { pass = pass, fail = fail, failures = failures }

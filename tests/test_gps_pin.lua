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

local pass, fail, failures = H.runSuite("GPSPin", tests)
return { pass = pass, fail = fail, failures = failures }

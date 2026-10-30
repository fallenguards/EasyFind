-- A companion loaded inside EasyFind's own ADDON_LOADED never hears its own
-- ADDON_LOADED: it registers for the event mid-dispatch (2026-10-27: the
-- chat's whole setup never ran after a reload). A load there is allowed
-- only for a companion that sets up at PLAYER_LOGIN too; a new one fails
-- here until it does and is added below.
local H = require("Harness")

local SETS_UP_AT_LOGIN = {}

local tests = {}

function tests.onlyCompanionsThatSetUpAtLoginLoadEarly()
    local f = assert(io.open(H.ADDON_ROOT .. "/Core/Main.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local body = assert(src:match("\nlocal function OnInitialize%(%)(.-)\nend\n"))
    local bad = {}
    for line in body:gmatch("[^\n]+") do
        -- The function's own statements, not the slash handlers inside it.
        if line:match("^    %S") then
            for call in line:gmatch("ns%.([%w_]+)%(") do
                local loads = call:match("^Request") or call:match("^Load") or call == "LoadAddOn"
                if loads and not SETS_UP_AT_LOGIN[call] then bad[#bad + 1] = call end
            end
            if line:find("LoadAddOn", 1, true) then bad[#bad + 1] = "LoadAddOn" end
        end
    end
    H.assertEq(#bad, 0, "loaded inside ADDON_LOADED: " .. table.concat(bad, ", "))
end

local pass, fail, failures = H.runSuite("EarlyCompanionLoad", tests)
return { pass = pass, fail = fail, failures = failures }

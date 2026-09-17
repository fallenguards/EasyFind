-- The GPS's secure buttons stay out of its own frames: a secure button
-- makes every frame it hangs from or is pinned to protected in a fight, and
-- the window and the tracker section move and resize in combat.
local H = require("Harness")

local function read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local tests = {}

function tests.secureButtons_belongToUIParent()
    local p = assert(io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "Apps/GPS/*.lua"'))
    local offenders, files = {}, 0
    for path in p:lines() do
        files = files + 1
        local n = 0
        for line in read(path):gmatch("[^\n]*") do
            n = n + 1
            local parent = line:match('CreateFrame%(%s*"%w+"%s*,%s*[^,]*,%s*([^,]+),%s*"Secure%w*Template"')
            if parent and parent:match("^%s*(.-)%s*$") ~= "UIParent" then
                offenders[#offenders + 1] = path .. ":" .. n .. " parent " .. parent
            end
        end
    end
    p:close()
    H.assertTrue(files > 0, "the GPS files were listed")
    H.assertEq(table.concat(offenders, ", "), "", "GPS secure buttons belong to UIParent, pinned only out of combat")
end

function tests.castButtons_hideAsAFightBegins()
    local src = read("Apps/GPS/GPS.lua")
    H.assertTrue(src:find('RegisterEvent%("PLAYER_REGEN_DISABLED"%)') ~= nil, "combat start is watched")
    H.assertTrue(src:find("castButtons%[i%]:ClearAllPoints%(%)") ~= nil, "the buttons are unpinned before the lockdown")
end

local pass, fail, failures = H.runSuite("GPSSecure", tests)
return { pass = pass, fail = fail, failures = failures }

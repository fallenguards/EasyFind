-- A menu over a menu sits Utils.MENU_LEVEL_STEP above its parent, and a menu
-- panel's Forever band one under that step: with the band at the windows'
-- offset (12) the Map Search flyout's metal edge crossed the NPC options
-- menu's body where the two overlapped (Forever, 2026-11-09).
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local tests = {}

function tests.aMenuPanelsBandStaysUnderTheStep()
    local utils = Read("Shared/Utils.lua")
    H.assertTrue(utils:find("Utils.MENU_LEVEL_STEP = 10", 1, true) ~= nil)
    H.assertTrue(utils:find("frame._efBandLevel = Utils.MENU_LEVEL_STEP - 1", 1, true) ~= nil,
        "StyleMenuPanel marks the band's level")
    H.assertTrue(utils:find("f.border:SetFrameLevel(frame:GetFrameLevel() + (frame._efBandLevel or FOREVER.level))", 1, true) ~= nil,
        "the Forever band reads the mark")
end

-- Every nested menu in the filter tree clears its parent's band.
function tests.everyNestedMenuClearsItsParentsBand()
    local p = assert(io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "Search/Filters/*.lua"'))
    local bad, seen = {}, 0
    for path in p:lines() do
        if not path:find("QuickFilter.lua", 1, true) then
            local n = 0
            for line in Read(path):gmatch("([^\n]*)\n?") do
                n = n + 1
                local offset = line:match("SetFrameLevel%([%w_.]+:GetFrameLevel%(%) %+ (%d+)%)")
                    or line:match("GetFrameLevel%(%) %+ (%d+) end")
                if offset then
                    seen = seen + 1
                    if tonumber(offset) < 10 then bad[#bad + 1] = path .. ":" .. n .. ": " .. line:gsub("^%s+", "") end
                end
            end
        end
    end
    p:close()
    H.assertTrue(seen > 0, "menu level offsets found")
    H.assertEq(#bad, 0, "a nested menu sits at least Utils.MENU_LEVEL_STEP above its parent:\n  " .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("MenuLevels", tests)
return { pass = pass, fail = fail, failures = failures }

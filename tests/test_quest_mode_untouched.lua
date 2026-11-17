-- The world map's quest panel mode is the client's alone. EasyFind's map tab
-- set it (SetDisplayMode, nil on show and the old mode back on hide), and the
-- mode stayed EasyFind's: the map key's next open read it, and in a fight the
-- area pins' SetPropagateMouseClicks was refused (Forever, 2026-11-15; the
-- pinshare dump named MapTab.lua's restore). The tab now covers the panel
-- (MapTab.lua CoverClientPanel: content see-through, tabs unchecked).
local H = require("Harness")

-- The third-party tab framework's own mode, not the client's.
local ALLOWED = {
    ["MapSearch/MapTab.lua:            pcall(lwmt.SetDisplayMode, lwmt, nil)"] = true,
}

local tests = {}

function tests.noQuestPanelModeWrittenByAddonCode()
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
                local call = code:find("SetDisplayMode%s*[%(,]") and not code:find("hooksecurefunc")
                local write = code:find("[%w_%]]%.displayMode%s*=[^=]") and not code:find("^%s*tab%.displayMode%s*=")
                if (call or write) and not ALLOWED[path .. ":" .. line] then
                    bad[#bad + 1] = path .. ":" .. n .. ": " .. line:gsub("^%s+", "")
                end
            end
            f:close()
        end
    end
    p:close()
    H.assertEq(#bad, 0, "cover the quest panel (MapTab.lua CoverClientPanel), never set its mode:\n  "
        .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("QuestModeUntouched", tests)
return { pass = pass, fail = fail, failures = failures }

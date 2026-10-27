-- A cogwheel says settings by itself (2026-10-27): no cog shows a
-- "Settings" tooltip; its hover is a glow on the cog.
local H = require("Harness")

local tests = {}

function tests.noSettingsTooltips()
    local bad = {}
    local p = io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "*.lua"')
    for rel in p:lines() do
        if not rel:match("^tests/") and not rel:match("^Locales/") and not rel:match("^dev/") then
            local f = io.open(H.ADDON_ROOT .. "/" .. rel, "rb")
            if f then
                local n = 0
                for line in f:lines() do
                    n = n + 1
                    if line:find('GameTooltip:SetText(_G["SETTINGS"]', 1, true) then bad[#bad + 1] = rel .. ":" .. n end
                end
                f:close()
            end
        end
    end
    p:close()
    H.assertEq(#bad, 0, table.concat(bad, ", "))
end

local pass, fail, failures = H.runSuite("CogNoTooltip", tests)
return { pass = pass, fail = fail, failures = failures }

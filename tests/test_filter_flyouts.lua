-- A filter row opens a flyout on hover only when it draws the arrow: every
-- flyout Search/Filters/Dropdown.lua attaches by a row's key must belong to
-- a row whose config has hasFlyout = true, or test opt.hasFlyout itself.
-- (The classic Professions row opened an empty popup with no arrow.)
local H = require("Harness")

local function read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.keyAttachedFlyoutsHaveTheirArrow()
    local dropdown = read("Search/Filters/Dropdown.lua")
    local config = read("Search/Filters/Config.lua")
    local wrong = {}
    for cond, key, body in dropdown:gmatch("\n%s*if (opt%.key == \"(%w+)\"[^\n]*) then\n(%s*[^\n]*)") do
        if body:find("Attach%w*Flyout") and not cond:find("hasFlyout", 1, true) then
            local row = config:match("{ key = \"" .. key .. "\",[^}]-hasFlyout = ([%w_]+)")
            if row ~= "true" then wrong[#wrong + 1] = key .. " (hasFlyout = " .. tostring(row) .. ")" end
        end
    end
    H.assertEq(table.concat(wrong, ", "), "", "flyouts attached to rows that draw no arrow")
end

local pass, fail, failures = H.runSuite("FilterFlyouts", tests)
return { pass = pass, fail = fail, failures = failures }

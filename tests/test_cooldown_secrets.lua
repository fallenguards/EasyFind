-- Every function that draws a cooldown swipe asks issecretvalue first: in a
-- fight the game withholds cooldown numbers, and a compare or a SetCooldown
-- of a secret errors from an addon (the GPS's cast button raised thousands
-- a dungeon run, 2026-11-25).
local H = require("Harness")

local function LuaFiles()
    local out = {}
    local p = io.popen('cd "' .. H.ADDON_ROOT .. '" && find . -name "*.lua" -not -path "./tests/*" -not -path "./dev/*"')
    for line in p:lines() do out[#out + 1] = line:gsub("^%./", "") end
    p:close()
    return out
end

local tests = {}

function tests.everySwipe_asksIssecretvalue()
    local bad = {}
    for _, rel in ipairs(LuaFiles()) do
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
        local src = f:read("*a")
        f:close()
        local at = 1
        while true do
            local s = src:find(":SetCooldown(", at, true)
            if not s then break end
            local head = src:sub(1, s)
            local fn = 1
            for p in head:gmatch("()function[%s%w_.:]*%(") do fn = p end
            if not src:sub(fn, s):find("issecretvalue", 1, true) then
                local line = select(2, head:gsub("\n", "")) + 1
                bad[#bad + 1] = rel .. ":" .. line
            end
            at = s + 1
        end
    end
    H.assertEq(table.concat(bad, ", "), "", "a swipe drawn without asking issecretvalue")
end

local pass, fail, failures = H.runSuite("CooldownSecrets", tests)
return { pass = pass, fail = fail, failures = failures }

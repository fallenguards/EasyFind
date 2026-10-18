-- Wrapped text takes its width from what holds it: anchored on both sides,
-- or the holder's own width. A bare pixel width runs past any window
-- narrower than it (the checklist's empty hint did).
local H = require("Harness")

local tests = {}

function tests.wrappedTextNeverHasABarePixelWidth()
    local p = assert(io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "*.lua"'))
    local bad = {}
    for path in p:lines() do
        if not (path:find("^tests/") or path:find("^dev/") or path:find("^Locales/") or path:find("[Ll]ibs/")) then
            local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
            local lines = {}
            for l in f:lines() do lines[#lines + 1] = l end
            f:close()
            for i, l in ipairs(lines) do
                local v = l:match("^%s*([%w_%.%[%]]+):SetWordWrap%(true%)")
                if v then
                    local pat = v:gsub("[%.%[%]]", "%%%0") .. ":SetWidth%(%s*%d+%s*%)"
                    for j = math.max(1, i - 10), math.min(#lines, i + 10) do
                        if lines[j]:find(pat) then bad[#bad + 1] = path .. ":" .. j .. " " .. v end
                    end
                end
            end
        end
    end
    p:close()
    H.assertEq(#bad, 0, "wrapped text with a bare pixel width: " .. table.concat(bad, ", "))
end

local pass, fail, failures = H.runSuite("TextFit", tests)
return { pass = pass, fail = fail, failures = failures }

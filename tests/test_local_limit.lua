-- Guardrail: Lua refuses a file once 200 locals are live at its top level,
-- and the client then loads none of it. Every shipped file keeps 10 spare:
-- each compiles with 10 more locals in front of it.
local H = require("Harness")

local SPARE = 10
-- Files already closer: held where they are until some locals are bundled.
local HELD = { ["Shared/Utils.lua"] = 0, ["Database/Main.lua"] = 4 }

local function Front(n)
    local names = {}
    for i = 1, n do names[i] = "_spare" .. i end
    return n > 0 and ("local " .. table.concat(names, ", ") .. "\n") or ""
end

local tests = {}

function tests.everyFileKeepsRoomForMoreLocals()
    local full, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "rb")
            if fh then
                local src = fh:read("*a"):gsub("^\239\187\191", "")
                fh:close()
                checked = checked + 1
                local _, err = load(Front(HELD[rel] or SPARE) .. src, "=" .. rel)
                if err and err:find("too many local variables", 1, true) then full[#full + 1] = rel end
            end
        end
    end
    H.assertTrue(checked > 50, "expected the shipped files, read " .. checked)
    H.assertEq(#full, 0, "within " .. SPARE .. " of the 200 locals (bundle some into a table):\n  "
        .. table.concat(full, "\n  "))
end

local pass, fail, failures = H.runSuite("LocalLimit", tests)
return { pass = pass, fail = fail, failures = failures }

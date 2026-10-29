-- Guardrail: a module's field set twice at a file's top level, the later
-- one silently replacing the earlier. GPS.Destination (a row's place, the
-- GPS button's check) was replaced further down GPS.lua by the trip
-- editor's export of the same name, so quest rows in a dungeon zone lost
-- the button and the rest led to their zone's middle (2026-10-29).
local H = require("Harness")

local tests = {}

function tests.noModuleFieldIsDefinedTwiceInAFile()
    local seenFile, dupes, checked = {}, {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            if not seenFile[rel] then
                seenFile[rel] = true
                local f = io.open(H.ADDON_ROOT .. "/" .. rel, "rb")
                if f then
                    local src = f:read("*a"):gsub("\r\n", "\n")
                    f:close()
                    checked = checked + 1
                    local defined = {}
                    local n = 0
                    for line in (src .. "\n"):gmatch("(.-)\n") do
                        n = n + 1
                        -- Top level only: "function M.f(" / "function M:f(" / "M.f = " (not "M.f = M.f or").
                        local name = line:match("^function ([%a_][%w_]*[.:][%a_][%w_]*)%s*%(")
                        if not name then
                            local lhs, rhs = line:match("^([%a_][%w_]*%.[%a_][%w_]*)%s*=%s*(.*)$")
                            if lhs and not rhs:find("^" .. lhs:gsub("%p", "%%%0") .. "%s+or") then name = lhs end
                        end
                        if name then
                            name = name:gsub(":", ".")
                            if defined[name] then
                                dupes[#dupes + 1] = string.format("%s: %s at lines %d and %d", rel, name, defined[name], n)
                            else
                                defined[name] = n
                            end
                        end
                    end
                end
            end
        end
    end
    H.assertTrue(checked > 100, "expected the shipped files, read " .. checked)
    H.assertEq(#dupes, 0, "a field defined twice, the later replacing the earlier:\n  " .. table.concat(dupes, "\n  "))
end

local pass, fail, failures = H.runSuite("ModuleRedefinition", tests)
return { pass = pass, fail = fail, failures = failures }

-- Guardrail: the client keeps an edit box focused through clicks anywhere
-- else, so a box swallowed every key until Esc (the settings searches,
-- the GPS and map tab boxes, 2026-10-28). Every edit box a shipped file
-- makes either drops its focus on an outside click
-- (Utils.ReleaseFocusOnOutsideClick, after the box's own focus scripts:
-- a later SetScript drops its hooks) or says why it keeps it
-- (-- keeps focus: ... right above the CreateFrame line).
local H = require("Harness")

local function Lines(rel)
    local f = io.open(H.ADDON_ROOT .. "/" .. rel, "rb")
    if not f then return nil end
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local out = {}
    for line in (src .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    return out
end

local tests = {}

function tests.everyEditBox_releasesFocusOrSaysWhyNot()
    local problems, boxes, seen = {}, 0, {}
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local lines = not seen[rel] and Lines(rel)
            seen[rel] = true
            for i = 1, lines and #lines or 0 do
                if lines[i]:find('CreateFrame%("EditBox"') then
                    boxes = boxes + 1
                    local keeps = lines[i]:find("%-%- keeps focus:") or (lines[i - 1] or ""):find("%-%- keeps focus:")
                    if not keeps then
                        local var = lines[i]:match("^%s*local%s+([%w_%.%[%]]+)%s*=") or lines[i]:match("^%s*([%w_%.%[%]]+)%s*=")
                        local esc = var and var:gsub("%p", "%%%0")
                        local released, lateScript
                        for j = i + 1, #lines do
                            if esc and lines[j]:find("ReleaseFocusOnOutsideClick%(" .. esc .. "%)") then released = j end
                            if esc and lines[j]:find(esc .. ':SetScript%("OnEditFocus') then lateScript = j end
                        end
                        if not released then
                            problems[#problems + 1] = rel .. ":" .. i .. " " .. tostring(var) .. " keeps focus through outside clicks"
                        elseif lateScript and lateScript > released then
                            problems[#problems + 1] = rel .. ":" .. lateScript .. " " .. var
                                .. "'s own focus script comes after the release and drops it"
                        end
                    end
                end
            end
        end
    end
    H.assertTrue(boxes > 20, "expected the shipped edit boxes, found " .. boxes)
    H.assertEq(#problems, 0, "edit boxes:\n  " .. table.concat(problems, "\n  "))
end

local pass, fail, failures = H.runSuite("EditBoxFocus", tests)
return { pass = pass, fail = fail, failures = failures }

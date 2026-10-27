-- A backdrop mixed into a frame by hand (Mixin(f, BackdropTemplateMixin))
-- lacks the template's resize script, so its tiles keep the size the frame
-- had when dressed: a card sized later wore the marble stretched
-- (2026-10-26). Every file that mixes it in hooks OnBackdropSizeChanged.
local H = require("Harness")

local tests = {}

function tests.everyMixedInBackdropRetilesOnResize()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                checked = checked + 1
                local text = fh:read("a")
                fh:close()
                if text:find("Mixin%([^)]*BackdropTemplateMixin%)") and not text:find("OnBackdropSizeChanged", 1, true) then
                    bad[#bad + 1] = rel
                end
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "hook OnSizeChanged to OnBackdropSizeChanged in:\n  " .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("BackdropMixin", tests)
return { pass = pass, fail = fail, failures = failures }

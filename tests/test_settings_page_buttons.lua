-- A button on a settings page wears the window's text like the window's
-- own buttons (2026-10-27: Clipboard's Clear history was the plain API
-- button, smaller). Pages build buttons with kit.Button, never
-- API.CreateButton on the page.
local H = require("Harness")

local FILES = { "Apps/Clipboard/Clipboard.lua", "Core/Extensions.lua", "API/example/EasyFind_Bookmarks/Bookmarks.lua" }

local tests = {}

function tests.pagesUseTheKitsButton()
    local bad = {}
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do FILES[#FILES + 1] = rel end
    end
    local seen = {}
    for _, rel in ipairs(FILES) do
        if not seen[rel] then
            seen[rel] = true
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                local n = 0
                for line in fh:lines() do
                    n = n + 1
                    if line:find("API%.CreateButton%(page") then bad[#bad + 1] = rel .. ":" .. n end
                end
                fh:close()
            end
        end
    end
    H.assertEq(#bad, 0, "settings pages making a plain button:\n  " .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("SettingsPageButtons", tests)
return { pass = pass, fail = fail, failures = failures }

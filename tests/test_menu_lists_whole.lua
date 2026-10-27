-- A menu lists everything it holds (2026-10-27: Trash showed 15 notes, Add
-- to note 20, the chat flyout 12, the rest unreachable). A long menu scrolls
-- (Utils.MENU_MAX_ROWS, test_menu_row_cap.lua); a builder never cuts its
-- list with math.min. Search hits capped by a named limit are the one case.
local H = require("Harness")

local function scan(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local bad = {}
    for i, line in ipairs(lines) do
        local cap = line:match("for %w+ = 1, m?a?t?h?%.?m?min%(#[%w_%.]+, ([%w_%.]+)%) do")
        if cap and tonumber(cap) then
            for j = i + 1, math.min(#lines, i + 4) do
                if lines[j]:find("%[#%w+ %+ 1%] = {") then
                    bad[#bad + 1] = i .. ": cuts a menu at " .. cap
                    break
                end
            end
        end
    end
    return bad
end

local tests = {}

function tests.menuBuildersListEverything()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                checked = checked + 1
                for _, hit in ipairs(scan(fh:read("a"))) do bad[#bad + 1] = rel .. ":" .. hit end
                fh:close()
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "\n  " .. table.concat(bad, "\n  "))
end

function tests.scan_flagsANumberCut()
    H.assertEq(#scan("for i = 1, math.min(#list, 12) do\n    rows[#rows + 1] = { text = x }\nend\n"), 1)
    H.assertEq(#scan("for i = 1, mmin(#hits, Auto.FOUND_MAX) do rows[i] = x end\n"), 0)
    H.assertEq(#scan("for i = 1, #list do\n    rows[#rows + 1] = { text = x }\nend\n"), 0)
end

local pass, fail, failures = H.runSuite("MenuListsWhole", tests)
return { pass = pass, fail = fail, failures = failures }

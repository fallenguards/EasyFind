-- The selected row's frame is asked of the list (Results:RowFrame), never
-- read from the frame pool by the row's index: the rows near the view take
-- whichever frame is free, so past the first screen pool[index] is another
-- row or none. Enter on the "Reagent for" heading far down an item's
-- sources page acted on another row and the selection fell back to the
-- box, while the headings on the first screen folded (2026-11-21).
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"), path)
    local s = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return s
end

local tests = {}

function tests.noKeyPathReadsTheSelectedRowFromThePool()
    local found = {}
    local p = assert(io.popen('grep -rnE "esultButtons\\(\\)\\[Search:GetSelectedIndex\\(\\)\\]|esultButtons\\[selectedIndex\\]|'
        .. 'esultButtons\\(\\)\\[sel(ected)?\\]" "' .. H.ADDON_ROOT .. '" --include=*.lua'
        .. ' --exclude-dir=tests --exclude-dir=dev --exclude-dir=.git 2>/dev/null'))
    for line in p:lines() do found[#found + 1] = line:sub(#H.ADDON_ROOT + 2, #H.ADDON_ROOT + 90) end
    p:close()
    H.assertEq(#found, 0, "the selected row read from the pool by its index: " .. table.concat(found, " | ", 1, math.min(#found, 4)))
end

function tests.enterActsOnTheSelectedRowsOwnFrame()
    local nav = Read("Search/Results/Navigation.lua")
    local s = assert(nav:find("\nfunction Results:ActivateSelected(source)\n", 1, true))
    local e = assert(nav:find("\nend\n", s, true))
    local body = nav:sub(s, e)
    H.assertTrue(body:find("local resultRow = self:RowFrame(selected)", 1, true) ~= nil, "by the list's own lookup")
    H.assertNil(body:find("GetResultButtons", 1, true), "never the pool")
    local bar = Read("Search/SearchBar.lua")
    local _, lookups = bar:gsub("Results:RowFrame%(selectedIndex%)", "")
    H.assertTrue(lookups >= 9, "the bar's key paths too: " .. lookups)
    H.assertTrue(bar:find("for i = 1, Results:RowCount() do\n                local row = Results:RowEntry(i)", 1, true) ~= nil,
        "Enter from the box finds the first row among the list's rows")
end

-- Space folds a heading as Enter does.
function tests.spaceFoldsAHeading()
    local bar = Read("Search/SearchBar.lua")
    H.assertTrue(bar:find("if row and row.isSectionHeader then\n                    Results:ActivateResultRow(row, \"key\")\n"
        .. "                    return\n                end", 1, true) ~= nil, "Space on a heading runs its toggle")
    H.assertTrue(bar:find("((row.isPinHeader or row.isSectionHeader) and row.pinToggle and row.pinToggle:IsShown())", 1, true) ~= nil,
        "and is taken from the game only where a heading folds")
end

local pass, fail, failures = H.runSuite("SelectedRowFrame", tests)
return { pass = pass, fail = fail, failures = failures }

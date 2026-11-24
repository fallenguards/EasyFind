-- An extension's rows as a page in the bar, in the order it hands them
-- (Search/RowsPage.lua, API.ShowRows, MINOR 14): the Questie extension's
-- quests of one name, a chain's parts numbered, which a ranking would
-- reorder (one row a name, 2026-11-24).
local H = require("Harness")

local function Load()
    local env = H.newEnv()
    local ns = H.newNs(env)
    local shown = {}
    ns.Filters.ApplyQuickFilter = function(_, def, text) shown.def, shown.text = def, text end
    ns.Results.ShowHierarchicalResults = function(_, entries) shown.entries = entries end
    H.loadModule("Search/RowsPage.lua", env, ns)
    return ns.RowsPage, shown
end

local function Names(entries)
    local out = {}
    for i, e in ipairs(entries) do out[i] = e.name end
    return table.concat(out, ", ")
end

local function Parts()
    return {
        { name = "Sweet Amber (part 1)", questId = 48, searchCommandDesc = "Done: Level 40, Feralas" },
        { name = "Sweet Amber (part 2)", questId = 49, searchCommandDesc = "In your log: Level 40, Feralas" },
        { name = "Sweet Amber (part 3)", questId = 50, searchCommandDesc = "Needs level 45: Tanaris" },
    }
end

local tests = {}

function tests.theRows_keepTheOrderGiven_theirProvidersOwn()
    local Page, shown = Load()
    local rows = Parts()
    Page:Show("questie", "Sweet Amber", rows)
    H.assertEq(shown.def.token, "@Sweet Amber", "its pill names the title")
    Page:ShowView(shown.def, "")
    H.assertEq(Names(shown.entries), "Sweet Amber (part 1), Sweet Amber (part 2), Sweet Amber (part 3)")
    H.assertTrue(shown.entries[2].data == rows[2], "the provider's own row: its click, tooltip and hint")
    H.assertEq(rows[3].category, "questie", "given the provider's category")
    H.assertEq(rows[3].nameLower, "sweet amber (part 3)")
end

function tests.typing_narrowsByNameOrSubtext()
    local Page, shown = Load()
    Page:Show("questie", "Sweet Amber", Parts())
    Page:ShowView(shown.def, "tanaris")
    H.assertEq(Names(shown.entries), "Sweet Amber (part 3)")
    Page:ShowView(shown.def, "part 2")
    H.assertEq(Names(shown.entries), "Sweet Amber (part 2)")
end

-- Wired: the search draws it as a page, the API opens it, the toc loads it.
function tests.thePage_isWired()
    local function Read(rel)
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
        local src = f:read("*a"):gsub("\r\n", "\n")
        f:close()
        return src
    end
    H.assertTrue(Read("Search/Query.lua"):find("if ns.RowsPage then ns.RowsPage:ShowView(quickFilter, text) end", 1, true) ~= nil)
    local api = Read("Core/API.lua")
    H.assertTrue(api:find("local API = { VERSION = 1, MINOR = 14 }", 1, true) ~= nil)
    H.assertTrue(api:find("ns.RowsPage:Show(p.category, title, rows)", 1, true) ~= nil)
    H.assertTrue(Read("EasyFind.toc"):find("Search/RowsPage.lua\n", 1, true) ~= nil)
    H.assertTrue(Read("API/README.md"):find("| `ShowRows(key, title, rows)` |", 1, true) ~= nil, "documented")
end

local pass, fail, failures = H.runSuite("RowsPage", tests)
return { pass = pass, fail = fail, failures = failures }

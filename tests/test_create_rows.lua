-- A create row (Create snippet, Create note, an extension's Create shopping
-- list) carries createRow: the renderer's green plus badge and glow hang on
-- that one field, the API documents it (MINOR 4), and Notes offers its own
-- Create note row first (2026-10-30).
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local tests = {}

function tests.theBadgeHangsOnCreateRowAlone()
    local render = Read("Search/Results/Render/Core.lua")
    H.assertTrue(render:find("data.createRow", 1, true) ~= nil, "the renderer reads createRow")
    for _, path in ipairs({ "Search/Results/Render/Core.lua", "Search/Results/Rows/ResultButton.lua",
                            "Apps/Snippets/Snippets.lua", "Shared/Shortkeys.lua", "Apps/Quicklists/Quicklists.lua",
                            "Shared/ResultLinks.lua", "Search/Query.lua" }) do
        H.assertTrue(Read(path):find("snippetCreate", 1, true) == nil, path .. " still says snippetCreate")
    end
end

function tests.notesOfferTheCreateRowFirst()
    local env = setmetatable({
        NotesStore = function() return { { id = 1, name = "Mats" } } end,
        notesNS = { NoteShown = function() return true end,
                    NoteSearchRow = function(n) return { name = n.name, noteID = n.id } end },
        L = setmetatable({}, { __index = function(_, k) return k end }),
        slower = string.lower,
        ns = { NOTES_ICON_TEX = "tex" },
    }, { __index = _G })
    local src = Read("Apps/Notes/Notes.lua")
    local s = assert(src:find("function notesNS.BuildSearchData()", 1, true))
    local _, e = src:find("\nend\n", s)
    assert(load(src:sub(s, e), "=Notes.lua BuildSearchData", "t", env))()
    local rows = env.notesNS.BuildSearchData()
    H.assertEq(rows[1].name, "NOTES_CREATE")
    H.assertTrue(rows[1].createRow == true, "the first row makes a note")
    H.assertEq(rows[1].category, "Notes")
    H.assertEq(rows[2].noteID, 1, "then the notes")
end

function tests.theApiOffersIt()
    H.assertTrue(Read("Core/API.lua"):find("MINOR = 7", 1, true) ~= nil)
    H.assertTrue(Read("API/README.md"):find("`createRow`", 1, true) ~= nil, "documented for extensions")
end

local pass, fail, failures = H.runSuite("CreateRows", tests)
return { pass = pass, fail = fail, failures = failures }

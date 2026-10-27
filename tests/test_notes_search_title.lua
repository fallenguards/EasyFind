-- Tests for the Notes list search (Apps/Notes/Notes.lua SortedNotes): the
-- words typed match a note's shown title as well as its body and tags. A
-- note named "Checklist" with nothing in its body vanished from the list
-- on "che" (2026-10-27).
local H = require("Harness")

local function Read(rel)
    local fh = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local text = fh:read("*a")
    fh:close()
    return text
end

local function LoadSearch(notes)
    local src = Read("Apps/Notes/Notes.lua")
    local s = assert(src:find("\nlocal function SortedNotes(filter)", 1, true), "SortedNotes not in Notes.lua")
    local _, e = src:find("\nend\r?\n", s)
    local env = setmetatable({
        NotesStore = function() return notes end,
        EasyNotesDB = {},
        CurrentCharKey = function() return "A-Realm" end,
        UI = { _notes = {}, EasyNotesCategoriesOf = function() return {} end },
        NoteTags = { Matches = function() return false end },
        PlainSearchText = function(n) return (n.body or ""):lower() end,
        NoteTitle = function(n) return n.name or "" end,
        sfind = string.find, slower = string.lower, tsort = table.sort,
        strtrim = function(t) return (t:gsub("^%s+", ""):gsub("%s+$", "")) end,
    }, { __index = _G })
    local chunk = assert(load(src:sub(s, e) .. "\nreturn SortedNotes", "=Notes.lua SortedNotes", "t", env))
    return chunk()
end

-- PlainSearchText cut from Notes.lua: the words a note is searched by.
local function LoadPlainText()
    local src = Read("Apps/Notes/Notes.lua")
    local s = assert(src:find("\nlocal plainBodyCache = {}", 1, true), "plainBodyCache not in Notes.lua")
    local f = assert(src:find("\nlocal function PlainSearchText(note)", s, true))
    local _, e = src:find("\nend\r?\n", f)
    local env = setmetatable({
        slower = string.lower,
        StripColorEscapes = function(t) return t end,
        MapSelection = function(t) return t end,
        GlyphPlain = {},
        notesNS = { Checklist = {
            Is = function(n) return n.kind == "checklist" end,
            LineName = function(line) return line.text end,
        } },
    }, { __index = _G })
    local chunk = assert(load(src:sub(s, e) .. "\nreturn PlainSearchText", "=Notes.lua PlainSearchText", "t", env))
    return chunk()
end

local function names(list)
    local out = {}
    for i = 1, #list do out[i] = list[i].name end
    return table.concat(out, ",")
end

local tests = {}

function tests.titleMatchesWithAnEmptyBody()
    local SortedNotes = LoadSearch({
        { name = "Checklist", body = "", updated = 2 },
        { name = "Untitled note", body = "buy ore", updated = 1 },
    })
    H.assertEq(names(SortedNotes("che")), "Checklist")
    H.assertEq(names(SortedNotes("CHECK")), "Checklist", "case does not matter")
end

function tests.bodyStillMatches()
    local SortedNotes = LoadSearch({
        { name = "Checklist", body = "", updated = 2 },
        { name = "Untitled note", body = "buy ore", updated = 1 },
    })
    H.assertEq(names(SortedNotes("ore")), "Untitled note")
    H.assertEq(names(SortedNotes("zzz")), "", "nothing matching: an empty list")
    H.assertEq(names(SortedNotes("")), "Checklist,Untitled note", "no words: every note")
end

function tests.checklistLinesAreSearched()
    local PlainSearchText = LoadPlainText()
    local list = { kind = "checklist", body = "", list = { lines = { { text = "Buy Ore" }, { text = "Kill boars" } } } }
    H.assertTrue(PlainSearchText(list):find("buy ore", 1, true) ~= nil, "a line's words, lowered")
    H.assertTrue(PlainSearchText(list):find("kill boars", 1, true) ~= nil)
    list.list.lines[1].text = "Sell Ore"
    H.assertTrue(PlainSearchText(list):find("sell ore", 1, true) ~= nil, "a renamed line counts at once")
    H.assertEq(PlainSearchText({ body = "Hello There" }), "hello there", "a plain note: its body")
end

local pass, fail, failures = H.runSuite("NotesSearchTitle", tests)
return { pass = pass, fail = fail, failures = failures }

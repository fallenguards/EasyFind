-- A client window is a tag ("Auction House": the note applies there) and
-- "Auction House open" a toggle on the note that opens the window and
-- gives the tag when missing; an extension's linked checklists get their
-- category's window tag by themselves, once (2026-10-30).
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Chunk(path, from, to, ret, env)
    local src = Read(path)
    local s = assert(src:find(from, 1, true), from)
    local e = assert(src:find(to, s, true), to)
    return assert(load(src:sub(s, e - 1) .. "\nreturn " .. ret, "=" .. path, "t", setmetatable(env, { __index = _G })))()
end

local L = setmetatable({}, { __index = function(_, k) return k end })

local tests = {}

function tests.theWindowsAreTagsNamedAfterTheWindow()
    local Ctx = Chunk("Apps/Notes/Context.lua", "function Ctx.Windows()", "local function Fixed()", "Ctx", {
        Ctx = {}, L = L, Caps = { retail = false },
        WINDOWS = { { id = "auctionhouse", label = "NOTES_CTX_AUCTION" }, { id = "greatvault", label = "NOTES_CTX_VAULT", retail = true } },
    })
    local list = Ctx.Windows()
    H.assertEq(#list, 1, "a retail-only window stays off a classic client")
    H.assertEq(list[1].type, "uistate")
    H.assertEq(list[1].id, "auctionhouse")
    H.assertEq(Ctx.WindowLabel("auctionhouse"), "NOTES_CTX_AUCTION")
    H.assertNil(Ctx.WindowLabel("nothing"))
    H.assertEq(L["NOTES_CTX_AUCTION"], "NOTES_CTX_AUCTION")
    local en = Read("Locales/enUS.lua")
    H.assertTrue(en:find('L%["NOTES_CTX_AUCTION"%]%s*= "Auction House"') ~= nil, "the tag reads as the window")
    H.assertTrue(en:find('L%["NOTES_CTX_OPEN_FMT"%]%s*= "%%s open"') ~= nil, "the toggle says open")
end

local function Linked()
    local store = {}
    local env = {
        NotesStore = function() return store end,
        CreateNote = function() local n = { id = #store + 1, appliesIn = {} } table.insert(store, 1, n) return n end,
        notesNS = {
            Context = { WindowLabel = function(id) return id == "auctionhouse" and "Auction House" or nil end },
            Checklist = { Init = function(note) note.list = {} return note.list end },
        },
        ns = { ChecklistLinks = { auctionator = { category = { key = "ShoppingLists", window = "auctionhouse" } } } },
    }
    local fns = Chunk("Apps/Notes/Notes.lua", "function notesNS.LinkedNote(ext, key, title, create)",
        "-- The extension's list into its checklist", "notesNS", env)
    return fns, store
end

function tests.aLinkedChecklistGetsItsWindowTag_once()
    local notesNS, store = Linked()
    local id = notesNS.LinkedNote("auctionator", "Mats", "Mats", true)
    local note = store[1]
    H.assertEq(note.id, id)
    H.assertEq(note.appliesIn[1].type, "uistate")
    H.assertEq(note.appliesIn[1].id, "auctionhouse")
    H.assertEq(note.appliesIn[1].name, "Auction House")
    H.assertNil(note.appliesIn[1].opens, "the tag alone, never the open toggle")
    -- The player takes the tag off: it stays off.
    note.appliesIn = {}
    notesNS.LinkedNote("auctionator", "Mats", "Mats", false)
    H.assertEq(#note.appliesIn, 0)
end

function tests.anOlderLinkedChecklistIsTaggedWhenFound()
    local notesNS, store = Linked()
    store[1] = { id = 9, appliesIn = {}, list = { source = { ext = "auctionator", key = "Herbs" } } }
    H.assertEq(notesNS.LinkedNote("auctionator", "Herbs", "Herbs", false), 9)
    H.assertEq(store[1].appliesIn[1].id, "auctionhouse")
end

function tests.theToggleAndTheRenameAreWired()
    local src = Read("Apps/Notes/Notes.lua")
    H.assertTrue(src:find("function NoteWhen.WindowRows(note)", 1, true) ~= nil, "the window toggles")
    H.assertTrue(src:find('L["NOTES_AUTO_WINDOWS"]', 1, true) ~= nil, "offered in Auto-show")
    H.assertTrue(src:find("local NOTES_DB_VERSION = 15", 1, true) ~= nil)
    H.assertTrue(src:find("if v < 15 then", 1, true) ~= nil, "stored names migrate to the window's")
end

local pass, fail, failures = H.runSuite("NotesWindowTags", tests)
return { pass = pass, fail = fail, failures = failures }

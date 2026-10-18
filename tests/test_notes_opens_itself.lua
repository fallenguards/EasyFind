-- Tests for notes that open by themselves (Apps/Notes/Notes.lua
-- UI:OpenNotesThatApply): a note set to, whose place comes up, opens the
-- closed window on it; it goes again when the place ends; a window in use
-- is never taken over; notes not set to never open.

local H = require("Harness")

local function Load(notes)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Notes/Notes.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function UI:OpenNotesThatApply()", 1, true), "OpenNotesThatApply not in Notes.lua")
    local _, e = src:find("\nend\r?\n", s)
    assert(e, "end of OpenNotesThatApply not found")
    local here = {}
    local frame = { shown = false }
    function frame:IsShown() return self.shown end
    function frame:Show() self.shown = true end
    local UI = { _notes = {} }
    function UI:EnsureEasyNotesFrame() UI._notes.frame = frame return frame end
    function UI:CloseEasyNotes() frame.shown = false end
    function UI:HideEasyNotesPalette() end
    function UI:RefreshEasyNotes() end
    local env = setmetatable({
        UI = UI,
        NotesStore = function() return notes end,
        SortedNotes = function() return notes end,
        NormalizeDB = function() end,
        Ctx = {
            Active = function() return {}, here end,
            Applies = function(n, set) return set[n.place] == true end,
        },
    }, { __index = _G })
    assert(load(src:sub(s, e), "=Notes.lua OpenNotesThatApply", "t", env))()
    return UI, frame, here
end

local tests = {}

function tests.opensOnItsPlace_andGoesWhenItEnds()
    local notes = { { id = 1, place = "icc", opensItself = true }, { id = 2, place = "ah" } }
    local UI, frame, here = Load(notes)
    UI:OpenNotesThatApply()
    H.assertFalse(frame.shown, "nowhere yet")
    here.icc = true
    UI:OpenNotesThatApply()
    H.assertTrue(frame.shown, "its place came up")
    H.assertEq(UI._notes.selectedID, 1)
    here.icc = nil
    UI:OpenNotesThatApply()
    H.assertFalse(frame.shown, "its place ended")
end

function tests.onlyNotesSetToOpen()
    local UI, frame, here = Load({ { id = 2, place = "ah" } })
    here.ah = true
    UI:OpenNotesThatApply()
    H.assertFalse(frame.shown)
end

function tests.neverOverAWindowInUse()
    local notes = { { id = 1, place = "ah", opensItself = true } }
    local UI, frame, here = Load(notes)
    UI:EnsureEasyNotesFrame()
    frame.shown = true
    UI._notes.selectedID = 7
    here.ah = true
    UI:OpenNotesThatApply()
    H.assertEq(UI._notes.selectedID, 7, "the note in use stays")
    here.ah = nil
    UI:OpenNotesThatApply()
    H.assertTrue(frame.shown, "a window it did not open stays open")
end

function tests.leftOpenOnAnotherNoteStaysOpen()
    local notes = { { id = 1, place = "ah", opensItself = true } }
    local UI, frame, here = Load(notes)
    here.ah = true
    UI:OpenNotesThatApply()
    UI._notes.selectedID = 3
    here.ah = nil
    UI:OpenNotesThatApply()
    H.assertTrue(frame.shown, "switched to another note: kept open")
end

local pass, fail, failures = H.runSuite("NotesOpensItself", tests)
return { pass = pass, fail = fail, failures = failures }

-- Tests for notes that open by themselves (Apps/Notes/Notes.lua
-- UI:OpenNotesThatApply): a note set to, whose place comes up, opens in
-- a window of its own beside the list (the main window), a second note
-- in another; each goes again when the place ends; a window in use is
-- never taken over; notes not set to never open.

local H = require("Harness")

local function Load(notes)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Notes/Notes.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function UI:OpenNotesThatApply()", 1, true), "OpenNotesThatApply not in Notes.lua")
    local _, e = src:find("\nend\r?\n", s)
    assert(e, "end of OpenNotesThatApply not found")
    local here = {}
    -- The windows: the main one (the list) and those opened beside it.
    local W = { list = {}, shared = {} }
    local function NewWindow(name)
        local frame = { shown = false }
        function frame:IsShown() return self.shown end
        function frame:Show() self.shown = true end
        local w = { name = name, frame = frame }
        W.list[#W.list + 1] = w
        return w
    end
    W.main = NewWindow("main")
    W.active = W.main
    function W.Run(w, fn, ...)
        local prev = W.active
        W.active = w
        local a = fn(...)
        W.active = prev
        return a
    end
    function W.ShowingNote(id)
        for _, w in ipairs(W.list) do
            if w ~= W.main and w.frame.shown and w.selectedID == id then return w end
        end
        return nil
    end
    function W.OpenNote(id)
        local w = W.ShowingNote(id)
        if not w then
            for _, x in ipairs(W.list) do
                if x ~= W.main and not x.frame.shown then w = x break end
            end
        end
        w = w or NewWindow("beside" .. #W.list)
        w.selectedID = id
        w.frame.shown = true
        return w
    end
    local UI = {}
    UI._notes = setmetatable({}, {
        __index = function(_, k) if k == "opensShown" then return W.shared[k] end return W.active[k] end,
        __newindex = function(_, k, v) if k == "opensShown" then W.shared[k] = v else W.active[k] = v end end,
    })
    function UI:CloseEasyNotes() W.active.frame.shown = false end
    -- A note stands for its own condition here: its place, opens, once, keep.
    local env = setmetatable({
        UI = UI,
        time = os.time,
        notesNS = { Windows = W },
        NotesStore = function() return notes end,
        SortedNotes = function() return notes end,
        NormalizeDB = function() end,
        Ctx = {
            Active = function() return {}, here end,
            Holds = function(h, set) return set[h.place] == true end,
            OpensNow = function(n, set) return (n.opens == true and set[n.place] == true) and n or nil end,
            AnyOpens = function(n) return n.opens == true end,
        },
    }, { __index = _G })
    assert(load(src:sub(s, e), "=Notes.lua OpenNotesThatApply", "t", env))()
    return UI, W, here
end

local tests = {}

function tests.opensBesideTheList_andGoesWhenThePlaceEnds()
    local notes = { { id = 1, place = "icc", opens = true }, { id = 2, place = "ah" } }
    local UI, W, here = Load(notes)
    UI:OpenNotesThatApply()
    H.assertEq(#W.list, 1, "nowhere yet")
    here.icc = true
    UI:OpenNotesThatApply()
    H.assertFalse(W.main.frame.shown, "the list stays as it was")
    H.assertEq(#W.list, 2, "a window of its own")
    H.assertEq(W.list[2].selectedID, 1)
    H.assertTrue(W.list[2].frame.shown)
    here.icc = nil
    UI:OpenNotesThatApply()
    H.assertFalse(W.list[2].frame.shown, "its place ended")
end

function tests.onlyNotesSetToOpen()
    local UI, W, here = Load({ { id = 2, place = "ah" } })
    here.ah = true
    UI:OpenNotesThatApply()
    H.assertEq(#W.list, 1)
end

-- A window in use on another note: the note opens in another.
function tests.neverOverAWindowInUse()
    local notes = { { id = 1, place = "ah", opens = true } }
    local UI, W, here = Load(notes)
    local used = W.OpenNote(7)
    here.ah = true
    UI:OpenNotesThatApply()
    H.assertEq(used.selectedID, 7, "the note in use stays")
    H.assertEq(#W.list, 3, "a window of its own")
    H.assertEq(W.list[3].selectedID, 1)
    H.assertTrue(W.list[3].frame.shown)
    here.ah = nil
    UI:OpenNotesThatApply()
    H.assertTrue(used.frame.shown, "a window it did not open stays open")
    H.assertFalse(W.list[3].frame.shown, "the one it opened goes")
end

function tests.leftOpenOnAnotherNoteStaysOpen()
    local notes = { { id = 1, place = "ah", opens = true } }
    local UI, W, here = Load(notes)
    here.ah = true
    UI:OpenNotesThatApply()
    W.list[2].selectedID = 3
    here.ah = nil
    UI:OpenNotesThatApply()
    H.assertTrue(W.list[2].frame.shown, "switched to another note: kept open")
end

-- Two notes set to the same place: both open, one window each.
function tests.twoNotesOpenInTwoWindows()
    local notes = { { id = 1, place = "ah", opens = true }, { id = 2, place = "ah", opens = true } }
    local UI, W, here = Load(notes)
    here.ah = true
    UI:OpenNotesThatApply()
    H.assertEq(#W.list, 3)
    H.assertEq(W.list[2].selectedID, 1)
    H.assertEq(W.list[3].selectedID, 2)
    UI:OpenNotesThatApply()
    H.assertEq(#W.list, 3, "a second look opens nothing twice")
    here.ah = nil
    UI:OpenNotesThatApply()
    H.assertFalse(W.list[2].frame.shown)
    H.assertFalse(W.list[3].frame.shown)
end

-- Only the next time: the opening spends the switch; the window stays
-- while the place lasts, goes when it ends, and the next visit opens nothing.
function tests.onlyTheNextTime_thenTheSwitchIsSpent()
    local notes = { { id = 1, place = "ah", opens = true, once = true } }
    local UI, W, here = Load(notes)
    here.ah = true
    UI:OpenNotesThatApply()
    H.assertTrue(W.list[2].frame.shown, "opened this once")
    H.assertNil(notes[1].opens, "the switch turned itself off")
    H.assertNil(notes[1].once)
    UI:OpenNotesThatApply()
    H.assertTrue(W.list[2].frame.shown, "stays open while the place lasts")
    here.ah = nil
    UI:OpenNotesThatApply()
    H.assertFalse(W.list[2].frame.shown, "goes when the place ends")
    here.ah = true
    UI:OpenNotesThatApply()
    H.assertFalse(W.list[2].frame.shown, "the next visit opens nothing")
end

-- "Close it when this ends" off: the window it opened stays when the place ends.
function tests.keepOn_theWindowStaysWhenThePlaceEnds()
    local notes = { { id = 1, place = "ah", opens = true, keep = true } }
    local UI, W, here = Load(notes)
    here.ah = true
    UI:OpenNotesThatApply()
    H.assertTrue(W.list[2].frame.shown)
    here.ah = nil
    UI:OpenNotesThatApply()
    H.assertTrue(W.list[2].frame.shown, "left to the player")
    H.assertNil(W.list[2].openedFor, "no longer the opener's")
end

-- Closed by the player while the place lasts: it does not come back until
-- the place does.
function tests.closedByHand_staysClosedForThatVisit()
    local notes = { { id = 1, place = "ah", opens = true } }
    local UI, W, here = Load(notes)
    here.ah = true
    UI:OpenNotesThatApply()
    W.list[2].frame.shown = false
    UI:OpenNotesThatApply()
    H.assertFalse(W.list[2].frame.shown, "closed is closed")
    here.ah = nil
    UI:OpenNotesThatApply()
    here.ah = true
    UI:OpenNotesThatApply()
    H.assertTrue(W.list[2].frame.shown, "the next visit opens it again")
end

local pass, fail, failures = H.runSuite("NotesOpensItself", tests)
return { pass = pass, fail = fail, failures = failures }

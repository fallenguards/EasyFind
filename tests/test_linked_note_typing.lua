-- Typing in a linked note (an Auctionator shopping list) sent the caret to
-- the top and undid the last key (Era, 2026-11-02, /efd notecaret): the
-- note's lines went out half a second after the first key, the list came
-- back 0.3 s later as of then, replaced the text and reset the caret to 0.
-- Now the push goes out after the last key, a copy that comes while the
-- note is typed in waits, and a note being typed in keeps its caret.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

-- Told and Holding cut from Lines.lua, timers and the clock in hand.
local function LoadTold()
    local src = Read("Apps/Notes/Lines.lua")
    local s = assert(src:find("local told, edited = {}, {}", 1, true))
    local e = select(2, assert(src:find("\nend\n", assert(src:find("function Lines.Holding(note)", s, true)), true)))
    local timers, now, pushes = {}, 0, {}
    local env = setmetatable({
        Utils = { SafeAfter = function(delay, fn) timers[#timers + 1] = { at = now + delay, fn = fn } end },
        notesNS = { LinkedChanged = function(note) pushes[#pushes + 1] = note.body end },
        Lines = {},
        GetTime = function() return now end,
    }, { __index = _G })
    local Told = assert(load(src:sub(s, e) .. "\nreturn Told", "=Lines.lua told", "t", env))()
    local clock = {}
    function clock.Advance(dt)
        now = now + dt
        for _, t in ipairs(timers) do
            if not t.done and t.at <= now then t.done = true; t.fn() end
        end
    end
    return Told, env.Lines, clock, pushes
end

local tests = {}

function tests.theListHearsTheLinesAfterTheLastKey()
    local Told, Lines, clock, pushes = LoadTold()
    local note = { id = 7, list = { source = { ext = "auctionator", key = "Raid" } }, body = "a" }
    Told(note)
    clock.Advance(0.2)
    note.body = "ab"
    Told(note)
    clock.Advance(0.2)
    note.body = "abc"
    Told(note)
    H.assertTrue(Lines.Holding(note), "a change still to go out holds the list's copy")
    clock.Advance(0.3)
    H.assertEq(#pushes, 0, "half a second after the first key: nothing yet")
    clock.Advance(0.3)
    H.assertEq(#pushes, 1, "one push")
    H.assertEq(pushes[1], "abc", "with the last key in it")
    H.assertFalse(Lines.Holding(note))
end

function tests.aCopyWaitsWhileTheNoteIsTypedIn_andTheCaretStays()
    local notes = Read("Apps/Notes/Notes.lua")
    local s = assert(notes:find("function notesNS.SyncLinked(id, entries)", 1, true))
    local body = notes:sub(s, assert(notes:find("\nend\n", s, true)))
    local hold = body:find("if notesNS.Lines and notesNS.Lines.Holding(note) then", 1, true)
    H.assertTrue(hold ~= nil and hold < body:find("CK.SyncLinked(note, entries)", 1, true), "held before it is written")
    H.assertTrue(body:find("notesNS.Windows.heldSync[id] = entries", 1, true) ~= nil, "the latest copy kept")
    local push = assert(notes:find("function notesNS.LinkedChanged(note)", 1, true))
    local pushBody = notes:sub(push, assert(notes:find("\nend\n", push, true)))
    H.assertTrue(pushBody:find("notesNS.Windows.heldSync[note.id] = nil", 1, true) ~= nil, "a push drops the held copy")
    H.assertTrue(notes:find("local caret = frame.editor:HasFocus() and frame.editor:GetCursorPosition() or 0\n"
        .. "            frame.editor:SetText(wantText)\n"
        .. "            frame.editor:SetCursorPosition(math.min(caret, #wantText))", 1, true) ~= nil,
        "a note being typed in keeps its caret")
    H.assertNil(notes:find("frame.editor:SetText(wantText)\n            frame.editor:SetCursorPosition(0)", 1, true))
end

local pass, fail, failures = H.runSuite("LinkedNoteTyping", tests)
return { pass = pass, fail = fail, failures = failures }

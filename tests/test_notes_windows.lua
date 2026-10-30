-- Notes windows (Apps/Notes/Notes.lua, notesNS.Windows): any number of
-- full notes windows from the one builder. The module's per-window state
-- follows the window in use through UI._notes; a window's frames, timers
-- and callbacks run as that window; the last one used stands between.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function FakeFrame()
    local f = { scripts = {}, shown = false }
    function f:SetScript(name, fn) self.scripts[name] = fn end
    function f:HookScript(name, fn) self.scripts[name] = fn end
    function f:IsShown() return self.shown end
    return f
end

local function Load()
    local src = Read("Apps/Notes/Notes.lua")
    local s = assert(src:find("-- Notes windows: the main one", 1, true))
    local e = assert(src:find("local function GetSelectedNote()", s, true))
    local timers = {}
    local env = setmetatable({
        UI = {}, notesNS = {}, Utils = {}, NormalizeDB = function() end,
        CreateFrame = function() return FakeFrame() end,
        ns = { Utils = { SafeAfter = function(_, fn) timers[#timers + 1] = fn end, Other = "kept" } },
    }, { __index = _G })
    assert(load(src:sub(s, e - 1), "=Notes.lua Windows", "t", env))()
    return env, env.notesNS.Windows, timers
end

local tests = {}

function tests.keysOfAWindowFollowTheWindowInUse()
    local env, W = Load()
    local UI = env.UI
    UI._notes.selectedID = 5
    UI._notes.toolbarShown = true
    H.assertEq(W.main.selectedID, 5, "a window key on the main window")
    H.assertEq(W.shared.toolbarShown, true, "a shared key beside it")
    local other = W.New("EasyNotesFrame2")
    W.Run(other, function() UI._notes.selectedID = 9 end)
    H.assertEq(other.selectedID, 9)
    H.assertEq(UI._notes.selectedID, 5, "the main window again after the run")
    H.assertEq(W.active, W.main)
    H.assertEq(W.list[2], other)
end

function tests.aWindowsFramesScriptsRunAsIt()
    local env, W = Load()
    local other = W.New("EasyNotesFrame2")
    other.selectedID = 9
    local f = W.Run(other, function() return env.CreateFrame("Button") end)
    local seen
    f:SetScript("OnClick", function() seen = env.UI._notes.selectedID end)
    f.scripts.OnClick()
    H.assertEq(seen, 9, "the click acted on its window")
    H.assertEq(W.last, other, "a hand on it makes it the window used")
    H.assertEq(W.active, W.main, "and the state goes back after")
    f:SetScript("OnClick", nil)
    H.assertNil(f.scripts.OnClick, "nil clears a script as before")
end

function tests.aTimerAndACallbackRunAsTheirWindow()
    local env, W, timers = Load()
    local other = W.New("EasyNotesFrame2")
    other.selectedID = 9
    local seen, cb
    W.Run(other, function()
        env.Utils.SafeAfter(0, function() seen = env.UI._notes.selectedID end)
        cb = W.Bound(function() return env.UI._notes.selectedID end)
    end)
    H.assertEq(env.Utils.Other, "kept", "the rest of Utils reads through")
    timers[1]()
    H.assertEq(seen, 9, "the timer ran as its window")
    H.assertEq(cb(), 9, "the bound callback too")
end

function tests.freeWindowsAndTheOneShowingANote()
    local env, W = Load()
    W.main.frame = FakeFrame()
    W.main.frame.shown = true
    W.main.selectedID = 4
    H.assertEq(W.ShowingNote(4), W.main)
    H.assertNil(W.ShowingNote(5))
    local fresh = W.Free()
    H.assertEq(fresh.name, "EasyNotesFrame2", "none free: a new one, named in order")
    fresh.frame = FakeFrame()
    H.assertEq(W.Free(), fresh, "a closed one beside the main is free")
    fresh.frame.shown = true
    H.assertEq(W.Free().name, "EasyNotesFrame3")
    H.assertEq(env.CreateFrame, W.CreateFrame, "frames made here are the windows'")
end

function tests.theChecklistViewKeepsASetPerWindow()
    local src = Read("Apps/Notes/ChecklistView.lua")
    H.assertTrue(src:find("View.States[w]", 1, true) ~= nil, "a state per window")
    H.assertTrue(src:find("local CreateFrame, time = notesNS.Windows.CreateFrame, time", 1, true) ~= nil, "its frames are the windows'")
    H.assertTrue(src:find("notesNS.Windows.Each(View.Refresh)", 1, true) ~= nil, "events refresh every window")
end

local pass, fail, failures = H.runSuite("NotesWindows", tests)
return { pass = pass, fail = fail, failures = failures }

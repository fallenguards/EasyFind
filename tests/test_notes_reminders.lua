-- Notes reminders (Apps/Notes/Reminders.lua): a note holds several, listed
-- soonest first with an X each; a custom time and a repeat; a due one says
-- so once and a repeating one comes round again (2026-10-26: one reminder a
-- note, presets only, and a lone "Clear reminder").
local H = require("Harness")

local function Load()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.date, env.time = os.date, os.time
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    local said = {}
    env.EasyFind.Print = function(_, msg) said[#said + 1] = msg end
    env.GetCVarBool = function() return true end
    local notesNS = { UI = {}, NoteTitle = function(note) return note.name end }
    H.loadModule("Apps/Notes/Reminders.lua", env, notesNS)
    return notesNS.Reminders, said
end

local function At(y, m, d, h, min)
    return os.time({ year = y, month = m, day = d, hour = h or 12, min = min or 0 })
end

local tests = {}

function tests.severalReminders_listSoonestFirst_eachWithItsX()
    local R = Load()
    local note = { name = "Raid prep" }
    R.Add(note, At(2026, 11, 3))
    R.Add(note, At(2026, 11, 1))
    local rows = R.MenuRows(note)
    H.assertTrue(rows[1].remove and rows[2].remove, "each listed reminder has its X")
    H.assertEq(R.List(note)[1].at, At(2026, 11, 1), "soonest first")
    rows[1].remove()
    H.assertEq(#R.List(note), 1)
    H.assertEq(R.List(note)[1].at, At(2026, 11, 3), "the other stays")
end

function tests.quickPicksAdd_andClearAllShowsForSeveral()
    local R = Load()
    local note = { name = "N" }
    local function Find(rows, label)
        for _, r in ipairs(rows) do if r.text == label then return r end end
    end
    Find(R.MenuRows(note), "NOTES_REMIND_1H").onClick()
    H.assertTrue(Find(R.MenuRows(note), "NOTES_REMIND_1H").keepOpen, "the menu stays to show what was set")
    H.assertNil(Find(R.MenuRows(note), "NOTES_REMIND_CLEAR_ALL"), "one reminder: its X is enough")
    Find(R.MenuRows(note), "NOTES_REMIND_1W").onClick()
    Find(R.MenuRows(note), "NOTES_REMIND_CLEAR_ALL").onClick()
    H.assertEq(#R.List(note), 0)
    H.assertTrue(Find(R.MenuRows(note), "NOTES_REMIND_CUSTOM") ~= nil, "a custom time, not presets only")
end

function tests.next_keepsTheTimeOfDay_andTheMonthsOwnDay()
    local R = Load()
    H.assertEq(R.Next({ at = At(2026, 10, 26, 18, 30), rep = "day" }, At(2026, 10, 27, 9)), At(2026, 10, 27, 18, 30))
    H.assertEq(R.Next({ at = At(2026, 10, 26, 18, 30), rep = "week" }, At(2026, 10, 27)), At(2026, 11, 2, 18, 30))
    H.assertEq(R.Next({ at = At(2027, 1, 31), rep = "month", day = 31 }, At(2027, 2, 1)), At(2027, 2, 28),
        "the 31st falls on a short month's last day")
    H.assertEq(R.Next({ at = At(2027, 2, 28), rep = "month", day = 31 }, At(2027, 3, 1)), At(2027, 3, 31),
        "and back to the 31st after it")
    H.assertEq(R.Next({ at = At(2028, 2, 29), rep = "year", day = 29 }, At(2028, 3, 1)), At(2029, 2, 28))
    -- 2026-10-26 is a Monday: Wednesdays and Fridays.
    local r = { at = At(2026, 10, 26, 20), rep = "days", days = { [4] = true, [6] = true } }
    H.assertEq(R.Next(r, At(2026, 10, 26, 21)), At(2026, 10, 28, 20))
    H.assertNil(R.Next({ at = At(2026, 10, 26) }, At(2026, 10, 27)), "a one-time reminder has no next")
end

function tests.aDueReminder_saysSoOnce_aRepeatingOneComesRound()
    local R, said = Load()
    local note = { name = "Dailies", reminders = {
        { at = At(2026, 10, 26, 9) }, { at = At(2026, 10, 26, 10), rep = "day" } } }
    R.CheckDue({ note }, At(2026, 10, 26, 11))
    H.assertEq(#said, 2)
    H.assertEq(#note.reminders, 1, "the one-time one is gone")
    H.assertEq(note.reminders[1].at, At(2026, 10, 27, 10), "the daily one is tomorrow")
    R.CheckDue({ note }, At(2026, 10, 26, 12))
    H.assertEq(#said, 2, "nothing twice")
end

function tests.anOlderSingleReminder_joinsTheList()
    local R = Load()
    local note = { name = "Old", reminderAt = At(2026, 11, 1) }
    H.assertEq(#R.List(note), 1)
    H.assertNil(note.reminderAt)
end

function tests.typedTimes_read()
    local R = Load()
    for text, want in pairs({ ["18:30"] = { 18, 30 }, ["6:05"] = { 6, 5 }, ["6pm"] = { 18, 0 },
                               ["6:30 PM"] = { 18, 30 }, ["12am"] = { 0, 0 }, ["18"] = { 18, 0 } }) do
        local h, m = R.ParseClock(text)
        H.assertEq(h, want[1], text)
        H.assertEq(m, want[2], text)
    end
    H.assertNil(R.ParseClock("25:00"))
    H.assertNil(R.ParseClock("soon"))
end

local pass, fail, failures = H.runSuite("NotesReminders", tests)
return { pass = pass, fail = fail, failures = failures }

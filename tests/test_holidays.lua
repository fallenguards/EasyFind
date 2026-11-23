-- Holidays (2026-11-19): the calendar's holidays as rows with how long
-- until each starts or ends, "next holiday", and the calendar opened on
-- a holiday's day. The game's month offsets count from the month its
-- calendar window shows, which is not always today's.
local H = require("Harness")

-- Today is 2026-11-19. The window was left on January 2027 (offset 0).
local EVENTS = {
    ["2026-11"] = {
        [19] = { { title = "Pilgrim's Bounty", type = "HOLIDAY", from = { 2026, 11, 17 }, to = { 2026, 11, 24 } },
                 { title = "Guild Raid", type = "GUILD_EVENT", from = { 2026, 11, 19 }, to = { 2026, 11, 19 } } },
        [20] = { { title = "Pilgrim's Bounty", type = "HOLIDAY", from = { 2026, 11, 17 }, to = { 2026, 11, 24 } } },
        [3] = { { title = "Day of the Dead", type = "HOLIDAY", from = { 2026, 11, 1 }, to = { 2026, 11, 3 } } },
    },
    ["2026-12"] = {
        [6] = { { title = "Darkmoon Faire", type = "HOLIDAY", from = { 2026, 12, 6 }, to = { 2026, 12, 12 } } },
        [16] = { { title = "Feast of Winter Veil", type = "HOLIDAY", from = { 2026, 12, 16 }, to = { 2027, 1, 2 } } },
    },
    ["2027-01"] = {
        [3] = { { title = "Darkmoon Faire", type = "HOLIDAY", from = { 2027, 1, 3 }, to = { 2027, 1, 9 } } },
    },
    ["2027-06"] = {
        [21] = { { title = "Midsummer Fire Festival", type = "HOLIDAY", from = { 2027, 6, 21 }, to = { 2027, 7, 5 } } },
    },
}

local function World(opts)
    opts = opts or {}
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    ns.Caps = { calendar = opts.calendar ~= false }
    ns.L.HOLIDAY_STARTS_FMT, ns.L.HOLIDAY_ENDS_FMT = "Starts in %s (%s)", "Now, ends in %s (%s)"
    env.time = os.time
    env.D_DAYS = "%d Days"
    local t = { opened = 0, shownMonth = { 2027, 1 }, clicked = nil, sent = opts.sent ~= false, frames = {} }
    env.CreateFrame = function()
        local f = H.newFrame()
        t.frames[#t.frames + 1] = f
        return f
    end
    env.C_DateAndTime = { GetCurrentCalendarTime = function() return { year = 2026, month = 11, monthDay = 19 } end }
    env.C_ChatInfo = { InChatMessagingLockdown = function() return t.locked == true end }
    local function Month(offset)
        local n = t.shownMonth[1] * 12 + t.shownMonth[2] - 1 + offset
        return math.floor(n / 12), n % 12 + 1
    end
    -- As the game: an answer for the month set and the one each side of it,
    -- nothing further off (read on Forever, 2026-11-21).
    local function Day(offset, day)
        if not t.sent or offset < -1 or offset > 1 then return {} end
        local year, month = Month(offset)
        local m = EVENTS[string.format("%d-%02d", year, month)]
        return m and m[day] or {}
    end
    local function Date(d) return { year = d[1], month = d[2], monthDay = d[3] } end
    env.C_Calendar = {
        GetMonthInfo = function(offset)
            local year, month = Month(offset or 0)
            return { year = year, month = month, numDays = 30, firstWeekday = 3 }
        end,
        GetNumDayEvents = function(offset, day) return #Day(offset, day) end,
        GetDayEvent = function(offset, day, i)
            -- In a chat lockdown the game's answer is secret: any compare on it throws.
            if t.locked then error("attempt to compare a secret string value") end
            local e = Day(offset, day)[i]
            return { title = e.title, calendarType = e.type, startTime = Date(e.from), endTime = Date(e.to), iconTexture = 1 }
        end,
        OpenCalendar = function() t.opened = t.opened + 1 end,
        OpenEvent = function(offset, day, index) t.event = { offset, day, index } end,
        SetAbsMonth = function(month, year) t.shownMonth = { year, month } end,
    }
    ns.Database.uiSearchData = {}
    ns.Database.RemoveEntriesByCategory = function(category)
        local data = ns.Database.uiSearchData
        for i = #data, 1, -1 do if data[i].category == category then table.remove(data, i) end end
    end
    local dirty = {}
    ns.Database.MarkDynamicCategoryDirty = function(_, key) dirty[#dirty + 1] = key end
    t.dirty = dirty
    H.loadModule("Database/Holidays.lua", env, ns)
    return ns, t, env
end

local function Names(ns)
    local out = {}
    for i, row in ipairs(ns.Database.uiSearchData) do out[i] = row.name end
    return table.concat(out, ", ")
end

local tests = {}

function tests.eachHolidayOnce_fromTodayOn_whateverMonthTheCalendarShows()
    local ns, t = World()
    H.assertTrue(ns.Database:PopulateDynamicHolidays())
    H.assertEq(Names(ns), "Pilgrim's Bounty, Darkmoon Faire, Feast of Winter Veil, Midsummer Fire Festival",
        "no past holiday, no guild event, the faire once at its next days, and one seven months off")
    H.assertEq(t.shownMonth[1] * 100 + t.shownMonth[2], 202701, "the calendar is put back on the month it showed")
    local row = ns.Database.uiSearchData[2]
    H.assertEq(row.category, "Holiday")
    H.assertEq(row.holidayStart.month, 12)
    H.assertEq(row.holidayDay.monthDay, 6)
    H.assertEq(ns.Database.uiSearchData[1].holidayDay.monthDay, 19, "one running now opens on today")
end

function tests.aRowSaysWhenItStartsOrEnds()
    local ns = World()
    ns.Database:PopulateDynamicHolidays()
    local rows = ns.Database.uiSearchData
    H.assertEq(ns.Holidays.Line(rows[1]), "Now, ends in 5 Days (11/24)")
    H.assertEq(ns.Holidays.Line(rows[2]), "Starts in 17 Days (12/6)")
    rows[1].holidayEnd = { year = 2026, month = 11, monthDay = 19 }
    H.assertEq(ns.Holidays.Line(rows[1]), "HOLIDAY_ENDS_TODAY")
end

function tests.nextHoliday_isTheSoonestToStart()
    local ns = World()
    H.assertNil(ns.Holidays.Next(), "nothing read yet")
    ns.Database:PopulateDynamicHolidays()
    H.assertEq(ns.Holidays.Next(), "Darkmoon Faire: Starts in 17 Days (12/6)", "not the one already running")
end

function tests.noCalendarYet_itIsAskedForOnce_andReadWhenItArrives()
    local ns, t = World({ sent = false })
    H.assertFalse(ns.Database:PopulateDynamicHolidays(), "not ready")
    H.assertEq(t.opened, 1, "the game is asked for its calendar")
    local watcher = t.frames[1]
    watcher._handlers.OnEvent(watcher, "CALENDAR_UPDATE_EVENT_LIST")
    H.assertEq(t.dirty[1], "holidays", "its arrival has the rows made")
    t.sent = true
    H.assertTrue(ns.Database:PopulateDynamicHolidays())
    H.assertEq(#ns.Database.uiSearchData, 4)
    watcher._handlers.OnEvent(watcher, "CALENDAR_UPDATE_EVENT_LIST")
    H.assertEq(#t.dirty, 1, "a later month flip in the window makes nothing again")
end

-- Reading the months may send the calendar's news again: an empty one is
-- not asked for ever.
function tests.anEmptyCalendar_isReadAFewTimes_notForEver()
    local ns, t = World({ sent = false })
    ns.Database:PopulateDynamicHolidays()
    local watcher = t.frames[1]
    for _ = 1, 20 do watcher._handlers.OnEvent(watcher, "CALENDAR_UPDATE_EVENT_LIST") end
    H.assertEq(#t.dirty, 4)
end

-- Forever, 2026-11-23: in a boss fight the holiday read threw four times
-- ("attempt to compare a secret string value").
function tests.inAChatLockdown_theCalendarWaits_andIsReadWhenItEnds()
    local ns, t, env = World()
    t.locked = true
    H.assertFalse(ns.Database:PopulateDynamicHolidays(), "not read in the lockdown")
    H.assertEq(#ns.Database.uiSearchData, 0)
    local watcher = t.frames[1]
    watcher._handlers.OnEvent(watcher, "ADDON_RESTRICTION_STATE_CHANGED", 5, 2)
    env._clock:advance(1)
    H.assertEq(#t.dirty, 0, "another restriction while still locked asks nothing")
    -- The client still reads the restriction active while it sends the news.
    watcher._handlers.OnEvent(watcher, "ADDON_RESTRICTION_STATE_CHANGED", 5, 0)
    t.locked = false
    H.assertEq(#t.dirty, 0, "not inside the event")
    env._clock:advance(1)
    H.assertEq(t.dirty[1], "holidays", "its end has the rows made")
    H.assertTrue(ns.Database:PopulateDynamicHolidays())
    H.assertEq(#ns.Database.uiSearchData, 4)
    watcher._handlers.OnEvent(watcher, "ADDON_RESTRICTION_STATE_CHANGED", 5, 0)
    env._clock:advance(1)
    H.assertEq(#t.dirty, 1, "once")
end

function tests.rowsMadeBeforeALockdown_stayThroughIt()
    local ns, t = World()
    ns.Database:PopulateDynamicHolidays()
    t.locked = true
    H.assertFalse(ns.Database:PopulateDynamicHolidays())
    H.assertEq(#ns.Database.uiSearchData, 4)
    H.assertEq(ns.Holidays.Next(), "Darkmoon Faire: Starts in 17 Days (12/6)")
end

function tests.aClientWithoutTheCalendar_hasNoRows()
    local ns, t = World({ calendar = false })
    H.assertTrue(ns.Database:PopulateDynamicHolidays())
    H.assertEq(#ns.Database.uiSearchData, 0)
    H.assertEq(t.opened, 0)
end

function tests.aClick_opensTheCalendarOnTheHolidaysDay()
    local ns, t, env = World()
    ns.Database:PopulateDynamicHolidays()
    local shownPanel, updated
    env.Calendar_LoadUI = function() return true end
    env.CalendarFrame = { IsShown = function() return false end }
    ns.SearchOpeners = { SecureShowUIPanel = function(_, frame) shownPanel = frame end }
    env.InCombatLockdown = function() return false end
    env.CalendarFrame_Update = function() updated = true end
    env.CALENDAR_FIRST_WEEKDAY = 1
    env.CalendarDayButton_Click = function(button) t.clicked = button end
    for i = 1, 42 do env["CalendarDayButton" .. i] = { index = i } end
    ns.Holidays.Open(ns.Database.uiSearchData[2])
    H.assertTrue(shownPanel == env.CalendarFrame, "the window, through the secure opener")
    H.assertEq(t.shownMonth[2], 12, "on December")
    H.assertTrue(updated)
    H.assertEq(t.clicked.index, 6 + 3 - 1, "the 6th's cell, the month starting on the third weekday")
    H.assertEq(table.concat(t.event, ","), "0,6,1", "and the holiday itself opened on that day, not the day alone")
end

-- The row's click asked ns.Openers for the window, a name nothing
-- defines, and this file's stand-in bore the same wrong name (the first
-- click threw, Forever, 2026-11-21). Whoever a shipped file asks to show
-- a panel is a name the addon sets.
function tests.thePanelOpener_isANameTheAddonSets()
    local function read(rel)
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
        local src = f:read("*a")
        f:close()
        return src
    end
    -- Search/Modules.lua makes the search's namespaces from its list of names.
    local set = {}
    for name in read("Search/Modules.lua"):gmatch('"([%w_]+)"') do set[name] = true end
    local asked = 0
    for _, rel in ipairs({ "Database/Holidays.lua", "Guide/DirectOpen.lua" }) do
        for name in read(rel):gmatch("ns%.([%w_]+):SecureShowUIPanel") do
            asked = asked + 1
            H.assertTrue(set[name] == true, rel .. " asks ns." .. name .. ", which Search/Modules.lua never makes")
        end
    end
    H.assertTrue(asked >= 1, "the holiday row's ask was read")
end

local pass, fail, failures = H.runSuite("Holidays", tests)
return { pass = pass, fail = fail, failures = failures }

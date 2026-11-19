local _, ns = ...

-- The calendar's holidays as rows ("darkmoon", "brewfest"): each one's
-- next days, with how long until it starts or ends. A click opens the
-- calendar on its day; "next holiday" answers the soonest.
local Holidays = {}
ns.Holidays = Holidays

local Database, Utils, L = ns.Database, ns.Utils, ns.L
local sformat, slower = Utils.sformat, Utils.slower
local C_Calendar, C_DateAndTime = C_Calendar, C_DateAndTime

local MONTHS_AHEAD = 12
local CATEGORY = "Holiday"
-- The game's art for a holiday is a calendar cell's, not an icon.
local GLYPH = { tex = 134939 }

-- A calendar date as a count of days: noon, clear of any clock change.
local function DayNumber(date)
    return math.floor(time({ year = date.year, month = date.month, day = date.monthDay, hour = 12 }) / 86400)
end

local function DateText(date)
    if FormatShortDate then return FormatShortDate(date.monthDay, date.month) end
    return sformat("%d/%d", date.month, date.monthDay)
end

local function Days(count)
    return sformat(_G["D_DAYS"] or "%d Days", count)
end

-- "Now, ends in 3 Days (11/26)" or "Starts in 12 Days (12/1)".
function Holidays.Line(row)
    local now = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime and C_DateAndTime.GetCurrentCalendarTime()
    if not (now and row.holidayStart and row.holidayEnd) then return "" end
    local today, first, last = DayNumber(now), DayNumber(row.holidayStart), DayNumber(row.holidayEnd)
    if today < first then return sformat(L["HOLIDAY_STARTS_FMT"], Days(first - today), DateText(row.holidayStart)) end
    if today >= last then return L["HOLIDAY_ENDS_TODAY"] end
    return sformat(L["HOLIDAY_ENDS_FMT"], Days(last - today), DateText(row.holidayEnd))
end

local listed, asked = {}, false

-- The holiday running now that ends first, else the next to start:
-- "Darkmoon Faire: Starts in 12 Days (12/1)".
function Holidays.Next()
    local now = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime and C_DateAndTime.GetCurrentCalendarTime()
    if not now or #listed == 0 then return nil end
    local today, best, bestDay = DayNumber(now), nil, nil
    for i = 1, #listed do
        local row = listed[i]
        local first = DayNumber(row.holidayStart)
        if first > today and (not bestDay or first < bestDay) then best, bestDay = row, first end
    end
    return best and (best.name .. ": " .. Holidays.Line(best)) or nil
end

local function Words()
    local kw = { "holiday", "holidays", "event", "events", "calendar" }
    local own = _G["CALENDAR_FILTER_HOLIDAYS"]
    if own then kw[#kw + 1] = slower(own) end
    return kw
end

-- Each holiday from today on, at its first day found. The game answers
-- for the month its calendar is set to and little past it (two months of
-- thirteen by offset: no Hallow's End, 2026-11-21), so each month is set
-- in turn, read in one go, and the calendar put back on the month it was.
local function ReadMonths(today, shown)
    local found, seen = {}, {}
    for ahead = 0, MONTHS_AHEAD do
        local count = today.month - 1 + ahead
        local year, month = today.year + math.floor(count / 12), count % 12 + 1
        C_Calendar.SetAbsMonth(month, year)
        local info = C_Calendar.GetMonthInfo(0)
        for day = ahead == 0 and today.monthDay or 1, info and info.numDays or 0 do
            for index = 1, C_Calendar.GetNumDayEvents(0, day) or 0 do
                local event = C_Calendar.GetDayEvent(0, day, index)
                local title = event and event.calendarType == "HOLIDAY" and event.title
                if title and title ~= "" and not seen[title] and event.startTime and event.endTime then
                    seen[title] = true
                    found[#found + 1] = { title = title, first = event.startTime, last = event.endTime,
                                          year = year, month = month, day = day }
                end
            end
        end
    end
    C_Calendar.SetAbsMonth(shown.month, shown.year)
    return found
end

-- Every holiday from today on, once each at its next days.
function Database:PopulateDynamicHolidays()
    Database.RemoveEntriesByCategory(CATEGORY)
    if self.ResetSearchCache then self:ResetSearchCache() end
    wipe(listed)
    if not (ns.Caps.calendar and C_Calendar and C_Calendar.GetMonthInfo and C_Calendar.GetNumDayEvents
            and C_Calendar.GetDayEvent and C_Calendar.SetAbsMonth and C_DateAndTime
            and C_DateAndTime.GetCurrentCalendarTime) then
        return true
    end
    local today, shown = C_DateAndTime.GetCurrentCalendarTime(), C_Calendar.GetMonthInfo(0)
    if not (today and shown) then return false end
    local rows, words = self.uiSearchData, Words()
    local found = ReadMonths(today, shown)
    for i = 1, #found do
        Utils.SliceCheckpoint()
        local event = found[i]
        local lower = slower(event.title)
        local kw = { lower }
        for w = 1, #words do kw[#kw + 1] = words[w] end
        local row = {
            name = event.title, nameLower = lower, category = CATEGORY, keywords = kw, keywordsLower = kw,
            glyph = GLYPH, noPin = true,
            holidayStart = { year = event.first.year, month = event.first.month, monthDay = event.first.monthDay },
            holidayEnd = { year = event.last.year, month = event.last.month, monthDay = event.last.monthDay },
            -- The day to open: today while it runs, else its first.
            holidayDay = { year = event.year, month = event.month, monthDay = event.day },
        }
        rows[#rows + 1] = row
        listed[#listed + 1] = row
    end
    -- Nothing yet: the game sends its calendar once asked.
    if #listed == 0 and not asked and C_Calendar.OpenCalendar then
        asked = true
        C_Calendar.OpenCalendar()
        return false
    end
    return true
end

-- The calendar's first answer brings the rows; a read of its months may
-- send this news again, so an empty calendar is asked a few times only.
local watcher, emptyReads = CreateFrame("Frame"), 0
Utils.RegisterEventIfValid(watcher, "CALENDAR_UPDATE_EVENT_LIST")
watcher:SetScript("OnEvent", function()
    if #listed > 0 then
        emptyReads = 0
    elseif emptyReads < 4 and Database.MarkDynamicCategoryDirty then
        emptyReads = emptyReads + 1
        Database:MarkDynamicCategoryDirty("holidays")
    end
end)

-- The calendar window on the holiday's month, its day selected and the
-- holiday itself opened there, as a click on it in its cell: the game's
-- mark on a selected day alone is faint (2026-11-21).
function Holidays.Open(row)
    local day = row.holidayDay
    if not (day and Calendar_LoadUI and Calendar_LoadUI()) or InCombatLockdown() then return end
    local frame = _G["CalendarFrame"]
    if not frame then return end
    if not frame:IsShown() then ns.SearchOpeners:SecureShowUIPanel(frame) end
    C_Calendar.SetAbsMonth(day.month, day.year)
    local update, click = _G["CalendarFrame_Update"], _G["CalendarDayButton_Click"]
    if update then update() end
    -- The day's button, counted as the window counts them.
    local month, firstWeekday = C_Calendar.GetMonthInfo(0), _G["CALENDAR_FIRST_WEEKDAY"] or 1
    if not (month and click) then return end
    local index = day.monthDay + month.firstWeekday - firstWeekday
    if month.firstWeekday < firstWeekday then index = index + 7 end
    local button = _G["CalendarDayButton" .. index]
    if not button then return end
    click(button)
    if not C_Calendar.OpenEvent then return end
    for i = 1, C_Calendar.GetNumDayEvents(0, day.monthDay) or 0 do
        local event = C_Calendar.GetDayEvent(0, day.monthDay, i)
        if event and event.title == row.name then
            C_Calendar.OpenEvent(0, day.monthDay, i)
            return
        end
    end
end

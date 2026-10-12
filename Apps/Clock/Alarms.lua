local ns = EasyFind and EasyFind._ns
if not (ns and ns.ClockRuns and ns.ClockGrammar) then return end

local Utils = ns.Utils
local Grammar, Runs = ns.ClockGrammar, ns.ClockRuns
local type, tremove, tsort = type, Utils.tremove, Utils.tsort

-- The kept alarms, as a phone's clock keeps them: a time, a name, the days
-- it repeats on, realm or local time, and a switch. Saved in EasyClockDB.
local Alarms = {}
ns.ClockAlarms = Alarms

Alarms.MAX = 20

local function IsNumber(v)
    return type(v) == "number" and v == v
end

local function IsValid(a)
    return type(a) == "table" and IsNumber(a.id) and IsNumber(a.hour) and a.hour >= 0 and a.hour <= 23
        and IsNumber(a.min) and a.min >= 0 and a.min <= 59
        and IsNumber(a.days) and a.days >= 0 and a.days <= 127
        and (a.name == nil or type(a.name) == "string")
        and (a.next == nil or IsNumber(a.next))
end

-- Takes the saved table Runs:Attach prepared.
function Alarms:Attach(sv)
    self.sv = sv
    local list = sv.alarms
    for i = #list, 1, -1 do
        local a = list[i]
        if not IsValid(a) then
            tremove(list, i)
        else
            a.enabled = a.enabled and true or false
            a.server = a.server and true or nil
            if not a.enabled then a.next = nil end
        end
    end
end

function Alarms:List()
    return self.sv and self.sv.alarms or {}
end

local function Offset(alarm, now)
    return alarm.server and Grammar.ServerOffset(now) or 0
end

-- The next ring after `now`.
function Alarms:Arm(alarm, now)
    alarm.next = Grammar.NextOccurrence(alarm.hour, alarm.min, alarm.days, true, now, Offset(alarm, now))
    alarm.armedAt = now
end

function Alarms:Find(id)
    local list = self:List()
    for i = 1, #list do
        if list[i].id == id then return list[i] end
    end
    return nil
end

-- A new alarm, switched on; the same alarm again is switched back on. nil
-- when the list is full.
function Alarms:Add(now, hour, minute, days, name, server)
    local list = self:List()
    days, name, server = days or 0, Runs.CleanName(name), server and true or nil
    for i = 1, #list do
        local a = list[i]
        if a.hour == hour and a.min == minute and a.days == days and a.name == name and a.server == server then
            a.enabled = true
            self:Arm(a, now)
            return a
        end
    end
    if #list >= Alarms.MAX then return nil end
    local sv = self.sv
    local a = { id = sv.nextAlarmID, hour = hour, min = minute, days = days, name = name, server = server, enabled = true }
    sv.nextAlarmID = sv.nextAlarmID + 1
    list[#list + 1] = a
    self:Arm(a, now)
    return a
end

function Alarms:SetEnabled(alarm, on, now)
    alarm.enabled = on and true or false
    if alarm.enabled then
        self:Arm(alarm, now)
    else
        alarm.next = nil
    end
end

-- New time, name, days or clock; a switched-on alarm arms for the new time.
function Alarms:Edit(alarm, now, hour, minute, days, name, server)
    alarm.hour, alarm.min, alarm.days = hour, minute, days or 0
    alarm.name, alarm.server = Runs.CleanName(name), server and true or nil
    if alarm.enabled then self:Arm(alarm, now) end
end

function Alarms:Delete(alarm)
    local list = self:List()
    for i = #list, 1, -1 do
        if list[i] == alarm then tremove(list, i) end
    end
end

-- Switched-on alarms whose time has come, into `out`.
function Alarms:Due(now, out)
    local list = self:List()
    for i = 1, #list do
        local a = list[i]
        if a.enabled and a.next and a.next <= now then out[#out + 1] = a end
    end
    return out
end

-- After a ring: a repeating alarm arms for its next day, a one-off
-- switches itself off.
function Alarms:Rang(alarm, now)
    if alarm.days ~= 0 then
        self:Arm(alarm, now)
    else
        alarm.enabled, alarm.next = false, nil
    end
end

-- Switched-on alarms without a next ring get one (a login, a new day).
function Alarms:ArmAll(now)
    local list = self:List()
    for i = 1, #list do
        local a = list[i]
        if a.enabled and not a.next then self:Arm(a, now) end
    end
end

function Alarms:AnyOn()
    local list = self:List()
    for i = 1, #list do
        if list[i].enabled then return true end
    end
    return false
end

function Alarms:Soonest()
    local best
    local list = self:List()
    for i = 1, #list do
        local a = list[i]
        if a.enabled and a.next and (not best or a.next < best.next) then best = a end
    end
    return best
end

local function ByClock(a, b)
    if a.hour ~= b.hour then return a.hour < b.hour end
    if a.min ~= b.min then return a.min < b.min end
    return a.id < b.id
end

-- The list in clock order, as the window shows it.
function Alarms:Sorted(out)
    local list = self:List()
    for i = #out, 1, -1 do out[i] = nil end
    for i = 1, #list do out[i] = list[i] end
    tsort(out, ByClock)
    return out
end

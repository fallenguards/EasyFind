local _, AL = ...
local ns = EasyFind and EasyFind._ns
if not ns then return end

-- Saved alerts (EasyAlertsDB, account wide): the rules and what each
-- character last read, so a cooldown or a lockout on an alt can ring here.
local Store = {}
AL.Store = Store

local type, pairs, ipairs, tremove = type, pairs, ipairs, table.remove

local DB_VERSION = 1
local MIGRATIONS = {}

local DEFAULT_SIGNALS = { chat = true, big = true, sound = "alarm", taskbar = true }
Store.DEFAULT_SIGNALS = DEFAULT_SIGNALS

local function CopySignals(src)
    local s = {}
    for k, v in pairs(src or DEFAULT_SIGNALS) do s[k] = v end
    return s
end

local function ValidRule(rule)
    return type(rule) == "table" and type(rule.id) == "number"
        and type(rule.trigger) == "table" and type(rule.trigger.kind) == "string"
end

-- The saved table (or nil), migrated and cleaned.
function Store:Attach(sv)
    if type(sv) ~= "table" then sv = {} end
    local from = type(sv.version) == "number" and sv.version or 0
    for v = from + 1, DB_VERSION do
        if MIGRATIONS[v] then MIGRATIONS[v](sv) end
    end
    sv.version = DB_VERSION
    if type(sv.rules) ~= "table" then sv.rules = {} end
    if type(sv.chars) ~= "table" then sv.chars = {} end
    if type(sv.nextID) ~= "number" then sv.nextID = 1 end
    local rules = sv.rules
    for i = #rules, 1, -1 do
        local rule = rules[i]
        if not ValidRule(rule) then
            tremove(rules, i)
        else
            if type(rule.conds) ~= "table" then rule.conds = {} end
            if type(rule.signals) ~= "table" then rule.signals = CopySignals() end
            if rule.id >= sv.nextID then sv.nextID = rule.id + 1 end
        end
    end
    self.sv = sv
    return sv
end

function Store:Rules()
    return self.sv.rules
end

function Store:AnyOn()
    for _, rule in ipairs(self.sv.rules) do
        if rule.on then return true end
    end
    return false
end

function Store:Find(id)
    for i, rule in ipairs(self.sv.rules) do
        if rule.id == id then return rule, i end
    end
end

-- A new rule from a trigger (a template's or the builder's), switched on.
function Store:New(trigger, fields)
    local rule = {
        id = self.sv.nextID,
        on = true,
        trigger = trigger,
        conds = {},
        signals = CopySignals(),
    }
    for k, v in pairs(fields or {}) do rule[k] = v end
    self.sv.nextID = self.sv.nextID + 1
    self.sv.rules[#self.sv.rules + 1] = rule
    return rule
end

function Store:Delete(id)
    local _, i = self:Find(id)
    if i then tremove(self.sv.rules, i) end
end

-- A deep copy, for the editor: changes land only on Save.
function Store.Copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = Store.Copy(v) end
    return out
end

function Store:Replace(rule)
    local _, i = self:Find(rule.id)
    if i then
        self.sv.rules[i] = rule
    else
        self.sv.rules[#self.sv.rules + 1] = rule
        if rule.id >= self.sv.nextID then self.sv.nextID = rule.id + 1 end
    end
end

-- One character's records (cooldowns, lockouts, rest, mail).
function Store:Char(key)
    local chars = self.sv.chars
    local rec = chars[key]
    if type(rec) ~= "table" then
        rec = {}
        chars[key] = rec
    end
    return rec
end

function Store:Chars()
    return self.sv.chars
end

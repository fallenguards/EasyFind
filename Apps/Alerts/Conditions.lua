local _, AL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and AL.Triggers) then return end

-- The "only if" checks a rule may add; each can be turned around ("is not").
local C = {}
AL.Conditions = C
local KINDS = {}
C.KINDS = KINDS
C.ORDER = {}

local L = ns.L
local slower, sfind, smatch, sformat = string.lower, string.find, string.match, string.format
local tonumber, ipairs, date = tonumber, ipairs, date

local function Add(kind, def)
    def.kind = kind
    KINDS[kind] = def
    C.ORDER[#C.ORDER + 1] = kind
end

local INSTANCES = {
    { value = "none", label = L["ALERTS_INST_NONE"] },
    { value = "party", label = _G["DUNGEONS"] or L["ALERTS_INST_PARTY"] },
    { value = "raid", label = _G["RAIDS"] or L["ALERTS_INST_RAID"] },
    { value = "pvp", label = _G["BATTLEGROUNDS"] or L["ALERTS_INST_PVP"] },
}

local GROUPS = {
    { value = "solo", label = _G["SOLO"] or L["ALERTS_GROUP_SOLO"] },
    { value = "party", label = _G["PARTY"] or L["ALERTS_GROUP_PARTY"] },
    { value = "raid", label = _G["RAID"] or L["ALERTS_GROUP_RAID"] },
}

Add("combat", {
    label = L["ALERTS_COND_COMBAT"],
    Test = function() return (InCombatLockdown() or UnitAffectingCombat("player")) and true or false end,
    Text = function() return L["ALERTS_COND_COMBAT"] end,
})

Add("instance", {
    label = L["ALERTS_COND_INSTANCE"],
    field = { type = "choice", options = INSTANCES, default = "party" },
    Test = function(cond)
        local inside, kind = IsInInstance()
        if not inside then kind = "none" end
        if kind == "arena" then kind = "pvp" end
        return kind == cond.value
    end,
    Text = function(cond)
        for _, o in ipairs(INSTANCES) do
            if o.value == cond.value then return sformat(L["ALERTS_COND_IN_FMT"], o.label) end
        end
        return L["ALERTS_COND_INSTANCE"]
    end,
})

Add("zone", {
    label = L["ALERTS_COND_ZONE"],
    field = { type = "text", hint = L["ALERTS_HINT_ZONE"] },
    Test = function(cond)
        local want = slower(cond.value or "")
        if want == "" then return true end
        local zone, sub = slower(GetRealZoneText() or ""), slower(GetSubZoneText() or "")
        return sfind(zone, want, 1, true) ~= nil or sfind(sub, want, 1, true) ~= nil
    end,
    Text = function(cond) return sformat(L["ALERTS_COND_IN_FMT"], cond.value or "") end,
})

Add("resting", {
    label = L["ALERTS_COND_RESTING"],
    Test = function() return IsResting() and true or false end,
    Text = function() return L["ALERTS_COND_RESTING"] end,
})

Add("group", {
    label = L["ALERTS_COND_GROUP"],
    field = { type = "choice", options = GROUPS, default = "party" },
    Test = function(cond)
        local now = IsInRaid() and "raid" or (IsInGroup() and "party" or "solo")
        return now == cond.value
    end,
    Text = function(cond)
        for _, o in ipairs(GROUPS) do
            if o.value == cond.value then return o.label end
        end
        return L["ALERTS_COND_GROUP"]
    end,
})

Add("character", {
    label = L["ALERTS_COND_CHARACTER"],
    field = { type = "character" },
    Test = function(cond) return cond.value == ns.CurrentCharacterKey() end,
    Text = function(cond) return AL.Triggers.CharName(cond.value) end,
})

Add("class", {
    label = L["ALERTS_COND_CLASS"],
    field = { type = "class" },
    Test = function(cond)
        local _, file = UnitClass("player")
        return file == cond.value
    end,
    Text = function(cond)
        local names = LOCALIZED_CLASS_NAMES_MALE
        return names and names[cond.value] or cond.value or ""
    end,
})

local function Clock(text)
    local h, m = smatch(text or "", "^(%d%d?):(%d%d)$")
    h, m = tonumber(h), tonumber(m)
    if not (h and m) or h > 23 or m > 59 then return nil end
    return h * 60 + m
end
C.ParseClock = Clock

-- From one time of day to another, crossing midnight when the end is
-- earlier than the start.
Add("hours", {
    label = L["ALERTS_COND_HOURS"],
    field = { type = "text", hint = L["ALERTS_HINT_HOURS"] },
    Test = function(cond, now)
        local a, b = smatch(cond.value or "", "^%s*(%d%d?:%d%d)%s*%-%s*(%d%d?:%d%d)%s*$")
        a, b = Clock(a), Clock(b)
        if not (a and b) then return true end
        local t = date("*t", now)
        local m = t.hour * 60 + t.min
        if a <= b then return m >= a and m < b end
        return m >= a or m < b
    end,
    Text = function(cond) return cond.value or "" end,
})

-- Every condition holds (each turned around when `neg`).
function C.Pass(conds, now)
    for _, cond in ipairs(conds) do
        local def = KINDS[cond.kind]
        if def then
            local ok = def.Test(cond, now)
            if cond.neg then ok = not ok end
            if not ok then return false end
        end
    end
    return true
end

function C.Fresh(kind)
    local def = KINDS[kind]
    local cond = { kind = kind }
    if def and def.field then
        if def.field.type == "character" then
            cond.value = ns.CurrentCharacterKey()
        elseif def.field.type == "class" then
            local _, file = UnitClass("player")
            cond.value = file
        else
            cond.value = def.field.default
        end
    end
    return cond
end

function C.Text(cond)
    local def = KINDS[cond.kind]
    local text = def and def.Text(cond) or cond.kind
    return cond.neg and sformat(L["ALERTS_COND_NOT_FMT"], text) or text
end

-- Events after which a condition may have changed.
C.EVENTS = { "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED",
    "GROUP_ROSTER_UPDATE", "PLAYER_UPDATE_RESTING", "PLAYER_ENTERING_WORLD" }

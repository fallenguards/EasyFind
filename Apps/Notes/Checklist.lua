local _, notesNS = ...
local ns = EasyFind and EasyFind._ns
if not (ns and notesNS.Context) then return end

-- Checklist notes: lines ticked by hand, or linked to something the game
-- answers (an item count, a quest, a reputation, gold, a level, a skill, a
-- lockout, a cooldown). A list is account wide or kept per character, and
-- may clear its hand ticks on a schedule.
local CK = {}
notesNS.Checklist = CK

local L = ns.L
local sformat, slower, sfind, smatch, mfloor, mmax = string.format, string.lower, string.find, string.match, math.floor, math.max
local ipairs, pairs, type, tonumber, tostring, time, date = ipairs, pairs, type, tonumber, tostring, time, date

local function Plain(v)
    return v ~= nil and not (issecretvalue and issecretvalue(v))
end

local function CharName(key)
    return smatch(key or "", "^([^%-]+)") or key or "?"
end
CK.CharName = CharName

-- Lists

function CK.Init(note)
    note.kind = "checklist"
    note.list = note.list or {}
    local list = note.list
    list.scope = list.scope or "account"
    list.reset = list.reset or { every = "never" }
    list.lines = list.lines or {}
    list.ticks = list.ticks or {}
    list.seen = list.seen or {}
    list.resetAt = list.resetAt or {}
    list.nextLine = list.nextLine or 1
    return list
end

function CK.Is(note)
    return note and note.kind == "checklist" and type(note.list) == "table"
end

-- Whose hand ticks a list keeps: "account" or a character key.
local function Holder(list, charKey)
    return list.scope == "character" and charKey or "account"
end

-- A line after line afterID, or last.
function CK.InsertLine(note, line, afterID)
    local list = CK.Init(note)
    line.id = list.nextLine
    list.nextLine = list.nextLine + 1
    local at = #list.lines + 1
    for i, l in ipairs(list.lines) do
        if l.id == afterID then at = i + 1 break end
    end
    table.insert(list.lines, at, line)
    CK.SyncBody(note)
    return line
end

function CK.AddLine(note, line)
    return CK.InsertLine(note, line, nil)
end

function CK.RemoveLine(note, id)
    local list = note.list
    for i, line in ipairs(list.lines) do
        if line.id == id then
            table.remove(list.lines, i)
            break
        end
    end
    for _, ticks in pairs(list.ticks) do ticks[id] = nil end
    for _, seen in pairs(list.seen) do seen[id] = nil end
    CK.SyncBody(note)
end

function CK.MoveLine(note, id, delta)
    local lines = note.list.lines
    for i, line in ipairs(lines) do
        if line.id == id then
            local j = i + delta
            if j >= 1 and j <= #lines then lines[i], lines[j] = lines[j], lines[i] end
            return
        end
    end
end

function CK.Ticked(note, line, charKey)
    local ticks = note.list.ticks[Holder(note.list, charKey)]
    return ticks and ticks[line.id] == true
end

function CK.SetTicked(note, line, charKey, on)
    local list = note.list
    local key = Holder(list, charKey)
    list.ticks[key] = list.ticks[key] or {}
    list.ticks[key][line.id] = on or nil
    note.updated = time()
end

-- Game links: each answers done, a progress text and a detail line.

local function ItemName(id)
    return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("item:" .. id)
end

local function Span(sec)
    sec = mmax(0, mfloor(sec))
    if sec >= 3600 then return sformat("%dh %dm", mfloor(sec / 3600), mfloor(sec % 3600 / 60)) end
    return sformat("%dm", mmax(1, mfloor(sec / 60)))
end

local function Gold(copper)
    return sformat("%dg", mfloor((copper or 0) / 10000))
end

local LINKS = {}
CK.LINKS = LINKS

LINKS.item = {
    label = L["CHECK_LINK_ITEM"],
    Name = function(line) return ItemName(line.item) end,
    State = function(line, ctx)
        local get = C_Item and C_Item.GetItemCount
        if not get then return false, "" end
        local bags = get(line.item) or 0
        local bank = mmax(0, (get(line.item, true) or bags) - bags)
        local total = bags + bank
        local parts = {}
        if bags > 0 then parts[#parts + 1] = sformat(L["CHECK_BAGS_FMT"], bags) end
        if bank > 0 then parts[#parts + 1] = sformat(L["CHECK_BANK_FMT"], bank) end
        if ctx.account and ns.StoredItemCounts then
            for charKey, c in pairs(ns.StoredItemCounts(line.item) or {}) do
                if charKey ~= ctx.char then
                    local n = (c.bags or 0) + (c.bank or 0)
                    if n > 0 then
                        total = total + n
                        parts[#parts + 1] = sformat("%s %d", CharName(charKey), n)
                    end
                end
            end
        end
        local target = line.target or 1
        return total >= target, sformat("%d/%d", total, target), table.concat(parts, ", "), total, target
    end,
}

LINKS.quest = {
    label = L["CHECK_LINK_QUEST"],
    Name = function(line)
        local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(line.quest)
        return title or line.text or ("quest:" .. line.quest)
    end,
    State = function(line)
        local QL = C_QuestLog
        if not QL then return false, "" end
        if QL.IsQuestFlaggedCompleted and QL.IsQuestFlaggedCompleted(line.quest) then
            return true, L["CHECK_DONE"]
        end
        if QL.GetLogIndexForQuestID and QL.GetLogIndexForQuestID(line.quest) then
            local have, need = 0, 0
            for _, o in ipairs(QL.GetQuestObjectives and QL.GetQuestObjectives(line.quest) or {}) do
                if Plain(o.numFulfilled) and Plain(o.numRequired) then
                    have, need = have + o.numFulfilled, need + o.numRequired
                end
            end
            if need > 0 then return false, sformat("%d/%d", have, need), L["CHECK_IN_LOG"] end
            return false, L["CHECK_IN_LOG"]
        end
        return false, L["CHECK_NOT_STARTED"]
    end,
}

local function Standing(factionID)
    local R = C_Reputation
    if R and R.GetFactionDataByID then
        local data = R.GetFactionDataByID(factionID)
        return data and data.name, data and data.reaction
    end
    if GetFactionInfoByID then
        local name, _, standing = GetFactionInfoByID(factionID)
        return name, standing
    end
end

local function StandingLabel(n)
    return _G["FACTION_STANDING_LABEL" .. tostring(n)] or tostring(n)
end
CK.StandingLabel = StandingLabel

LINKS.rep = {
    label = L["CHECK_LINK_REP"],
    Name = function(line) return (Standing(line.faction)) or line.text or ("faction:" .. line.faction) end,
    State = function(line)
        local _, now = Standing(line.faction)
        if not Plain(now) then return false, "" end
        local want = line.standing or 8
        return now >= want, sformat("%s/%s", StandingLabel(now), StandingLabel(want))
    end,
}

LINKS.gold = {
    label = L["CHECK_LINK_GOLD"],
    Name = function(line) return line.text or L["CHECK_LINK_GOLD"] end,
    State = function(line, ctx)
        local have = GetMoney and GetMoney() or 0
        if ctx.account then
            local ledger = type(EasyFindDB) == "table" and type(EasyFindDB.charGold) == "table" and EasyFindDB.charGold
            for charKey, copper in pairs(ledger or {}) do
                if charKey ~= ctx.char and type(copper) == "number" then have = have + copper end
            end
        end
        local want = line.target or 0
        return have >= want, sformat("%s/%s", Gold(have), Gold(want)), nil, have, want
    end,
}

LINKS.level = {
    label = L["CHECK_LINK_LEVEL"],
    Name = function(line) return line.text or sformat(L["CHECK_LEVEL_FMT"], line.target or 0) end,
    State = function(line)
        local have, want = UnitLevel("player") or 0, line.target or 0
        return have >= want, sformat("%d/%d", have, want)
    end,
}

-- A profession by name: its skill against the target.
local function SkillLevel(name)
    if not (GetProfessions and GetProfessionInfo) then return nil end
    local want = slower(name or "")
    for _, prof in ipairs({ GetProfessions() }) do
        if prof then
            local pname, _, level = GetProfessionInfo(prof)
            if pname and slower(pname) == want then return level end
        end
    end
end

LINKS.skill = {
    label = L["CHECK_LINK_SKILL"],
    Name = function(line) return line.skill or "?" end,
    State = function(line)
        local have = SkillLevel(line.skill)
        if not have then return false, L["CHECK_NOT_LEARNED"] end
        local want = line.target or 1
        return have >= want, sformat("%d/%d", have, want)
    end,
}

LINKS.lockout = {
    label = L["CHECK_LINK_LOCKOUT"],
    Name = function(line) return line.instance or "?" end,
    State = function(line)
        if not (GetNumSavedInstances and GetSavedInstanceInfo) then return false, "" end
        local want = slower(line.instance or "")
        for i = 1, GetNumSavedInstances() do
            local name, _, reset, _, locked, _, _, _, _, diff, numBosses, killed = GetSavedInstanceInfo(i)
            if Plain(name) and locked and reset and reset > 0 and sfind(slower(name), want, 1, true) then
                local cleared = Plain(killed) and Plain(numBosses) and numBosses > 0 and killed >= numBosses
                return cleared, sformat("%d/%d", killed or 0, numBosses or 0), diff
            end
        end
        return false, L["CHECK_NOT_SAVED"]
    end,
}

-- A cooldown in use reads as done: "Mooncloth made today".
LINKS.cooldown = {
    label = L["CHECK_LINK_COOLDOWN"],
    Name = function(line)
        if line.item then return ItemName(line.item) end
        return (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(line.spell)) or ("spell:" .. tostring(line.spell))
    end,
    State = function(line, ctx)
        local start, dur
        if line.item then
            local f = (C_Container and C_Container.GetItemCooldown) or (C_Item and C_Item.GetItemCooldown)
            if f then start, dur = f(line.item) end
        else
            local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(line.spell)
            if type(info) == "table" then start, dur = info.startTime, info.duration end
        end
        if not (Plain(start) and Plain(dur)) then return false, "" end
        if dur <= 1.5 then return false, L["CHECK_READY"] end
        local left = start + dur - ctx.gnow
        return true, sformat(L["CHECK_READY_IN_FMT"], Span(left))
    end,
}

CK.LINK_ORDER = { "item", "quest", "rep", "gold", "level", "skill", "lockout", "cooldown" }

local ctx = {}
local function Ctx(note)
    ctx.char = ns.CurrentCharacterKey()
    ctx.account = note.list.scope ~= "character"
    ctx.gnow = GetTime()
    return ctx
end

-- done, progress, detail for a line on this character; a linked line also
-- leaves what it read for the alts board.
function CK.LineState(note, line)
    local c = Ctx(note)
    local link = line.link and LINKS[line.link]
    if not link then
        return CK.Ticked(note, line, c.char), nil, nil
    end
    local done, progress, detail, have, need = link.State(line, c)
    local seen = note.list.seen
    seen[c.char] = seen[c.char] or {}
    seen[c.char][line.id] = { d = done and true or nil, p = progress, t = time() }
    return done, progress, detail, have, need
end

function CK.LineName(line)
    if line.text and line.text ~= "" then return line.text end
    if line.item and not line.link then return ItemName(line.item) end
    local link = line.link and LINKS[line.link]
    return link and link.Name(line) or ""
end

-- How many lines are done on this character.
function CK.Progress(note)
    local done, total = 0, #note.list.lines
    for _, line in ipairs(note.list.lines) do
        if CK.LineState(note, line) then done = done + 1 end
    end
    return done, total
end

-- The alts board: what each character last had for each line.
function CK.Board(note)
    local list = note.list
    local chars = {}
    for charKey in pairs(list.seen) do chars[charKey] = true end
    for charKey in pairs(list.ticks) do
        if charKey ~= "account" then chars[charKey] = true end
    end
    chars[ns.CurrentCharacterKey()] = true
    local out = {}
    for charKey in pairs(chars) do out[#out + 1] = charKey end
    table.sort(out)
    return out
end

function CK.BoardCell(note, line, charKey)
    if line.link then
        local s = note.list.seen[charKey]
        s = s and s[line.id]
        if not s then return nil end
        return s.d == true, s.p
    end
    local ticks = note.list.ticks[charKey]
    return ticks and ticks[line.id] == true or false, nil
end

-- Resets: the last moment the list's schedule passed, or nil for never.

local WEEKDAY = { [1] = 3, [2] = 5, [3] = 4, [4] = 5, [5] = 5 }

-- The game's daily reset that last went by (a moment in time).
local function LastDaily(now)
    local left = GetQuestResetTime and GetQuestResetTime()
    if not (Plain(left) and left and left > 0) then return nil end
    return now + left - 86400
end

-- The region's weekly reset: the last daily reset on its weekday (UTC).
local function LastWeekly(now)
    local daily = LastDaily(now)
    if not daily then return nil end
    local want = WEEKDAY[GetCurrentRegion and GetCurrentRegion() or 1] or 3
    for back = 0, 6 do
        local t = daily - back * 86400
        if date("!*t", t).wday == want then return t end
    end
end

-- Chosen weekdays (1 Sunday ... 7 Saturday) at a local time of day.
local function LastChosen(now, reset)
    local hour, min = reset.hour or 0, reset.min or 0
    local days = reset.days or {}
    for back = 0, 7 do
        local t = date("*t", now - back * 86400)
        t.hour, t.min, t.sec = hour, min, 0
        local at = time(t)
        if days[t.wday] and at <= now then return at end
    end
end

function CK.LastReset(reset, now)
    local every = reset and reset.every
    if every == "daily" then return LastDaily(now) end
    if every == "weekly" then return LastWeekly(now) end
    if every == "days" then return LastChosen(now, reset) end
    return nil
end

-- Clears hand ticks a schedule has passed since they were last cleared.
function CK.ApplyReset(note, now)
    local list = note.list
    local last = CK.LastReset(list.reset, now)
    if not last then return false end
    local cleared = false
    for holder, ticks in pairs(list.ticks) do
        local was = list.resetAt[holder] or 0
        if was < last then
            if next(ticks) then cleared = true end
            list.ticks[holder] = {}
            list.resetAt[holder] = now
        end
    end
    return cleared
end

-- The note body mirrors the line names, so search and titles see them.
function CK.SyncBody(note)
    local parts = {}
    for _, line in ipairs(note.list.lines) do parts[#parts + 1] = CK.LineName(line) end
    note.body = table.concat(parts, "\n")
    note.updated = time()
end

function CK.Preview(note)
    local done, total = CK.Progress(note)
    return sformat(L["CHECK_PREVIEW_FMT"], done, total)
end

-- A line from a pasted or shift-clicked link: item, quest or spell. An
-- item is one to tick by hand (it came from the bags it would count);
-- Track counts one.
function CK.LineFromLink(link)
    local item = tonumber(smatch(link or "", "|Hitem:(%d+)"))
    if item then return { item = item } end
    local quest = tonumber(smatch(link or "", "|Hquest:(%d+)"))
    if quest then return { link = "quest", quest = quest } end
    local spell = tonumber(smatch(link or "", "|Hspell:(%d+)"))
    if spell then return { link = "cooldown", spell = spell } end
end

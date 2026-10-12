local _, AL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and AL.Store) then return end

-- What each kind of alert watches and what it says. A kind is one of:
--   state: State(rule, ctx) -> active, text, recheckIn; rings as it turns on
--   event: Event(rule, ctx, event, ...) -> text; rings every time
--   timed: Read(rule, ctx) records per character; Due(rule, ctx) -> list
--          of { at, key, text }, each rung once
-- fields describe the editor: spell, item, aura, number, text, choice,
-- multi, bool.
local T = {}
AL.Triggers = T
local KINDS = {}
T.KINDS = KINDS
T.ORDER = {}

local L = ns.L
local sformat, slower, sfind, sgsub, smatch = string.format, string.lower, string.find, string.gsub, string.match
local mmax, mfloor, mmin = math.max, math.floor, math.min
local ipairs, pairs, tostring, type, select = ipairs, pairs, tostring, type, select

local function Plain(v)
    return v ~= nil and not (issecretvalue and issecretvalue(v))
end
T.Plain = Plain

local function Add(kind, def)
    def.kind = kind
    KINDS[kind] = def
    T.ORDER[#T.ORDER + 1] = kind
end

local function Minutes(sec)
    return mmax(1, mfloor(sec / 60 + 0.5))
end

local function Short(text, n)
    if #text <= n then return text end
    return text:sub(1, n - 3) .. "..."
end

local function CharName(key)
    return smatch(key or "", "^([^%-]+)") or key or "?"
end
T.CharName = CharName

-- Lowercased words from a comma or space separated list.
local function Words(text)
    local out = {}
    for w in (slower(text or "")):gmatch("[^,%s]+") do out[#out + 1] = w end
    return out
end
T.Words = Words

local function NameListed(list, name)
    if #list == 0 then return true end
    if not Plain(name) then return false end
    local n = slower(CharName(name))
    for i = 1, #list do
        if list[i] == n then return true end
    end
    return false
end

-- Every space separated term must appear; "a/b" means either.
local function WordsMatch(terms, text)
    if not Plain(text) then return false end
    local t = slower(text)
    for i = 1, #terms do
        local hit = false
        for alt in terms[i]:gmatch("[^/]+") do
            if sfind(t, alt, 1, true) then hit = true break end
        end
        if not hit then return false end
    end
    return true
end
T.WordsMatch = WordsMatch

-- Reads

local function SpellLeft(spellID, gnow)
    local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(spellID)
    if type(info) ~= "table" then return nil end
    local start, dur = info.startTime, info.duration
    if not (Plain(start) and Plain(dur)) then return nil end
    -- Off cooldown, or only the global cooldown.
    if dur <= 1.5 then return 0 end
    return mmax(0, start + dur - gnow)
end

local ItemCooldown = (C_Container and C_Container.GetItemCooldown) or (C_Item and C_Item.GetItemCooldown)
local function ItemLeft(itemID, gnow)
    if not ItemCooldown then return nil end
    local start, dur = ItemCooldown(itemID)
    if not (Plain(start) and Plain(dur)) then return nil end
    if dur <= 1.5 then return 0 end
    return mmax(0, start + dur - gnow)
end

local function Knows(trigger)
    if trigger.item then
        return C_Item and C_Item.GetItemCount and (C_Item.GetItemCount(trigger.item) or 0) > 0
    end
    if IsPlayerSpell then return IsPlayerSpell(trigger.spell) end
    return true
end

-- The player's buff whose name or spell id the rule names; nil and true
-- when it is not found but some buff could not be read.
local function FindAura(trigger)
    local get = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not get then return nil, true end
    local want = trigger.aura and slower(trigger.aura)
    local unknown = false
    for i = 1, 255 do
        local aura = get("player", i, "HELPFUL")
        if not aura then return nil, unknown end
        local name, id = aura.name, aura.spellId
        if not (Plain(name) and Plain(id)) then unknown = true end
        if Plain(name) and want and slower(name) == want then return aura end
        if Plain(id) and trigger.spell and id == trigger.spell then return aura end
    end
    return nil, unknown
end

-- Seconds left on a found buff; math.huge for one that never ends.
local function AuraLeft(aura, gnow)
    local exp = aura.expirationTime
    if not Plain(exp) then return nil end
    if exp == 0 then return math.huge end
    return mmax(0, exp - gnow)
end

local function Label(trigger)
    return trigger.label or (trigger.aura) or tostring(trigger.spell or trigger.item or "?")
end
T.Label = Label

-- Ready

Add("cooldown", {
    group = "ready", timed = true,
    label = L["ALERTS_KIND_COOLDOWN"],
    fields = { { key = "what", type = "spellOrItem" }, { key = "alts", type = "bool", label = L["ALERTS_FIELD_ALTS"] } },
    events = { "SPELL_UPDATE_COOLDOWN", "BAG_UPDATE_COOLDOWN", "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED" },
    Read = function(rule, ctx)
        local tr = rule.trigger
        if not (tr.spell or tr.item) then return end
        local rec = ctx.store:Char(ctx.char)
        rec.cd = rec.cd or {}
        local key = (tr.item and "i" or "s") .. (tr.item or tr.spell)
        if not Knows(tr) then
            rec.cd[key] = nil
            return
        end
        local left
        if tr.item then left = ItemLeft(tr.item, ctx.gnow) else left = SpellLeft(tr.spell, ctx.gnow) end
        if left == nil then return end
        local prev = rec.cd[key]
        if left > 0 then
            rec.cd[key] = ctx.now + mfloor(left + 0.5)
        elseif type(prev) ~= "number" or prev > ctx.now then
            -- Never seen on cooldown, or ready earlier than the record said.
            rec.cd[key] = prev and mmin(prev, ctx.now) or 0
        end
    end,
    Due = function(rule, ctx, out)
        local tr = rule.trigger
        if not (tr.spell or tr.item) then return end
        local key = (tr.item and "i" or "s") .. (tr.item or tr.spell)
        for charKey, rec in pairs(ctx.store:Chars()) do
            local at = rec.cd and rec.cd[key]
            if type(at) == "number" and at > 0 and (tr.alts or charKey == ctx.char) then
                local text = charKey == ctx.char and sformat(L["ALERTS_READY_FMT"], Label(tr))
                    or sformat(L["ALERTS_READY_ON_FMT"], Label(tr), CharName(charKey))
                out[#out + 1] = { at = at, key = charKey .. ":" .. at, text = text }
            end
        end
    end,
    Summary = function(rule)
        local tr = rule.trigger
        return sformat(tr.alts and L["ALERTS_SUM_COOLDOWN_ALTS"] or L["ALERTS_SUM_COOLDOWN"], Label(tr))
    end,
})

-- Running out

Add("buffEnding", {
    group = "running", state = true, primeFires = true,
    label = L["ALERTS_KIND_BUFF_ENDING"],
    fields = { { key = "aura", type = "aura" }, { key = "minutes", type = "number", default = 5, min = 1, max = 600, unit = L["ALERTS_UNIT_MIN"] } },
    events = { "UNIT_AURA", "PLAYER_ENTERING_WORLD" },
    unit = "player",
    State = function(rule, ctx)
        local aura, unknown = FindAura(rule.trigger)
        if not aura then
            if unknown then return nil end
            return false
        end
        local left = AuraLeft(aura, ctx.gnow)
        if left == nil then return nil end
        if left == math.huge then return false end
        local warn = (rule.trigger.minutes or 5) * 60
        if left <= warn then
            return true, sformat(L["ALERTS_ENDS_IN_FMT"], Label(rule.trigger), Minutes(left))
        end
        return false, nil, left - warn
    end,
    Summary = function(rule)
        return sformat(L["ALERTS_SUM_BUFF_ENDING"], Label(rule.trigger), rule.trigger.minutes or 5)
    end,
})

Add("buffMissing", {
    group = "running", state = true,
    label = L["ALERTS_KIND_BUFF_MISSING"],
    fields = { { key = "aura", type = "aura" } },
    events = { "UNIT_AURA", "PLAYER_ENTERING_WORLD" },
    unit = "player",
    State = function(rule)
        local aura, unknown = FindAura(rule.trigger)
        if aura then return false end
        if unknown then return nil end
        return true, sformat(L["ALERTS_MISSING_FMT"], Label(rule.trigger))
    end,
    Summary = function(rule)
        return sformat(L["ALERTS_SUM_BUFF_MISSING"], Label(rule.trigger))
    end,
})

local HANDS = {
    { value = "main", label = _G["INVTYPE_WEAPONMAINHAND"] or L["ALERTS_HAND_MAIN"] },
    { value = "off", label = _G["INVTYPE_WEAPONOFFHAND"] or L["ALERTS_HAND_OFF"] },
}

Add("weaponEnchant", {
    group = "running", state = true, primeFires = true,
    label = L["ALERTS_KIND_WEAPON"],
    fields = { { key = "hand", type = "choice", options = HANDS, default = "main" },
               { key = "minutes", type = "number", default = 5, min = 0, max = 120, unit = L["ALERTS_UNIT_MIN"] } },
    events = { "UNIT_INVENTORY_CHANGED", "PLAYER_ENTERING_WORLD" },
    unit = "player",
    State = function(rule)
        if not GetWeaponEnchantInfo then return false end
        local off = rule.trigger.hand == "off"
        if not GetInventoryItemID("player", off and 17 or 16) then return false end
        local hasMain, mainLeft, _, _, hasOff, offLeft = GetWeaponEnchantInfo()
        local has, leftMs = hasMain, mainLeft
        if off then has, leftMs = hasOff, offLeft end
        if not (Plain(has) and (not has or Plain(leftMs))) then return nil end
        local hand = off and HANDS[2].label or HANDS[1].label
        if not has then return true, sformat(L["ALERTS_NO_ENCHANT_FMT"], hand) end
        local left, warn = leftMs / 1000, (rule.trigger.minutes or 5) * 60
        if left <= warn then return true, sformat(L["ALERTS_ENCHANT_ENDS_FMT"], hand, Minutes(left)) end
        return false, nil, left - warn
    end,
    Summary = function(rule)
        return sformat(L["ALERTS_SUM_WEAPON"], rule.trigger.hand == "off" and HANDS[2].label or HANDS[1].label)
    end,
})

Add("itemLow", {
    group = "running", state = true, primeFires = true,
    label = L["ALERTS_KIND_ITEM_LOW"],
    fields = { { key = "what", type = "item" }, { key = "count", type = "number", default = 5, min = 0, max = 10000 } },
    events = { "BAG_UPDATE_DELAYED", "PLAYER_ENTERING_WORLD" },
    State = function(rule)
        local tr = rule.trigger
        if not (tr.item and C_Item and C_Item.GetItemCount) then return false end
        local n = C_Item.GetItemCount(tr.item) or 0
        if n <= (tr.count or 5) then return true, sformat(L["ALERTS_ITEM_LEFT_FMT"], Label(tr), n) end
        return false
    end,
    Summary = function(rule)
        return sformat(L["ALERTS_SUM_ITEM_LOW"], Label(rule.trigger), rule.trigger.count or 5)
    end,
})

Add("durability", {
    group = "running", state = true, primeFires = true,
    label = L["ALERTS_KIND_DURABILITY"],
    fields = { { key = "percent", type = "number", default = 20, min = 1, max = 99, unit = "%" } },
    events = { "UPDATE_INVENTORY_DURABILITY", "PLAYER_ENTERING_WORLD" },
    State = function(rule)
        local low
        for slot = 1, 19 do
            local cur, max = GetInventoryItemDurability(slot)
            if Plain(cur) and Plain(max) and max > 0 then
                local pct = cur / max * 100
                if not low or pct < low then low = pct end
            end
        end
        if low and low <= (rule.trigger.percent or 20) then
            return true, sformat(L["ALERTS_DURABILITY_FMT"], mfloor(low))
        end
        return false
    end,
    Summary = function(rule)
        return sformat(L["ALERTS_SUM_DURABILITY"], rule.trigger.percent or 20)
    end,
})

Add("bagsFull", {
    group = "running", state = true, primeFires = true,
    label = L["ALERTS_KIND_BAGS"],
    fields = { { key = "slots", type = "number", default = 2, min = 0, max = 100 } },
    events = { "BAG_UPDATE_DELAYED", "PLAYER_ENTERING_WORLD" },
    State = function(rule)
        local free = C_Container and C_Container.GetContainerNumFreeSlots
        if not free then return false end
        local n = 0
        for bag = 0, NUM_BAG_SLOTS or 4 do
            local f = free(bag)
            if Plain(f) then n = n + f end
        end
        if n <= (rule.trigger.slots or 2) then return true, sformat(L["ALERTS_BAGS_FMT"], n) end
        return false
    end,
    Summary = function(rule)
        return sformat(L["ALERTS_SUM_BAGS"], rule.trigger.slots or 2)
    end,
})

-- Resets

Add("lockout", {
    group = "resets", timed = true,
    label = L["ALERTS_KIND_LOCKOUT"],
    fields = {},
    events = { "UPDATE_INSTANCE_INFO", "PLAYER_ENTERING_WORLD" },
    Read = function(_, ctx, event)
        if event == "PLAYER_ENTERING_WORLD" then
            if RequestRaidInfo then RequestRaidInfo() end
            return
        end
        if not (GetNumSavedInstances and GetSavedInstanceInfo) then return end
        local rec = ctx.store:Char(ctx.char)
        local out = {}
        for i = 1, GetNumSavedInstances() do
            local name, _, reset, _, locked, _, _, _, _, diffName = GetSavedInstanceInfo(i)
            if Plain(name) and Plain(reset) and locked and reset > 0 then
                out[name .. (diffName and diffName ~= "" and (" (" .. diffName .. ")") or "")] = ctx.now + reset
            end
        end
        rec.lockouts = out
    end,
    Due = function(_, ctx, out)
        -- One line per reset moment: every instance and character on it.
        local byAt = {}
        for charKey, rec in pairs(ctx.store:Chars()) do
            for name, at in pairs(rec.lockouts or {}) do
                local minute = mfloor(at / 60) * 60
                local slot = byAt[minute]
                if not slot then
                    slot = { names = {}, seen = {} }
                    byAt[minute] = slot
                end
                if not slot.seen[name] then
                    slot.seen[name] = true
                    slot.names[#slot.names + 1] = name
                end
                slot.chars = (slot.chars or 0) + 1
            end
        end
        for at, slot in pairs(byAt) do
            table.sort(slot.names)
            out[#out + 1] = { at = at, key = "reset:" .. at,
                text = sformat(L["ALERTS_LOCKOUT_FMT"], Short(table.concat(slot.names, ", "), 120)) }
        end
    end,
    Summary = function() return L["ALERTS_SUM_LOCKOUT"] end,
})

-- Rest builds 5% of a level per 8 hours in an inn or a city, a quarter
-- of that elsewhere, up to a level and a half.
local REST_SPAN, REST_RATE, REST_WILD, REST_CAP = 8 * 3600, 0.05, 0.25, 1.5

function T.RecordRest(store, char, now)
    if not (GetXPExhaustion and UnitXPMax and UnitLevel) then return end
    local maxLevel = GetMaxPlayerLevel and GetMaxPlayerLevel()
    local rec = store:Char(char)
    if maxLevel and UnitLevel("player") >= maxLevel then
        rec.rest = nil
        return
    end
    rec.rest = { xp = GetXPExhaustion() or 0, max = UnitXPMax("player"), resting = IsResting() and true or false, at = now }
end

function T.RestFullAt(rest)
    local full = rest.max * REST_CAP
    if rest.xp >= full then return rest.at end
    local perSec = rest.max * REST_RATE / REST_SPAN * (rest.resting and 1 or REST_WILD)
    return rest.at + mfloor((full - rest.xp) / perSec)
end

Add("rested", {
    group = "resets", timed = true,
    label = L["ALERTS_KIND_RESTED"],
    fields = {},
    events = { "UPDATE_EXHAUSTION", "PLAYER_UPDATE_RESTING", "PLAYER_ENTERING_WORLD" },
    Read = function(_, ctx) T.RecordRest(ctx.store, ctx.char, ctx.now) end,
    Due = function(_, ctx, out)
        for charKey, rec in pairs(ctx.store:Chars()) do
            local rest = rec.rest
            if type(rest) == "table" and type(rest.max) == "number" and rest.max > 0 and charKey ~= ctx.char then
                local at = T.RestFullAt(rest)
                out[#out + 1] = { at = at, key = charKey .. ":rest:" .. rest.at,
                    text = sformat(L["ALERTS_RESTED_FMT"], CharName(charKey)) }
            end
        end
    end,
    Summary = function() return L["ALERTS_SUM_RESTED"] end,
})

Add("mail", {
    group = "resets", timed = true,
    label = L["ALERTS_KIND_MAIL"],
    fields = { { key = "days", type = "number", default = 3, min = 1, max = 29, unit = L["ALERTS_UNIT_DAYS"] } },
    events = { "MAIL_INBOX_UPDATE" },
    Read = function(_, ctx)
        if not (GetInboxNumItems and GetInboxHeaderInfo) then return end
        local soonest
        for i = 1, GetInboxNumItems() do
            local daysLeft = select(7, GetInboxHeaderInfo(i))
            if Plain(daysLeft) and (not soonest or daysLeft < soonest) then soonest = daysLeft end
        end
        local rec = ctx.store:Char(ctx.char)
        rec.mail = soonest and (ctx.now + mfloor(soonest * 86400)) or nil
    end,
    Due = function(rule, ctx, out)
        local lead = (rule.trigger.days or 3) * 86400
        for charKey, rec in pairs(ctx.store:Chars()) do
            if type(rec.mail) == "number" then
                out[#out + 1] = { at = rec.mail - lead, key = charKey .. ":mail:" .. rec.mail,
                    text = sformat(L["ALERTS_MAIL_FMT"], CharName(charKey)) }
            end
        end
    end,
    Summary = function(rule) return sformat(L["ALERTS_SUM_MAIL"], rule.trigger.days or 3) end,
})

-- People

local FRIEND_PATTERN
local function FriendOnlineName(msg)
    if not FRIEND_PATTERN then
        local fmt = _G["ERR_FRIEND_ONLINE_SS"] or "|Hplayer:%s|h[%s]|h has come online."
        FRIEND_PATTERN = "^" .. sgsub(sgsub(fmt, "([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"), "%%s", "(.-)") .. "$"
    end
    local _, name = smatch(msg, FRIEND_PATTERN)
    return name
end
T.FriendOnlineName = FriendOnlineName

Add("online", {
    group = "people", event = true,
    label = L["ALERTS_KIND_ONLINE"],
    fields = { { key = "names", type = "text", hint = L["ALERTS_HINT_NAMES"] } },
    events = { "CHAT_MSG_SYSTEM" },
    Event = function(rule, _, _, msg)
        if not Plain(msg) then return nil end
        local name = FriendOnlineName(msg)
        if name and NameListed(Words(rule.trigger.names), name) then
            return sformat(L["ALERTS_ONLINE_FMT"], name)
        end
    end,
    Summary = function(rule)
        local names = rule.trigger.names
        return (names and names ~= "") and sformat(L["ALERTS_SUM_ONLINE_NAMES"], names) or L["ALERTS_SUM_ONLINE"]
    end,
})

Add("whisper", {
    group = "people", event = true,
    label = L["ALERTS_KIND_WHISPER"],
    fields = { { key = "names", type = "text", hint = L["ALERTS_HINT_NAMES"] },
               { key = "words", type = "text", hint = L["ALERTS_HINT_WORDS"] } },
    events = { "CHAT_MSG_WHISPER", "CHAT_MSG_BN_WHISPER" },
    Event = function(rule, _, event, msg, sender)
        local tr = rule.trigger
        local names = Words(tr.names)
        -- A Battle.net sender has no name to compare.
        if event == "CHAT_MSG_BN_WHISPER" then
            if #names > 0 then return nil end
            sender = _G["BATTLENET_FRIEND"] or "Battle.net"
        elseif not NameListed(names, sender) then
            return nil
        end
        local words = Words(tr.words)
        if #words > 0 and not WordsMatch(words, msg) then return nil end
        local from = Plain(sender) and CharName(sender) or "?"
        return sformat(L["ALERTS_WHISPER_FMT"], from, Plain(msg) and Short(msg, 70) or "")
    end,
    Summary = function(rule)
        local names = rule.trigger.names
        return (names and names ~= "") and sformat(L["ALERTS_SUM_WHISPER_NAMES"], names) or L["ALERTS_SUM_WHISPER"]
    end,
})

Add("chatWords", {
    group = "people", event = true,
    label = L["ALERTS_KIND_CHAT"],
    fields = { { key = "words", type = "text", hint = L["ALERTS_HINT_CHAT_WORDS"] },
               { key = "channel", type = "text", hint = L["ALERTS_HINT_CHANNEL"] },
               { key = "say", type = "bool", label = L["ALERTS_FIELD_SAY"] } },
    events = { "CHAT_MSG_CHANNEL", "CHAT_MSG_SAY", "CHAT_MSG_YELL" },
    Event = function(rule, ctx, event, msg, sender, _, _, _, _, _, _, channelName)
        local tr = rule.trigger
        local words = Words(tr.words)
        if #words == 0 then return nil end
        if event ~= "CHAT_MSG_CHANNEL" and not tr.say then return nil end
        if Plain(sender) and CharName(sender) == ctx.playerName then return nil end
        local where = event == "CHAT_MSG_CHANNEL" and channelName or (event == "CHAT_MSG_SAY" and (_G["SAY"] or "Say") or (_G["YELL"] or "Yell"))
        if event == "CHAT_MSG_CHANNEL" and tr.channel and tr.channel ~= "" then
            if not (Plain(where) and sfind(slower(where), slower(tr.channel), 1, true)) then return nil end
        end
        if not WordsMatch(words, msg) then return nil end
        return sformat(L["ALERTS_CHAT_FMT"], Plain(sender) and CharName(sender) or "?",
            Plain(where) and where or "", Short(msg, 70))
    end,
    Summary = function(rule)
        return sformat(L["ALERTS_SUM_CHAT"], rule.trigger.words or "")
    end,
})

local REQUESTS = {
    { value = "ready", label = _G["READY_CHECK"] or L["ALERTS_REQ_READY"] },
    { value = "summon", label = L["ALERTS_REQ_SUMMON"] },
    { value = "res", label = L["ALERTS_REQ_RES"] },
    { value = "invite", label = L["ALERTS_REQ_INVITE"] },
    { value = "duel", label = L["ALERTS_REQ_DUEL"] },
}
local REQUEST_EVENT = { READY_CHECK = "ready", CONFIRM_SUMMON = "summon", RESURRECT_REQUEST = "res",
    PARTY_INVITE_REQUEST = "invite", DUEL_REQUESTED = "duel" }

Add("request", {
    group = "people", event = true,
    label = L["ALERTS_KIND_REQUEST"],
    fields = { { key = "which", type = "multi", options = REQUESTS, default = { ready = true, summon = true, res = true, invite = true } } },
    events = { "READY_CHECK", "CONFIRM_SUMMON", "RESURRECT_REQUEST", "PARTY_INVITE_REQUEST", "DUEL_REQUESTED" },
    Event = function(rule, _, event, who)
        local which = REQUEST_EVENT[event]
        if not (which and rule.trigger.which and rule.trigger.which[which]) then return nil end
        local name = Plain(who) and CharName(who) or "?"
        if which == "ready" then return L["ALERTS_READY_CHECK"] end
        if which == "summon" then
            local area = C_SummonInfo and C_SummonInfo.GetSummonConfirmAreaName and C_SummonInfo.GetSummonConfirmAreaName()
            return sformat(L["ALERTS_SUMMON_FMT"], Plain(area) and area or "?")
        end
        if which == "res" then return sformat(L["ALERTS_RES_FMT"], name) end
        if which == "invite" then return sformat(L["ALERTS_INVITE_FMT"], name) end
        return sformat(L["ALERTS_DUEL_FMT"], name)
    end,
    Summary = function(rule)
        local parts = {}
        for _, opt in ipairs(REQUESTS) do
            if rule.trigger.which and rule.trigger.which[opt.value] then parts[#parts + 1] = opt.label end
        end
        return table.concat(parts, ", ")
    end,
})

-- Nearby

local RANKS = {
    { value = "rare", label = L["ALERTS_RANK_RARE"] },
    { value = "rareelite", label = L["ALERTS_RANK_RAREELITE"] },
    { value = "elite", label = _G["ELITE"] or L["ALERTS_RANK_ELITE"] },
    { value = "worldboss", label = L["ALERTS_RANK_BOSS"] },
}
local RANK_LABEL = {}
for _, r in ipairs(RANKS) do RANK_LABEL[r.value] = r.label end

Add("nameplate", {
    group = "nearby", event = true,
    label = L["ALERTS_KIND_NAMEPLATE"],
    fields = { { key = "ranks", type = "multi", options = RANKS, default = { rare = true, rareelite = true } },
               { key = "names", type = "text", hint = L["ALERTS_HINT_MOBS"] } },
    events = { "NAME_PLATE_UNIT_ADDED" },
    -- One ring per mob for this long.
    seenFor = 300,
    Event = function(rule, ctx, _, unit)
        if not unit then return nil end
        local tr = rule.trigger
        local name = UnitName(unit)
        if not Plain(name) or UnitIsDead(unit) or UnitIsPlayer(unit) then return nil end
        local rank = UnitClassification(unit)
        if not Plain(rank) then return nil end
        local names = Words(tr.names)
        local named = #names > 0 and WordsMatch({ table.concat(names, "/") }, name)
        if not (named or (tr.ranks and tr.ranks[rank])) then return nil end
        local guid = UnitGUID(unit)
        local seenKey = Plain(guid) and guid or name
        local seen = ctx.Seen(rule, seenKey)
        if seen then return nil end
        local tag = RANK_LABEL[rank]
        return tag and sformat(L["ALERTS_NEARBY_RANK_FMT"], name, tag) or sformat(L["ALERTS_NEARBY_FMT"], name)
    end,
    Summary = function(rule)
        local parts = {}
        for _, r in ipairs(RANKS) do
            if rule.trigger.ranks and rule.trigger.ranks[r.value] then parts[#parts + 1] = r.label end
        end
        local names = rule.trigger.names
        if names and names ~= "" then parts[#parts + 1] = names end
        return sformat(L["ALERTS_SUM_NAMEPLATE"], table.concat(parts, ", "))
    end,
})

T.GROUPS = {
    { key = "ready", label = L["ALERTS_GROUP_READY"] },
    { key = "running", label = L["ALERTS_GROUP_RUNNING"] },
    { key = "resets", label = L["ALERTS_GROUP_RESETS"] },
    { key = "people", label = L["ALERTS_GROUP_PEOPLE"] },
    { key = "nearby", label = L["ALERTS_GROUP_NEARBY"] },
}

function T.Summary(rule)
    local kind = KINDS[rule.trigger.kind]
    return kind and kind.Summary(rule) or rule.trigger.kind
end

-- A trigger with every field at its default.
function T.Fresh(kind)
    local def = KINDS[kind]
    local tr = { kind = kind }
    for _, f in ipairs(def and def.fields or {}) do
        if f.default ~= nil then
            if type(f.default) == "table" then
                tr[f.key] = {}
                for k, v in pairs(f.default) do tr[f.key][k] = v end
            else
                tr[f.key] = f.default
            end
        end
    end
    return tr
end

-- What a rule says it needs before it can run (a spell, an item, words).
function T.Missing(rule)
    local def = KINDS[rule.trigger.kind]
    if not def then return L["ALERTS_ERR_KIND"] end
    local tr = rule.trigger
    for _, f in ipairs(def.fields) do
        if (f.type == "spellOrItem" and not (tr.spell or tr.item)) or (f.type == "item" and not tr.item) then
            return L["ALERTS_ERR_WHAT"]
        end
        if f.type == "aura" and not (tr.aura or tr.spell) then return L["ALERTS_ERR_AURA"] end
    end
    if tr.kind == "chatWords" and #Words(tr.words) == 0 then return L["ALERTS_ERR_WORDS"] end
    return nil
end

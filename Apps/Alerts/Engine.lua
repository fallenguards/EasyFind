local _, AL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and AL.Store and AL.Triggers and AL.Conditions) then return end

-- Runs the rules: listens only to the events switched-on rules need,
-- rings state kinds as they turn on, event kinds each time, and timed
-- kinds once per moment, waiting out a fight when the rule asks.
local Engine = {}
AL.Engine = Engine

local Store, T, C = AL.Store, AL.Triggers, AL.Conditions
local KINDS = T.KINDS
local Utils = ns.Utils
local CreateFrame, GetTime, time, InCombatLockdown = CreateFrame, GetTime, time, InCombatLockdown
local ipairs, pairs, next, type, wipe, smatch = ipairs, pairs, next, type, wipe, string.match
local mmax = math.max

-- Never saved: per rule { was, primed, last, seen }.
local runtime = {}
local queued = {}
local byEvent = {}
local pending = {}
local S = { flushAt = nil, timer = nil, timerAt = nil, started = false }

local frame = CreateFrame("Frame")
local ctx = { store = Store }

local function State(rule)
    local st = runtime[rule.id]
    if not st then
        st = {}
        runtime[rule.id] = st
    end
    return st
end

function ctx.Seen(rule, key)
    local st = State(rule)
    st.seen = st.seen or {}
    local now = time()
    local last = st.seen[key]
    local span = KINDS[rule.trigger.kind].seenFor or 300
    if last and now - last < span then return true end
    st.seen[key] = now
    return false
end

local function Refresh()
    ctx.now, ctx.gnow, ctx.char = time(), GetTime(), ns.CurrentCharacterKey()
    -- Chat senders carry the first name; Forever adds a surname after it.
    ctx.playerName = smatch(ns.PlayerName() or "", "^[^%s%-]+")
    return ctx
end

-- The text a ring shows: the rule's own message, else its name and what
-- happened.
function Engine.RingText(rule, text)
    if rule.message and rule.message ~= "" then return rule.message end
    if rule.name and rule.name ~= "" then return rule.name .. ": " .. (text or "") end
    return text or ""
end

local function Ring(rule, text)
    if EasyFind.db.alertsPaused then return end
    local st = State(rule)
    local now = time()
    if rule.gap and rule.gap > 0 and st.last and now - st.last < rule.gap then return end
    if rule.waitCombat and InCombatLockdown() then
        for _, q in ipairs(queued) do
            if q.rule == rule then
                q.text = text
                return
            end
        end
        queued[#queued + 1] = { rule = rule, text = text }
        return
    end
    st.last = now
    rule.lastFired = now
    ns.Signals.Fire(rule.signals, Engine.RingText(rule, text))
    if rule.once then
        rule.on = false
        Engine.Rebuild()
    end
    if AL.OnRang then AL.OnRang(rule) end
end
Engine.Ring = Ring

local function Schedule(at)
    if S.timerAt and S.timerAt <= at then return end
    if S.timer then S.timer:Cancel() end
    S.timerAt = at
    S.timer = C_Timer.NewTimer(mmax(0.5, at - time()), function()
        S.timer, S.timerAt = nil, nil
        Engine.EvaluateAll()
    end)
end

local function EvalState(rule)
    local kind = KINDS[rule.trigger.kind]
    local active, text, recheck = kind.State(rule, ctx)
    -- nil: unreadable now (a secret value); keep what was known.
    if active == nil then return end
    if recheck then Schedule(ctx.now + recheck + 1) end
    local st = State(rule)
    local pass = active and C.Pass(rule.conds, ctx.now) or false
    if pass and not st.was and (st.primed or kind.primeFires) then Ring(rule, text) end
    st.was = pass
    st.primed = true
end

local due = {}
local function RunTimed(rule)
    local kind = KINDS[rule.trigger.kind]
    wipe(due)
    kind.Due(rule, ctx, due)
    -- A new rule starts from now: what already happened is not news.
    local fresh = type(rule.fired) ~= "table"
    local fired = {}
    local soonest
    for _, item in ipairs(due) do
        local done = not fresh and rule.fired[item.key]
        if done or (fresh and item.at <= ctx.now) then
            fired[item.key] = true
        elseif item.at <= ctx.now then
            if C.Pass(rule.conds, ctx.now) then
                fired[item.key] = true
                Ring(rule, item.text)
            end
        elseif not soonest or item.at < soonest then
            soonest = item.at
        end
    end
    rule.fired = fired
    if soonest then Schedule(soonest) end
end

local function Evaluate(rule)
    if not rule.on or T.Missing(rule) then return end
    local kind = KINDS[rule.trigger.kind]
    if not kind then return end
    if kind.state then
        EvalState(rule)
    elseif kind.timed then
        RunTimed(rule)
    end
end

function Engine.EvaluateAll()
    Refresh()
    for _, rule in ipairs(Store:Rules()) do Evaluate(rule) end
end

local function FlushQueued()
    if #queued == 0 or InCombatLockdown() then return end
    local list = {}
    for i, q in ipairs(queued) do list[i] = q end
    wipe(queued)
    for _, q in ipairs(list) do
        if q.rule.on then Ring(q.rule, q.text) end
    end
end

-- Bursty events (auras, bags, cooldowns) settle for a moment first.
local function FlushPending()
    S.flushAt = nil
    Refresh()
    for rule, event in pairs(pending) do
        pending[rule] = nil
        local kind = KINDS[rule.trigger.kind]
        if kind and rule.on then
            if kind.timed then
                kind.Read(rule, ctx, event)
                RunTimed(rule)
            else
                EvalState(rule)
            end
        end
    end
end

local CONDITION_EVENTS = {}
for _, e in ipairs(C.EVENTS) do CONDITION_EVENTS[e] = true end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGOUT" then
        T.RecordRest(Store, ns.CurrentCharacterKey(), time())
        return
    end
    local rules = byEvent[event]
    if rules then
        Refresh()
        for _, rule in ipairs(rules) do
            local kind = KINDS[rule.trigger.kind]
            if kind.event then
                local text = kind.Event(rule, ctx, event, ...)
                if text and C.Pass(rule.conds, ctx.now) then Ring(rule, text) end
            elseif not kind.unit or (...) == kind.unit or event == "PLAYER_ENTERING_WORLD" then
                pending[rule] = event
                if not S.flushAt then
                    S.flushAt = GetTime()
                    Utils.SafeAfter(0.25, FlushPending)
                end
            end
        end
    end
    if CONDITION_EVENTS[event] then
        if event == "PLAYER_REGEN_ENABLED" then FlushQueued() end
        Engine.EvaluateAll()
    end
end)

-- Registers what the switched-on rules need, and nothing while none is on.
function Engine.Rebuild()
    for _, list in pairs(byEvent) do wipe(list) end
    frame:UnregisterAllEvents()
    local any = false
    for _, rule in ipairs(Store:Rules()) do
        local kind = KINDS[rule.trigger.kind]
        if rule.on and kind and not T.Missing(rule) then
            any = true
            for _, e in ipairs(kind.events) do
                byEvent[e] = byEvent[e] or {}
                local list = byEvent[e]
                list[#list + 1] = rule
            end
        end
    end
    for e, list in pairs(byEvent) do
        if next(list) then frame:RegisterEvent(e) end
    end
    if any then
        for e in pairs(CONDITION_EVENTS) do frame:RegisterEvent(e) end
        frame:RegisterEvent("PLAYER_LOGOUT")
    end
    for id in pairs(runtime) do
        if not Store:Find(id) then runtime[id] = nil end
    end
    if EasyFind.db then EasyFind.db.alertsInUse = any or nil end
end

-- A rule's first look at the game, as at login.
function Engine.Prime(rule)
    Refresh()
    local kind = KINDS[rule.trigger.kind]
    if kind and kind.timed then kind.Read(rule, ctx, "PLAYER_ENTERING_WORLD") end
    Evaluate(rule)
end

function Engine.Start()
    if S.started then return end
    S.started = true
    Engine.Rebuild()
    Refresh()
    for _, rule in ipairs(Store:Rules()) do
        if rule.on then Engine.Prime(rule) end
    end
end

-- A rule changed in the editor: its state starts over.
function Engine.Reset(rule)
    runtime[rule.id] = nil
    Engine.Rebuild()
    if rule.on then Engine.Prime(rule) end
end

-- What the editor's Test button rings.
function Engine.Test(rule)
    ns.Signals.Fire(rule.signals, Engine.RingText(rule, T.Summary(rule)))
end

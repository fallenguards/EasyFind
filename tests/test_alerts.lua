-- Tests for Apps/Alerts: saved rules, triggers, conditions and the engine.

local H = require("Harness")

local FILES = { "Apps/Alerts/Store.lua", "Apps/Alerts/Triggers.lua", "Apps/Alerts/Conditions.lua", "Apps/Alerts/Engine.lua" }

local function Load(opts)
    opts = opts or {}
    local env = H.newEnv()
    env._G = env
    local w = {
        rings = {}, combat = false, instance = nil, free = 10, auras = {}, secret = {},
        name = "Tester", cds = {}, items = {}, saved = {},
    }
    env.ERR_FRIEND_ONLINE_SS = "|Hplayer:%s|h[%s]|h has come online."
    env.UnitName = function() return w.name end
    env.GetUnitName = function() return w.name end
    env.GetRealmName = function() return "Realm" end
    env.InCombatLockdown = function() return w.combat end
    env.UnitAffectingCombat = function() return w.combat end
    env.IsInInstance = function() return w.instance ~= nil, w.instance or "none" end
    env.GetRealZoneText = function() return "Elwynn Forest" end
    env.GetSubZoneText = function() return "" end
    env.IsResting = function() return false end
    env.IsInRaid = function() return false end
    env.IsInGroup = function() return false end
    env.UnitClass = function() return "Mage", "MAGE", 8 end
    env.issecretvalue = function(v) return w.secret[v] == true end
    env.NUM_BAG_SLOTS = 0
    env.C_Container = {
        GetContainerNumFreeSlots = function() return w.free end,
        GetItemCooldown = function(id) local c = w.cds["i" .. id] return c and c[1] or 0, c and c[2] or 0, 1 end,
    }
    env.C_Item = { GetItemCount = function(id) return w.items[id] or 0 end }
    env.C_Spell = { GetSpellCooldown = function(id)
        local c = w.cds["s" .. id]
        return { startTime = c and c[1] or 0, duration = c and c[2] or 0 }
    end }
    env.IsPlayerSpell = function() return true end
    env.C_UnitAuras = { GetAuraDataByIndex = function(_, i) return w.auras[i] end }
    env.GetNumSavedInstances = function() return #w.saved end
    env.GetSavedInstanceInfo = function(i) local s = w.saved[i] return s[1], 1, s[2], 1, true, false, 0, true, 40, "" end
    env.RequestRaidInfo = function() end
    local clock = env._clock
    env.C_Timer.NewTimer = function(delay, fn)
        local t = { cancelled = false }
        function t.Cancel() t.cancelled = true end
        clock:after(delay, function() if not t.cancelled then fn() end end)
        return t
    end
    local frames = {}
    local makeFrame = env.CreateFrame
    env.CreateFrame = function(...)
        local f = makeFrame(...)
        frames[#frames + 1] = f
        f.UnregisterAllEvents = function() end
        return f
    end
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.EasyFind.db = {}
    env.date = os.date
    H.loadModule("Locales/enUS.lua", env, ns)
    ns.Signals = { Fire = function(_, text) w.rings[#w.rings + 1] = text end }
    local AL = {}
    for _, f in ipairs(FILES) do
        local chunk = assert(loadfile(H.ADDON_ROOT .. "/" .. f, "t", env))
        chunk("EasyFind_Alerts", AL)
    end
    AL.Store:Attach(opts.sv)
    local onEvent = frames[1]:GetScript("OnEvent")
    function w.Fire(event, ...)
        onEvent(frames[1], event, ...)
        clock:advance(0.3)
    end
    function w.Advance(s) clock:advance(s) end
    return AL, w, env
end

local tests = {}

function tests.bagsFull_ringsAtLoginOnceThenOnlyAfterClearing()
    local AL, w = Load()
    w.free = 1
    AL.Store:New({ kind = "bagsFull", slots = 2 })
    AL.Engine.Start()
    H.assertEq(#w.rings, 1, "full at login")
    w.Fire("BAG_UPDATE_DELAYED")
    H.assertEq(#w.rings, 1, "still full: no second ring")
    w.free = 8
    w.Fire("BAG_UPDATE_DELAYED")
    w.free = 0
    w.Fire("BAG_UPDATE_DELAYED")
    H.assertEq(#w.rings, 2, "full again")
end

function tests.buffMissing_ringsOnlyWhenTheBuffDrops()
    local AL, w = Load()
    w.auras = { { name = "Arcane Intellect", spellId = 1459, expirationTime = 0 } }
    AL.Store:New({ kind = "buffMissing", aura = "Arcane Intellect" })
    AL.Engine.Start()
    H.assertEq(#w.rings, 0, "present at login")
    -- A secret buff list says nothing either way.
    w.auras = { { name = "s1", spellId = 1 } }
    w.secret = { s1 = true }
    w.Fire("UNIT_AURA", "player")
    H.assertEq(#w.rings, 0, "unreadable: no ring")
    w.auras, w.secret = {}, {}
    w.Fire("UNIT_AURA", "player")
    H.assertEq(#w.rings, 1, "dropped")
end

function tests.condition_holdsTheRingUntilItPasses()
    local AL, w = Load()
    w.free = 0
    local rule = AL.Store:New({ kind = "bagsFull", slots = 2 })
    rule.conds = { { kind = "instance", value = "party" } }
    AL.Engine.Start()
    H.assertEq(#w.rings, 0, "not in a dungeon")
    w.instance = "party"
    w.Fire("ZONE_CHANGED_NEW_AREA")
    H.assertEq(#w.rings, 1, "entered one")
end

function tests.waitCombat_ringsWhenTheFightEnds()
    local AL, w = Load()
    local rule = AL.Store:New({ kind = "whisper" })
    rule.waitCombat = true
    AL.Engine.Start()
    w.combat = true
    w.Fire("CHAT_MSG_WHISPER", "inv pls", "Friend-Realm")
    H.assertEq(#w.rings, 0, "held in the fight")
    w.combat = false
    w.Fire("PLAYER_REGEN_ENABLED")
    H.assertEq(#w.rings, 1, "rung after")
    H.assertTrue(w.rings[1]:find("Friend", 1, true) ~= nil)
end

function tests.once_switchesTheRuleOff()
    local AL, w = Load()
    local rule = AL.Store:New({ kind = "whisper" })
    rule.once = true
    AL.Engine.Start()
    w.Fire("CHAT_MSG_WHISPER", "a", "X-Realm")
    w.Fire("CHAT_MSG_WHISPER", "b", "X-Realm")
    H.assertEq(#w.rings, 1)
    H.assertFalse(rule.on)
end

function tests.gap_spacesRepeatRings()
    local AL, w = Load()
    local rule = AL.Store:New({ kind = "whisper" })
    rule.gap = 60
    AL.Engine.Start()
    w.Fire("CHAT_MSG_WHISPER", "a", "X-Realm")
    w.Fire("CHAT_MSG_WHISPER", "b", "X-Realm")
    H.assertEq(#w.rings, 1)
    w.Advance(61)
    w.Fire("CHAT_MSG_WHISPER", "c", "X-Realm")
    H.assertEq(#w.rings, 2)
end

function tests.whisper_namesFilter()
    local AL, w = Load()
    AL.Store:New({ kind = "whisper", names = "Bob, alice" })
    AL.Engine.Start()
    w.Fire("CHAT_MSG_WHISPER", "hi", "Carl-Realm")
    w.Fire("CHAT_MSG_WHISPER", "hi", "Alice-Realm")
    H.assertEq(#w.rings, 1)
end

function tests.cooldownOnAnAlt_ringsOnceWhenDue()
    local AL, w, env = Load()
    local now = env.time()
    AL.Store:Char("Alt-Realm").cd = { s18560 = now + 100 }
    AL.Store:New({ kind = "cooldown", spell = 18560, label = "Mooncloth", alts = true })
    AL.Engine.Start()
    H.assertEq(#w.rings, 0)
    w.Advance(101)
    H.assertEq(#w.rings, 1)
    H.assertTrue(w.rings[1]:find("Alt", 1, true) ~= nil, w.rings[1])
    AL.Engine.EvaluateAll()
    H.assertEq(#w.rings, 1, "rung once")
end

function tests.newRule_doesNotRingWhatAlreadyHappened()
    local AL, w, env = Load()
    local now = env.time()
    AL.Store:Char("Alt-Realm").cd = { s18560 = now - 50 }
    AL.Store:New({ kind = "cooldown", spell = 18560, label = "Mooncloth", alts = true })
    AL.Engine.Start()
    H.assertEq(#w.rings, 0)
end

function tests.ownCooldown_ringsWhenReady()
    local AL, w, env = Load()
    w.cds.i6948 = { env.GetTime() - 10, 60 }
    w.items[6948] = 1
    AL.Store:New({ kind = "cooldown", item = 6948, label = "Hearthstone" })
    AL.Engine.Start()
    H.assertEq(#w.rings, 0)
    w.Advance(51)
    H.assertEq(#w.rings, 1)
end

function tests.lockouts_oneRingPerResetMoment()
    local AL, w, env = Load()
    local now = env.time()
    local at = (math.floor(now / 60) + 2) * 60
    AL.Store:Char("A-Realm").lockouts = { ["Molten Core"] = at }
    AL.Store:Char("B-Realm").lockouts = { ["Molten Core"] = at + 5, ["Onyxia's Lair"] = at + 10 }
    AL.Store:New({ kind = "lockout" })
    AL.Engine.Start()
    w.Advance(200)
    H.assertEq(#w.rings, 1)
    H.assertTrue(w.rings[1]:find("Onyxia", 1, true) ~= nil, w.rings[1])
end

function tests.friendOnline_readsTheSystemLine()
    local AL = Load()
    H.assertEq(AL.Triggers.FriendOnlineName("|Hplayer:Bob-Realm|h[Bob]|h has come online."), "Bob")
end

function tests.wordsMatch_allTermsEachWithAlternatives()
    local AL = Load()
    local W = AL.Triggers.Words("lfm strat/strath")
    H.assertTrue(AL.Triggers.WordsMatch(W, "LFM Strath UD 2 more"))
    H.assertFalse(AL.Triggers.WordsMatch(W, "LFG strat"))
end

function tests.restFullAt_aLevelAndAHalfAtTheInnRate()
    local AL = Load()
    local at = AL.Triggers.RestFullAt({ xp = 0, max = 1000, resting = true, at = 0 })
    H.assertEq(at, 864000)
    H.assertEq(AL.Triggers.RestFullAt({ xp = 0, max = 1000, resting = false, at = 0 }), 864000 * 4)
end

function tests.store_dropsBrokenRulesAndKeepsIDsAhead()
    local AL = Load({ sv = { version = 1, rules = { { id = 7, trigger = { kind = "bagsFull" } }, { id = "x" } } } })
    H.assertEq(#AL.Store:Rules(), 1)
    H.assertEq(AL.Store:New({ kind = "whisper" }).id, 8)
end

function tests.hours_crossMidnight()
    local AL = Load()
    local test = AL.Conditions.KINDS.hours.Test
    local base = os.time({ year = 2026, month = 10, day = 11, hour = 23, min = 30 })
    H.assertTrue(test({ value = "22:00-02:00" }, base))
    H.assertFalse(test({ value = "08:00-17:00" }, base))
end

-- A frame that answers every method: Get* reads 0, the rest do nothing.
local function Stub()
    local special = {
        GetText = function() return "" end,
        GetChecked = function() return false end,
        GetFont = function() return "Fonts\\FRIZQT__.TTF", 12, "" end,
        IsShown = function(self) return self._shown ~= false end,
        Show = function(self) self._shown = true end,
        Hide = function(self) self._shown = false end,
        SetShown = function(self, v) self._shown = v and true or false end,
        CreateFontString = function() return Stub() end,
        CreateTexture = function() return Stub() end,
        CreateAnimationGroup = function() return Stub() end,
        GetHighlightTexture = function() return Stub() end,
        GetParent = function() return Stub() end,
        SetScript = function(self, name, fn) self._scripts[name] = fn end,
        GetScript = function(self, name) return self._scripts[name] end,
        HookScript = function() end,
    }
    local t = { _scripts = {} }
    return setmetatable(t, { __index = function(_, k)
        if special[k] then return special[k] end
        if k:sub(1, 3) == "Get" then return function() return 0 end end
        return function() end
    end })
end

function tests.window_buildsTheListAndEveryEditor()
    local AL, w, env = Load()
    env.CreateFrame = function() return Stub() end
    local ns = env.EasyFind._ns
    ns.Utils.ShowCursorMenu = function(_, rows) w.menu = rows return Stub() end
    ns.Utils.AttachEscClose = function() end
    ns.Utils.CreateMinimalScrollBar = function() return Stub() end
    ns.StyleMenuPanel = function() end
    ns.CreateCloseX = function() return Stub() end
    ns.CreateModernButton = function() local b = Stub() b._label = Stub() return b end
    ns.RegisterAddonFont = function() end
    ns.Signals.SOUNDS, ns.Signals.COLORS = { { key = "alarm", label = "Alarm" } }, { { key = "red", label = "Red" } }
    ns.Signals.SoundLabel = function() return "Alarm" end
    ns.Signals.ColorLabel = function() return "Red" end
    env.LOCALIZED_CLASS_NAMES_MALE = { MAGE = "Mage" }
    env.C_Container.GetContainerNumSlots = function() return 0 end
    for _, f in ipairs({ "Apps/Alerts/Templates.lua", "Apps/Alerts/Window.lua" }) do
        assert(loadfile(H.ADDON_ROOT .. "/" .. f, "t", env))("EasyFind_Alerts", AL)
    end
    AL.Window.Show()
    AL.Store:New({ kind = "bagsFull", slots = 2 })
    AL.Window.Refresh()
    for _, entry in ipairs(AL.Templates.LIST) do
        local draft = AL.Templates.Draft(entry)
        for _, kind in ipairs(AL.Conditions.ORDER) do draft.conds[#draft.conds + 1] = AL.Conditions.Fresh(kind) end
        draft.conds[1].neg = true
        AL.Window.Edit(draft)
    end
    for _, kind in ipairs(AL.Triggers.ORDER) do
        AL.Window.Edit(AL.Templates.Draft({ make = function() return AL.Triggers.Fresh(kind) end }))
    end
    AL.Window.ShowList()
    H.assertTrue(#AL.Window.NewMenuRows() > 0)
end

local pass, fail, failures = H.runSuite("Alerts", tests)
return { pass = pass, fail = fail, failures = failures }

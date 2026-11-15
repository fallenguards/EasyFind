-- AceConfig options tables read as settings rows: names, paths, hidden
-- options, handler methods, the hosting Blizzard category, and the open
-- through AceConfigDialog.
local H = require("Harness")

local function FakeAce()
    local tables = {}
    local registry = {
        RegisterOptionsTable = function(_, appName, options) tables[appName] = options end,
        IterateOptionsTables = function() return pairs(tables) end,
        GetOptionsTable = function(_, appName) return tables[appName] end,
    }
    local dialog = { BlizOptions = {}, OpenFrames = {}, selected = {}, opened = {} }
    function dialog:SelectGroup(appName, ...) self.selected[appName] = { ... } end
    function dialog:Open(appName)
        self.opened[#self.opened + 1] = appName
        self.OpenFrames[appName] = { frame = {} }
    end
    return registry, dialog
end

-- shared: the next login's { db, registry, dialog, versions }: the same save
-- and the same addons' tables.
local function Load(shared)
    local env = H.newEnv()
    if shared and shared.db then env.EasyFind.db = shared.db end
    -- One addon on, at the version the test sets.
    local versions = shared and shared.versions or { "1.0" }
    env.C_AddOns.GetNumAddOns = function() return #versions end
    env.C_AddOns.GetAddOnInfo = function(i) return "Addon" .. i end
    env.C_AddOns.GetAddOnEnableState = function() return 2 end
    env.C_AddOns.GetAddOnMetadata = function(i, field) return field == "Version" and versions[i] or nil end
    env._G = env
    env.GetCVar = function() return nil end
    env.Settings = {
        GetSetting = function() return nil end,
        GetCategory = function(id)
            if id == 77 then return { GetName = function() return "Hosted Addon" end } end
        end,
    }
    env.hooksecurefunc = function(t, name, fn)
        local orig = t[name]
        t[name] = function(...)
            orig(...)
            fn(...)
        end
    end
    local registry, dialog
    if shared and shared.registry then registry, dialog = shared.registry, shared.dialog else registry, dialog = FakeAce() end
    env.LibStub = { libs = { ["AceConfigRegistry-3.0"] = registry, ["AceConfigDialog-3.0"] = dialog } }
    local ns = H.newNs(env)
    ns.Database.uiSearchData = {}
    ns.Database.ResetSearchCache = function(self) self.resetCount = (self.resetCount or 0) + 1 end
    env.EasyFind._ns = ns
    H.loadModule("Apps/Settings/BlizzSearch.lua", env, ns)
    -- A first read with nothing saved waits past the login rush (20 s).
    function ns.Populated()
        ns.BlizzOptionsSearch:Populate(false)
        env._clock:advance(25)
    end
    return ns, env, registry, dialog
end

local function RowsOf(ns, addon)
    local out = {}
    for _, e in ipairs(ns.Database.uiSearchData) do
        if e.addon == addon then out[e.name] = e end
    end
    return out
end

local tests = {}

function tests.optionsTableRowsCarryTheirGroupPath()
    local ns, _, registry, dialog = Load()
    local handler = { IsHidden = function() return false end }
    registry:RegisterOptionsTable("Hello", {
        type = "group", name = "|cff00ff00Hello|r", handler = handler,
        args = {
            general = { type = "group", name = "General", args = {
                zone = { type = "toggle", name = "Show the zone" },
                secret = { type = "toggle", name = "Secret", hidden = true },
                byMethod = { type = "toggle", name = "By method", hidden = "IsHidden" },
                size = { type = "range", name = function(info) return "Size " .. info[#info] end },
                look = { type = "group", inline = true, name = "Look", args = {
                    tint = { type = "color", name = "Tint" },
                } },
            } },
            about = { type = "description", name = "About" },
            reset = { type = "execute", name = "Reset" },
        },
    })
    ns.Populated()
    local rows = RowsOf(ns, "Hello")
    H.assertTrue(rows["Show the zone"] ~= nil, "a toggle")
    H.assertTrue(rows["By method"] ~= nil, "hidden by a handler method answering false")
    H.assertTrue(rows["Size size"] ~= nil, "a name function called with its info path")
    H.assertTrue(rows["Tint"] ~= nil, "a control in an inline group")
    H.assertTrue(rows["Reset"] ~= nil, "a button")
    H.assertNil(rows["Secret"], "hidden")
    H.assertNil(rows["About"], "a description is no setting")
    H.assertEq(rows["Show the zone"].category, "AddOn Settings")
    H.assertEq(table.concat(rows["Show the zone"].path, " > "), "Hello Settings > General")
    H.assertEq(table.concat(rows["Tint"].path, " > "), "Hello Settings > General > Look")
    H.assertEq(table.concat(rows["Tint"].steps[1].aceGroup, "/"), "general", "an inline group adds no selection")
    H.assertEq(#rows["Reset"].steps[1].aceGroup, 0)
    H.assertTrue(ns.settingsFeeds["Hello"] ~= nil, "listed as a feed for the filter flyout")

    H.assertTrue(ns.BlizzOptionsSearch:HandleStep(rows["Show the zone"].steps[1]), "handled")
    H.assertEq(dialog.opened[1], "Hello", "its own dialog opened")
    H.assertEq(dialog.selected["Hello"][1], "general", "its group selected first")
end

function tests.hostedAppsOpenThroughTheirBlizzardCategory()
    local ns, _, registry, dialog = Load()
    registry:RegisterOptionsTable("Hosted", {
        type = "group", name = "Hosted",
        args = {
            deep = { type = "group", name = "Deep", args = {
                thing = { type = "toggle", name = "Thing" },
            } },
            top = { type = "toggle", name = "Top" },
        },
    })
    dialog.BlizOptions["Hosted"] = { Hosted = { frame = { name = 77 } } }
    ns.Populated()
    local rows = RowsOf(ns, "Hosted Addon")
    H.assertTrue(rows["Top"] ~= nil, "named after the hosting category")
    H.assertEq(rows["Top"].settingsCategory, "Hosted Addon")
    H.assertEq(rows["Top"].settingCategoryID, 77)
    H.assertEq(rows["Thing"].settingCategoryID, 77, "a deeper group under the root category")
    H.assertEq(rows["Thing"].steps[1].canvasLabel, "Thing")
end

function tests.optionsBecomeInlineControlsThroughTheirOwnGetAndSet()
    local ns, _, registry = Load()
    local reg = {}
    ns.ResultRows = { RegisterCustomSetting = function(_, variable, control) reg[variable] = control end }
    local state = { on = false, size = 2, pick = "y", ran = 0 }
    local seenPath
    local handler = {
        GetOn = function(_, info) seenPath = table.concat(info, "/") return state.on end,
        SetOn = function(_, _, v) state.on = v end,
    }
    registry:RegisterOptionsTable("Hello", {
        type = "group", name = "Hello", handler = handler,
        args = {
            general = { type = "group", name = "General", args = {
                on = { type = "toggle", name = "On", desc = "Turns it on", get = "GetOn", set = "SetOn" },
                size = { type = "range", name = "Size", min = 1, max = 4, step = 1, isPercent = true,
                         get = function() return state.size end, set = function(_, v) state.size = v end },
                pick = { type = "select", name = "Pick", values = function() return { x = "Ex", y = "Why" } end,
                         get = function() return state.pick end, set = function(_, v) state.pick = v end },
                run = { type = "execute", name = "Run", func = function() state.ran = state.ran + 1 end },
                text = { type = "input", name = "Text", get = function() return "" end, set = function() end },
                zone = { type = "select", name = "Zone", get = function() return "z1" end, set = function() end,
                         values = function()
                             local v = {}
                             for i = 1, 30 do v["z" .. i] = "Zone " .. i end
                             return v
                         end },
            } },
        },
    })
    ns.Populated()
    local rows = {}
    for _, e in ipairs(ns.Database.uiSearchData) do
        if e.addon == "Hello" then rows[e.name] = e end
    end
    local function hasKeyword(row, word)
        for _, k in ipairs(row.keywords) do if k == word then return true end end
        return false
    end
    H.assertTrue(hasKeyword(rows["Pick"], "ex"), "a dropdown's choices are keywords")
    H.assertEq(#rows["Zone"].settingOptions, 30, "a long list still opens as a dropdown")
    H.assertFalse(hasKeyword(rows["Zone"], "zone 17"), "a list of every zone is no keyword set")
    H.assertEq(rows["On"].settingType, "checkbox")
    H.assertEq(rows["On"].settingTooltip, "Turns it on", "its desc as the tooltip")
    H.assertEq(reg[rows["On"].settingVariable].get(), false, "read through the handler method")
    H.assertEq(seenPath, "general/on", "with the option's info path")
    reg[rows["On"].settingVariable].set(true)
    H.assertEq(state.on, true, "written through the handler method")
    H.assertEq(rows["Size"].settingType, "slider")
    H.assertEq(rows["Size"].settingMax, 4)
    H.assertEq(rows["Size"].settingFormatter(0.5), "50%", "a percent range formats as one")
    H.assertEq(rows["Pick"].settingType, "dropdown")
    H.assertEq(rows["Pick"].settingOptions[1].label, "Ex", "values sorted by label")
    reg[rows["Pick"].settingVariable].set("x")
    H.assertEq(state.pick, "x")
    rows["Run"].settingPress()
    H.assertEq(state.ran, 1, "a button runs its func")
    H.assertNil(rows["Text"].settingVariable, "an input opens the dialog instead")
end

function tests.anAppRegisteredLaterJoinsTheIndex()
    local ns, env, registry = Load()
    registry:RegisterOptionsTable("First", { type = "group", name = "First", args = {
        a = { type = "toggle", name = "Alpha" } } })
    ns.Populated()
    H.assertNil(RowsOf(ns, "Later")["Beta"])
    registry:RegisterOptionsTable("Later", { type = "group", name = "Later", args = {
        b = { type = "toggle", name = "Beta" } } })
    env._clock:advance(0.1)
    H.assertTrue(RowsOf(ns, "Later")["Beta"] ~= nil, "pulled after its registration")
    H.assertTrue(RowsOf(ns, "First")["Alpha"] ~= nil, "the first app's rows stay")
end

-- An addon builds its options when they are read: each name's rows read
-- its own apps, so one pass reads every app once (on retail, 58 apps read
-- for each of 54 names ran every builder 54 times).
function tests.onePassReadsEachAppOnce()
    local ns, _, registry = Load()
    local reads = {}
    local get = registry.GetOptionsTable
    registry.GetOptionsTable = function(self, appName, ...)
        reads[appName] = (reads[appName] or 0) + 1
        return get(self, appName, ...)
    end
    for _, name in ipairs({ "Alpha", "Beta", "Gamma" }) do
        registry:RegisterOptionsTable(name, { type = "group", name = name, args = {
            on = { type = "toggle", name = name .. " on" },
        } })
    end
    ns.Populated()
    for _, name in ipairs({ "Alpha", "Beta", "Gamma" }) do
        H.assertTrue(RowsOf(ns, name)[name .. " on"] ~= nil, name .. "'s row")
        -- Once to name it, once for its rows.
        H.assertEq(reads[name], 2, name .. " read")
    end
end

-- The options a login reads, counted per app.
local function CountReads(registry)
    local reads = {}
    local get = rawget(registry, "_get") or registry.GetOptionsTable
    registry._get = get
    registry.GetOptionsTable = function(self, appName, ...)
        reads[appName] = (reads[appName] or 0) + 1
        return get(self, appName, ...)
    end
    return reads
end

local function Register(registry, state)
    registry:RegisterOptionsTable("Hello", { type = "group", name = "Hello", args = {
        on = { type = "toggle", name = "Shown", desc = "Shows it", get = function() return state.on end,
               set = function(_, v) state.on = v end },
        pick = { type = "select", name = "Pick", values = { [1] = "One", [2] = "Two" },
                 get = function() return state.pick end, set = function(_, v) state.pick = v end },
    } })
end

-- Same addons at the same versions: the next login lists the saved rows at
-- once and reads no addon's options until a row's control is used.
function tests.aSecondLogin_readsNoAddonsOptions()
    local state = { on = false, pick = 1 }
    local ns, env, registry, dialog = Load()
    Register(registry, state)
    ns.Populated()
    local reg = {}
    local ns2, env2 = Load({ db = env.EasyFind.db, registry = registry, dialog = dialog })
    ns2.ResultRows = { RegisterCustomSetting = function(_, variable, control) reg[variable] = control end }
    local reads = CountReads(registry)
    ns2.BlizzOptionsSearch:Populate(false)
    local rows = RowsOf(ns2, "Hello")
    H.assertTrue(rows["Shown"] ~= nil, "listed at once")
    H.assertEq(rows["Shown"].settingTooltip, "Shows it")
    H.assertEq(#rows["Pick"].settingOptions, 2, "its choices saved")
    H.assertEq(rows["Pick"].settingOptions[1].value, 1, "a number stays a number")
    H.assertNil(reads.Hello, "no options read")
    env2._clock:advance(25)
    H.assertNil(reads.Hello, "nor later")
    reg[rows["Shown"].feedVariable].set(true)
    H.assertTrue(state.on, "the control works on the live option")
    H.assertEq(reads.Hello, 1, "read once the control is used")
end

function tests.anAddonUpdated_readsAgain()
    local state = { on = false, pick = 1 }
    local ns, env, registry, dialog = Load()
    Register(registry, state)
    ns.Populated()
    local ns2, env2 = Load({ db = env.EasyFind.db, registry = registry, dialog = dialog, versions = { "1.1" } })
    local reads = CountReads(registry)
    ns2.BlizzOptionsSearch:Populate(false)
    H.assertNil(RowsOf(ns2, "Hello")["Shown"], "a new version: read as a first time")
    env2._clock:advance(25)
    H.assertTrue(RowsOf(ns2, "Hello")["Shown"] ~= nil)
    H.assertTrue((reads.Hello or 0) > 0, "read anew")
end

-- A logout before the first read finished leaves part of a save: the next
-- login reads every addon again instead of listing what was cut short.
function tests.aSaveCutShort_isReadAgain()
    local state = { on = false, pick = 1 }
    local ns, env, registry, dialog = Load()
    Register(registry, state)
    ns.Populated()
    local db = env.EasyFind.db
    H.assertTrue(db.aceSettingsCache.whole, "whole once every name is in")
    db.aceSettingsCache.whole = nil
    local ns2, env2 = Load({ db = db, registry = registry, dialog = dialog })
    local reads = CountReads(registry)
    ns2.BlizzOptionsSearch:Populate(false)
    H.assertNil(RowsOf(ns2, "Hello")["Shown"], "not listed from a part")
    env2._clock:advance(25)
    H.assertTrue(RowsOf(ns2, "Hello")["Shown"] ~= nil, "read again")
    H.assertTrue((reads.Hello or 0) > 0)
    H.assertTrue(db.aceSettingsCache.whole, "and whole again")
end

function tests.theFirstRead_waitsPastTheLoginRush_andAFight()
    local ns, env, registry = Load()
    Register(registry, { on = false, pick = 1 })
    local fighting = true
    env.InCombatLockdown = function() return fighting end
    ns.BlizzOptionsSearch:Populate(false)
    H.assertNil(RowsOf(ns, "Hello")["Shown"], "not in the login rush")
    env._clock:advance(25)
    H.assertNil(RowsOf(ns, "Hello")["Shown"], "not in a fight")
    fighting = false
    env._clock:advance(6)
    H.assertTrue(RowsOf(ns, "Hello")["Shown"] ~= nil, "read once the fight is over")
end

function tests.itsWindowOpened_readsItAgain()
    local state = { on = false, pick = 1 }
    local ns, env, registry, dialog = Load()
    Register(registry, state)
    ns.Populated()
    local ns2, env2 = Load({ db = env.EasyFind.db, registry = registry, dialog = dialog })
    ns2.BlizzOptionsSearch:Populate(false)
    local options = registry:GetOptionsTable("Hello")
    options.args.size = { type = "toggle", name = "Bigger", get = function() return false end, set = function() end }
    H.assertNil(RowsOf(ns2, "Hello")["Bigger"])
    dialog:Open("Hello")
    env2._clock:advance(1.5)
    H.assertTrue(RowsOf(ns2, "Hello")["Bigger"] ~= nil, "its rows read from the open window's options")
end

local pass, fail, failures = H.runSuite("AceOptions", tests)
return { pass = pass, fail = fail, failures = failures }

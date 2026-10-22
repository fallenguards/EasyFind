local H = require("Harness")

local function makeSetting(name, variableType)
    return {
        GetName = function() return name end,
        GetVariableType = function() return variableType or "boolean" end,
    }
end

local function makeLiveSetting(name, variable, variableType)
    return {
        GetName = function() return name end,
        GetVariable = function() return variable end,
        GetVariableType = function() return variableType or "boolean" end,
    }
end

local function makeCategory(name, id)
    return {
        GetName = function() return name end,
        GetID = function() return id or 1 end,
    }
end

local function loadOptionsSearch(opts)
    opts = opts or {}
    local env = H.newEnv()
    env._G = env
    env.GetCVar = function(variable)
        return opts.cvars and opts.cvars[variable] or nil
    end
    env.Settings = {
        GetSetting = function(variable)
            return opts.settings and opts.settings[variable] or nil
        end,
    }
    env.SettingsPanel = opts.settingsPanel

    local ns = H.newNs(env)
    ns.Database.uiSearchData = {}
    ns.Database.ResetSearchCache = function(self)
        self.resetCount = (self.resetCount or 0) + 1
    end

    -- The module ships as the EasyFind_Settings companion, which reads the
    -- parent addon's ns via the EasyFind._ns handshake.
    env.EasyFind._ns = ns
    H.loadModule("Apps/Settings/BlizzSearch.lua", env, ns)
    return ns, env
end

local function findByVariable(data, variable)
    for i = 1, #data do
        if data[i].settingVariable == variable then
            return data[i]
        end
    end
    return nil
end

local function hasKeyword(entry, keyword)
    if not entry or not entry.keywords then return false end
    for i = 1, #entry.keywords do
        if entry.keywords[i] == keyword then return true end
    end
    return false
end

local tests = {}

function tests.fastGameOptionsSkipUnregisteredHumanizedProxy()
    local ns = loadOptionsSearch({
        settings = {
            autoLootDefault = makeSetting("Auto Loot"),
        },
    })

    ns.BlizzOptionsSearch:EnsureFastGameOptions()

    H.assertNil(findByVariable(ns.Database.uiSearchData, "PROXY_SHOW_HELM"),
        "unregistered proxy variables should not be humanized into results")
    H.assertNotNil(findByVariable(ns.Database.uiSearchData, "autoLootDefault"),
        "registered settings should still be available in the fast pass")
end

function tests.fastFallbackNamesRequireLiveBacking()
    local ns = loadOptionsSearch()

    ns.BlizzOptionsSearch:EnsureFastGameOptions()

    H.assertNil(findByVariable(ns.Database.uiSearchData, "nameplateMotion"),
        "fallback CVar labels should not emit without a live CVar")
    H.assertNotNil(findByVariable(ns.Database.uiSearchData, "PROXY_VIEW_DISTANCE"),
        "explicitly supported SettingsPanel proxy rows should still emit")
end

function tests.fastFallbackNamesAllowLiveCVars()
    local ns = loadOptionsSearch({
        cvars = {
            nameplateMotion = "0",
        },
    })

    ns.BlizzOptionsSearch:EnsureFastGameOptions()

    H.assertNotNil(findByVariable(ns.Database.uiSearchData, "nameplateMotion"),
        "fallback CVar labels should emit when the CVar exists")
end

function tests.fastGameOptionsDoNotHumanizeRawLiveCVars()
    local ns = loadOptionsSearch({
        cvars = {
            nameplateShowEnemyMinions = "1",
            nameplateShowEnemyMinus = "1",
        },
    })

    ns.BlizzOptionsSearch:EnsureFastGameOptions()

    H.assertNil(findByVariable(ns.Database.uiSearchData, "nameplateShowEnemyMinions"),
        "raw live CVars should not be humanized into fake Settings rows")
    H.assertNil(findByVariable(ns.Database.uiSearchData, "nameplateShowEnemyMinus"),
        "raw live CVars should not be humanized into fake Settings rows")
end

function tests.fastNameplateFallbackUsesVisibleSettingsLabel()
    local ns = loadOptionsSearch({
        cvars = {
            nameplateShowEnemies = "1",
        },
    })

    ns.BlizzOptionsSearch:EnsureFastGameOptions()

    local entry = findByVariable(ns.Database.uiSearchData, "nameplateShowEnemies")
    H.assertNotNil(entry, "enemy unit nameplate should be available in the fast pass")
    H.assertEq(entry.name, "Enemy Unit Nameplate")
    H.assertTrue(hasKeyword(entry, "enemy nameplate"),
        "common reordered query should be an explicit keyword")
end

function tests.liveDropdownOptionLabelsBecomeSearchKeywords()
    local cat = makeCategory("Interface", 1)
    local setting = makeLiveSetting("Nameplate Aura Display", "testNameplateAuraDisplay", "number")
    local init = {
        data = {
            setting = setting,
            options = {
                { value = 1, label = "Mob Buffs, Personal Debuffs, Shared CC" },
            },
        },
    }
    local ns = loadOptionsSearch({
        settingsPanel = {
            GetAllCategories = function() return { cat } end,
            GetLayout = function(_, category)
                if category ~= cat then return nil end
                return {
                    GetInitializers = function() return { init } end,
                }
            end,
        },
    })

    local entries = ns.BlizzOptionsSearch.CollectGameSettings()
    local entry = findByVariable(entries, "testNameplateAuraDisplay")

    H.assertNotNil(entry, "live SettingsPanel dropdown rows should be collected")
    H.assertTrue(hasKeyword(entry, "mob buffs, personal debuffs, shared cc"),
        "dropdown option labels should be searchable on the owning setting row")
end

function tests.liveSettingsCanFillCuratedVariablesMissingFromFastPass()
    local cat = makeCategory("Interface", 1)
    local setting = makeLiveSetting("Enemy Player Names", "UnitNameEnemyPlayerName", "boolean")
    local init = {
        data = {
            setting = setting,
        },
    }
    local ns = loadOptionsSearch({
        settingsPanel = {
            GetAllCategories = function() return { cat } end,
            GetLayout = function(_, category)
                if category ~= cat then return nil end
                return {
                    GetInitializers = function() return { init } end,
                }
            end,
        },
    })

    local entries = ns.BlizzOptionsSearch.CollectGameSettings()
    local entry = findByVariable(entries, "UnitNameEnemyPlayerName")

    H.assertNotNil(entry,
        "live SettingsPanel rows should not be suppressed just because the variable is curated")
    H.assertEq(entry.name, "Enemy Player Names")
end

function tests.searchLowerStripsMarkupInsideNames()
    local ns = loadOptionsSearch()
    local lower = ns.BlizzOptionsSearch.SearchLower
    H.assertEq(lower("Better|cff00c0ffBlizz|rFrames |A:gmchat-icon-blizz:16:16|a"), "betterblizzframes",
        "color codes and texture escapes must not survive into the searchable name")
    H.assertEq(lower("Auto Loot"), "auto loot", "plain names are only lowered")
    H.assertEq(lower("|cff00ff00|r"), "|cff00ff00|r", "a name that is only markup keeps its raw form")
end

-- A window's toggle binding row stays out while the window's own entry is
-- offered: both open the same window.
function tests.windowToggleBindingYieldsToTheWindowsEntry()
    local ns, env = loadOptionsSearch()
    local actions = { "TOGGLECOLLECTIONS", "TOGGLEMUSIC" }
    env.GetNumBindings = function() return #actions end
    env.GetBinding = function(i) return actions[i], "Interface" end
    ns.Caps = { BUTTON_BINDING = { CollectionsMicroButton = "TOGGLECOLLECTIONS" } }
    local offered = true
    ns.Database.uiSearchData = { { name = "Collections", category = "Menu Bar", buttonFrame = "CollectionsMicroButton",
                                   available = function() return offered end } }
    ns.BlizzOptionsSearch:Populate(false)
    local function Row(action)
        for _, e in ipairs(ns.Database.uiSearchData) do
            if e.bindingAction == action then return e end
        end
    end
    local toggle = Row("TOGGLECOLLECTIONS")
    H.assertTrue(toggle and toggle.available and not toggle.available(), "hidden while the window's entry is offered")
    offered = false
    H.assertTrue(toggle.available(), "back while the window's entry is not offered")
    H.assertNil(Row("TOGGLEMUSIC").available, "other bindings left alone")
end

function tests.settingsFeedRowsOpenThroughTheirOwnFunction()
    local ns = loadOptionsSearch()
    local opened = 0
    ns.settingsFeeds = {
        ["ClassicUI Forever"] = function()
            return {
                { name = "Border thickness", path = { "Chat" }, keywords = { "edge" },
                  open = function() opened = opened + 1 end },
                { name = "", open = function() end },
                { name = "No opener" },
            }
        end,
    }
    local function Rows()
        local out = {}
        for _, e in ipairs(ns.Database.uiSearchData) do
            if e.addon == "ClassicUI Forever" then out[#out + 1] = e end
        end
        return out
    end
    ns.BlizzOptionsSearch:Populate(false)
    local rows = Rows()
    H.assertEq(#rows, 1, "only rows with a name and an opener")
    H.assertEq(rows[1].category, "AddOn Settings")
    H.assertEq(rows[1].path[2], "Chat")
    H.assertTrue(hasKeyword(rows[1], "edge"), "its keywords")
    H.assertTrue(hasKeyword(rows[1], "classicui forever"), "its addon's name")
    H.assertTrue(ns.BlizzOptionsSearch:HandleStep(rows[1].steps[1]), "handled")
    H.assertEq(opened, 1, "opened through its own function")

    ns.settingsFeeds["ClassicUI Forever"] = function()
        return { { name = "Bubbles", open = function() end } }
    end
    ns.BlizzOptionsSearch:PullSettingsFeed("ClassicUI Forever")
    rows = Rows()
    H.assertEq(#rows, 1, "a second pull replaces the addon's rows")
    H.assertEq(rows[1].name, "Bubbles")
end

function tests.settingsFeedControlsBecomeInlineRows()
    local ns = loadOptionsSearch()
    local registry = {}
    ns.ResultRows = { RegisterCustomSetting = function(_, variable, control) registry[variable] = control end }
    local state = { on = true, pick = "b", size = 3, radio = false, pressed = 0 }
    local open = function() end
    ns.settingsFeeds = {
        Hello = function()
            return {
                { name = "Box", open = open, control = { kind = "check", tooltip = "Flips it",
                    get = function() return state.on end, set = function(v) state.on = v end } },
                { name = "Radio", open = open, control = { kind = "radio",
                    get = function() return state.radio end, set = function(v) state.radio = v end } },
                { name = "Size", open = open, control = { kind = "slider", min = 1, max = 5, step = 2,
                    get = function() return state.size end, set = function(v) state.size = v end } },
                { name = "Pick", open = open, control = { kind = "choice",
                    choices = function() return { { value = "a", label = "Apple" }, { value = "b", label = "Berry" } } end,
                    get = function() return state.pick end, set = function(v) state.pick = v end } },
                { name = "Go", open = open, control = { kind = "button", press = function() state.pressed = state.pressed + 1 end } },
                { name = "Odd", open = open, control = { kind = "dial" } },
            }
        end,
    }
    ns.BlizzOptionsSearch:Populate(false)
    local byName = {}
    for _, e in ipairs(ns.Database.uiSearchData) do
        if e.addon == "Hello" then byName[e.name] = e end
    end
    local box = byName["Box"]
    H.assertEq(box.settingType, "checkbox")
    H.assertEq(box.settingTooltip, "Flips it")
    H.assertEq(registry[box.settingVariable].get(), true, "read through its own get")
    registry[box.settingVariable].set(false)
    H.assertEq(state.on, false, "written through its own set")
    registry[byName["Radio"].settingVariable].set(false)
    H.assertEq(state.radio, false, "a radio never turns off")
    registry[byName["Radio"].settingVariable].set(true)
    H.assertEq(state.radio, true)
    local size = byName["Size"]
    H.assertEq(size.settingType, "slider")
    H.assertEq(size.settingMin, 1)
    H.assertEq(size.settingMax, 5)
    H.assertEq(size.settingStep, 2)
    local pick = byName["Pick"]
    H.assertEq(pick.settingType, "dropdown")
    H.assertEq(pick.settingOptions[2].label, "Berry")
    H.assertTrue(hasKeyword(pick, "berry"), "a choice's labels find the row")
    H.assertNil(byName["Go"].settingVariable, "a button has no variable")
    byName["Go"].settingPress()
    H.assertEq(state.pressed, 1, "pressed through its own press")
    H.assertNil(byName["Odd"].settingVariable, "an unknown kind stays a plain row")
    H.assertEq(byName["Odd"].steps[1].open, open)
end

local pass, fail, failures = H.runSuite("BlizzOptionsSearch", tests)
return { pass = pass, fail = fail, failures = failures }

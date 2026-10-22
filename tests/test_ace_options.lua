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

local function Load()
    local env = H.newEnv()
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
    local registry, dialog = FakeAce()
    env.LibStub = { libs = { ["AceConfigRegistry-3.0"] = registry, ["AceConfigDialog-3.0"] = dialog } }
    local ns = H.newNs(env)
    ns.Database.uiSearchData = {}
    ns.Database.ResetSearchCache = function(self) self.resetCount = (self.resetCount or 0) + 1 end
    env.EasyFind._ns = ns
    H.loadModule("Apps/Settings/BlizzSearch.lua", env, ns)
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
    ns.BlizzOptionsSearch:Populate(false)
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
    ns.BlizzOptionsSearch:Populate(false)
    local rows = RowsOf(ns, "Hosted Addon")
    H.assertTrue(rows["Top"] ~= nil, "named after the hosting category")
    H.assertEq(rows["Top"].settingsCategory, "Hosted Addon")
    H.assertEq(rows["Top"].settingCategoryID, 77)
    H.assertEq(rows["Thing"].settingCategoryID, 77, "a deeper group under the root category")
    H.assertEq(rows["Thing"].steps[1].canvasLabel, "Thing")
end

function tests.anAppRegisteredLaterJoinsTheIndex()
    local ns, env, registry = Load()
    registry:RegisterOptionsTable("First", { type = "group", name = "First", args = {
        a = { type = "toggle", name = "Alpha" } } })
    ns.BlizzOptionsSearch:Populate(false)
    H.assertNil(RowsOf(ns, "Later")["Beta"])
    registry:RegisterOptionsTable("Later", { type = "group", name = "Later", args = {
        b = { type = "toggle", name = "Beta" } } })
    env._clock:advance(0.1)
    H.assertTrue(RowsOf(ns, "Later")["Beta"] ~= nil, "pulled after its registration")
    H.assertTrue(RowsOf(ns, "First")["Alpha"] ~= nil, "the first app's rows stay")
end

local pass, fail, failures = H.runSuite("AceOptions", tests)
return { pass = pass, fail = fail, failures = failures }

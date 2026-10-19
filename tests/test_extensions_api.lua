-- EasyFind.API extensions (Core/API.lua): registering, the tile's entry,
-- launching (a load-on-demand addon loaded first), open and close, the
-- launcher rows a search offers, and an extension's own error kept to it.
local H = require("Harness")

local function fresh()
    local env = H.newEnv()
    local errors = {}
    env.geterrorhandler = function() return function(e) errors[#errors + 1] = tostring(e) end end
    env.InCombatLockdown = function() return false end
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.EasyFind.Print = function() end
    ns.L = setmetatable({ COMPANION_INCOMPLETE_FMT = "%s is incomplete" }, { __index = function(_, k) return k end })
    return env, ns, env.EasyFind.API, errors
end

local function raises(fn, needle)
    local ok, err = pcall(fn)
    H.assertFalse(ok, "should raise")
    H.assertTrue(tostring(err):find(needle, 1, true) ~= nil, "message names it: " .. tostring(err))
end

local tests = {}

function tests.register_refusesWhatCannotWork()
    local _, _, API = fresh()
    raises(function() API.RegisterExtension("x") end, "expects a table")
    raises(function() API.RegisterExtension({ id = "a b", name = "X" }) end, "id must be")
    raises(function() API.RegisterExtension({ id = "menu", name = "X" }) end, "taken by EasyFind")
    raises(function() API.RegisterExtension({ id = "x" }) end, "name is required")
    raises(function() API.RegisterExtension({ id = "x", name = "X", open = "no" }) end, "open must be a function")
    raises(function() API.RegisterExtension({ id = "x", name = "X", icon = {} }) end, "icon must be")
end

function tests.register_stubThenTheRest()
    local _, ns, API = fresh()
    API.RegisterExtension({ id = "b", name = "Bee" })
    API.RegisterExtension({ id = "a", name = "Ay", icon = 123, tint = true })
    API.RegisterExtension({ id = "b", open = function() end })
    local entries = ns.Extensions.Entries()
    H.assertEq(#entries, 2)
    H.assertEq(entries[1].extensionID, "b", "registration order")
    H.assertEq(entries[1].name, "Bee", "the stub's name kept")
    H.assertNotNil(ns.Extensions.Get("b").open, "the rest added")
    H.assertEq(entries[2].icon, 123)
    H.assertTrue(entries[2].iconTint)
    H.assertTrue(entries[1] == ns.Extensions.Entry("b"), "one entry per extension")
end

function tests.entries_hideAnExtensionWhoseAddonIsOff()
    local _, ns, API = fresh()
    ns.IsCompanionLoadable = function(name) return name ~= "Off_Addon" end
    API.RegisterExtension({ id = "on", name = "On", addon = "On_Addon" })
    API.RegisterExtension({ id = "off", name = "Off", addon = "Off_Addon" })
    local entries = ns.Extensions.Entries()
    H.assertEq(#entries, 1)
    H.assertEq(entries[1].extensionID, "on")
end

function tests.launch_loadsTheAddonFirst()
    local env, ns, API = fresh()
    ns.IsCompanionLoadable = function() return true end
    local opened, loaded = 0, nil
    env.C_AddOns = {
        LoadAddOn = function(name)
            loaded = name
            API.RegisterExtension({ id = "lod", open = function() opened = opened + 1 end })
        end,
        GetAddOnMetadata = function() return "LoD" end,
    }
    API.RegisterExtension({ id = "lod", name = "LoD", addon = "My_LoD" })
    H.assertTrue(API.OpenExtension("lod"))
    H.assertEq(loaded, "My_LoD")
    H.assertEq(opened, 1)
end

function tests.launch_noLoadInCombatUnlessAllowed()
    local env, ns, API = fresh()
    ns.IsCompanionLoadable = function() return true end
    local loads = 0
    env.C_AddOns = { LoadAddOn = function() loads = loads + 1 end }
    env.InCombatLockdown = function() return true end
    API.RegisterExtension({ id = "x", name = "X", addon = "X_LoD" })
    H.assertFalse(API.OpenExtension("x"))
    H.assertEq(loads, 0)
    API.RegisterExtension({ id = "y", name = "Y", addon = "Y_LoD", loadInCombat = true })
    API.OpenExtension("y")
    H.assertEq(loads, 1)
end

function tests.anExtensionsErrorStaysWithIt()
    local _, _, API, errors = fresh()
    API.RegisterExtension({
        id = "x", name = "X",
        open = function() error("boom") end,
        isOpen = function() error("bang") end,
    })
    H.assertFalse(API.OpenExtension("x"))
    H.assertFalse(API.IsExtensionOpen("x"))
    H.assertEq(#errors, 2, "both reach the error handler")
end

function tests.toggle_closesWhatIsOpen()
    local _, _, API = fresh()
    local open = false
    API.RegisterExtension({
        id = "x", name = "X",
        open = function() open = true end,
        close = function() open = false end,
        isOpen = function() return open end,
    })
    API.ToggleExtension("x")
    H.assertTrue(open)
    H.assertFalse(API.ToggleExtension("x"))
    H.assertFalse(open)
end

-- A list and a settings page (the clipboard history): the launcher, the
-- apps menu and its key open the list.
function tests.launch_aListBeforeItsSettings()
    local _, _, API = fresh()
    local opened
    API.ShowScope = function(key) opened = "list " .. key end
    API.OpenSettings = function(id) opened = "settings " .. id end
    API.RegisterExtension({ id = "x", name = "X", icon = 1, scope = "clips", settings = function() end })
    API.OpenExtension("x")
    H.assertEq(opened, "list clips")
end

function tests.scope_isOpenWhileItsPillIsUp()
    local _, ns, API = fresh()
    local shown, key = true, "clips"
    ns.Filters.GetQuickFilter = function() return key and { key = key } or nil end
    ns.Filters.ClearQuickFilter = function() key = nil end
    ns.Search.GetResultsFrame = function() return { IsShown = function() return shown end } end
    ns.Results.HideResults = function() shown = false end
    API.RegisterExtension({ id = "x", name = "X", scope = "clips" })
    H.assertTrue(API.IsExtensionOpen("x"))
    H.assertEq(ns.Extensions.ScopeShowing(), "x")
    API.CloseExtension("x")
    H.assertFalse(API.IsExtensionOpen("x"))
end

function tests.launcherRows_byNameOrWords()
    local _, ns, API = fresh()
    API.RegisterExtension({ id = "a", name = "Bookmarks", keywords = { "saved places" } })
    API.RegisterExtension({ id = "b", name = "Calculator", hideFromSearch = true })
    local function ids(text)
        local out = {}
        for _, e in ipairs(ns.Extensions.LauncherMatches(text, {})) do out[#out + 1] = e.extensionID end
        return table.concat(out, ",")
    end
    H.assertEq(ids("book"), "a")
    H.assertEq(ids("places"), "a", "a word")
    H.assertEq(ids("bo"), "", "under 3 letters")
    H.assertEq(ids("calc"), "", "hidden from search")
end

function tests.badge_reachesTheIcon()
    local _, ns, API = fresh()
    local got
    ns.SetApplicationBadge = function(id, n) got = id .. "=" .. tostring(n) end
    API.SetBadge("x", 3)
    H.assertEq(got, "x=3")
end

function tests.legacyFlags_nameEveryBundledExtension()
    local _, ns = fresh()
    local seen = {}
    for _, id in pairs(ns.Extensions.LEGACY_FLAGS) do seen[id] = true end
    for _, id in ipairs({ "calculator", "icons", "snippets", "clipboard", "notes", "gps", "quicklists", "chat" }) do
        H.assertTrue(seen[id], id .. " keeps its stored copies working")
    end
end

local pass, fail, failures = H.runSuite("ExtensionsAPI", tests)
return { pass = pass, fail = fail, failures = failures }

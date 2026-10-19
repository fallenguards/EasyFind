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
    raises(function() API.RegisterExtension({ id = "x", name = "X" }) end, "icon is required")
    raises(function() API.RegisterExtension({ id = "x", name = "X", open = "no" }) end, "open must be a function")
    raises(function() API.RegisterExtension({ id = "x", name = "X", icon = {} }) end, "icon must be")
end

function tests.register_stubThenTheRest()
    local _, ns, API = fresh()
    API.RegisterExtension({ id = "b", name = "Bee", icon = 1 })
    API.RegisterExtension({ id = "a", name = "Ay", icon = 123 })
    API.RegisterExtension({ id = "b", open = function() end })
    local entries = ns.Extensions.Entries()
    H.assertEq(#entries, 2)
    H.assertEq(entries[1].extensionID, "b", "registration order")
    H.assertEq(entries[1].name, "Bee", "the stub's name kept")
    H.assertNotNil(ns.Extensions.Get("b").open, "the rest added")
    H.assertEq(entries[2].icon, 123)
    H.assertTrue(entries[1] == ns.Extensions.Entry("b"), "one entry per extension")
end

-- Shortkeys and aliases key an entry by path and name: the calculator's
-- tile keeps the path its saved keys carry.
function tests.entry_keepsABundledPath()
    local _, ns, API = fresh()
    API.RegisterExtension({ id = "calc", name = "Calculator", icon = 1, _path = { "Calculator" } })
    H.assertEq(ns.Extensions.Entry("calc").path[1], "Calculator")
end

function tests.entries_hideAnExtensionWhoseAddonIsOff()
    local _, ns, API = fresh()
    ns.IsCompanionLoadable = function(name) return name ~= "Off_Addon" end
    API.RegisterExtension({ id = "on", name = "On", icon = 1, addon = "On_Addon" })
    API.RegisterExtension({ id = "off", name = "Off", icon = 1, addon = "Off_Addon" })
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
    API.RegisterExtension({ id = "lod", name = "LoD", icon = 1, addon = "My_LoD" })
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
    API.RegisterExtension({ id = "x", name = "X", icon = 1, addon = "X_LoD" })
    H.assertFalse(API.OpenExtension("x"))
    H.assertEq(loads, 0)
    API.RegisterExtension({ id = "y", name = "Y", icon = 1, addon = "Y_LoD", loadInCombat = true })
    API.OpenExtension("y")
    H.assertEq(loads, 1)
end

function tests.anExtensionsErrorStaysWithIt()
    local _, _, API, errors = fresh()
    API.RegisterExtension({
        id = "x", name = "X", icon = 1,
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
        id = "x", name = "X", icon = 1,
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
    API.RegisterExtension({ id = "x", name = "X", icon = 1, scope = "clips" })
    H.assertTrue(API.IsExtensionOpen("x"))
    H.assertEq(ns.Extensions.ScopeShowing(), "x")
    API.CloseExtension("x")
    H.assertFalse(API.IsExtensionOpen("x"))
end

function tests.launcherRows_byNameOrWords()
    local _, ns, API = fresh()
    API.RegisterExtension({ id = "a", name = "Bookmarks", icon = 1, keywords = { "saved places" } })
    API.RegisterExtension({ id = "b", name = "Calculator", icon = 1, hideFromSearch = true })
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

-- ==== search providers ======================================================

-- Where a provider plugs in, recorded.
local function wired(ns)
    local w = { cats = {}, providers = {}, engine = {}, filters = {}, scopes = {}, replaced = {} }
    ns.CategoryMap.Add = function(e) w.cats[#w.cats + 1] = e end
    ns.Database.AddDynamicProvider = function(_, p) w.providers[p.key] = p end
    ns.Database.ReplaceCategoryEntries = function(_, cat, rows)
        w.replaced[cat] = rows or false
        return rows ~= nil
    end
    ns.SearchEngine.AddProvider = function(_, spec) w.engine[spec.key] = spec end
    ns.Filters.AddExtensionFilter = function(sub) w.filters[sub.key] = sub end
    ns.Filters.AddQuickFilter = function(_, def) w.scopes[def.key] = def end
    return w
end

function tests.provider_refusesWhatCannotWork()
    local _, _, API = fresh()
    raises(function() API.RegisterSearchProvider({ key = "x" }) end, "label is required")
    raises(function() API.RegisterSearchProvider({ key = "a b", label = "X" }) end, "key must be")
    raises(function() API.RegisterSearchProvider({ key = "x", label = "X", rows = {} }) end, "rows must be a function")
    API.RegisterSearchProvider({ key = "x", label = "X", icon = 1 })
    raises(function() API.RegisterSearchProvider({ key = "y", label = "Y" }) end, "icon is required")
    raises(function() API.RegisterSearchProvider({ key = "y", label = "Y", icon = 1, category = "x" }) end, "taken")
end

function tests.provider_borrowsItsExtensionIcon()
    local _, ns, API = fresh()
    API.RegisterExtension({ id = "m", name = "Marks", icon = 42, iconCoords = { 0, 1, 0, 1 } })
    API.RegisterSearchProvider({ key = "m", label = "Marks", extension = "m" })
    local glyph = ns.Extensions.Provider("m").glyph
    H.assertEq(glyph.tex, 42)
    H.assertEq(glyph.coords[2], 1)
    H.assertTrue(glyph.chromeTint, "painted in the theme's color")
end

function tests.provider_plugsInEverywhere()
    local _, ns, API = fresh()
    local w = wired(ns)
    local opt = { label = "Show all", get = function() return true end, set = function() end }
    API.RegisterSearchProvider({
        key = "marks", label = "Bookmarks", category = "Bookmark", words = { "mark" }, lowResults = true,
        eager = true, aliases = { "bm" }, options = { opt }, icon = 7,
    })
    H.assertEq(w.cats[1].key, "marks")
    H.assertEq(w.cats[1].parent, "extensions", "under the Extensions filter")
    H.assertEq(w.cats[1].categories[1], "Bookmark")
    H.assertTrue(w.providers.marks.eager)
    H.assertEq(type(w.providers.marks.fn), "function")
    H.assertEq(w.engine.marks.words[1], "mark")
    H.assertTrue(w.engine.marks.loadOnLowResults)
    H.assertTrue(w.filters.marks.checkboxOptions[1] == opt, "its options on its filter row")
    H.assertEq(w.scopes.marks.aliases[1], "bm")
    H.assertEq(ns.Extensions.ProviderOf({ category = "Bookmark" }).glyph.tex, 7)
end

function tests.provider_rowsTakeItsCategory()
    local _, ns, API = fresh()
    local w = wired(ns)
    API.RegisterSearchProvider({ key = "marks", label = "Bookmarks", icon = 1, rows = function() return { { name = "Home" } } end })
    H.assertTrue(w.providers.marks.fn(ns.Database))
    H.assertEq(w.replaced.marks[1].category, "marks")
end

function tests.provider_noRowsYetIsNotReady()
    local _, ns, API = fresh()
    local w = wired(ns)
    API.RegisterSearchProvider({ key = "marks", label = "Bookmarks", icon = 1 })
    H.assertFalse(w.providers.marks.fn(ns.Database), "retried later")
    H.assertEq(w.replaced.marks, false, "its category emptied")
end

function tests.provider_loadsItsAddonForSearchWhenAsked()
    local env, ns, API = fresh()
    local w = wired(ns)
    ns.IsCompanionLoadable = function() return true end
    local inUse = false
    env.C_AddOns = { LoadAddOn = function()
        API.RegisterExtension({ id = "msg", open = function() end })
        API.RegisterSearchProvider({ key = "msg", rows = function() return { { name = "Hi", icon = 1 } } end })
    end }
    API.RegisterExtension({ id = "msg", name = "Messages", icon = 1, addon = "Msg_LoD" })
    API.RegisterSearchProvider({ key = "msg", label = "Messages", icon = 1, extension = "msg",
        loadOnSearch = function() return inUse end })
    H.assertFalse(w.providers.msg.fn(ns.Database), "never used: no load")
    inUse = true
    H.assertTrue(w.providers.msg.fn(ns.Database), "used: loaded, then its rows")
end

function tests.provider_offWithItsAddon()
    local _, ns, API = fresh()
    local w = wired(ns)
    ns.IsCompanionLoadable = function() return false end
    API.RegisterExtension({ id = "msg", name = "Messages", icon = 1, addon = "Msg_LoD" })
    H.assertFalse(API.RegisterSearchProvider({ key = "msg", label = "Messages", icon = 1, extension = "msg", aliases = { "m" } }))
    H.assertNil(w.filters.msg, "no filter row")
    H.assertNil(w.scopes.msg, "no scope")
end

function tests.selectRow_getsACopyAfterTheBarCloses()
    local _, ns, API = fresh()
    wired(ns)
    local got, finished
    API.RegisterSearchProvider({ key = "marks", label = "Bookmarks", icon = 1,
        select = function(row) got = row end })
    local data = { category = "marks", name = "Home", id = 4 }
    H.assertTrue(ns.Extensions.SelectRow(data, function() finished = true end))
    H.assertTrue(finished)
    H.assertEq(got.id, 4)
    H.assertFalse(got == data, "a copy")
    H.assertFalse(ns.Extensions.SelectRow({ category = "Mount" }, function() end), "no provider's row")
end

function tests.dbOption_readsOnUnlessFalse()
    local env, ns = fresh()
    env.EasyFind.db = {}
    local changed
    local opt = ns.Extensions.DbOption("flag", "Flag", nil, function(v) changed = v end)
    H.assertTrue(opt.get())
    opt.set(false)
    H.assertEq(env.EasyFind.db.flag, false)
    H.assertFalse(opt.get())
    H.assertEq(changed, false)
end

-- ==== actions and events ======================================================

function tests.action_callsAcrossExtensions()
    local _, _, API = fresh()
    API.RegisterAction("gps", "navigate", function(dest, opts) return dest.name, opts and opts.popout end)
    H.assertTrue(API.HasAction("gps", "navigate"))
    local name, popout = API.CallAction("gps", "navigate", { name = "Booty Bay" }, { popout = true })
    H.assertEq(name, "Booty Bay")
    H.assertTrue(popout, "every result comes back")
    H.assertNil(API.CallAction("gps", "fly"), "no such action: nothing")
    H.assertNil(API.CallAction("nobody", "x"))
end

function tests.action_loadsItsOwnerFirst()
    local env, ns, API = fresh()
    ns.IsCompanionLoadable = function() return true end
    env.C_AddOns = { LoadAddOn = function()
        API.RegisterAction("notes", "flatten", function(doc) return doc.body end)
    end }
    API.RegisterExtension({ id = "notes", name = "Notes", icon = 1, addon = "Notes_LoD", loadInCombat = true })
    H.assertFalse(API.HasAction("notes", "flatten"), "not loaded yet")
    H.assertEq(API.CallAction("notes", "flatten", { body = "hi" }), "hi")
end

function tests.action_errorStaysWithIt()
    local _, _, API, errors = fresh()
    API.RegisterAction("x", "boom", function() error("boom") end)
    H.assertNil(API.CallAction("x", "boom"))
    H.assertEq(#errors, 1)
end

function tests.action_refusesWhatCannotWork()
    local _, _, API = fresh()
    raises(function() API.RegisterAction("x", "y", "z") end, "fn must be a function")
    raises(function() API.RegisterAction(nil, "y", function() end) end, "id must be a string")
end

function tests.events_reachEveryListener()
    local _, _, API, errors = fresh()
    local heard = {}
    local function one(dest) heard[#heard + 1] = "one:" .. dest end
    API.On("gps", "arrived", one)
    API.On("gps", "arrived", function() error("listener bug") end)
    API.On("gps", "arrived", function(dest) heard[#heard + 1] = "two:" .. dest end)
    API.Fire("gps", "arrived", "Ironforge")
    H.assertEq(table.concat(heard, ","), "one:Ironforge,two:Ironforge", "one listener's error stops no other")
    H.assertEq(#errors, 1)
    API.Off("gps", "arrived", one)
    API.Fire("gps", "arrived", "Stormwind")
    H.assertEq(heard[#heard], "two:Stormwind")
    H.assertEq(#heard, 3, "the one taken off hears nothing")
end

function tests.theme_colorsByRole()
    local _, ns, API = fresh()
    ns.ACTIVE_UI_PALETTE = { leafColor = { 0.9, 0.8, 0.7 }, accent = { 0.1, 0.2, 0.3, 0.5 }, light = true }
    local r, g, b, a = API.GetThemeColor("text")
    H.assertEq(r .. "," .. g .. "," .. b .. "," .. a, "0.9,0.8,0.7,1")
    H.assertEq(select(4, API.GetThemeColor("accent")), 0.5)
    H.assertTrue(API.IsLightTheme())
    raises(function() API.GetThemeColor("plaid") end, "no color named")
end

-- The options panel builds an extension's page as build(page, ctx): the
-- extension's settings get the page and the kit made from ctx.
function tests.settings_pageAndKitInTheirPlaces()
    local _, ns, API = fresh()
    local page, gotPage, gotKit = {}, nil, nil
    ns.RegisterExtensionPage = function(def) ns._page = def end
    API.RegisterExtension({ id = "x", name = "X", icon = 1, settings = function(p, kit) gotPage, gotKit = p, kit end })
    ns._page.build(page, { SELECTOR_ROW_W = 330, SELECTOR_BTN_W = 120 })
    H.assertTrue(gotPage == page, "the page first")
    H.assertEq(gotKit.ROW_WIDTH, 330, "then the kit")
    H.assertEq(type(gotKit.Checkbox), "function")
    H.assertEq(type(gotKit.Title), "function")
end

local pass, fail, failures = H.runSuite("ExtensionsAPI", tests)
return { pass = pass, fail = fail, failures = failures }

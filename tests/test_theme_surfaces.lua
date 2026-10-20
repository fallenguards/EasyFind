-- Tests for a theme's windows with their own look (Search/Results/Theme.lua):
-- a window without one reads the shared live tables, a window with one gets
-- its own set derived the same way, and a frame finds its window up its
-- parents. Loads the REAL Shared/Utils.lua and Theme.lua.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end
env.CreateFrame = function() return fakeWidget() end
env.CreateFont = fakeWidget
env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
env.UIParent = fakeWidget()
env.WorldFrame = fakeWidget()
env.GameTooltip = fakeWidget()
env.hooksecurefunc = function() end
env.GameFontNormal = setmetatable({}, { __index = function(_, k)
    if k == "GetFont" then return function() return "font", 12, "" end end
    return function() end
end })
H.loadModule("Shared/Utils.lua", env, ns)
H.loadModule("Search/Results/Theme.lua", env, ns)

local P = ns.UI_THEME_PALETTES

local function Copy(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = type(v) == "table" and Copy(v) or v
    end
    return out
end

local function Same(a, b)
    for i = 1, 4 do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- Black, with the Notes window in Linen's look.
local function Apply(withNotes)
    local theme = Copy(P.Black)
    if withNotes then theme.surfaces = { notes = Copy(P.Linen) } end
    P.Test = theme
    ns.ApplyUITheme("Test", true)
    return theme
end

local tests = {}

function tests.sharedSet_isTheLiveTables()
    Apply(false)
    local shared = ns.ThemeSet(nil)
    H.assertTrue(shared.BTN_FILL_NORMAL == ns.BTN_FILL_NORMAL, "buttons read the live table")
    H.assertTrue(shared.SEARCH_WINDOW_FILL_COLOR == ns.SEARCH_WINDOW_FILL_COLOR, "so does the window fill")
    H.assertTrue(shared.theme == ns.Results:GetActiveTheme(), "the text colors are Modern's")
    H.assertTrue(ns.ThemeSet("notes") == shared, "no look of its own: the shared set")
end

function tests.ownLook_getsItsOwnSet()
    Apply(true)
    local shared, notes = ns.ThemeSet(nil), ns.ThemeSet("notes")
    H.assertTrue(notes ~= shared, "a set of its own")
    H.assertTrue(Same(notes.SEARCH_WINDOW_FILL_COLOR, P.Linen.windowFill), "its window fill")
    H.assertTrue(Same(shared.SEARCH_WINDOW_FILL_COLOR, P.Black.windowFill), "the shared one untouched")
    H.assertEq(notes.theme.lightTheme, true, "its light look")
    H.assertEq(shared.theme.lightTheme, nil, "the shared look stays dark")
    H.assertTrue(notes.theme.rowHeight == ns.Results:GetActiveTheme().rowHeight, "sizes from Modern")
end

function tests.ownLook_derivesAsTheSharedWould()
    Apply(true)
    local notes = ns.ThemeSet("notes")
    local fills = { "BTN_FILL_NORMAL", "BTN_FILL_HOVER", "NAV_SELECTED_FILL", "PANEL_CARD_FILL",
        "EDITBOX_INSET_FILL", "TEXT_PRIMARY", "CONTROL_ACCENT" }
    local own = {}
    for _, k in ipairs(fills) do own[k] = Copy(notes[k]) end
    P.Test = Copy(P.Linen)
    ns.ApplyUITheme("Test", true)
    for _, k in ipairs(fills) do
        H.assertTrue(Same(own[k], ns[k]), k .. " as Linen derives it shared")
    end
end

function tests.frame_findsItsWindowUpItsParents()
    Apply(true)
    local window = { _efSurface = "notes" }
    local panel = { GetParent = function() return window end }
    local row = { GetParent = function() return panel end }
    H.assertTrue(ns.ThemeSetOf(row) == ns.ThemeSet("notes"), "a row deep in the window")
    H.assertTrue(ns.ThemeSetOf({}) == ns.ThemeSet(nil), "a frame of no window: shared")
    H.assertTrue(ns.ThemePaletteOf(row) == P.Test.surfaces.notes, "its look")
end

function tests.surfaces_registerOnceInOrder()
    ns.AddThemeSurface("notes", "Notes")
    ns.AddThemeSurface("gps", "GPS")
    ns.AddThemeSurface("notes", "Notes!")
    local ids = {}
    for _, s in ipairs(ns.THEME_SURFACES) do ids[#ids + 1] = s.id .. "=" .. s.label end
    H.assertEq(table.concat(ids, ","), "notes=Notes!,gps=GPS", "one page each, first order kept")
end

local pass, fail, failures = H.runSuite("ThemeSurfaces", tests)
return { pass = pass, fail = fail, failures = failures }

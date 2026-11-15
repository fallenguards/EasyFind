-- The results window's Searching line (Search/Results/Render/Core.lua):
-- while a provider or the login warm-up still has rows on the way to a
-- typed search, the footer says Searching with dots that move, once that
-- has lasted past its delay; a quick load shows nothing, an empty list
-- shows the window with the line alone, and the rows' arrival repaints.
local H = require("Harness")

local function FontString()
    local fs, text, shown = {}, nil, false
    function fs.SetText(_, t) text = t end
    function fs.GetText() return text end
    function fs.Show() shown = true end
    function fs.Hide() shown = false end
    function fs.IsShown() return shown end
    function fs.GetFont() return "font", 12, "" end
    function fs.GetStringHeight() return 10 end
    function fs.GetStringWidth() return 50 end
    function fs.GetWidth() return 200 end
    for _, m in ipairs({ "SetFont", "SetTextColor", "ClearAllPoints", "SetPoint", "SetSize" }) do fs[m] = function() end end
    return fs
end

local function Panel()
    local f, shown = {}, false
    function f.Show() shown = true end
    function f.Hide() shown = false end
    function f.IsShown() return shown end
    function f.GetWidth() return 300 end
    function f.GetHeight() return f.height or 0 end
    function f.SetHeight(_, h) f.height = h end
    for _, m in ipairs({ "SetWidth", "ClearAllPoints", "SetPoint", "SetVerticalScroll", "SetBackdrop" }) do f[m] = function() end end
    return f
end

local function World(opts)
    opts = opts or {}
    local env = H.newEnv()
    env._G = env
    env.SEARCHING = opts.gameWord
    local clock = env._clock
    env.C_Timer.NewTicker = function(interval, fn)
        local t = {}
        function t.Cancel() t.cancelled = true end
        local function Fire()
            if t.cancelled then return end
            fn(t)
            if not t.cancelled then clock:after(interval, Fire) end
        end
        clock:after(interval, Fire)
        return t
    end
    env.EasyFind = { db = { fontSize = 1 } }
    local ns = H.newNs(env)
    local w = { env = env, typed = "bran", pending = opts.pending, warming = false, newer = nil, refreshes = 0 }
    local frame = Panel()
    frame.scrollChild, frame.scrollFrame = Panel(), Panel()
    frame.updateFooter, frame.updateFooterHover = FontString(), FontString()
    w.frame = frame
    local Render = { MAX_BUTTON_POOL = 50, MAX_DEPTH = 5, Window = {}, HideUnusedResultRow = function() end }
    function Render.HideResults() frame:Hide() end
    w.Render = Render
    ns.ResultRender = Render
    ns.Search = {
        GetTypedQuery = function() return w.typed end,
        GetResultsFrame = function() return frame end,
        GetResultButtons = function() return {} end,
        GetSearchFrame = function() return Panel() end,
        RefreshActiveSearch = function()
            w.refreshes = w.refreshes + 1
            Render:ShowHierarchicalResults({})
        end,
    }
    ns.Results = {
        _collapsedNodes = {}, _SCRATCH = {},
        GetActiveTheme = function() return { resultsPadTop = 4, resultsPadBot = 4, textFaint = { 1, 1, 1 } } end,
        ScaleFont = function() end,
        IsGridShown = function() return false end,
        HideGrids = function() end,
    }
    ns.ResultSecureAttributes, ns.ResultShortcuts, ns.ResultTooltips = {}, {}, {}
    ns.SearchHistory, ns.ResultIcons = {}, {}
    ns.SearchEngine = { HasPendingProviders = function() return w.pending end }
    ns.Database = { IsWarmingProviders = function() return w.warming end }
    ns.VersionCheck = { GetAvailableVersion = function() return w.newer end }
    ns.UPDATE_NOTICE_FONT_SCALE, ns.UPDATE_NOTICE_BOTTOM_PAD, ns.UPDATE_NOTICE_TOP_PAD = 0.85, 6, 1
    H.loadModule("Search/Results/Render/Core.lua", env, ns)
    function w.Advance(s) clock:advance(s) end
    function w.Footer() return frame.updateFooter:IsShown() and frame.updateFooter:GetText() or nil end
    return w
end

local tests = {}

function tests.aQuickLoad_saysNothing()
    local w = World({ pending = true })
    w.Render:ShowHierarchicalResults({})
    H.assertFalse(w.frame:IsShown(), "under the delay an empty list stays closed")
    w.Advance(0.2)
    w.pending = false
    w.Advance(1)
    H.assertEq(w.refreshes, 0, "landed inside the delay: no repaint, no line")
    H.assertNil(w.Footer())
end

function tests.aSlowLoad_opensTheLineAlone_dotsMove_thenRepaints()
    local w = World({ pending = true, gameWord = "Searching..." })
    w.Render:ShowHierarchicalResults({})
    w.Advance(0.35)
    H.assertEq(w.refreshes, 1, "one repaint when the delay is up")
    H.assertTrue(w.frame:IsShown(), "the window opens for the line")
    H.assertEq(w.Footer(), "Searching.")
    w.Advance(0.35)
    H.assertEq(w.Footer(), "Searching..")
    w.Advance(0.35)
    H.assertEq(w.Footer(), "Searching...")
    w.Advance(0.35)
    H.assertEq(w.Footer(), "Searching.")
    w.pending = false
    w.Advance(0.35)
    H.assertEq(w.refreshes, 2, "the rows in: the search paints again")
    H.assertFalse(w.frame:IsShown(), "still nothing found: the window closes")
    w.Advance(2)
    H.assertEq(w.refreshes, 2, "the ticker stopped")
end

function tests.theWarmUp_counts_anEmptyBar_neverDoes()
    local w = World()
    w.warming = true
    w.Render:ShowHierarchicalResults({})
    w.Advance(0.35)
    H.assertEq(w.Footer(), "Searching.", "the game's word missing: the English one")
    local idle = World()
    idle.warming, idle.typed = true, ""
    idle.Render:ShowHierarchicalResults({})
    idle.Advance(1)
    H.assertFalse(idle.frame:IsShown())
    H.assertEq(idle.refreshes, 0)
end

function tests.theUpdateNotice_waitsWhileSearching()
    local w = World({ pending = true, gameWord = "Recherche…" })
    w.newer = "9.9.9"
    w.Render:ShowHierarchicalResults({})
    w.Advance(0.35)
    H.assertEq(w.Footer(), "Recherche.", "a translation's own ellipsis gives way to the dots")
    H.assertFalse(w.frame.updateFooterHover:IsShown(), "the reminder's hover is not the line's")
    w.pending = false
    H.assertTrue(w.Render:LayoutUpdateFooter(w.frame) > 0)
    H.assertEq(w.Footer(), "UPDATE_AVAILABLE_HINT UPDATE_AVAILABLE_SOURCE")
end

local pass, fail, failures = H.runSuite("SearchingLine", tests)
return { pass = pass, fail = fail, failures = failures }

-- The item sources page past its first look (2026-11-21): a section shows
-- its first rows and a row that asks to show more ("630 more" was a dead
-- line), its heading folds it, and typing narrows the rows by place or by
-- heading ("ek", "reagent"); the same words after "sources" typed.
local H = require("Harness")

local LINEN = 2589

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"), path)
    local s = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return s
end

local ZONES = { [52] = { "westfall", "eastern kingdoms", "ek" }, [10] = { "the barrens", "kalimdor", "kali" } }

-- The page over one item's sections; typed: the bar's text, for the typed form.
local function Page(sections, typed)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind = { API = {} }
    local shown, kept, selected = nil, nil, 0
    ns.L = setmetatable({ SOURCES_SHOW_MORE_FMT = "Show %d more", SOURCES_NOT_SHOWN_FMT = "%d not shown",
                          SOURCES_NONE = "No known source for %s", HINT_SOURCES = "Sources" },
        { __index = function(_, k) return k end })
    ns.Extensions = { Run = function(fn, ...) return pcall(fn, ...) end }
    ns.Filters = { ApplyQuickFilter = function() end }
    ns.MapUtils = { ZoneWords = function(m) return ZONES[m] or {} end }
    ns.Search = { GetSelectedIndex = function() return selected end, SetSelectedIndex = function(_, i) selected = i end,
                  GetTypedQuery = function() return typed end }
    ns.Results = { ShowHierarchicalResults = function(_, entries, keep)
        shown, kept = {}, keep
        for i = 1, #entries do shown[i] = entries[i] end
    end, UpdateSelectionHighlight = function() end }
    ns.RequestSourceData = function()
        ns.SourceData = { Sections = function() return sections end }
        return true
    end
    H.loadModule("Search/ItemSources.lua", env, ns)
    local function Names()
        local out = {}
        for i, e in ipairs(shown) do out[i] = e.name end
        return out
    end
    return ns.ItemSources, Names, function() return shown end, function() return kept end,
        function(i) selected = i end, function() return selected end
end

local function Creatures(n, mapOf)
    local rows = {}
    for i = 1, n do
        rows[i] = { name = "Creature " .. i, nameLower = "creature " .. i, sourceNote = (50 - i) .. "% drop chance",
                    mapID = mapOf and mapOf(i) or 52, category = "npc" }
    end
    return rows
end

local function View(text, page, view)
    view = view or { sourcesItem = { itemID = LINEN, name = "Linen Cloth" } }
    page:ShowView(view, text or "")
    return view
end

local tests = {}

function tests.aLongSection_showsItsFirstRows_andAsksBeforeMore()
    local page, Names, Shown = Page({ { label = "Dropped by", key = "dropped", rows = Creatures(30) } })
    View("", page)
    local names = Names()
    H.assertEq(names[1], "Dropped by (30)", "the heading counts what is out of sight")
    H.assertEq(names[9], "Creature 8", "eight rows")
    H.assertEq(names[10], "Show 10 more")
    H.assertEq(#names, 10)
    local more = Shown()[10].data
    H.assertEq(more.sourceNote, "22 not shown")
    H.assertNotNil(more.icon == nil or more.icon, "no red question mark: its own glyph where the art is loaded")
    H.assertTrue(more.noLearn and more.noPin and more.noMenu, "an asking row, never a result to learn or pin")
    more.pageAction(more)
    names = Names()
    H.assertEq(names[19], "Creature 18", "ten more")
    H.assertEq(names[20], "Show 10 more")
    H.assertEq(Shown()[20].data.sourceNote, "12 not shown")
    more.pageAction(more)
    more.pageAction(more)
    names = Names()
    H.assertEq(#names, 31, "the heading and all thirty")
    H.assertEq(names[1], "Dropped by", "nothing out of sight: no count")
    H.assertEq(names[31], "Creature 30")
end

function tests.theLastStep_saysHowManyItShows()
    local page, Names, Shown = Page({ { label = "Dropped by", rows = Creatures(12) } })
    View("", page)
    H.assertEq(Names()[10], "Show 4 more")
    H.assertNil(Shown()[10].data.sourceNote, "all of the rest: no second line")
end

function tests.oneRowPastTheLimit_isShown_notAskedFor()
    local page, Names = Page({ { label = "Dropped by", rows = Creatures(9) } })
    View("", page)
    local names = Names()
    H.assertEq(#names, 10)
    H.assertEq(names[1], "Dropped by")
    H.assertEq(names[10], "Creature 9")
end

function tests.aHeadingFoldsItsSection_theNextOneComesUp()
    local page, Names, Shown, Kept = Page({ { label = "Dropped by", rows = Creatures(30) },
                                            { label = "Reagent for", rows = Creatures(2) } })
    View("", page)
    local header = Shown()[1]
    H.assertTrue(header.isSectionHeader and type(header.toggle) == "function", "the heading folds: the list draws its toggle")
    H.assertFalse(header.collapsed)
    header.toggle(header)
    local names = Names()
    H.assertEq(names[1], "Dropped by (30)")
    H.assertEq(names[2], "Reagent for", "the next section right under it")
    H.assertEq(#names, 4)
    H.assertTrue(Shown()[1].collapsed, "the list draws it folded")
    H.assertTrue(Kept(), "the list stays scrolled where it was")
    Shown()[1].toggle(Shown()[1])
    H.assertEq(Names()[2], "Creature 1", "and unfolds")
    H.assertNil(Shown()[2].toggle, "a plain row has no toggle left from a heading")
end

function tests.aFoldKeepsTheSelection()
    local page, _, Shown, _, Select, Selected = Page({ { label = "Dropped by", rows = Creatures(30) } })
    View("", page)
    Select(1)
    Shown()[1].toggle(Shown()[1])
    H.assertEq(Selected(), 1, "Enter on a heading again unfolds it")
end

function tests.typingAPlace_keepsTheRowsThere()
    local rows = Creatures(30, function(i) return i % 3 == 0 and 10 or 52 end)
    local page, Names = Page({ { label = "Dropped by", rows = rows } })
    local view = View("", page)
    View("ek", page, view)
    local names = Names()
    H.assertEq(names[1], "Dropped by (20)", "the count is of the rows there")
    H.assertEq(names[4], "Creature 4", "Creature 3 is in Kalimdor")
    View("kali", page, view)
    H.assertEq(Names()[2], "Creature 3")
    View("barr", page, view)
    H.assertEq(Names()[2], "Creature 3", "part of a zone's name")
    View("ka", page, view)
    H.assertEq(Names()[1], "No known source for Linen Cloth", "two letters are no part of a place's name, and no row's")
    View("westfall 2", page, view)
    H.assertEq(Names()[2], "Creature 2", "a place and a name together")
end

function tests.aPlaceRowAnswersToEveryMapItHasASpotOn()
    local vein = { name = "Copper Vein", nameLower = "copper vein", mapID = 52, category = "treasure",
                   allInstances = { { mapID = 52, x = 0.1, y = 0.1 }, { mapID = 10, x = 0.2, y = 0.2 } } }
    local page, Names = Page({ { label = "Gathered from", rows = { vein } } })
    local view = View("kalimdor", page)
    H.assertEq(Names()[2], "Copper Vein")
    View("ek", page, view)
    H.assertEq(Names()[2], "Copper Vein")
    View("northrend", page, view)
    H.assertEq(Names()[1], "No known source for Linen Cloth")
end

function tests.typingAHeading_keepsItsWholeSection()
    local page, Names = Page({ { label = "Dropped by", rows = Creatures(3) },
                               { label = "Reagent for", rows = { { name = "Linen Bandage", sourceNote = "First Aid, 1 needed" },
                                                                 { name = "Bolt of Linen Cloth", sourceNote = "Tailoring, 2 needed" } } } })
    local view = View("reagent", page)
    local names = Names()
    H.assertEq(#names, 3)
    H.assertEq(names[1], "Reagent for")
    H.assertEq(names[3], "Bolt of Linen Cloth")
    View("reagent bolt", page, view)
    H.assertEq(#Names(), 2, "a heading word and a name word together")
end

function tests.wordsAfterSources_narrowTheTypedPage()
    local sections = { { label = "Dropped by", rows = Creatures(3) },
                       { label = "Reagent for", rows = { { name = "Linen Bandage", sourceNote = "First Aid, 1 needed" } } } }
    local page, Names = Page(sections, "linen cloth sources reagent")
    local rest, narrow = page.SourcesQuery("linen cloth sources reagent")
    H.assertEq(rest, "linen cloth")
    H.assertEq(narrow, "reagent")
    rest, narrow = page.SourcesQuery("Copper Ore Sources")
    H.assertEq(rest, "Copper Ore")
    H.assertEq(narrow, "")
    H.assertNil(page.SourcesQuery("sources"), "the word alone asks for nothing")
    H.assertNil(page.SourcesQuery("sources of power"), "nor first")
    H.assertNil(page.SourcesQuery("linen cloth"))
    page:ShowTyped({ itemID = LINEN, name = "Linen Cloth" })
    local names = Names()
    H.assertEq(names[1], "Linen Cloth", "the item's own row first")
    H.assertEq(names[2], "Reagent for")
    H.assertEq(#names, 3, "the drops narrowed away")
end

-- ==== the list ================================================================

function tests.aRowsOwnPageAction_runsAndKeepsThePage()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.InCombatLockdown = function() return false end
    ns.ResultGestures = { Blocked = function() return false end }
    ns.Learned = { RecordPick = function() error("an asking row is no pick to learn") end }
    H.loadModule("Search/Results/Handlers/Selection.lua", env, ns)
    local Handlers = ns.ResultHandlers
    Handlers.FinishResultSelection = function() error("the page stays") end
    local ran
    Handlers:SelectResult({ name = "Show 10 more", pageAction = function(row) ran = row.name end })
    H.assertEq(ran, "Show 10 more")
end

function tests.theListFoldsAHeading_onAClickAndOnEnter()
    local click = Read("Search/Results/Rows/Interactions.lua")
    H.assertTrue(click:find("if self.isSectionHeader then\n            local entry = Results:RowEntry(self.rowIndex or 0)\n"
        .. "            if entry and entry.toggle then entry.toggle(entry) end\n            return\n        end", 1, true) ~= nil,
        "a click on a heading runs its toggle")
    H.assertTrue(click:find('ns.ResultGestures.Held() == "click" and not d.pageAction', 1, true) ~= nil,
        "an asking row acts on the first click, whatever Click selects says")
    local nav = Read("Search/Results/Navigation.lua")
    H.assertTrue(nav:find("self:RowEntry(newIndex).isSectionHeader\n          and not self:RowEntry(newIndex).toggle do", 1, true) ~= nil,
        "the arrow keys stop on a heading that folds")
    H.assertTrue(nav:find("if resultRow.isSectionHeader then\n        local entry = self:RowEntry(resultRow.rowIndex or 0)\n"
        .. "        if entry and entry.toggle then entry.toggle(entry) end\n        return true\n    end", 1, true) ~= nil,
        "Enter on it runs the toggle")
    local draw = Read("Search/Results/Render/Tree.lua")
    H.assertTrue(draw:find("ns.SetQuestLogToggle(fold, entry.collapsed == true, theme)", 1, true) ~= nil,
        "the heading wears the expand / collapse glyph")
end

local pass, fail, failures = H.runSuite("SourcesPage", tests)
return { pass = pass, fail = fail, failures = failures }

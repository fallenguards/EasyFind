-- Another addon's tab column beside the quest log (ForeverCore.QuestLogTabs,
-- Shortest Path Forever's: a Quests tab and its panels' tabs, built from the
-- game's side tab template with no display mode). Our tabs were placed only
-- under tabs with a display mode, so they lay over that column (issue #33).
-- Ours now hang under its lowest tab, our Quests tab gives way to its, and
-- the two sides close each other's panel.
local H = require("Harness")

local function Source()
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/MapTab.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

-- From the line starting `from` to the end of the function it opens, or up
-- to the line starting `upto`.
local function Slice(src, from, upto)
    local s = assert(src:find(from, 1, true), from)
    if upto then return src:sub(s, assert(src:find(upto, s, true), upto) - 1) end
    local _, e = assert(src:find("\nend\n", s))
    return src:sub(s, e)
end

local function Frame(fields)
    local f = fields or {}
    f.shown = f.shown ~= false
    function f:IsShown() return self.shown end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:GetBottom() return self.bottom end
    function f:ClearAllPoints() self.point = nil end
    function f:SetPoint(_, rel) self.point = rel end
    function f:SetShown(v) self.shown = v and true or false end
    function f:SetAlpha(a) self.alpha = a end
    return f
end

local function Load()
    local src = Source()
    local mixin = {}
    function mixin:SetChecked(v) self.checked = v and true or false end
    local function Template(fields)
        local tab = Frame(fields)
        tab.SetChecked = mixin.SetChecked
        return tab
    end
    -- The game's own tabs, hidden on Forever, and the column's two.
    local gameQuests = Template({ displayMode = "Quests", OnEnter = function() end, shown = false, bottom = 520 })
    local quests = Template({ bottom = 520, checked = true })
    local services = Template({ bottom = 480 })
    local ours = Frame({ displayMode = "EasyFindMapSearch", bottom = 440 })
    local back = Frame({ bottom = 520 })
    local content = Frame()
    local qmf = Frame({ ContentFrames = { content }, TabButtons = { gameQuests }, QuestsTab = gameQuests })
    function qmf:GetChildren() return gameQuests, quests, services, ours, back end
    local servicesPanel = Frame({ shown = false })
    -- The column's API as the library has it: Select and ShowQuests check tabs.
    local api = { selected = nil }
    function api.Selected() return api.selected end
    function api.Select(key)
        api.selected = key
        servicesPanel:Show()
        services:SetChecked(true)
        quests:SetChecked(false)
    end
    function api.ShowQuests()
        api.selected = nil
        servicesPanel:Hide()
        services:SetChecked(false)
        quests:SetChecked(true)
    end
    local ourPanel = Frame({ shown = false })
    local env
    env = setmetatable({
        QuestMapFrame = qmf, SidePanelTabButtonMixin = mixin,
        ForeverCore = { QuestLogTabs = api }, ForeverQuestLogQuestsTab = quests,
        tabFrame = ours, backTab = back, TAB_STACK_GAP = -3, pageOrder = {}, extraTabs = {},
        IsMapSearchEnabled = function() return true end, Host = function() return qmf end,
        panel = ourPanel, SidePanel = {}, MapTab = {}, activePage = "page",
        SelectPage = function() end, RefreshSelectGlows = function() end,
        selectedIsOurs = false, lastSelectedWasOurs = false,
        HideOurPanel = function()
            env.selectedIsOurs = false
            ourPanel:Hide()
            env.CoverClientPanel(qmf, false)
        end,
        hooksecurefunc = function(t, name, fn)
            local orig = t[name]
            t[name] = function(...)
                orig(...)
                fn(...)
            end
        end,
    }, { __index = _G })
    env._G = env
    local code = Slice(src, "-- Another addon's tab column", "local function IsMapSearchEnabled()")
        .. Slice(src, "local function CoverClientPanel(qmf, covered)")
        .. Slice(src, "local function ShowOurPanel(pageID)")
        .. Slice(src, "-- A side tab beside the quest log", "local function JoinColumnTab(tab)")
        .. Slice(src, "local function JoinColumnTab(tab)")
        .. Slice(src, "function PlaceTab()")
        .. "\nreturn CoverClientPanel, ShowOurPanel, IsSideTab"
    local cover, show, isSideTab = assert(load(code, "=MapTab.lua column", "t", env))()
    env.CoverClientPanel = cover
    return {
        env = env, PlaceTab = env.PlaceTab, ShowOurPanel = show, IsSideTab = isSideTab, api = api,
        quests = quests, services = services, ours = ours, back = back, gameQuests = gameQuests,
        servicesPanel = servicesPanel, ourPanel = ourPanel, content = content,
    }
end

local tests = {}

function tests.aColumnTab_isASideTab_oursIsNot()
    local t = Load()
    H.assertTrue(t.IsSideTab(t.quests), "the game's side tab template, no display mode")
    H.assertTrue(t.IsSideTab(t.gameQuests), "the game's own tab")
    H.assertFalse(t.IsSideTab(t.ours), "our own tab: a plain frame")
    H.assertFalse(t.IsSideTab(t.back))
end

function tests.ourTabs_hangUnderTheColumn_andOurQuestsTabGivesWay()
    local t = Load()
    t.PlaceTab()
    H.assertTrue(t.ours.point == t.services, "under the column's lowest shown tab")
    H.assertFalse(t.back.shown, "its own Quests tab stands in for ours")
end

function tests.aColumnTabPicked_closesOurPanel()
    local t = Load()
    t.PlaceTab()
    t.ShowOurPanel()
    H.assertTrue(t.ourPanel.shown and t.env.selectedIsOurs)
    t.api.Select("services")
    H.assertFalse(t.ourPanel.shown, "its panel picked: ours goes")
    H.assertTrue(t.servicesPanel.shown)
    t.ShowOurPanel()
    t.quests.SetChecked(t.quests, true)
    H.assertFalse(t.ourPanel.shown, "its Quests tab picked: ours goes")
end

function tests.ourPanelOpened_putsTheColumnsPanelAway()
    local t = Load()
    t.PlaceTab()
    t.api.Select("services")
    t.ShowOurPanel()
    H.assertTrue(t.ourPanel.shown, "our own call into the column never closes ours")
    H.assertFalse(t.servicesPanel.shown, "its panel put away")
    H.assertNil(t.api.Selected())
    H.assertFalse(t.quests.checked, "its tabs unchecked under our panel")
    H.assertFalse(t.services.checked)
    H.assertEq(t.content.alpha, 0, "the quest log covered")
end

function tests.ourPanelClosed_givesTheQuestsTabBack()
    local t = Load()
    t.PlaceTab()
    t.ShowOurPanel()
    t.env.HideOurPanel()
    H.assertTrue(t.quests.checked, "the quest log shows again: its Quests tab checked")
    H.assertEq(t.content.alpha, 1)
end

local pass, fail, failures = H.runSuite("MapTabColumn", tests)
return { pass = pass, fail = fail, failures = failures }

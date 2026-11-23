-- The settings page inside the game's settings window (Settings > AddOns
-- > EasyFind) under the Classic theme: the iron bar between the sidebar
-- and the page ran through the page, the "EasyFind" title plate sat on top
-- of it and the search box on the border's metal (2026-11-23). The page
-- there has no column and no title on any theme.
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local options = Read("Apps/Options/OptionsPanel.lua")

local function Header(classic)
    local body = Read("Shared/Utils.lua"):match("(function ns%.ApplyClassicHeader%(frame, title%).-\nend)\n")
    assert(body, "ApplyClassicHeader is there")
    local ns = { IsClassicChrome = function() return classic end, CLASSIC_HEADER = "header" }
    local function Region()
        local r = { shown = true }
        function r:SetShown(v) self.shown = v and true or false end
        function r:SetTexture() end
        function r:SetSize() end
        function r:SetPoint() end
        function r:SetText(t) self.text = t end
        return r
    end
    local frame = { CreateTexture = function() return Region() end, CreateFontString = function() return Region() end }
    local chunk = assert(load("local ns = ...\n" .. body, "header", "t", {}))
    chunk(ns)
    return ns.ApplyClassicHeader, frame
end

local tests = {}

function tests.noTitle_noPlate()
    local apply, frame = Header(true)
    apply(frame, "EasyFind")
    H.assertTrue(frame._efClassicHeader.plate.shown, "the standalone window's plate")
    H.assertEq(frame._efClassicHeader.text.text, "EasyFind")
    apply(frame, nil)
    H.assertFalse(frame._efClassicHeader.plate.shown, "no title: no plate")
    H.assertFalse(frame._efClassicHeader.text.shown)
end

function tests.theGameSettingsPage_asksForNoTitle()
    H.assertTrue(options:find('ns%.ApplyClassicHeader%(self%.bgTex, not self%.paged and "EasyFind" or nil%)') ~= nil)
end

function tests.theColumnRule_isNotDrawnWithoutTheColumn()
    local rule = options:match("local function ShowColumnRule%(%)(.-)\n    end\n")
    H.assertTrue(rule ~= nil, "one owner for the rule")
    H.assertTrue(rule:find("divider:SetShown%(not classic and not optionsFrame%.paged%)") ~= nil)
    H.assertTrue(rule:find("sidebarIron:SetShown%(classic and not optionsFrame%.paged%)") ~= nil)
    local shows = 0
    for line in options:gmatch("[^\n]+") do
        if line:find("sidebarIron:SetShown", 1, true) or line:find("divider:SetShown", 1, true) then shows = shows + 1 end
    end
    H.assertEq(shows, 2, "nothing else shows them")
end

function tests.theStrip_clearsTheClassicMetal()
    local strip = options:match("function optionsFrame%.PlacePagedStrip%(%)(.-)\n    end\n")
    H.assertTrue(strip ~= nil, "PlacePagedStrip is there")
    H.assertTrue(strip:find("local top = ns%.IsClassicChrome%(%) and CLASSIC_EDGE or 10") ~= nil)
    H.assertTrue(options:find("if optionsFrame%.PlacePagedStrip then optionsFrame%.PlacePagedStrip%(%) end") ~= nil,
        "a theme change places it again")
end

local pass, fail, failures = H.runSuite("EmbeddedClassic", tests)
return { pass = pass, fail = fail, failures = failures }

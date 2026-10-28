-- The map's "Show me how" on a map with no navigation bar (the classic
-- clients'): it asks for a right-click to zoom out and waits, where it
-- once moved the map itself and taught nothing (MoP, 2026-10-26).
-- MapSearch/Zones/Breadcrumbs.lua.
local H = require("Harness")

local function Frame()
    local f = { shown = true, points = {} }
    return setmetatable(f, { __index = function(_, k)
        if k == "Show" then return function(self) self.shown = true end end
        if k == "Hide" then return function(self) self.shown = false end end
        if k == "IsShown" then return function(self) return self.shown end end
        if k == "SetText" then return function(self, v) self.text = v end end
        if k == "GetStringWidth" then return function() return 200 end end
        if k == "GetParent" then return function() return f.parent end end
        if k == "CreateTexture" or k == "CreateFontString" then return function() return Frame() end end
        if type(k) == "string" and k:match("^%u") then return function() end end
    end })
end

local function Load()
    local env = H.newEnv()
    local ns = H.newNs(env)
    local moved = {}
    env.WorldMapFrame = Frame()
    env.WorldMapFrame.ScrollContainer = Frame()
    env.WorldMapFrame.NavBar = false   -- the classic clients' map
    env.WorldMapFrame.SetMapID = function(_, id) moved[#moved + 1] = id end
    env.WorldMapFrame.GetMapID = function() return 13 end
    env.CreateFrame = function(_, _, parent) local f = Frame() f.parent = parent return f end
    env.C_Map = { GetMapInfo = function(id) return { name = "Map " .. id } end }
    ns.L.MAP_GUIDE_ZOOM_OUT = "Right-click the map to zoom out"
    ns.MapUtils = { GetMapPath = function() return {} end }
    ns.MapSearchFrames = { AttachBounceAnimation = function(f, o) f[o.groupKey] = { Play = function() f.pulsing = true end } end }
    local MapSearch = { ClearZoneHighlight = function(self) if self.zoomOutHint then self.zoomOutHint:Hide() end end }
    ns.MapSearch = MapSearch
    H.loadModule("MapSearch/Zones/Breadcrumbs.lua", env, ns)
    return MapSearch, moved
end

local tests = {}

function tests.noNavigationBar_asksForARightClick_andLeavesTheMap()
    local MapSearch, moved = Load()
    MapSearch:HighlightBreadcrumbForNavigation(12, 1429, {}, 1)
    H.assertEq(#moved, 0, "the map is not moved for the player")
    local hint = MapSearch.zoomOutHint
    H.assertTrue(hint and hint.shown, "the hint shows")
    H.assertEq(hint.text.text, "Right-click the map to zoom out")
    H.assertTrue(hint.pulsing)
    H.assertEq(MapSearch.pendingZoneHighlight, 1429, "the map change guides on to the zone")
    MapSearch:ClearZoneHighlight()
    H.assertFalse(hint.shown, "the next step clears it")
end

-- The words on the map itself beside the game's right-click glyph: a
-- black box held them (2026-10-28).
function tests.theHintIsAGlyphAndWordsOnTheMap()
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Zones/Breadcrumbs.lua", "rb"))
    local src = f:read("*a")
    f:close()
    H.assertTrue(src:find('hint%.glyph:SetAtlas%("NPE_RightClick"%)') ~= nil, "the game's right-click glyph, on every client")
    H.assertTrue(src:find('hint%.text:SetPoint%("LEFT", hint%.glyph, "RIGHT", 6, 0%)') ~= nil, "the words beside it")
    H.assertTrue(src:find("SetColorTexture%(0, 0, 0, 0%.75%)") == nil, "no box")
    H.assertTrue(src:find('hint:SetPoint%("BOTTOM", hint:GetParent%(%), "BOTTOM", 0, 14%)') ~= nil,
        "over the map's bottom: the top has the zone names")
end

-- A hover on the map (its zone outline) put the hint away before any
-- right-click (2026-10-28): the hint stays through a hover's outline and
-- its end, and goes with the breadcrumb guide it belongs to.
function tests.theHintStaysThroughAHoverOnTheMap()
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Zones/Highlight.lua", "rb"))
    local src = f:read("*a")
    f:close()
    H.assertTrue(src:find("if self%.zoomOutHint and not preserveBreadcrumb then self%.zoomOutHint:Hide%(%) end") ~= nil,
        "a hover's end keeps it")
    H.assertTrue(src:find("local hintShown = self%.zoomOutHint ~= nil and self%.zoomOutHint:IsShown%(%)%s+"
        .. "DebugPrint%(.-%)%s+self:ClearZoneHighlight%(%)%s+self%.pendingZoneHighlight, self%._zoneGuide = savedPending, savedGuide%s+"
        .. "if hintShown then self%.zoomOutHint:Show%(%) end") ~= nil, "a hover's outline keeps it")
end

local pass, fail, failures = H.runSuite("MapZoomOutHint", tests)
return { pass = pass, fail = fail, failures = failures }

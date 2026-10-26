-- Alt-click for directions (Apps/GPS/MapClick.lua): a spot on the world map
-- or the pin under the cursor, the game's waypoint pin naming it in its
-- tooltip, and a map pin linked in chat. Plain and Shift clicks stay the
-- game's (Shift shares a pin in chat).
local H = require("Harness")

local function Load()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    local went = {}
    ns.GPS = { NavigateTo = function(_, data) went[#went + 1] = data return true end }
    ns.L.GPS_MAP_POINT_FMT = "%s %.1f, %.1f"
    ns.Utils.RegisterEventIfValid = function(f, event) f:RegisterEvent(event) return true end
    ns.Utils.SafeAfter = function(_, fn) fn() end
    local alt = false
    env.IsAltKeyDown = function() return alt end
    local scripts, frames = {}, {}
    env.CreateFrame = function()
        local f = { events = {} }
        function f:SetScript(name, fn) self[name] = fn end
        function f:RegisterEvent(e) self.events[e] = true end
        function f:UnregisterAllEvents() self.events = {} end
        frames[#frames + 1] = f
        return f
    end
    local map = { mapID = 84, shown = true, over = true, cursor = { 0.25, 0.75 } }
    map.ScrollContainer = { IsMouseOver = function() return map.over end }
    function map:IsVisible() return self.shown end
    function map:IsShown() return self.shown end
    function map:GetMapID() return self.mapID end
    function map:SetMapID(id) self.mapID = id end
    function map:GetNormalizedCursorPosition() return self.cursor[1], self.cursor[2] end
    function map:HookScript(name, fn) scripts[name] = fn end
    function map:GetScript(name) return scripts[name] end
    env.WorldMapFrame = map
    local foci = {}
    env.GetMouseFoci = function() return foci end
    env.C_Map = { GetMapInfo = function(id) return { name = "Map " .. id } end }
    local tip = { lines = {} }
    function tip:HookScript(_, fn) self.onShow = fn end
    function tip:GetOwner() return self.owner end
    function tip:AddLine(text) self.lines[#self.lines + 1] = text end
    function tip:Show() end
    env.GameTooltip = tip
    local itemRef
    env.hooksecurefunc = function(name, fn) if name == "SetItemRef" then itemRef = fn end end
    H.loadModule("Apps/GPS/MapClick.lua", env, ns)
    for _, f in ipairs(frames) do if f.OnEvent and f.events.PLAYER_LOGIN then f.OnEvent(f, "PLAYER_LOGIN") end end
    local watch = frames[1]
    return {
        went = went, map = map, tip = tip, foci = foci, scripts = scripts,
        alt = function(v) alt = v end,
        press = function(button)
            watch.OnEvent(watch, "GLOBAL_MOUSE_DOWN", button or "LeftButton")
            watch.OnEvent(watch, "GLOBAL_MOUSE_UP", button or "LeftButton")
        end,
        link = function(link, button) itemRef(link, "[Map Pin]", button or "LeftButton") end,
        watching = function() return watch.events.GLOBAL_MOUSE_DOWN == true end,
    }
end

local tests = {}

function tests.altClickOnTheMap_routesToTheSpot_andTheZoomGoesBack()
    local t = Load()
    t.scripts.OnShow(t.map)
    H.assertTrue(t.watching(), "the mouse watched while the map is up")
    t.alt(true)
    t.press()
    H.assertEq(#t.went, 1)
    H.assertEq(t.went[1].mapID, 84)
    H.assertEq(t.went[1].x, 0.25)
    H.assertEq(t.went[1].name, "Map 84 25.0, 75.0")
end

function tests.thePinUnderTheCursor_givesItsSpotAndName()
    local t = Load()
    t.scripts.OnShow(t.map)
    t.foci[1] = { owningMap = t.map, name = "Flight Master", GetPosition = function() return 0.5, 0.4 end }
    t.alt(true)
    t.press()
    H.assertEq(t.went[1].name, "Flight Master")
    H.assertEq(t.went[1].y, 0.4)
end

function tests.plainAndRightClicks_stayTheGames()
    local t = Load()
    t.scripts.OnShow(t.map)
    t.press()
    t.alt(true)
    t.press("RightButton")
    t.map.over = false
    t.press()
    H.assertEq(#t.went, 0)
end

function tests.theMapClosed_theMouseIsLeftAlone()
    local t = Load()
    t.scripts.OnShow(t.map)
    t.scripts.OnHide(t.map)
    H.assertFalse(t.watching())
end

function tests.theGamesWaypointPin_namesTheAltClick_otherTooltipsDoNot()
    local t = Load()
    t.tip.owner = { owningMap = t.map, CopySlashCommandToClipboard = function() end }
    t.tip.onShow(t.tip)
    H.assertEq(t.tip.lines[1], "GPS_ALT_CLICK_PIN")
    t.tip.lines = {}
    t.tip.owner = { owningMap = t.map }
    t.tip.onShow(t.tip)
    H.assertEq(#t.tip.lines, 0)
end

function tests.aMapPinLinkInChat_altClicked_routesThere()
    local t = Load()
    t.link("worldmap:84:5000:2500")
    H.assertEq(#t.went, 0, "a plain click is the game's: it sets the pin")
    t.alt(true)
    t.link("worldmap:84:5000:2500")
    H.assertEq(t.went[1].mapID, 84)
    H.assertEq(t.went[1].x, 0.5)
    H.assertEq(t.went[1].y, 0.25)
    t.link("item:1234")
    H.assertEq(#t.went, 1, "other links are not places")
end

local pass, fail, failures = H.runSuite("GPSMapClick", tests)
return { pass = pass, fail = fail, failures = failures }

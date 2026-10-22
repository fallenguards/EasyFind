-- Tests for the GPS section snapped into the tracker (Apps/GPS/GPS.lua
-- PlaceDock): it hangs in its slot, and goes back there after something
-- else anchored it.

local H = require("Harness")

local function Frame(height, left, bottom, width)
    local f = { points = {}, rect = { left or 0, bottom or 0, width or 0, height or 40 } }
    function f:GetRect() return self.rect[1], self.rect[2], self.rect[3], self.rect[4] end
    function f:GetEffectiveScale() return 1 end
    function f:ClearAllPoints() self.points = {} end
    function f:SetPoint(p, rel, rp, x, y) self.points[#self.points + 1] = { p, rel, rp, x, y } end
    function f:GetPoint(i)
        local q = self.points[i]
        if q then return q[1], q[2], q[3], q[4], q[5] end
    end
    function f:SetWidth(w) self.width = w end
    function f:GetWidth() return self.width or 0 end
    function f:GetHeight() return height or 40 end
    function f:GetFrameLevel() return 10 end
    function f:SetFrameLevel() end
    function f:GetAlpha() return 1 end
    function f:SetAlpha() end
    return f
end

-- PlaceDock cut from GPS.lua (the rest of the file needs the whole client),
-- with a tracker whose one section the GPS section sits above.
local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local function PlaceDock()", 1, true), "PlaceDock not in GPS.lua")
    local e = assert(src:find("-- A drag in progress over the tracker", s, true), "end of PlaceDock not found")
    local tracker = Frame(400, 100, 300, 272)
    function tracker:IsCollapsed() return false end
    local quests = Frame(200, 112, 450, 248)
    quests.leftMargin, quests.width = 12, 248
    tracker.modules = { quests }
    local dock = Frame(40)
    dock.docked = true
    local uiParent = Frame(1000)
    local env = setmetatable({
        dockFrame = dock,
        UIParent = uiParent,
        SectionLook = function() return dock.look end,
        Host = function() return "game" end,
        Watch = function() return nil end,
        Tracker = function() return tracker end,
        VisibleModules = function() return { quests } end,
        DB = function() return {} end,
        DockMouse = function() end,
        Refresh = function() end,
        Look = { ScreenRect = function(r)
            local l, b, w, h = r:GetRect()
            local k = r:GetEffectiveScale()
            return l * k, (b + h) * k, (l + w) * k, b * k
        end },
        mmax = math.max,
        DOCK_HEADER_H = 25,
    }, { __index = _G })
    return assert(load(src:sub(s, e - 1) .. "\nreturn PlaceDock", "=GPS.lua PlaceDock", "t", env))(), dock, tracker, uiParent
end

local tests = {}

-- Under the tracker's last section, a section's spacing below it, hung
-- on the screen: nothing of ours is written into the tracker.
function tests.hangsUnderTheLastSection()
    local PlaceDock, dock, _, uiParent = Load()
    PlaceDock()
    local p, rel, _, x, y = dock:GetPoint(1)
    H.assertEq(p, "TOPLEFT")
    H.assertEq(rel, uiParent)
    H.assertEq(x, 112, "the tracker's left plus the sections' margin")
    H.assertEq(y, 440, "the quests' bottom less the spacing")
    H.assertEq(dock.width, 248, "a section's width")
end

-- Dragged out and dropped back in the same slot: the drag's ghost hung it
-- on the window, and the same place must not leave it there.
function tests.backInItsSlotAfterADrag()
    local PlaceDock, dock, _, uiParent = Load()
    PlaceDock()
    local window = Frame(80)
    dock:ClearAllPoints()
    dock:SetPoint("TOPLEFT", window, "TOPLEFT", 0, 0)
    PlaceDock()
    local _, rel = dock:GetPoint(1)
    H.assertEq(rel, uiParent, "back under the tracker, not on the window")
end

-- Every line of the section is a button, and a button that takes only the
-- left click swallows the right one: each takes it and opens a menu.
function tests.everyLineOpensTheMenuOnRightClick()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    for _, b in ipairs({
        { "local function TipRow(" }, { "local function DockLine(" }, { "local function DockTipLine(" },
        { "local function DockFromLine(" },
        { "function Look.EraLine(" }, { "local eraGrip = CreateFrame", "f.eraGrip = eraGrip" },
        { "local titleBtn = CreateFrame", "f.titleBtn = titleBtn" },
    }) do
        local s = assert(src:find(b[1], 1, true), b[1] .. " not in GPS.lua")
        local e = b[2] and src:find(b[2], s, true) or src:find("\nend\r?\n", s)
        local body = src:sub(s, assert(e, b[1] .. ": no end"))
        local buttons = select(2, body:gsub('CreateFrame%("Button"', ""))
        local right = select(2, body:gsub("RightButtonUp", ""))
        H.assertTrue(right >= buttons, b[1] .. ": a button that takes no right click")
        H.assertTrue(body:find("ShowMenu", 1, true) ~= nil or body:find("ShowDockMenu", 1, true) ~= nil
            or body:find("ShowStepMenu", 1, true) ~= nil, b[1] .. ": no menu")
    end
end

-- GPS.MenuRows cut from GPS.lua, with a route on and the rows it calls stubbed.
local function MenuRows()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function GPS.MenuRows(f)", 1, true), "GPS.MenuRows not in GPS.lua")
    local _, e = src:find("\nend\r?\n", s)
    assert(e, "end of GPS.MenuRows not found")
    local function row(label) return function() return { kind = "check", label = label } end end
    local GPS = {
        WorldPinRow = row("GPS_WORLD_PIN"), SnapRow = row("GPS_SNAP_TRACKER"), AutoLearnRow = row("GPS_AUTO_LEARN"),
        DetoursRow = row("GPS_SHOW_DETOURS"), OtherWaysRow = row("GPS_SHOW_OTHER_WAYS"), LaunchRow = row("GPS_LAUNCH_WINDOW"),
        HideDoneRow = row("GPS_HIDE_DONE"),
        StyleMenu = function() return { kind = "submenu", label = "GPS_STYLE", rows = {} } end,
        PlanningMenu = function() return { kind = "submenu", label = "GPS_PLANNING", rows = {} } end,
    }
    function GPS.PicksMenu(label, choices, current)
        local rows = {}
        for i = 1, #choices do rows[i] = { text = choices[i][2], picked = current == choices[i][1] } end
        return { kind = "submenu", label = label, rows = rows }
    end
    local env = setmetatable({
        GPS = GPS,
        L = setmetatable({}, { __index = function(_, k) return k end }),
        ns = {
            ResultLinks = { BuildRouteText = function() return "route link" end },
            BuildSendLinkRows = function() return { { text = "Say" } } end,
        },
        Route = function() return { dest = { name = "Astaia" } } end,
        RouteTracked = function() return false end,
        ToggleRouteTracking = function() end,
        DB = function() return {} end,
        CharDB = function() return {} end,
        PopoutSize = function() return 300 end,
        SetPopoutSize = function() end,
        SIZE_WIDTHS = { { 240, "GPS_SIZE_NARROW" }, { 300, "GPS_SIZE_NORMAL" } },
        SIZE_HEIGHTS = { { nil, "GPS_SIZE_FIT" }, { 160, "GPS_SIZE_SHORT" } },
    }, { __index = _G })
    assert(load(src:sub(s, e), "=GPS.lua MenuRows", "t", env))()
    return GPS.MenuRows
end

-- The section snapped in, floating in either look, and the window: the
-- route's actions and settings on every one, the size only on the window.
function tests.everySurfaceHasTheSameMenu()
    local rowsFor = MenuRows()
    local shared = { "GPS_CLEAR", "GPS_FROM_PICK", "CTX_SEND_LINK", "GPS_REPORT",
        "GPS_WORLD_PIN", "GPS_SNAP_TRACKER", "GPS_PLANNING", "GPS_LAUNCH_WINDOW", "GPS_HIDE_DONE" }
    for _, s in ipairs({
        { name = "snapped in", f = { docked = true } },
        { name = "floating", f = { floating = true, look = "game" }, style = true },
        { name = "floating Era", f = { floating = true, look = "era" }, style = true },
        { name = "window", f = { isPopout = true }, style = true, size = true },
    }) do
        local has = {}
        for _, d in ipairs(rowsFor(s.f)) do
            if d.label then has[d.label] = true end
        end
        for _, label in ipairs(shared) do H.assertTrue(has[label], s.name .. ": no " .. label) end
        H.assertEq(has.GPS_STYLE == true, s.style == true, s.name .. ": style rows")
        H.assertEq(has.GPS_SIZE_WIDTH == true, s.size == true, s.name .. ": width rows")
    end
end

-- Style, width and height are flyouts holding their picks, the one in use
-- picked; their picks never sit in the menu itself.
function tests.settingsWithPicksAreFlyouts()
    local defs = MenuRows()({ isPopout = true })
    local flyouts = {}
    for _, d in ipairs(defs) do
        H.assertTrue(d.kind ~= "radio" and d.kind ~= "title", "a pick or a heading in the menu itself: " .. tostring(d.label))
        if d.kind == "submenu" then flyouts[d.label] = d end
    end
    for _, label in ipairs({ "GPS_STYLE", "GPS_PLANNING", "GPS_SIZE_WIDTH", "GPS_SIZE_HEIGHT" }) do
        H.assertTrue(flyouts[label] ~= nil, label .. " is a flyout")
    end
    local width, height = flyouts.GPS_SIZE_WIDTH.rows, flyouts.GPS_SIZE_HEIGHT.rows
    H.assertEq(#width, 2)
    H.assertTrue(width[2].picked and not width[1].picked, "the width in use is picked")
    H.assertTrue(height[1].picked and not height[2].picked, "fit to steps, as no height is set")
end

-- Route planning's three switches share one flyout, the window's border
-- sits under the looks in the style flyout, and a switch flips in place.
function tests.planningAndBorderAreFlyoutSwitches()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local MENU_CHECK", 1, true), "MENU_CHECK not in GPS.lua")
    local s2 = assert(src:find("function GPS.StyleMenu(border)", s, true), "GPS.StyleMenu(border) not after it")
    local _, e = src:find("\nend\r?\n", s2)
    local on = { learn = true, detours = false, ways = true }
    local function check(key, label)
        return function()
            return { kind = "check", label = label, get = function() return on[key] end, set = function(v) on[key] = v end }
        end
    end
    local db = {}
    local GPS = { AutoLearnRow = check("learn", "GPS_AUTO_LEARN"), DetoursRow = check("detours", "GPS_SHOW_DETOURS"),
        OtherWaysRow = check("ways", "GPS_SHOW_OTHER_WAYS") }
    local palette = { chrome = nil }
    local env = setmetatable({ GPS = GPS, L = setmetatable({}, { __index = function(_, k) return k end }),
        PopoutStyle = function() return "easyfind" end, DB = function() return db end, HideMenus = function() end,
        ns = { ACTIVE_UI_PALETTE = palette } }, { __index = _G })
    assert(load(src:sub(s, e), "=GPS.lua flyouts", "t", env))()
    local planning = GPS.PlanningMenu()
    H.assertEq(planning.kind, "submenu")
    local rows = planning.rows()
    H.assertEq(#rows, 3)
    H.assertEq(rows[1].text, "GPS_AUTO_LEARN")
    H.assertTrue(rows[1].keepOpen and rows[1].icon ~= nil, "on: ticked, and a click keeps the flyout open")
    H.assertNil(rows[2].icon, "off: no tick")
    rows[2].onClick()
    H.assertTrue(on.detours, "the click flips it")
    H.assertTrue(planning.rows()[2].icon ~= nil, "listed anew, it is ticked")
    local border = { label = "GPS_SIZE_BORDER", get = function() return true end, set = function() end }
    local style = GPS.StyleMenu(border).rows()
    H.assertEq(style[#style].text, "GPS_SIZE_BORDER", "the border under the looks")
    H.assertTrue(style[#style - 1].isSeparator)
    H.assertEq(#GPS.StyleMenu(nil).rows(), 3, "no border row off the window")
    -- The row opens a choice of rims: the quest log's paper or the line;
    -- a theme with frame art of its own offers that first and by default.
    local rims = style[#style].submenu
    H.assertEq(#rims, 2)
    H.assertEq(rims[1].text, "GPS_BORDER_QUEST")
    H.assertTrue(rims[1].picked and not rims[2].picked, "the paper by default on a plain theme")
    db.gpsPopoutBorder = false
    H.assertTrue(GPS.StyleMenu(border).rows()[#style].submenu[2].picked, "an older border-off reads as the line")
    db.gpsPopoutBorder = nil
    palette.chrome = "classic"
    style = GPS.StyleMenu(border).rows()
    rims = style[#style].submenu
    H.assertEq(#rims, 3)
    H.assertEq(rims[1].text, "GPS_BORDER_IRON")
    H.assertTrue(rims[1].picked and not rims[2].picked, "the theme's own rim until one is picked")
    rims[2].onClick()
    H.assertEq(db.gpsPopoutRim, "quest")
    H.assertTrue(GPS.StyleMenu(border).rows()[#style].submenu[2].picked, "listed anew, the quest rim is picked")
    rims = GPS.StyleMenu(border).rows()[#style].submenu
    rims[3].onClick()
    H.assertEq(db.gpsPopoutRim, "line")
    palette.chrome = nil
    H.assertTrue(GPS.StyleMenu(border).rows()[#style].submenu[2].picked, "the line holds on a plain theme")
    db.gpsPopoutRim = "iron"
    H.assertTrue(GPS.StyleMenu(border).rows()[#style].submenu[1].picked, "iron on a plain theme reads as the paper")
end

-- A step's right-click: restarting the route there comes first.
function tests.stepMenu_opensWithRestartFromThisStep()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function GPS.ShowStepMenu(container, index)", 1, true), "GPS.ShowStepMenu not in GPS.lua")
    local _, e = src:find("\nend\r?\n", s)
    local jumped, dropped
    local GPS = { GoToStep = function(i) jumped = i end }
    function GPS:ReportRoute() end
    function GPS:DropLearn(id) dropped = id end
    local route = { steps = { {}, {}, { kind = "travel" }, { kind = "learn", nodeID = 77 } } }
    local env = setmetatable({ GPS = GPS, L = setmetatable({}, { __index = function(_, k) return k end }),
        Route = function() return route end }, { __index = _G })
    assert(load(src:sub(s, e), "=GPS.lua ShowStepMenu", "t", env))()
    local shown
    GPS.ShowStepMenu({ ShowMenu = function(defs) shown = defs end }, 3)
    H.assertEq(shown[1].label, "GPS_RESTART_FROM_STEP", "the top entry")
    H.assertEq(shown[2].label, "GPS_FEEDBACK_STEP", "a planned step cannot be removed")
    shown[1].onClick()
    H.assertEq(jumped, 3, "the route restarts at that step")
    -- A stop taken up from a suggestion offers to go again.
    GPS.ShowStepMenu({ ShowMenu = function(defs) shown = defs end }, 4)
    H.assertEq(shown[2].label, "GPS_REMOVE_STEP")
    shown[2].onClick()
    H.assertEq(dropped, 77, "dropped by its flight master")
end

-- GPS:OpenWindow to GPS:CloseWindow cut from GPS.lua over a stub section
-- and window: what shows, and what the saved state says.
local function Windows(db)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function GPS:OpenWindow()", 1, true), "GPS:OpenWindow not in GPS.lua")
    local c2 = assert(src:find("function GPS:CloseWindow()", s, true), "GPS:CloseWindow not after it")
    local _, e = src:find("\nend\r?\n", c2)
    local c = {}
    local dock = { shown = false }
    function dock:IsShown() return self.shown end
    local window = { shown = false }
    local GPS = {}
    function GPS:Dock()
        db.gpsDocked = true
        dock.docked, dock.shown = true, true
        return true
    end
    function GPS:Undock()
        db.gpsDocked = nil
        dock.docked, dock.shown = nil, false
    end
    function GPS:IsWindowOpen() return dock.shown or window.shown end
    -- As GPS:TogglePopout: showing the window leaves the tracker.
    function GPS:TogglePopout(show)
        if show and db.gpsDocked then self:Undock() end
        window.shown = show
        c.popoutOpen = show or nil
    end
    local env = setmetatable({
        GPS = GPS, DB = function() return db end, CharDB = function() return c end, dockFrame = dock,
    }, { __index = _G })
    assert(load(src:sub(s, e), "=GPS.lua OpenWindow", "t", env))()
    return GPS, dock, window, c
end

function tests.closedSnappedInOpensSnappedIn()
    local db = { gpsDocked = true }
    local GPS, dock, window, c = Windows(db)
    GPS:OpenWindow()
    H.assertTrue(dock.shown and not window.shown, "snapped in")
    GPS:CloseWindow()
    H.assertFalse(dock.shown)
    H.assertTrue(db.gpsDocked, "remembered as snapped in")
    H.assertEq(c.popoutOpen, false, "closed")
    GPS:OpenWindow()
    H.assertTrue(dock.shown and not window.shown, "snapped back in")
end

function tests.closedWindowOpensAsTheWindow()
    local db = {}
    local GPS, dock, window = Windows(db)
    GPS:OpenWindow()
    H.assertTrue(window.shown and not dock.shown)
    GPS:CloseWindow()
    H.assertFalse(window.shown)
    GPS:OpenWindow()
    H.assertTrue(window.shown and not dock.shown, "the window again")
end

-- A route from a search row: snapped in, it stays in the tracker.
function tests.routeFromARowKeepsItSnappedIn()
    local db = { gpsDocked = true }
    local GPS, dock, window = Windows(db)
    GPS:OpenWindow()
    GPS:ShowWindow()
    H.assertTrue(dock.shown and db.gpsDocked and not window.shown, "still snapped in")
    GPS:CloseWindow()
    GPS:ShowWindow()
    H.assertTrue(dock.shown and not window.shown, "closed, it opens snapped in")
end

function tests.routeFromARowKeepsTheWindow()
    local db = {}
    local GPS, dock, window = Windows(db)
    GPS:ShowWindow()
    H.assertTrue(window.shown and not dock.shown, "the window")
end

function tests.snappingOffOpensTheWindow()
    local db = { gpsDocked = true, gpsNeverDock = true }
    local GPS, dock, window = Windows(db)
    GPS:OpenWindow()
    H.assertTrue(window.shown and not dock.shown)
end

local pass, fail, failures = H.runSuite("GPSDock", tests)
return { pass = pass, fail = fail, failures = failures }

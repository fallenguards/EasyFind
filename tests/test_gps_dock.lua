-- Tests for the GPS section snapped into the tracker (Apps/GPS/GPS.lua
-- PlaceDock): it hangs in its slot, and goes back there after something
-- else anchored it.

local H = require("Harness")

local function Frame(height)
    local f = { points = {} }
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
    local tracker = Frame(400)
    function tracker:IsCollapsed() return false end
    local quests = Frame(200)
    quests.leftMargin, quests.width = 12, 248
    tracker.modules = { quests }
    local dock = Frame(40)
    dock.docked = true
    local env = setmetatable({
        dockFrame = dock,
        SectionLook = function() return dock.look end,
        Host = function() return "game" end,
        Watch = function() return nil end,
        Tracker = function() return tracker end,
        ApplyInsert = function() return nil, quests, { pad = 0 } end,
        VisibleModules = function() return { quests } end,
        DB = function() return {} end,
        DockMouse = function() end,
        Refresh = function() end,
        topPad = { seen = 0 },
        DOCK_HEADER_H = 25,
    }, { __index = _G })
    return assert(load(src:sub(s, e - 1) .. "\nreturn PlaceDock", "=GPS.lua PlaceDock", "t", env))(), dock, tracker
end

local tests = {}

function tests.hangsInItsSlot()
    local PlaceDock, dock, tracker = Load()
    PlaceDock()
    local p, rel = dock:GetPoint(1)
    H.assertEq(p, "TOP")
    H.assertEq(rel, tracker)
    H.assertEq(dock.width, 248, "a section's width")
end

-- Dragged out and dropped back in the same slot: the drag's ghost hung it
-- on the window, and the same place must not leave it there.
function tests.backInItsSlotAfterADrag()
    local PlaceDock, dock, tracker = Load()
    PlaceDock()
    local window = Frame(80)
    dock:ClearAllPoints()
    dock:SetPoint("TOPLEFT", window, "TOPLEFT", 0, 0)
    PlaceDock()
    local _, rel = dock:GetPoint(1)
    H.assertEq(rel, tracker, "back on the tracker, not on the window")
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
        StyleMenu = function() return { kind = "submenu", label = "GPS_STYLE", rows = {} } end,
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
        "GPS_WORLD_PIN", "GPS_SNAP_TRACKER", "GPS_AUTO_LEARN", "GPS_LAUNCH_WINDOW" }
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
    for _, label in ipairs({ "GPS_STYLE", "GPS_SIZE_WIDTH", "GPS_SIZE_HEIGHT" }) do
        H.assertTrue(flyouts[label] ~= nil, label .. " is a flyout")
    end
    local width, height = flyouts.GPS_SIZE_WIDTH.rows, flyouts.GPS_SIZE_HEIGHT.rows
    H.assertEq(#width, 2)
    H.assertTrue(width[2].picked and not width[1].picked, "the width in use is picked")
    H.assertTrue(height[1].picked and not height[2].picked, "fit to steps, as no height is set")
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

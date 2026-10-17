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
-- left click swallows the right one: each takes it and opens the menu.
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
        H.assertTrue(body:find("ShowMenu", 1, true) ~= nil or body:find("ShowDockMenu", 1, true) ~= nil,
            b[1] .. ": no menu")
    end
end

local pass, fail, failures = H.runSuite("GPSDock", tests)
return { pass = pass, fail = fail, failures = failures }

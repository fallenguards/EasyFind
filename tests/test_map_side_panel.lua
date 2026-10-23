-- The classic map's side panel (MapSearch/MapTab.lua SidePanel): Era's,
-- Anniversary's and MoP Classic's map has no quest panel beside it, so the
-- windowed map grows one in its own border art, opened from a toggle in its
-- corner. It opens on the windowed map only, moves the client's close
-- button to the new end and back, and a retail map builds none.
local H = require("Harness")

local function Region(name, kind)
    local r = { name = name, kind = kind or "frame", shown = true, points = {} }
    function r:Show() self.shown = true end
    function r:Hide() self.shown = false end
    function r:SetShown(v) self.shown = v and true or false end
    function r:IsShown() return self.shown end
    function r:SetPoint(point, rel, relPoint, x, y)
        if type(rel) ~= "table" then rel, relPoint, x, y = nil, point, rel, relPoint end
        self.points[point] = { point, rel, relPoint, x or 0, y or 0 }
        self.lastPoint = point
    end
    function r:GetPoint()
        local p = self.points[self.lastPoint]
        return p[1], p[2], p[3], p[4] + (rawget(self, "noise") or 0), p[5]
    end
    function r:SetSize(w, h) self.w, self.h = w, h end
    function r:SetTexCoord(...) self.coords = { ... } end
    function r:GetFrameLevel() return 1 end
    function r:CreateTexture() return Region("texture", "texture") end
    function r:GetNormalTexture() return Region("normal") end
    function r:GetPushedTexture() return Region("pushed") end
    function r:SetScript(k, fn) self[k] = fn end
    return setmetatable(r, { __index = function() return function() end end })
end

local function Load(classicMap)
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/MapTab.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local s = assert(src:find("-- Classic's windowed map grows a side panel", 1, true), "the side panel block")
    local e = assert(src:find("-- Sibling content panel:", s, true), "end of the side panel block")
    local right = classicMap and Region("MiniBorderRight", "texture") or nil
    local close = Region("close")
    close:SetPoint("TOPRIGHT", right, "TOPRIGHT", -44, 5)
    local wmf = Region("WorldMapFrame")
    wmf.MiniBorderFrame = Region("MiniBorderFrame")
    wmf.ScrollContainer = Region("ScrollContainer")
    wmf.maximized = false
    function wmf:IsMaximized() return self.maximized end
    local hidden = 0
    local env = {
        SidePanel = {}, WorldMapFrame = wmf, MiniBorderRight = right, WorldMapFrameCloseButton = close,
        CreateFrame = function(_, name) return Region(name) end,
        ns = { GPS_ICON_TEX = "pin" }, Utils = { RGB = function(c) return c[1], c[2], c[3] end },
        TAB_ICON_GOLD = { 1, 0.82, 0 }, L = setmetatable({}, { __index = function(_, k) return k end }),
        EasyFind = { db = {} }, IsMapSearchEnabled = function() return true end,
        HideOurPanel = function() hidden = hidden + 1 end, ShowOurPanel = function() end,
        hooksecurefunc = function() end, unpack = table.unpack or unpack,
        SQUARE_BUTTON_TEXCOORDS = { LEFT = { 1, 2, 3, 4 }, RIGHT = { 2, 1, 3, 4 } },
    }
    env._G = env
    setmetatable(env, { __index = _G })
    assert(load(src:sub(s, e - 1), "=MapTab.lua SidePanel", "t", env))()
    return env.SidePanel, env, wmf, right, close, function() return hidden end
end

local tests = {}

function tests.aRetailMapBuildsNone()
    local SidePanel = Load(false)
    H.assertNil(SidePanel.Build(), "no windowed border art: the quest panel hosts the tab")
end

function tests.opensBesideTheWindowedMapAndMovesTheCloseButton()
    local SidePanel, env, _, right, close = Load(true)
    local host = SidePanel.Build()
    H.assertNotNil(host and host.ContentsAnchor, "the panel's contents")
    H.assertTrue(SidePanel.Expand(), "windowed: it opens")
    H.assertTrue(host:IsShown())
    H.assertFalse(right:IsShown(), "the map's right end gives way to the panel's")
    local _, rel, _, x, y = close:GetPoint()
    H.assertEq(rel, right)
    H.assertEq(x, -44 + SidePanel.W, "the close button at the new end")
    H.assertEq(y, 5)
    H.assertTrue(env.EasyFind.db.mapSidePanelOpen, "left open, it opens next time")
    H.assertDeepEq(SidePanel.arrow.coords, { 1, 2, 3, 4 }, "the arrow points back")

    SidePanel.PlaceClose()
    _, _, _, x = close:GetPoint()
    H.assertEq(x, -44 + SidePanel.W, "placed once, not again")

    SidePanel.Collapse()
    H.assertFalse(host:IsShown())
    H.assertTrue(right:IsShown())
    _, rel, _, x = close:GetPoint()
    H.assertEq(rel, right)
    H.assertEq(x, -44, "the close button back where the client put it")
    H.assertDeepEq(SidePanel.arrow.coords, { 2, 1, 3, 4 })
end

-- The GPS page's cast buttons are secure, and the client refuses to place
-- one through a texture: the page stopped at its first teleport step.
function tests.theContentsHangFromFramesOnly()
    local SidePanel = Load(true)
    local host = SidePanel.Build()
    for point, p in pairs(host.ContentsAnchor.points) do
        H.assertTrue(p[2] ~= nil and p[2].kind == "frame", point .. " hangs from a frame")
    end
end

function tests.theFullScreenMapHasNoRoom()
    local SidePanel, _, wmf, _, close, hidden = Load(true)
    local host = SidePanel.Build()
    SidePanel.Expand()
    -- The client maximizes: it places the close button on its own border.
    wmf.maximized = true
    local border = {}
    close:SetPoint("TOPRIGHT", border, "TOPRIGHT", 5, 4)
    SidePanel.ClientPlacedClose()
    SidePanel.Sync()
    H.assertFalse(SidePanel.toggle:IsShown(), "no toggle on the full-screen map")
    H.assertFalse(host:IsShown())
    H.assertEq(hidden(), 1, "the panel let go")
    local _, rel, _, x = close:GetPoint()
    H.assertEq(rel, border, "the client's placement kept")
    H.assertEq(x, 5)
    H.assertFalse(SidePanel.Expand(), "it does not open there")

    wmf.maximized = false
    SidePanel.Sync()
    H.assertTrue(SidePanel.toggle:IsShown(), "windowed again: the toggle")
end

-- The client reads a point back a hair off what was set: the button
-- must come back each time, not move a panel's width further per open.
function tests.everyCloseComesBackWhereTheClientPutIt()
    local SidePanel, _, _, _, close = Load(true)
    SidePanel.Build()
    close.noise = 0.0001
    for i = 1, 3 do
        SidePanel.Expand()
        H.assertTrue(math.abs(close.points.TOPRIGHT[4] - (SidePanel.W - 44)) < 0.01, "open " .. i)
        SidePanel.Collapse()
        H.assertTrue(math.abs(close.points.TOPRIGHT[4] + 44) < 0.01, "closed " .. i)
    end
end

function tests.theArtSlicesJoin()
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/MapTab.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local W, BARS_U, EDGE_U, CAP_U = src:match("local W, BARS_U, EDGE_U, CAP_U = (%d+), (%d+), (%d+), (%d+)")
    W, BARS_U, EDGE_U, CAP_U = tonumber(W), tonumber(BARS_U), tonumber(EDGE_U), tonumber(CAP_U)
    H.assertNotNil(W, "the art numbers")
    -- The bars come from inside the left piece, clear of its left edge (to 12).
    H.assertTrue(BARS_U > 12 and BARS_U + CAP_U + W <= 512, "the bars' slice within the left piece")
    H.assertTrue(CAP_U < EDGE_U, "the end cap holds the right edge")
end

local pass, fail, failures = H.runSuite("MapSidePanel", tests)
return { pass = pass, fail = fail, failures = failures }

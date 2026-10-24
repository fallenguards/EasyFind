-- The 1.x iron divider (Shared/Utils.lua CreateIronLine): under the Classic
-- theme one line parts the tutorial's footer and the settings sidebar from
-- the page, where a whole iron frame went round them. Its caps keep their
-- size at any length; the vertical one turns the art down a side.
local H = require("Harness")

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end

local function Frame()
    local f = { textures = {} }
    function f:CreateTexture()
        local t = { points = {} }
        function t:SetTexCoord(...) self.coords = { ... } end
        function t:SetTexture(p) self.file = p end
        function t:SetWidth(w) self.w = w end
        function t:SetHeight(h) self.h = h end
        function t:SetPoint(...) self.points[#self.points + 1] = { ... } end
        f.textures[#f.textures + 1] = t
        return t
    end
    function f:SetWidth(w) self.w = w end
    function f:SetHeight(h) self.h = h end
    return f
end

local env = H.newEnv()
local ns = H.newNs(env)
env.CreateFrame = function() return env.frameNext and Frame() or fakeWidget() end
env.CreateFont = fakeWidget
env.CreateColor = function(r, g, b, a) return { r, g, b, a } end
env.UIParent, env.WorldFrame, env.GameTooltip = fakeWidget(), fakeWidget(), fakeWidget()
env.hooksecurefunc = function() end
env.GameFontNormal = setmetatable({}, { __index = function(_, k)
    if k == "GetFont" then return function() return "font", 12, "" end end
    return function() end
end })
H.loadModule("Shared/Utils.lua", env, ns)
env.frameNext = true

local tests = {}

function tests.acrossCapsFixedMiddleStretched()
    local line = ns.CreateIronLine(Frame(), false)
    local l, m, r = line.textures[1], line.textures[2], line.textures[3]
    H.assertEq(line.h, 16, "the art's band")
    H.assertEq(l.w, 6)
    H.assertEq(r.w, 6)
    H.assertNil(m.w, "the middle takes what is left")
    H.assertEq(#l.coords, 4, "plain crop")
    H.assertTrue(l.file:find("UI%-DialogBox%-Divider") ~= nil)
end

function tests.downASideTheArtTurns()
    local line = ns.CreateIronLine(Frame(), true)
    local top, mid = line.textures[1], line.textures[2]
    H.assertEq(line.w, 16)
    H.assertEq(top.h, 6, "the cap at the top")
    H.assertEq(#mid.coords, 8, "corner by corner: the length runs down")
    -- Top left and top right share the art's start; the bottom its end.
    H.assertEq(mid.coords[1], mid.coords[5])
    H.assertEq(mid.coords[3], mid.coords[7])
    H.assertTrue(mid.coords[3] > mid.coords[1])
end

local pass, fail, failures = H.runSuite("IronLine", tests)
return { pass = pass, fail = fail, failures = failures }

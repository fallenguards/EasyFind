-- The Chevrons indicator style (MapSearch/Indicators.lua): the old tutorial
-- pointer, two chevrons sliding toward the target and fading late, in the
-- indicator's place on every indicator. The frame's own bounce stays still
-- under them, and the arrow comes back when another style is picked.
local H = require("Harness")

local function Region(parent)
    local r = { parent = parent, shown = true, scripts = {}, alpha = 1 }
    function r:GetParent() return self.parent end
    function r:Show() self.shown = true end
    function r:Hide() self.shown = false end
    function r:IsShown() return self.shown end
    function r:SetPoint(_, _, _, x, y) self.x, self.y = x, y end
    function r:SetAlpha(a) self.alpha = a end
    function r:SetRotation(rad) self.rot = rad end
    function r:SetVertexColor(...) self.color = { ... } end
    function r:GetWidth() return 48 end
    function r:GetSize() return 48, 48 end
    function r:SetScript(k, fn) self.scripts[k] = fn end
    function r:HookScript(k, fn) self.scripts[k] = fn end
    function r:CreateTexture() return Region(self) end
    return setmetatable(r, { __index = function(_, k)
        if type(k) == "string" and k:match("^%u") then return function() end end
    end })
end

local function Load(style)
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    ns.Caps = { classic = false }
    env.EasyFind = { db = { indicatorStyle = style, indicatorColor = "Gold" } }
    env.CreateFrame = function(_, _, parent) return Region(parent) end
    H.loadModule("MapSearch/Indicators.lua", env, ns)
    local host = Region(nil)
    local playing = true
    host.animGroup = { IsPlaying = function() return playing end, Stop = function() playing = false end }
    ns.CreateIndicatorTextures(host, 48, 68)
    ns.UpdateIndicator(host)
    return ns, host, env.EasyFind.db, function() return playing end
end

local tests = {}

function tests.chevronsTakeTheArrowsPlace()
    local _, host = Load("Chevrons")
    H.assertFalse(host.indicator:IsShown(), "the arrow gives way")
    H.assertFalse(host.glow:IsShown())
    H.assertTrue(host.chevrons and host.chevrons:IsShown(), "the chevrons")
    H.assertEq(#host.chevrons.pairs, 2)
end

function tests.theySlideTowardTheTargetAndFadeLate()
    local _, host, _, playing = Load("Chevrons")
    local tick = host.chevrons.scripts.OnUpdate
    tick(host.chevrons, 0)
    H.assertFalse(playing(), "the frame's bounce stopped under them")
    local first = host.chevrons.pairs[1][1]
    H.assertEq(first.rot, 0, "pointing down")
    local y0 = first.y
    tick(host.chevrons, 0.5)
    H.assertTrue(first.y < y0, "moving down, toward the target")
    H.assertEq(first.x, 0)
    H.assertEq(first.alpha, 1, "bright for most of the way")
    tick(host.chevrons, 0.6)
    H.assertTrue(first.alpha < 0.5, "fading at the end")
    H.assertTrue(math.abs(host.chevrons.pairs[2][2].alpha - 0.7) < 1e-6, "the other's glow, half a cycle behind")
end

function tests.aSidewaysIndicatorSlidesSideways()
    local _, host = Load("Chevrons")
    host.indicatorDirection = "left"
    local tick = host.chevrons.scripts.OnUpdate
    tick(host.chevrons, 0)
    local first = host.chevrons.pairs[1][1]
    local x0 = first.x
    tick(host.chevrons, 0.5)
    H.assertTrue(first.x < x0, "moving left")
    H.assertEq(first.y, 0)
end

function tests.anotherStyleBringsTheArrowBack()
    local ns, host, db = Load("Chevrons")
    db.indicatorStyle = "EasyFind Arrow"
    ns.UpdateIndicator(host)
    H.assertTrue(host.indicator:IsShown())
    H.assertTrue(host.glow:IsShown())
    H.assertFalse(host.chevrons:IsShown())
end

function tests.theArrowStylesBuildNoChevrons()
    local _, host = Load("EasyFind Arrow")
    H.assertNil(host.chevrons)
    H.assertTrue(host.indicator:IsShown())
end

local pass, fail, failures = H.runSuite("IndicatorChevrons", tests)
return { pass = pass, fail = fail, failures = failures }

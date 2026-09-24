-- Tests for the Forever skin (Shared/Utils.lua): a surface that opts in
-- wears the client's "Dialog" border over the quest log background while
-- the Forever palette is active, remembers the panel and ring requests the
-- rounded helpers made meanwhile, and hands back its rounded pieces when
-- another palette returns. Loads the REAL Shared/Utils.lua.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end

-- A region or frame that keeps the state the skin touches.
local function newRegion(w, h)
    local r = { shown = true, scale = 1, level = 1, w = w or 100, h = h or 30, hooks = {}, coords = nil }
    function r:Show() self.shown = true end
    function r:Hide() self.shown = false end
    function r:SetShown(v) self.shown = v and true or false end
    function r:IsShown() return self.shown end
    function r:SetScale(s) self.scale = s end
    function r:SetFrameLevel(l) self.level = l end
    function r:GetFrameLevel() return self.level end
    function r:GetWidth() return self.w end
    function r:GetHeight() return self.h end
    function r:SetTexCoord(...) self.coords = { ... } end
    function r:SetTexture(t) self.tex = t return true end
    function r:SetColorTexture(...) self.color = { ... } end
    function r:SetAlpha(a) self.alpha = a end
    function r:HookScript(name, fn) self.hooks[name] = fn end
    function r:CreateTexture() return newRegion() end
    function r:CreateMaskTexture() return newRegion() end
    function r:ClearAllPoints() self.points = {} end
    function r:SetPoint(...) self.points = self.points or {}; self.points[#self.points + 1] = { ... } end
    -- Unknown methods are no-ops; unknown fields stay nil.
    setmetatable(r, { __index = function(_, k)
        if type(k) == "string" and k:match("^%u") then return function() end end
    end })
    return r
end

local factory = fakeWidget
env.CreateFrame = function(...) return factory(...) end
env.CreateFont = fakeWidget
env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
env.UIParent = fakeWidget()
env.WorldFrame = fakeWidget()
env.GameTooltip = fakeWidget()
env.hooksecurefunc = function() end
env.GameFontNormal = setmetatable({}, { __index = function(_, k)
    if k == "GetFont" then return function() return "font", 12, "" end end
    return function() end
end })

H.loadModule("Shared/Utils.lua", env, ns)

local ATLAS = { file = 5684755, width = 307, height = 510,
                leftTexCoord = 0.3, rightTexCoord = 0.6, topTexCoord = 0.0, bottomTexCoord = 1.0 }
local applied
local function installClient(withLayout)
    applied = {}
    env.NineSliceUtil = withLayout and {
        GetLayout = function(name) return name == "Dialog" and {} or nil end,
        ApplyLayoutByName = function(frame, name) applied[#applied + 1] = { frame = frame, name = name } end,
    } or nil
    env.C_Texture = { GetAtlasInfo = function(name) return name == "QuestLog-main-background" and ATLAS or nil end }
end

local FOREVER = { chrome = "forever", fillAtlas = "QuestLog-main-background", windowFill = { 0.1, 0.1, 0.1 } }
local PLAIN = { windowFill = { 0.1, 0.1, 0.1 } }

local function surface(optIn, w, h)
    factory = function() return newRegion() end
    local f = newRegion(w or 400, h or 30)
    ns.CreateRoundedRectBorder(f)
    ns.CreateRoundedRectDivider(f)
    ns.SetRoundedRectBarHeight(f, 30)
    f._efForeverSurface = optIn or nil
    return f
end

local function roundedShown(f, part)
    for _, t in pairs(f.combinedBorder[part]) do
        if t.shown then return true end
    end
    return false
end

local tests = {}

function tests.optedInSurface_wearsTheDialogBorderOverTheQuestLog()
    installClient(true)
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(true)
    ns.ApplyThemeFill(f)
    H.assertTrue(f._efForeverOn, "the skin is on")
    H.assertEq(applied[1].name, "Dialog", "the game menu's layout, by name")
    H.assertTrue(f._efForever.border.shown and f._efForever.fill.shown)
    H.assertEq(f._efForever.fill.tex, ATLAS.file)
    H.assertTrue(not roundedShown(f, "fill") and not roundedShown(f, "border"), "rounded pieces step aside")
    H.assertTrue(math.abs(f._efForever.border.scale - 30 / 96) < 1e-6, "corners meet on a bar-high window")
end

function tests.fill_isFittedToWidthAndCroppedFromTop()
    installClient(true)
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(true, 307, 51)
    ns.ApplyThemeFill(f)
    local c = f._efForever.fill.coords
    H.assertTrue(math.abs(c[1] - 0.3) < 1e-6 and math.abs(c[2] - 0.6) < 1e-6, "full width of the atlas")
    H.assertTrue(math.abs(c[3]) < 1e-6 and math.abs(c[4] - 0.1) < 1e-6, "the top tenth: " .. tostring(c[4]))
end

function tests.ringAndPanelRequests_areKeptWhileOn()
    installClient(true)
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(true)
    ns.ApplyThemeFill(f)
    ns.SetRoundedRectRingShown(f, false)
    H.assertTrue(not f._efForever.border.shown and f._efForever.fill.shown, "border off, fill stays")
    H.assertTrue(not roundedShown(f, "border"), "the rounded ring stays hidden")
    ns.SetRoundedRectBorderShown(f, false)
    H.assertTrue(not f._efForever.fill.shown, "panel off hides the fill")
    ns.SetRoundedRectBorderShown(f, true)
    H.assertTrue(f._efForever.fill.shown and f._efForever.border.shown)
    ns.SetRoundedRectRingShown(f, false)
    ns.ACTIVE_UI_PALETTE = PLAIN
    ns.ApplyThemeFill(f)
    H.assertTrue(not f._efForeverOn and not f._efForever.fill.shown and not f._efForever.border.shown, "skin off")
    H.assertTrue(roundedShown(f, "fill") and not roundedShown(f, "border"), "rounded back, ring still off")
end

function tests.surfaceNotOptedIn_keepsTheRoundedLook()
    installClient(true)
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(false)
    ns.ApplyThemeFill(f)
    H.assertTrue(not f._efForeverOn and f._efForever == nil)
    H.assertTrue(f._efArtCells and f._efArtCells.mm.shown, "the quest log art fills the rounded window")
    H.assertEq(f._efArtCells.mm.tex, ATLAS.file)
end

function tests.clientWithoutTheLayout_fallsBackToRounded()
    installClient(false)
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(true)
    ns.ApplyThemeFill(f)
    H.assertTrue(not f._efForeverOn, "no layout, no skin")
    H.assertTrue(roundedShown(f, "fill"), "the rounded panel is there")
end

function tests.divider_isThinBronzeWhileOn()
    installClient(true)
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(true)
    ns.ApplyThemeFill(f)
    ns.SetRoundedRectDivider(f, 30, true)
    H.assertEq(f.combinedDivider.color[1], ns.FOREVER_BRONZE[1])
    H.assertEq(f.combinedDivider.points[1][4], 2, "band to band")
    ns.ACTIVE_UI_PALETTE = PLAIN
    ns.ApplyThemeFill(f)
    ns.SetRoundedRectDivider(f, 30, true)
    H.assertTrue(f.combinedDivider.color[1] ~= ns.FOREVER_BRONZE[1], "the plain divider returns")
end

local pass, fail, failures = H.runSuite("ForeverChrome", tests)
return { pass = pass, fail = fail, failures = failures }

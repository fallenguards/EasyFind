-- Tests for the Forever skin (Shared/Utils.lua): a surface that opts in
-- wears the spellbook frame's bronze border, cut from the client's own
-- UI-Frame-Metal atlases, over the quest log background while the Forever
-- palette is active; keeps the panel and ring requests the rounded helpers
-- made meanwhile; and hands back its rounded pieces when another palette
-- returns or the client serves other art. Loads the REAL Shared/Utils.lua.

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
    local r = { shown = true, level = 1, w = w or 100, h = h or 30, hooks = {}, coords = nil }
    function r:Show() self.shown = true end
    function r:Hide() self.shown = false end
    function r:SetShown(v) self.shown = v and true or false end
    function r:IsShown() return self.shown end
    function r:SetFrameLevel(l) self.level = l end
    function r:GetFrameLevel() return self.level end
    function r:GetWidth() return self.w end
    function r:GetHeight() return self.h end
    function r:SetWidth(v) self.w = v end
    function r:SetHeight(v) self.h = v end
    function r:SetSize(a, b) self.w, self.h = a, b end
    function r:GetEffectiveScale() return 1 end
    function r:SetTexCoord(...) self.coords = { ... } end
    function r:SetTexture(t, wh, wv) self.tex, self.wrapH, self.wrapV = t, wh, wv return true end
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

local FILL = { file = 5684755, width = 307, height = 510,
               leftTexCoord = 0.3, rightTexCoord = 0.6, topTexCoord = 0.0, bottomTexCoord = 1.0 }
local function info(file, w, h)
    return { file = file, width = w, height = h, leftTexCoord = 0, rightTexCoord = 1, topTexCoord = 0, bottomTexCoord = 1 }
end
-- Forever's spellbook art: bands wider than tall.
local FOREVER_ART = {
    ["UI-Frame-Metal-CornerTopLeft"] = info(1, 95, 95), ["UI-Frame-Metal-CornerTopRight"] = info(2, 95, 95),
    ["UI-Frame-Metal-CornerBottomLeft"] = info(3, 95, 100), ["UI-Frame-Metal-CornerBottomRight"] = info(4, 95, 100),
    ["_UI-Frame-Metal-EdgeTop"] = info(5, 128, 95), ["_UI-Frame-Metal-EdgeBottom"] = info(6, 128, 100),
    ["!UI-Frame-Metal-EdgeLeft"] = info(7, 95, 128), ["!UI-Frame-Metal-EdgeRight"] = info(8, 95, 128),
}
local served
local function installClient(art)
    served = art
    env.C_Texture = { GetAtlasInfo = function(name)
        if name == "QuestLog-main-background" then return FILL end
        return served and served[name]
    end }
end
local OTHER_ART = {}
for k, v in pairs(FOREVER_ART) do OTHER_ART[k] = v end
OTHER_ART["_UI-Frame-Metal-EdgeBottom"] = info(6, 16, 32)

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

local function near(a, b) return math.abs(a - b) < 1e-6 end

local tests = {}

function tests.optedInSurface_wearsTheSpellbookBorderOverTheQuestLog()
    installClient(FOREVER_ART)
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(true)
    ns.ApplyThemeFill(f)
    H.assertTrue(f._efForeverOn, "the skin is on")
    local p = f._efForever.pieces
    H.assertEq(p.bl.tex, 3, "the bottom-left corner is the client's own atlas")
    H.assertTrue(near(p.bl.coords[1], 20 / 190) and near(p.bl.coords[4], 197 / 200), "cropped to the chamfer")
    H.assertTrue(near(p.tl.coords[4], 38 / 190), "the top pieces stop above the title strip")
    H.assertEq(p.top.wrapH, "REPEAT", "the band tiles along its length")
    H.assertTrue(f._efForever.border.shown and f._efForever.fill.shown)
    H.assertEq(f._efForever.fill.tex, FILL.file)
    H.assertTrue(not roundedShown(f, "fill") and not roundedShown(f, "border"), "rounded pieces step aside")
end

function tests.fill_runsUnderTheMetal()
    installClient(FOREVER_ART)
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(true)
    ns.ApplyThemeFill(f)
    local pts = f._efForever.fill.points
    H.assertEq(pts[1][4], 1.5, "1.5 units in: under the band's inner half")
    H.assertEq(pts[2][4], -1.5)
    H.assertEq(f._efForever.pieces.tl.points[1][4], -5, "the band's middle sits on the window edge")
end

function tests.fill_isFittedToWidthAndCroppedFromTop()
    installClient(FOREVER_ART)
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(true, 310, 54)
    ns.ApplyThemeFill(f)
    local c = f._efForever.fill.coords
    H.assertTrue(near(c[1], 0.3) and near(c[2], 0.6), "full width of the atlas")
    H.assertTrue(near(c[3], 0) and near(c[4], 51 / 510), "the top slice: " .. tostring(c[4]))
end

function tests.ringAndPanelRequests_areKeptWhileOn()
    installClient(FOREVER_ART)
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
    installClient(FOREVER_ART)
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(false)
    ns.ApplyThemeFill(f)
    H.assertTrue(not f._efForeverOn and f._efForever == nil)
    H.assertTrue(f._efArtCells and f._efArtCells.mm.shown, "the quest log art fills the rounded window")
    H.assertEq(f._efArtCells.mm.tex, FILL.file)
end

function tests.otherClientsArt_fallsBackToRounded()
    installClient(OTHER_ART)
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(true)
    ns.ApplyThemeFill(f)
    H.assertTrue(not f._efForeverOn, "not Forever's art, no skin")
    H.assertTrue(roundedShown(f, "fill"), "the rounded panel is there")
    installClient(nil)
    local g = surface(true)
    ns.ApplyThemeFill(g)
    H.assertTrue(not g._efForeverOn, "no art at all, no skin")
end

function tests.divider_isOneScreenPixelOfBronze()
    installClient(FOREVER_ART)
    env.GetPhysicalScreenSize = function() return 2560, 1440 end
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(true)
    ns.ApplyThemeFill(f)
    ns.SetRoundedRectDivider(f, 30, true)
    local d = f.combinedDivider
    H.assertEq(d.color[1], ns.FOREVER_BRONZE[1])
    H.assertTrue(near(d.h, 768 / 1440), "one physical pixel: " .. tostring(d.h))
    H.assertEq(d.points[1][4], 2, "band to band")
    ns.ACTIVE_UI_PALETTE = PLAIN
    ns.ApplyThemeFill(f)
    ns.SetRoundedRectDivider(f, 30, true)
    H.assertTrue(d.color[1] ~= ns.FOREVER_BRONZE[1] and d.h == 1, "the plain divider returns")
end

function tests.glyphBlend_isNormalForFlatGlyphThemes()
    H.assertEq(ns.ChromeGlyphBlend({ flatGlyphs = true }), "BLEND")
    H.assertEq(ns.ChromeGlyphBlend({ lightTheme = true }), "BLEND")
    H.assertEq(ns.ChromeGlyphBlend({}), "ADD")
end

local pass, fail, failures = H.runSuite("ForeverChrome", tests)
return { pass = pass, fail = fail, failures = failures }

-- Tests for the frame-art skins (Shared/Utils.lua, ns.ApplySkin): while the
-- window border option is on, a surface that opts in wears the Forever
-- spellbook border over the quest log background, or the Classic tooltip
-- frame; off, every surface is rounded again with the ring it last asked
-- for. Loads the REAL Shared/Utils.lua.

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
    function r:GetEffectiveScale() return self.effScale or 1 end
    function r:SetTexCoord(...) self.coords = { ... } end
    function r:SetTexture(t, wh, wv) self.tex, self.wrapH, self.wrapV = t, wh, wv return true end
    function r:SetColorTexture(...) self.color = { ... } end
    function r:SetVertexColor(...) self.vertex = { ... } end
    function r:SetBackdrop(b) self.backdrop = b end
    function r:SetBackdropColor(...) self.bdColor = { ... } end
    function r:SetBackdropBorderColor() end
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
env.UIParent = newRegion()
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
local CLASSIC = { chrome = "classic", windowFill = { 0.05, 0.05, 0.1 } }

local function borderOption(on) env.EasyFind.db.windowBorder = on end

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

-- The band off (frame art off): the line border and divider are the
-- Forever theme's bronze, the usual gray under any other theme.
function tests.bandOff_lineBorderWearsTheThemesBronze()
    installClient(FOREVER_ART)
    borderOption(true)
    env.EasyFind.db.themeFrameArt = false
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(true)
    ns.ApplyThemeFill(f)
    ns.SetRoundedRectDivider(f, 30, true)
    H.assertFalse(f._efForeverOn, "no band")
    for _, t in pairs(f.combinedBorder.border) do H.assertTrue(near(t.vertex[1], 0.78), "bronze border") end
    H.assertTrue(near(f.combinedDivider.color[1], 0.78), "bronze divider")
    ns.ACTIVE_UI_PALETTE = PLAIN
    ns.ApplyThemeFill(f)
    ns.SetRoundedRectDivider(f, 30, true)
    for _, t in pairs(f.combinedBorder.border) do H.assertTrue(near(t.vertex[1], 0.42), "gray border") end
    H.assertTrue(near(f.combinedDivider.color[1], 0.42), "gray divider")
    env.EasyFind.db.themeFrameArt = nil
end

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

-- The filter menu is zoomed 1.5x; its band is drawn at the bar's size.
function tests.zoomedMenu_wearsTheBandAtTheSpellbookSize()
    installClient(FOREVER_ART)
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(true)
    f.effScale = 1.5
    ns.ApplyThemeFill(f)
    local tl = f._efForever.pieces.tl
    H.assertTrue(near(tl.w, 30 * 0.5 / 1.5), "corner width in the menu's own units: " .. tostring(tl.w))
    H.assertTrue(near(tl.points[1][4], -10 * 0.5 / 1.5))
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

-- Option on: the filter menu, which asks for no rounded ring, still wears
-- the Forever frame the bar wears.
function tests.ringOff_keepsTheForeverBorder()
    installClient(FOREVER_ART)
    ns.ACTIVE_UI_PALETTE = PLAIN
    local f = surface(true)
    ns.SetRoundedRectRingShown(f, false)
    ns.ACTIVE_UI_PALETTE = FOREVER
    ns.ApplyThemeFill(f)
    H.assertTrue(f._efForever.border.shown and f._efForever.fill.shown, "a ring-off menu keeps the border")
end

function tests.ringAndPanelRequests_areKeptWhileOn()
    installClient(FOREVER_ART)
    ns.ACTIVE_UI_PALETTE = FOREVER
    local f = surface(true)
    ns.ApplyThemeFill(f)
    ns.SetRoundedRectRingShown(f, false)
    H.assertTrue(f._efForever.border.shown and f._efForever.fill.shown, "the Forever frame stays")
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

-- Window border off: the Forever theme is rounded everywhere, with its
-- quest log fill, and the bar and the filter menu agree on no ring.
function tests.forever_borderOff_isRoundedEverywhere()
    installClient(FOREVER_ART)
    ns.ACTIVE_UI_PALETTE = FOREVER
    borderOption(false)
    local bar, menu = surface(true), surface(true)
    ns.SetRoundedRectRingShown(bar, false)
    ns.SetRoundedRectRingShown(menu, false)
    ns.ApplyThemeFill(bar)
    ns.ApplyThemeFill(menu)
    for _, f in ipairs({ bar, menu }) do
        H.assertTrue(not f._efSkin and f._efForever == nil, "no frame art")
        H.assertTrue(f._efArtCells and f._efArtCells.mm.shown, "the quest log fill in the rounded shape")
        H.assertTrue(not roundedShown(f, "border"), "no ring, as the option asks")
    end
    borderOption(nil)
end

-- Toggling the option flips a dressed surface both ways.
function tests.forever_toggle_flipsBothWays()
    installClient(FOREVER_ART)
    ns.ACTIVE_UI_PALETTE = FOREVER
    borderOption(true)
    local menu = surface(true)
    ns.SetRoundedRectRingShown(menu, false)
    ns.ApplyThemeFill(menu)
    H.assertTrue(menu._efForever.border.shown, "on: the spellbook border, ring request aside")
    borderOption(false)
    ns.ApplyThemeFill(menu)
    H.assertTrue(not menu._efForever.border.shown and not menu._efForever.fill.shown, "off: the art is gone")
    H.assertTrue(roundedShown(menu, "fill") and not roundedShown(menu, "border"), "rounded, ring still off")
    borderOption(true)
    ns.ApplyThemeFill(menu)
    H.assertTrue(menu._efForever.border.shown and not roundedShown(menu, "fill"), "on again")
    borderOption(nil)
end

local function classicSurface()
    local f = surface(true)
    f._efClassicSurface = true
    return f
end

function tests.classic_borderOn_wearsTheTooltipFrame()
    installClient(FOREVER_ART)
    ns.ACTIVE_UI_PALETTE = CLASSIC
    borderOption(true)
    local f = classicSurface()
    ns.ApplyThemeFill(f)
    H.assertEq(f._efSkin, "classic")
    H.assertEq(f.backdrop, ns.CLASSIC_BACKDROP)
    H.assertTrue(not roundedShown(f, "fill") and not roundedShown(f, "border"), "rounded pieces step aside")
    ns.SetRoundedRectRingShown(f, true)
    H.assertTrue(not roundedShown(f, "border"), "a ring request cannot show the rounded ring over the frame")
    borderOption(nil)
end

function tests.classic_borderOff_isRounded()
    installClient(FOREVER_ART)
    ns.ACTIVE_UI_PALETTE = CLASSIC
    borderOption(true)
    local f = classicSurface()
    ns.SetRoundedRectRingShown(f, false)
    ns.ApplyThemeFill(f)
    borderOption(false)
    H.assertTrue(not ns.IsClassicChrome(), "the classic layout flags follow the option")
    ns.ApplyThemeFill(f)
    H.assertTrue(f.backdrop == nil and not f._efSkin, "the frame art is gone")
    H.assertTrue(roundedShown(f, "fill") and not roundedShown(f, "border"), "rounded, ring as asked")
    borderOption(nil)
end

function tests.classicWindow_usesTheDialogFrame()
    installClient(FOREVER_ART)
    ns.ACTIVE_UI_PALETTE = CLASSIC
    borderOption(true)
    local f = surface(false)
    H.assertTrue(ns.ApplyClassicChrome(f, 0.9, "dialog"))
    H.assertEq(f.backdrop, ns.CLASSIC_DIALOG)
    H.assertEq(f.bdColor[4], 0.9)
    borderOption(false)
    H.assertTrue(not ns.ApplyClassicChrome(f, 0.9, "dialog"), "off: the window is rounded")
    H.assertTrue(f.backdrop == nil)
    borderOption(nil)
end

function tests.switchingThemes_leavesOnlyOneSkin()
    installClient(FOREVER_ART)
    borderOption(true)
    local f = classicSurface()
    ns.ACTIVE_UI_PALETTE = CLASSIC
    ns.ApplyThemeFill(f)
    ns.ACTIVE_UI_PALETTE = FOREVER
    ns.ApplyThemeFill(f)
    H.assertTrue(f.backdrop == nil and f._efSkin == "forever", "classic frame removed for the Forever border")
    ns.ACTIVE_UI_PALETTE = CLASSIC
    ns.ApplyThemeFill(f)
    H.assertTrue(not f._efForever.border.shown and f.backdrop == ns.CLASSIC_BACKDROP, "and back")
    borderOption(nil)
end

local pass, fail, failures = H.runSuite("ForeverChrome", tests)
return { pass = pass, fail = fail, failures = failures }

-- The GPS pop-out on a light theme (2026-10-27: its text and fields were
-- the dark art's, near white on the light fill, and the quest log's dark
-- paper framed it). The pop-out's text is the theme's own dark ink there;
-- beside the map and on the dock the art stays dark, and so does the ink.
local H = require("Harness")

local function Source()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local SKY = { lightTheme = true, pathColorHover = { 0.05, 0.17, 0.36, 1 }, leafColor = { 0.10, 0.28, 0.52 },
    textFaint = { 0.24, 0.35, 0.48 }, accent = { 0.15, 0.45, 0.80, 0.85 }, chromeGlyph = { 0.10, 0.28, 0.52 } }
local MIDNIGHT = { leafColor = { 0.9, 0.9, 0.9 }, textFaint = { 0.5, 0.5, 0.5 } }

local function Load(theme)
    local src = Source()
    local s = assert(src:find("-- The steps' ink.", 1, true))
    local _, e = assert(src:find("\nend\r?\n", s))
    local ns = { GOLD_COLOR = { 1, 0.82, 0 }, TEXT_NEXT = { 0.78, 0.78, 0.80 }, TEXT_DIM = { 0.55, 0.55, 0.58 },
        TEXT_ASIDE = { 0.56, 0.74, 0.82 },
        Results = { GetActiveTheme = function() return theme end } }
    local GPS = {}
    local env = setmetatable({ ns = ns, GPS = GPS }, { __index = _G })
    assert(load(src:sub(s, e), "=GPS.lua ink", "t", env))()
    return GPS, ns
end

local function same(a, b)
    return math.abs(a[1] - b[1]) < 1e-6 and math.abs(a[2] - b[2]) < 1e-6 and math.abs(a[3] - b[3]) < 1e-6
end

local tests = {}

function tests.lightTheme_thePopoutTakesTheThemesInk()
    local GPS = Load(SKY)
    local ink = GPS.Ink({ isPopout = true })
    H.assertTrue(ink.light)
    H.assertTrue(same(ink.primary, SKY.pathColorHover), "the active step")
    H.assertTrue(same(ink.next, SKY.leafColor), "steps to come")
    H.assertTrue(same(ink.dim, SKY.textFaint), "done, the time, the links")
    H.assertTrue(same(ink.aside, { SKY.accent[1] * 0.8, SKY.accent[2] * 0.8, SKY.accent[3] * 0.8 }), "advice, a shade darker")
    H.assertTrue(same(ink.field, { SKY.leafColor[1] * 0.85, SKY.leafColor[2] * 0.85, SKY.leafColor[3] * 0.85 }),
        "the fields' words, glass and X: one blue")
    H.assertEq(#ink.aside, 3, "no alpha of the accent's on the text")
end

function tests.lightTheme_besideTheMapTheArtStaysDark()
    local GPS, ns = Load(SKY)
    local ink = GPS.Ink({ mapFont = true })
    H.assertFalse(ink.light)
    H.assertEq(ink.dim, ns.TEXT_DIM, "the live table, lifted over a tree")
end

function tests.darkTheme_thePopoutKeepsTheDarkInk()
    local GPS, ns = Load(MIDNIGHT)
    local ink = GPS.Ink({ isPopout = true })
    H.assertFalse(ink.light)
    H.assertEq(ink.next, ns.TEXT_NEXT)
end

function tests.aThemeChange_repaintsWhatWasInked()
    local theme = MIDNIGHT
    local GPS = Load(setmetatable({}, { __index = function(_, k) return theme[k] end }))
    local frame, painted = { isPopout = true }, nil
    GPS.Inked(frame, function(ink) painted = ink.dim end)
    H.assertTrue(same(painted, { 0.55, 0.55, 0.58 }))
    theme = SKY
    GPS.RepaintInk(frame)
    H.assertTrue(same(painted, SKY.textFaint))
end

-- The pop-out's own parts paint in the ink: no dark-art gray or white
-- hover written into them by hand.
function tests.popoutSurfaces_haveNoHandPaintedDarkArtColors()
    local src = Source()
    local bad = {}
    local function scan(fromMark, toMark)
        local s = assert(src:find(fromMark, 1, true), fromMark)
        local e = assert(src:find(toMark, s + #fromMark, true), toMark)
        local body = src:sub(s, e)
        local line = select(2, src:sub(1, s):gsub("\n", "")) + 1
        for text in body:gmatch("([^\n]*)\n") do
            if text:find("ns.TEXT_DIM", 1, true) or text:find("ns.TEXT_NEXT", 1, true)
               or text:find("ns.TEXT_ASIDE", 1, true) or text:find("1, 0.97, 0.86", 1, true)
               or text:find("(1, 1, 1)", 1, true) or text:find("(1, 1, 1, 1)", 1, true) then
                -- The map page's pop-out button sits on the map's dark art.
                if not text:find("tint(", 1, true) then bad[#bad + 1] = "GPS.lua:" .. line .. ": " .. text end
            end
            line = line + 1
        end
    end
    scan("local function BuildSurface(", "\nlocal function BuildPage(")
    scan("local function BuildPopout(", "\nfunction GPS:TogglePopout(")
    scan("local function FromRow(", "\nend\n")
    H.assertEq(#bad, 0, table.concat(bad, "\n"))
end

function tests.lightTheme_noQuestPaper()
    local src = Source()
    local s = assert(src:find("function GPS.QuestRimOffered()", 1, true))
    local _, e = assert(src:find("\nend\r?\n", s))
    local theme = SKY
    local GPS = {}
    local env = setmetatable({ GPS = GPS, GAME_ART = { questRim = true },
        ns = { Results = { GetActiveTheme = function() return theme end } } }, { __index = _G })
    assert(load(src:sub(s, e), "=GPS.lua rim", "t", env))()
    H.assertFalse(GPS.QuestRimOffered(), "a light theme")
    theme = MIDNIGHT
    H.assertTrue(GPS.QuestRimOffered(), "a dark theme")
end

local pass, fail, failures = H.runSuite("GPSLightInk", tests)
return { pass = pass, fail = fail, failures = failures }

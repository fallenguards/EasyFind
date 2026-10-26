-- The map tab's search box keeps the game's own search box font, at the
-- list's text size (MapTab.ScaleChrome, MapSearch/MapTab.lua): the typed
-- text went thin and small when sized from ChatFontSmall, not the
-- template's ChatFontNormal (2026-10-26).
local H = require("Harness")

local function Font(file, size, flags)
    return { GetFont = function() return file, size, flags end }
end

local function Region()
    local r = {}
    function r:SetFont(file, size, flags) self.file, self.size, self.flags = file, size, flags end
    return r
end

local function Load(scale)
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/MapTab.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local function ScaleFont", 1, true))
    local _, se = assert(src:find("\nend\r?\n", s))
    local c = assert(src:find("function MapTab.ScaleChrome", se, true))
    local _, ce = assert(src:find("\nend\r?\n", c))
    local MapTab = {}
    local env = setmetatable({
        MapTab = MapTab, FontScale = function() return scale end,
        ChatFontNormal = Font("chat", 14, "OUTLINE"), ChatFontSmall = Font("chat", 12, ""),
        GameFontDisableSmall = Font("game", 10, ""), GameFontHighlight = Font("game", 12, ""),
        GameFontHighlightSmall = Font("game", 10, ""),
    }, { __index = _G })
    env._G = env
    assert(load(src:sub(s, se) .. src:sub(c, ce), "=MapTab.lua chrome", "t", env))()
    return MapTab
end

local tests = {}

function tests.theBoxKeepsTheGamesSearchFont_atTheListsSize()
    local box = Region()
    box.Instructions = Region()
    Load(1).ScaleChrome({ searchBox = box })
    H.assertEq(box.size, 14, "the template's ChatFontNormal, as the game's own box")
    H.assertEq(box.flags, "OUTLINE")
    H.assertEq(box.Instructions.size, 10, "the placeholder's own GameFontDisableSmall")
    Load(1.3).ScaleChrome({ searchBox = box })
    H.assertTrue(math.abs(box.size - 18.2) < 0.01, "grown with the text size")
end

-- The box grows with its text, its border art with it: 14 pt filled the 20
-- tall box at Medium and spilled past it larger (MoP, 2026-10-26).
local function FitBox(minHeight, size)
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/MapTab.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("searchBox.minHeight = 20", 1, true))
    local _, e = assert(src:find("searchBox.FitHeight()", s, true))
    local function Piece() return { SetHeight = function(self, h) self.h = h end } end
    local box = { Left = Piece(), Middle = Piece(), Right = Piece() }
    function box:GetFont() return "font", size, "" end
    function box:SetHeight(h) self.h = h end
    local env = setmetatable({ searchBox = box, mmax = math.max }, { __index = _G })
    assert(load(src:sub(s, e), "=MapTab.lua box", "t", env))()
    box.minHeight = minHeight
    box.FitHeight()
    return box
end

function tests.theBoxFitsItsText_atEveryTextSize()
    H.assertEq(FitBox(20, 14).h, 22, "Medium: room round the 14 pt text")
    H.assertEq(FitBox(20, 18.2).h, 26, "Extra large")
    H.assertEq(FitBox(20, 11.9).h, 20, "Small: never under the client's box")
    local box = FitBox(24, 14)
    H.assertEq(box.h, 24, "a taller client box stays")
    H.assertEq(box.Middle.h, 24, "the border art goes with it")
end

function tests.aTextSizeReachesTheBoxHeight()
    local box = Region()
    local fitted = 0
    box.FitHeight = function() fitted = fitted + 1 end
    Load(1.3).ScaleChrome({ searchBox = box })
    H.assertEq(fitted, 1)
end

local pass, fail, failures = H.runSuite("MapTabBoxFont", tests)
return { pass = pass, fail = fail, failures = failures }

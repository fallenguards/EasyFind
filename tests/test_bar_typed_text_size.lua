-- The search bar's typed text follows Font Size. The box draws what is typed
-- with a text of its own; the addon font pass (RegisterAddonFontsIn) held
-- that text at the font's base size, 12, while the box, its placeholder and
-- the results grew (barfont probe, Era, 2026-11-04).
local H = require("Harness")

local function Read(rel)
    local fh = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local text = fh:read("*a")
    fh:close()
    return text
end

local function Span(src, from, to)
    local s = assert(src:find(from, 1, true), "not found: " .. from)
    local e = assert(src:find(to, s, true), "not found: " .. to)
    local _, stop = src:find("\nend\r?\n", e)
    return src:sub(s, stop)
end

local function Text(size)
    local fs = { path = "Fonts\\FRIZQT__.TTF", size = size, flags = "", sets = 0 }
    function fs:GetObjectType() return "FontString" end
    function fs:GetFont() return self.path, self.size, self.flags end
    function fs:SetFont(path, sz, flags)
        self.path, self.size, self.flags, self.sets = path, sz, flags, self.sets + 1
        return true
    end
    return fs
end

-- The bar's edit box: its typed text and our placeholder, as GetRegions gives them.
local function Box(size)
    local box = Text(size)
    box.typed, box.placeholder = Text(size), Text(size)
    function box:GetObjectType() return "EditBox" end
    function box:GetRegions() return self.typed, self.placeholder end
    function box:GetChildren() end
    return box
end

-- The addon font pass from Shared/Utils.lua, and the bar's sizing of its box.
local function Load(fontSize)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind.db = env.EasyFind.db or {}
    env.EasyFind.db.fontSize = fontSize
    local utils = Read("Shared/Utils.lua")
    local registry = Span(utils, "\nlocal fontRegistry = {}", "\nfunction ns.RefreshAddonFont()")
    local chunk = assert(load("local ns, ADDON_FONT_FILES = ...\n" .. registry, "=Utils.lua font pass", "t", env))
    chunk(ns, {})
    local bar = Read("Search/SearchBar.lua")
    local sizing = Span(bar, "\nlocal function SizeTypedText(", "\nlocal function SizeTypedText(")
    local Search = { ScaleFont = function(_, fs) fs:SetFont("Fonts\\FRIZQT__.TTF", 12 * fontSize, "") end }
    local fn = assert(load("local Search, ns = ...\n" .. sizing .. "\nreturn SizeTypedText", "=SearchBar.lua", "t", env))
    return ns, fn(Search, ns)
end

local tests = {}

function tests.typedText_followsFontSize_throughTheFontPass()
    for _, fontSize in ipairs({ 0.80, 0.90, 1.15, 1.35 }) do
        local ns, SizeTypedText = Load(fontSize)
        local box = Box(12)
        SizeTypedText(box)
        ns.RegisterAddonFontsIn(box)
        H.assertEq(box.typed.size, 12 * fontSize, "typed text at Font Size " .. fontSize)
        ns.RefreshAddonFont()
        H.assertEq(box.typed.size, 12 * fontSize, "a font choice redrawing every text leaves it, " .. fontSize)
        H.assertTrue(box.placeholder._addonFontBaseline ~= nil, "the placeholder still goes through the font pass")
    end
end

function tests.theBarSizesItsTypedText_beforeTheFontPass()
    local bar = Read("Search/SearchBar.lua")
    local body = Span(bar, "\nfunction Search:UpdateFontSize()", "\nfunction Search:UpdateFontSize()")
    local sized = body:find("SizeTypedText(searchFrame.editBox)", 1, true)
    local pass = body:find("ns.RegisterAddonFontsIn(searchFrame)", 1, true)
    H.assertTrue(sized ~= nil and pass ~= nil and sized < pass, "sized and kept out before the pass registers it")
end

local pass, fail, failures = H.runSuite("BarTypedTextSize", tests)
return { pass = pass, fail = fail, failures = failures }

-- The overlay layout cut a line into pieces and measured each with a font
-- string; a piece ending inside a link's hidden data read that data as
-- text, so a folded line's long data wrapped it four rows and every box,
-- tail and overlay under it went down with it (2026-11-02, /efd suite
-- fold: "tons of weird overlapping"). Link and color codes are now one
-- entry each, never measured part-open.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

-- A font string as the game's: complete codes draw nothing, a part-open
-- link's data reads as text, 6 px a character.
local function Meter()
    local m = {}
    function m:SetText(t) self.text = t end
    function m:GetStringWidth()
        local t = (self.text or ""):gsub("|H[^|]*|h", ""):gsub("|h", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        local n = 0
        for _ in t:gmatch("[^\128-\191]") do n = n + 1 end
        return n * 6
    end
    return m
end

local function LoadLayout()
    local src = Read("Apps/Notes/Notes.lua")
    local s = assert(src:find("function Fmt.LinkCodeEnd(text, i)", 1, true))
    local l = assert(src:find("\nlocal function LayoutCharacters(text, editor, wrapWidth)", s, true))
    local e = select(2, assert(src:find("\n    return positions\nend\n", l, true)))
    local meter = Meter()
    local env = setmetatable({
        Fmt = {},
        GetMeasureMeter = function() return meter end,
        MatchLinePrefix = function() return 0 end,
        GlyphSize = function(b) return b < 128 and 1 or b < 224 and 2 or b < 240 and 3 or 4 end,
    }, { __index = _G })
    return assert(load(src:sub(s, e) .. "\nreturn LayoutCharacters", "=Notes.lua layout", "t", env))()
end

local tests = {}

function tests.aFoldsHiddenData_neverWrapsItsLine()
    local Layout = LoadLayout()
    local fold = "|cffa335ee|Heasyfind:fold:" .. ("q"):rep(160) .. "|h[Thunderfury...]|h|r"
    local text = "a " .. fold .. "\nnext"
    local positions = Layout(text, { GetTextInsets = function() return 0, 0, 0, 0 end }, 200)
    local nextLine
    for _, p in ipairs(positions) do
        if p.byteStart == #text - 3 then nextLine = p.line end
    end
    H.assertEq(nextLine, 2, "the line under the fold is the second")
    local codes = 0
    for _, p in ipairs(positions) do
        if p.glyph == "" then
            codes = codes + 1
            H.assertEq(p.width, 0, "a code draws nothing")
        end
    end
    H.assertEq(codes, 4, "the color, the link's data, its close and the color's end: one entry each")
end

function tests.aPipeTypedTwiceIsDrawn()
    local Layout = LoadLayout()
    local positions = Layout("a||b", { GetTextInsets = function() return 0, 0, 0, 0 end }, 200)
    for _, p in ipairs(positions) do H.assertTrue(p.glyph ~= "", "|| is a character, not a code") end
end

local pass, fail, failures = H.runSuite("NotesLayoutCodes", tests)
return { pass = pass, fail = fail, failures = failures }

-- A provider's iconWell (EasyFind.API): its small glyphs (a quest's "?")
-- on the map's pin in a dark round well, ns.SetIconWell (Shared/Utils.lua);
-- bare, the mark was lost in the map's art. The pin is reused: it takes the
-- old well away before its icon is set, so a shrunk glyph never carries on.
-- Never on result rows: a well in the row's own colors shows nothing.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Texture(owner)
    local t = { shown = true, coords = { 0, 0, 0, 1, 1, 0, 1, 1 }, owner = owner }
    function t:SetColorTexture() end
    function t:SetPoint() end
    function t:SetAllPoints() end
    function t:AddMaskTexture() end
    function t:SetVertexColor(r, g, b, a) self.color = { r, g, b, a } end
    function t:Show() self.shown = true end
    function t:Hide() self.shown = false end
    function t:IsShown() return self.shown end
    function t:GetParent() return self.owner end
    function t:GetDrawLayer() return "ARTWORK", 0 end
    function t:GetTexture() return self.file end
    function t:SetTexture(file, wrap) self.file, self.wrap = file, wrap end
    function t:GetTexCoord() return table.unpack(self.coords) end
    function t:SetTexCoord(l, r, top, b) self.coords = { l, top, l, b, r, top, r, b } end
    return t
end

local function SetIconWell()
    local src = Read("Shared/Utils.lua")
    local s = assert(src:find("function ns.SetIconWell", 1, true), "SetIconWell")
    local e = select(2, assert(src:find("\nend\n", s, true)))
    local env = setmetatable({ ns = { PORTRAIT_ALPHA_MASK = "mask" } }, { __index = _G })
    assert(load(src:sub(s, e), "=Utils.lua SetIconWell", "t", env))()
    return env.ns.SetIconWell
end

local function Row()
    local row = { made = {} }
    function row:CreateTexture() local t = Texture(row) row.made[#row.made + 1] = t return t end
    function row:CreateMaskTexture() return Texture(row) end
    local icon = Texture(row)
    icon.file = 365195
    return row, icon
end

local RING, FILL = { 0.4, 0.5, 0.7 }, { 0.02, 0.02, 0.03 }

local tests = {}

function tests.aWholeGlyphSitsSmallerInItsWell()
    local well = SetIconWell()
    local row, icon = Row()
    well(icon, RING, FILL)
    H.assertEq(#row.made, 2, "a ring and a disc")
    H.assertTrue(icon.efWell.ring:IsShown() and icon.efWell.disc:IsShown())
    H.assertEq(icon.efWell.ring.color[1], 0.4)
    H.assertTrue(icon.coords[1] < 0 and icon.coords[7] > 1, "the glyph drawn inside the box")
    H.assertEq(icon.wrap, "CLAMPTOBLACKADDITIVE", "clear past the glyph's edge")
end

function tests.aCutKeepsItsCoords()
    local well = SetIconWell()
    local _, icon = Row()
    icon:SetTexCoord(0.25, 0.5, 0, 0.5)
    well(icon, RING, FILL)
    H.assertEq(icon.coords[1], 0.25)
    H.assertEq(icon.coords[7], 0.5)
end

function tests.takenAwayTheGlyphIsWholeAgain()
    local well = SetIconWell()
    local row, icon = Row()
    well(icon, RING, FILL)
    well(icon, nil)
    H.assertFalse(icon.efWell.ring:IsShown())
    H.assertFalse(icon.efWell.disc:IsShown())
    H.assertEq(icon.coords[1], 0)
    H.assertEq(icon.coords[7], 1)
    well(icon, RING, FILL)
    H.assertEq(#row.made, 2, "made once, shown again")
end

function tests.aRowNeverWellLeavesItsCoordsAlone()
    local well = SetIconWell()
    local _, icon = Row()
    icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    well(icon, nil)
    H.assertEq(icon.coords[1], 0.1, "no well before: nothing to put back")
end

-- The map's own pin: the quest mark that sat bare on the city art.
function tests.theMapPinWearsItToo()
    local frames = Read("MapSearch/Frames.lua")
    local s = assert(frames:find("function Frames.SetPinIcon(pin, icon, face, category)", 1, true), "SetPinIcon takes the category")
    local off = assert(frames:find("ns.SetIconWell(pin.icon, nil)", s, true))
    local set = assert(frames:find("Utils.SetIconTexture(pin.icon, icon)", s, true))
    H.assertTrue(off < set, "dropped before the pin's next icon")
    H.assertTrue(frames:find("ns.SetIconWell(pin.icon, WELL_RING, WELL_FILL)", set, true) ~= nil)
    local nav = Read("MapSearch/Navigation.lua")
    local calls = 0
    for args in nav:gmatch("MapFrames%.SetPinIcon%(([^\n]*)%)") do
        calls = calls + 1
        H.assertTrue(args:find("category") ~= nil, "every pin passes its category: " .. args)
    end
    H.assertTrue(calls >= 2, "the single pin and the cluster's")
end

local pass, fail, failures = H.runSuite("IconWell", tests)
return { pass = pass, fail = fail, failures = failures }

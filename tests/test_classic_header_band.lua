-- The map search's zone headers on a client without the quest log sheet
-- (Era, MoP Classic) wear our copy of retail's band and fold glyphs
-- (textures/art/questlog-*, cut from the sheet): a plain box with the
-- client's red buttons stood in, drawn as large as the row and touching
-- the next (2026-10-28).
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.theArtShipsAndIsListed()
    for _, name in ipairs({ "questlog-tab", "questlog-expand", "questlog-shrink" }) do
        local f = io.open(H.ADDON_ROOT .. "/textures/art/" .. name .. ".tga", "rb")
        H.assertTrue(f ~= nil, name .. ".tga ships")
        if f then f:close() end
    end
    local utils = Read("Shared/Utils.lua")
    H.assertTrue(utils:find('questlog_tab = { tex = ns%.ART_DIR %.%. "questlog%-tab", coords = { 0, 1, 0, 0%.6875 } }') ~= nil)
    H.assertTrue(utils:find('questlog_expand = { tex = ns%.ART_DIR %.%. "questlog%-expand", coords = { 0, 0%.5625, 0, 0%.5625 } }') ~= nil)
    H.assertTrue(utils:find('questlog_shrink = { tex = ns%.ART_DIR %.%. "questlog%-shrink", coords = { 0, 0%.5625, 0, 0%.5625 } }') ~= nil)
end

-- The band in three slices: its rounded ends at the art's own proportion
-- (stretched whole across a header they went ragged), the middle between.
function tests.theHeadersWearTheBandWithoutTheSheet()
    local src = Read("MapSearch/PlaceList.lua")
    H.assertTrue(src:find("local art, u, v = ns%.ART%.questlog_tab, BAND_CAP / 128, ns%.ART%.questlog_tab%.coords%[4%]") ~= nil,
        "the band's art and its ends' share")
    H.assertTrue(src:find("hdr%.bgL:SetTexCoord%(0, u, 0, v%)") ~= nil and src:find("hdr%.bgR:SetTexCoord%(1 %- u, 1, 0, v%)") ~= nil
        and src:find("bg:SetTexCoord%(u, 1 %- u, 0, v%)") ~= nil, "the ends and the middle each from their slice")
    H.assertTrue(src:find("local capW = BAND_CAP / 44 %* %(hdr:GetHeight%(%) or GROUP_HEADER_H%)") ~= nil,
        "an end as wide as the band's height says")
    H.assertTrue(src:find("hdr:HookScript%(\"OnSizeChanged\", PlaceBandCaps%)") ~= nil, "and again as the header resizes")
    H.assertTrue(src:find("hover:SetAlpha%(0%.40%)") ~= nil and src:find("hdr%.hoverL:SetAlpha%(0%.40%)") ~= nil,
        "the hover band, as retail's, ends included")
    H.assertTrue(src:find("if skin ~= MAP_SKIN then HideBandCaps%(hdr%) end") ~= nil, "another skin puts the ends away")
    H.assertTrue(src:find("SetColorTexture%(0%.42, 0%.38, 0%.32") == nil, "the plain box is gone")
end

-- A row's hover glow is retail's too: the atlas drew a green box on Era.
function tests.theRowGlowIsRetailsWithoutTheSheet()
    local src = Read("MapSearch/PlaceList.lua")
    H.assertTrue(src:find("local art = ns%.ART%.questlog_glow%s+row:SetHighlightTexture%(art%.tex%)") ~= nil)
    H.assertTrue(src:find('if not %(ns%.Caps and ns%.Caps%.questLogAtlas == false%) then%s+row:SetHighlightAtlas%("QuestLog%-quest%-glow%-yellow"%)') ~= nil,
        "the atlas only with the sheet")
    local f = io.open(H.ADDON_ROOT .. "/textures/art/questlog-glow.tga", "rb")
    H.assertTrue(f ~= nil, "questlog-glow.tga ships")
    if f then f:close() end
    H.assertTrue(Read("Shared/Utils.lua"):find('questlog_glow = { tex = ns%.ART_DIR %.%. "questlog%-glow", coords = { 0, 0%.57617, 0, 0%.78125 } }') ~= nil)
end

function tests.theFoldGlyphsAreRetailsWithoutTheSheet()
    local src = Read("Shared/Utils.lua")
    H.assertTrue(src:find("local art = collapsed and ns%.ART%.questlog_expand or ns%.ART%.questlog_shrink%s+tex:SetTexture%(art%.tex%)") ~= nil)
    H.assertTrue(src:find("UI%-PlusButton%-Up") == nil and src:find("UI%-MinusButton%-Up") == nil, "the red buttons are gone")
end

local pass, fail, failures = H.runSuite("ClassicHeaderBand", tests)
return { pass = pass, fail = fail, failures = failures }

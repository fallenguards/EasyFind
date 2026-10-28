-- The time still to go on a GPS surface (the pop-out, the map tab's page)
-- wears a (WIP) tag after it with a hover line saying the estimate is
-- still being worked on (2026-10-28). The tag follows the time: hidden
-- with it, sized with it, and the search box after the time sits after
-- the tag when it shows.
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.theTagAfterTheTimeWithItsHoverLine()
    local src = Read("Apps/GPS/GPS.lua")
    H.assertTrue(src:find('tag:SetPoint%("LEFT", eta, "LEFT", %(eta:GetStringWidth%(%) or 0%) %+ 4, 0%)') ~= nil,
        "right after the time's words: the line spans to the Clear link (the tag sat there, 2026-10-28)")
    H.assertTrue(src:find('tag:SetPoint%("LEFT", eta, "RIGHT"') == nil, "never at the line's far end")
    H.assertTrue(src:find('tagText:SetText%(L%["GPS_ETA_WIP"%]%)') ~= nil, "the tag's word from the locale")
    H.assertTrue(src:find('GameTooltip:AddLine%(L%["GPS_ETA_WIP_TT"%], 1, 1, 1, true%)') ~= nil, "the hover line, wrapped")
    H.assertTrue(src:find("frame%.PlaceEtaTag = function%(self, shown%)") ~= nil)
    local en = Read("Locales/enUS.lua")
    H.assertTrue(en:find('L%["GPS_ETA_WIP"%]%s+= "%(WIP%)"') ~= nil)
    H.assertTrue(en:find('L%["GPS_ETA_WIP_TT"%]%s+= "Please take ETAs with a grain of salt') ~= nil)
end

function tests.theTagFollowsTheTime()
    local src = Read("Apps/GPS/GPS.lua")
    H.assertTrue(src:find("s%.eta:SetText%(eta%)%s+if s%.PlaceEtaTag then s:PlaceEtaTag%(eta ~= \"\"%) end") ~= nil,
        "placed as the time ticks")
    H.assertTrue(src:find("container:PlaceEtaTag%(not route%.arrived and not GPS%.planning and route%.eta ~= nil and route%.eta > 0%)") ~= nil,
        "placed on a redraw, after the fonts are sized; never over a plan under way")
    H.assertTrue(src:find("container%.eta:SetText%(\"\"%)%s+container:PlaceEtaTag%(false%)") ~= nil, "gone on arrival")
    H.assertTrue(src:find("self%.eta:SetShown%(hasRoute%)%s+if not hasRoute then self%.etaTag:Hide%(%) end") ~= nil,
        "gone with the time when the route goes")
    H.assertTrue(src:find("self%.eta:Hide%(%); self%.etaTag:Hide%(%);") ~= nil, "folded away with the time")
    H.assertTrue(src:find("SizeFont%(container%.eta, px%)%s+SizeFont%(container%.etaTagText, px%)") ~= nil, "the page's size")
    H.assertTrue(src:find('ScaleFont%(container%.etaTagText, "GameFontHighlightSmall", scale and MAP_STEP_PX %* scale%)') ~= nil,
        "the pop-out's scale")
    H.assertTrue(src:find('if self%.etaTag:IsShown%(%) then%s+box:SetPoint%("LEFT", self%.etaTag, "RIGHT", 10, 0%)%s+else%s+'
        .. 'box:SetPoint%("LEFT", self%.eta, "LEFT", %(self%.eta:GetStringWidth%(%) or 0%) %+ 10, 0%)') ~= nil,
        "the search box after the tag when it shows, after the time's words otherwise")
end

local pass, fail, failures = H.runSuite("GPSEtaTag", tests)
return { pass = pass, fail = fail, failures = failures }

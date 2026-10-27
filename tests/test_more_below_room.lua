-- A scrolling settings page keeps room under its view for the more-below
-- chevron, which hangs under the view: the page's holder runs to the
-- window's edge, and with no room the chevron sat on the Classic frame art
-- (2026-10-27).
local H = require("Harness")

local tests = {}

function tests.scrollingPage_leavesRoomForTheChevron()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Options/OptionsPanel.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local body = assert(src:match("local function ScrollingPage%(holder%)(.-)\nend\n"))
    local y = tonumber(body:match('scroll:SetPoint%("BOTTOMRIGHT", holder, "BOTTOMRIGHT", %-?%d+, (%-?%d+)%)'))
    H.assertTrue(y ~= nil, "the view's bottom anchor is found")
    -- The chevron is 10 tall, 2 under the view.
    H.assertTrue(y >= 12, "room under the view: " .. tostring(y))
end

local pass, fail, failures = H.runSuite("MoreBelowRoom", tests)
return { pass = pass, fail = fail, failures = failures }

-- Our Quests and search tabs under ClassicUI Forever's classic map (Forever,
-- 2026-11-09/10): the back tab hangs off CUIF's own map frame, scaled apart
-- from the quest pane, and its drop was the two GetTop values subtracted
-- across scales: /efd maptabs measured the tab 399.8 down where the pane's
-- top is 43.8 (map scale 0.9), so both tabs sat at the map's foot. The drop
-- is taken on the screen and put back in the tab's units.
local H = require("Harness")

local function Drop(qTop, qs, wTop, ws, tabScale)
    return (qTop * qs - wTop * ws) / tabScale - 28
end

local tests = {}

function tests.theDrop_isTheScreenGap_inTheTabsUnits()
    -- The pane 43.8 screen units under the frame's top, the tab at 0.9.
    local d = Drop((1000 - 43.8) / 0.9, 0.9, 1000 / 0.45, 0.45, 0.9)
    H.assertTrue(math.abs(d - (-43.8 / 0.9 - 28)) < 1e-6, "just under the pane's top, whatever the frame's scale")
end

function tests.placeTab_convertsBothTopsToTheScreen()
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/MapTab.lua", "rb"))
    local src = f:read("*a")
    f:close()
    H.assertTrue(src:find("(qTop * qmf:GetEffectiveScale() - wTop * wmf:GetEffectiveScale()) / backTab:GetEffectiveScale()",
        1, true) ~= nil)
    H.assertTrue(src:find("qTop - wTop - 28", 1, true) == nil, "never the raw difference")
end

local pass, fail, failures = H.runSuite("MapTabPlace", tests)
return { pass = pass, fail = fail, failures = failures }

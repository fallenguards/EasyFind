-- A row's tooltip is owned with ANCHOR_PRESERVE (Search/Results/Tooltips.lua
-- AnchorRowTooltip). The client's comparison manager slides a tooltip whose
-- compare frames do not fit beside it with SetAnchorType(anchorType,
-- slide, 0); on a tooltip owned with ANCHOR_NONE that drops the points the
-- edge placement set, and the tooltip was up with its lines and no
-- rectangle from the second gear hover on (retail, 2026-11-02, /efd
-- iconwatch). ANCHOR_PRESERVE is the one anchor the manager leaves alone.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local tests = {}

function tests.theRowTooltipIsOwnedWithAnchorPreserve()
    local src = Read("Search/Results/Tooltips.lua")
    local s = assert(src:find("function Tooltips:AnchorRowTooltip(tooltip, ownerFrame)", 1, true))
    local body = src:sub(s, assert(src:find("\nend\n", s, true)))
    H.assertTrue(body:find('tooltip:SetOwner(ownerFrame, "ANCHOR_PRESERVE")', 1, true) ~= nil, "owned with ANCHOR_PRESERVE")
    H.assertNil(body:find('SetOwner(ownerFrame, "ANCHOR_NONE")', 1, true), "never ANCHOR_NONE: the compare slide drops its points")
    H.assertTrue(body:find("self:PlaceAtPanelEdge(tooltip, ownerFrame)", 1, true) ~= nil, "the edge placement stays")
end

-- The equipped item's compare frames show beside a row's tooltip only
-- while the compare key is held, as Classic shows them; the client's
-- always-compare option doubled every gear row's tooltip width.
function tests.comparesShowOnlyWhileTheCompareKeyIsHeld()
    local src = Read("Search/Results/Tooltips.lua")
    local s = assert(src:find("local function HookCompareTooltip(compare, tooltip)", 1, true))
    local body = src:sub(s, assert(src:find("\nend\n", s, true)))
    H.assertTrue(body:find('if not IsModifiedClick("COMPAREITEMS") then\n            tooltip._efCompareHeld = tooltip._efCompareHeld or {}\n'
        .. '            tooltip._efCompareHeld[self] = true\n            self:Hide()\n            return\n        end', 1, true) ~= nil,
        "a compare shown without the key is held and hidden at once")
    H.assertTrue(body:find("ReassertCompareAnchors()", 1, true) ~= nil, "with the key it sits outward of the tooltip")
    -- The manager counts a hidden compare as shown and never shows it
    -- again for the key: the tooltip's own update follows the key.
    local anchor = assert(src:find("function Tooltips:AnchorRowTooltip(tooltip, ownerFrame)", 1, true))
    local tail = src:sub(anchor)
    H.assertTrue(tail:find('local want = IsModifiedClick("COMPAREITEMS")\n            for compare in pairs(held) do\n'
        .. "                if want ~= compare:IsShown() then compare:SetShown(want) end", 1, true) ~= nil,
        "held compares show while the key is down and hide when it is up")
    H.assertTrue(tail:find("self._efCompareHeld = nil", 1, true) ~= nil, "the held set goes with the tooltip")
end

-- The fit shrinks from the base scale, never from the last showing's: a
-- tooltip re-owned while up keeps its scale, and a fit from a shrunk scale
-- shrank it again at every re-hover (retail, 2026-11-02).
function tests.theScaleIsResetBeforeEveryFit()
    local src = Read("Search/Results/Tooltips.lua")
    local s = assert(src:find("local function ApplySearchTooltipScale(tooltip)", 1, true))
    local body = src:sub(s, assert(src:find("\nend\n", s, true)))
    H.assertNil(body:find("if s == 1.0 then return end", 1, true), "no early return at scale 1: the reset must run")
    H.assertTrue(body:find("tooltip:SetScale(tooltip._efBaseScale * s)", 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("RowTooltipAnchor", tests)
return { pass = pass, fail = fail, failures = failures }

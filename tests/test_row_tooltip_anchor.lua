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

local pass, fail, failures = H.runSuite("RowTooltipAnchor", tests)
return { pass = pass, fail = fail, failures = failures }

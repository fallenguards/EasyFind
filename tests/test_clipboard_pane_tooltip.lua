-- The clipboard pane embeds a link entry's own tooltip (the item, the
-- spell) inside itself as a row is hovered. The row's generic provider
-- path then took the tooltip over, anchored it to the row and hid it
-- when the provider said none, so the pane showed a blank block
-- (2026-10-27). A tooltip owned by a surface that embeds it is left alone.
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.anEmbeddedTooltipIsLeftToItsOwner()
    local src = Read("Search/Results/Rows/Tooltips.lua")
    local at = src:find("if provider and provider%.tooltip then%s+local owner = GameTooltip:IsShown%(%) and GameTooltip:GetOwner%(%)%s+if owner and owner%._efEmbedsTooltip then return end%s+AnchorRowTooltip%(GameTooltip, self%)")
    H.assertTrue(at ~= nil, "the owner is asked before the row takes the tooltip")
    local pane = Read("Apps/Clipboard/Pane.lua")
    H.assertTrue(pane:find("_efEmbedsTooltip = true", 1, true) ~= nil, "the pane says it embeds one")
    H.assertTrue(pane:find('GameTooltip:SetOwner(pane, "ANCHOR_NONE")', 1, true) ~= nil, "and owns it while it does")
end

local pass, fail, failures = H.runSuite("ClipboardPaneTooltip", tests)
return { pass = pass, fail = fail, failures = failures }

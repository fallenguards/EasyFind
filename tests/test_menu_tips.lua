-- A menu in the TOOLTIP strata at a high level draws over the game's own
-- tooltip (GameTooltip sits low in that strata): its hover tips go through
-- ns.ShowHintTooltip, which sits above every menu (Utils.HINT_LEVEL). The
-- GPS pop-out's settings rows showed their tips under the menu (2026-10-26).
-- KNOWN: files whose game tooltip serves another frame, not the menu.
local H = require("Harness")

local KNOWN = {
    -- Its settings search results sit there; the game's tooltip is the aliases tab's.
    ["Apps/Options/OptionsPanel.lua"] = true,
    -- Its paste dialog sits there; the game's tooltips are the shared cut-label tips.
    ["Shared/Utils.lua"] = true,
}

local function scan(text)
    for level in text:gmatch('SetFrameStrata%("TOOLTIP"%)%s*\n[^\n]-SetFrameLevel%((%d+)%)') do
        if tonumber(level) >= 1000 and text:find("GameTooltip:SetOwner", 1, true) then return true end
    end
    return false
end

local tests = {}

function tests.noHighMenuUsesTheGamesTooltip()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                checked = checked + 1
                if scan(fh:read("a")) and not KNOWN[rel] then bad[#bad + 1] = rel end
                fh:close()
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "use ns.ShowHintTooltip in:\n  " .. table.concat(bad, "\n  "))
end

function tests.scan_flagsTheOldPopup()
    H.assertTrue(scan('popup:SetFrameStrata("TOOLTIP")\n    popup:SetFrameLevel(9500)\n'
        .. 'GameTooltip:SetOwner(popup, "ANCHOR_NONE")\n'))
    H.assertFalse(scan('popup:SetFrameStrata("DIALOG")\n    popup:SetFrameLevel(9000)\n'
        .. 'GameTooltip:SetOwner(row, "ANCHOR_RIGHT")\n'))
end

local pass, fail, failures = H.runSuite("MenuTips", tests)
return { pass = pass, fail = fail, failures = failures }

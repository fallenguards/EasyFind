-- No hand-made panels (2026-10-27: Notes' Remind me and item note popups
-- each set their own grey fill and hid their border, unlike every menu).
-- A panel takes ns.StyleMenuPanel (the theme's fill, a border, the skins)
-- and an input ns.CreateRingedWell with ns.PaintInputWell. Flagged: a frame
-- whose border edge is turned off and filled with an opaque color written
-- out in numbers.
local H = require("Harness")

-- Not panels: chips, filled as their kind.
local KNOWN = { ["Apps/Notes/Notes.lua ov"] = "the +N chip after the context chips" }

local function scan(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local bad = {}
    for i, line in ipairs(lines) do
        local name = line:match("SetRoundedRectBorderEdgeShown%(([%w_%.]+), false%)")
        if name then
            local esc = name:gsub("%p", "%%%0")
            for j = math.max(1, i - 4), math.min(#lines, i + 4) do
                local a = lines[j]:match("SetRoundedRectFill%(" .. esc .. ", [%d%.]+, [%d%.]+, [%d%.]+, ([%d%.]+)")
                if a and tonumber(a) > 0 then
                    bad[#bad + 1] = { line = j, name = name }
                    break
                end
            end
        end
    end
    return bad
end

local tests = {}

function tests.panelsWearTheSharedStyle()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                checked = checked + 1
                for _, hit in ipairs(scan(fh:read("a"))) do
                    if not KNOWN[rel .. " " .. hit.name] then bad[#bad + 1] = rel .. ":" .. hit.line .. ": " .. hit.name .. " is filled by hand" end
                end
                fh:close()
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "\n  " .. table.concat(bad, "\n  "))
end

function tests.scan_flagsAPanelFilledByHand()
    H.assertEq(#scan("ns.SetRoundedRectFill(p, 0.08, 0.08, 0.09, 1, true)\nns.SetRoundedRectBorderEdgeShown(p, false)\n"), 1)
    H.assertEq(#scan("ns.SetRoundedRectFill(b, 0, 0, 0, 0, true)\nns.SetRoundedRectBorderEdgeShown(b, false)\n"), 0)
end

local pass, fail, failures = H.runSuite("HandPanels", tests)
return { pass = pass, fail = fail, failures = failures }

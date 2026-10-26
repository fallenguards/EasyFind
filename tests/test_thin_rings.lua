-- The rounded border art's ring is 2 px of a 256 px texture, its corner a
-- quarter of it: on a frame whose corners are under 16 px (a bar height
-- under 32) the line draws under a pixel, gone on the edges and broken on
-- the corners. A frame given a ring color there must hide the art's ring
-- and draw one with ns.CreateRingedWell. KNOWN: older frames, to convert.
local H = require("Harness")

local KNOWN = {
    ["Apps/Calc/Popup.lua frame"] = true,
    ["Apps/Notes/Notes.lua frame.palette"] = true,
    ["Shared/Utils.lua self"] = true,
}

local function esc(s) return (s:gsub("%p", "%%%0")) end

-- Frames of one file's text with a small corner and a ring painted on
-- purpose, the art's ring still shown: { "expr", ... }.
local function scan(text)
    local hits = {}
    for expr, arg in text:gmatch("SetRoundedRectBarHeight%(%s*([%w_%.]+)%s*,%s*([^\n]-)%)%s*\n") do
        local least
        for n in arg:gmatch("%d+") do
            n = tonumber(n)
            if not least or n < least then least = n end
        end
        -- A corner named by a file constant (the hover tip's CORNER = 6).
        for word in arg:gmatch("[%a_][%w_]*") do
            local n = tonumber(text:match("local%s+" .. word .. "%s*=%s*(%d+)"))
            if n and (not least or n < least) then least = n end
        end
        local e = esc(expr)
        local ringed = text:find("SetRoundedRectBorderColor%(%s*" .. e .. "%s*,")
            or text:find("SetCalculatorRoundedFill%(%s*" .. e .. "%s*,")
        local hidden = text:find("SetRoundedRectBorderEdgeShown%(%s*" .. e .. "%s*,%s*false")
            or text:find("SetRoundedRectRingShown%(%s*" .. e .. "%s*,%s*false")
            or text:find("HideCalculatorRoundedBorder%(%s*" .. e)
        if least and least < 32 and ringed and not hidden then hits[#hits + 1] = expr end
    end
    return hits
end

local tests = {}

function tests.noSmallFrameShowsTheArtRing()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                checked = checked + 1
                for _, expr in ipairs(scan(fh:read("a") .. "\n")) do
                    if not KNOWN[rel .. " " .. expr] then bad[#bad + 1] = rel .. ": " .. expr end
                end
                fh:close()
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "a ring under a pixel; use ns.CreateRingedWell:\n  " .. table.concat(bad, "\n  "))
end

function tests.scan_flagsARingedSmallFrame()
    local src = "ns.CreateRoundedRectBorder(well)\nns.SetRoundedRectBarHeight(well, 10)\n"
        .. "ns.SetRoundedRectBorderColor(well, 1, 1, 1, 1)\n"
    H.assertEq(#scan(src), 1)
end

function tests.scan_readsANamedCorner()
    local src = "local CORNER = 6\nns.SetRoundedRectBarHeight(tip, CORNER)\n"
        .. "ns.SetRoundedRectBorderColor(tip, 1, 1, 1, 0.45)\n"
    H.assertEq(#scan(src), 1, "the hover tip's ring vanished at a named 6 px corner (2026-10-26)")
end

-- Its corner is set on `tip` and its ring painted on `self`, past the scan.
function tests.hoverTip_drawsItsEdgeAsAShape()
    local fh = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "r"))
    local text = fh:read("a")
    fh:close()
    H.assertTrue(text:find("SetRoundedRectBorderEdgeShown(tip, false)", 1, true) ~= nil, "the art ring hidden")
    H.assertTrue(text:find("SetRoundedRectFill(self.ring,", 1, true) ~= nil, "the edge painted as a shape")
end

function tests.scan_acceptsAHiddenRingOrABigCorner()
    H.assertEq(#scan("ns.SetRoundedRectBarHeight(w, 10)\nns.SetRoundedRectBorderColor(w, 1, 1, 1)\n"
        .. "ns.SetRoundedRectBorderEdgeShown(w, false)\n"), 0)
    H.assertEq(#scan("ns.SetRoundedRectBarHeight(bar, 40)\nns.SetRoundedRectBorderColor(bar, 1, 1, 1)\n"), 0)
    H.assertEq(#scan("ns.SetRoundedRectBarHeight(card, 8)\n"), 0)
end

local pass, fail, failures = H.runSuite("ThinRings", tests)
return { pass = pass, fail = fail, failures = failures }

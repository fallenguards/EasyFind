-- Our windows sit above the action bars: in MEDIUM, the bars' strata,
-- frame levels interleave and the bars cut into a window, its back under
-- the buttons and its boxes over them (the GPS pop-out, 2026-10-26). Only
-- the minimap button belongs there, among the minimap's own.
local H = require("Harness")

local KNOWN = { ["Core/Main.lua mmBtn"] = true }

local function scan(text)
    local hits = {}
    for frame in text:gmatch('([%w_%.]+):SetFrameStrata%("MEDIUM"%)') do hits[#hits + 1] = frame end
    return hits
end

local tests = {}

function tests.nothingOfOursSitsWithTheActionBars()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                checked = checked + 1
                for _, frame in ipairs(scan(fh:read("a"))) do
                    if not KNOWN[rel .. " " .. frame] then bad[#bad + 1] = rel .. ": " .. frame end
                end
                fh:close()
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "a frame in MEDIUM, under and over the action bars; use HIGH:\n  " .. table.concat(bad, "\n  "))
end

function tests.scan_findsAMediumFrame()
    H.assertEq(scan('dockFrame:SetFrameStrata("MEDIUM")\n')[1], "dockFrame")
    H.assertEq(#scan('f:SetFrameStrata("HIGH")\n'), 0)
end

local pass, fail, failures = H.runSuite("WindowStrata", tests)
return { pass = pass, fail = fail, failures = failures }

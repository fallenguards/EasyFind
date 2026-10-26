-- A frame meant to hear hover alone (SetMouseMotionEnabled) still took
-- clicks once its OnEnter was hooked: the GPS window's trip rows covered
-- most of the folded window and a press there never dragged it
-- (/efd popdrag, 2026-10-26). Each such frame turns its clicks off right
-- after, and hooks no mouse script past that point.
local H = require("Harness")

local MOUSE_SCRIPT = { OnEnter = true, OnLeave = true, OnMouseDown = true, OnMouseUp = true }

local function scan(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local bad = {}
    for i, line in ipairs(lines) do
        local name = line:match("([%w_%.]+):SetMouseMotionEnabled%(true%)")
        if name then
            local esc = name:gsub("%p", "%%%0")
            local off = false
            for j = i, math.min(#lines, i + 2) do
                if lines[j]:find(esc .. ":SetMouseClickEnabled%(false%)") then off = true end
            end
            if not off then bad[#bad + 1] = i .. ": " .. name .. " keeps its clicks" end
            for j = i + 1, math.min(#lines, i + 15) do
                local script = lines[j]:match(esc .. ':%a+Script%("(On%a+)"')
                if script and MOUSE_SCRIPT[script] then bad[#bad + 1] = j .. ": " .. name .. " " .. script .. " after it" end
            end
        end
    end
    return bad
end

local tests = {}

function tests.motionOnlyFramesTakeNoClicks()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                checked = checked + 1
                for _, hit in ipairs(scan(fh:read("a"))) do bad[#bad + 1] = rel .. ":" .. hit end
                fh:close()
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "\n  " .. table.concat(bad, "\n  "))
end

function tests.scan_flagsAFrameThatKeepsItsClicks()
    H.assertEq(#scan('row:SetMouseMotionEnabled(true)\nrow:HookScript("OnEnter", f)\n'), 2)
    H.assertEq(#scan('row:HookScript("OnEnter", f)\nrow:SetMouseMotionEnabled(true)\nrow:SetMouseClickEnabled(false)\n'), 0)
end

local pass, fail, failures = H.runSuite("MotionOnlyFrames", tests)
return { pass = pass, fail = fail, failures = failures }

-- A themed button (ns.CreateModernButton) paints its states from its own
-- OnEnter and OnLeave; a SetScript on either replaced them, and the
-- quicklist's Macro buttons never took the Classic red on hover
-- (2026-10-26). Extra behavior hooks them instead (HookScript). The
-- button a name holds is its nearest assignment above the SetScript.
-- KNOWN: buttons that repaint every state themselves.
local H = require("Harness")

local KNOWN = {
    -- Segmented preset buttons: PaintPresetButton paints each state.
    ["Apps/Options/OptionsPanel.lua btn"] = true,
}

local function scan(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local bad = {}
    for i, line in ipairs(lines) do
        local name, script = line:match('([%w_%.]+):SetScript%("(On%a+)"')
        if name and (script == "OnEnter" or script == "OnLeave") then
            local esc = name:gsub("%p", "%%%0")
            for j = i - 1, math.max(1, i - 60), -1 do
                local rhs = lines[j]:match("^%s*local%s+" .. esc .. "%s*=%s*(.*)$") or lines[j]:match("^%s*" .. esc .. "%s*=%s*(.*)$")
                if rhs then
                    if rhs:find("CreateModernButton%(") then bad[#bad + 1] = name .. " " .. script end
                    break
                end
            end
        end
    end
    return bad
end

local tests = {}

function tests.noThemedButtonLosesItsOwnHoverPaint()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                checked = checked + 1
                for _, hit in ipairs(scan(fh:read("a"))) do
                    if not KNOWN[rel .. " " .. hit:match("^(%S+)")] then bad[#bad + 1] = rel .. ": " .. hit end
                end
                fh:close()
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "use HookScript:\n  " .. table.concat(bad, "\n  "))
end

-- Built inside a shown page a button hears no OnShow, so its first paint
-- comes after its paint state exists, or the Classic red waits for a hover.
function tests.aNewButtonPaintsOnceItsPaintStateExists()
    local fh = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "r"))
    local text = fh:read("a")
    fh:close()
    local state = assert(text:find("btn._efPaintState = PaintState", 1, true))
    local paint = text:find("ns.PaintButtonRamp(btn)", state, true)
    local done = assert(text:find("\n    return btn\n", state))
    H.assertTrue(paint ~= nil and paint < done, "CreateModernButton repaints after setting _efPaintState")
end

function tests.scan_flagsAReplacedHover()
    H.assertEq(#scan('row.macroBtn = CreateModernButton(row, "Macro")\nrow.macroBtn:SetScript("OnEnter", f)\n'), 1)
    H.assertEq(#scan('row.macroBtn = CreateModernButton(row, "Macro")\nrow.macroBtn:HookScript("OnEnter", f)\n'), 0)
    H.assertEq(#scan('local btn = CreateFrame("Button")\nbtn:SetScript("OnEnter", f)\n'), 0, "a plain button")
end

local pass, fail, failures = H.runSuite("ModernButtonScripts", tests)
return { pass = pass, fail = fail, failures = failures }

-- Under the Classic skin the Notes window's buttons are the red 1.x panel
-- buttons; a fill set for hover or an engaged state sits under that art,
-- so the toolbar showed no hover and only a text color when a style was on
-- (2026-11-03). UI.PaintClassicButton paints the glow and the pushed art.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Extract(src, header)
    local s = assert(src:find(header, 1, true), header)
    local indent = src:sub(src:sub(1, s):find("[^\n]*$"), s - 1)
    local _, e = assert(src:find("\n" .. indent .. "end\n", s, true))
    return src:sub(s, e)
end

local tests = {}

function tests.classicButtons_glowOnHover_pushInWhenEngaged()
    local src = Read("Apps/Notes/Notes.lua")
    local painted, shown = {}, nil
    local ns = { BTN_FILL_NORMAL = {}, BTN_FILL_HOVER = {}, BTN_FILL_PRESSED = {},
                 ClassicLook = function() return true end, SetRoundedRectBorderShown = function() end }
    ns.PaintRedButton = function(btn, fill)
        painted[#painted + 1] = fill
        btn._efRed = btn._efRed or { hl = { SetShown = function(_, v) shown = v end } }
    end
    local UI = {}
    assert(load(Extract(src, "function UI.PaintClassicButton(btn, hovered, pressed)"), "=Paint", "t",
        setmetatable({ UI = UI, ns = ns }, { __index = _G })))()
    local btn = {}
    H.assertTrue(UI.PaintClassicButton(btn, true, false))
    H.assertEq(painted[#painted], ns.BTN_FILL_HOVER, "the glow under the mouse")
    UI.PaintClassicButton(btn, false, true)
    H.assertEq(painted[#painted], ns.BTN_FILL_PRESSED, "pushed in while engaged")
    H.assertFalse(shown, "no glow on an engaged button at rest")
    UI.PaintClassicButton(btn, true, true)
    H.assertTrue(shown, "an engaged button under the mouse glows too")
    UI.PaintClassicButton(btn, false, false)
    H.assertEq(painted[#painted], ns.BTN_FILL_NORMAL)
end

function tests.everyStatefulButtonPaintsThroughIt()
    local src = Read("Apps/Notes/Notes.lua")
    local refresh = Extract(src, "function UI:RefreshEasyNotesToolbarButton(btn)")
    H.assertTrue(refresh:find("UI.PaintClassicButton(btn, btn._hover, active)", 1, true) ~= nil, "the formatting toolbar")
    local auto = Extract(src, "function UI:RefreshEasyNotesAutoResizeButton()")
    H.assertTrue(auto:find("UI.PaintClassicButton(frame.autoResizeButton", 1, true) ~= nil, "the auto-resize toggle")
    -- A hover script that sets a fill goes through the Classic painter first.
    local bad = {}
    for indent, at in src:gmatch("\n(%s*)[%w_.]+:[SH][eo][to][Sk]cript%(\"On[EL][ne][ta][ev][re]?\", function%(()") do
        local lineEnd = src:find("\n", at, true) or #src
        local body = src:sub(at, lineEnd)
        if not body:find("end%)") then
            local _, e = src:find("\n" .. indent .. "end%)", at)
            body = src:sub(at, e or at)
        end
        if body:find("SetRoundedRectFill(", 1, true) and not body:find("PaintClassicButton", 1, true) then
            local line = select(2, src:sub(1, at):gsub("\n", "\n")) + 1
            bad[#bad + 1] = line
        end
    end
    H.assertEq(#bad, 0, "hover fills that skip the Classic painter at lines " .. table.concat(bad, ", "))
end

local pass, fail, failures = H.runSuite("NotesClassicButtons", tests)
return { pass = pass, fail = fail, failures = failures }

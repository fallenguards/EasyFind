-- The map tab's text size stepped live (MapSearch/MapTab.lua StepFontSize):
-- Ctrl+wheel over the map's GPS page and Ctrl+plus, minus or 0 in its search
-- box. Steps land on the menu's sizes, never past them (the sizes the panel
-- is checked to fit), and the menu ticks the nearest.
local H = require("Harness")

local function Load(size)
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/MapTab.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local sizes = assert(src:match("\n(local FONT_SIZES = [^\n]+)"), "FONT_SIZES")
    local s = assert(src:find("local function FontRows(onPick)", 1, true), "FontRows")
    local e = assert(src:find("local function MapOptionsDefs", s, true), "StepFontSize's end")
    local picked = 0
    local env = setmetatable({
        EasyFind = { db = { mapTabFontSize = size } }, MapTab = {}, MENU_CHECK = "check",
        L = setmetatable({}, { __index = function(_, k) return k end }),
        panel = { OnFontPicked = function() picked = picked + 1 end },
    }, { __index = _G })
    local chunk = sizes .. "\nlocal function FontScale() return EasyFind.db.mapTabFontSize or 1 end\n"
        .. src:sub(s, e - 1) .. "\nreturn FontRows"
    local fontRows = assert(load(chunk, "=MapTab.lua StepFontSize", "t", env))()
    return env.MapTab.StepFontSize, env.EasyFind.db, function() return picked end, fontRows
end

local tests = {}

function tests.eachNotchIsAStepOnTheMenusGrid()
    local step, db, picked = Load(1)
    step(1)
    step(1)
    H.assertEq(db.mapTabFontSize, 1.1)
    step(1)
    H.assertEq(db.mapTabFontSize, 1.15, "the menu's Large")
    H.assertEq(picked(), 3, "applied each time")
end

function tests.neverPastTheMenusSizes()
    local step, db, picked = Load(1.3)
    step(1)
    H.assertEq(db.mapTabFontSize, 1.3)
    H.assertEq(picked(), 0, "nothing changed, nothing applied")
    step, db = Load(0.85)
    step(-1)
    H.assertEq(db.mapTabFontSize, 0.85)
end

function tests.zeroIsNormalAgain()
    local step, db = Load(1.25)
    step(0)
    H.assertEq(db.mapTabFontSize, 1)
end

function tests.theMenuTicksTheNearest()
    local _, _, _, fontRows = Load(1.1)
    local ticked = {}
    for _, row in ipairs(fontRows(function() end)()) do
        if row.icon then ticked[#ticked + 1] = row.text end
    end
    H.assertEq(table.concat(ticked, ","), "OPT_FONT_LARGE")
end

local pass, fail, failures = H.runSuite("MapFontStep", tests)
return { pass = pass, fail = fail, failures = failures }

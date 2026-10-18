-- Tests for the GPS button on search bar rows (Render.ApplyGPSButton in
-- Search/Results/Render/Layout.lua): just left of a place's own icon, the
-- name stopping short of it. The rows are secure buttons, so nothing of the
-- row is ever anchored to the button.

local H = require("Harness")

local function Region(name)
    local r = { name = name, points = {}, shown = true }
    function r:SetPoint(point, rel, relPoint, x, y)
        self.points[point] = { rel = rel, relPoint = relPoint, x = x, y = y }
    end
    function r:ClearAllPoints() self.points = {} end
    function r:IsShown() return self.shown end
    function r:Show() self.shown = true end
    function r:Hide() self.shown = false end
    return r
end

local function Load()
    local Render = { INDENT_PX = 16, LINE_X_OFF = 6, MAX_DEPTH = 6, IsBossResultData = function() return false end }
    local navigable = {}
    local ns = {
        Utils = { tconcat = table.concat },
        ResultRender = Render,
        ResultIcons = {
            IsMenuBarSpecificIconData = function() return false end,
            IsRightSideIconData = function(d) return d.mapSearchResult == true end,
        },
        GPS = {
            RowButton = function(row, data)
                if not navigable[data] then
                    if row.gpsBtn then row.gpsBtn:Hide() end
                    return nil
                end
                row.gpsBtn = row.gpsBtn or Region("gpsBtn")
                row.gpsBtn:Show()
                return row.gpsBtn
            end,
        },
    }
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Render/Layout.lua", "rb"))
    local src = f:read("*a")
    f:close()
    assert(load(src, "=Layout.lua", "t", setmetatable({}, { __index = _G })))("EasyFind", ns)
    return Render, navigable
end

local function Row()
    local row = Region("row")
    row.icon, row.text, row.pathSubtext = Region("icon"), Region("text"), Region("pathSubtext")
    return row
end

local STATE = { theme = { iconSize = 15 } }
local tests = {}

function tests.aPlaceGetsTheButtonLeftOfItsIcon()
    local Render, navigable = Load()
    local row, data = Row(), { mapSearchResult = true, name = "Booty Bay" }
    navigable[data] = true
    Render.ApplyGPSButton(row, { data = data }, STATE)
    local at = row.gpsBtn.points.RIGHT
    H.assertTrue(row.gpsBtn:IsShown())
    H.assertTrue(at and at.rel == row.icon and at.relPoint == "LEFT", "hangs from the icon's left")
end

function tests.nothingOfTheRowHangsFromTheButton()
    local Render, navigable = Load()
    local row, data = Row(), { mapSearchResult = true }
    navigable[data] = true
    Render.ApplyGPSButton(row, { data = data }, STATE)
    for _, region in ipairs({ row.icon, row.text, row.pathSubtext }) do
        for point, p in pairs(region.points) do
            H.assertTrue(p.rel ~= row.gpsBtn, region.name .. " " .. point .. " anchored to the button")
        end
    end
    H.assertTrue(row.text.points.RIGHT.x <= -(15 + 4), "the name stops short of the button")
end

function tests.otherRowsHideIt()
    local Render, navigable = Load()
    local row, place = Row(), { mapSearchResult = true }
    navigable[place] = true
    Render.ApplyGPSButton(row, { data = place }, STATE)
    Render.ApplyGPSButton(row, { data = { name = "Frostbolt" } }, STATE)
    H.assertFalse(row.gpsBtn:IsShown(), "a pooled row drops it for a spell")
    Render.ApplyGPSButton(row, { data = place, isSectionHeader = true }, STATE)
    H.assertFalse(row.gpsBtn:IsShown(), "never on a header")
end

local pass, fail, failures = H.runSuite("GPSRowButton", tests)
return { pass = pass, fail = fail, failures = failures }

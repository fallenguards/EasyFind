-- The map page's steps (Apps/GPS/GPS.lua FitPage): the rows' cast buttons
-- (the item or spell a teleport step uses) are placed again inside the
-- fitted list. FitPage once rendered again instead; Render sets the list's
-- full height and calls FitPage, so steps taller than the room looped until
-- the stack overflowed, freezing the game on every map open.
local H = require("Harness")

local function LoadFitPage(placed)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local s = assert(src:find("local function FitPage(self, hasRoute)", 1, true), "FitPage")
    local e = assert(src:find("\nlocal function Rule(frame)", s, true), "FitPage's end")
    local route = { active = 2, steps = { { kind = "walk" }, { kind = "teleport", itemID = 6948 } } }
    local env = setmetatable({
        Route = function() return route end, mmax = math.max,
        SetupCast = function(btn, step, active, ahead) placed[#placed + 1] = { btn, step, active, ahead } end,
    }, { __index = _G })
    return assert(load(src:sub(s, e) .. "\nreturn FitPage", "=GPS.lua FitPage", "t", env))(), route
end

local function Row(index, shown)
    return { index = index, cast = "cast " .. index, IsShown = function() return shown end }
end

local function Page(listH, contentH, route)
    local list = {}
    function list:GetTop() return 400 end
    function list:GetHeight() return listH end
    function list:SetHeight(h) listH = h end
    function list:SetClipsChildren() end
    local page = { list = list, contentHeight = contentH, fitRoute = route, rows = { Row(1, true), Row(2, true) },
        footRule = { GetTop = function() return 100 end } }
    return page, function() return listH end
end

local tests = {}

function tests.theButtonsArePlacedInsideTheFittedList()
    local placed = {}
    local FitPage, route = LoadFitPage(placed)
    local page, height = Page(1, 200, route)
    FitPage(page, true)
    H.assertEq(height(), 200)
    H.assertEq(#placed, 2, "each shown step's button")
    H.assertEq(placed[2][1], "cast 2")
    H.assertTrue(placed[2][3], "the step that is up")
    H.assertFalse(placed[1][3])
    H.assertTrue(placed[2][4], "still ahead: its button shows")
    H.assertFalse(placed[1][4], "taken: none")
end

-- Render's own shape: the list at its full height, then FitPage.
function tests.stepsTallerThanTheRoomRenderOnce()
    local placed = {}
    local FitPage, route = LoadFitPage(placed)
    local page, height = Page(1, 600, route)
    local renders = 0
    function page:Render()
        renders = renders + 1
        if renders > 5 then error("FitPage rendered again") end
        self.list:SetHeight(self.contentHeight)
        FitPage(self, true)
    end
    page:Render()
    H.assertEq(renders, 1)
    H.assertEq(height(), 292, "the room above the foot rule")
end

-- Every step still ahead has its button, the one that is up bright and a
-- later one dimmed (the teleport after a stop showed none, 2026-10-27).
function tests.aLaterStepsButtonShowsDimmed()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    H.assertTrue(src:find("local function SetupCast%(btn, step, active, ahead%)") ~= nil)
    H.assertTrue(src:find("if not %(active or ahead%) or not %(spellID or itemID%)") ~= nil)
    H.assertTrue(src:find("btn:SetAlpha%(active and 1 or 0%.55%)") ~= nil, "a later step's dimmed")
    local calls = 0
    for args in src:gmatch("SetupCast(%b())") do
        if args:find("^%(row%.cast") then
            local _, commas = args:gsub(",", "")
            H.assertEq(commas, 3, "the call says which steps are still ahead: " .. args)
            calls = calls + 1
        end
    end
    H.assertEq(calls, 4, "every list's rows")
end

function tests.noRouteNoButtons()
    local placed = {}
    local FitPage, route = LoadFitPage(placed)
    local page = Page(1, 0, route)
    FitPage(page, false)
    H.assertEq(#placed, 0)
end

local pass, fail, failures = H.runSuite("GPSPageCast", tests)
return { pass = pass, fail = fail, failures = failures }

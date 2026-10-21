-- Tests for the "Finding a way" label (Apps/GPS/GPS.lua Planner.Show and
-- Planner.Tick): its dots count one to three while a plan runs.

local H = require("Harness")

local tests = {}

local function Planner(fmt)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local Planner = {", 1, true), "Planner not in GPS.lua")
    local t = assert(src:find("function Planner.Tick()", s, true), "Planner.Tick not after it")
    local _, e = src:find("\nend\r?\n", t)
    local GPS = { planning = { name = "Gadgetzan" } }
    local env = setmetatable({
        GPS = GPS,
        L = { GPS_PLANNING_FMT = fmt },
        sformat = string.format,
        CreateFrame = function() return {} end,
        wipe = function(tbl) for k in pairs(tbl) do tbl[k] = nil end end,
    }, { __index = _G })
    local P = assert(load(src:sub(s, e) .. "\nreturn Planner", "=GPS.lua Planner", "t", env))()
    return P, GPS
end

local function Label()
    local fs = { text = "" }
    function fs:SetText(t) self.text = t end
    function fs:GetText() return self.text end
    return fs
end

function tests.theDotsCountOneToThreeAndAgain()
    local P = Planner("Finding a way to %s...")
    local fs = Label()
    P.Show(fs)
    H.assertEq(fs.text, "Finding a way to Gadgetzan.")
    P.Tick()
    H.assertEq(fs.text, "Finding a way to Gadgetzan..")
    P.Tick()
    H.assertEq(fs.text, "Finding a way to Gadgetzan...")
    P.Tick()
    H.assertEq(fs.text, "Finding a way to Gadgetzan.", "back to one")
end

function tests.aLocaleEllipsisMakesWayForTheDots()
    local P = Planner("Weg nach %s\226\128\166")
    local fs = Label()
    P.Show(fs)
    H.assertEq(fs.text, "Weg nach Gadgetzan.")
end

function tests.aLabelSayingSomethingElseIsLeftAlone()
    local P = Planner("Finding a way to %s...")
    local fs = Label()
    P.Show(fs)
    fs:SetText("To Gadgetzan")
    P.Tick()
    H.assertEq(fs.text, "To Gadgetzan")
end

function tests.thePlanDoneStopsTheCount()
    local P, GPS = Planner("Finding a way to %s...")
    local cancelled
    P.dotTicker = { Cancel = function() cancelled = true end }
    P.Show(Label())
    GPS.planning = nil
    P.Tick()
    H.assertTrue(cancelled, "the ticker stops")
    H.assertNil(P.dotTicker)
    H.assertNil(next(P.labels), "no label is held")
end

local pass, fail, failures = H.runSuite("GPSPlanningDots", tests)
return { pass = pass, fail = fail, failures = failures }

-- Tests for the time still to go (Apps/GPS/GPS.lua EtaText).

local H = require("Harness")

-- EtaText, cut from GPS.lua (the rest of the file needs the whole client).
local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("-- The time still to go in minutes", 1, true), "EtaText not in GPS.lua")
    local e = assert(src:find("GPS.EtaText = EtaText", s, true), "end of EtaText not found")
    local env = setmetatable({
        L = { GPS_UNIT_HR = "%d hr", GPS_UNIT_MIN = "%d min" },
        sformat = string.format, mfloor = math.floor,
    }, { __index = _G })
    return assert(load(src:sub(s, e - 1) .. "\nreturn EtaText", "=GPS.lua EtaText", "t", env))()
end

local tests = {}

function tests.underAMinute_readsLessThanOne()
    local EtaText = Load()
    H.assertEq(EtaText(5), "<1 min")
    H.assertEq(EtaText(59), "<1 min")
    H.assertEq(EtaText(60), "1 min")
    H.assertEq(EtaText(89), "1 min")
    H.assertEq(EtaText(90), "2 min")
end

function tests.pastAnHour_hoursThenMinutes()
    local EtaText = Load()
    H.assertEq(EtaText(3600), "1 hr")
    H.assertEq(EtaText(3600 + 5 * 60), "1 hr 5 min")
end

local pass, fail, failures = H.runSuite("GPSEta", tests)
return { pass = pass, fail = fail, failures = failures }

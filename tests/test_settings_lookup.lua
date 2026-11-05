-- Settings.GetSetting scans every registered setting on each call
-- (Blizzard_SettingsPanel GetSetting). The settings walk and the setting rows
-- asked it hundreds of times, and a player with many addons got "script ran
-- too long" from that scan (2026-11-05). Every lookup goes through
-- Utils.FindSetting: one pass over the registry fills a map, refilled when two
-- seconds old.
local H = require("Harness")

local TOCS = {
    "EasyFind.toc", "Apps/Calc/EasyFind_Calc.toc", "Apps/Clipboard/EasyFind_Clipboard.toc",
    "Apps/Guide/EasyFind_Guide.toc", "Apps/Icons/EasyFind_Icons.toc", "Apps/Items/EasyFind_Items.toc",
    "Apps/Onboarding/EasyFind_Onboarding.toc", "Apps/Options/EasyFind_Options.toc",
    "Apps/Quicklists/EasyFind_Quicklists.toc", "Apps/Settings/EasyFind_Settings.toc",
    "Apps/Snippets/EasyFind_Snippets.toc",
}

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"), path)
    local src = f:read("*a")
    f:close()
    return src
end

-- The real Utils.FindSetting, cut from Shared/Utils.lua and run on a fake registry.
local function Load(registry, clock)
    local src = Read("Shared/Utils.lua")
    local s = assert(src:find("do\r?\nlocal settingByVariable", 1))
    local _, e = assert(src:find("return settingByVariable%[variable%]\r?\nend\r?\nend", s))
    local Utils = {}
    local env = setmetatable({ Utils = Utils, GetTime = function() return clock.now end,
        wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
        SettingsPanel = { settings = registry } }, { __index = _G })
    assert(load("local Utils, GetTime, wipe = Utils, GetTime, wipe\n" .. src:sub(s, e), "=Utils.lua FindSetting", "t", env))()
    return Utils.FindSetting
end

local reads = 0
local function Setting(variable)
    return { GetVariable = function() reads = reads + 1 return variable end }
end

local tests = {}

function tests.manyLookups_readTheRegistryOnce()
    local registry = {}
    for i = 1, 1000 do registry[Setting("var" .. i)] = "category" end
    local clock = { now = 10 }
    local Find = Load(registry, clock)
    reads = 0
    for i = 1, 300 do
        local hit = Find("var" .. i)
        H.assertNotNil(hit, "var" .. i)
        H.assertEq(hit.GetVariable(), "var" .. i)
        H.assertEq(Find("missing" .. i), nil, "an unregistered variable")
    end
    H.assertEq(reads, 1000 + 300, "one pass over 1000, plus the 300 checks above")
end

function tests.aSettingRegisteredLater_isFoundOnceTheMapIsTwoSecondsOld()
    local registry = { [Setting("first")] = "category" }
    local clock = { now = 10 }
    local Find = Load(registry, clock)
    H.assertNotNil(Find("first"))
    registry[Setting("late")] = "category"
    clock.now = 11
    H.assertEq(Find("late"), nil, "the map is a second old")
    clock.now = 12
    H.assertNotNil(Find("late"), "refilled at two seconds")
end

function tests.noCodeCallsTheScanningLookup()
    local offenders = {}
    for _, toc in ipairs(TOCS) do
        local files, ok = H.TocFiles(toc)
        H.assertTrue(ok, toc .. " readable")
        for _, file in ipairs(files) do
            file = file:gsub("\\", "/")
            if file ~= "Shared/Utils.lua" then
                local no = 0
                for line in (Read(file) .. "\n"):gmatch("([^\n]*)\n") do
                    no = no + 1
                    local code = line:gsub("%-%-.*$", "")
                    if code:find("Settings%.GetSetting") then offenders[#offenders + 1] = file .. ":" .. no end
                end
            end
        end
    end
    H.assertEq(table.concat(offenders, ", "), "", "Settings.GetSetting outside Utils.FindSetting")
end

local pass, fail, failures = H.runSuite("SettingsLookup", tests)
return { pass = pass, fail = fail, failures = failures }

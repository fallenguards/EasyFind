-- A map place's name is a locale key (POI_<name>): one with no key showed
-- the key itself in its row ("POI_RIDING_TRAINER", and 107 creature names
-- used as place names, 2026-11-20).
local H = require("Harness")

local function read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local function KeyOf(name)
    return "POI_" .. name:upper():gsub("&", "AND"):gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
end

-- POIName as the game has it: L answers a missing key with the key.
local function POIName(keys)
    local src = read("Database/StaticLocations.lua")
    local _, stop = assert(src:find("ns.POIName = POIName", 1, true))
    local L = setmetatable(keys, { __index = function(_, k) return k end })
    local ns = { L = L }
    assert(load(src:sub(1, stop), "=StaticLocations.lua head", "t", {
        rawget = rawget, string = string,
    }))("EasyFind", ns)
    return ns.POIName
end

local tests = {}

function tests.everyShippedPlaceName_hasItsKey()
    local keyed = {}
    for key in read("Locales/enUS.lua"):gmatch('L%["(POI_[%w_]+)"%]') do keyed[key] = true end
    local missing = {}
    for _, flavor in ipairs({ "", "_Retail", "_Forever", "_Era", "_TBC", "_Mists" }) do
        local path = "Database/StaticLocations" .. flavor .. ".lua"
        for name in read(path):gmatch('POIName%("([^"]+)"%)') do
            if not keyed[KeyOf(name)] and not missing[name] then
                missing[name] = true
                missing[#missing + 1] = path .. ": " .. name
            end
        end
    end
    H.assertEq(#missing, 0, "place names with no key in Locales/enUS.lua: " .. table.concat(missing, ", ", 1, math.min(#missing, 8)))
end

function tests.aNameWithItsKey_readsTheLocale()
    H.assertEq(POIName({ POI_INNKEEPER = "Gastwirt" })("Innkeeper"), "Gastwirt")
end

function tests.aNameWithNoKey_showsAsWritten()
    H.assertEq(POIName({})("Donaal Downbreeze"), "Donaal Downbreeze")
end

local pass, fail, failures = H.runSuite("PlaceNames", tests)
return { pass = pass, fail = fail, failures = failures }

-- Every translation keeps its English line's placeholders (%s, %d, %.1f),
-- the same ones in the same order: a missing or swapped one errors in that
-- locale's client alone, where the English one runs fine.
local H = require("Harness")

local LOCALES = { "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }

local function Load(name)
    local f = assert(io.open(H.ADDON_ROOT .. "/Locales/" .. name .. ".lua", "rb"))
    local out = {}
    for line in f:read("*a"):gmatch("[^\n]+") do
        local key, value = line:match('^L%["([^"]+)"%]%s*=%s*"(.*)"%s*\r?$')
        if key then out[key] = value end
    end
    f:close()
    return out
end

local function Specs(s)
    local out = {}
    for spec in s:gsub("%%%%", ""):gmatch("%%[-+ #0]*%d*%.?%d*[sdifgxXc]") do out[#out + 1] = spec end
    return table.concat(out, " ")
end

local tests = {}

function tests.everyLocaleKeepsTheEnglishPlaceholders()
    local en = Load("enUS")
    local bad = {}
    for _, loc in ipairs(LOCALES) do
        local t = Load(loc)
        for key, value in pairs(en) do
            if t[key] and Specs(t[key]) ~= Specs(value) then
                bad[#bad + 1] = loc .. " " .. key .. ": " .. Specs(value) .. " / " .. Specs(t[key])
            end
        end
    end
    table.sort(bad)
    H.assertEq(#bad, 0, "\n  " .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("LocalePlaceholders", tests)
return { pass = pass, fail = fail, failures = failures }

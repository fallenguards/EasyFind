-- The CI Localization job's two checks, run in the suite: every locale holds
-- enUS's key set, and every literal L lookup in a tracked .lua file outside Locales/
-- and dev/ (tests too, as CI scans them) is an enUS key. A test line naming
-- a dead key failed CI after the push (4.2.0, 2026-11-02).
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local function Keys(path)
    local out = {}
    for line in Read(path):gmatch("[^\n]+") do
        local key = line:match('^L%["([^"]+)')
        if key then out[key] = true end
    end
    return out
end

local function TrackedLua()
    local out = {}
    local p = assert(io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "*.lua"'))
    for path in p:lines() do
        path = path:gsub("\r$", "")
        if not (("/" .. path):find("/Locales/", 1, true) or ("/" .. path):find("/dev/", 1, true)) then
            out[#out + 1] = path
        end
    end
    p:close()
    return out
end

local tests = {}

function tests.everyLocaleHoldsTheEnglishKeySet()
    local en = Keys("Locales/enUS.lua")
    local bad = {}
    for _, loc in ipairs({ "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }) do
        local t = Keys("Locales/" .. loc .. ".lua")
        for key in pairs(en) do if not t[key] then bad[#bad + 1] = loc .. " lacks " .. key end end
        for key in pairs(t) do if not en[key] then bad[#bad + 1] = loc .. " strays " .. key end end
    end
    table.sort(bad)
    H.assertEq(#bad, 0, "\n  " .. table.concat(bad, "\n  "))
end

function tests.everyNamedKeyIsAnEnglishKey()
    local en = Keys("Locales/enUS.lua")
    local files = TrackedLua()
    H.assertTrue(#files > 100, "the tracked file list came back")
    local bad, seen = {}, {}
    for _, path in ipairs(files) do
        for key in Read(path):gmatch('L%["([^"\n]+)"%]') do
            if not en[key] and not seen[path .. key] then
                seen[path .. key] = true
                bad[#bad + 1] = path .. ": " .. key
            end
        end
    end
    table.sort(bad)
    H.assertEq(#bad, 0, "\n  " .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("LocaleRefs", tests)
return { pass = pass, fail = fail, failures = failures }

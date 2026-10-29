-- Guardrail: a companion's data file shipped for a client is turned on
-- there. The item catalog's Era, TBC and Mists data loaded, but its
-- switch still said "off on every classic client" (2026-10-29).
local H = require("Harness")

local CLIENTS = {
    { name = "retail",  tags = { standard = true, mainline = true }, project = 1,  build = "12.1.5", interface = 120105 },
    { name = "Forever", tags = { camelot = true, mainline = true },  project = nil, build = "1.60.1", interface = 16001 },
    { name = "Era",     tags = { vanilla = true },                   project = 2,  build = "1.15.9", interface = 11509 },
    { name = "TBC",     tags = { tbc = true },                       project = 5,  build = "2.5.5",  interface = 20505 },
    { name = "Mists",   tags = { mists = true },                     project = 19, build = "5.5.4",  interface = 50504 },
}

local function ClientCaps(client)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env._G = env
    env.WOW_PROJECT_MAINLINE, env.WOW_PROJECT_CLASSIC = 1, 2
    env.WOW_PROJECT_BURNING_CRUSADE_CLASSIC, env.WOW_PROJECT_MISTS_CLASSIC = 5, 19
    env.WOW_PROJECT_ID = client.project
    env.GetBuildInfo = function() return client.build, "70000", "Oct 1 2026", client.interface end
    env.GetNumBindings = function() return 0 end
    env.C_AddOns = {
        GetAddOnInfo = function(name) return name, name, "", true, nil end,
        IsAddOnLoaded = function() return false end,
        LoadAddOn = function() return false, "WRONG_GAME_TYPE" end,
    }
    H.loadModule("Shared/Caps.lua", env, ns)
    return ns.Caps
end

-- Companion name -> its switch, as Search/Modules.lua maps them.
local function CompanionCaps()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Modules.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local map = {}
    for name, cap in (src:match("local COMPANION_CAP = (%b{})") or ""):gmatch("([%w_]+)%s*=%s*\"([%w_]+)\"") do
        map[name] = cap
    end
    return map
end

local tests = {}

function tests.aCompanionsDataIsTurnedOnWhereItShips()
    local map, checked, off = CompanionCaps(), 0, {}
    H.assertTrue(next(map) ~= nil, "no companion switches read from Search/Modules.lua")
    for name, cap in pairs(map) do
        local toc
        for _, path in ipairs(H.TOCS) do
            if path:find("/" .. name .. "%.toc$") then toc = path end
        end
        H.assertNotNil(toc, name .. " has no toc in the harness list")
        local fh = assert(io.open(H.ADDON_ROOT .. "/" .. toc, "r"))
        for line in fh:lines() do
            local file, rules = H.TocLine(line)
            local tags = rules:match("AllowLoadGameType ([^%]]+)")
            if tags and file:find("%.lua$") then
                for _, client in ipairs(CLIENTS) do
                    for tag in tags:gmatch("[%w_]+") do
                        if client.tags[tag] then
                            checked = checked + 1
                            if not ClientCaps(client)[cap] then
                                off[#off + 1] = string.format("%s ships %s on %s, but Caps.%s is off there", name, file, client.name, cap)
                            end
                            break
                        end
                    end
                end
            end
        end
        fh:close()
    end
    H.assertTrue(checked >= 5, "expected the item catalog's five data files, checked " .. checked)
    H.assertEq(#off, 0, "\n  " .. table.concat(off, "\n  "))
end

local pass, fail, failures = H.runSuite("CompanionDataCaps", tests)
return { pass = pass, fail = fail, failures = failures }

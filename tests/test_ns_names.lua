-- Every namespace a shipped file calls into (ns.X.y, ns.X:y) is one some
-- shipped file makes. A holiday row's click asked ns.Openers, a name
-- nothing defines, and its test's stand-in bore the same wrong name, so
-- the first click threw (Forever, 2026-11-21).
local H = require("Harness")

-- Made by an extension of its own repo; EasyFind reads them guarded.
local FROM_EXTENSIONS = { GPS = true, GPSData = true, Notes = true }

-- Generated data and locale tables: no calls in them, megabytes each.
local SKIP = { "/Database/Npcs", "/Database/Loot", "/Database/ItemData", "/Database/Icon", "/Database/Items_",
               "/Database/StaticLocations", "/Database/Floors", "/Locales/" }

local function ShippedFiles()
    local out = {}
    local p = assert(io.popen('find "' .. H.ADDON_ROOT .. '" -name "*.lua" -not -path "*/tests/*" -not -path "*/.git/*"'
        .. ' -not -path "*/dev/*" -not -path "*/API/*" 2>/dev/null'))
    for line in p:lines() do
        local skip = false
        for _, part in ipairs(SKIP) do
            if line:find(part, 1, true) then skip = true end
        end
        if not skip then out[#out + 1] = line end
    end
    p:close()
    return out
end

local tests = {}

function tests.everyNamespaceCalledInto_isMadeSomewhere()
    local made, asked = {}, {}
    local files = ShippedFiles()
    H.assertTrue(#files > 100, "the shipped files were found: " .. #files)
    for _, path in ipairs(files) do
        local f = assert(io.open(path, "rb"))
        local src = f:read("*a")
        f:close()
        local rel = path:sub(#H.ADDON_ROOT + 2)
        for name in src:gmatch("function%s+ns%.([A-Z][%w_]*)%s*[%.:%(]") do made[name] = true end
        for name in src:gmatch('ns%[%s*"([A-Z][%w_]*)"%s*%]%s*=') do made[name] = true end
        for line in src:gmatch("[^\r\n]+") do
            -- An assignment's left side: ns.A = ..., ns.A, ns.B = ...
            local left = line:match("^%s*([%w_%.,%s]-)%s*=[^=]")
            if left and left:find("ns%.") and not left:find("^local%s") then
                for name in left:gmatch("ns%.([A-Z][%w_]*)%f[^%w_]") do
                    if not left:find("ns%." .. name .. "%.") then made[name] = true end
                end
            end
        end
        for name in src:gmatch("ns%.([A-Z][%w_]*)%s*[%.:]%s*[%a_]") do
            asked[name] = asked[name] or rel
        end
        -- The search's namespaces come from a list of names.
        if rel == "Search/Modules.lua" then
            for name in src:gmatch('"([A-Z][%w_]*)"') do made[name] = true end
        end
    end
    local missing = {}
    for name, rel in pairs(asked) do
        if not made[name] and not FROM_EXTENSIONS[name] then missing[#missing + 1] = "ns." .. name .. " (" .. rel .. ")" end
    end
    table.sort(missing)
    H.assertEq(#missing, 0, "called into, made nowhere: " .. table.concat(missing, ", ", 1, math.min(#missing, 8)))
    H.assertTrue(made.SearchOpeners, "the panel opener's own name is among them")
    H.assertNil(asked.Openers, "and the wrong one is asked nowhere")
end

local pass, fail, failures = H.runSuite("NsNames", tests)
return { pass = pass, fail = fail, failures = failures }

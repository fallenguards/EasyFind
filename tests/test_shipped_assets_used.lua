-- Every font, image and sound the zip ships is named somewhere in the code
-- (a .lua, .xml or .toc): one nothing loads only makes every download
-- bigger (a math font WoW cannot even draw shipped half a megabyte).
local H = require("Harness")

local ASSET = { ttf = true, otf = true, blp = true, tga = true, png = true, jpg = true, ogg = true, mp3 = true }
local SKIP = { "^dev/", "^tests/", "^media/", "^%.github/" }
-- Named in code as a stem plus a part: each counts when its stem is named.
local BUILT_STEMS = { "textures/ForeverBand" }   -- Shared/Utils.lua Shipped(name)

local function Tracked()
    local p = assert(io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files'))
    local out = {}
    for line in p:lines() do
        local skip = false
        for _, s in ipairs(SKIP) do skip = skip or line:find(s) ~= nil end
        if not skip then out[#out + 1] = line end
    end
    p:close()
    return out
end

local tests = {}

function tests.everyShippedAssetIsNamedInCode()
    local files, texts = Tracked(), {}
    for _, path in ipairs(files) do
        if path:find("%.lua$") or path:find("%.xml$") or path:find("%.toc$") then
            local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
            texts[#texts + 1] = f:read("*a"):lower()
            f:close()
        end
    end
    local code = table.concat(texts, "\n")
    local function Named(path, stem)
        if code:find(stem:lower(), 1, true) then return true end
        for _, built in ipairs(BUILT_STEMS) do
            if path:sub(1, #built) == built and code:find(built:match("[^/]+$"):lower(), 1, true) then return true end
        end
        return false
    end
    local unused = {}
    for _, path in ipairs(files) do
        local stem, ext = path:match("([^/]+)%.(%w+)$")
        if stem and ASSET[ext:lower()] and not Named(path, stem) then unused[#unused + 1] = path end
    end
    H.assertEq(#unused, 0, "shipped but named nowhere:\n  " .. table.concat(unused, "\n  "))
end

local pass, fail, failures = H.runSuite("ShippedAssetsUsed", tests)
return { pass = pass, fail = fail, failures = failures }

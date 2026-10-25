-- Events a client lacks (2026-10-26, TBC: GPS.lua registered
-- SUPER_TRACKING_CHANGED at load; the client threw and the rest of the
-- file never ran, so the GPS button did nothing). A file that loads on a
-- classic client or Forever registers only the events that client has,
-- or goes through Utils.RegisterEventIfValid. Event lists: client_events.lua
-- (tests/build_client_events.py). The dev add-on beside it is read too.
local H = require("Harness")

local events = dofile(H.ADDON_ROOT .. "/tests/client_events.lua")
local KINDS = { "vanilla", "tbc", "mists", "camelot" }
local NAMES = { vanilla = "Era", tbc = "TBC", mists = "Mists", camelot = "Forever" }
local CLASSIC = { vanilla = true, tbc = true, mists = true }

local function Set(words)
    local set = {}
    for w in words:gmatch("[%w_]+") do set[w] = true end
    return set
end
local all, missing = Set(events.all), {}
for _, kind in ipairs(KINDS) do missing[kind] = Set(events.missing[kind]) end

local function Read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function Loads(kind, tags)
    if not tags then return true end
    for tag in tags:gmatch("[%a]+") do
        if tag == kind or (tag == "classic" and CLASSIC[kind]) or (tag == "mainline" and kind == "camelot") then return true end
    end
    return false
end

-- Each Lua file a toc loads, with the client kinds it loads on.
local function TocFiles(root, toc, out)
    local src = Read(root .. "/" .. toc)
    if not src then return end
    local dir = toc:match("^(.*)/[^/]*$")
    local addonTags = src:match("\n## AllowLoadGameType:%s*([^\r\n]+)")
    for line in src:gmatch("[^\r\n]+") do
        local file, rest = line:match("^%s*([^#%s][^%[]-%.lua)%s*(.*)$")
        if file then
            local tags = rest:match("%[AllowLoadGameType ([^%]]+)%]") or addonTags
            local kinds = {}
            for _, kind in ipairs(KINDS) do
                if Loads(kind, tags) then kinds[#kinds + 1] = kind end
            end
            if #kinds > 0 then
                local path = (dir and (dir .. "/") or "") .. file:gsub("\\", "/")
                out[#out + 1] = { root = root, path = path, kinds = kinds }
            end
        end
    end
end

local function Tocs(root, pattern)
    local out = {}
    local cmd = package.config:sub(1, 1) == "\\"
        and ('dir /b /s "' .. (root .. "/" .. pattern):gsub("/", "\\") .. '" 2>nul')
        or ('find "' .. root .. '" -path "' .. root .. "/" .. pattern .. '" 2>/dev/null')
    local p = io.popen(cmd)
    for line in p:lines() do
        local rel = line:gsub("\\", "/"):sub(#root + 2)
        if rel:find("%.toc$") and not rel:find("^tests/") then out[#out + 1] = rel end
    end
    p:close()
    return out
end

local function Scan(src, path, kinds, bad)
    local n = 0
    for line in src:gmatch("([^\n]*)\n?") do
        n = n + 1
        if not line:find("^%s*%-%-") then
            for _, call in ipairs({ ":RegisterEvent%(", ":RegisterUnitEvent%(" }) do
                for event in line:gmatch(call .. "%s*[\"']([%w_]+)[\"']") do
                    local lacking = {}
                    for _, kind in ipairs(kinds) do
                        if not all[event] or missing[kind][event] then lacking[#lacking + 1] = NAMES[kind] end
                    end
                    if #lacking > 0 then
                        bad[#bad + 1] = string.format("%s:%d %s (no such event on %s)", path, n, event,
                            table.concat(lacking, ", "))
                    end
                end
            end
        end
    end
end

local function Violations(files)
    local bad = {}
    for _, f in ipairs(files) do Scan(assert(Read(f.root .. "/" .. f.path), f.path), f.path, f.kinds, bad) end
    return bad
end

local tests = {}

function tests.easyFindRegistersOnlyEventsItsClientsHave()
    local files = {}
    TocFiles(H.ADDON_ROOT, "EasyFind.toc", files)
    for _, toc in ipairs(Tocs(H.ADDON_ROOT, "Apps")) do TocFiles(H.ADDON_ROOT, toc, files) end
    H.assertTrue(#files > 100, "the tocs were read: " .. #files .. " files")
    local bad = Violations(files)
    H.assertEq(#bad, 0, "\n  " .. table.concat(bad, "\n  "))
end

function tests.theDevAddonToo()
    local root = H.ADDON_ROOT .. "/../EasyFindDev"
    if not Read(root .. "/EasyFindDev.toc") then return end
    local files = {}
    TocFiles(root, "EasyFindDev.toc", files)
    H.assertTrue(#files > 50, "its toc was read: " .. #files .. " files")
    local bad = Violations(files)
    H.assertEq(#bad, 0, "\n  " .. table.concat(bad, "\n  "))
end

function tests.theGPSLineIsCaughtAndItsFixPasses()
    local bad = {}
    Scan('    watch:RegisterEvent("SUPER_TRACKING_CHANGED")\n', "GPS.lua", { "tbc" }, bad)
    H.assertEq(#bad, 1, "the line that broke TBC's GPS")
    Scan('    watch:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")\n'
        .. '    Utils.RegisterEventIfValid(watch, "SUPER_TRACKING_CHANGED")\n', "GPS.lua", { "tbc", "vanilla" }, bad)
    H.assertEq(#bad, 1, "events TBC has, and the helper, pass")
end

local pass, fail, failures = H.runSuite("ClientEvents", tests)
return { pass = pass, fail = fail, failures = failures }

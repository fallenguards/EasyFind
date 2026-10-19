-- Every extension of ours registers through EasyFind.API, as anyone's
-- would: no tile, flag, opener or launcher row wired by hand in core.
local H = require("Harness")

local function Read(path)
    local f = io.open(H.ADDON_ROOT .. "/" .. path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function LuaFiles(dir)
    local out = {}
    local p = io.popen('ls "' .. H.ADDON_ROOT .. "/" .. dir .. '"/*.lua 2>/dev/null')
    for line in p:lines() do out[#out + 1] = dir .. "/" .. line:match("([^/\\]+)$") end
    p:close()
    return out
end

-- id -> where it registers: its companion's files, and core's stub for
-- the ones that load on demand.
local BUNDLED = {
    calculator = { "Apps/Calc" }, clipboard = { "Apps/Clipboard" }, gps = { "Apps/GPS" },
    quicklists = { "Apps/Quicklists" }, snippets = { "Apps/Snippets" },
    icons = { "Apps/Icons", "Core/Extensions.lua" }, notes = { "Apps/Notes", "Core/Extensions.lua" },
    chat = { "Core/Extensions.lua" },
}

local function Registers(path, id)
    local src = Read(path) or ""
    for call in src:gmatch("RegisterExtension%b()") do
        if call:find('id%s*=%s*"' .. id .. '"') then return true end
    end
    return false
end

local tests = {}

function tests.eachBundledExtension_registersThroughTheAPI()
    for id, places in pairs(BUNDLED) do
        for _, place in ipairs(places) do
            local files = place:match("%.lua$") and { place } or LuaFiles(place)
            local found = false
            for _, f in ipairs(files) do found = found or Registers(f, id) end
            H.assertTrue(found, id .. " registers in " .. place)
        end
    end
end

-- The flags core once kept per extension live on only where old stored
-- copies are read.
local RETIRED = { "iconSearchLauncher", "clipboardLauncher", "notesLauncher", "gpsLauncher",
                  "quicklistsLauncher", "chatLauncher" }
local ALLOWED = { ["Core/API.lua"] = true, ["Shared/UIPins.lua"] = true }

function tests.core_wiresNoExtensionByHand()
    local p = io.popen('cd "' .. H.ADDON_ROOT .. '" && git ls-files "*.lua"')
    local bad = {}
    for f in p:lines() do
        if not ALLOWED[f] and not f:match("^tests/") then
            local src = Read(f) or ""
            for _, flag in ipairs(RETIRED) do
                if src:find(flag, 1, true) then bad[#bad + 1] = f .. ": " .. flag end
            end
            for name in src:gmatch("function [%w_.:]*Get(%w+)LauncherMatch") do
                if name ~= "Calculator" then bad[#bad + 1] = f .. ": Get" .. name .. "LauncherMatch" end
            end
        end
    end
    p:close()
    H.assertEq(table.concat(bad, "; "), "", "registered through EasyFind.API instead")
end

local pass, fail, failures = H.runSuite("ExtensionsRegistered", tests)
return { pass = pass, fail = fail, failures = failures }

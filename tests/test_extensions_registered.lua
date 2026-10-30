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
    calculator = { "Apps/Calc" }, clipboard = { "Apps/Clipboard" },
    quicklists = { "Apps/Quicklists" }, snippets = { "Apps/Snippets" },
    icons = { "Apps/Icons", "Core/Extensions.lua" }, notes = { "Apps/Notes", "Core/Extensions.lua" },
    chat = { "Core/Extensions.lua" },
}

local function Registers(path, id, fn, field)
    local src = Read(path) or ""
    for call in src:gmatch((fn or "RegisterExtension") .. "%b()") do
        if call:find((field or "id") .. '%s*=%s*"' .. id .. '"') then return true end
    end
    return false
end

local function RegistersIn(place, id, fn, field)
    local files = place:match("%.lua$") and { place } or LuaFiles(place)
    for _, f in ipairs(files) do
        if Registers(f, id, fn, field) then return true end
    end
    return false
end

local tests = {}

function tests.eachBundledExtension_registersThroughTheAPI()
    for id, places in pairs(BUNDLED) do
        for _, place in ipairs(places) do
            H.assertTrue(RegistersIn(place, id), id .. " registers in " .. place)
        end
    end
end

-- The extensions' search results, the same way.
local PROVIDERS = {
    snippets = { "Apps/Snippets" }, clipboard = { "Apps/Clipboard" }, quicklists = { "Apps/Quicklists" },
    notes = { "Apps/Notes", "Core/Extensions.lua" }, chat = { "Core/Extensions.lua" },
}

function tests.eachBundledProvider_registersThroughTheAPI()
    for key, places in pairs(PROVIDERS) do
        for _, place in ipairs(places) do
            H.assertTrue(RegistersIn(place, key, "RegisterSearchProvider", "key"),
                key .. " results register in " .. place)
        end
    end
end

function tests.core_listsNoExtensionCategory()
    H.assertNil((Read("Shared/CategoryMap.lua") or ""):find('parent = "extensions"', 1, true),
        "an extension's category comes with its registration")
    local config = (Read("Search/Filters/Config.lua") or ""):gsub("\r", "")
    H.assertTrue(config:find('key = "extensions",%s+label = [^\n]+\n%s+flyoutSubFilters = {} }') ~= nil,
        "the Extensions filter row starts empty")
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

-- One extension asks another through its actions, never its internals.
-- (Core's own modules may still reach an extension's table.)
local REACH = { "ns%.GPS[:.]NavigateTo", "ns%.Chat[:.]ComposeWith", "ns%.Snippets[:.]RunByName",
                "ns%.Snippets[:.]OpenEditorPrefilled", "ns%.Notes%.FlattenDocument",
                "ns%.Notes%.AttachSnippetBodyEditor", "ns%.Notes%.DocumentFromMarkdown",
                "ns%.Notes%.OpenUnitNote", "ns%.Notes%.FindUnitNote", "ns%.Notes%.HasUnitNote" }

function tests.extensions_callEachOtherThroughActions()
    local p = io.popen('cd "' .. H.ADDON_ROOT .. '" && git ls-files "*.lua"')
    local bad = {}
    for f in p:lines() do
        if not f:match("^tests/") then
            local src = Read(f) or ""
            for _, pat in ipairs(REACH) do
                if src:find(pat) then bad[#bad + 1] = f .. ": " .. pat:gsub("%%", "") end
            end
        end
    end
    p:close()
    H.assertEq(table.concat(bad, "; "), "", "EasyFind.API.CallAction instead")
end

local pass, fail, failures = H.runSuite("ExtensionsRegistered", tests)
return { pass = pass, fail = fail, failures = failures }

-- Tests for the settings resets: Reset All (Core/Main.lua) keeps the
-- player's own lists and restores the real defaults, and every key the
-- options panel's resets name is a DB_DEFAULTS key (no copied values).

local H = require("Harness")

local function Read(rel)
    local fh = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local text = fh:read("*a")
    fh:close()
    return text
end

-- DB_DEFAULTS through ResetSettingsToDefaults, run alone.
local function LoadReset()
    local src = Read("Core/Main.lua")
    local s = assert(src:find("\nlocal DB_DEFAULTS = {", 1, true), "DB_DEFAULTS not in Core/Main.lua")
    local f = assert(src:find("\nfunction EasyFind:ResetSettingsToDefaults()", s, true))
    local _, e = src:find("\nend\r?\n", f)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind = { db = {} }
    local deep
    deep = function(v)
        if type(v) ~= "table" then return v end
        local out = {}
        for k, x in pairs(v) do out[k] = deep(x) end
        return out
    end
    ns.Utils.DeepCopy = ns.Utils.DeepCopy or deep
    local chunk = assert(load("local _, ns = ...\nlocal Utils, pairs = ns.Utils, pairs\n" .. src:sub(s, e),
        "=Core/Main.lua reset", "t", setmetatable({ EasyFind = env.EasyFind }, { __index = _G })))
    chunk(nil, ns)
    return env.EasyFind, ns.DB_DEFAULTS
end

-- DB_DEFAULTS' top-level keys from the source, nil defaults included.
local function DefaultKeys()
    local body = Read("Core/Main.lua"):match("\nlocal DB_DEFAULTS = {\r?\n(.-)\r?\n}\r?\n")
    local keys = {}
    for line in (body .. "\n"):gmatch("(.-)\r?\n") do
        if line:find("^    [%a_]") then
            for key in line:gmatch("([%a_][%w_]*)%s*=[^=]") do keys[key] = true end
        end
    end
    return keys
end

local tests = {}

function tests.resetAllKeepsThePlayersListsAndRestoresDefaults()
    local EasyFind, defaults = LoadReset()
    local snippets, quicklists, learned = { { text = "hi" } }, { { name = "Raid" } }, { bank = { key = "x" } }
    EasyFind.db = {
        snippets = snippets, quicklists = quicklists, queryLearn = learned,
        aliases = { a = 1 }, pinnedUIItems = { 1 },
        windowBorder = false, lootFilter = "all", appearanceItemSlot = 5,
    }
    EasyFind:ResetSettingsToDefaults()
    local db = EasyFind.db
    H.assertEq(db.snippets, snippets, "snippets stay")
    H.assertEq(db.quicklists, quicklists, "quicklists stay")
    H.assertEq(db.queryLearn, learned, "learned picks stay")
    H.assertEq(db.aliases.a, 1, "aliases stay")
    H.assertEq(db.pinnedUIItems[1], 1, "pins stay")
    H.assertEq(db.windowBorder, defaults.windowBorder, "the border goes back to its default")
    H.assertEq(db.lootFilter, nil, "the gear filter goes back to the current spec")
    H.assertEq(db.appearanceItemSlot, nil)
end

function tests.everyOptionsResetKeyIsADefault()
    local panel = Read("Apps/Options/OptionsPanel.lua")
    local known, bad, lists = DefaultKeys(), {}, 0
    for name in ("UI_RESET_KEYS UI_POSITION_KEYS MAP_RESET_KEYS"):gmatch("%S+") do
        local body = panel:match("\nlocal " .. name .. " = {(.-)\n}")
        assert(body, name .. " not in OptionsPanel.lua")
        lists = lists + 1
        for key in body:gmatch('"([%a_][%w_]*)"') do
            if not known[key] then bad[#bad + 1] = name .. ": " .. key end
        end
    end
    H.assertEq(lists, 3)
    H.assertEq(table.concat(bad, ", "), "", "reset keys with no DB_DEFAULTS entry")
    H.assertTrue(not panel:find("\nlocal UI_DEFAULTS = {", 1, true), "no copied default values in the panel")
end

local pass, fail, failures = H.runSuite("Reset defaults", tests)
return { pass = pass, fail = fail, failures = failures }

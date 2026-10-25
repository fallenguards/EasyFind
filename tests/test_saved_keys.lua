-- Every top-level saved key a shipped file writes is classified: a
-- default, a profile section, state (Shared/Profiles.lua STATE_KEYS), or
-- a nil-default setting listed here. An unclassified key moves with a
-- profile switch by accident (gpsChar, macroButtons, notesInUse did).
local H = require("Harness")

-- Settings with no default.
local NIL_DEFAULT_SETTINGS = {
    "appearanceItemClass", "appearanceItemSlot", "appearanceItemSourceFilters", "heirloomFilter", "lootFilter",
    "npcFilters", "appsMenu", "chatFindMessages", "classicArt", "clipboardMaxDays", "clipboardMaxEntries",
    "optionsPosition", "themeStudioHoverPreview",
    "gpsArrowPos", "gpsArrowText", "gpsAutoLearn", "gpsBeaconStyle", "gpsDockSlot", "gpsDocked", "gpsHideDone",
    "gpsLaunchWindow", "gpsLineColors", "gpsLineWidth", "gpsMapClick", "gpsNeverDock", "gpsPopout",
    "gpsPopoutCollapsed", "gpsPopoutFieldsHidden", "gpsPopoutNextOnly", "gpsPopoutSize", "gpsPopoutStyle",
    "gpsPopoutText", "gpsShowDetours", "gpsShowOtherWays", "gpsWatchSlot", "gpsWorldPin",
}
-- `db.x =` lines whose db is not EasyFindDB (Notes' own EasyNotesDB), and
-- keys only an old migration step writes.
local NOT_SAVED = {
    "autoResize", "border", "borderStyle", "nextID", "opacity", "reader", "savedColors", "showsFolded",
    "tagColors", "uiScale",
    "uiMaxResults", "mapMaxResults", "uiResultsHeight", "showLoginMessage",
}
-- key, then the first word of the value (a write of nil retires a key).
local WRITES = {
    "EasyFind%.db%.([%a_][%w_]*)%s*=%s*([^=%s]%S*)", "EasyFindDB%.([%a_][%w_]*)%s*=%s*([^=%s]%S*)",
    "%f[%w_]db%.([%a_][%w_]*)%s*=%s*([^=%s]%S*)",
}

-- DB_DEFAULTS' top-level keys: lines at its first indent, several per line allowed.
local function DefaultKeys()
    local fh = assert(io.open(H.ADDON_ROOT .. "/Core/Main.lua", "rb"))
    local body = fh:read("*a"):match("\nlocal DB_DEFAULTS = {\r?\n(.-)\r?\n}\r?\n")
    fh:close()
    local keys = {}
    for line in (body .. "\n"):gmatch("(.-)\r?\n") do
        if line:find("^    [%a_]") then
            for key in line:gmatch("([%a_][%w_]*)%s*=[^=]") do keys[key] = true end
        end
    end
    return keys
end

local tests = {}

function tests.everySavedKeyIsClassified()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    H.loadModule("Shared/Profiles.lua", env, ns)
    local known, bad, seen = DefaultKeys(), {}, {}
    for _, list in ipairs({ NIL_DEFAULT_SETTINGS, NOT_SAVED }) do
        for _, key in ipairs(list) do known[key] = true end
    end
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "rb")
            local text = fh and fh:read("*a") or ""
            if fh then fh:close() end
            if text:find("EasyFind.db", 1, true) or text:find("EasyFindDB", 1, true) then
                for line in (text .. "\n"):gmatch("(.-)\r?\n") do
                    local code = line:gsub("%-%-.*$", "")
                    for _, pattern in ipairs(WRITES) do
                        for key, value in code:gmatch(pattern) do
                            if not value:find("^nil") and ns.Profiles.IsSettingKey(key)
                               and not known[key] and not seen[key] then
                                seen[key] = true
                                bad[#bad + 1] = key .. "  (" .. rel .. ")"
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(bad)
    H.assertEq(#bad, 0, "saved keys no list classifies (STATE_KEYS, a section, or this test):\n  "
        .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("Saved keys", tests)
return { pass = pass, fail = fail, failures = failures }

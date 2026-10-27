-- Every chat line EasyFind prints, each with why it may (2026-10-26: lines
-- that only confirmed a click, an arrival or an import were spam). A new
-- chat line fails here until listed with one of these reasons:
--   error    something broke
--   refusal  what was asked cannot be done (combat, a bad code, a full list)
--   asked    the player asked for this text (/ef help)
--   alert    news the player did not click for (a reminder due, a reply)
--   release  the What's New and tour offers
--   dev      dev mode only
--   helper   a local print helper's own body
local H = require("Harness")

local ALLOWED = {
    ["Apps/GPS/GPS.lua|GPS drag: "] = { 1, "error" },
    ["Apps/GPS/GPS.lua|GPS menu: "] = { 2, "error" },
    ["Apps/Guide/Highlight.lua|MSG_GUIDE_TARGET_LOCKED"] = { 1, "refusal" },
    ["Apps/Notes/Notes.lua|NOTES_LINK_ASKING_FMT"] = { 1, "alert" },
    ["Apps/Notes/Notes.lua|NOTES_LINK_NO_ANSWER_FMT"] = { 1, "alert" },
    ["Apps/Notes/Notes.lua|NOTES_NOTHING_TO_UNDO"] = { 1, "refusal" },
    ["Apps/Notes/Notes.lua|NOTES_READER_EMPTY"] = { 1, "refusal" },
    ["Apps/Notes/Reminders.lua|NOTES_REMINDER_FMT"] = { 1, "alert" },
    ["Apps/Notes/Notes.lua|SHORTKEY_IMPORT_BAD"] = { 3, "refusal" },
    ["Apps/Options/OptionsPanel.lua|IMPORT_OVER_CAP_FMT"] = { 1, "refusal" },
    ["Apps/Options/OptionsPanel.lua|IMPORT_PREVIEW_EMPTY"] = { 1, "refusal" },
    ["Apps/Options/OptionsPanel.lua|PROFILE_EXPORT_EMPTY"] = { 1, "refusal" },
    ["Apps/Options/OptionsPanel.lua|PROFILE_NAME_TAKEN"] = { 1, "refusal" },
    ["Apps/Options/OptionsPanel.lua|SHORTKEY_IMPORT_BAD"] = { 3, "refusal" },
    ["Apps/Quicklists/Quicklists.lua|QUICKLIST_FULL_FMT"] = { 1, "refusal" },
    ["Apps/Quicklists/Quicklists.lua|QUICKLIST_NAME_TAKEN_FMT"] = { 2, "refusal" },
    ["Apps/Quicklists/Quicklists.lua|msg"] = { 1, "helper" },
    ["Core/API.lua|COMPANION_INCOMPLETE_FMT"] = { 1, "refusal" },
    ["Core/API.lua|ERR_NOT_IN_COMBAT"] = { 1, "refusal" },
    ["Core/Main.lua|CMD_BUG"] = { 1, "asked" },
    ["Core/Main.lua|CMD_CLEAR"] = { 1, "asked" },
    ["Core/Main.lua|CMD_FEATURE"] = { 1, "asked" },
    ["Core/Main.lua|CMD_HEADER"] = { 1, "asked" },
    ["Core/Main.lua|CMD_OPTIONS"] = { 1, "asked" },
    ["Core/Main.lua|CMD_RESET"] = { 1, "asked" },
    ["Core/Main.lua|ERR_MODULE_INIT_FAILED"] = { 1, "error" },
    ["Core/Main.lua|ERR_OPTIONS_REGISTER_FAILED"] = { 1, "error" },
    ["Core/Main.lua|TUTORIAL_CHAT_OFFER"] = { 1, "release" },
    ["Core/Main.lua|ns.CHAT_LOGO .. msg"] = { 1, "release" },
    ["Core/Main.lua|%s|cFF00FF00EasyFind:|r %s"] = { 1, "helper" },
    ["Database/Dynamic.lua|ERR_SEARCH_DATA_FAILED"] = { 1, "error" },
    ["Database/Main.lua|ERR_DATABASE_INIT_FAILED"] = { 1, "error" },
    ["Database/Main.lua|ERR_NOT_IN_COMBAT"] = { 1, "refusal" },
    ["Search/Modules.lua|COMPANION_INCOMPLETE_FMT"] = { 1, "refusal" },
    ["Search/Modules.lua|ns.L[disabledKey]"] = { 1, "refusal" },
    ["Search/Results/Handlers/Appearances.lua|ERR_APPEARANCE_SET_LOAD"] = { 1, "error" },
    ["Search/Results/ThemeShare.lua|SHORTKEY_IMPORT_BAD"] = { 1, "refusal" },
    ["Shared/Profiles.lua|PROFILE_SWITCHED_FMT"] = { 1, "alert" },
    ["Shared/ResultLinks.lua|EFLINK_IN_COMBAT"] = { 1, "refusal" },
    ["Shared/ResultLinks.lua|EFLINK_NOT_FOUND"] = { 2, "refusal" },
    ["Shared/Shortkeys.lua|MACRO_IN_COMBAT"] = { 1, "refusal" },
    ["Shared/Shortkeys.lua|MACRO_NO_ROOM"] = { 1, "refusal" },
    ["Shared/Signals.lua|text"] = { 1, "alert" },
    ["Shared/Utils.lua||cff33ff99[EasyFind]|r"] = { 1, "dev" },
}

-- Every shipped Lua file but the locales, once.
local function Files()
    local out, seen = {}, {}
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            if rel:match("%.lua$") and not rel:match("^Locales/") and not seen[rel] then
                seen[rel] = true
                out[#out + 1] = rel
            end
        end
    end
    return out
end

-- What a print line says: its first locale key, else its first string,
-- else the argument as written.
local function Token(line)
    return line:match('L%["([%w_]+)"%]') or line:match('_G%["([%w_]+)"%]') or line:match('"([^"]+)"')
        or line:match("[Pp]rint%((.-)%)%s*$") or line:match("[Pp]rint%((.-)%)") or "?"
end

local function Found()
    local found = {}
    for _, rel in ipairs(Files()) do
        local f = io.open(H.ADDON_ROOT .. "/" .. rel, "rb")
        if f then
            for line in f:lines() do
                local code = line:gsub("%-%-.*$", "")
                local call = code:find("EasyFind:Print%(") or code:find("%f[%w_.:]Print%(")
                    or code:find("%f[%w_.:]print%(")
                if call and not code:find("function [%w_.:]*[Pp]rint%(") then
                    local key = rel .. "|" .. Token(code)
                    found[key] = (found[key] or 0) + 1
                end
            end
            f:close()
        end
    end
    return found
end

local tests = {}

function tests.everyChatLineHasItsReason()
    local found = Found()
    local new, gone = {}, {}
    for key, n in pairs(found) do
        local allowed = ALLOWED[key]
        if not allowed or n > allowed[1] then new[#new + 1] = key .. " x" .. n end
    end
    for key, allowed in pairs(ALLOWED) do
        if (found[key] or 0) < allowed[1] then gone[#gone + 1] = key end
    end
    table.sort(new)
    table.sort(gone)
    H.assertEq(table.concat(new, "; "), "",
        "a chat line that only confirms what the player just did is spam; list it in ALLOWED with its reason or drop it")
    H.assertEq(table.concat(gone, "; "), "", "listed lines no longer printed: take them off ALLOWED")
end

local pass, fail, failures = H.runSuite("ChatLines", tests)
return { pass = pass, fail = fail, failures = failures }

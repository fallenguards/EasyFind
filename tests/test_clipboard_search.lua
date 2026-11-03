-- The clipboard history answers a plain search (8a767eab made the provider
-- eager in 2026-10-21, but Search/Query.lua still skipped the category
-- outside @clipboard, so "ciabatta" found nothing, 2026-11-03). Its rows
-- are found by what they say; its date groups head only its own list.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local tests = {}

function tests.plainSearchesKeepTheClipboardCategory()
    local query = Read("Search/Query.lua")
    H.assertNil(query:find('skipCategories["Clipboard"]', 1, true), "no forced skip outside @clipboard")
    H.assertTrue(query:find('SCRATCH.clipGroups = quickFilter ~= nil and quickFilter.key == "clipboard"', 1, true) ~= nil,
        "the date groups only under @clipboard")
    H.assertTrue(query:find("local group = (SCRATCH.clipGroups and d.clipGroup) or (mapSplit and d.sectionLabel)", 1, true) ~= nil)
    local clip = Read("Apps/Clipboard/Clipboard.lua")
    H.assertTrue(clip:find("eager = true", 1, true) ~= nil, "the provider joins every search")
end

-- "clip" or "history" typed in the bar is the launcher's: no entry carries
-- those words, and the empty-kinds line matches nothing.
function tests.entriesAreFoundByWhatTheySay()
    local clip = Read("Apps/Clipboard/Clipboard.lua")
    H.assertNil(clip:find('{ "clipboard", "clip", "history" }', 1, true), "no generic words on every entry")
    local s = assert(clip:find('name = L["CLIP_EMPTY_TYPES"],', 1, true))
    local block = clip:sub(s, s + 200)
    H.assertTrue(block:find('nameLower = "",', 1, true) ~= nil and block:find("keywordsLower = {},", 1, true) ~= nil,
        "the empty-kinds line is listed, never found")
end

local pass, fail, failures = H.runSuite("ClipboardSearch", tests)
return { pass = pass, fail = fail, failures = failures }

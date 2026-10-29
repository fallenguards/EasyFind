-- The settings window indexes a setting by its label's font: the gold
-- GameFontNormal* family. The panel draws with its own copies of the game
-- fonts (OPT_FONTS, "EasyFindOptions" .. name); the index only knew the
-- game's names, so every dropdown row, header and key row went missing
-- from Search settings and Search this page (2026-10-26 to 2026-10-28).
local H = require("Harness")

local function Source()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Options/OptionsPanel.lua", "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.indexAcceptsThePanelsOwnFontCopies()
    local src = Source()
    local prefix = assert(src:match('local copy = "([%w_]+)" %.%. name'), "the font copy prefix")
    local at = assert(src:find("local function IndexableLabel", 1, true))
    local body = src:sub(at, at + 1600)
    H.assertTrue(body:find('"^' .. prefix .. 'GameFontNormal"', 1, true) ~= nil,
        "IndexableLabel must accept " .. prefix .. "GameFontNormal*")
end

function tests.pageSearchRing_sitsOverTheWindowBackground()
    local src = Source()
    local at = assert(src:find("-- ==== search this page", 1, true))
    local body = src:sub(at, at + 900)
    H.assertTrue(body:find("SetFrameLevel(optionsFrame.bgTex:GetFrameLevel()", 1, true) ~= nil,
        "the page search well must sit over the background frame before its ring is made")
end

local pass, fail, failures = H.runSuite("SettingsLabelIndex", tests)
return { pass = pass, fail = fail, failures = failures }

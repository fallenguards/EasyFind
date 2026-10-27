-- The options window's text is the game's fonts 2 pt larger (OPT_FONTS,
-- Apps/Options/OptionsPanel.lua): a game font named anywhere else in the
-- file draws its text at the old, small size (2026-10-26).
local H = require("Harness")

local tests = {}

function tests.theWindowNamesOnlyItsOwnFonts()
    local fh = assert(io.open(H.ADDON_ROOT .. "/Apps/Options/OptionsPanel.lua", "r"))
    local text = fh:read("a")
    fh:close()
    local s, e = text:find("local OPT_FONTS = {}.-\nend\n")
    assert(s, "the OPT_FONTS block")
    local bad = {}
    local rest = text:sub(1, s - 1) .. text:sub(e + 1)
    for name in rest:gmatch('"(%u%a*Font%a*)"') do
        if not name:find("^EasyFind") then bad[#bad + 1] = name end
    end
    H.assertEq(#bad, 0, "use OPT_FONTS." .. (bad[1] or "") .. ": " .. table.concat(bad, ", "))
end

-- The kit extensions build their pages with names the same fonts, and a
-- page's own text asks the kit (the descriptions read small, 2026-10-26).
function tests.theExtensionKitAndPagesUseTheLargerFonts()
    local fh = assert(io.open(H.ADDON_ROOT .. "/Core/API.lua", "r"))
    local api = fh:read("a")
    fh:close()
    local s = assert(api:find("local function Kit(ctx)", 1, true))
    local _, e = assert(api:find("\nend\r?\n", s))
    local kit = api:sub(s, e)
    local bare = {}
    for name in kit:gmatch('[^(]"(%u%a*Font%a*)"') do bare[#bare + 1] = name end
    H.assertEq(#bare, 0, "the kit names a game font bare: " .. table.concat(bare, ", "))
    H.assertTrue(kit:find("kit.Font = Font", 1, true) ~= nil, "pages can ask for it")
end

function tests.theButtonsWearTheLargerFontToo()
    local fh = assert(io.open(H.ADDON_ROOT .. "/Apps/Options/OptionsPanel.lua", "r"))
    local text = fh:read("a")
    fh:close()
    H.assertNil(text:find("local CreateModernButton = ns.CreateModernButton", 1, true))
    H.assertTrue(text:find("btn._label:SetFontObject(OPT_FONTS.GameFontNormalSmall)", 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("OptionsFonts", tests)
return { pass = pass, fail = fail, failures = failures }

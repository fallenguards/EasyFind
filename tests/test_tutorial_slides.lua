-- The tutorial's slides: every picture a slide names ships tracked in
-- Onboarding/Images, the map tab's rares slides show on retail alone (the
-- other clients track no rares from the map tab), and the map tab deck
-- ends on the GPS extension.
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local WIZARD = "Apps/Onboarding/TutorialWizard.lua"
-- A locale line's opening, built so the key checker reads no lookup here.
local LOCALE_KEY = "L" .. '["%s"]'

-- Each slide table's text: image line to its closing brace at 4 spaces.
local function Slides(src)
    local out = {}
    for body in src:gmatch("\n    {\n(.-)\n    },") do
        local image = body:match('image = "Interface\\\\AddOns\\\\EasyFind\\\\Onboarding\\\\Images\\\\([%w%-]+)"')
        if image then
            out[#out + 1] = { image = image, caps = body:match('caps = "(%w+)"'), text = body:match('L%["([%w_]+)"%]') }
        end
    end
    return out
end

local tests = {}

function tests.everySlidePicture_shipsTracked()
    local p = assert(io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files Onboarding/Images'))
    local tracked = {}
    for path in p:lines() do
        local name = path:match("^Onboarding/Images/([%w%-]+)%.%a+$")
        if name then tracked[name] = true end
    end
    p:close()
    local slides = Slides(Read(WIZARD))
    H.assertTrue(#slides > 15, "the slides read: " .. #slides)
    for _, s in ipairs(slides) do
        H.assertTrue(tracked[s.image], s.image .. " is not a tracked file in Onboarding/Images")
    end
end

function tests.theRaresSlides_showOnRetailAlone()
    local seen = 0
    for _, s in ipairs(Slides(Read(WIZARD))) do
        if s.text == "TUT_MAP_RARES_DESC" or s.text == "TUT_MAP_AUTOTRACK_DESC" then
            seen = seen + 1
            H.assertEq(s.caps, "retail", s.text)
        end
    end
    H.assertEq(seen, 2)
end

function tests.theMapTabDeck_endsOnTheGPSExtension()
    local src = Read(WIZARD)
    local deck = assert(src:match("local MAP_SEARCH_TUTORIAL_SLIDES = {\n(.-)\n}\n"))
    local slides = Slides("\n" .. deck)
    local last = slides[#slides]
    H.assertEq(last.text, "TUT_MAP_GPS_DESC")
    H.assertEq(last.image, "tutorial-map-gps-hires")
    H.assertNil(last.caps, "every client")
end

-- The Extensions deck draws a card per extension of ours on CurseForge:
-- each needs its title, an icon EasyFind ships and a blurb in enUS.
function tests.everyExtensionOnCurseForge_hasItsCard()
    local src = Read("Core/Extensions.lua")
    local list = assert(src:match("local FIRST_PARTY = {\n(.-)\n}\n"))
    local enUS = Read("Locales/enUS.lua")
    local p = assert(io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files textures'))
    local tracked = {}
    for path in p:lines() do tracked[path] = true end
    p:close()
    local n = 0
    local text, starts = "\n" .. list, {}
    for pos in text:gmatch("()\n    { addon") do starts[#starts + 1] = pos end
    for i, pos in ipairs(starts) do
        local entry = text:sub(pos, (starts[i + 1] or #text + 1) - 1)
        local addon = entry:match('addon = "([%w_]+)"')
        if entry:find("slug = ") then
            n = n + 1
            H.assertTrue(entry:find("title = ") ~= nil, addon .. " has no title")
            local icon = entry:match('icon = TEX %.%. "([%w%-]+)"')
            H.assertTrue(icon and tracked["textures/" .. icon .. ".tga"], addon .. "'s icon is not a tracked texture")
            local blurb = entry:match('blurb = L%["([%w_]+)"%]')
            H.assertTrue(blurb and enUS:find(LOCALE_KEY:format(blurb), 1, true), addon .. "'s blurb is not in enUS")
        end
    end
    H.assertTrue(n >= 10, "extensions with a page: " .. n)
end

function tests.theBuiltInCards_haveTheirBlurbs()
    local src = Read(WIZARD)
    local enUS = Read("Locales/enUS.lua")
    local list = assert(src:match("local BUILT_IN_CARDS = {\n(.-)\n}\n"))
    local n = 0
    for key in list:gmatch('blurb = L%["([%w_]+)"%]') do
        n = n + 1
        H.assertTrue(enUS:find(LOCALE_KEY:format(key), 1, true) ~= nil, key)
    end
    H.assertEq(n, 5)
end

local pass, fail, failures = H.runSuite("TutorialSlides", tests)
return { pass = pass, fail = fail, failures = failures }

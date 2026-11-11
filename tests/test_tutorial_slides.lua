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
    H.assertTrue(#slides > 20, "the slides read: " .. #slides)
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

local pass, fail, failures = H.runSuite("TutorialSlides", tests)
return { pass = pass, fail = fail, failures = failures }

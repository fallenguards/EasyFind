-- Map pins cut square art round (MapSearch/Frames.lua SetPinIcon): a class
-- trainer's square class icon sat inside the round ring drawn round the pin.
-- Round art (the minimap's tracking icons, atlases like the flight path's)
-- and a creature's face are left as drawn.
local H = require("Harness")

local function Load()
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    ns.Utils.SetIconTexture = function() end
    ns.SetIconWell = function() end
    ns.Extensions = { Providers = { byCategory = {} } }
    H.loadModule("MapSearch/Frames.lua", env, ns)
    return ns.MapSearchFrames
end

local function Pin()
    local masks = {}
    local icon = { masks = masks }
    function icon:AddMaskTexture(m) masks[#masks + 1] = m end
    function icon:RemoveMaskTexture(m)
        for i = #masks, 1, -1 do if masks[i] == m then table.remove(masks, i) end end
    end
    setmetatable(icon, { __index = function(_, k)
        if type(k) == "string" and k:match("^%u") then return function() end end
    end })
    local pin = { icon = icon }
    function pin:CreateMaskTexture()
        return setmetatable({}, { __index = function() return function() end end })
    end
    return pin, masks
end

local tests = {}

function tests.squareArtIsCutRound()
    local Frames = Load()
    local pin, masks = Pin()
    Frames.SetPinIcon(pin, "atlas:classicon-druid")
    H.assertEq(#masks, 1, "a class icon")
    Frames.SetPinIcon(pin, "Interface\\Icons\\Trade_Alchemy")
    H.assertEq(#masks, 1, "a profession's icon, masked once")
end

function tests.roundArtAndFacesStayAsDrawn()
    local Frames = Load()
    local pin, masks = Pin()
    Frames.SetPinIcon(pin, "atlas:classicon-mage")
    Frames.SetPinIcon(pin, 136453)
    H.assertEq(#masks, 0, "a tracking icon: the mask comes off")
    Frames.SetPinIcon(pin, "atlas:TaxiNode_Neutral")
    H.assertEq(#masks, 0)
    Frames.SetPinIcon(pin, "Interface\\Icons\\INV_Misc_QuestionMark", true)
    H.assertEq(#masks, 0, "a creature's face")
end

local pass, fail, failures = H.runSuite("RoundPinIcons", tests)
return { pass = pass, fail = fail, failures = failures }

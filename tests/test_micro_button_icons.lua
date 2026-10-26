-- A result under a micro button wears that button's art (GetButtonIcon,
-- Search/Results/Icons.lua): retail's an atlas named by its textureName,
-- the classic clients' a file cropped to the button. MoP's Mounts showed
-- the question mark: the classic buttons have no textureName and were taken
-- for the character portrait (2026-10-26).
local H = require("Harness")

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Icons.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local BUTTON_ICON_REGIONS", 1, true))
    local fs = assert(src:find("local function GetButtonIcon", s, true))
    local _, e = assert(src:find("\nend\r?\n", fs))
    local env = setmetatable({}, { __index = _G })
    env._G = env
    return env, assert(load(src:sub(s, e) .. "\nreturn GetButtonIcon", "=Icons.lua GetButtonIcon", "t", env))()
end

local function ClassicButton(file)
    local normal = {
        GetTexture = function() return file end,
        GetAtlas = function() return nil end,
        GetTexCoord = function() return 0, 0.359375, 0, 1, 1, 0.359375, 1, 1 end,
    }
    return { GetNormalTexture = function() return normal end, GetRegions = function() end }
end

local tests = {}

function tests.aClassicMicroButton_givesItsFileCroppedToTheButton()
    local env, GetButtonIcon = Load()
    env.CollectionsMicroButton = ClassicButton("Interface\\Buttons\\UI-MicroButton-Mounts-Up")
    local icon, isAtlas = GetButtonIcon("CollectionsMicroButton")
    H.assertTrue(type(icon) == "table", "an icon, not the question mark")
    H.assertEq(icon.file, "Interface\\Buttons\\UI-MicroButton-Mounts-Up")
    H.assertEq(icon.coords[2], 0.359375, "the client's crop")
    H.assertTrue(not isAtlas)
end

function tests.retailsButton_givesItsAtlas()
    local env, GetButtonIcon = Load()
    env.CollectionsMicroButton = { textureName = "Collections" }
    local icon, isAtlas = GetButtonIcon("CollectionsMicroButton")
    H.assertEq(icon, "UI-HUD-MicroMenu-Collections-Up")
    H.assertTrue(isAtlas)
end

function tests.theCharacterButton_isStillThePortraitsCase()
    local env, GetButtonIcon = Load()
    env.CharacterMicroButton = ClassicButton("Interface\\Buttons\\UI-MicroButtonCharacter-Up")
    H.assertNil(GetButtonIcon("CharacterMicroButton"))
end

local pass, fail, failures = H.runSuite("MicroButtonIcons", tests)
return { pass = pass, fail = fail, failures = failures }

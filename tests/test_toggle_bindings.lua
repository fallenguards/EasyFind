-- Tests for the key binding rows with a checkbox (Apps/Settings/BlizzSearch.lua
-- TOGGLE_BINDING_STATE): a click on the row runs what the binding runs, and
-- its checkbox flips with it. Each binding below does what the client's own
-- code does (Bindings_Standard.xml and the functions it calls, Gethe's
-- wow-ui-source, the same on the forever, classic_era and
-- classic_anniversary branches): a row whose checkbox reads anything else
-- never moves. A toggle added to the table with no client behavior here fails.
local H = require("Harness")

local function Frame(shown)
    local f = { shown = shown }
    function f:IsShown() return self.shown end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:SetShown(on) self.shown = on and true or false end
    return f
end

-- What each binding does in the client, by its action name.
local CLIENT = {
    TOGGLEMINIMAP = "ToggleMinimap: Minimap:Hide() or Show(), the cluster untouched",
    TOGGLEMUSIC = "Sound_ToggleMusic: Sound_EnableMusic, while all sound is on",
    TOGGLESOUND = "Sound_ToggleSound: Sound_EnableSFX, Ambience and Dialog, while all sound is on",
    TOGGLEACTIONBARLOCK = "the lockActionBars setting, registered on its CVar",
    TOGGLEAUTOSELFCAST = "the autoSelfCast CVar, no setting registered for it",
    TOGGLE_VOICE_SELF_MUTE = "VoiceChat_ToggleMutedFromUserAction",
    TOGGLE_VOICE_SELF_DEAFEN = "VoiceChat_ToggleDeafenedFromUserAction",
    EASYFIND_TOGGLECHATFRAME = "EasyFind:ToggleChatFrames",
    TOGGLEWORLDMAP = "ToggleWorldMap",
    TOGGLEFPS = "FramerateFrame:Toggle: SetShown(not IsShown())",
    TOGGLEBATTLEFIELDMINIMAP = "ToggleBattlefieldMap",
}

local function load()
    local env = H.newEnv()
    env._G = env
    local cvars = { Sound_EnableAllSound = "1", Sound_EnableSFX = "1", Sound_EnableAmbience = "1",
        Sound_EnableDialog = "1", Sound_EnableMusic = "1", lockActionBars = "0", autoSelfCast = "1" }
    env.GetCVar = function(name) return cvars[name] end
    env.SetCVar = function(name, v)
        if type(v) == "boolean" then v = v and "1" or "0" end
        cvars[name] = tostring(v)
    end
    local registered = {
        lockActionBars = {
            GetValue = function() return cvars.lockActionBars == "1" end,
            SetValue = function(_, v) cvars.lockActionBars = v and "1" or "0" end,
        },
    }
    env.Settings = {
        GetSetting = function(v) return registered[v] end,
        GetValue = function(v) return registered[v] and registered[v]:GetValue() end,
        SetValue = function(v, value)
            if not registered[v] then error(string.format("Setting for variable '%s' did not exist.", v)) end
            registered[v]:SetValue(value)
        end,
    }
    env.Minimap, env.MinimapCluster = Frame(true), Frame(true)
    env.ToggleMinimap = function()
        if env.Minimap:IsShown() then env.Minimap:Hide() else env.Minimap:Show() end
    end
    env.Sound_ToggleMusic = function()
        if cvars.Sound_EnableAllSound == "0" then return end
        env.SetCVar("Sound_EnableMusic", cvars.Sound_EnableMusic == "0" and 1 or 0)
    end
    env.Sound_ToggleSound = function()
        if cvars.Sound_EnableAllSound == "0" then return end
        local v = cvars.Sound_EnableSFX == "0" and 1 or 0
        env.SetCVar("Sound_EnableSFX", v)
        env.SetCVar("Sound_EnableAmbience", v)
        env.SetCVar("Sound_EnableDialog", v)
    end
    local voice = { muted = false, deafened = false }
    env.C_VoiceChat = {
        IsMuted = function() return voice.muted end,
        IsDeafened = function() return voice.deafened end,
    }
    env.VoiceChat_ToggleMutedFromUserAction = function() voice.muted = not voice.muted end
    env.VoiceChat_ToggleDeafenedFromUserAction = function() voice.deafened = not voice.deafened end
    env.ChatFrame1 = Frame(true)
    env.WorldMapFrame = Frame(false)
    env.ToggleWorldMap = function() env.WorldMapFrame:SetShown(not env.WorldMapFrame:IsShown()) end
    env.FramerateFrame = Frame(false)
    function env.FramerateFrame:Toggle() self:SetShown(not self:IsShown()) end
    env.BattlefieldMapFrame = Frame(false)
    env.ToggleBattlefieldMap = function() env.BattlefieldMapFrame:SetShown(not env.BattlefieldMapFrame:IsShown()) end
    local ns = H.newNs(env)
    ns.Database.uiSearchData = {}
    env.EasyFind._ns = ns
    env.EasyFind.ToggleChatFrames = function() env.ChatFrame1:SetShown(not env.ChatFrame1:IsShown()) end
    H.loadModule("Search/Openers.lua", env, ns)
    H.loadModule("Apps/Settings/BlizzSearch.lua", env, ns)
    return ns.BlizzOptionsSearch, cvars, env
end

-- The actions with a checkbox, read off the table in the source.
local function StatefulActions()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Settings/BlizzSearch.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local TOGGLE_BINDING_STATE = {", 1, true), "TOGGLE_BINDING_STATE not in BlizzSearch.lua")
    local e = assert(src:find("\n}", s, true), "end of TOGGLE_BINDING_STATE not found")
    local list = {}
    for name in src:sub(s, e):gmatch("\n    ([A-Z_0-9]+) = {") do list[#list + 1] = name end
    return list
end

local tests = {}

function tests.everyCheckboxFlipsWithItsBinding()
    local Blizz = load()
    local actions = StatefulActions()
    H.assertTrue(#actions >= 10, "the toggles read off the source: " .. #actions)
    for _, action in ipairs(actions) do
        H.assertNotNil(CLIENT[action], action .. ": write what the client's binding does into this test's CLIENT and load()")
        local before = Blizz:GetToggleBindingState(action)
        H.assertNotNil(before, action .. ": its checkbox reads nothing")
        H.assertTrue(Blizz:PerformBinding(action), action .. ": the click ran nothing")
        H.assertEq(Blizz:GetToggleBindingState(action), not before, action .. ": its checkbox reads what the binding does not flip")
        H.assertTrue(Blizz:PerformBinding(action), action .. ": the second click ran nothing")
        H.assertEq(Blizz:GetToggleBindingState(action), before, action .. ": a second click flips it back")
    end
end

function tests.toggleSoundLeavesTheMasterSwitch()
    local Blizz, cvars = load()
    Blizz:PerformBinding("TOGGLESOUND")
    H.assertEq(cvars.Sound_EnableAllSound, "1", "the binding never touches all sound")
    H.assertEq(cvars.Sound_EnableSFX, "0")
    H.assertFalse(Blizz:GetToggleBindingState("TOGGLESOUND"), "effects off: unchecked")
end

function tests.selfCastFlipsItsCVarWithNoSetting()
    local Blizz, cvars = load()
    H.assertTrue(Blizz:PerformBinding("TOGGLEAUTOSELFCAST"), "no setting registered: the CVar itself")
    H.assertEq(cvars.autoSelfCast, "0")
    H.assertEq(cvars.lockActionBars, "0", "the action bars stay as they were")
end

local pass, fail, failures = H.runSuite("ToggleBindings", tests)
return { pass = pass, fail = fail, failures = failures }

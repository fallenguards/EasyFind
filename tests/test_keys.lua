-- Keybinds both ways (2026-11-19): an ability row names the key its bar
-- slot is bound to, and a key typed alone answers what it is bound to.
local H = require("Harness")

local function World()
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    local frames, combat = {}, false
    env.CreateFrame = function()
        local f = H.newFrame()
        frames[#frames + 1] = f
        return f
    end
    env.InCombatLockdown = function() return combat end
    -- Bar buttons: the main bar on page 2 (slot 13 up), bottom left bar at 61.
    for i = 1, 12 do
        env["ActionButton" .. i] = { action = 12 + i }
        env["MultiBarBottomLeftButton" .. i] = { action = 60 + i }
    end
    env.BT4Button7 = { GetAttribute = function(_, k) return k == "action" and 99 or nil end }
    local t = {
        keys = { ACTIONBUTTON3 = "SHIFT-3", MULTIACTIONBAR1BUTTON1 = "F" },
        actions = { ["SHIFT-3"] = "ACTIONBUTTON3", F = "MULTIACTIONBAR1BUTTON1", M = "TOGGLEWORLDMAP",
                    ["CTRL-SHIFT-F"] = "CLICK BT4Button7:LeftButton", ["ALT-1"] = "SPELL Fireball",
                    ["2"] = "ACTIONBUTTON2" },
        slots = { [15] = { "spell", 133 }, [61] = { "macro", 7 }, [99] = { "item", 858 } },
        frames = frames, fight = function(on) combat = on end, rebuilds = 0,
    }
    env.GetBindingKey = function(command) t.rebuilds = t.rebuilds + 1 return t.keys[command] end
    env.GetBindingAction = function(key) return t.actions[key] or "" end
    env.GetBindingText = function(key) return key:sub(1, 1) .. key:sub(2):lower() end
    env.GetActionInfo = function(slot) local a = t.slots[slot] if a then return a[1], a[2] end end
    env.GetActionText = function(slot) return slot == 61 and "Burst" or nil end
    env.GetActionTexture = function() return 4 end
    env.GetMacroSpell = function(id) return id == 7 and 12472 or nil end
    env.C_Spell = { GetSpellName = function(id) return ({ [133] = "Fireball", [12472] = "Icy Veins" })[id] end,
                    GetSpellTexture = function(id) return id end }
    env.C_Item = { GetItemNameByID = function() return "Lesser Healing Potion" end, GetItemIconByID = function() return 9 end }
    env.BINDING_NAME_TOGGLEWORLDMAP = "Toggle World Map"
    env.BINDING_NAME_ACTIONBUTTON3 = "Action Button 3"
    env.BINDING_NAME_ACTIONBUTTON2 = "Action Button 2"
    env.BINDING_NAME_MULTIACTIONBAR1BUTTON1 = "Bottom Left Action Button 1"
    env.GetBindingName = function(command) return command end
    H.loadModule("Search/Keys.lua", env, ns)
    return ns.Keys, t, env, ns
end

local tests = {}

function tests.aTypedKey_isModifiersThenOneKey()
    local Keys = World()
    H.assertEq(Keys.Parse("shift 3"), "SHIFT-3")
    H.assertEq(Keys.Parse("Shift-3"), "SHIFT-3")
    H.assertEq(Keys.Parse("shift+ctrl f"), "CTRL-SHIFT-F", "the game's own order of modifiers")
    H.assertEq(Keys.Parse("ctrl-alt-shift-f5"), "ALT-CTRL-SHIFT-F5")
    H.assertEq(Keys.Parse("f"), "F")
    H.assertEq(Keys.Parse("shift -"), "SHIFT--", "the minus key itself")
    H.assertEq(Keys.Parse("alt mouse4"), "ALT-BUTTON4")
    H.assertEq(Keys.Parse("shift mousewheelup"), "SHIFT-MOUSEWHEELUP", "the game's own name for the wheel")
    H.assertEq(Keys.Parse("numpad 5") or "none", "none", "two words, the first no modifier")
    H.assertEq(Keys.Parse("num5"), "NUMPAD5")
    H.assertNil(Keys.Parse("fire"), "a word is no key")
    H.assertNil(Keys.Parse("shift"), "a modifier alone is no key")
    H.assertNil(Keys.Parse("shift shift f"), "a modifier twice")
    H.assertNil(Keys.Parse("f13"))
end

function tests.aTypedKey_answersWhatItIsBoundTo()
    local Keys = World()
    local key, what, icon = Keys.Answer("shift 3")
    H.assertEq(key, "Shift-3", "written as the game writes it")
    H.assertEq(what, "Fireball (Action Button 3)", "the spell in the slot the button presses on this page")
    H.assertEq(icon, 133)
    H.assertEq(select(2, Keys.Answer("key f")), "Burst (Bottom Left Action Button 1)", "a macro by its name")
    H.assertEq(select(2, Keys.Answer("key m")), "Toggle World Map", "any other binding by its name")
    H.assertEq(select(2, Keys.Answer("ctrl shift f")), "Lesser Healing Potion (CLICK BT4Button7:LeftButton)",
        "a clicked bar button: what its slot holds")
    H.assertEq(select(2, Keys.Answer("alt 1")), "Fireball", "a spell bound outright")
    H.assertNil(Keys.Answer("key x"), "an unbound key says nothing")
    H.assertNil(Keys.Answer("frost"))
end

-- A letter or digit alone is how every search starts ("what is the point
-- of this", 2026-11-20): only "key t" asks for it. A button that holds
-- nothing answers nothing either way.
function tests.aLetterAlone_answersNothing()
    local Keys, t = World()
    H.assertNil(Keys.Answer("f"), "a letter alone")
    H.assertNil(Keys.Answer("m"))
    H.assertNil(Keys.Answer("2"), "a digit alone")
    H.assertEq(select(1, Keys.Answer("key f")), "F", "asked for by word")
    H.assertEq(select(2, Keys.Answer("f5")) or "none", "none", "a named key with nothing bound")
    t.actions.F5 = "TOGGLEWORLDMAP"
    H.assertEq(select(2, Keys.Answer("f5")), "Toggle World Map", "a named key alone still answers")
    H.assertNil(Keys.Answer("key 2"), "an empty bar button")
    t.actions["SHIFT-4"] = "ACTIONBUTTON4"
    H.assertNil(Keys.Answer("shift 4"), "an empty button under a modifier too")
    t.actions["ALT-Q"] = "CLICK NoSuchButton:LeftButton"
    H.assertNil(Keys.Answer("alt q"), "a clicked button that is not there")
end

function tests.aSpellOnTheBars_namesItsKey()
    local Keys, t = World()
    H.assertEq(Keys.SpellKey(133), "Shift-3")
    H.assertEq(Keys.SpellKey(12472), "F", "the spell a macro casts")
    H.assertEq(Keys.SpellKey(25306, "Fireball"), "Shift-3", "another rank, by its name")
    H.assertNil(Keys.SpellKey(1, "Frostbolt"))
    local reads = t.rebuilds
    Keys.SpellKey(133)
    H.assertEq(t.rebuilds, reads, "the bars are read once, not per row")
end

function tests.theBarsAreReadAgain_whenABindingOrSlotChanges_neverInAFight()
    local Keys, t = World()
    H.assertEq(Keys.SpellKey(133), "Shift-3")
    t.keys.ACTIONBUTTON3 = "G"
    H.assertEq(Keys.SpellKey(133), "Shift-3", "no event yet")
    local watcher = t.frames[1]
    t.fight(true)
    watcher._handlers.OnEvent(watcher, "UPDATE_BINDINGS")
    H.assertEq(Keys.SpellKey(133), "Shift-3", "in a fight the last reading stands")
    t.fight(false)
    H.assertEq(Keys.SpellKey(133), "G")
end

function tests.theAnswerRow_forATypedKey()
    local Keys, _, env, ns = World()
    env.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    H.loadModule("Search/Answers.lua", env, ns)
    local row = ns.Answers:GetAnswerEntry("Shift 3")
    H.assertEq(row.name, "Shift-3")
    H.assertEq(row.searchCommandDesc, "Fireball (Action Button 3)")
    H.assertEq(row.glyph.tex, 133, "the spell's icon")
    H.assertEq(ns.Answers:GetAnswerEntry("Key M").glyph.tex, "Interface\\Icons\\INV_Misc_Key_14", "a key glyph otherwise")
    H.assertNil(ns.Answers:GetAnswerEntry("m"), "a letter alone: no row over the search")
    H.assertNil(ns.Answers:GetAnswerEntry("key x"))
    H.assertTrue(Keys ~= nil)
end

local pass, fail, failures = H.runSuite("Keys", tests)
return { pass = pass, fail = fail, failures = failures }

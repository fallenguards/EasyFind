-- Abilities by what they do (2026-11-19): the words of each known spell's
-- description join its row's keywords ("stun", "interrupt", "slow"), out
-- of combat; a word many descriptions share is left out.
local H = require("Harness")

local DESCRIPTIONS = {
    [1] = "Hurls a fiery ball that causes 100 Fire damage to the target.",
    [2] = "Counters the enemy's spellcast, |cffffffffpreventing|r any spell from that school for 8 sec. Interrupts the target.",
    [3] = "Blasts enemies near the caster for 50 Frost damage and freezes them in place for up to 8 sec. Damage caused may interrupt the effect.",
    [4] = "Launches a bolt of frost at the enemy, causing 20 Frost damage and slowing movement speed by 40% for 5 sec. Deals damage to the target.",
    [5] = "Transforms the enemy into a sheep. Any damage will transform the target back.",
    [6] = "Stuns the target for 4 sec, causing damage.",
}

local function World(opts)
    opts = opts or {}
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    H.loadModule("Shared/SearchText.lua", env, ns)
    local frames, combat = {}, opts.combat
    env.CreateFrame = function()
        local f = H.newFrame()
        f._events = {}
        f.RegisterEvent = function(self, event) self._events[event] = true end
        f.UnregisterEvent = function(self, event) self._events[event] = nil end
        frames[#frames + 1] = f
        return f
    end
    env.InCombatLockdown = function() return combat end
    local asked = {}
    env.C_Spell = {
        GetSpellDescription = function(id) return (opts.descriptions or DESCRIPTIONS)[id] or "" end,
        RequestLoadSpellData = function(id) asked[#asked + 1] = id end,
    }
    local dirty = {}
    ns.Database.MarkDynamicCategoryDirty = function(_, key) dirty[#dirty + 1] = key end
    local shared = { "talent", "talents" }
    ns.Database.uiSearchData = {
        { name = "Fireball", category = "Ability", spellID = 1, keywords = { "fireball", "ability" } },
        { name = "Counterspell", category = "Ability", spellID = 2, keywords = { "counterspell", "ability" } },
        { name = "Frost Nova", category = "Ability", spellID = 3, keywords = { "frost nova", "ability" } },
        { name = "Frostbolt", category = "Ability", spellID = 4, keywords = { "frostbolt", "ability" } },
        { name = "Polymorph", category = "Ability", spellID = 5, keywords = { "polymorph", "ability" } },
        { name = "Hammer", category = "Talent", spellID = 6, keywords = shared, keywordsLower = shared },
        { name = "Other Talent", category = "Talent", spellID = 9, keywords = shared, keywordsLower = shared },
        { name = "Linen Cloth", category = "Item", itemID = 5, keywords = { "linen cloth" } },
    }
    H.loadModule("Database/SpellWords.lua", env, ns)
    return ns.Database, {
        frames = frames, asked = asked, dirty = dirty, shared = shared,
        fight = function(on) combat = on end, clock = env.__clock,
    }
end

local function Has(row, word)
    for _, kw in ipairs(row.keywords) do if kw == word then return true end end
    return false
end

local tests = {}

function tests.anAbility_answersTheWordsOfWhatItDoes()
    local Database = World()
    Database:AddSpellWords("Ability", "abilities")
    local rows = Database.uiSearchData
    H.assertTrue(Has(rows[2], "interrupts"), "Counterspell interrupts")
    H.assertTrue(Has(rows[2], "preventing"), "a colored word is still a word")
    H.assertTrue(Has(rows[4], "slowing"), "Frostbolt slows")
    H.assertTrue(Has(rows[5], "sheep"))
    H.assertTrue(Has(rows[2], "counterspell") and Has(rows[2], "ability"), "its own keywords stay, first")
    H.assertEq(rows[2].keywords[1], "counterspell")
end

function tests.aWordMostDescriptionsShare_isLeftOut()
    local Database = World()
    Database:AddSpellWords("Ability", "abilities")
    for i = 1, 5 do
        H.assertFalse(Has(Database.uiSearchData[i], "damage"), "all five say damage: " .. Database.uiSearchData[i].name)
        H.assertFalse(Has(Database.uiSearchData[i], "target"), "four say target")
    end
    H.assertFalse(Has(Database.uiSearchData[1], "100"), "no numbers")
    H.assertFalse(Has(Database.uiSearchData[1], "a"), "no short words")
end

function tests.onlyTheCategorysRows_andASharedKeywordTableIsCopied()
    local Database, t = World()
    Database:AddSpellWords("Talent", "talents")
    local rows = Database.uiSearchData
    H.assertTrue(Has(rows[6], "stuns"), "the talent's own words")
    H.assertTrue(rows[6].keywordsLower == rows[6].keywords, "both keyword fields are the new table")
    H.assertEq(#t.shared, 2, "the table two talents share is untouched")
    H.assertTrue(rows[7].keywords == t.shared, "a talent with no description keeps it")
    H.assertEq(#rows[1].keywords, 2, "an ability is left for its own pass")
    H.assertEq(#rows[8].keywords, 1, "an item is never touched")
end

function tests.inAFight_nothingIsRead_andTheRowsAreMadeAgainAfterIt()
    local Database, t = World({ combat = true })
    Database:AddSpellWords("Ability", "abilities")
    H.assertEq(#Database.uiSearchData[2].keywords, 2, "untouched in a fight")
    local watcher = t.frames[1]
    H.assertTrue(watcher._events.PLAYER_REGEN_ENABLED, "waits for the fight's end")
    t.fight(false)
    watcher._handlers.OnEvent(watcher, "PLAYER_REGEN_ENABLED")
    H.assertEq(t.dirty[1], "abilities", "the provider populates again")
    H.assertNil(watcher._events.PLAYER_REGEN_ENABLED, "and the event is let go")
end

function tests.aDescriptionNotInYet_isAskedFor_andReadOnceMore()
    local Database, t = World()
    Database:AddSpellWords("Talent", "talents")
    H.assertEq(t.asked[1], 9, "the talent with no text yet")
    local later = #t.dirty
    Database:AddSpellWords("Talent", "talents")
    H.assertEq(#t.asked, 2)
    H.assertEq(#t.dirty, later, "no loop: one retry is scheduled a session")
end

local pass, fail, failures = H.runSuite("SpellWords", tests)
return { pass = pass, fail = fail, failures = failures }

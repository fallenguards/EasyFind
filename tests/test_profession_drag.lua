-- Shift+drag on a profession row puts its spell on the cursor, for the
-- action bar (Search/Results/Rows/Interactions.lua Rows.CanPickUp); it
-- picked up nothing (Forever, 2026-11-16).
local H = require("Harness")

local tests = {}

function tests.shiftDrag_picksUpTheProfessionsSpell()
    local env = H.newEnv()
    local ns = H.newNs(env)
    ns.ResultIcons.IsSpellbookOnlyAbility = function() return false end
    H.loadModule("Search/Results/Rows/Interactions.lua", env, ns)
    local CanPickUp = ns.ResultRows.CanPickUp
    H.assertTrue(CanPickUp({ name = "First Aid", category = "Profession", spellID = 3273, professionSkillLine = 129 }))
    H.assertTrue(CanPickUp({ name = "Tailoring", category = "Profession", spellID = 3908, classicProfession = "Tailoring" }),
        "a classic client's profession row")
    H.assertFalse(CanPickUp({ name = "Bolt of Linen Cloth", category = "Profession", spellID = 3908, classicRecipe = true }),
        "a classic recipe row carries its window's spell, not its own")
    H.assertFalse(CanPickUp({ name = "Linen Bandage", category = "Profession", professionRecipeID = 3275 }))
    H.assertTrue(CanPickUp({ name = "Fireball", category = "Ability", spellID = 133 }))
end

local pass, fail, failures = H.runSuite("ProfessionDrag", tests)
return { pass = pass, fail = fail, failures = failures }

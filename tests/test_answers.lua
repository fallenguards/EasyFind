-- The answer rows (Search/Answers.lua): a word typed alone pins a live
-- value above the results. Reset timers and the character's stats
-- (2026-11-19); a stat the game hands over secret is never computed
-- with or formatted by our code.
local H = require("Harness")

local function Load(setup)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    env.SecondsToTime = function(seconds) return math.floor(seconds / 60) .. " min" end
    env._G = env
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    if setup then setup(env, ns) end
    H.loadModule("Search/Answers.lua", env, ns)
    return ns.Answers, env, ns
end

local tests = {}

function tests.reset_answersTheDailyAndWeeklyTimers()
    local Answers = Load(function(env)
        env.C_DateAndTime = { GetSecondsUntilDailyReset = function() return 3600 end,
                              GetSecondsUntilWeeklyReset = function() return 7200 end }
        env.DAILY, env.WEEKLY = "Daily", "Weekly"
    end)
    local row = Answers:GetAnswerEntry(" Reset ")
    H.assertNotNil(row, "a row for reset")
    H.assertEq(row.name, "ANSWER_RESETS")
    H.assertEq(row.searchCommandDesc, "Daily: 60 min, Weekly: 120 min")
    H.assertEq(row.copyText, row.searchCommandDesc, "a copy row")
end

function tests.reset_withoutTheCalendarCalls_readsTheQuestReset()
    local Answers = Load(function(env)
        env.C_DateAndTime = nil
        env.GetQuestResetTime = function() return 600 end
    end)
    H.assertEq(Answers:GetAnswerEntry("resets").searchCommandDesc, "Daily: 10 min", "the daily one alone")
end

function tests.aStat_answersItsNumbers()
    local Answers = Load(function(env, ns)
        ns.Caps = { era = true, classic = true }
        env.GetCritChance = function() return 5.5 end
        env.GetRangedCritChance = function() return 4 end
        env.GetSpellCritChance = function(school) return school == 5 and 9.25 or 3 end
        env.UnitArmor = function() return 100, 250 end
        env.UnitDefense = function() return 300, 12 end
        env.STAT_CRITICAL_STRIKE = "Kritischer Treffer"
    end)
    local row = Answers:GetAnswerEntry("crit")
    H.assertEq(row.name, "Kritischer Treffer", "the client's own label")
    H.assertEq(row.searchCommandDesc, "Melee 5.50%, Ranged 4.00%, Spell 9.25%", "the best spell school")
    H.assertEq(Answers:GetAnswerEntry("kritischer treffer").searchCommandDesc, row.searchCommandDesc,
        "and by its name in the client's language")
    H.assertEq(Answers:GetAnswerEntry("armor").searchCommandDesc, "250", "the armor that counts")
    H.assertEq(Answers:GetAnswerEntry("defense").searchCommandDesc, "312", "skill and what gear adds")
end

function tests.aStatTheClientLacks_hasNoRow()
    local Answers = Load(function(env, ns)
        ns.Caps = { retail = true }
        env.GetHitModifier = function() return 3 end
        env.GetHaste = nil
    end)
    H.assertNil(Answers:GetAnswerEntry("hit"), "retail has no hit")
    H.assertNil(Answers:GetAnswerEntry("haste"), "no call, no row")
    H.assertNil(Answers:GetAnswerEntry("defense"), "a classic stat")
end

-- A secret number errors on any compare, sum or format our code does.
function tests.aSecretStat_reachesTheRowUntouched()
    local SECRET = setmetatable({}, {
        __add = function() error("arithmetic on a secret") end,
        __lt = function() error("compare on a secret") end,
        __le = function() error("compare on a secret") end,
        __tostring = function() error("a secret turned into text") end,
    })
    local Answers = Load(function(env)
        env.issecretvalue = function(v) return v == SECRET end
        env.GetCritChance = function() return SECRET end
        env.GetRangedCritChance = function() return SECRET end
        env.GetSpellCritChance = function() return SECRET end
        env.UnitAttackPower = function() return SECRET, SECRET, SECRET end
        env.UnitRangedAttackPower = function() return 10, 2, 0 end
        env.UnitArmor = function() return 5, 7 end
    end)
    local row = Answers:GetAnswerEntry("crit")
    H.assertNotNil(row, "still a row")
    H.assertNil(row.searchCommandDesc, "no text of ours")
    H.assertNil(row.copyText, "and nothing to copy")
    H.assertEq(row.secretFormat, "Melee %.2f%%, Ranged %.2f%%, Spell %.2f%%")
    H.assertTrue(row.secretArgs[1] == SECRET and row.secretArgs[3] == SECRET, "the values as the game gave them")
    local ap = Answers:GetAnswerEntry("attack power")
    H.assertTrue(ap.secretArgs[1] == SECRET, "melee attack power unsummed")
    H.assertEq(ap.secretArgs[2], 12, "ranged summed, it was plain")
    local armor = Answers:GetAnswerEntry("armor")
    H.assertNil(armor.secretFormat, "the next plain answer is plain again")
    H.assertEq(armor.searchCommandDesc, "7")
end

local pass, fail, failures = H.runSuite("Answers", tests)
return { pass = pass, fail = fail, failures = failures }

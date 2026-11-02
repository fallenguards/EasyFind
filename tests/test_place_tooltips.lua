-- A place or creature row's own tooltip (Search/Results/Tooltips.lua
-- SetMapRowTooltip) and a boss row's (SetBossTooltip): map rows had none,
-- so an extension's lines (what a creature casts) had nothing to sit
-- under, and a boss row said nothing on hover. The tooltip adds what the
-- row cannot: the spot, the distance, the spot count; the boss's drops.
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local ENGLISH = {
    GPS_UNIT_YD = "%d yd", TT_PLACE_AT_FMT = "%s at %s", TT_PLACE_AWAY_FMT = "%s away",
    TT_PLACE_SPOTS_FMT = "%d spots, the nearest shown", TT_BOSS_DROPS_FMT = "Drops %d items",
}

local function Load(caps)
    local src = Read("Search/Results/Tooltips.lua")
    local s = assert(src:find("function Tooltips:SetMapRowTooltip", 1, true))
    local e = assert(src:find("function Tooltips:SetGameTooltipForResult", s, true))
    local env = { Tooltips = {}, L = setmetatable({}, { __index = function(_, k) return ENGLISH[k] or k end }),
                  sformat = string.format, mfloor = math.floor, math = math, ns = { Caps = caps } }
    assert(load(src:sub(s, e - 1), "=Tooltips.lua", "t", setmetatable(env, { __index = _G })))()
    return env.Tooltips
end

local function Tip()
    local tip = { lines = {} }
    function tip:SetText(text) self.lines[1] = text end
    function tip:AddLine(text) self.lines[#self.lines + 1] = text end
    function tip:SetHyperlink(link) self.link = link end
    return tip
end

local tests = {}

function tests.aPlaceRow_saysWhereHowFarAndHowMany()
    local T = Load({})
    local tip = Tip()
    T:SetMapRowTooltip(tip, { name = "Duskbat", zoneName = "Tirisfal Glades", x = 0.614, y = 0.523,
        mapNear = 410 * 410, spotCount = 3 })
    H.assertEq(tip.lines[1], "Duskbat")
    H.assertEq(tip.lines[2], "Tirisfal Glades at 61.4, 52.3")
    H.assertEq(tip.lines[3], "410 yd away")
    H.assertEq(tip.lines[4], "3 spots, the nearest shown")
    H.assertEq(#tip.lines, 4)
end

function tests.aPlaceRow_leavesOutWhatItLacks()
    local T = Load({})
    local tip = Tip()
    T:SetMapRowTooltip(tip, { name = "Innkeeper", x = 0.5, y = 0.25, mapNear = math.huge, spotCount = 1 })
    H.assertEq(tip.lines[2], "50.0, 25.0", "no zone: the spot alone")
    H.assertEq(#tip.lines, 2, "no distance off the continent, one spot unsaid")
end

function tests.aBossRow_onTheClassicClients_saysWhatItDrops()
    local T = Load({ journal = false, instanceTable = true })
    local tip = Tip()
    T:SetBossTooltip(tip, { name = "Ragnaros", encounterID = 672, lootCount = 23 })
    H.assertEq(tip.lines[1], "Ragnaros")
    H.assertEq(tip.lines[2], "Drops 23 items")
    H.assertNil(tip.link)
    tip = Tip()
    T:SetBossTooltip(tip, { name = "Rethilgore", encounterID = 2748 })
    H.assertEq(#tip.lines, 1, "no drops known: the name alone")
end

function tests.aBossRow_withTheJournal_showsTheJournalsTooltip()
    local T = Load({ journal = true, instanceTable = false })
    local tip = Tip()
    T:SetBossTooltip(tip, { name = "Ragnaros", encounterID = 672 })
    H.assertEq(tip.link, "journal:1:672:14")
    H.assertEq(#tip.lines, 0)
    -- WoW Forever: the journal's functions with no tiers; our table's bosses.
    T = Load({ journal = true, instanceTable = true })
    tip = Tip()
    T:SetBossTooltip(tip, { name = "Ragnaros", encounterID = 672, lootCount = 5 })
    H.assertNil(tip.link)
    H.assertEq(tip.lines[2], "Drops 5 items")
end

function tests.theRowHover_opensThem()
    local rows = Read("Search/Results/Rows/Tooltips.lua")
    H.assertTrue(rows:find("Tooltips:SetMapRowTooltip(GameTooltip, self.data)", 1, true) ~= nil, "a map row")
    H.assertTrue(rows:find('if self.data.category == "Boss" then', 1, true) ~= nil
        and rows:find("Tooltips:SetBossTooltip(GameTooltip, self.data)", 1, true) ~= nil, "a boss row")
    H.assertTrue(Read("MapSearch/Search/Results.lua"):find("d.spotCount = r.allInstances and #r.allInstances or nil", 1, true) ~= nil,
        "the bar row carries how many spots fold into it")
    H.assertTrue(Read("Database/Main.lua"):find("entry.lootCount = boss.items and #boss.items or nil", 1, true) ~= nil,
        "a static boss carries its loot count")
    for _, loc in ipairs({ "enUS", "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }) do
        local src = Read("Locales/" .. loc .. ".lua")
        for _, key in ipairs({ "TT_PLACE_AT_FMT", "TT_PLACE_AWAY_FMT", "TT_PLACE_SPOTS_FMT", "TT_BOSS_DROPS_FMT" }) do
            H.assertTrue(src:find(("L[%q]"):format(key), 1, true) ~= nil, loc .. " has " .. key)
        end
    end
end

local pass, fail, failures = H.runSuite("PlaceTooltips", tests)
return { pass = pass, fail = fail, failures = failures }

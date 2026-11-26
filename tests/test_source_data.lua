-- Where an item comes from, on the shipped data (Apps/Sources): the item
-- sources page said "No known source" for most items of Forever, Era and
-- TBC until this data came into EasyFind (2026-11-21). The companion's
-- sections on each client's real data file, the page that shows them, and
-- the funnel that reads the companion in on the first page, never at login.
local H = require("Harness")

local TOC = "Apps/Sources/EasyFind_Sources.toc"
local SILVER_ROD, SILVER_BAR, WEAK_FLUX = 6338, 2842, 3470
local LINEN, HEAVY_LINEN_BANDAGE = 2589, 2581
local COPPER_ORE, HEARTHSTONE = 2770, 6948
local SPELLS = { [2018] = "Blacksmithing", [3273] = "First Aid", [2550] = "Cooking", [2575] = "Mining",
                 [2366] = "Herb Gathering", [7818] = "Silver Rod", [3276] = "Heavy Linen Bandage" }
local FILE = { era = "Data_Era.lua", tbc = "Data_TBC.lua", forever = "Data_Forever.lua" }

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"), path)
    local s = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return s
end

local english
local function English()
    if not english then
        english = {}
        local src = Read("Locales/enUS.lua")
        for _, prefix in ipairs({ "SOURCES_", "MATS_" }) do
            for key, text in src:gmatch('\nL%["(' .. prefix .. '[%w_]+)"%]%s*=%s*"([^\n]*)"') do
                english[key] = text:gsub('\\"', '"')
            end
        end
    end
    return english
end

-- The companion as a client reads it: Sources.lua, then that client's data.
local function Load(opts)
    opts = opts or {}
    local client = opts.client or "era"
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind = { _ns = ns }
    ns.Caps = { [client] = true }
    ns.L = setmetatable({}, { __index = function(_, k) return English()[k] or k end })
    env.C_Spell = { GetSpellName = function(id) return SPELLS[id] end }
    env.C_Map = { GetMapInfo = function(m) return { name = "Map " .. m } end }
    env.C_QuestLog = { GetTitleForQuestID = function() return nil end }
    env.C_TradeSkillUI = nil
    env.UnitFactionGroup = function() return opts.faction or "Alliance" end
    local own = {}
    for _, f in ipairs({ "Sources.lua", "Data_Era.lua", "Data_TBC.lua", "Data_Forever.lua" }) do
        local chunk = assert(loadfile(H.ADDON_ROOT .. "/Apps/Sources/" .. f, "t", env))
        chunk("EasyFind_Sources", own)
    end
    -- The sections by label: { label = rows }.
    local function Page(itemID)
        local out = {}
        for _, s in ipairs(ns.SourceData.Sections(itemID) or {}) do out[s.label] = s.rows end
        return out
    end
    return ns, Page
end

local function Find(rows, kind, id)
    for _, row in ipairs(rows or {}) do
        if row[kind] == id then return row end
    end
    return nil
end

local function Recipes(file)
    local out = {}
    for spell, rank, trainers in Read("Apps/Sources/" .. file):gmatch('\n    %[(%d+)%] = "%d+,(%d+),%d+,%d+,%d|[^|]*|([^|]*)|[^|"]*",') do
        out[tonumber(spell)] = { rank = tonumber(rank), trainers = trainers }
    end
    return out
end

local tests = {}

function tests.theCompanionLoadsOnDemand_eachClientItsOwnData()
    local toc = Read(TOC)
    H.assertTrue(toc:find("\n## LoadOnDemand: 1\n", 1, true) ~= nil, "loaded on demand")
    H.assertTrue(toc:find("\n## RequiredDeps: EasyFind\n", 1, true) ~= nil, "needs only EasyFind")
    H.assertTrue(toc:find("\nSources.lua\n", 1, true) ~= nil, "the code, before any data")
    H.assertTrue(toc:find("\nData_Era.lua [AllowLoadGameType vanilla]\n", 1, true) ~= nil, "Era's")
    H.assertTrue(toc:find("\nData_TBC.lua [AllowLoadGameType tbc]\n", 1, true) ~= nil, "TBC's")
    H.assertTrue(toc:find("\nData_Forever.lua [AllowLoadGameType camelot]\n", 1, true) ~= nil, "Forever's")
    local listed = false
    for _, t in ipairs(H.TOCS) do listed = listed or t == TOC end
    H.assertTrue(listed, "among the shipped tocs every toc test walks")
    H.assertNil(Read("EasyFind.toc"):find("Apps[/\\]Sources"), "nothing of it in the core's toc: none at login")
end

-- Forever's own spell tables lack the 1.12 trainers' teach spells: read
-- alone, its recipes lost every trainer and skill rank (2026-11-17).
function tests.forever_teachesEraRecipes_asEraDoes()
    local era, forever = Recipes("Data_Era.lua"), Recipes("Data_Forever.lua")
    local shared, same = 0, 0
    for spell, r in pairs(era) do
        local f = forever[spell]
        if f then
            shared = shared + 1
            if f.rank == r.rank and f.trainers == r.trainers then same = same + 1 end
        end
    end
    H.assertTrue(shared > 1000, "recipes on both clients: " .. shared)
    H.assertEq(same, shared, "Forever recipes with Era's rank and trainers")
end

function tests.silverRod_isCraftedByBlacksmithing_withItsReagentsAndTrainers()
    for _, client in ipairs({ "era", "forever" }) do
        local r = Recipes(FILE[client])[7818]
        H.assertTrue(r ~= nil and r.rank == 100 and r.trainers ~= "", client .. ": Silver Rod at 100 with trainers")
        local _, Page = Load({ client = client })
        local page = Page(SILVER_ROD)
        local rows = page["Crafted: Blacksmithing 100"]
        H.assertNotNil(rows, client .. ": a section for the recipe, its profession and rank")
        -- Its reagents a section of their own, worded as on its mats page
        -- (they sat among the trainers, 2026-11-26).
        local reagents = page["Reagents"]
        H.assertNotNil(reagents, client .. ": a Reagents section")
        H.assertEq(Find(reagents, "item", SILVER_BAR).note, "Need 1, have 0")
        H.assertEq(Find(reagents, "item", WEAK_FLUX).note, "Need 2, have 0")
        H.assertTrue(Find(reagents, "item", SILVER_BAR).ownCounted, "the own count said: Owned adds the alts")
        H.assertNil(Find(rows, "item", SILVER_BAR), "not among the trainers")
        local trainer
        for _, row in ipairs(rows) do
            if row.creature then trainer = row end
        end
        H.assertTrue(trainer ~= nil and trainer.note == "Teaches the recipe", client .. ": its trainers, creature rows")
    end
end

function tests.linenCloth_dropsFromCreatures_andIsAReagent()
    local _, Page = Load({ client = "forever" })
    local page = Page(LINEN)
    local drops = page["Dropped by"]
    H.assertTrue(drops ~= nil and drops[1].creature ~= nil, "creatures that drop it")
    H.assertTrue(drops[1].note:find("^[%d%.]+%% drop chance$") ~= nil, "each with its chance, said as one: " .. drops[1].note)
    H.assertTrue(#drops > 20, "every likely one, not the first eight: " .. #drops)
    for _, row in ipairs(drops) do
        H.assertTrue(row.creature ~= nil, "no line that only counts the rest")
    end
    local bandage = Find(page["Reagent for"], "item", HEAVY_LINEN_BANDAGE)
    H.assertEq(bandage and bandage.note, "First Aid 40, 2 needed")
end

function tests.copperOre_isGatheredFromVeins_eachWithItsSpots()
    local _, Page = Load()
    local vein
    for _, row in ipairs(Page(COPPER_ORE)["Gathered from"] or {}) do
        if row.name == "Copper Vein" then vein = row end
    end
    H.assertNotNil(vein, "Copper Vein")
    H.assertTrue(#vein.spots >= 3 and #vein.spots % 3 == 0, "its spots: map, x, y")
    H.assertTrue(vein.spots[2] > 0 and vein.spots[2] < 1, "x in the map's 0 to 1")
    H.assertEq(vein.note:match("^Mining"), "Mining", "the profession it needs")
end

function tests.anItemTheDataLacks_hasNoSections()
    local ns = Load()
    H.assertNil(ns.SourceData.Sections(HEARTHSTONE), "the hearthstone")
    H.assertFalse(ns.SourceData.Has(HEARTHSTONE))
    H.assertTrue(ns.SourceData.Has(LINEN))
end

function tests.theOtherFactionsQuests_areNotListed()
    local ns, Page = Load({ faction = "Alliance" })
    local D = ns.SOURCE_DATA
    local item
    for id, s in pairs(D.items) do
        local q = tonumber(s:match("q(%d+);") or s:match("q(%d+)$") or "")
        if q and D.quests[q] and D.quests[q]:match("^.-|%-?%d*|H|") and not s:match("[^;]*[cdwspofi]") then
            item = id
            break
        end
    end
    H.assertNotNil(item, "an item only a Horde quest rewards")
    H.assertNil(Page(item)["Quest reward"], "an Alliance player sees no Horde quest")
    local _, hordePage = Load({ faction = "Horde" })
    H.assertNotNil(hordePage(item)["Quest reward"], "a Horde player does")
end

function tests.everyClientsData_loadsOnItsClientOnly()
    for client, file in pairs(FILE) do
        local ns, Page = Load({ client = client })
        H.assertNotNil(ns.SOURCE_DATA, client .. ": its data")
        H.assertNotNil(Page(LINEN)["Dropped by"], client .. ": linen drops")
        H.assertTrue(Read("Apps/Sources/" .. file):find("\nif not (ns and ns.Caps and ns.Caps." .. client .. ") then return end\n", 1, true) ~= nil,
            file .. " stops on another client")
    end
    local ns = Load({ client = "mists" })
    H.assertNil(ns.SOURCE_DATA, "a client with no data file holds none")
    H.assertNil(ns.SourceData.Sections(LINEN), "and answers nothing")
end

-- ==== the page ================================================================

local function Sources(data)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind = { API = {} }
    local shown
    ns.L = setmetatable({}, { __index = function(_, k) return English()[k] or k end })
    ns.Extensions = { Run = function(fn, ...) return pcall(fn, ...) end }
    ns.Filters = { ApplyQuickFilter = function() end }
    ns.Results = { ShowHierarchicalResults = function(_, entries)
        shown = {}
        for i = 1, #entries do shown[i] = { name = entries[i].name, header = entries[i].isSectionHeader, data = entries[i].data } end
    end }
    ns.Database.uiSearchData = { { name = "Edwin VanCleef", category = "Boss", encounterID = 1588, instanceName = "The Deadmines" } }
    ns.STATIC_LOOT = { { inst = 36, enc = 1588, items = { LINEN } } }
    local asked = 0
    ns.RequestSourceData = function()
        asked = asked + 1
        if data then ns.SourceData = data end
        return data ~= nil
    end
    H.loadModule("Search/ItemSources.lua", env, ns)
    return ns.ItemSources, function() return shown end, function() return asked end
end

function tests.thePageShowsTheDatasSections_dropsJoinTheBossRows()
    local data = { Sections = function(itemID)
        if itemID ~= LINEN then return nil end
        return { { label = "Dropped by", key = "dropped", rows = { { name = "Defias Thug", note = "38%" } } },
                 { label = "Reagent for", rows = { { name = "Linen Bandage", note = "First Aid, 1 needed" } } } }
    end }
    local page, shown, asked = Sources(data)
    H.assertEq(asked(), 0, "nothing asked for until a page is built")
    local view = { sourcesItem = { itemID = LINEN, name = "Linen Cloth" } }
    page:ShowView(view, "")
    local rows = shown()
    H.assertEq(asked(), 1, "the first page asks for the data")
    H.assertEq(rows[1].name, "Dropped by")
    H.assertEq(rows[2].name, "Edwin VanCleef", "the boss rows first")
    H.assertEq(rows[3].name, "Defias Thug", "the creatures under the same heading")
    H.assertEq(rows[3].data.sourceNote, "38%")
    H.assertEq(rows[4].name, "Reagent for")
    H.assertTrue(rows[4].header)
    H.assertEq(#rows, 5)
    page:ShowView(view, "ban")
    H.assertEq(asked(), 1, "its sections stand while the page is up")
    H.assertEq(shown()[2].name, "Linen Bandage", "typing narrows them")
end

function tests.withoutTheData_thePageStandsOnTheCoresOwn()
    local page, shown = Sources(nil)
    page:ShowView({ sourcesItem = { itemID = LINEN, name = "Linen Cloth" } }, "")
    H.assertEq(#shown(), 2, "the boss alone")
    page:ShowView({ sourcesItem = { itemID = HEARTHSTONE, name = "Hearthstone" } }, "")
    H.assertEq(shown()[1].name, "No known source for Hearthstone")
end

-- ==== the funnel ==============================================================

local function Funnel(caps, loads)
    local src = Read("Search/Modules.lua")
    local s = assert(src:find("function ns.RequestSourceData()", 1, true))
    local e = assert(src:find("\nend\n", s, true))
    local ns = { Caps = caps }
    local loaded, warned = {}, {}
    local env = setmetatable({
        ns = ns,
        LoadCompanion = function(addon)
            loaded[#loaded + 1] = addon
            if loads then ns.SourceData = {} end
        end,
        WarnCompanion = function(addon, key) warned[#warned + 1] = addon .. " " .. key end,
    }, { __index = _G })
    assert(load(src:sub(s, e + 4), "=funnel", "t", env))()
    return ns, loaded, warned
end

function tests.theFunnelReadsTheCompanionInOnce_onlyWhereThereIsData()
    local ns, loaded, warned = Funnel({ sourceData = true }, true)
    H.assertTrue(ns.RequestSourceData())
    H.assertTrue(ns.RequestSourceData())
    H.assertEq(#loaded, 1, "loaded on the first ask only")
    H.assertEq(loaded[1], "EasyFind_Sources")
    H.assertEq(#warned, 0)
    local none, never = Funnel({ sourceData = false }, true)
    H.assertFalse(none.RequestSourceData(), "retail and Mists have no data file")
    H.assertEq(#never, 0, "and load nothing")
    local off, _, said = Funnel({ sourceData = true }, false)
    H.assertFalse(off.RequestSourceData(), "switched off in the AddOns list")
    H.assertEq(said[1], "EasyFind_Sources SOURCES_MODULE_DISABLED", "it says so")
    H.assertNotNil(English().SOURCES_MODULE_DISABLED, "in words of its own")
end

-- A read at login would cost every player its megabytes: the sources page
-- and a quest's rewards page, each on the player's own gesture, are the
-- callers.
function tests.onlyTheSourcesPageAsksForTheData()
    local callers, seen = {}, {}
    local p = assert(io.popen('grep -rn "RequestSourceData" "' .. H.ADDON_ROOT .. '" --include=*.lua'
        .. ' --exclude-dir=tests --exclude-dir=dev --exclude-dir=.git 2>/dev/null'))
    for line in p:lines() do
        local path, code = line:sub(#H.ADDON_ROOT + 2):match("^(.-):%d+:(.*)$")
        if path and not code:match("^%s*%-%-") and not seen[path] then
            seen[path] = true
            callers[#callers + 1] = (path:gsub("\\", "/"))
        end
    end
    p:close()
    table.sort(callers)
    H.assertEq(table.concat(callers, ", "), "Search/ItemSources.lua, Search/Modules.lua, Search/QuestRewards.lua")
    local rewards = Read("Search/QuestRewards.lua")
    local show = assert(rewards:find("\nfunction QuestRewards:Show(questID, title)\n", 1, true))
    local rcall = assert(rewards:find("ns.RequestSourceData()", 1, true))
    H.assertTrue(rcall > show and rcall < assert(rewards:find("\nend\n", show, true)), "inside its Show, on the gesture")
    H.assertNil(rewards:find("ns.RequestSourceData()", rcall + 1, true), "and nowhere else")
    local page = Read("Search/ItemSources.lua")
    local s = assert(page:find("\nlocal function Sections(item)\n", 1, true))
    local e = assert(page:find("\nend\n", s, true))
    local call = assert(page:find("ns.RequestSourceData()", 1, true))
    H.assertTrue(call > s and call < e, "inside the page's section build")
    H.assertNil(page:find("ns.RequestSourceData()", call + 1, true), "and nowhere else")
end

local pass, fail, failures = H.runSuite("SourceData", tests)
return { pass = pass, fail = fail, failures = failures }

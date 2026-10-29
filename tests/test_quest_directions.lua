-- Apps/GPS/QuestDirections.lua: "Directions" on the game's quest menus
-- and the log's quests as search rows, from where the game places a
-- quest (its mark on its map, else the next waypoint); and GPS.LeadsTo
-- (Apps/GPS/GPS.lua), which asks an extension row's provider where it
-- leads (the Questie rows' GPS button, 2026-10-29).
local H = require("Harness")

local function Load(opts)
    opts = opts or {}
    local menus, provider, navigated = {}, nil, {}
    local log = opts.log or {
        { questID = 101, title = "Wanted: Hogger", level = 10 },
        { questID = 102, title = "Far Away", level = 12 },
    }
    local onMap = opts.onMap or { [1429] = { { questID = 101, x = 0.25, y = 0.75 } } }
    local questMap = opts.questMap or { [101] = 1429, [102] = 1436 }
    local QL = {
        GetNumQuestLogEntries = function() return #log end,
        GetInfo = function(i) return log[i] end,
        IsOnQuest = function(id) for _, q in ipairs(log) do if q.questID == id then return true end end return false end,
        IsComplete = function() return false end,
        GetTitleForQuestID = function(id) for _, q in ipairs(log) do if q.questID == id then return q.title end end end,
        GetQuestsOnMap = function(m) return onMap[m] end,
        GetNextWaypoint = opts.noWaypoints and nil or function(id) if id == 102 then return 1436, 0.5, 0.5 end end,
    }
    local env = setmetatable({
        C_QuestLog = QL,
        GetQuestUiMapID = function(id) return questMap[id] end,
        GetMouseFoci = function() return opts.foci or {} end,
        C_AddOns = { IsAddOnLoadable = function(name) return name == "EasyFind_Questie" and opts.questie or false end },
        Menu = { ModifyMenu = function(tag, fn) menus[tag] = fn end },
        CreateFrame = function() return { SetScript = function() end, RegisterEvent = function() end } end,
        IsAltKeyDown = function() return false end,
        QUESTS_LABEL = "Quests", QUEST_LOG = "Quest Log",
        EasyFind = { API = {
            CallAction = function(_, _, dest) navigated[#navigated + 1] = dest return true end,
            RegisterSearchProvider = function(def) provider = def end,
            RefreshSearchProvider = function() end,
        } },
    }, { __index = _G })
    local ns = {
        L = setmetatable({}, { __index = function(_, k) return k end }),
        GPS = { CanNavigate = function(_, dest) return dest.mapID ~= nil end },
        Utils = { RegisterEventIfValid = function() end },
    }
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/QuestDirections.lua", "rb"))
    local src = f:read("*a")
    f:close()
    env.EasyFind._ns = ns
    assert(load(src, "=QuestDirections.lua", "t", env))("EasyFind_GPS", {})
    return ns, menus, provider, navigated
end

-- A menu's root, recording what is added.
local function Root()
    local root = { items = {} }
    function root:CreateDivider() self.items[#self.items + 1] = "divider" end
    function root:CreateButton(text, fn) self.items[#self.items + 1] = { text = text, fn = fn } end
    return root
end

local tests = {}

function tests.spot_isTheQuestsMarkOnItsMap_elseTheNextWaypoint()
    local ns = Load()
    local m, x, y = ns.GPS.QuestSpot(101)
    H.assertEq(m, 1429)
    H.assertEq(x, 0.25)
    H.assertEq(y, 0.75)
    m = ns.GPS.QuestSpot(102)
    H.assertEq(m, 1436, "no mark on its map: the waypoint")
    H.assertNil(ns.GPS.QuestSpot(999))
end

function tests.trackerMenu_addsDirectionsForTheQuestUnderTheCursor()
    local block = { id = 101 }
    local header = { GetParent = function() return block end }
    local _, menus, _, navigated = Load({ foci = { header } })
    local root = Root()
    menus.MENU_QUEST_OBJECTIVE_TRACKER(nil, root)
    H.assertEq(#root.items, 2)
    H.assertEq(root.items[2].text, "GPS_MENU_DIRECTIONS")
    root.items[2].fn()
    H.assertEq(navigated[1].mapID, 1429)
    H.assertEq(navigated[1].name, "Wanted: Hogger")
end

function tests.logTitleMenu_readsTheTitlesQuest()
    local _, menus = Load()
    local root = Root()
    menus.MENU_QUEST_MAP_LOG_TITLE({ questID = 102 }, root)
    H.assertEq(#root.items, 2)
end

function tests.aQuestWithNoPlace_getsNoEntry()
    local _, menus = Load({ noWaypoints = true, questMap = {} })
    local root = Root()
    menus.MENU_QUEST_MAP_LOG_TITLE({ questID = 101 }, root)
    H.assertEq(#root.items, 0)
end

function tests.logRows_leadWhereTheGamePlacesThem()
    local _, _, provider = Load()
    local rows = provider.rows()
    H.assertEq(#rows, 2)
    H.assertEq(rows[1].name, "Wanted: Hogger")
    H.assertEq(provider.place(rows[1]).mapID, 1429)
end

function tests.besideTheQuestieExtension_noLogRows()
    local _, menus, provider = Load({ questie = true })
    H.assertNil(provider, "its rows already list the log")
    H.assertTrue(menus.MENU_QUEST_OBJECTIVE_TRACKER ~= nil, "the menus stay")
end

-- GPS.LeadsTo: an extension's row with no spot of its own leads where
-- its provider's place says.
function tests.destination_asksTheRowsProvider()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function GPS.LeadsTo", 1, true))
    local _, e = src:find("\nend\r?\n", s)
    local now = 100
    local asked = 0
    local provider = { place = function(row) asked = asked + 1 return { name = "Giver", mapID = 1429, x = 0.1, y = 0.2, step = row.name } end }
    local GPS = {}
    local env = setmetatable({
        GPS = GPS, GetTime = function() return now end,
        ns = { Extensions = {
            ProviderOf = function(data) return data.category == "Quests" and provider or nil end,
            Run = function(fn, ...) return true, fn(...) end,
        } },
    }, { __index = _G })
    assert(load("local GPS, ns = GPS, ns\n" .. src:sub(s, e), "=GPS.lua Destination", "t", env))()
    local row = { name = "Quest", category = "Quests" }
    local dest = GPS.LeadsTo(row)
    H.assertEq(dest.mapID, 1429)
    H.assertEq(dest.step, "Quest")
    H.assertNil(dest.icon, "no icon on either: the map pin falls back to none")
    GPS.LeadsTo(row)
    H.assertEq(asked, 1, "asked again only after a few seconds")
    now = 106
    GPS.LeadsTo(row)
    H.assertEq(asked, 2)
    local placed = { name = "Spot", category = "Quests", mapID = 1, x = 0.5, y = 0.5 }
    H.assertEq(GPS.LeadsTo(placed), placed, "a row with its own spot stays")
    -- The map pin's face: the place's own icon (a quest's ! or ?), else the row's.
    provider.place = function() return { name = "Giver", mapID = 1429, x = 0.1, y = 0.2, icon = 132049 } end
    H.assertEq(GPS.LeadsTo({ name = "Q2", category = "Quests", icon = 365195 }).icon, 132049)
    provider.place = function() return { name = "Giver", mapID = 1429, x = 0.1, y = 0.2 } end
    H.assertEq(GPS.LeadsTo({ name = "Q3", category = "Quests", icon = 365195 }).icon, 365195)
end

local pass, fail, failures = H.runSuite("QuestDirections", tests)
return { pass = pass, fail = fail, failures = failures }

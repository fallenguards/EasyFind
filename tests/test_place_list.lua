-- The map search's list (MapSearch/PlaceList.lua), which the map tab and
-- every GPS search draw through: a query draws its first 25 places and a
-- "Show more" row; each click on it adds 25; a new query starts over.
-- The GPS once drew a frame for every match (2092 for "a", 2026-10-25).
local H = require("Harness")

local function Frame()
    local f = { shown = true, mouse = true, text = "" }
    return setmetatable(f, { __index = function(_, k)
        if not k:match("^%u") then return nil end   -- a field, not a method
        if k == "Show" then return function(self) self.shown = true end end
        if k == "Hide" then return function(self) self.shown = false end end
        if k == "IsShown" then return function(self) return self.shown end end
        if k == "SetShown" then return function(self, v) self.shown = v and true or false end end
        if k == "EnableMouse" then return function(self, v) self.mouse = v end end
        if k == "SetText" then return function(self, v) self.text = v end end
        if k == "GetText" then return function(self) return self.text end end
        if k == "SetHeight" then return function(self, v) self.height = v end end
        if k == "SetScript" then return function(self, name, fn) self[name] = fn end end
        if k == "CreateTexture" or k == "CreateFontString" or k == "GetHighlightTexture" then
            return function() return Frame() end
        end
        if k == "GetFont" then return function() return "font", 12, "" end end
        if k == "GetStringHeight" or k == "GetFrameLevel" then return function() return 12 end end
        if k == "IsMouseOver" then return function() return false end end
        return function() end
    end })
end

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/PlaceList.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local ns = {
        Utils = {
            tinsert = table.insert, tsort = table.sort, mmin = math.min, mmax = math.max,
            RGB = function() return 1, 1, 1 end, SetIconTexture = function() end,
            CreateClearButton = function() return Frame() end,
        },
        L = setmetatable({ MAP_SHOW_MORE_FMT = "Show %d more" }, { __index = function(_, k) return k end }),
        MapUtils = {
            GetTopAncestor = function(mapID) if mapID then return "Continent" .. mapID, mapID end end,
            GetZoneUnderAncestor = function() return nil end,
        },
        GOLD_COLOR = { 1, 0.82, 0 }, TEXT_DIM = { 0.5, 0.5, 0.5 },
        SetQuestLogToggle = function() end,
    }
    local env = setmetatable({
        CreateFrame = function() return Frame() end,
        GameTooltip = Frame(), C_Map = {}, Enum = { UIMapType = {} },
        EasyFind = { db = {} },
        wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
        Game15Font_Shadow = Frame(), GameFontNormal = Frame(), GameFontNormalSmall = Frame(),
    }, { __index = _G })
    env._G = env
    assert(load(src, "=PlaceList.lua", "t", env))("EasyFind", ns)
    return ns.PlaceList
end

local function Places(n, mapID)
    local out = {}
    for i = 1, n do out[i] = { name = "Place " .. i, mapID = mapID } end
    return out
end

local function Shown(list)
    local places, more, last = 0, nil, nil
    for i = 1, list.rowAt - 1 do
        local row = list.rows[i]
        if row.data and row.data.isShowMore then more = row.text.text
        elseif row.data then places = places + 1 end
        last = row
    end
    return places, more, last
end

local function NewList(PlaceList)
    local list
    list = PlaceList.New(Frame(), { click = function() end, refresh = function() list:Redraw() end })
    return list
end

local tests = {}

function tests.aQueryDrawsItsFirstPageAndShowMoreAddsTheNext()
    local PlaceList = Load()
    local list = NewList(PlaceList)
    list:Render({ query = "a", globalEntries = PlaceList.FlatEntries(Places(60)) })
    local places, more, last = Shown(list)
    H.assertEq(places, 25, "first page")
    H.assertEq(more, "Show 25 more")
    H.assertEq(#list.rows, 26, "rows made: the page and its Show more row")
    last.OnClick(last, "LeftButton")
    places, more = Shown(list)
    H.assertEq(places, 50, "second page")
    H.assertEq(more, "Show 10 more", "says how many are left")
    local _, _, again = Shown(list)
    again.OnClick(again, "LeftButton")
    places, more = Shown(list)
    H.assertEq(places, 60, "all of them")
    H.assertNil(more, "nothing left to show")
end

function tests.aNewQueryStartsAtTheFirstPage()
    local PlaceList = Load()
    local list = NewList(PlaceList)
    list:Render({ query = "a", globalEntries = PlaceList.FlatEntries(Places(60)) })
    local _, _, last = Shown(list)
    last.OnClick(last, "LeftButton")
    list:Render({ query = "a", globalEntries = PlaceList.FlatEntries(Places(60)) })
    H.assertEq((Shown(list)), 50, "the same query keeps its pages")
    list:Render({ query = "ab", globalEntries = PlaceList.FlatEntries(Places(60)) })
    H.assertEq((Shown(list)), 25, "a new one starts over")
end

function tests.groupHeadersPastThePageAreNotDrawn()
    local PlaceList = Load()
    local list = NewList(PlaceList)
    local results = Places(30, 1)
    for _, p in ipairs(Places(10, 2)) do results[#results + 1] = p end
    list:Render({ query = "a", globalEntries = (PlaceList.WorldEntries(results)) })
    local headers = 0
    for i = 1, list.headerAt - 1 do if list.headers[i].shown then headers = headers + 1 end end
    H.assertEq(headers, 1, "the second continent's header waits for its places")
    H.assertEq((Shown(list)), 25)
end

function tests.nothingFoundSaysSoOnARowThatTakesNoClick()
    local PlaceList = Load()
    local list = NewList(PlaceList)
    list:Render({ query = "zz", globalEntries = {}, emptyText = "No matches." })
    local row = list.rows[1]
    H.assertEq(row.text.text, "No matches.")
    H.assertNil(row.data)
    H.assertFalse(row.mouse, "the empty line takes no click")
    H.assertEq(list.lines, 1, "it counts as the list's one line")
end

-- A list's owner dresses the group headers for where the list sits (the
-- tracker's header art snapped in, the theme in the window); a new skin
-- repaints the pooled headers.
-- Two zones of one name fold under one header and leave the list of
-- places outside headers empty: the map tab's "No matches." line read that
-- list and showed under the Dalaran header (MoP, 2026-10-26). It reads the
-- entries drawn.
function tests.sameNamedZonesFoldUnderOneHeader_soTheEmptyLineReadsTheEntries()
    local PlaceList = Load()
    local entries, outside = PlaceList.WorldEntries({
        { name = "Dalaran", isZone = true, zoneMapID = 125, mapID = 125 },
        { name = "Dalaran", isZone = true, zoneMapID = 126, mapID = 126 },
    })
    H.assertEq(#entries, 1)
    H.assertEq(entries[1].type, "version")
    H.assertEq(#outside, 0, "nothing left outside the header")
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/MapTab.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local cond = src:match("if activePage == nil and %(not pinned or #pinned == 0%)(.-)then")
    H.assertTrue(cond ~= nil, "the empty line's condition")
    H.assertTrue(cond:find("#globalEntries == 0", 1, true) ~= nil and not cond:find("Filtered", 1, true),
        "it reads the entries drawn, not the places outside headers")
end

function tests.aHostSkinDressesTheHeaders()
    local PlaceList = Load()
    local painted, toggled = 0, 0
    local function NewSkin()
        return {
            paint = function() painted = painted + 1 end,
            toggle = function() toggled = toggled + 1 end,
            color = function() return 0.1, 0.2, 0.3 end,
        }
    end
    local skin = NewSkin()
    local list
    list = PlaceList.New(Frame(), { click = function() end, refresh = function() list:Redraw() end,
        headerSkin = function() return skin end })
    list:Render({ query = "a", globalEntries = (PlaceList.WorldEntries(Places(3, 1))) })
    H.assertEq(painted, 1, "the one header painted")
    H.assertEq(toggled, 1, "its toggle drawn by the skin")
    list:Redraw()
    H.assertEq(painted, 1, "the same skin: no repaint")
    skin = NewSkin()
    list:Redraw()
    H.assertEq(painted, 2, "a new skin repaints")
end

function tests.theMapAndTheGPSDrawThroughIt()
    for _, path in ipairs({ "/MapSearch/MapTab.lua", "/Apps/GPS/GPS.lua" }) do
        local f = assert(io.open(H.ADDON_ROOT .. path, "rb"))
        local src = f:read("*a")
        f:close()
        H.assertTrue(src:find("ns.PlaceList.New(", 1, true) ~= nil, path .. " draws its places through PlaceList")
    end
end

local pass, fail, failures = H.runSuite("PlaceList", tests)
return { pass = pass, fail = fail, failures = failures }

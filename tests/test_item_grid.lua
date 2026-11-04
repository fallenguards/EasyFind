-- The item grid (Search/Results/ItemGrid.lua): a character's containers
-- in slot order, words filtering it, a place word keeping to its place
-- with a chip that says so, and the bar's arrows walking the cells.
local H = require("Harness")

-- A widget that keeps what was set on it and makes children of its own.
local made = {}
local function Widget()
    local w = { _shown = true }
    made[#made + 1] = w
    return setmetatable(w, { __index = function(_, k)
        if k == "SetText" then return function(self, s) self._text = s end end
        if k == "GetText" then return function(self) return self._text end end
        if k == "Show" then return function(self) self._shown = true end end
        if k == "Hide" then return function(self) self._shown = false end end
        if k == "IsShown" or k == "IsVisible" then return function(self) return self._shown end end
        if k == "LockHighlight" then return function(self) self._locked = true end end
        if k == "UnlockHighlight" then return function(self) self._locked = false end end
        if k == "GetWidth" then return function() return 400 end end
        if k == "GetStringWidth" then return function() return 40 end end
        if k == "GetVerticalScroll" then return function() return 0 end end
        if k == "IsMouseOver" or k == "HasFocus" then return function() return false end end
        if k == "CreateFontString" or k == "CreateTexture" then return function() return Widget() end end
        if k == "GetFontString" then return function(self) self._fs = self._fs or Widget() return self._fs end end
        -- Methods are capitalized; a plain field is unset.
        if k:find("^%u") then return function() end end
        return nil
    end })
end

local function Cell(name, place, id)
    return { itemID = id, name = name, count = 1, place = place, folded = name:lower(), icon = 1 }
end

local function Grid(sections)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.CreateFrame = function() return Widget() end
    env.GameTooltip = Widget()
    env.EasyFind.db.uiResultsRows = 4
    local resultsFrame = Widget()
    resultsFrame.scrollChild = Widget()
    resultsFrame.scrollFrame = Widget()
    local navFrame = Widget()
    ns.Search.GetResultsFrame = function() return resultsFrame end
    ns.Search.GetResultButtons = function() return {} end
    ns.Search.ClearResultShortcutBindings = function() end
    ns.Search.GetNavFrame = function() return navFrame end
    ns.Search.GetSearchFrame = function() return nil end
    ns.Results.GetActiveTheme = function() return { resultsPadTop = 4, resultsPadBot = 4 } end
    ns.Results.GetRowUnitHeight = function() return 36 end
    ns.ResultRender.ApplyResultsFrameLayout = function() end
    ns.WarbandBankLabel = function() return "Warband Bank" end
    local Data = {}
    local folded = { bank = "bank", bags = "bags", bag = "bag", voucher = "voucher", potion = "potion" }
    function Data.Fold(s) return (s or ""):lower() end
    function Data.Words(q, out)
        for i = #out, 1, -1 do out[i] = nil end
        for w in (q or ""):lower():gmatch("%S+") do out[#out + 1] = folded[w] or w end
        return out
    end
    function Data.MatchesAll(text, words, skip)
        for i = 1, #words do
            if not (skip and skip[i]) and not text:find(words[i], 1, true) then return false end
        end
        return true
    end
    function Data.PlaceLabel(place) return place == "bank" and "Bank" or "Bags" end
    function Data.Sections() return sections end
    ns.CharacterData = Data
    H.loadModule("Search/Results/Grids.lua", env, ns)
    made = {}
    H.loadModule("Search/Results/ItemGrid.lua", env, ns)
    return ns
end

local function Sections()
    return {
        { header = "Backpack", place = "bags", cells = { Cell("Bank Voucher", "bags", 1), Cell("Mana Potion", "bags", 2) } },
        { header = "Bank", place = "bank", cells = { Cell("Silk Cloth", "bank", 3) } },
    }
end

local function Host()
    for _, w in ipairs(made) do
        if w.countText then return w end
    end
end

local function Focused()
    for _, w in ipairs(made) do
        if w._locked and w.cell then return w.cell.name end
    end
end

local tests = {}

function tests.noWords_everyItem_counted()
    local ns = Grid(Sections())
    ns.Results:ShowItemGrid({ charKey = "Jaina-Realm", gridKind = "items" }, "")
    local host = Host()
    H.assertEq(host.countText._text, "3/3")
    H.assertFalse(host.chip._shown, "no place chosen")
end

function tests.aPlaceWordAlone_keepsToThatPlace_withAChip()
    local ns = Grid(Sections())
    ns.Results:ShowItemGrid({ charKey = "Jaina-Realm", gridKind = "items" }, "bank")
    local host = Host()
    H.assertEq(host.countText._text, "1/3", "the bank's one item")
    H.assertTrue(host.chip._shown)
    H.assertTrue(host.chip._text:find("^Bank") ~= nil)
end

function tests.aPlaceWordInAnItemsName_findsTheItem()
    local ns = Grid(Sections())
    ns.Results:ShowItemGrid({ charKey = "Jaina-Realm", gridKind = "items" }, "bank voucher")
    local host = Host()
    H.assertEq(host.countText._text, "1/3")
    H.assertFalse(host.chip._shown, "the words name an item")
end

function tests.aPlaceWordBesideOthers_narrowsWhenNoItemIsNamedSo()
    local ns = Grid(Sections())
    ns.Results:ShowItemGrid({ charKey = "Jaina-Realm", gridKind = "items" }, "bags potion")
    local host = Host()
    H.assertEq(host.countText._text, "1/3")
    H.assertTrue(host.chip._shown)
end

function tests.arrows_walkTheItems_upFromTheTopLeaves()
    local ns = Grid(Sections())
    local R = ns.Results
    R:ShowItemGrid({ charKey = "Jaina-Realm", gridKind = "items" }, "")
    H.assertTrue(R:IsGridShown())
    H.assertTrue(R:MoveGridFocus(0, 1), "Down from the box enters the grid")
    H.assertEq(Focused(), "Bank Voucher")
    R:MoveGridFocus(1, 0)
    H.assertEq(Focused(), "Mana Potion", "right: the next item")
    R:MoveGridFocus(0, 1)
    H.assertEq(Focused(), "Silk Cloth", "down: the next line's nearest item, past its header")
    R:MoveGridFocus(0, -1)
    H.assertTrue(R:IsGridNavActive())
    R:MoveGridFocus(0, -1)
    H.assertFalse(R:IsGridNavActive(), "up past the top goes back to the box")
end

function tests.hiding_leavesNoGridShown()
    local ns = Grid(Sections())
    ns.Results:ShowItemGrid({ charKey = "Jaina-Realm", gridKind = "items" }, "")
    ns.Results:HideGrids(true)
    H.assertFalse(ns.Results:IsGridShown())
end

local pass, fail, failures = H.runSuite("ItemGrid", tests)
return { pass = pass, fail = fail, failures = failures }

-- Tests for the apps menu's grid: tiles run down a column for the rows
-- setting (six to start) before the next column opens, the column count
-- following the tile count; the setting is rows per column, offered in
-- the settings and translated everywhere.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local tests = {}

-- The grid's own arithmetic, cut from the file.
local function Cell()
    local src = Read("Search/AppsMenu.lua")
    local s = assert(src:find("local function Cell(i, rows)", 1, true))
    local e = assert(src:find("\nend\n", s, true))
    return assert(load(src:sub(s, e + 3) .. "\nreturn Cell", "=AppsMenu Cell", "t", { math = math }))()
end

function tests.tilesRunDownAColumnThenTheNext()
    local cell = Cell()
    local c, r = cell(1, 6)
    H.assertEq(c, 1) H.assertEq(r, 0)
    c, r = cell(6, 6)
    H.assertEq(c, 1, "the sixth tile closes the first column") H.assertEq(r, 5)
    c, r = cell(7, 6)
    H.assertEq(c, 2, "the seventh opens the second") H.assertEq(r, 0)
    c, r = cell(13, 6)
    H.assertEq(c, 3) H.assertEq(r, 0)
    c, r = cell(5, 4)
    H.assertEq(c, 2, "four rows a column: the fifth opens the second") H.assertEq(r, 0)
end

function tests.theColumnCountFollowsTheTiles()
    local src = Read("Search/AppsMenu.lua")
    H.assertTrue(src:find("local rows = math.max(1, s.rows)\n    local cols = math.max(1, math.ceil(n / rows))", 1, true) ~= nil,
        "as many columns as the rows setting fills")
    H.assertTrue(src:find("local lines = math.max(1, math.min(rows, #items))", 1, true) ~= nil,
        "the menu as tall as its fullest column")
    H.assertTrue(src:find("local c, r = Cell(i, rows)", 1, true) ~= nil, "each tile placed by its column and row")
    H.assertNil(src:find("Settings().columns", 1, true), "no column count read anywhere")
end

function tests.sixRowsToStart_andTheSettingOffersOthers()
    local src = Read("Search/AppsMenu.lua")
    H.assertTrue(src:find("AppsMenu.ROWS_DEFAULT = 6", 1, true) ~= nil)
    H.assertTrue(src:find("AppsMenu.ROWS_CHOICES = { 4, 6, 8, 10, 12 }", 1, true) ~= nil)
    H.assertTrue(src:find("s.rows = s.rows or AppsMenu.ROWS_DEFAULT", 1, true) ~= nil, "the default when unset")
    H.assertTrue(src:find("s.columns = nil", 1, true) ~= nil, "a column count once saved is let go")
    for _, path in ipairs({ "Core/SettingsRows.lua", "Apps/Options/OptionsPanel.lua" }) do
        local page = Read(path)
        H.assertTrue(page:find('L["OPT_EXT_ROWS"]', 1, true) ~= nil, path .. " offers rows per column")
        H.assertTrue(page:find("AppsMenu.ROWS_CHOICES", 1, true) ~= nil, path .. " from the menu's own choices")
        H.assertNil(page:find('OPT_EXT_COLUMNS', 1, true), path .. " offers no column count")
    end
end

-- The menu closed on the click that changed one of its settings
-- (2026-11-02): a click on the options window or a quick settings menu
-- leaves it open, so the change is seen, as the results window stays.
function tests.theMenuStaysWhileItsSettingsAreChanged()
    local src = Read("Search/AppsMenu.lua")
    local s = assert(src:find('if event ~= "GLOBAL_MOUSE_DOWN" then return end', 1, true))
    local e = assert(src:find("self:Hide()", s, true))
    local closer = src:sub(s, e)
    H.assertTrue(closer:find("surface:IsOptionsSurfaceMouseOver()", 1, true) ~= nil, "the options surface keeps it")
    H.assertTrue(closer:find("Utils.IsCursorMenuMouseOver()", 1, true) ~= nil, "a cursor menu keeps it")
end

function tests.rowsPerColumnIsTranslatedEverywhere()
    for _, loc in ipairs({ "enUS", "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }) do
        local src = Read("Locales/" .. loc .. ".lua")
        H.assertTrue(src:find('L["OPT_EXT_ROWS"]', 1, true) ~= nil, loc .. " has the string")
        H.assertTrue(src:find('L["OPT_EXT_ICON_SIZE"]', 1, true) ~= nil, loc .. " names the icon size")
        H.assertNil(src:find('L["OPT_EXT_COLUMNS"]', 1, true), loc .. " keeps no dead one")
    end
end

-- The icons' size is a setting of its own beside the labels' (2026-11-02):
-- every tile's icon, the tiles' width and height and the drag ghost
-- follow it.
function tests.theIconSizeIsASettingBesideTheLabelSize()
    local src = Read("Search/AppsMenu.lua")
    H.assertTrue(src:find("AppsMenu.ICON_SIZES = {", 1, true) ~= nil)
    H.assertTrue(src:find("s.iconSize = s.iconSize or 1", 1, true) ~= nil, "the default when unset")
    H.assertTrue(src:find("local iconPx, tilePx = IconPx(Settings())\n    icon:ClearAllPoints()", 1, true) ~= nil,
        "each tile's icon at the setting")
    H.assertNil(src:find("icon:SetSize(ICON, ICON)\n        icon:SetPoint", 1, true), "no tile at the bare size")
    H.assertNil(src:find("icon:SetSize(TILE_ICON, TILE_ICON)", 1, true))
    H.assertTrue(src:find("h = math.max(ROW_H, iconPx + 8, math.ceil(fontH) + 10)", 1, true) ~= nil,
        "a row as tall as a big icon")
    for _, path in ipairs({ "Core/SettingsRows.lua", "Apps/Options/OptionsPanel.lua" }) do
        local page = Read(path)
        H.assertTrue(page:find('L["OPT_EXT_ICON_SIZE"]', 1, true) ~= nil, path .. " offers it")
        H.assertTrue(page:find("AppsMenu.ICON_SIZES", 1, true) ~= nil, path .. " from the menu's own choices")
    end
end

-- The tile list cut from the file, over given settings and extensions.
local function Items(settings, apps)
    local src = Read("Search/AppsMenu.lua")
    local s = assert(src:find("local function GroupByID(s, id)", 1, true))
    local e = assert(src:find("AppsMenu.MenuItems = MenuItems", s, true))
    local env = { ipairs = ipairs, pairs = pairs, table = table, math = math, string = string, next = next,
        Settings = function() return settings end, AppsMenu = {},
        ns = { BuildApplicationEntries = function() return apps end, ApplicationEntryID = function(app) return app.id end } }
    return assert(load(src:sub(s, e - 1) .. "\nreturn MenuItems", "=AppsMenu MenuItems", "t", env))()
end

local function Ids(items)
    local out = {}
    for _, it in ipairs(items) do out[#out + 1] = it.id end
    return table.concat(out, ",")
end

-- A hidden extension (the tile's menu, the settings page; 2026-11-02)
-- leaves the grid, alone or inside a group, and a group with nothing
-- left to show goes with it; its search row and key stay.
function tests.hiddenExtensionsLeaveTheGrid_groupsToo()
    local apps = { { id = "calc", name = "Calculator" }, { id = "notes", name = "Notes" }, { id = "gps", name = "GPS" } }
    local settings = { groups = { { id = "g1", name = "Tools", apps = { "calc", "notes" } } }, hidden = { notes = true } }
    local MenuItems = Items(settings, apps)
    H.assertEq(Ids(MenuItems()), "gps,group:g1")
    H.assertEq(Ids(MenuItems("g1")), "calc", "the hidden one is gone from its group")
    settings.hidden.calc = true
    H.assertEq(Ids(MenuItems()), "gps", "a group with nothing left to show goes too")
    settings.order = { "group:g1", "gps", "notes" }
    H.assertEq(Ids(MenuItems()), "gps", "the saved order lists them, the grid does not")
    settings.hidden = nil
    H.assertEq(Ids(MenuItems()), "group:g1,gps", "all back, the grouped one inside its group")
    H.assertEq(Ids(MenuItems("g1")), "calc,notes")
end

function tests.hideIsOfferedOnTheTile_andTheSettingsPageShowsThemAgain()
    local menu = Read("Search/AppsMenu.lua")
    H.assertTrue(menu:find("function AppsMenu:SetHidden(id, on)", 1, true) ~= nil)
    H.assertTrue(menu:find("ns.ExtensionButtons:ShowAppMenu(row, item.app, true)", 1, true) ~= nil,
        "the tile's menu asks for the Hide entry")
    H.assertTrue(menu:find("local app = not AppsMenu:IsHidden(id) and ns.FindApplicationEntry(id)", 1, true) ~= nil,
        "a group's stack leaves a hidden one out")
    local buttons = Read("Search/ExtensionButtons.lua")
    H.assertTrue(buttons:find("if inMenu and appID and ns.AppsMenu and ns.AppsMenu.SetHidden then", 1, true) ~= nil,
        "only a tile offers Hide, never a button on the screen")
    H.assertTrue(buttons:find('label = L["EXTMENU_HIDE"], tooltip = L["EXTMENU_HIDE_TT"]', 1, true) ~= nil)
    local panel = Read("Apps/Options/OptionsPanel.lua")
    H.assertTrue(panel:find('shownTitle:SetText(L["OPT_EXT_SHOWN"])', 1, true) ~= nil, "the page lists them")
    H.assertTrue(panel:find("AppsMenu:SetHidden(id, not self:GetChecked())", 1, true) ~= nil, "a switch off hides")
    H.assertTrue(panel:find("s.rows, s.labels, s.labelSize, s.iconSize, s.order, s.hidden = nil, nil, nil, nil, nil, nil", 1, true) ~= nil,
        "reset shows them all again")
    H.assertTrue(Read("Core/SettingsRows.lua"):find('Check(sformat(L["OPT_EXT_SHOW_FMT"], app.name or id), L["OPT_EXT_SHOWN_HINT"]', 1, true) ~= nil,
        "a row per extension in the settings search")
    for _, loc in ipairs({ "enUS", "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }) do
        local src = Read("Locales/" .. loc .. ".lua")
        for _, key in ipairs({ "OPT_EXT_SHOWN", "OPT_EXT_SHOWN_HINT", "OPT_EXT_SHOW_FMT", "EXTMENU_HIDE", "EXTMENU_HIDE_TT" }) do
            H.assertTrue(src:find('L["' .. key .. '"]', 1, true) ~= nil, loc .. " has " .. key)
        end
    end
end

local pass, fail, failures = H.runSuite("AppsMenuRows", tests)
return { pass = pass, fail = fail, failures = failures }

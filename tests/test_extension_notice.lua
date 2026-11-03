-- The one-time chat notice after an upgrade (Core/Extensions.lua
-- NoteUpgrade, TellExtensions): from 4.0.0 or 4.0.1, where Chat and GPS
-- went (each a bracket link to its CurseForge page) and the other
-- extensions; from before 4.0.0, the extensions. Nothing from 4.0.2 on,
-- nothing for a new install, and never twice.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Compare(a, b)
    local pa, pb = {}, {}
    for n in a:gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
    for n in b:gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
    for i = 1, 3 do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    return 0
end

local inCombat = false

local function Load(installed)
    local src = Read("Core/Extensions.lua")
    local s = assert(src:find("local PAGE = ", 1, true), "the notice's start")
    local e = assert(src:find("local noticeWatch", s, true), "its end")
    local said, dialogs, menus = {}, {}, {}
    inCombat = false
    local ns = {
        version = "4.0.2", CHAT_LOGO = "EF ",
        CompareVersion = Compare,
        BlueChatLink = function(target, label) return "[" .. label .. "](" .. target .. ")" end,
        ShowThemedDialog = function(opts) dialogs[#dialogs + 1] = opts end,
        Utils = { ShowCursorMenu = function(_, rows, opts) menus[#menus + 1] = { rows = rows, opts = opts } end },
    }
    local env = setmetatable({
        ns = ns, L = {
            EXT_SPLIT_FMT = "split %s.", EXT_SPLIT_GET_FMT = "get %s.", EXT_AND_FMT = "%s and %s",
            EXT_OTHERS_FMT = "others %s.", EXT_NEW_FMT = "new %s: %s.", EXT_PAGE_COPY = "copy it",
            FILTER_EXTENSIONS = "Extensions", EXT_PAGE_TT = "page", EXT_INSTALLED = "have",
        },
        EasyFind = { db = {} },
        C_AddOns = { DoesAddOnExist = function(name) return installed and installed[name] or false end },
        InCombatLockdown = function() return inCombat end,
        print = function(line) said[#said + 1] = line end,
    }, { __index = _G })
    assert(load(src:sub(s, e - 1), "=Extensions.lua notice", "t", env))()
    for _, x in ipairs(ns.FirstPartyExtensions) do
        if x.addon == "EasyFind_Chat" then x.slug = "easyfind-chat-extension" end
        if x.addon == "EasyFind_GPS" then x.slug = "easyfind-gps-navigation-extension" end
    end
    return ns, env.EasyFind.db, said, dialogs, menus
end

local CHAT = "[EasyFind: Chat Extension](easyfind:page:easyfind-chat-extension)"
local GPS = "[EasyFind: GPS Navigation Extension](easyfind:page:easyfind-gps-navigation-extension)"
local PAGES = "[Extensions](easyfind:extensions)"

local tests = {}

function tests.fromTheBundledReleases_whereChatAndGPSWent()
    local ns, db, said = Load()
    ns.NoteUpgrade("4.0.1")
    H.assertEq(db.extensionsNoticeFrom, "4.0.1")
    ns.TellExtensions()
    H.assertEq(said[1], "EF split 4.0.2. get " .. CHAT .. " and " .. GPS .. ". others " .. PAGES .. ".")
    H.assertNil(db.extensionsNoticeFrom, "told once")
    ns.TellExtensions()
    H.assertEq(#said, 1)
end

function tests.oneAlreadyInstalled_onlyTheOtherToGet()
    local ns, _, said = Load({ EasyFind_GPS = true })
    ns.NoteUpgrade("4.0.0")
    ns.TellExtensions()
    H.assertEq(said[1], "EF split 4.0.2. get " .. CHAT .. ". others " .. PAGES .. ".")
end

function tests.bothInstalled_justTheNews()
    local ns, _, said = Load({ EasyFind_GPS = true, EasyFind_Chat = true })
    ns.NoteUpgrade("4.0.1")
    ns.TellExtensions()
    H.assertEq(said[1], "EF split 4.0.2. others " .. PAGES .. ".")
end

function tests.fromBeforeTheBundle_theLinkAlone()
    local ns, _, said = Load()
    ns.NoteUpgrade("3.5.0")
    ns.TellExtensions()
    H.assertEq(said[1], "EF new 4.0.2: " .. PAGES .. ".")
end

-- The [Extensions] link: one menu of every page, installed ones checked,
-- a row's click the page's address.
function tests.theExtensionsLinkListsEveryPage()
    local ns, _, _, dialogs, menus = Load({ EasyFind_GPS = true })
    ns.ShowExtensionPages()
    local rows = menus[1].rows
    H.assertEq(#rows, 4)
    H.assertEq(rows[2].text, "EasyFind: GPS Navigation Extension")
    H.assertTrue(rows[2].icon ~= nil, "installed: checked")
    H.assertNil(rows[3].icon)
    H.assertEq(menus[1].opts.iconSide, "left")
    rows[3].onClick()
    H.assertEq(dialogs[1].editBoxDefault, "https://www.curseforge.com/wow/addons/easyfind-questie-extension")
end

function tests.fromTheSplitOn_nothing()
    local ns, db, said = Load()
    ns.NoteUpgrade("4.0.2")
    H.assertNil(db.extensionsNoticeFrom)
    ns.TellExtensions()
    H.assertEq(#said, 0)
end

function tests.inAFight_keptForTheNextLogin()
    local ns, db, said = Load()
    ns.NoteUpgrade("4.0.1")
    inCombat = true
    ns.TellExtensions()
    H.assertEq(#said, 0)
    H.assertEq(db.extensionsNoticeFrom, "4.0.1")
    inCombat = false
    ns.TellExtensions()
    H.assertEq(#said, 1)
end

function tests.aPageLinkGivesTheAddressToCopy()
    local ns, _, _, dialogs = Load()
    ns.ShowExtensionPage("easyfind-questie-extension")
    H.assertEq(dialogs[1].editBoxDefault, "https://www.curseforge.com/wow/addons/easyfind-questie-extension")
    H.assertTrue(dialogs[1].readOnly and dialogs[1].single)
end

-- Main.lua hands the notice the version left, and page links to it.
function tests.mainWiresIt()
    local main = Read("Core/Main.lua")
    local block = assert(main:find("if lastSeen ~= nil then", 1, true))
    H.assertTrue(main:find("ns.NoteUpgrade(lastSeen)", block, true) ~= nil)
    H.assertTrue(main:find('PAGE_LINK_PREFIX = "easyfind:page:"', 1, true) ~= nil)
    H.assertTrue(main:find("ns.ShowExtensionPage(link:sub(#PAGE_LINK_PREFIX + 1))", 1, true) ~= nil)
    H.assertTrue(main:find('EXTENSIONS_LINK = "easyfind:extensions"', 1, true) ~= nil)
    H.assertTrue(main:find("link == EXTENSIONS_LINK then\n            ns.ShowExtensionPages()", 1, true) ~= nil)
end

-- An extension recommended where it would help (2026-11-02): its words a
-- link in the link blue, a click on them the page's address; nothing for
-- a player who has it or hid recommendations ("Hide extension
-- recommendations", General settings).
function tests.aRecommendationLinksThePage_untilHiddenOrInstalled()
    local ns, db, _, dialogs = Load()
    local link = ns.ExtensionTipLink("EasyFind_GPS", "EasyFind's GPS extension")
    H.assertTrue(link ~= nil and link:find("|Heasyfind:page:easyfind-gps-navigation-extension|hEasyFind's GPS extension|h", 1, true) ~= nil,
        "the words, linked: " .. tostring(link))
    H.assertTrue(link:find("^|cff%x%x%x%x%x%x") ~= nil, "in the link blue, no brackets")
    H.assertTrue(ns.ExtensionTipClick("easyfind:page:easyfind-gps-navigation-extension"))
    H.assertTrue(dialogs[1] and dialogs[1].editBoxDefault:find("easyfind-gps-navigation-extension", 1, true) ~= nil,
        "the page's address to copy")
    H.assertFalse(ns.ExtensionTipClick("item:6948"), "another link is not ours")
    db.hideExtensionTips = true
    H.assertNil(ns.ExtensionTipLink("EasyFind_GPS", "x"), "hidden by the setting")
    local had = Load({ EasyFind_GPS = true })
    H.assertNil(had.ExtensionTipLink("EasyFind_GPS", "x"), "the player has it")
end

-- The map tab's line over its footer checks, and the setting in both the
-- options window and the search bar's settings rows.
function tests.theMapTabRecommendsGPS_andTheSettingHidesIt()
    local map = Read("MapSearch/MapTab.lua")
    H.assertTrue(map:find('ns.ExtensionTipLink("EasyFind_GPS", L["MAP_GPS_TIP_LINK"])', 1, true) ~= nil, "the GPS recommendation")
    H.assertTrue(map:find('local tip = CreateFrame("Frame", nil, p)\n    tip:Hide()', 1, true) ~= nil, "hidden until laid out")
    H.assertTrue(map:find('tip:SetScript("OnHyperlinkClick", function(_, link) ns.ExtensionTipClick(link) end)', 1, true) ~= nil)
    H.assertTrue(map:find("foot = foot + h + 6", 1, true) ~= nil, "the list ends above it")
    local opts, rows = Read("Apps/Options/OptionsPanel.lua"), Read("Core/SettingsRows.lua")
    H.assertTrue(opts:find('CreateCheckbox(sec3, "HideExtTips", L["OPT_HIDE_EXT_TIPS"])', 1, true) ~= nil, "in General")
    H.assertTrue(opts:find("optionsFrame.extTipsCheckbox:SetChecked(EasyFind.db.hideExtensionTips == true)", 1, true) ~= nil, "kept in step")
    H.assertTrue(rows:find('Check(L["OPT_HIDE_EXT_TIPS"], nil,', 1, true) ~= nil, "found from the search bar")
end

local pass, fail, failures = H.runSuite("ExtensionNotice", tests)
return { pass = pass, fail = fail, failures = failures }

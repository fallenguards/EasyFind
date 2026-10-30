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

local pass, fail, failures = H.runSuite("ExtensionNotice", tests)
return { pass = pass, fail = fail, failures = failures }

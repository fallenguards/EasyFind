-- A checkbox line's auction search (2026-10-30): Ctrl+click on its tail
-- at an open house searches it, as Search AH on its menu does; a linked
-- list's extension searches first (its own term), else the house's own
-- bar, retail's or the classic browse box; away from the house Ctrl+click
-- does nothing.
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local tests = {}

function tests.ctrlClick_searchesAtTheHouse_elseNothing()
    local src = Read("Apps/Notes/Lines.lua")
    local s = assert(src:find('tail:SetScript("OnClick", function(self, button)', 1, true))
    local block = src:sub(s, s + 400)
    H.assertTrue(block:find('if button == "LeftButton" and IsControlKeyDown() then\n            if AuctionOpen() then SearchAH(note, self.line) end\n            return', 1, true) ~= nil,
        "Ctrl+click searches at an open house and otherwise does nothing")
    H.assertTrue(block:find("LineMenu(self)", 1, true) ~= nil, "a plain click opens the line's menu")
end

function tests.theHouse_openByEvents_searchedInRetailsOrTheClassicBox()
    local src = Read("Apps/Notes/Lines.lua")
    H.assertTrue(src:find('return notesNS.Context.WindowOpen("auctionhouse")', 1, true) ~= nil,
        "open by the client's events: TSM's window keeps AuctionFrame hidden")
    local s = assert(src:find("local function SearchAH(note, line)", 1, true))
    local body = src:sub(s, select(2, src:find("\nend\n", s, true)))
    H.assertTrue(body:find("notesNS.LinkedSearch(note, line)", 1, true) ~= nil, "the linked extension searches first")
    H.assertTrue(body:find('_G["BrowseName"]:SetText(name)', 1, true) ~= nil, "the classic browse box when the retail bar is absent")
    H.assertTrue(body:find('_G["AuctionFrameBrowse_Search"]()', 1, true) ~= nil)
end

function tests.linkedSearch_handsTheLineToTheExtension()
    local src = Read("Apps/Notes/Notes.lua")
    local s = assert(src:find("function notesNS.LinkedSearch(note, line)", 1, true))
    local body = src:sub(s, s + 600)
    H.assertTrue(body:find("if not (link and link.search) then return false end", 1, true) ~= nil)
    H.assertTrue(body:find("xpcall(link.search, geterrorhandler(), note.id, src.key,", 1, true) ~= nil)
    H.assertTrue(body:find("return ok and took == true", 1, true) ~= nil, "taken only on a true")
    H.assertTrue(Read("API/README.md"):find("handlers.search(noteID, key, line)", 1, true) ~= nil, "documented")
end

-- Without an extension's search the house's own: on the classic house the
-- Browse tab first (on another tab the search ran out of sight), and a
-- name typed as words searches as itself (2026-11-03).
function tests.theHousesOwnSearch_onTheBrowseTab_wordsToo()
    local src = Read("Apps/Notes/Lines.lua")
    local s = assert(src:find("local function SearchAH(note, line)", 1, true))
    local chunk = src:sub(s, select(2, src:find("\nend\n", s, true)))
    local log, shown = {}, { frame = true, browse = false, chat = nil }
    local env = setmetatable({
        notesNS = { LinkedSearch = function() return false end },
        ns = { AuctionSearches = {} },
        S = function() return {} end,
        C_Item = { GetItemNameByID = function(id) return id == 2589 and "Linen Cloth" or nil end,
                   GetItemInfo = function(id) return "Item", "item:" .. id end },
        CK = { SplitCount = function(t) return (t:gsub("%s*x%d+$", "")) end,
               LineWords = function(_, line) return line.id == 7 and "Hearthstone" or nil end },
        InSight = function(f) return f ~= nil and f:IsShown() end,
        ChatFrameUtil = { GetActiveWindow = function() return shown.chat end },
        ChatEdit_InsertLink = function(link) log[#log + 1] = "link:" .. link end,
        AuctionFrame = { IsShown = function() return shown.frame end },
        AuctionFrameBrowse = { IsShown = function() return shown.browse end },
        AuctionFrameTab1 = {},
        AuctionFrameTab_OnClick = function() log[#log + 1] = "tab" shown.browse = true end,
        BrowseName = { SetText = function(_, t) log[#log + 1] = "name:" .. t end },
        AuctionFrameBrowse_Search = function() log[#log + 1] = "search" end,
    }, { __index = _G })
    env._G = env
    local SearchAH = assert(load(chunk .. "\nreturn SearchAH", "=SearchAH", "t", env))()
    SearchAH({}, { id = 1, item = 2589 })
    H.assertEq(table.concat(log, " "), "tab name:Linen Cloth search", "the Browse tab, then the name, then the search")
    log = {}
    SearchAH({}, { id = 2, text = "copper ore x10" })
    H.assertEq(table.concat(log, " "), "name:copper ore search", "typed words search as themselves; already on Browse")
    log = {}
    SearchAH({}, { id = 3, link = "quest", text = "Fly to Ironforge" })
    H.assertEq(#log, 0, "a line the game ticks is no item")
    -- Another addon's auction window keeps the house's hidden (TSM): the
    -- link goes where a linked item goes; never into an open chat box.
    shown.frame = false
    SearchAH({}, { id = 4, item = 2589 })
    H.assertEq(table.concat(log, " "), "link:item:2589", "handed on as a linked item")
    log, shown.chat = {}, {}
    SearchAH({}, { id = 5, item = 2589 })
    H.assertEq(#log, 0, "a chat box open: not pasted into it")
    SearchAH({}, { id = 6, text = "copper ore" })
    H.assertEq(#log, 0, "words have no link to hand on")
    -- An item the client cannot name yet: the words typed for it.
    shown.frame, shown.chat = true, nil
    SearchAH({}, { id = 7, item = 6948 })
    H.assertEq(table.concat(log, " "), "name:Hearthstone search", "searched by the name as typed")
    local src2 = Read("Apps/Notes/Lines.lua")
    H.assertTrue(src2:find("return frame ~= nil and frame:IsShown() and frame:GetScale() > 0.01", 1, true) ~= nil,
        "in sight: shown and not shrunk away (TSM scales retail's to 0.001)")
    local hook = src:find("if button ~= \"LeftButton\" or not IsControlKeyDown() or not AuctionOpen() then return end", 1, true)
    H.assertTrue(hook ~= nil, "Ctrl+click on the words searches too")
end

local pass, fail, failures = H.runSuite("ChecklistAHSearch", tests)
return { pass = pass, fail = fail, failures = failures }

-- A checklist line's auction search (2026-10-30): Ctrl+click on the line
-- at an open house searches it, as Search AH on its menu does; a linked
-- list's extension searches first (its own term), else the house's own
-- bar, retail's or the classic browse box; away from the house Ctrl+click
-- does nothing, never types in the line.
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local tests = {}

function tests.ctrlClick_searchesAtTheHouse_elseNothing()
    local src = Read("Apps/Notes/ChecklistView.lua")
    local s = assert(src:find('row:SetScript("OnClick", function(self, button)', 1, true))
    local block = src:sub(s, s + 400)
    H.assertTrue(block:find("elseif IsControlKeyDown() then\n            if self.line and AuctionOpen() then SearchAH(self.line) end", 1, true) ~= nil,
        "Ctrl+click searches at an open house and otherwise does nothing")
    H.assertTrue(block:find("elseif self.line and not UI.board then\n            View.Edit(self.line.id)", 1, true) ~= nil,
        "a plain click still types in the line")
end

function tests.theHouse_isRetailsOrTheClassicOne()
    local src = Read("Apps/Notes/ChecklistView.lua")
    H.assertTrue(src:find('local ah = _G["AuctionHouseFrame"] or _G["AuctionFrame"]', 1, true) ~= nil)
    local s = assert(src:find("local function SearchAH(line)", 1, true))
    local body = src:sub(s, s + 1200)
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

local pass, fail, failures = H.runSuite("ChecklistAHSearch", tests)
return { pass = pass, fail = fail, failures = failures }

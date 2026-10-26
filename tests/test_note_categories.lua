-- An extension's note category (2026-10-26, the Auctionator extension's
-- "Shopping lists"): listed after Notes' own, named by the extension, and
-- a note's category names are search words ("shop" finds a shopping list).
local H = require("Harness")

local function Source()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Notes/Notes.lua", "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local function Load(categories)
    local src = Source()
    local s = assert(src:find("local CATEGORY_LABELS = {", 1, true))
    local fe = assert(src:find("function UI:EasyNotesCategoryLabel(cat)", s, true))
    local e = select(2, assert(src:find("\nend\r?\n", fe)))
    local env = setmetatable({
        UI = {}, ns = { NoteCategories = categories },
        L = setmetatable({}, { __index = function(_, k) return "L:" .. k end }),
    }, { __index = _G })
    assert(load(src:sub(s, e), "=Notes.lua categories", "t", env))()
    return env.UI
end

local tests = {}

function tests.anExtensionsCategoryComesAfterNotesOwn()
    local UI = Load({ ShoppingLists = "Shopping lists" })
    local cats = UI:GetEasyNotesCategories()
    H.assertEq(cats[1], "General")
    H.assertEq(cats[#cats], "ShoppingLists")
    H.assertEq(UI:EasyNotesCategoryLabel("ShoppingLists"), "Shopping lists", "named by its extension")
    H.assertEq(UI:EasyNotesCategoryLabel("Players"), "L:NOTES_CAT_PLAYERS", "Notes' own by their strings")
end

function tests.withoutExtensionsOnlyNotesOwn()
    local UI = Load(nil)
    H.assertEq(#UI:GetEasyNotesCategories(), 7)
end

function tests.searchFindsANoteByItsCategoriesNames()
    local src = Source()
    local s = assert(src:find("function notesNS.BuildSearchData()", 1, true))
    local body = src:sub(s, (src:find("\nend\r?\n", s)))
    H.assertTrue(body:find("UI:EasyNotesCategoriesOf(n)", 1, true) ~= nil, "each of its categories")
    H.assertTrue(body:find("UI:EasyNotesCategoryLabel(cat)", 1, true) ~= nil, "by its shown name")
end

local pass, fail, failures = H.runSuite("NoteCategories", tests)
return { pass = pass, fail = fail, failures = failures }

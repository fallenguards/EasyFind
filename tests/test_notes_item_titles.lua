-- Item notes read as the item's link (Apps/Notes/Notes.lua): titled
-- [Name] when made, the title and the On tooltips menu showing it in the
-- item's quality color once the client knows the item.

local H = require("Harness")

local function Extract(src, header)
    local s = assert(src:find(header, 1, true), header .. " not in Notes.lua")
    local indent = src:sub(src:sub(1, s):find("[^\n]*$"), s - 1)
    local _, e = src:find("\n" .. indent .. "end\r?\n", s)
    return src:sub(s, e)
end

local function Load(known)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Notes/Notes.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local env = setmetatable({
        Fmt = {},
        C_Item = {
            GetItemQualityByID = function(id) return known[id] end,
            GetItemQualityColor = function() return 1, 1, 1, "ffa335ee" end,
        },
        NoteTitle = function(note) return note.name end,
    }, { __index = _G })
    for _, header in ipairs({ "function Fmt.ItemColorCode(", "function Fmt.ItemLabel(", "function Fmt.ShownTitle(" }) do
        assert(load(Extract(src, header), "=Notes.lua", "t", env))()
    end
    return env.Fmt
end

local tests = {}

function tests.knownItem_wearsItsQualityColor()
    local Fmt = Load({ [19019] = 4 })
    H.assertEq(Fmt.ItemLabel(19019, "Thunderfury"), "|cffa335ee[Thunderfury]|r")
end

function tests.unknownItem_keepsItsBrackets()
    local Fmt = Load({})
    H.assertEq(Fmt.ItemLabel(19019, "Thunderfury"), "[Thunderfury]")
end

function tests.itemNoteTitle_colorsOnlyWhileTitledAsItsItem()
    local Fmt = Load({ [19019] = 4 })
    local note = { name = "[Thunderfury]", showsOn = { { type = "item", id = 19019, name = "Thunderfury" } } }
    H.assertEq(Fmt.ShownTitle(note), "|cffa335ee[Thunderfury]|r", "titled as its item")
    note.name = "My sword"
    H.assertEq(Fmt.ShownTitle(note), "My sword", "renamed: plain")
end

local pass, fail, failures = H.runSuite("NotesItemTitles", tests)
return { pass = pass, fail = fail, failures = failures }

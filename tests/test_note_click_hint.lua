-- The Ctrl+Right-click note hint (Search/NoteMenus.lua NoteClickOwner):
-- shown only for the client's buttons that send that click to the note
-- opener, never for an action bar button (it casts on a modified click).

local H = require("Harness")

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/NoteMenus.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local function NoteClickOwner(", 1, true))
    local _, e = src:find("\nend\r?\n", s)
    local bag = { OnModifiedClick = function() end }
    local bank = { OnModifiedClick = function() end }
    local env = setmetatable({
        issecret = function() return false end,
        _G = { ContainerFrameItemButtonMixin = bag, BankPanelItemButtonMixin = bank },
    }, { __index = _G })
    local chunk = src:sub(s, e):gsub("^local function NoteClickOwner", "function NoteClickOwner")
    assert(load(chunk, "=NoteMenus.lua", "t", env))()
    return env.NoteClickOwner, bag, bank
end

local function Button(fields)
    local b = fields or {}
    function b:GetName() return self.name end
    function b:GetParent() return self.parent end
    return b
end

local tests = {}

function tests.bagAndBankItems_getTheHint()
    local Owner, bag, bank = Load()
    H.assertTrue(Owner(Button({ OnModifiedClick = bag.OnModifiedClick })), "a bag item")
    H.assertTrue(Owner(Button({ OnModifiedClick = bank.OnModifiedClick })), "a bank item")
end

function tests.characterSlotsLootAndSpellbook_getTheHint()
    local Owner = Load()
    H.assertTrue(Owner(Button({ name = "CharacterHeadSlot" })), "a character slot")
    local element = { GetSlotIndex = function() return 1 end }
    element.Item = Button({ parent = element })
    H.assertTrue(Owner(element.Item), "a loot item")
    H.assertTrue(Owner(Button({ parent = { spellBookItemInfo = {} } })), "a spellbook entry")
    H.assertTrue(Owner(Button({ _efNoteClicks = true })), "a messenger line")
end

function tests.actionBarButton_getsNoHint()
    local Owner = Load()
    H.assertEq(Owner(Button({ name = "ActionButton1", OnModifiedClick = function() end })), false)
    H.assertEq(Owner(nil), false)
end

local pass, fail, failures = H.runSuite("NoteClickHint", tests)
return { pass = pass, fail = fail, failures = failures }

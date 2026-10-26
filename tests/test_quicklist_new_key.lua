-- A new quicklist's key and hold choice in its name prompt
-- (Apps/Quicklists/Quicklists.lua PromptNew), 2026-10-26: most lists get a
-- key, so the prompt offers it under the name with the hold switch.
local H = require("Harness")

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Quicklists/Quicklists.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function Quicklists:PromptNew(onCreated)", 1, true))
    local _, e = src:find("\nend\r?\n", s)
    local made, dialog, combo = {}, nil, nil
    local Store = {
        CleanName = function(v) return v ~= "" and v or nil end,
        FindByName = function() return nil end,
        Create = function(name) made.name = name return { id = 7 } end,
        SetKey = function(id, key) made.key = id == 7 and key end,
        SetHold = function(id, hold) made.hold = id == 7 and hold end,
    }
    local Quicklists = { Changed = function() end }
    local env = setmetatable({
        Quicklists = Quicklists, Store = Store, sformat = string.format, Print = print,
        L = setmetatable({}, { __index = function(_, k) return k end }),
        ns = {
            ShowThemedDialog = function(opts) dialog = opts end,
            Shortkeys = { PromptForCombo = function(_, _, _, onCombo) onCombo(combo) end },
        },
    }, { __index = _G })
    assert(load(src:sub(s, e), "=Quicklists.lua PromptNew", "t", env))()
    return Quicklists, made, function() return dialog end, function(c) combo = c end
end

local function Button()
    local b = { text = nil }
    function b:SetText(t) self.text = t end
    function b:GetParent() return { editBox = { ClearFocus = function() end } } end
    return b
end

local tests = {}

function tests.theKeyAndHoldGoWithTheNewList()
    local Q, made, dialog, press = Load()
    Q:PromptNew()
    local d = dialog()
    H.assertEq(d.extraButton.label, "QUICKLIST_COL_KEY", "a key row under the name")
    H.assertEq(d.checkText, "QUICKLIST_HOLD_CHECK", "and the hold switch")
    local btn = Button()
    press("CTRL-Q")
    d.extraButton.onClick(btn)
    H.assertEq(btn.text, "CTRL-Q", "the button shows the key")
    d.onAccept("Mounts", true)
    H.assertEq(made.name, "Mounts")
    H.assertEq(made.key, "CTRL-Q")
    H.assertEq(made.hold, true)
end

function tests.noKeyNoHold_aPlainList()
    local Q, made, dialog = Load()
    Q:PromptNew()
    dialog().onAccept("Bags", false)
    H.assertEq(made.name, "Bags")
    H.assertNil(made.key)
    H.assertNil(made.hold)
end

local pass, fail, failures = H.runSuite("QuicklistNewKey", tests)
return { pass = pass, fail = fail, failures = failures }

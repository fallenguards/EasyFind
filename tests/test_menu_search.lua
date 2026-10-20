-- Tests for a menu's search box (Shared/Utils.lua Utils.CursorMenuSearch):
-- only typing rebuilds a live search and keeps the box focused. A menu
-- opening sets the box's text to match, and taking that as typing focused
-- the box on every open of a pooled flyout.

local H = require("Harness")

local function Fake()
    local f = { scripts = {}, text = "" }
    function f:SetScript(name, fn) self.scripts[name] = fn end
    function f:GetText() return self.text end
    function f:SetText(t) self.text = t end
    function f:CreateFontString() return Fake() end
    -- Any other method does nothing; fields stay nil.
    return setmetatable(f, { __index = function(_, k)
        if k:match("^%u") then return function() end end
    end })
end

local function Load()
    local fh = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = fh:read("*a")
    fh:close()
    local s = assert(src:find("function Utils.CursorMenuSearch(", 1, true), "CursorMenuSearch not in Utils.lua")
    local _, e = src:find("\nend\r?\n", s)
    local shown = {}
    local Utils = {
        ShowCursorMenu = function(name, _, opts) shown[#shown + 1] = { name = name, opts = opts } end,
        LayoutCursorMenuRows = function() end,
    }
    local ns = {
        CreateRingedWell = function(shell) shell.ringInset = { GetFrameLevel = function() return 1 end } end,
        PaintRingedWell = function() end,
    }
    local env = setmetatable({
        Utils = Utils, ns = ns,
        CreateFrame = function() return Fake() end,
        CursorMenuCloseSubmenu = function() end,
        CursorMenuRoot = function(m) return m end,
    }, { __index = _G })
    assert(load(src:sub(s, e), "=Utils.lua CursorMenuSearch", "t", env))()
    local menu = Fake()
    menu._lastName = "Flyout"
    menu._lastOpts = { liveSearch = true }
    menu._rowsProvider = function(text) return { text = text } end
    local edit = Utils.CursorMenuSearch(menu, "Search").edit
    return edit, menu, shown
end

local tests = {}

function tests.typing_rebuildsAndKeepsFocus()
    local edit, menu, shown = Load()
    edit.text = "dru"
    edit.scripts.OnTextChanged(edit, true)
    H.assertEq(#shown, 1, "the rows rebuilt from the words")
    H.assertEq(menu._lastOpts._searchTyping, true, "the box keeps typing on")
end

function tests.openingClearsOldWords_withoutFocus()
    local edit, menu, shown = Load()
    edit.text = ""
    edit.scripts.OnTextChanged(edit, false)
    H.assertEq(#shown, 0, "no rebuild from a menu setting the text")
    H.assertEq(menu._lastOpts._searchTyping, nil, "the box is not focused")
end

local pass, fail, failures = H.runSuite("MenuSearch", tests)
return { pass = pass, fail = fail, failures = failures }

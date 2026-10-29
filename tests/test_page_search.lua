-- Search this page (Apps/Options/OptionsPanel.lua), run on a mock of the
-- General page: checkbox and dropdown rows chained top to bottom, a header,
-- the key card stacking its rows from its own top, and buttons below.
-- A kept row takes the slot of the hidden rows above it; it fell below
-- the window when it hung from the page's bottom instead (2026-10-28).
local H = require("Harness")

-- ==== a mock of the frames, with their layout =============================

local Frame, Region = {}, {}
local unpack = table.unpack or unpack
local function noop() end
local function Lookup(class)
    return function(_, k)
        local v = class[k]
        if v ~= nil then return v end
        if k == "GetChildren" and class == Region then return nil end
        -- Methods the test does not model do nothing; fields stay nil.
        if type(k) == "string" and k:match("^%u") then return noop end
        return nil
    end
end
local FrameMT = { __index = Lookup(Frame) }
local RegionMT = { __index = Lookup(Region) }

local function Base(obj, kind, parent)
    obj.kind, obj.parent, obj.points, obj.shown, obj.h, obj.w = kind, parent, {}, true, 20, 300
    obj.scripts, obj.hooks, obj.level = {}, {}, parent and (parent.level or 0) + 1 or 0
    return obj
end
local function NewFrame(kind, parent)
    local f = setmetatable(Base({ children = {}, regions = {} }, kind, parent), FrameMT)
    if parent then parent.children[#parent.children + 1] = f end
    return f
end
local function NewRegion(kind, parent)
    local r = setmetatable(Base({}, kind, parent), RegionMT)
    parent.regions[#parent.regions + 1] = r
    return r
end

local function Common(class)
    function class:SetPoint(p, rel, rp, x, y)
        if type(rel) == "string" then rel = nil end
        rp, x, y = rp or p, x or 0, y or 0
        for i, q in ipairs(self.points) do
            if q[1] == p then self.points[i] = { p, rel, rp, x, y } return end
        end
        self.points[#self.points + 1] = { p, rel, rp, x, y }
    end
    function class:GetPoint(i)
        local q = self.points[i or 1]
        if not q then return nil end
        return q[1], q[2] or self.parent, q[3], q[4], q[5]
    end
    function class:GetNumPoints() return #self.points end
    function class:ClearAllPoints() self.points = {} end
    function class:SetHeight(h) self.h = h end
    function class:GetHeight() return self.h end
    function class:SetSize(w, h) self.w, self.h = w, h end
    function class:SetWidth(w) self.w = w end
    function class:GetWidth() return self.w end
    function class:Show() self.shown = true end
    function class:Hide() self.shown = false end
    function class:SetShown(on) self.shown = on and true or false end
    function class:IsShown() return self.shown end
    function class:IsVisible()
        local o = self
        while o do
            if not o.shown then return false end
            o = o.parent
        end
        return true
    end
    function class:GetParent() return self.parent end
    function class:IsObjectType(t) return self.kind == t end
    function class:SetText(t)
        self.text = t
        local fn = self.scripts.OnTextChanged
        if fn then fn(self, false) end
        for _, h in ipairs(self.hooks.OnTextChanged or {}) do h(self, false) end
    end
    function class:GetText() return self.text end
    local function RefY(rel, rp)
        if rp:find("^TOP") then return rel:GetTop() end
        if rp:find("^BOTTOM") then return rel:GetBottom() end
        return (rel:GetTop() + rel:GetBottom()) / 2
    end
    function class:GetTop()
        if self.root then return 0 end
        local p, rel, rp, _, y = self:GetPoint(1)
        if not p then return self.parent:GetTop() end
        local ry = RefY(rel, rp) + y
        if p:find("^TOP") then return ry end
        if p:find("^BOTTOM") then return ry + self.h end
        return ry + self.h / 2
    end
    function class:GetBottom()
        if self.root then return -500 end
        for i = 1, #self.points do
            local p, rel, rp, _, y = self:GetPoint(i)
            if p:find("^BOTTOM") and i > 1 then return RefY(rel, rp) + y end
        end
        return self:GetTop() - self.h
    end
    function class:GetLeft()
        if self.root then return 0 end
        local p, rel, rp, x = self:GetPoint(1)
        if not p then return self.parent:GetLeft() end
        local rx = rp:find("RIGHT") and rel:GetLeft() + rel.w or rel:GetLeft()
        return rx + x
    end
end
Common(Frame)
Common(Region)
function Frame:GetChildren() return unpack(self.children) end
function Frame:GetRegions() return unpack(self.regions) end
function Frame:CreateFontString() return NewRegion("FontString", self) end
function Frame:CreateTexture() return NewRegion("Texture", self) end
function Frame:SetScript(name, fn) self.scripts[name], self.hooks[name] = fn, {} end
function Frame:GetScript(name) return self.scripts[name] end
function Frame:HookScript(name, fn)
    self.hooks[name] = self.hooks[name] or {}
    self.hooks[name][#self.hooks[name] + 1] = fn
end
function Frame:SetFrameLevel(l) self.level = l end
function Frame:GetFrameLevel() return self.level end

-- ==== the General page ====================================================

local function Page()
    local window = NewFrame("Frame")
    window.root = true
    local tf = NewFrame("Frame", window)
    tf.root = true
    local index = {}
    local function Row(anchor, rel, rp, x, y, label, h)
        local row = NewFrame("Frame", tf)
        row.h = h or 30
        row:SetPoint(anchor, rel, rp, x, y)
        local fs = row:CreateFontString()
        fs:SetPoint("LEFT", row, "LEFT", 8, 0)
        fs.text = label
        index[#index + 1] = { label = label, lower = label:lower(), tab = 1, target = row, region = fs }
        NewFrame("Button", row):SetPoint("RIGHT", row, "RIGHT", -8, 0)
        return row
    end
    local p = {}
    p.update = Row("TOPLEFT", tf, "TOPLEFT", 8, -8, "Show update reminders")
    p.minimap = Row("TOPLEFT", p.update, "BOTTOMLEFT", 0, -2, "Show Minimap Button")
    p.theme = Row("TOPLEFT", p.minimap, "BOTTOMLEFT", 0, -8, "Theme", 24)
    p.background = Row("TOPLEFT", p.theme, "BOTTOMLEFT", 0, -8, "Classic background", 24)
    p.header = tf:CreateFontString()
    p.header:SetPoint("TOPLEFT", p.background, "BOTTOMLEFT", 8, -18)
    p.header.text = "Keybindings (applies to every character)"
    index[#index + 1] = { label = p.header.text, lower = p.header.text:lower(), tab = 1, target = tf, region = p.header }
    p.card = NewFrame("Frame", tf)
    p.card.h = 4 * 26 + 8
    p.card:SetPoint("TOPLEFT", p.header, "BOTTOMLEFT", 0, -3)
    p.ring = NewFrame("Frame", p.card)
    p.ring:SetPoint("TOPLEFT", p.card, "TOPLEFT", -1, 1)
    p.ring:SetPoint("BOTTOMRIGHT", p.card, "BOTTOMRIGHT", 1, -1)
    p.keys = {}
    for i, label in ipairs({ "Toggle Search Bar:", "Focus Search Bar:", "Open Map Search Tab:", "Clear All:" }) do
        local row = NewFrame("Frame", p.card)
        row.h = 26
        row:SetPoint("TOPLEFT", p.card, "TOPLEFT", 0, -4 - (i - 1) * 26)
        local fs = row:CreateFontString()
        fs:SetPoint("LEFT", row, "LEFT", 8, 0)
        index[#index + 1] = { label = label, lower = label:lower(), tab = 1, target = row, region = fs }
        NewFrame("Button", row):SetPoint("LEFT", fs, "RIGHT", 8, 0)
        p.keys[i] = row
    end
    p.reset = NewFrame("Button", tf)
    p.reset:SetPoint("TOPLEFT", p.card, "BOTTOMLEFT", 0, -20)
    return window, tf, index, p
end

-- The Map page: a row, a separator, a header and its card whose first row
-- hangs from the card's top and the rest from the row above.
local function MapPage()
    local window = NewFrame("Frame")
    window.root = true
    local tf = NewFrame("Frame", window)
    tf.root = true
    local index = {}
    local function Row(parent, rel, rp, x, y, label)
        local row = NewFrame("CheckButton", parent)
        row.h = 28
        row:SetPoint("TOPLEFT", rel, rp, x, y)
        local fs = row:CreateFontString()
        fs:SetPoint("LEFT", row, "LEFT", 8, 0)
        index[#index + 1] = { label = label, lower = label:lower(), tab = 1, target = row, region = fs }
        NewFrame("Frame", row):SetPoint("RIGHT", row, "RIGHT", -8, 0)
        return row
    end
    local p = {}
    p.enable = Row(tf, tf, "TOPLEFT", 8, -6, "Enable Map Search Mode")
    p.sep = tf:CreateTexture()
    p.sep:SetPoint("TOPLEFT", tf, "TOPLEFT", 6, -40)
    p.header = tf:CreateFontString()
    p.header:SetPoint("TOPLEFT", tf, "TOPLEFT", 8, -48)
    index[#index + 1] = { label = "Map Tab", lower = "map tab", tab = 1, target = tf, region = p.header }
    p.card = NewFrame("Frame", tf)
    p.card.h = 28 * 4 + 8
    p.card:SetPoint("TOPLEFT", p.header, "BOTTOMLEFT", 0, -3)
    local ring = NewFrame("Frame", p.card)
    ring:SetPoint("TOPLEFT", p.card, "TOPLEFT", -1, 1)
    ring:SetPoint("BOTTOMRIGHT", p.card, "BOTTOMRIGHT", 1, -1)
    p.recent = Row(p.card, p.card, "TOPLEFT", 0, -4, "Show Recent Searches")
    p.count = Row(p.card, p.recent, "BOTTOMLEFT", 0, 0, "Recent Count")
    p.inline = Row(p.card, p.count, "BOTTOMLEFT", 0, 0, "Inline autocomplete")
    p.parents = Row(p.card, p.inline, "BOTTOMLEFT", 0, 0, "Show parent zones")
    return window, tf, index, p
end

local function Load(page)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Options/OptionsPanel.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("    -- ==== search this page, in the title band", 1, true))
    local e = assert(src:find("    -- ==== settings search, above the tabs", s, true))
    local window, tf, index, p = (page or Page)()
    local box
    local env = setmetatable({
        CreateFrame = function(kind, _, parent)
            local fr = NewFrame(kind, parent)
            if kind == "EditBox" then box = fr end
            return fr
        end,
        SearchWell = function(shell) shell.ringInset = NewFrame("Frame", shell) end,
        AddSearchClear = noop,
        Utils = { StyleSearchHint = noop, ReleaseFocusOnOutsideClick = noop },
        L = setmetatable({}, { __index = function(_, k) return k end }),
        OPT_FONTS = {}, SMALL_HIGHLIGHT_FONT = {},
        optionsFrame = setmetatable({
            bgTex = NewFrame("Frame", window), closeBtn = NewFrame("Button", window),
            PlacePageSearch = noop, SettingsIndex = function() return index end,
        }, { __index = window }),
        tabFrames = { tf },
        tabButtons = { { label = { GetText = function() return "General" end } } },
        Options = { _extensionsTabIndex = 9 },
        wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
        strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
    }, { __index = _G })
    assert(load(src:sub(s, e - 1), "=OptionsPanel.lua page search", "t", env))()
    return box, tf, p
end

local function Type(box, text)
    box:SetText(text)
end

local tests = {}

function tests.mini_keepsTheMinimapRow_inTheTopSlot()
    local box, _, p = Load()
    local top, left = p.update:GetTop(), p.update:GetLeft()
    Type(box, "mini")
    H.assertTrue(p.minimap:IsShown())
    H.assertFalse(p.update:IsShown())
    H.assertFalse(p.theme:IsShown())
    H.assertFalse(p.header:IsShown(), "a header that misses")
    H.assertFalse(p.card:IsShown())
    H.assertFalse(p.reset:IsShown(), "a button that is no setting")
    H.assertEq(p.minimap:GetTop(), top, "in the first row's slot, not below the page")
    H.assertEq(p.minimap:GetLeft(), left)
end

function tests.theme_keepsTheDropdownRow()
    local box, _, p = Load()
    local top = p.update:GetTop()
    Type(box, "theme")
    H.assertTrue(p.theme:IsShown())
    H.assertFalse(p.background:IsShown())
    H.assertEq(p.theme:GetTop(), top)
end

function tests.focus_keepsOneKeyRow_inACardThatCloses()
    local box, _, p = Load()
    local headerLeft, cardH = p.header:GetLeft(), p.card:GetHeight()
    Type(box, "focus")
    H.assertTrue(p.card:IsShown(), "the card holding the match")
    H.assertTrue(p.ring:IsShown(), "the card's ring")
    H.assertTrue(p.keys[2]:IsShown())
    H.assertFalse(p.keys[1]:IsShown())
    H.assertFalse(p.keys[3]:IsShown())
    H.assertEq(p.keys[2]:GetTop(), p.card:GetTop() - 4, "the card's first slot")
    H.assertEq(p.card:GetHeight(), cardH - 3 * 26)
    H.assertEq(p.card:GetTop(), -8, "the card up in the first row's slot")
    H.assertEq(p.card:GetLeft(), headerLeft, "the card keeps its indent")
end

function tests.aMatchingHeader_keepsItsSection()
    local box, _, p = Load()
    Type(box, "keybind")
    H.assertTrue(p.header:IsShown())
    H.assertTrue(p.card:IsShown())
    for i = 1, 4 do H.assertTrue(p.keys[i]:IsShown(), "key row " .. i) end
    H.assertFalse(p.minimap:IsShown())
    H.assertEq(p.header:GetTop(), -8)
end

function tests.cleared_thePageIsWholeAgain()
    local box, _, p = Load()
    local before = {}
    for _, o in ipairs({ p.update, p.minimap, p.theme, p.background, p.header, p.card, p.reset, p.keys[2] }) do
        before[o] = { o:GetTop(), o:GetLeft() }
    end
    local cardH = p.card:GetHeight()
    Type(box, "focus")
    Type(box, "")
    for o, at in pairs(before) do
        H.assertTrue(o:IsShown())
        H.assertEq(o:GetTop(), at[1])
        H.assertEq(o:GetLeft(), at[2])
    end
    H.assertEq(p.card:GetHeight(), cardH)
end

function tests.typingOn_fromMinToMini_movesFromTheLastNarrowing()
    local box, _, p = Load()
    local top = p.update:GetTop()
    Type(box, "min")
    H.assertTrue(p.update:IsShown(), "reminders holds min")
    H.assertTrue(p.minimap:IsShown())
    Type(box, "mini")
    H.assertEq(p.minimap:GetTop(), top)
end

function tests.mapPage_recentSearch_keepsItsRowInTheCard()
    local box, _, p = Load(MapPage)
    Type(box, "recent search")
    H.assertTrue(p.card:IsShown(), "the card holding the match")
    H.assertTrue(p.recent:IsShown())
    H.assertFalse(p.count:IsShown())
    H.assertFalse(p.enable:IsShown())
end

local pass, fail, failures = H.runSuite("PageSearch", tests)
return { pass = pass, fail = fail, failures = failures }

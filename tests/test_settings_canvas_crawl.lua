-- The crawler that lists other addons' settings panels as search rows
-- (Apps/Settings/BlizzSearch.lua CanvasControls, PushCanvasEntries): it
-- never reads EasyFind's own pages, whose options window it found embedded
-- there (rows named "+", "-" and dropdown values), and a control whose label
-- has no letter or digit names no setting.
local H = require("Harness")

local function source()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Settings/BlizzSearch.lua", "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local function slice(src, from, to)
    local s = assert(src:find(from, 1, true), from .. " not found")
    local e = assert(src:find(to, s, true), to .. " not found")
    return src:sub(s, e - 1)
end

local function widget(kind, label, kids)
    return {
        Text = { GetText = function() return label end },
        GetObjectType = function() return kind end,
        GetChildren = function() return (rawget(table, "unpack") or unpack)(kids or {}) end,
    }
end

local tests = {}

function tests.labelsWithoutLettersAreNotSettings()
    local env = setmetatable({ Utils = { StripMarkup = function(t) return t end } }, { __index = _G })
    local chunk = slice(source(), "local CANVAS_MAX", "\nlocal function CanvasRows") .. "\nreturn CanvasControls"
    local CanvasControls = assert(load(chunk, "=BlizzSearch.lua CanvasControls", "t", env))()
    local root = widget("Frame", nil, {
        widget("CheckButton", "+"), widget("CheckButton", "-"), widget("Slider", "Font size"),
        widget("CheckButton", "字体大小"), widget("CheckButton", "x2"),
    })
    local labels = {}
    for _, c in ipairs(CanvasControls(root)) do labels[#labels + 1] = c.label end
    table.sort(labels)
    H.assertEq(table.concat(labels, ", "), "Font size, x2, 字体大小")
end

function tests.easyFindsOwnPagesAreNotCrawled()
    local ours, other = { name = "EasyFind" }, { name = "SomeAddon" }
    local renamedOurs = { name = "EasyFind (old client)" }
    for _, c in ipairs({ ours, other, renamedOurs }) do
        c.GetName = function(self) return self.name end
    end
    local read = {}
    local env = setmetatable({
        ns = { OptionsCategory = renamedOurs },
        GetSettingsCategoryList = function() return { ours, other, renamedOurs } end,
        IsAddonCategory = function() return true end,
        PushCanvasRows = function(_, cat) read[#read + 1] = cat.name return false end,
    }, { __index = _G })
    local chunk = slice(source(), "local function PushCanvasEntries", "\n-- Rows other addons feed us")
        .. "\nreturn PushCanvasEntries"
    local PushCanvasEntries = assert(load(chunk, "=BlizzSearch.lua PushCanvasEntries", "t", env))()
    PushCanvasEntries({})
    H.assertEq(table.concat(read, ", "), "SomeAddon", "by its category and by its name")
end

local pass, fail, failures = H.runSuite("SettingsCanvasCrawl", tests)
return { pass = pass, fail = fail, failures = failures }

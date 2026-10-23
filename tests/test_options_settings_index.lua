-- The options window's settings index (Apps/Options/OptionsPanel.lua),
-- read by its sidebar search and fed to the search bar as EasyFind's own
-- settings: setting labels only. Button captions (the steppers' + and -,
-- menu and choice buttons) and labels without a letter or digit are not
-- settings; they showed as "+" and "-" rows under "EasyFind: Map".
local H = require("Harness")

local function region(text, font, opts)
    opts = opts or {}
    local fs = {
        _efSearchLabel = opts.tagged,
        GetText = function() return text end,
        GetFontObject = function() return { GetName = function() return font end } end,
        IsObjectType = function(_, t) return t == "FontString" end,
    }
    return fs
end

local function frame(kind, regions, children)
    local f = { kind = kind }
    f.IsObjectType = function(_, t) return t == kind or (t == "Button" and kind == "CheckButton") end
    f.GetRegions = function() return (rawget(table, "unpack") or unpack)(regions or {}) end
    f.GetChildren = function() return (rawget(table, "unpack") or unpack)(children or {}) end
    for _, r in ipairs(regions or {}) do r.GetParent = function() return f end end
    return f
end

local tests = {}

function tests.onlySettingLabelsAreIndexed()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Options/OptionsPanel.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("        local function IndexableLabel(fs)", 1, true), "IndexableLabel")
    local e = assert(src:find("        local function BuildIndex()", s, true), "BuildIndex")
    local env = setmetatable({ index = {}, Utils = { StripMarkup = function(t) return t end } }, { __index = _G })
    local IndexFrame = assert(load(src:sub(s, e - 1) .. "\nreturn IndexFrame", "=OptionsPanel.lua IndexFrame", "t", env))()

    local tab = frame("Frame", { region("Pin size", "GameFontNormalSmall") }, {
        frame("Button", { region("+", "GameFontNormalSmall") }),
        frame("Button", { region("-", "GameFontNormalSmall") }),
        frame("Button", { region("Glow", "GameFontNormalSmall") }),
        frame("CheckButton", { region("Show pins", "GameFontNormalSmall", { tagged = true }) }),
        frame("Frame", { region("-", "GameFontNormal"), region("Pin details", "GameFontHighlightSmall") }),
    })
    IndexFrame(tab, 3, nil, nil, {}, {})
    local labels = {}
    for i, hit in ipairs(env.index) do labels[i] = hit.label end
    table.sort(labels)
    H.assertEq(table.concat(labels, ", "), "Pin size, Show pins")
end

local pass, fail, failures = H.runSuite("OptionsSettingsIndex", tests)
return { pass = pass, fail = fail, failures = failures }

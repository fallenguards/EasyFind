-- The GPS menus on the game's own menu (ShowGameMenu in GPS.lua), as the
-- section in the objective tracker shows them: a flyout row that reads its
-- state (get) is a checkbox there too, and its own flyout nests under it.
-- The Show flyout's buckets showed no boxes and lost their flyouts.
local H = require("Harness")

local function Element(label, kind)
    local e = { label = label, kind = kind, children = {}, enabled = true }
    local function add(child) e.children[#e.children + 1] = child return child end
    function e:CreateDivider() return add(Element(nil, "divider")) end
    function e:CreateTitle(l) return add(Element(l, "title")) end
    function e:CreateButton(l, fn) local c = add(Element(l, "button")) c.click = fn return c end
    function e:CreateRadio(l, sel, fn) local c = add(Element(l, "radio")) c.selected, c.click = sel, fn return c end
    function e:CreateCheckbox(l, sel, fn) local c = add(Element(l, "check")) c.selected, c.click = sel, fn return c end
    function e:SetEnabled(v) self.enabled = v end
    function e:SetTooltip(fn) self.tooltip = fn end
    return e
end

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local function AddGameCheck", 1, true))
    local m = assert(src:find("ShowGameMenu = function", s, true))
    local _, e = assert(src:find("\n    return ok\r?\nend\r?\n", m))
    local root = Element("root", "menu")
    local env = setmetatable({
        MenuUtil = { CreateContextMenu = function(_, gen) gen(nil, root) end },
        MenuResponse = { Refresh = 2 },
        EasyFind = {},
        ns = {},
    }, { __index = _G })
    assert(load(src:sub(s, e), "=GPS.lua ShowGameMenu", "t", env))()
    return env.ShowGameMenu, root
end

local function Child(e, label)
    for _, c in ipairs(e.children) do
        if c.label == label then return c end
    end
end

local tests = {}

function tests.showsBuckets_areChecks_withTheirOwnFlyouts()
    local show, root = Load()
    local zones, services, inns = true, true, false
    H.assertTrue(show({}, { { kind = "submenu", label = "Show", rows = function()
        return {
            { text = "Zones", get = function() return zones end, onClick = function() zones = not zones end },
            { text = "Services", get = function() return services end, onClick = function() services = not services end,
              submenu = function()
                  return { { text = "Inns", disabled = not services, get = function() return inns end,
                             onClick = function() inns = not inns end } }
              end },
        }
    end } }))
    local sub = Child(root, "Show")
    local z, sv = Child(sub, "Zones"), Child(sub, "Services")
    H.assertEq(z.kind, "check", "a bucket is a checkbox")
    H.assertTrue(z.selected(), "ticked while on")
    z.click()
    H.assertFalse(zones, "a click turns it off")
    H.assertFalse(z.selected(), "and the box follows")
    H.assertEq(sv.kind, "check")
    local inn = Child(sv, "Inns")
    H.assertTrue(inn ~= nil, "the bucket's own flyout nests under it")
    H.assertEq(inn.kind, "check")
    H.assertFalse(inn.selected())
end

function tests.aDisabledRow_staysDisabled()
    local show, root = Load()
    show({}, { { kind = "submenu", label = "Show", rows = {
        { text = "Inns", disabled = true, get = function() return true end, onClick = function() end },
        { text = "Plain", disabled = true, onClick = function() end },
    } } })
    local sub = Child(root, "Show")
    H.assertFalse(Child(sub, "Inns").enabled)
    H.assertFalse(Child(sub, "Plain").enabled)
end

local pass, fail, failures = H.runSuite("GPSGameMenu", tests)
return { pass = pass, fail = fail, failures = failures }

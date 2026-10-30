-- The map tab's cog menu is the game's own menu where the client has the
-- menu kit (the tab is the game's look throughout; the GPS window keeps
-- EasyFind's): checks for the Show buckets, their kinds as children,
-- radios for the sizes, the toggle popup only without MenuUtil (2026-10-30).
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Chunk(path, from, to, ret, env)
    local src = Read(path)
    local s = assert(src:find(from, 1, true), from)
    local e = assert(src:find(to, s, true), to)
    return assert(load(src:sub(s, e - 1) .. "\nreturn " .. ret, "=" .. path, "t", setmetatable(env, { __index = _G })))()
end

local function Elem(list, kind, text)
    local e = { kind = kind, text = text, children = {}, enabled = true }
    list[#list + 1] = e
    function e:CreateTitle(t) return Elem(self.children, "title", t) end
    function e:CreateDivider() return Elem(self.children, "divider") end
    function e:CreateCheckbox(t, is, set) local c = Elem(self.children, "check", t) c.is, c.set = is, set return c end
    function e:CreateRadio(t, is, set) local c = Elem(self.children, "radio", t) c.is, c.set = is, set return c end
    function e:CreateButton(t, fn) local c = Elem(self.children, "button", t) c.fn = fn return c end
    function e:SetEnabled(on) self.enabled = on end
    function e:SetTooltip(fn) self.tip = fn end
    return e
end

local function Show(defs, withKit)
    local roots = {}
    local env = { GameTooltip_SetTitle = function() end, GameTooltip_AddNormalLine = function() end }
    if withKit then
        env.MenuUtil = { CreateContextMenu = function(owner, gen)
            local root = Elem(roots, "root")
            gen(owner, root)
            return root
        end }
    end
    local show = Chunk("MapSearch/MapTab.lua", "local function NativeTip", "-- A Show choice changed", "ShowNativeMapOptions", env)
    return show({}, defs), roots[1]
end

local tests = {}

function tests.theBucketsAreChecks_theirKindsChildren_sizesRadios()
    local zones, dungeons, size = true, false, 1
    local defs = {
        { kind = "title", label = "Show:" },
        { kind = "check", label = "Zones", tooltip = "Every zone", get = function() return zones end,
          set = function(v) zones = v end },
        { kind = "check", label = "Instances", get = function() return true end, set = function() end,
          rows = function() return {
              { text = "Dungeons", get = function() return dungeons end, onClick = function() dungeons = not dungeons end },
              { text = "Raids", get = function() return true end, onClick = function() end, disabled = true },
              { text = "Kinds", submenu = function() return { { text = "Delves", get = function() return true end, onClick = function() end } } end },
          } end },
        { kind = "separator" },
        { kind = "submenu", label = "Font Size", rows = function() return {
            { text = "Small", radio = true, get = function() return size == 0 end, onClick = function() size = 0 end },
            { text = "Normal", radio = true, get = function() return size == 1 end, onClick = function() size = 1 end },
        } end },
    }
    local shown, root = Show(defs, true)
    H.assertTrue(shown, "shown by the game's menu")
    local c = root.children
    H.assertEq(c[1].kind, "title")
    H.assertEq(c[2].kind, "check")
    H.assertEq(c[2].text, "Zones")
    H.assertTrue(c[2].tip ~= nil, "a tooltip on the row")
    H.assertTrue(c[2].is(), "read from get")
    c[2].set()
    H.assertFalse(zones, "a click flips it through set")
    H.assertEq(#c[3].children, 3, "the bucket's kinds under it")
    H.assertEq(c[3].children[1].kind, "check")
    c[3].children[1].set()
    H.assertTrue(dungeons, "a kind's click runs its onClick")
    H.assertFalse(c[3].children[2].enabled, "a grayed kind is disabled")
    H.assertEq(c[3].children[3].kind, "button", "a flyout-only row is a button")
    H.assertEq(c[3].children[3].children[1].text, "Delves", "with its own rows under it")
    H.assertEq(c[4].kind, "divider")
    H.assertEq(c[5].kind, "button")
    H.assertEq(c[5].children[2].kind, "radio")
    H.assertTrue(c[5].children[2].is())
    c[5].children[1].set()
    H.assertEq(size, 0)
end

function tests.noMenuKit_theTogglePopupStandsIn()
    local shown = Show({ { kind = "title", label = "Show:" } }, false)
    H.assertFalse(shown)
    local src = Read("MapSearch/MapTab.lua")
    H.assertTrue(src:find("if not ShowNativeMapOptions(cog, defs) then ns.ShowTogglePopup(\"EasyFindMapTabOptions\", cog, defs, {}) end", 1, true) ~= nil,
        "the cog asks the game's menu first")
end

local pass, fail, failures = H.runSuite("MapCogNative", tests)
return { pass = pass, fail = fail, failures = failures }

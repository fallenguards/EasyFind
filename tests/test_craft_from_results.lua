-- Crafting from a recipe row (Search/Results/Handlers/Selection.lua
-- CraftableCount, CanCraft, CraftRecipe; Render/Widgets.lua the row's
-- controls): a count, Create, Create All, as the profession window has
-- them (Forever, 2026-11-16, Linen Bandage).
local H = require("Harness")

local LINEN_BANDAGE, LINEN_CLOTH, WOOL_CLOTH = 3275, 2589, 2592

local function world(opts)
    opts = opts or {}
    local env = H.newEnv()
    local ns = H.newNs(env)
    local w = { crafted = {}, opened = {}, bags = opts.bags or { [LINEN_CLOTH] = 47 }, frames = {} }
    env.InCombatLockdown = function() return opts.inFight == true end
    env.Enum = { CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2 } }
    env.C_Item = { GetItemCount = function(id) return w.bags[id] or 0 end }
    env.C_SpellBook = { IsSpellKnown = function(id) return id ~= 3276 end }
    w.openProfession, w.listing, w.closes = nil, false, 0
    -- Every frame's handler for the events it holds, inside the call (the
    -- game fires TRADE_SKILL_SHOW inside OpenTradeSkill).
    w.event = function(event, ...)
        for _, f in ipairs(w.frames) do
            if f._events[event] then f:GetScript("OnEvent")(f, event, ...) end
        end
    end
    env.C_TradeSkillUI = {
        GetRecipeSchematic = function() return { reagentSlotSchematics = opts.slots or {
            { required = true, reagentType = 1, quantityRequired = 1, reagents = { { itemID = LINEN_CLOTH } } },
        } } end,
        GetCraftableCount = function() return 9 end,
        CraftRecipe = function(id, n) w.crafted[#w.crafted + 1] = id .. "x" .. n end,
        OpenRecipe = function(id) w.opened[#w.opened + 1] = id end,
        OpenTradeSkill = function(id)
            w.opened[#w.opened + 1] = id
            w.openProfession = id
            w.event("TRADE_SKILL_SHOW")
            return true
        end,
        CloseTradeSkill = function()
            w.closes, w.openProfession = w.closes + 1, nil
            w.event("TRADE_SKILL_CLOSE")
        end,
        GetBaseProfessionInfo = function() return { professionID = w.openProfession or 0 } end,
        IsDataSourceChanging = function() return w.listing end,
    }
    env.CreateFrame = function()
        local f, events = H.newFrame(), {}
        f._events = events
        f.RegisterEvent = function(_, e) events[e] = true end
        f.RegisterUnitEvent = function(_, e) events[e] = true end
        f.UnregisterEvent = function(_, e) events[e] = nil end
        f.UnregisterAllEvents = function() for e in pairs(events) do events[e] = nil end end
        w.frames[#w.frames + 1] = f
        return f
    end
    env.UIParent = {}
    local pf = { alpha = 1, points = { { "TOPLEFT", env.UIParent, "TOPLEFT", 12, -104 } } }
    function pf:GetAlpha() return self.alpha end
    function pf:SetAlpha(a) self.alpha = a end
    function pf:GetNumPoints() return #self.points end
    function pf:GetPoint(i) return (table.unpack or unpack)(self.points[i]) end
    function pf:ClearAllPoints() self.points = {} end
    function pf:SetPoint(...) self.points[#self.points + 1] = { ... } end
    env.ProfessionsFrame, env._G, w.pf = pf, env, pf
    H.loadModule("Search/Results/Handlers/Selection.lua", env, ns)
    w.Handlers, w.env = ns.ResultHandlers, env
    w.cast = function(event, id) w.event(event, "player", "Cast-1", id or LINEN_BANDAGE) end
    return w
end

local tests = {}

function tests.createAllCounts_theFewestLotsOfAnyReagent()
    local w = world()
    H.assertEq(w.Handlers.CraftableCount(LINEN_BANDAGE), 47)
    local two = world({
        bags = { [LINEN_CLOTH] = 47, [WOOL_CLOTH] = 5 },
        slots = {
            { required = true, reagentType = 1, quantityRequired = 1, reagents = { { itemID = LINEN_CLOTH } } },
            { required = true, reagentType = 1, quantityRequired = 2, reagents = { { itemID = WOOL_CLOTH } } },
            { required = false, reagentType = 0, quantityRequired = 1, reagents = { { itemID = 999 } } },
        },
    })
    H.assertEq(two.Handlers.CraftableCount(LINEN_BANDAGE), 2, "5 wool in lots of 2; an optional slot never limits")
    H.assertEq(world({ slots = {} }).Handlers.CraftableCount(LINEN_BANDAGE), 9, "no reagents read: the client's count")
    local qualities = world({ slots = {
        { required = true, reagentType = 1, quantityRequired = 1, reagents = { { itemID = 1 }, { itemID = 2 }, { itemID = 3 } } },
    } })
    H.assertNil(qualities.Handlers.CraftableCount(LINEN_BANDAGE), "a reagent in three qualities: the window's choice, no controls")
end

function tests.onlyALearnedRecipe_outOfAFight()
    local w = world()
    H.assertTrue(w.Handlers.CanCraft({ professionRecipeID = LINEN_BANDAGE }))
    H.assertFalse(w.Handlers.CanCraft({ professionRecipeID = 3276 }), "not learned")
    H.assertFalse(w.Handlers.CanCraft({ name = "First Aid", professionSkillLine = 129 }), "the profession row")
    H.assertFalse(world({ inFight = true }).Handlers.CanCraft({ professionRecipeID = LINEN_BANDAGE }), "in a fight")
end

local FIRST_AID = { professionRecipeID = LINEN_BANDAGE, professionSkillLine = 129, professionOpenID = 2942 }

function tests.create_withItsProfessionUp_craftsTheCount()
    local w = world()
    w.openProfession = 129
    w.event("TRADE_SKILL_SHOW")
    w.Handlers:CraftRecipe(FIRST_AID, 5)
    H.assertEq(table.concat(w.crafted, " "), "3275x5")
    H.assertEq(#w.opened, 0, "already open: no open")
    H.assertEq(w.pf.alpha, 1, "in sight, as the player left it")
    w.cast("UNIT_SPELLCAST_START")
    H.assertEq(w.closes, 0, "the player's own window stays up")
end

-- Forever, 2026-11-16 (craftquiet): OpenTradeSkill inside the press opens
-- at once; a close before the server takes the craft (~0.2 s) drops it, a
-- close at a cast's start drops the rest of the run.
function tests.create_withItClosed_opensUnseen_shutsAtTheLastStart()
    local w = world()
    w.Handlers:CraftRecipe(FIRST_AID, 3)
    H.assertEq(table.concat(w.opened, " "), "129", "opened inside the press")
    H.assertEq(table.concat(w.crafted, " "), "3275x3")
    H.assertEq(w.pf.alpha, 0, "unseen")
    H.assertEq(w.pf.points[1][4], 6000, "and off screen: at alpha 0 it still takes clicks")
    w.cast("UNIT_SPELLCAST_START")
    w.cast("UNIT_SPELLCAST_SUCCEEDED")
    w.cast("UNIT_SPELLCAST_START", 7934)
    w.cast("UNIT_SPELLCAST_START")
    H.assertEq(w.closes, 0, "two of three started; another spell's start counts nothing")
    w.cast("UNIT_SPELLCAST_START")
    H.assertEq(w.closes, 1, "shut as the last craft starts")
    H.assertEq(w.pf.alpha, 1)
    H.assertEq(w.pf.points[1][4], 12, "back where it stood")
    H.assertEq(#w.pf.points, 1)
end

function tests.anUnseenRun_endsOnAFailOrNoStart()
    local w = world()
    w.Handlers:CraftRecipe(FIRST_AID, 2)
    w.cast("UNIT_SPELLCAST_INTERRUPTED")
    H.assertEq(w.closes, 1, "interrupted: shut")
    H.assertEq(w.pf.alpha, 1)
    local quiet = world()
    quiet.Handlers:CraftRecipe(FIRST_AID, 1)
    quiet.env._clock:advance(2.9)
    H.assertEq(quiet.closes, 0)
    quiet.env._clock:advance(0.2)
    H.assertEq(quiet.closes, 1, "the server started nothing in 3 s: shut")
    H.assertEq(quiet.pf.alpha, 1)
    local between = world()
    between.Handlers:CraftRecipe(FIRST_AID, 2)
    between.cast("UNIT_SPELLCAST_START")
    between.env._clock:advance(10)
    H.assertEq(between.closes, 0, "a cast under way is never timed out")
    between.cast("UNIT_SPELLCAST_SUCCEEDED")
    between.env._clock:advance(3.1)
    H.assertEq(between.closes, 1, "no next start after a craft: shut")
end

function tests.thePlayerShuttingIt_endsTheRun()
    local w = world()
    w.Handlers:CraftRecipe(FIRST_AID, 4)
    w.env.C_TradeSkillUI.CloseTradeSkill()
    H.assertEq(w.closes, 1, "shut once (Escape), not again by us")
    H.assertEq(w.pf.alpha, 1, "and the window put back")
end

function tests.anotherProfessionInSight_switchesInSight()
    local w = world()
    w.openProfession = 197
    w.event("TRADE_SKILL_SHOW")
    w.Handlers:CraftRecipe(FIRST_AID, 1)
    H.assertEq(table.concat(w.crafted, " "), "3275x1")
    H.assertEq(w.pf.alpha, 1, "the player's window stays in sight")
    w.cast("UNIT_SPELLCAST_START")
    H.assertEq(w.closes, 0, "and stays up")
end

-- Which profession is open: its window's show and close, by its ids.
function tests.theRecipesProfession_openOrNot()
    local w = world()
    H.assertFalse(w.Handlers.RecipeProfessionOpen(FIRST_AID), "closed")
    w.openProfession = 197
    w.event("TRADE_SKILL_SHOW")
    H.assertFalse(w.Handlers.RecipeProfessionOpen(FIRST_AID), "Tailoring open")
    w.openProfession = 129
    w.event("TRADE_SKILL_SHOW")
    H.assertTrue(w.Handlers.RecipeProfessionOpen(FIRST_AID))
    w.event("TRADE_SKILL_CLOSE")
    H.assertFalse(w.Handlers.RecipeProfessionOpen(FIRST_AID), "closed again")
    H.assertEq(#w.crafted + #w.opened, 0, "watching crafts and opens nothing")
end

local function Source(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

-- Forever, 2026-11-16 (craftprobe, craftquiet): CraftRecipe with the
-- profession closed answers nothing; CraftRecipe from an event and
-- OpenTradeSkill/OpenRecipe from a timer are ADDON_ACTION_BLOCKED. Both
-- work inside the player's press: never from an event handler or a timer.
function tests.crafting_andOpening_onlyInsideAPress()
    local src = Source("Search/Results/Handlers/Selection.lua")
    local s = assert(src:find("-- Crafting from a recipe row", 1, true))
    local e = assert(src:find("function Handlers:CraftRecipe", s, true))
    local body = src:sub(s, assert(src:find("\nend\n", e, true)))
    H.assertNil(body:find("OpenRecipe(", 1, true))
    H.assertNil(body:find("OpenProfessionTarget(", 1, true))
    local handlers, timers = 0, 0
    for handler in body:gmatch('SetScript%("OnEvent", (.-)\nend%)') do
        handlers = handlers + 1
        H.assertNil(handler:find("CraftRecipe", 1, true), "never crafts from an event: blocked")
        H.assertNil(handler:find("OpenTradeSkill", 1, true), "never opens from an event: blocked")
    end
    for timed in body:gmatch("SafeAfter%((.-)\n    end%)") do
        timers = timers + 1
        H.assertNil(timed:find("CraftRecipe", 1, true), "never crafts from a timer")
        H.assertNil(timed:find("OpenTradeSkill", 1, true), "never opens from a timer: blocked")
    end
    H.assertTrue(handlers >= 2 and timers >= 1, "the event handlers and the timer were read")
    local craftFn = body:sub(e - s + 1)
    H.assertTrue(craftFn:find("OpenUnseen(data)", 1, true) ~= nil, "the press itself opens a closed one")
end

-- Forever, 2026-11-16 (/efd craftrow): hovered, the controls pushed the
-- name from -8 to -239; a redraw that left the name be read -239 as its
-- edge and pushed again to -470, the controls 103 px left of the row.
local function Region(x)
    local r = { points = { { "RIGHT", "row", "RIGHT", x, 0 } }, shown = true }
    function r:GetNumPoints() return #self.points end
    function r:GetPoint(i) return table.unpack(self.points[i]) end
    function r:SetPoint(point, rel, relPoint, px, py)
        for i, p in ipairs(self.points) do
            if p[1] == point then self.points[i] = { point, rel, relPoint, px, py } return end
        end
        self.points[#self.points + 1] = { point, rel, relPoint, px, py }
    end
    function r:IsShown() return self.shown end
    return r
end

local function Laid()
    local src = Source("Search/Results/Render/Widgets.lua")
    local s = assert(src:find("local CRAFT_H, CRAFT_GAP", 1, true))
    local e = assert(src:find("function Render.CalculatorRow", s, true))
    local Render, hovered = { SetClippedText = function() end }, { v = true }
    local ns = {
        ResultHandlers = { CanCraft = function() return true end },
        Search = { GetSelectedIndex = function() return 0 end },
        FitButtonRow = function() end,
        most = 14,
    }
    ns.ResultHandlers.CraftableCount = function() return ns.most end
    local function Button(w)
        return { GetWidth = function() return w end, SetEnabled = function() end, SetText = function() end }
    end
    local group = { shown = false, width = 0 }
    function group:Hide() self.shown = false end
    function group:Show() self.shown = true end
    function group:IsShown() return self.shown end
    function group:IsMouseOver() return false end
    function group:SetWidth(w) self.width = w end
    function group:ClearAllPoints() end
    function group:SetPoint(_, _, _, x) self.x = x end
    local sub = Region(-8)
    sub.shown = false
    local row = { text = Region(-8), pathSubtext = sub, craftGroup = group, data = { professionRecipeID = 2963 },
        craftBox = { HasFocus = function() return false end, SetText = function() end },
        craftCreate = Button(54), craftAll = Button(93) }
    function row:IsShown() return true end
    function row:IsMouseOver() return hovered.v end
    function row:GetWidth() return 361 end
    -- An error inside a layout is kept on the row for the test to read.
    local Utils = { ErrorHandler = function(err) row._layError = tostring(err) end }
    local env = setmetatable({ Render = Render, ns = ns, Utils = Utils,
        CreateFrame = function() return { SetScript = function() end, RegisterEvent = function() end,
            UnregisterEvent = function() end } end }, { __index = _G })
    assert(load(src:sub(s, e - 1), "=Widgets.lua craft", "t", env))()
    return Render, row, hovered, ns
end

function tests.aRedrawWhileHovered_neverPushesTheNameTwice()
    local Render, row, hovered = Laid()
    local entry = { data = row.data }
    Render.ApplyCraftControls(row, entry)
    H.assertEq(row.text.points[1][4], -239, "hovered: the name stops short of the controls")
    H.assertEq(row.craftGroup.x, -8, "the controls end where the name did")
    Render.ApplyCraftControls(row, entry)   -- a redraw that left the name be
    H.assertEq(row.text.points[1][4], -239, "pushed once, not to -470")
    H.assertEq(row.craftGroup.x, -8, "the controls stay in the row")
    row.text:SetPoint("RIGHT", "row", "RIGHT", -20, 0)   -- a redraw that laid it again
    Render.ApplyCraftControls(row, entry)
    H.assertEq(row.craftGroup.x, -20, "a new edge is taken")
    H.assertEq(row.text.points[1][4], -251)
    hovered.v = false
    Render.LayoutCraft(row)
    H.assertEq(row.text.points[1][4], -20, "unhovered: the name gets its edge back")
    H.assertFalse(row.craftGroup:IsShown())
end

-- Forever, 2026-11-17 (/efd craftrow): a redraw hid the controls under
-- the mouse; the hovered button's leave, fired inside that hide, showed
-- them again, and Create All stayed shown but unseen.
function tests.aLeaveInsideTheHide_neverShowsTheControls()
    local Render, row = Laid()
    local entry = { data = row.data }
    Render.ApplyCraftControls(row, entry)
    local group, showsInHide = row.craftGroup, 0
    local hide, show = group.Hide, group.Show
    function group:Show() if self.hiding then showsInHide = showsInHide + 1 end show(self) end
    function group:Hide()
        self.hiding = true
        hide(self)
        Render.LayoutCraft(row)   -- the hovered control's OnLeave
        self.hiding = nil
    end
    row.data = { professionRecipeID = 3275 }   -- the row drawn with another recipe
    Render.ApplyCraftControls(row, { data = row.data })
    H.assertEq(showsInHide, 0, "no show inside the hide")
    H.assertTrue(group:IsShown(), "shown again once the hide is done")
end

-- Forever, 2026-11-17: "i have to click multiple times", and the row's
-- tooltip flashed while crafting: each redraw (the bags changing, a
-- refresh) hid the controls under the mouse and showed them again. The
-- same recipe redrawn keeps them up.
function tests.aRedrawOfTheSameRecipe_neverHidesTheControls()
    local Render, row = Laid()
    local entry = { data = row.data }
    Render.ApplyCraftControls(row, entry)
    local hides, hide = 0, row.craftGroup.Hide
    function row.craftGroup:Hide() hides = hides + 1 hide(self) end
    Render.ApplyCraftControls(row, entry)
    Render.ApplyCraftControls(row, entry)
    H.assertEq(hides, 0, "never hidden by a redraw")
    H.assertTrue(row.craftGroup:IsShown())
    H.assertEq(row.text.points[1][4], -239, "the name pushed once")
end

-- Forever, 2026-11-17, Create All's last craft: "C stack overflow" in
-- SetEnabled. Disabling a button under the mouse fires its leave inside the
-- call, the button still enabled; the leave laid the row out again, which
-- disabled it again, without end. One layout at a time.
function tests.aLeaveInsideSetEnabled_neverLaysOutAgain()
    local Render, row, _, ns = Laid()
    Render.ApplyCraftControls(row, { data = row.data })
    ns.most = 0   -- the last craft used the cloth up
    local layouts, enabled = 0, true
    function row.craftAll:SetEnabled(on)
        layouts = layouts + 1
        if layouts > 50 then error("laid out without end") end
        if on ~= enabled then Render.LayoutCraft(row) end   -- the leave, before it reads disabled
        enabled = on
    end
    Render.LayoutCraft(row)
    H.assertNil(row._layError, "no error inside the layout")
    H.assertTrue(layouts <= 2, "laid out once, not again from the leave: " .. layouts)
    H.assertTrue(row.craftGroup:IsShown(), "still shown")
end

-- Forever, 2026-11-17 ("after one made, the row like tweaks out"): each
-- redraw laid the controls against the row's edge, then the shortcut
-- gutter moved the name to the Alt hint and dropped their push; 87 ms
-- later the selection pass laid them again, 28 px left. The row's own
-- pass lays them after the gutter, at the name's final end.
function tests.theRowPass_laysTheControlsAfterTheGutter()
    local src = Source("Search/Results/Render/Core.lua")
    local gutter = assert(src:find("ApplyResultShortcutGutter(resultRow)", 1, true), "the gutter")
    local craft = assert(src:find("Render.ApplyCraftControls(resultRow, entry)", 1, true), "the controls")
    H.assertTrue(craft > gutter, "the controls after the gutter")
    H.assertNil(src:find("Render.ApplyCraftControls(resultRow, entry)", craft + 1, true), "laid once per row pass")
end

-- The controls sit on the row, built once per pooled row, laid out by
-- hover and selection (Navigation) and redrawn with the bags.
function tests.theRowControls_areWired()
    H.assertTrue(Source("Search/Results/Render/Core.lua"):find("Render.ApplyCraftControls(resultRow, entry)", 1, true) ~= nil)
    H.assertTrue(Source("Search/Results/Navigation.lua"):find("ns.ResultRender.LayoutCraft(resultRow)", 1, true) ~= nil)
    local widgets = Source("Search/Results/Render/Widgets.lua")
    H.assertTrue(widgets:find('_G["CREATE_PROFESSION"]', 1, true) ~= nil, "the game's own Create")
    H.assertTrue(widgets:find('_G["PROFESSIONS_CREATE_ALL_FORMAT"]', 1, true) ~= nil, "and its Create All [n]")
    H.assertTrue(widgets:find("ns.ResultHandlers:CraftRecipe(row.data, row._craftMost)", 1, true) ~= nil,
        "Create All crafts in its own click")
end

local pass, fail, failures = H.runSuite("CraftFromResults", tests)
return { pass = pass, fail = fail, failures = failures }

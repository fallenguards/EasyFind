-- Jumping down: what lets this character land from any height, and so how
-- high a drop its walks may take. Spells, items and auras from the client's
-- data (feather fall aura on the spell); a reagent where the client asks one.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

local Jumps = {}
ns.GPSJumps = Jumps

local L = ns.L
local sformat, mfloor, mmax, mhuge = string.format, math.floor, math.max, math.huge
local issecret = _G.issecretvalue or function() return false end
local C_Spell, C_Item, C_Container = C_Spell, C_Item, C_Container

-- Slow fall, cast at the top: Slow Fall and Levitate (a Light Feather on
-- WoW Forever).
local SLOW_FALL_SPELLS = { 130, 1706 }
local FOREVER_REAGENT = { [130] = 17056, [1706] = 17056 }
-- Immunity, cast at the top and lasting the fall: Divine Shield, Ice Block.
local IMMUNE_SPELLS = { 642, 1020, 11958, 27619 }
-- Slow fall from an item: worn ones are used from their slot.
local SLOW_FALL_ITEMS = {
    { id = 260810, worn = true },    -- SAF-T Disposable Parachute
    { id = 10518, worn = true },     -- Parachute Cloak
    { id = 275729, worn = true },    -- Rusty Propeller Blade
    { id = 10684 },                  -- Colossal Parachute
    { id = 274616 },                 -- Aetherstill Spirits
}
-- What an auction house can sell to a character with none of the above.
Jumps.SHOP_ITEM = 260810
-- The shop tip shows when the item saves at least this many seconds.
local SHOP_MIN_SAVE = 60

local function Ready(start, duration)
    if issecret(start) or issecret(duration) then return false end
    return not (start and duration and start > 0 and duration > 1.5)
end

local function SpellReady(id)
    if not (IsPlayerSpell and IsPlayerSpell(id)) then return false end
    local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(id)
    return not info or Ready(info.startTime, info.duration)
end

local function SpellName(id)
    return (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or tostring(id)
end

local function ItemName(id)
    return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or nil
end

-- The way this character lands safely now: { name, kind = "spell" | "item" |
-- "immune", id, wear = true when the item has to go on first }, or nil.
function Jumps.Helper()
    for _, id in ipairs(SLOW_FALL_SPELLS) do
        local reagent = ns.Caps and ns.Caps.forever and FOREVER_REAGENT[id]
        if SpellReady(id) and (not reagent or (C_Item.GetItemCount(reagent) or 0) > 0) then
            return { kind = "spell", id = id, name = SpellName(id) }
        end
    end
    for _, item in ipairs(SLOW_FALL_ITEMS) do
        if C_Item and (C_Item.GetItemCount(item.id) or 0) > 0 then
            local start, duration = C_Container.GetItemCooldown(item.id)
            if Ready(start, duration) then
                local worn = C_Item.IsEquippedItem and C_Item.IsEquippedItem(item.id)
                return { kind = "item", id = item.id, name = ItemName(item.id) or tostring(item.id),
                         wear = item.worn and not worn or nil }
            end
        end
    end
    for _, id in ipairs(IMMUNE_SPELLS) do
        if SpellReady(id) then return { kind = "immune", id = id, name = SpellName(id) } end
    end
    return nil
end

-- The highest drop this character's walks take on continent ci: any with a
-- way to land safely, else what a full-health character survives, else the
-- safe height (nil).
function Jumps.Limit(ci)
    local Nav = ns.GPSNav
    if not (Nav and Nav.DropHeights) then return nil end
    local safe, survive = Nav.DropHeights(ci or 0)
    if not safe then return nil end
    if Jumps.Helper() then return mhuge end
    return survive
end

-- The name of the shop item, for the tip.
function Jumps.ShopItemName()
    return ItemName(Jumps.SHOP_ITEM) or L["GPS_PARACHUTE"]
end

-- Whether a route's walks jump down a ledge that costs health.
function Jumps.Any(steps)
    for i = 1, #steps do
        if steps[i].jumps then return true end
    end
    return false
end

-- A walk that jumps down a ledge says how: at full health, or with what
-- lands the character safely when the drop is past what a fall leaves.
function Jumps.StepText(step)
    local jumps = step and step.jumps
    if not jumps then return nil end
    local high = 0
    for i = 1, #jumps do high = mmax(high, jumps[i].h) end
    local Nav = ns.GPSNav
    local ci = step.arrive and step.arrive.ci or 0
    local survive
    if Nav and Nav.DropHeights then survive = select(2, Nav.DropHeights(ci)) end
    local yd = mfloor(high + 0.5)
    local helper = (not survive or high > survive) and Jumps.Helper()
    if helper then
        return sformat(helper.wear and L["GPS_JUMP_WEAR_FMT"] or L["GPS_JUMP_HELPER_FMT"], helper.name, yd)
    end
    return sformat(L["GPS_JUMP_FULL_FMT"], yd)
end

-- With nothing to land safely from any height: what the shop item would
-- save on this route, when that is a minute or more, as { save, name }.
-- A trip of several stops is not tried again.
function Jumps.ShopTip(route)
    local Nav, G = ns.GPSNav, ns.GPS
    local ci = route.from and route.from.ci or 0
    if not (Nav and Nav.DropHeights and Nav.DropHeights(ci) and G and route.total and route.dest) then return nil end
    if (route.stops and #route.stops > 1) or Jumps.Helper() then return nil end
    local _, total = G:BuildRoute(route.dest, nil, route.wayAvoid, true, nil, nil, mhuge)
    if not (total and route.total - total >= SHOP_MIN_SAVE) then return nil end
    return { save = route.total - total, name = Jumps.ShopItemName() }
end

local _, AL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and AL.Triggers) then return end

-- The ready-made alerts: each fills a rule the editor then shows, so any
-- part of it can still change.
local Templates = {}
AL.Templates = Templates

local L = ns.L

local function SpellName(id, fallback)
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
    return name or fallback
end

local function ItemName(id, fallback)
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
    return name or fallback
end

local HEARTHSTONE, MOONCLOTH, TRANSMUTE = 6948, 18560, 17187

Templates.LIST = {
    { group = "ready", label = L["ALERTS_T_HEARTH"], make = function()
        return { kind = "cooldown", item = HEARTHSTONE, label = ItemName(HEARTHSTONE, L["ALERTS_T_HEARTH"]) }
    end },
    { group = "ready", label = L["ALERTS_T_MOONCLOTH"], make = function()
        return { kind = "cooldown", spell = MOONCLOTH, alts = true, label = SpellName(MOONCLOTH, L["ALERTS_T_MOONCLOTH"]) }
    end },
    { group = "ready", label = L["ALERTS_T_TRANSMUTE"], make = function()
        return { kind = "cooldown", spell = TRANSMUTE, alts = true, label = SpellName(TRANSMUTE, L["ALERTS_T_TRANSMUTE"]) }
    end },
    { group = "ready", label = L["ALERTS_T_COOLDOWN"], make = function()
        return { kind = "cooldown" }
    end },
    { group = "running", label = L["ALERTS_T_FLASK"], make = function()
        return { kind = "buffEnding", minutes = 5 }
    end },
    { group = "running", label = L["ALERTS_T_RAID_BUFF"], make = function()
        return { kind = "buffMissing" }, { conds = { { kind = "instance", value = "raid" } }, waitCombat = true }
    end },
    { group = "running", label = L["ALERTS_T_POISON"], make = function()
        return { kind = "weaponEnchant", hand = "main", minutes = 5 }, { waitCombat = true }
    end },
    { group = "running", label = L["ALERTS_T_REAGENT"], make = function()
        return { kind = "itemLow", count = 5 }
    end },
    { group = "running", label = L["ALERTS_T_DURABILITY"], make = function()
        return { kind = "durability", percent = 20 }, { waitCombat = true }
    end },
    { group = "running", label = L["ALERTS_T_BAGS"], make = function()
        return { kind = "bagsFull", slots = 2 }, { waitCombat = true }
    end },
    { group = "resets", label = L["ALERTS_T_LOCKOUT"], make = function()
        return { kind = "lockout" }
    end },
    { group = "resets", label = L["ALERTS_T_RESTED"], make = function()
        return { kind = "rested" }
    end },
    { group = "resets", label = L["ALERTS_T_MAIL"], make = function()
        return { kind = "mail", days = 3 }
    end },
    { group = "people", label = L["ALERTS_T_ONLINE"], make = function()
        return { kind = "online" }
    end },
    { group = "people", label = L["ALERTS_T_WHISPER"], make = function()
        return { kind = "whisper" }
    end },
    { group = "people", label = L["ALERTS_T_LFM"], make = function()
        return { kind = "chatWords", words = "lfm" }, { gap = 60 }
    end },
    { group = "people", label = L["ALERTS_T_REQUEST"], make = function()
        return AL.Triggers.Fresh("request")
    end },
    { group = "nearby", label = L["ALERTS_T_RARE"], make = function()
        return AL.Triggers.Fresh("nameplate"), { signals = { chat = true, big = true, sound = "raidwarning", screen = "gold", taskbar = true } }
    end },
}

-- A new rule (not yet saved) from a list entry.
function Templates.Draft(entry)
    local trigger, extra = entry.make()
    local draft = {
        id = AL.Store.sv.nextID,
        on = true,
        trigger = trigger,
        conds = {},
        signals = AL.Store.Copy(AL.Store.DEFAULT_SIGNALS),
    }
    for k, v in pairs(extra or {}) do draft[k] = AL.Store.Copy(v) end
    return draft
end

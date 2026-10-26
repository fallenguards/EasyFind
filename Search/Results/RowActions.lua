local _, ns = ...
-- Result actions: an entry of the right-click menu (Pin, Add to note, an
-- extension's Shopping list) done by a chord, over the row under the mouse
-- or the one the arrow keys picked, or by a click with two modifiers held
-- (one modifier is the row's own Result clicks). An entry with a flyout
-- (which note, which list) opens it at the cursor. A key chord always
-- holds Alt or Ctrl: a plain or Shift key would type in the search box.
-- EasyFind.db.rowActionKeys[actionId] = "ALT-N" or "ALT-SHIFT-CLICK".
local RowActions = {}
ns.ResultRowActions = RowActions
local L = ns.L
local Utils = ns.Utils

-- The core actions in the settings' order; extensions' Add entries follow.
local CORE = {
    { id = "pin",       label = "ROWACT_PIN" },
    { id = "guide",     label = "CTX_GUIDE" },
    { id = "note",      label = "CTX_ADD_NOTE" },
    { id = "quicklist", label = "CTX_ADD_QUICKLIST" },
    { id = "alias",     label = "CTX_ADD_ALIAS" },
    { id = "shortkey",  label = "CTX_ADD_SHORTKEY" },
    { id = "macro",     label = "CTX_CREATE_MACRO" },
    { id = "send",      label = "CTX_SEND_LINK" },
    { id = "blacklist", label = "CTX_BLACKLIST" },
}

-- Chords the search box already answers.
local TAKEN = {
    ["CTRL-A"] = true, ["CTRL-C"] = true, ["CTRL-V"] = true, ["CTRL-X"] = true, ["CTRL-Z"] = true,
    ["CTRL-Y"] = true, ["CTRL-SHIFT-C"] = true,
    ["ALT-J"] = true, ["ALT-K"] = true, ["ALT-L"] = true,
}

local function Keys()
    local db = EasyFind and EasyFind.db
    if not db then return {} end
    if type(db.rowActionKeys) ~= "table" then db.rowActionKeys = {} end
    return db.rowActionKeys
end

-- Every bindable action: { id, label, icon, iconCoords }.
function RowActions.List()
    local out = {}
    for i = 1, #CORE do out[i] = { id = CORE[i].id, label = L[CORE[i].label] } end
    local Extensions = ns.Extensions
    for _, target in ipairs(Extensions and Extensions.AddTargets or {}) do
        local owner = Extensions.Get(target.extension)
        if owner then
            out[#out + 1] = { id = "add:" .. target.key, label = target.fullLabel or target.label,
                              icon = owner.icon, iconCoords = owner.iconCoords }
        end
    end
    return out
end

function RowActions.KeyOf(id) return Keys()[id] end

function RowActions.ActionFor(combo)
    for id, key in pairs(Keys()) do
        if key == combo then return id end
    end
    return nil
end

local MOD_TEXT = { ALT = "Alt", CTRL = "Ctrl", SHIFT = "Shift" }

-- "Alt+N" for "ALT-N", as the menus write chords.
function RowActions.ChordText(combo)
    if not combo or combo == "" then return nil end
    local parts = {}
    for part in combo:gmatch("[^%-]+") do parts[#parts + 1] = part end
    for i = 1, #parts - 1 do parts[i] = MOD_TEXT[parts[i]] or parts[i] end
    local Text = ns.ResultText
    if parts[#parts] == "CLICK" then
        parts[#parts] = L["HINT_CLICK"]
    else
        parts[#parts] = Text and Text.AbbrevBinding and Text:AbbrevBinding(parts[#parts]) or parts[#parts]
    end
    return table.concat(parts, "+")
end

-- The action a click with the modifiers held now does, if any.
function RowActions.ActionForClick()
    return RowActions.ActionFor(Utils.ModifierCombo("CLICK"))
end

-- Why a chord cannot be a result action, or nil when it can.
function RowActions.Refusal(combo)
    if combo:find("CLICK$") then
        local _, mods = combo:gsub("%-", "")
        return mods < 2 and L["ROWACT_CLICK_TWO_MODS"] or nil
    end
    if not combo:find("ALT%-") and not combo:find("CTRL%-") then return L["ROWACT_NEEDS_MOD"] end
    if TAKEN[combo] or combo:match("^ALT%-%d$") or combo:match("^ALT%-NUMPAD%d$") then
        return L["ROWACT_TAKEN"]
    end
    local bound = GetBindingAction and GetBindingAction(combo)
    if bound and bound:sub(1, 9) == "EASYFIND_" then return L["ROWACT_TAKEN"] end
    return nil
end

-- Binds a chord (nil clears). A chord another action had moves here; its
-- id is returned.
function RowActions.Set(id, combo)
    local keys = Keys()
    local moved
    if combo then
        moved = RowActions.ActionFor(combo)
        if moved and moved ~= id then keys[moved] = nil else moved = nil end
    end
    keys[id] = combo
    return moved
end

function RowActions.Reset()
    if EasyFind and EasyFind.db then EasyFind.db.rowActionKeys = {} end
end

-- The row a chord acts on: under the mouse, else the arrow keys' pick.
function RowActions.TargetRow()
    local Results, Search = ns.Results, ns.Search
    local hover = Results and Results._hoverRow
    if hover and hover:IsShown() and hover:IsMouseOver() and hover.data then return hover end
    local index = Search and Search.GetSelectedIndex and Search:GetSelectedIndex() or 0
    local buttons = index > 0 and Search:GetResultButtons()
    local row = buttons and buttons[index]
    return row and row:IsShown() and row.data and row or nil
end

-- The menu entry of that id among rows, a flyout's members included.
local function FindEntry(rows, id)
    for _, r in ipairs(rows or {}) do
        if r.actionId == id then return r end
        if type(r.submenu) == "table" and not r.actionId then
            local inner = FindEntry(r.submenu, id)
            if inner then return inner end
        end
    end
    return nil
end

-- Does the action on the row; false when this row's menu has no such entry.
function RowActions.Run(id, row)
    local Rows = ns.ResultRows
    local isPinned, onPin, onGuide, onAddAlias, extra = Rows:ResultMenuModel(row)
    if not extra then return false end
    local entry = FindEntry(Utils.PinMenuRows(isPinned, onPin, onGuide, onAddAlias, extra), id)
    if not entry or entry.disabled then return false end
    if entry.submenu then
        local Search = ns.Search
        local editBox = Search:GetSearchFrame() and Search:GetSearchFrame().editBox
        if editBox then
            editBox._menuUnfocus = true
            editBox:ClearFocus()
            editBox._menuUnfocus = nil
        end
        -- The right-click menu's look; width is a floor, the menu measures its labels.
        local opts = { strata = "TOOLTIP", level = 100, width = 96, rowHeight = 22 }
        opts.scale = EasyFind.db.uiSearchScale or 1.0
        Utils.ShowCursorMenu("EasyFindRowActionPicker", entry.submenu, opts)
        return true
    end
    if entry.onClick then
        entry.onClick()
        return true
    end
    return false
end

-- A key on the search box or the arrow-key list: true when a result
-- action took it.
function RowActions.HandleKey(box, key)
    if not key or Utils.IsModifierKey(key) then return false end
    local combo = Utils.ModifierCombo(key)
    local id = RowActions.ActionFor(combo)
    if not id then return false end
    local row = RowActions.TargetRow()
    if not row then return false end
    -- Alt+letter can still type its letter into a focused box.
    if box and box.HasFocus and box:HasFocus() and #key == 1 then Utils.SwallowNextCharInsert(box, key) end
    RowActions.Run(id, row)
    return true
end

return RowActions

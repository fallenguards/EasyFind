local _, AL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and AL.Store and AL.Triggers and AL.Conditions and AL.Engine and AL.Templates) then return end

-- The alerts window: the list of alerts, and the editor a list entry or
-- "Build your own" opens (When, Only if, Then).
local Window = {}
AL.Window = Window

local Store, T, C, Engine, Templates = AL.Store, AL.Triggers, AL.Conditions, AL.Engine, AL.Templates
local Utils = ns.Utils
local L = ns.L
local CreateFrame, UIParent, time = CreateFrame, UIParent, time
local sformat, mfloor, mmax, tonumber, tostring = string.format, math.floor, math.max, tonumber, tostring
local ipairs, pairs, type, smatch, strtrim = ipairs, pairs, type, string.match, strtrim

local W, H, PAD, HEADER_H, ROW_H, FOOT_H = 380, 470, 10, 32, 38, 40
local LABEL_W = 92

-- Frames and state in one table (upvalue budget).
local UI = { rows = {}, pools = {} }

-- Pieces

local function Text(parent, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template)
    ns.RegisterAddonFont(fs)
    fs:SetJustifyH("LEFT")
    return fs
end

local function ShowMenu(owner, rows)
    local menu = UI.menu
    if menu and menu:IsShown() and menu.toggleOwner == owner then
        menu:Hide()
        return
    end
    UI.menu = Utils.ShowCursorMenu("EasyFindAlertsMenu", rows, { toggleOwner = owner })
end

-- Editor widgets come from pools and go back on every rebuild.
local function Pool(kind, make)
    local pool = UI.pools[kind]
    if not pool then
        pool = { free = {}, used = {} }
        UI.pools[kind] = pool
    end
    local w = table.remove(pool.free)
    if not w then w = make() end
    pool.used[#pool.used + 1] = w
    w:ClearAllPoints()
    w:Show()
    return w
end

local function ReleaseAll()
    for _, pool in pairs(UI.pools) do
        for i = #pool.used, 1, -1 do
            local w = pool.used[i]
            w:Hide()
            if w.Reset then w:Reset() end
            pool.free[#pool.free + 1] = w
            pool.used[i] = nil
        end
    end
end

local function EditText()
    return Pool("text", function()
        local fs = Text(UI.content, "GameFontHighlightSmall")
        fs.Reset = function(self) self:SetText("") self:SetTextColor(1, 1, 1, 1) self:SetWidth(0) end
        return fs
    end)
end

local function EditButton(label, width, onClick)
    local btn = Pool("button", function()
        local b = ns.CreateModernButton(UI.content, "", 100, 22)
        b.Reset = function(self) self:SetScript("OnClick", nil) end
        return b
    end)
    btn:SetSize(width, 22)
    btn._label:SetText(label)
    btn:SetScript("OnClick", onClick)
    return btn
end

local function EditCheck(label, checked, onClick)
    local cb = Pool("check", function()
        local c = CreateFrame("CheckButton", nil, UI.content, "UICheckButtonTemplate")
        c:SetSize(22, 22)
        c.label = Text(c, "GameFontHighlightSmall")
        c.label:SetPoint("LEFT", c, "RIGHT", 2, 0)
        c.Reset = function(self) self:SetScript("OnClick", nil) self.label:SetText("") end
        return c
    end)
    cb.label:SetText(label)
    cb:SetChecked(checked and true or false)
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    return cb
end

local function EditInput(width, value, hint, onCommit, numeric)
    local box = Pool("input", function()
        local b = CreateFrame("EditBox", nil, UI.content, "InputBoxTemplate")
        b:SetAutoFocus(false)
        b:SetHeight(20)
        ns.RegisterAddonFont(b)
        b.hint = Text(b, "GameFontDisableSmall")
        b.hint:SetPoint("LEFT", b, "LEFT", 2, 0)
        b:SetScript("OnEscapePressed", b.ClearFocus)
        b:SetScript("OnEnterPressed", b.ClearFocus)
        b:SetScript("OnTextChanged", function(self) self.hint:SetShown((self:GetText() or "") == "") end)
        b:SetScript("OnEditFocusLost", function(self) if self.commit then self.commit(self:GetText() or "") end end)
        b.Reset = function(self) self.commit = nil self:SetNumeric(false) self:SetText("") end
        return b
    end)
    box.commit = nil
    box:SetNumeric(numeric and true or false)
    box:SetWidth(width)
    box:SetText(value ~= nil and tostring(value) or "")
    box.hint:SetText(hint or "")
    box.hint:SetShown((box:GetText() or "") == "")
    box.commit = onCommit
    return box
end

-- Laying out the editor top down.
local cursor = { y = 0 }

local function Place(widget, x, h)
    widget:SetPoint("TOPLEFT", UI.content, "TOPLEFT", x, -cursor.y)
    return h
end

local function Heading(text)
    local fs = Pool("heading", function()
        local h = Text(UI.content, "GameFontNormal")
        return h
    end)
    fs:SetText(text)
    cursor.y = cursor.y + 8
    Place(fs, 0)
    cursor.y = cursor.y + 18
end

local function Label(text)
    local fs = EditText()
    fs:SetText(text)
    fs:SetWidth(LABEL_W)
    fs:SetPoint("TOPLEFT", UI.content, "TOPLEFT", 4, -(cursor.y + 4))
    return fs
end

-- Relative time since a ring.
local function Ago(t)
    local s = time() - t
    if s < 60 then return L["ALERTS_JUST_NOW"] end
    if s < 3600 then return sformat(L["ALERTS_MIN_AGO_FMT"], mfloor(s / 60)) end
    if s < 86400 then return sformat(L["ALERTS_HOURS_AGO_FMT"], mfloor(s / 3600)) end
    return sformat(L["ALERTS_DAYS_AGO_FMT"], mfloor(s / 86400))
end

-- Things to pick from

local function BagItems()
    local seen, out = {}, {}
    local C_Container = C_Container
    if not (C_Container and C_Container.GetContainerNumSlots) then return out end
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and info.itemID
            if id and not seen[id] then
                seen[id] = true
                local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
                if name then out[#out + 1] = { id = id, name = name } end
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function PlayerBuffs()
    local out, seen = {}, {}
    local get = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not get then return out end
    for i = 1, 80 do
        local aura = get("player", i, "HELPFUL")
        if not aura then break end
        local name = aura.name
        if T.Plain(name) and not seen[name] then
            seen[name] = true
            out[#out + 1] = { name = name, id = T.Plain(aura.spellId) and aura.spellId or nil }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- A typed spell or item: an item link or id, an item in the bags, a spell.
local function Resolve(text, want)
    text = strtrim(text or "")
    if text == "" then return nil end
    if want == "aura" then return { aura = text, label = text } end
    local itemID = tonumber(smatch(text, "|Hitem:(%d+)"))
    local spellID = tonumber(smatch(text, "|Hspell:(%d+)"))
    local plain = smatch(text, "|h%[(.-)%]|h") or text
    if not (itemID or spellID) then
        local n = tonumber(plain)
        for _, it in ipairs(BagItems()) do
            if it.name:lower() == plain:lower() then itemID = it.id break end
        end
        if not itemID and C_Item.GetItemInfoInstant then itemID = C_Item.GetItemInfoInstant(n or plain) end
        if not itemID and want == "spellOrItem" and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(n or plain)
            spellID = info and info.spellID
        end
    end
    if itemID and want ~= "spell" then
        return { item = itemID, label = C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID) or plain }
    end
    if spellID and want == "spellOrItem" then
        return { spell = spellID, label = C_Spell.GetSpellName and C_Spell.GetSpellName(spellID) or plain }
    end
end

-- The editor

local Rebuild

local function SetWhat(tr, found)
    tr.spell, tr.item, tr.aura, tr.label = nil, nil, nil, nil
    if found then
        for k, v in pairs(found) do tr[k] = v end
    end
end

local function KindMenuRows()
    local rows = {}
    for _, g in ipairs(T.GROUPS) do
        local sub = {}
        for _, kind in ipairs(T.ORDER) do
            local def = T.KINDS[kind]
            if def.group == g.key then
                sub[#sub + 1] = { text = def.label, onClick = function()
                    UI.draft.trigger = T.Fresh(kind)
                    Rebuild()
                end }
            end
        end
        rows[#rows + 1] = { text = g.label, submenu = sub }
    end
    return rows
end

local function WhatField(f)
    local tr = UI.draft.trigger
    local box = EditInput(170, tr.label or tr.aura, f.type == "aura" and L["ALERTS_HINT_AURA"] or L["ALERTS_HINT_WHAT"], function(text)
        if (text or "") == (tr.label or tr.aura or "") then return end
        SetWhat(tr, Resolve(text, f.type))
        UI.whatMissed = strtrim(text or "") ~= "" and not (tr.spell or tr.item or tr.aura)
        Rebuild()
    end)
    Place(box, LABEL_W + 8)
    local pick = EditButton(L["ALERTS_PICK"], 64, function(self)
        local rows = {}
        if f.type == "aura" then
            for _, b in ipairs(PlayerBuffs()) do
                rows[#rows + 1] = { text = b.name, onClick = function()
                    SetWhat(tr, { aura = b.name, spell = b.id, label = b.name })
                    Rebuild()
                end }
            end
        else
            for _, it in ipairs(BagItems()) do
                rows[#rows + 1] = { text = it.name, onClick = function()
                    SetWhat(tr, { item = it.id, label = it.name })
                    Rebuild()
                end }
            end
        end
        if #rows == 0 then rows[1] = { text = L["ALERTS_PICK_NONE"], disabled = true } end
        ShowMenu(self, rows)
    end)
    pick:SetPoint("LEFT", box, "RIGHT", 6, 0)
    local status = EditText()
    status:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -3)
    if UI.whatMissed then
        status:SetText(L["ALERTS_NOT_FOUND"])
        status:SetTextColor(1, 0.35, 0.3, 1)
    elseif tr.item then
        status:SetText(sformat(L["ALERTS_IS_ITEM_FMT"], tr.label or tostring(tr.item)))
    elseif tr.spell and f.type ~= "aura" then
        status:SetText(sformat(L["ALERTS_IS_SPELL_FMT"], tr.label or tostring(tr.spell)))
    end
    return 40
end

-- A pick-one choice: radio rows, the current one ticked.
local function Radio(owner, options, get, set)
    local defs = {}
    for _, o in ipairs(options) do
        defs[#defs + 1] = { kind = "radio", label = o.label, value = o.value, get = get,
            set = function(v) set(v) Rebuild() end }
    end
    ns.ShowTogglePopup("EasyFindAlertsPick", owner, defs, {})
end

local function ChoiceLabel(options, value)
    for _, o in ipairs(options) do
        if o.value == value then return o.label end
    end
    return options[1] and options[1].label or ""
end

local function FieldRow(f)
    local tr = UI.draft.trigger
    local t = f.type
    if t == "bool" then
        local cb = EditCheck(f.label, tr[f.key], function(v) tr[f.key] = v end)
        Place(cb, LABEL_W + 4)
        return 24
    end
    if t == "spellOrItem" or t == "item" or t == "aura" then
        Label(t == "aura" and L["ALERTS_FIELD_BUFF"] or L["ALERTS_FIELD_WHAT"])
        return WhatField(f)
    end
    if t == "number" then
        Label(L["ALERTS_FIELD_" .. f.key:upper()] or f.key)
        local box = EditInput(56, tr[f.key] or f.default, nil, function(text)
            local n = tonumber(text)
            if n then tr[f.key] = mmax(f.min or 0, math.min(f.max or n, mfloor(n))) end
        end, true)
        Place(box, LABEL_W + 8)
        if f.unit then
            local u = EditText()
            u:SetText(f.unit)
            u:SetPoint("LEFT", box, "RIGHT", 6, 0)
        end
        return 26
    end
    if t == "text" then
        Label(L["ALERTS_FIELD_" .. f.key:upper()] or f.key)
        local box = EditInput(W - LABEL_W - 2 * PAD - 30, tr[f.key], f.hint, function(text) tr[f.key] = strtrim(text) end)
        Place(box, LABEL_W + 8)
        return 26
    end
    if t == "choice" then
        Label(L["ALERTS_FIELD_" .. f.key:upper()] or f.key)
        local btn = EditButton(ChoiceLabel(f.options, tr[f.key]), 150, function(self)
            Radio(self, f.options, function() return tr[f.key] end, function(v) tr[f.key] = v end)
        end)
        Place(btn, LABEL_W + 8)
        return 26
    end
    if t == "multi" then
        tr[f.key] = tr[f.key] or {}
        local set = tr[f.key]
        local h = 0
        for i, o in ipairs(f.options) do
            local col, row = (i - 1) % 2, mfloor((i - 1) / 2)
            local cb = EditCheck(o.label, set[o.value], function(v) set[o.value] = v or nil end)
            cb:SetPoint("TOPLEFT", UI.content, "TOPLEFT", LABEL_W + 4 + col * 130, -(cursor.y + row * 24))
            h = (row + 1) * 24
        end
        return h
    end
    return 0
end

local function CondValue(cond, def)
    local f = def.field
    if not f then return nil end
    if f.type == "choice" then
        return EditButton(ChoiceLabel(f.options, cond.value), 120, function(self)
            Radio(self, f.options, function() return cond.value end, function(v) cond.value = v end)
        end)
    end
    if f.type == "text" then
        return EditInput(120, cond.value, f.hint, function(text) cond.value = strtrim(text) end)
    end
    if f.type == "character" or f.type == "class" then
        return EditButton(C.Text({ kind = cond.kind, value = cond.value }), 120, function(self)
            local options = {}
            if f.type == "character" then
                local keys = { [ns.CurrentCharacterKey()] = true }
                for key in pairs(Store:Chars()) do keys[key] = true end
                for key in pairs(keys) do options[#options + 1] = { value = key, label = T.CharName(key) } end
            else
                for file, name in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
                    options[#options + 1] = { value = file, label = name }
                end
            end
            table.sort(options, function(a, b) return a.label < b.label end)
            Radio(self, options, function() return cond.value end, function(v) cond.value = v end)
        end)
    end
end

local function ConditionRows()
    local conds = UI.draft.conds
    for i, cond in ipairs(conds) do
        local def = C.KINDS[cond.kind]
        if def then
            local isBtn = EditButton(cond.neg and L["ALERTS_IS_NOT"] or L["ALERTS_IS"], 56, function()
                cond.neg = not cond.neg or nil
                Rebuild()
            end)
            Place(isBtn, 0)
            local name = EditText()
            name:SetText(def.label)
            name:SetWidth(108)
            name:SetPoint("LEFT", isBtn, "RIGHT", 6, 0)
            local value = CondValue(cond, def)
            if value then value:SetPoint("LEFT", name, "RIGHT", 4, 0) end
            local x = ns.CreateCloseX and Pool("x", function()
                local b = ns.CreateCloseX(UI.content, 14)
                b.Reset = function(self) self:SetScript("OnClick", nil) end
                return b
            end)
            if x then
                x:SetPoint("TOPRIGHT", UI.content, "TOPRIGHT", -4, -(cursor.y + 4))
                x:SetScript("OnClick", function()
                    table.remove(conds, i)
                    Rebuild()
                end)
            end
            cursor.y = cursor.y + 26
        end
    end
    local add = EditButton(L["ALERTS_ADD_CONDITION"], 140, function(self)
        local rows = {}
        for _, kind in ipairs(C.ORDER) do
            rows[#rows + 1] = { text = C.KINDS[kind].label, onClick = function()
                conds[#conds + 1] = C.Fresh(kind)
                Rebuild()
            end }
        end
        ShowMenu(self, rows)
    end)
    Place(add, 0)
    cursor.y = cursor.y + 26
end

-- "" stands for none: a radio row needs a value to tick.
local function PickSound(owner, sig)
    local options = { { value = "", label = _G["NONE"] or L["SIGNAL_SOUND_NONE"] } }
    for _, s in ipairs(ns.Signals.SOUNDS) do options[#options + 1] = { value = s.key, label = s.label } end
    Radio(owner, options, function() return sig.sound or "" end, function(v)
        sig.sound = v ~= "" and v or nil
        if sig.sound then ns.Signals.PlaySound(v) end
    end)
end

local function PickScreen(owner, sig)
    local options = { { value = "", label = L["ALERTS_SCREEN_OFF"] } }
    for _, c in ipairs(ns.Signals.COLORS) do options[#options + 1] = { value = c.key, label = c.label } end
    Radio(owner, options, function() return sig.screen or "" end, function(v)
        sig.screen = v ~= "" and v or nil
        if sig.screen then ns.Signals.FlashScreen(v) end
    end)
end

local function SignalRows()
    local d = UI.draft
    local sig = d.signals
    local checks = {
        { L["ALERTS_SIG_CHAT"], "chat" }, { L["ALERTS_SIG_BIG"], "big" }, { L["ALERTS_SIG_TASKBAR"], "taskbar" },
    }
    for i, c in ipairs(checks) do
        local cb = EditCheck(c[1], sig[c[2]], function(v) sig[c[2]] = v or nil end)
        cb:SetPoint("TOPLEFT", UI.content, "TOPLEFT", (i - 1) * 118, -cursor.y)
    end
    cursor.y = cursor.y + 26
    Label(L["ALERTS_SIG_SOUND"])
    local snd = EditButton(sig.sound and ns.Signals.SoundLabel(sig.sound) or (_G["NONE"] or L["SIGNAL_SOUND_NONE"]), 150,
        function(self) PickSound(self, sig) end)
    Place(snd, LABEL_W + 8)
    cursor.y = cursor.y + 26
    Label(L["ALERTS_SIG_SCREEN"])
    local scr = EditButton(sig.screen and ns.Signals.ColorLabel(sig.screen) or L["ALERTS_SCREEN_OFF"], 150,
        function(self) PickScreen(self, sig) end)
    Place(scr, LABEL_W + 8)
    cursor.y = cursor.y + 28
    local wait = EditCheck(L["ALERTS_WAIT_COMBAT"], d.waitCombat, function(v) d.waitCombat = v or nil end)
    Place(wait, 0)
    local once = EditCheck(L["ALERTS_ONCE"], d.once, function(v) d.once = v or nil end)
    once:SetPoint("TOPLEFT", UI.content, "TOPLEFT", 200, -cursor.y)
    cursor.y = cursor.y + 26
    Label(L["ALERTS_GAP"])
    local gap = EditInput(56, d.gap, "0", function(text) d.gap = tonumber(text) end, true)
    Place(gap, LABEL_W + 8)
    local unit = EditText()
    unit:SetText(L["ALERTS_UNIT_SEC"])
    unit:SetPoint("LEFT", gap, "RIGHT", 6, 0)
    cursor.y = cursor.y + 26
    Label(L["ALERTS_MESSAGE"])
    local msg = EditInput(W - LABEL_W - 2 * PAD - 30, d.message, L["ALERTS_HINT_MESSAGE"], function(text)
        d.message = strtrim(text) ~= "" and strtrim(text) or nil
    end)
    Place(msg, LABEL_W + 8)
    cursor.y = cursor.y + 26
end

-- A field committing as the editor tears down asks again once it is done.
function Rebuild()
    local d = UI.draft
    if not d then return end
    if UI.building then
        UI.again = true
        return
    end
    UI.building = true
    ReleaseAll()
    cursor.y = 0
    Label(L["ALERTS_NAME"])
    local name = EditInput(W - LABEL_W - 2 * PAD - 30, d.name, T.Summary(d), function(text)
        d.name = strtrim(text) ~= "" and strtrim(text) or nil
    end)
    Place(name, LABEL_W + 8)
    cursor.y = cursor.y + 26

    Heading(L["ALERTS_WHEN"])
    local def = T.KINDS[d.trigger.kind]
    local kindBtn = EditButton(def and def.label or "?", W - 2 * PAD - 30, function(self) ShowMenu(self, KindMenuRows()) end)
    Place(kindBtn, 0)
    cursor.y = cursor.y + 28
    for _, f in ipairs(def and def.fields or {}) do
        cursor.y = cursor.y + FieldRow(f)
    end

    Heading(L["ALERTS_ONLY_IF"])
    ConditionRows()

    Heading(L["ALERTS_THEN"])
    SignalRows()

    UI.content:SetHeight(cursor.y + 8)
    UI.fit()
    local missing = T.Missing(d)
    UI.error:SetText(missing or "")
    UI.save:SetEnabled(missing == nil)
    UI.delete:SetShown(Store:Find(d.id) ~= nil)
    UI.building = false
    if UI.again then
        UI.again = false
        Rebuild()
    end
end

local function ShowEditor(draft)
    UI.draft = draft
    UI.whatMissed = nil
    UI.listView:Hide()
    -- The empty list's hint and buttons hang on the window, not the list.
    UI.empty:Hide()
    UI.emptyList:Hide()
    UI.emptyOwn:Hide()
    UI.editView:Show()
    UI.win.title:SetText(Store:Find(draft.id) and L["ALERTS_EDIT"] or L["ALERTS_NEW"])
    UI.back:Show()
    UI.newBtn:Hide()
    UI.scroll:SetVerticalScroll(0)
    Rebuild()
end

local function ShowList()
    UI.draft = nil
    ReleaseAll()
    UI.editView:Hide()
    UI.listView:Show()
    UI.win.title:SetText(L["APP_ALERTS"])
    UI.back:Hide()
    UI.newBtn:Show()
    Window.Refresh()
end
Window.ShowList = ShowList
Window.Edit = ShowEditor

-- The list

local function NewMenuRows()
    local rows = {}
    for _, g in ipairs(T.GROUPS) do
        local sub = {}
        for _, entry in ipairs(Templates.LIST) do
            if entry.group == g.key then
                sub[#sub + 1] = { text = entry.label, onClick = function() ShowEditor(Templates.Draft(entry)) end }
            end
        end
        rows[#rows + 1] = { text = g.label, submenu = sub }
    end
    rows[#rows + 1] = { isSeparator = true }
    rows[#rows + 1] = { text = L["ALERTS_BUILD_OWN"], onClick = function()
        ShowEditor(Templates.Draft({ make = function() return T.Fresh("cooldown") end }))
    end }
    return rows
end
Window.NewMenuRows = NewMenuRows

local function RowMenu(row)
    local rule = row.rule
    ShowMenu(row, {
        { text = L["ALERTS_EDIT"], onClick = function() ShowEditor(Store.Copy(rule)) end },
        { text = L["ALERTS_TEST"], onClick = function() Engine.Test(rule) end },
        { text = L["ALERTS_DUPLICATE"], onClick = function()
            local copy = Store.Copy(rule)
            copy.id, copy.fired, copy.lastFired = Store.sv.nextID, nil, nil
            ShowEditor(copy)
        end },
        { text = _G["DELETE"] or L["ALERTS_DELETE"], onClick = function()
            Store:Delete(rule.id)
            Engine.Rebuild()
            Window.Refresh()
        end },
    })
end

local function CreateRow(i)
    local row = CreateFrame("Button", nil, UI.listView)
    row:SetHeight(ROW_H)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    row:GetHighlightTexture():SetAlpha(0.25)
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(24, 24)
    row.check:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.check:SetScript("OnClick", function(self)
        local rule = row.rule
        rule.on = self:GetChecked() and true or false
        Engine.Reset(rule)
        Window.Refresh()
    end)
    row.title = Text(row, "GameFontHighlight")
    row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 30, -4)
    row.title:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.title:SetWordWrap(false)
    row.sub = Text(row, "GameFontDisableSmall")
    row.sub:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.sub:SetWordWrap(false)
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            RowMenu(self)
        else
            ShowEditor(Store.Copy(self.rule))
        end
    end)
    UI.rows[i] = row
    return row
end

function Window.Refresh()
    if not (UI.win and UI.listView:IsShown()) then return end
    local rules = Store:Rules()
    for i, rule in ipairs(rules) do
        local row = UI.rows[i] or CreateRow(i)
        row.rule = rule
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", UI.listView, "TOPLEFT", 0, -(i - 1) * ROW_H)
        row:SetPoint("RIGHT", UI.listView, "RIGHT", 0, 0)
        row.check:SetChecked(rule.on)
        row.title:SetText(rule.name or T.Summary(rule))
        local parts = {}
        for _, cond in ipairs(rule.conds) do parts[#parts + 1] = C.Text(cond) end
        local missing = T.Missing(rule)
        if missing then
            parts[#parts + 1] = missing
        elseif rule.lastFired then
            parts[#parts + 1] = sformat(L["ALERTS_RANG_FMT"], Ago(rule.lastFired))
        end
        row.sub:SetText(table.concat(parts, ", "))
        row:SetAlpha(rule.on and 1 or 0.55)
        row:Show()
    end
    for i = #rules + 1, #UI.rows do UI.rows[i]:Hide() end
    local empty = #rules == 0
    UI.empty:SetShown(empty)
    UI.emptyList:SetShown(empty)
    UI.emptyOwn:SetShown(empty)
    UI.listView:SetHeight(mmax(1, #rules * ROW_H))
    UI.fit()
end

-- The window

local function SavePosition()
    local win = UI.win
    Store.sv.win = { left = win:GetLeft(), top = win:GetTop() }
end

local function EnsureWindow()
    if UI.win then return UI.win end
    local win = CreateFrame("Frame", "EasyFindAlertsWindow", UIParent, "BackdropTemplate")
    UI.win = win
    win:Hide()
    win:SetSize(W, H)
    win:SetFrameStrata("HIGH")
    win:SetClampedToScreen(true)
    win:EnableMouse(true)
    win:SetMovable(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", function(self)
        SavePosition()
        self:StopMovingOrSizing()
    end)
    ns.StyleMenuPanel(win)
    local pos = Store.sv.win
    if type(pos) == "table" and type(pos.left) == "number" and type(pos.top) == "number" then
        win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.left, pos.top)
    else
        win:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    end
    Utils.AttachEscClose(win)

    win.glyph = win:CreateTexture(nil, "ARTWORK")
    win.glyph:SetSize(16, 16)
    win.glyph:SetPoint("TOPLEFT", win, "TOPLEFT", PAD + 2, -9)
    win.glyph:SetTexture(ns.ALERTS_ICON_TEX)
    win.title = Text(win, "GameFontNormal")
    win.title:SetPoint("LEFT", win.glyph, "RIGHT", 6, 0)
    win.title:SetText(L["APP_ALERTS"])
    local close = ns.CreateCloseX(win, 16)
    close:SetPoint("TOPRIGHT", win, "TOPRIGHT", -PAD, -9)
    close:SetScript("OnClick", function() win:Hide() end)
    UI.newBtn = ns.CreateModernButton(win, L["ALERTS_NEW_BTN"], 110, 22)
    UI.newBtn:SetPoint("RIGHT", close, "LEFT", -8, 0)
    UI.newBtn:SetScript("OnClick", function(self) ShowMenu(self, NewMenuRows()) end)
    UI.back = ns.CreateModernButton(win, _G["BACK"] or L["ALERTS_BACK"], 70, 22)
    UI.back:SetPoint("RIGHT", close, "LEFT", -8, 0)
    UI.back:SetScript("OnClick", ShowList)
    UI.back:Hide()

    local scroll = CreateFrame("ScrollFrame", nil, win)
    scroll:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, -HEADER_H - 4)
    scroll:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -PAD - 10, FOOT_H)
    UI.scroll = scroll
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(W - 2 * PAD - 10, 1)
    scroll:SetScrollChild(child)
    local bar = Utils.CreateMinimalScrollBar(scroll, win)
    UI.listView = CreateFrame("Frame", nil, child)
    UI.listView:SetPoint("TOPLEFT")
    UI.listView:SetPoint("RIGHT")
    UI.editView = CreateFrame("Frame", nil, child)
    UI.editView:SetPoint("TOPLEFT")
    UI.editView:SetPoint("RIGHT")
    UI.editView:Hide()
    UI.content = UI.editView
    UI.fit = function()
        local view = UI.listView:IsShown() and UI.listView or UI.editView
        local h = view:GetHeight()
        child:SetHeight(mmax(1, h))
        local viewH = scroll:GetHeight() or 0
        if bar then
            if h > viewH + 1 then
                bar:Show()
                bar:UpdateThumb(h, viewH)
            else
                scroll:SetVerticalScroll(0)
                bar:Hide()
            end
        end
    end

    UI.empty = Text(win, "GameFontHighlight")
    UI.empty:SetPoint("TOP", win, "TOP", 0, -HEADER_H - 40)
    UI.empty:SetWidth(W - 4 * PAD)
    UI.empty:SetJustifyH("CENTER")
    UI.empty:SetText(L["ALERTS_EMPTY"])
    UI.emptyList = ns.CreateModernButton(win, L["ALERTS_FROM_LIST"], 150, 24)
    UI.emptyList:SetPoint("TOPRIGHT", UI.empty, "BOTTOM", -4, -16)
    UI.emptyList:SetScript("OnClick", function(self) ShowMenu(self, NewMenuRows()) end)
    UI.emptyOwn = ns.CreateModernButton(win, L["ALERTS_BUILD_OWN"], 150, 24)
    UI.emptyOwn:SetPoint("TOPLEFT", UI.empty, "BOTTOM", 4, -16)
    UI.emptyOwn:SetScript("OnClick", function()
        ShowEditor(Templates.Draft({ make = function() return T.Fresh("cooldown") end }))
    end)

    -- The editor's footer: what is missing, then the buttons.
    UI.error = Text(win, "GameFontHighlightSmall")
    UI.error:SetTextColor(1, 0.35, 0.3, 1)
    UI.error:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", PAD + 2, FOOT_H - 2)
    UI.save = ns.CreateModernButton(win, _G["SAVE"] or L["ALERTS_SAVE"], 80, 24)
    UI.save:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -PAD, 10)
    UI.save:SetScript("OnClick", function()
        -- A field still being typed in commits first.
        local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
        if focus and focus.commit then focus:ClearFocus() end
        local d = UI.draft
        if not d or T.Missing(d) then return end
        d.fired = nil
        Store:Replace(d)
        Engine.Reset(d)
        ShowList()
    end)
    UI.cancel = ns.CreateModernButton(win, _G["CANCEL"] or L["ALERTS_CANCEL"], 80, 24)
    UI.cancel:SetPoint("RIGHT", UI.save, "LEFT", -6, 0)
    UI.cancel:SetScript("OnClick", ShowList)
    UI.test = ns.CreateModernButton(win, L["ALERTS_TEST"], 70, 24)
    UI.test:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", PAD, 10)
    UI.test:SetScript("OnClick", function() if UI.draft then Engine.Test(UI.draft) end end)
    UI.delete = ns.CreateModernButton(win, _G["DELETE"] or L["ALERTS_DELETE"], 70, 24)
    UI.delete:SetPoint("LEFT", UI.test, "RIGHT", 6, 0)
    UI.delete:SetScript("OnClick", function()
        if UI.draft then
            Store:Delete(UI.draft.id)
            Engine.Rebuild()
        end
        ShowList()
    end)
    UI.editView:HookScript("OnShow", function()
        for _, w in ipairs({ UI.error, UI.save, UI.cancel, UI.test }) do w:Show() end
    end)
    UI.editView:HookScript("OnHide", function()
        for _, w in ipairs({ UI.error, UI.save, UI.cancel, UI.test, UI.delete }) do w:Hide() end
    end)
    for _, w in ipairs({ UI.error, UI.save, UI.cancel, UI.test, UI.delete }) do w:Hide() end
    win:HookScript("OnHide", function()
        if UI.menu then UI.menu:Hide() end
    end)
    return win
end

function Window.Show()
    EnsureWindow()
    UI.win:Show()
    if not UI.draft then ShowList() end
end

function Window.Hide()
    if UI.win then UI.win:Hide() end
end

function Window.IsShown()
    return UI.win ~= nil and UI.win:IsShown()
end

-- A rule rang: its "rang ... ago" line moves.
function AL.OnRang()
    if Window.IsShown() and not UI.draft then Window.Refresh() end
end

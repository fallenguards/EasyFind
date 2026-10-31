local _, notesNS = ...
local ns = EasyFind and EasyFind._ns
if not (ns and notesNS.Checklist and notesNS.UI and notesNS.Windows) then return end

-- A note's checkbox lines in its editor: the box ticks on the list (by
-- hand, or as the game answers), a ticked line reads struck and green, a
-- counted or tracked line wears its count at the right with an X to drop
-- it, and the note's menu holds what the line kinds and the ticks need.
local Lines = {}
notesNS.Lines = Lines

local CK = notesNS.Checklist
local NotesUI = notesNS.UI
local W = notesNS.Windows
local Utils = ns.Utils
local L = ns.L
-- Frames made here belong to the notes window in use (their scripts run as it).
local CreateFrame, time = W.CreateFrame, time
local sformat, mmax, mfloor, tonumber, tostring = string.format, math.max, math.floor, tonumber, tostring
local ipairs, smatch, strtrim = ipairs, string.match, strtrim
local IsControlKeyDown = IsControlKeyDown

local BOX_GLYPH, TICKED_GLYPH = CK.EMPTY:sub(1, 3), CK.FILLED:sub(1, 3)
local CELL_W, NAME_W, ROW_H = 56, 150, 22
local READY_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"
local MENU_CHECK_TEX = "Interface\\Buttons\\UI-CheckBox-Check"
local DONE_DARK, DONE_LIGHT = { 0.45, 0.85, 0.45 }, { 0.12, 0.50, 0.18 }

-- Frames and marks in one table, a set per notes window; reads go to the
-- set of the window in use.
Lines.States = setmetatable({}, { __mode = "k" })
local function S()
    local w = W.active
    local s = Lines.States[w]
    if not s then
        s = { tails = {}, cells = {}, heads = {}, rows = {} }
        Lines.States[w] = s
    end
    return s
end

local function Note() return notesNS.SelectedNote and notesNS.SelectedNote() end
local function Frame() return NotesUI._notes and NotesUI._notes.frame end
local function Theme() return ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme() end
local function DoneColor()
    local theme = Theme()
    return (theme and theme.lightTheme) and DONE_LIGHT or DONE_DARK
end
local function OpenColor()
    local theme = Theme()
    if theme and theme.lightTheme and theme.leafColor then return theme.leafColor end
    return { 1, 1, 1 }
end

-- Every window on the note draws it again from its body.
function Lines.Reload(note)
    local w = W.ShowingNote(note.id)
    if w then W.Run(w, function() NotesUI:RefreshEasyNotes() end) end
    notesNS.Refresh()
end

local function Repaint(note)
    local w = W.ShowingNote(note.id)
    if w then W.Run(w, function() NotesUI:QueueEasyNotesOverlayUpdate() end) end
end

-- The player changed the note's lines: a linked one's extension hears of
-- it, a beat after the last change.
local told = {}
local function Told(note)
    if not (note.list and note.list.source) or told[note.id] then return end
    told[note.id] = true
    Utils.SafeAfter(0.5, function()
        told[note.id] = nil
        if notesNS.LinkedChanged then notesNS.LinkedChanged(note) end
    end)
end

-- The body changed under the lines: they follow at once; the words settle
-- (a name looked up as an item) a beat after the typing stops.
local settling = {}
function Lines.BodyChanged(note)
    if not note then return end
    local changed = CK.Reconcile(note)
    if changed then Told(note) end
    if CK.ItemsList(note) and not settling[note.id] then
        settling[note.id] = true
        Utils.SafeAfter(0.7, function()
            settling[note.id] = nil
            if CK.Reconcile(note, true) then
                Told(note)
                Repaint(note)
            end
        end)
    end
end

-- A note coming up in a window: its lines in step, its ticks cleared as
-- its schedule says, a linked list pulled from its extension once.
function Lines.NoteLoaded(note)
    if not note then return end
    CK.Migrate(note, ns.CurrentCharacterKey())
    CK.Reconcile(note, true)
    if not CK.Is(note) then return end
    if CK.ApplyReset(note, time()) then note.updated = time() end
    local s = S()
    if note.list.source and s.pulled ~= note.id and notesNS.LinkedShown then
        s.pulled = note.id
        Utils.SafeAfter(0, function() notesNS.LinkedShown(note) end)
    end
end

-- Ticks

local function Editing(editor)
    local frame = Frame()
    return frame ~= nil and editor == frame.editor
end

-- Whether the box starting at startByte in editor's text is ticked, and its line.
function Lines.TickedAt(editor, startByte)
    if not Editing(editor) then return nil end
    local note = Note()
    local line = note and CK.LineAt(note, startByte)
    if not line then return nil end
    return (CK.LineState(note, line)) and true or false, line
end

-- A press on a box: a hand line's tick flips for whoever keeps them; a
-- line the game ticks stays as the game says.
function Lines.ToggleAt(note, startByte)
    local line = CK.LineAt(note, startByte)
    if not line then
        CK.Reconcile(note)
        line = CK.LineAt(note, startByte)
    end
    if not line or line.link then return false end
    local char = ns.CurrentCharacterKey()
    CK.SetTicked(note, line, char, not CK.Ticked(note, line, char))
    Repaint(note)
    notesNS.Refresh()
    return true
end

-- The decorations with a ticked line's strike and green over its words.
function Lines.WithTicks(editor, text, decos)
    if not Editing(editor) then return decos end
    local note = Note()
    if not (note and CK.Is(note)) then return decos end
    local out = {}
    for i = 1, #decos do out[i] = decos[i] end
    local c = DoneColor()
    for _, f in ipairs(CK.BodyLines(text)) do
        local line = CK.LineAt(note, f.start)
        if line and f.lineEnd >= f.contentStart and CK.LineState(note, line) then
            out[#out + 1] = { kind = "strike", startByte = f.contentStart, endByte = f.lineEnd + 1 }
            out[#out + 1] = { kind = "color", startByte = f.contentStart, endByte = f.lineEnd + 1, r = c[1], g = c[2], b = c[3] }
        end
    end
    return out
end

-- Tails: the count at a line's right, and its X

local function Layer(editor)
    local s = S()
    if s.layer and s.layerOf == editor then return s.layer end
    local scroll = editor:GetParent()
    local layer = CreateFrame("Frame", nil, scroll:GetParent())
    layer:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    layer:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 0, 0)
    layer:SetClipsChildren(true)
    layer:SetFrameLevel(editor:GetFrameLevel() + 5)
    layer:EnableMouse(false)
    layer:SetShown(scroll:IsShown())
    scroll:HookScript("OnShow", function() layer:Show() end)
    scroll:HookScript("OnHide", function() layer:Hide() end)
    s.layer, s.layerOf = layer, editor
    return layer
end

-- The house: retail's frame, or the classic one.
local function AuctionOpen()
    local ah = _G["AuctionHouseFrame"] or _G["AuctionFrame"]
    return ah ~= nil and ah:IsShown()
end

-- The line searched at the auction house: by the extension its list is
-- linked to when that searches (the list's own term), else the item's
-- name in the house's own bar (retail's, or the classic browse box).
local function SearchAH(note, line)
    if notesNS.LinkedSearch and notesNS.LinkedSearch(note, line) then
        S().lastSearched = line.id
        return
    end
    local name = line.item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(line.item)
    if not name then return end
    local ah, classic = _G["AuctionHouseFrame"], _G["AuctionFrame"]
    local bar = ah and ah:IsShown() and ah.SearchBar
    if bar and bar.SetSearchText and bar.StartSearch then
        bar:SetSearchText(name)
        bar:StartSearch()
    elseif classic and classic:IsShown() and _G["BrowseName"] and _G["AuctionFrameBrowse_Search"] then
        _G["BrowseName"]:SetText(name)
        _G["AuctionFrameBrowse_Search"]()
    else
        return
    end
    S().lastSearched = line.id
end

-- The next item line still short of its target, after the last searched.
local function SearchNext(note)
    local lines, start = note.list.lines, 1
    for i, line in ipairs(lines) do
        if line.id == S().lastSearched then start = i + 1 break end
    end
    for n = 0, #lines - 1 do
        local line = lines[(start - 1 + n) % #lines + 1]
        if line.link == "item" and not CK.LineState(note, line) then
            SearchAH(note, line)
            return
        end
    end
end

-- The icon of the item or spell a line names.
local function ItemIcon(line)
    local kind, id = line.item and "item", line.item
    if not kind and line.link == "cooldown" then kind, id = "spell", line.spell end
    if kind == "item" then return C_Item.GetItemIconByID and C_Item.GetItemIconByID(id) end
    if kind == "spell" then return C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id) end
end

-- The body's line for line id, its words replaced; decorations past it
-- move along, any inside its words go.
local function ReplaceWords(note, line, words)
    local start = CK.LineStart(note, line.id)
    if not start then return false end
    local body = note.body or ""
    local contentStart = start + #CK.EMPTY
    local nl = body:find("\n", contentStart, true)
    local lineEnd = nl and nl - 1 or #body
    local delta = #words - (lineEnd - contentStart + 1)
    note.body = body:sub(1, contentStart - 1) .. words .. body:sub(lineEnd + 1)
    local decos = note.decorations or {}
    for i = #decos, 1, -1 do
        local d = decos[i]
        if d.kind ~= "line" and d.startByte >= contentStart and d.startByte <= lineEnd + 1 then
            table.remove(decos, i)
        else
            if d.startByte > lineEnd then d.startByte = d.startByte + delta end
            if d.endByte > lineEnd + 1 then d.endByte = d.endByte + delta end
        end
    end
    note.updated = time()
    CK.Reconcile(note)
    return true
end

local function Changed(note)
    Told(note)
    Lines.Reload(note)
    W.ListFollows()
end

-- The line's own count or target changed: its words say so.
local function SetCount(note, line, n)
    CK.SetCount(line, n)
    ReplaceWords(note, line, CK.EditText(line))
    Changed(note)
end

-- Line id dropped from the note, its line of text with it.
function Lines.Remove(note, line)
    local start = CK.LineStart(note, line.id)
    if not start then return end
    local body = note.body or ""
    local nl = body:find("\n", start, true)
    local cutEnd = nl or #body
    local cutStart = start
    if not nl and start > 1 then cutStart = start - 1 end
    local len = cutEnd - cutStart + 1
    note.body = body:sub(1, cutStart - 1) .. body:sub(cutEnd + 1)
    local decos = note.decorations or {}
    for i = #decos, 1, -1 do
        local d = decos[i]
        if d.startByte >= cutStart and d.startByte <= cutEnd then
            table.remove(decos, i)
        else
            if d.startByte > cutEnd then d.startByte = d.startByte - len end
            if d.endByte > cutEnd then d.endByte = d.endByte - len end
        end
    end
    note.updated = time()
    CK.Reconcile(note)
    Changed(note)
end

-- A line under the note's last: the fields given, or words as typed.
function Lines.Add(note, line)
    local made = CK.AppendLine(note, line)
    Changed(note)
    return made
end

function Lines.AddWords(note, words)
    local last = CK.Is(note) and note.list.lines[#note.list.lines]
    -- An empty line waiting at the end takes the words.
    if last and not (last.item or last.link or (last.text or "") ~= "") then
        ReplaceWords(note, last, words)
        Changed(note)
        return last
    end
    return Lines.Add(note, { text = words })
end

local function Ask(text, default, onAccept, numeric)
    ns.ShowThemedDialog({
        text = text, hasEditBox = true, editBoxDefault = default and tostring(default) or "", maxLetters = 60,
        acceptText = _G["OKAY"] or "Okay", cancelText = _G["CANCEL"] or "Cancel",
        onAccept = function(value)
            value = strtrim(value or "")
            if numeric then
                local n = tonumber(value)
                if n then onAccept(n) end
            elseif value ~= "" then
                onAccept(value)
            end
        end,
    })
end

local TARGET_ASK = { item = "CHECK_TARGET_ITEM_ASK", gold = "CHECK_GOLD_ASK", level = "CHECK_LEVEL_ASK", skill = "CHECK_TARGET_SKILL_ASK" }

-- A line's menu: its auction search, its target, its standing, its end.
local function LineMenu(tail)
    local note, line = Note(), tail.line
    if not (note and line) then return end
    local rows = {}
    if AuctionOpen() and (line.link == "item" or (note.list.source and (line.text or "") ~= "")) then
        rows[#rows + 1] = { text = L["CHECK_SEARCH_AH"], onClick = function() SearchAH(note, line) end }
    end
    local counts = line.link or (line.item and "item")
    if TARGET_ASK[counts] then
        rows[#rows + 1] = { text = L["CHECK_SET_TARGET"], onClick = function()
            local cur = counts == "gold" and mfloor((line.target or 0) / 10000) or line.target
            Ask(L[TARGET_ASK[counts]], cur, function(n)
                if counts == "item" then
                    SetCount(note, line, mmax(1, mfloor(n)))
                else
                    line.link = counts
                    line.target = counts == "gold" and mfloor(n * 10000) or mmax(1, mfloor(n))
                    Changed(note)
                end
            end, true)
        end }
    end
    if line.link == "rep" then
        local sub = {}
        for standing = 4, 8 do
            sub[#sub + 1] = { text = CK.StandingLabel(standing), onClick = function() line.standing = standing Changed(note) end }
        end
        rows[#rows + 1] = { text = L["CHECK_SET_STANDING"], submenu = sub }
    end
    if #rows > 0 then rows[#rows + 1] = { isSeparator = true } end
    rows[#rows + 1] = { text = _G["REMOVE"] or L["CHECK_REMOVE"], onClick = function() Lines.Remove(note, line) end }
    NotesUI:ShowEasyNotesMenu("EasyNotesLineMenu", rows, { toggleOwner = tail })
end

-- The count typed over itself: Enter or a click away keeps it, emptied or
-- 0 the line has none, Escape leaves it.
local function CountBox()
    local s = S()
    if s.countBox then return s.countBox end
    local box = CreateFrame("EditBox", nil, Frame())
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlightSmall")
    ns.RegisterAddonFont(box)
    box:SetNumeric(true)
    box:SetMaxLetters(6)
    box:SetJustifyH("RIGHT")
    box:SetSize(44, 16)
    box:SetFrameLevel(Frame():GetFrameLevel() + 12)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self)
        self.cancel = true
        self:ClearFocus()
    end)
    box:SetScript("OnEditFocusLost", function(self)
        self:Hide()
        local note, line = Note(), self.line
        self.line = nil
        if self.cancel or not (note and line) then return end
        SetCount(note, line, tonumber(self:GetText() or ""))
    end)
    Utils.ReleaseFocusOnOutsideClick(box)
    box:Hide()
    s.countBox = box
    return box
end

local function EditCount(tail)
    local line = tail.line
    if not (line and CK.HasCount(line)) then return end
    local box = CountBox()
    box.line, box.cancel = line, false
    box:ClearAllPoints()
    box:SetPoint("RIGHT", tail.text, "RIGHT", 0, 0)
    box:SetText(tostring(line.target))
    box:Show()
    box:SetFocus()
    box:HighlightText()
end

local function Tail(layer, i)
    local s = S()
    local tail = s.tails[i]
    if tail then return tail end
    tail = CreateFrame("Button", nil, layer)
    tail:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    tail.x = ns.CreateCloseX(tail, 10)
    tail.x:SetPoint("RIGHT", tail, "RIGHT", -1, 0)
    tail.x:SetScript("OnClick", function()
        local note = Note()
        if note and tail.line then Lines.Remove(note, tail.line) end
    end)
    tail.x:Hide()
    tail.text = tail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.RegisterAddonFont(tail.text)
    tail.text:SetJustifyH("RIGHT")
    tail.text:SetWordWrap(false)
    tail.text:SetPoint("RIGHT", tail, "RIGHT", -14, 0)
    tail.icon = tail:CreateTexture(nil, "ARTWORK")
    tail.icon:SetSize(14, 14)
    tail.icon:SetPoint("RIGHT", tail.text, "LEFT", -3, 0)
    tail:SetScript("OnEnter", function(self)
        self.x:Show()
        local line = self.line
        local tip = line and line.detail
        if line and line.link then tip = tip and (tip .. "\n" .. L["CHECK_AUTO_TT"]) or L["CHECK_AUTO_TT"] end
        if line and CK.HasCount(line) then tip = tip and (tip .. "\n" .. L["CHECK_COUNT_TT"]) or L["CHECK_COUNT_TT"] end
        if tip then NotesUI:ShowNotesTipDelayed(self, "ANCHOR_LEFT", tip) end
    end)
    tail:SetScript("OnLeave", function(self)
        if not self.x:IsMouseOver() then self.x:Hide() end
        NotesUI:HideNotesTip(self)
    end)
    tail.x:HookScript("OnLeave", function() if not tail:IsMouseOver() then tail.x:Hide() end end)
    -- A click opens the line's menu; Ctrl+click searches it at an open
    -- auction house; a double-click types a new count over the count.
    tail:SetScript("OnClick", function(self, button)
        local note = Note()
        if not (note and self.line) then return end
        if button == "LeftButton" and IsControlKeyDown() then
            if AuctionOpen() then SearchAH(note, self.line) end
            return
        end
        LineMenu(self)
    end)
    tail:SetScript("OnDoubleClick", function(self) EditCount(self) end)
    s.tails[i] = tail
    return tail
end

-- A tail on every box line's first row: its count and icon when it has
-- them, the X under the cursor. positions nil: none.
function Lines.PlaceTails(editor, positions, lineYs, lineH)
    if not Editing(editor) then return end
    local s = S()
    local note = Note()
    if not (positions and note and CK.Is(note)) then
        for _, tail in ipairs(s.tails) do tail:Hide() end
        return
    end
    local layer = Layer(editor)
    local done, open = DoneColor(), OpenColor()
    local used = 0
    for k = 1, #positions do
        local p = positions[k]
        if p.isPrefix and (p.glyph == BOX_GLYPH or p.glyph == TICKED_GLYPH) then
            local line = CK.LineAt(note, p.byteStart)
            if line then
                used = used + 1
                local tail = Tail(layer, used)
                tail.line = line
                local isDone, progress, detail = CK.LineState(note, line)
                line.detail = (detail and detail ~= "") and detail or nil
                local icon = (line.link or line.item) and ItemIcon(line)
                tail.icon:SetShown(icon ~= nil)
                if icon then tail.icon:SetTexture(icon) end
                tail.text:SetText(progress or "")
                local c = isDone and done or open
                tail.text:SetTextColor(c[1], c[2], c[3], 1)
                local w = 16 + (progress and progress ~= "" and (tail.text:GetStringWidth() + 2) or 0) + (icon and 18 or 0)
                tail:SetSize(mmax(22, w), lineH)
                tail:ClearAllPoints()
                tail:SetPoint("TOPRIGHT", editor, "TOPRIGHT", 0, -(lineYs[p.line] or 0))
                tail:Show()
            end
        end
    end
    for i = used + 1, #s.tails do s.tails[i]:Hide() end
end

-- Tracking: lines the game ticks

local function QuestRows(note)
    local rows = {}
    local QL = C_QuestLog
    for i = 1, (QL and QL.GetNumQuestLogEntries and QL.GetNumQuestLogEntries()) or 0 do
        local info = QL.GetInfo(i)
        if info and not info.isHeader and info.questID then
            rows[#rows + 1] = { text = info.title, onClick = function() Lines.Add(note, { link = "quest", quest = info.questID }) end }
        end
    end
    return rows
end

local function FactionRows(note)
    local rows = {}
    for i = 1, ns.Caps.NumFactions() do
        local data = ns.Caps.FactionAt(i)
        if data and not data.isHeader and data.factionID and data.factionID > 0 then
            rows[#rows + 1] = { text = data.name, onClick = function() Lines.Add(note, { link = "rep", faction = data.factionID, standing = 8 }) end }
        end
    end
    return rows
end

local function SkillRows(note)
    local rows = {}
    for _, prof in ipairs({ GetProfessions and GetProfessions() }) do
        if prof then
            local name, _, _, maxLevel = GetProfessionInfo(prof)
            if name then
                rows[#rows + 1] = { text = name, onClick = function() Lines.Add(note, { link = "skill", skill = name, target = maxLevel or 1 }) end }
            end
        end
    end
    return rows
end

local function LockoutRows(note)
    local rows, seen = {}, {}
    for i = 1, (GetNumSavedInstances and GetNumSavedInstances()) or 0 do
        local name = GetSavedInstanceInfo(i)
        if name and not seen[name] then
            seen[name] = true
            rows[#rows + 1] = { text = name, onClick = function() Lines.Add(note, { link = "lockout", instance = name }) end }
        end
    end
    rows[#rows + 1] = { text = L["CHECK_TYPE_NAME"], onClick = function()
        Ask(L["CHECK_LOCKOUT_ASK"], "", function(v) Lines.Add(note, { link = "lockout", instance = v }) end)
    end }
    return rows
end

local function BagItemRows(note)
    local rows, seen = {}, {}
    local C_Container = C_Container
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, (C_Container and C_Container.GetContainerNumSlots(bag)) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and info.itemID
            if id and not seen[id] then
                seen[id] = true
                local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
                if name then rows[#rows + 1] = { text = name, onClick = function() Lines.Add(note, { link = "item", item = id, target = 1 }) end } end
            end
        end
    end
    table.sort(rows, function(a, b) return a.text < b.text end)
    return rows
end

local function Empty(rows)
    if #rows == 0 then rows[1] = { text = L["CHECK_NOTHING_HERE"], disabled = true } end
    return rows
end

-- What a new line can follow; the bags, quest log and factions run long:
-- a search, and a scroll past 14.
function Lines.TrackRows(note)
    local find, cap = L["SEARCH_PLACEHOLDER"], 14
    return {
        { text = L["CHECK_LINK_ITEM"], submenu = Empty(BagItemRows(note)), tooltip = L["CHECK_SHIFT_CLICK_TT"],
          submenuSearch = find, submenuMaxRows = cap },
        { text = L["CHECK_LINK_QUEST"], submenu = Empty(QuestRows(note)), submenuSearch = find, submenuMaxRows = cap },
        { text = L["CHECK_LINK_REP"], submenu = Empty(FactionRows(note)), submenuSearch = find, submenuMaxRows = cap },
        { text = L["CHECK_LINK_GOLD"], onClick = function()
            Ask(L["CHECK_GOLD_ASK"], 100, function(n) Lines.Add(note, { link = "gold", target = mfloor(n * 10000) }) end, true)
        end },
        { text = L["CHECK_LINK_LEVEL"], onClick = function()
            Ask(L["CHECK_LEVEL_ASK"], (UnitLevel("player") or 1) + 1, function(n) Lines.Add(note, { link = "level", target = mfloor(n) }) end, true)
        end },
        { text = L["CHECK_LINK_SKILL"], submenu = Empty(SkillRows(note)) },
        { text = L["CHECK_LINK_LOCKOUT"], submenu = Empty(LockoutRows(note)), submenuMaxRows = cap },
        { text = L["CHECK_LINK_COOLDOWN"], onClick = function()
            Ask(L["CHECK_COOLDOWN_ASK"], "", function(v)
                local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(tonumber(v) or v)
                if info and info.spellID then Lines.Add(note, { link = "cooldown", spell = info.spellID }) end
            end)
        end },
    }
end

-- The ticks' settings

local SCOPES = {
    { value = "account", label = L["CHECK_SCOPE_ACCOUNT"] },
    { value = "character", label = L["CHECK_SCOPE_CHARACTER"] },
}
local RESETS = {
    { value = "never", label = L["CHECK_RESET_NEVER"] },
    { value = "daily", label = L["CHECK_RESET_DAILY"] },
    { value = "weekly", label = L["CHECK_RESET_WEEKLY"] },
    { value = "days", label = L["CHECK_RESET_DAYS"] },
}

local function OptionLabel(options, value)
    for _, o in ipairs(options) do
        if o.value == value then return o.label end
    end
    return options[1].label
end

local function PickReset(owner, note)
    local reset = note.list.reset
    local defs = {}
    for _, o in ipairs(RESETS) do
        defs[#defs + 1] = { kind = "radio", label = o.label, value = o.value,
            get = function() return reset.every end, set = function(v) reset.every = v Changed(note) end }
    end
    if reset.every == "days" then
        defs[#defs + 1] = { kind = "separator" }
        reset.days = reset.days or {}
        for wday = 1, 7 do
            defs[#defs + 1] = { kind = "check", label = _G["WEEKDAY_" .. ({ "SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY" })[wday]] or tostring(wday),
                get = function() return reset.days[wday] == true end,
                set = function(v) reset.days[wday] = v or nil Changed(note) end }
        end
        defs[#defs + 1] = { kind = "action", label = sformat(L["CHECK_RESET_AT_FMT"], reset.hour or 0, reset.min or 0), onClick = function()
            Ask(L["CHECK_RESET_AT_ASK"], sformat("%02d:%02d", reset.hour or 0, reset.min or 0), function(v)
                local h, m = smatch(v, "^(%d%d?):(%d%d)$")
                h, m = tonumber(h), tonumber(m)
                if h and m and h < 24 and m < 60 then reset.hour, reset.min = h, m Changed(note) end
            end)
        end }
    end
    ns.ShowTogglePopup("EasyFindChecklistReset", owner, defs, {})
end

-- The note menu's Checklist entry: what a line can track; with lines, who
-- keeps the ticks, when they clear, the board, the next auction search.
function Lines.MenuRows(note, anchor)
    local rows = { { text = L["CHECK_TRACK"], submenu = Lines.TrackRows(note) } }
    if not CK.Is(note) then return rows end
    local list = CK.Init(note)
    local scopes = {}
    for _, o in ipairs(SCOPES) do
        scopes[#scopes + 1] = { text = o.label, icon = (list.scope or "account") == o.value and MENU_CHECK_TEX or nil,
            onClick = function() list.scope = o.value Changed(note) end }
    end
    rows[#rows + 1] = { isSeparator = true }
    rows[#rows + 1] = { text = sformat(L["CHECK_SCOPE_FMT"], OptionLabel(SCOPES, list.scope)), submenu = scopes }
    rows[#rows + 1] = { text = L["CHECK_RESET_ROW"], onClick = function() PickReset(anchor, note) end }
    rows[#rows + 1] = { text = L["CHECK_BOARD"], icon = S().boardShown and MENU_CHECK_TEX or nil, iconSide = "right",
        onClick = function() Lines.ShowBoard(not S().boardShown) end }
    rows[#rows + 1] = { text = L["CHECK_SEARCH_AH"], disabled = not AuctionOpen(), onClick = function() SearchNext(note) end }
    return rows
end

-- The alts board: one column per character, one row per line, over the words.

local function Text(parent, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template)
    ns.RegisterAddonFont(fs)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function Board()
    local s = S()
    if s.board then return s.board end
    local frame = Frame()
    local board = CreateFrame("Frame", nil, frame)
    board:SetAllPoints(frame.editorScroll)
    board:SetFrameLevel(frame.editor:GetFrameLevel() + 8)
    board:EnableMouse(true)
    board:EnableMouseWheel(true)
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(board)
        ns.SetRoundedRectBarHeight(board, 8)
        ns.SetRoundedRectBorderEdgeShown(board, false)
        ns.SetRoundedRectRingShown(board, false)
        local c = ns.ThemeSetOf(board).SEARCH_WINDOW_FILL_COLOR or { 0.052, 0.052, 0.060 }
        ns.SetRoundedRectFill(board, c[1], c[2], c[3], 1, true)
    end
    local scroll = CreateFrame("ScrollFrame", nil, board)
    scroll:SetPoint("TOPLEFT", board, "TOPLEFT", 0, -2)
    scroll:SetPoint("BOTTOMRIGHT", board, "BOTTOMRIGHT", -12, 2)
    board.scroll = scroll
    board.list = CreateFrame("Frame", nil, scroll)
    board.list:SetSize(1, 1)
    scroll:SetScrollChild(board.list)
    board.bar = Utils.CreateMinimalScrollBar(scroll, board)
    board:Hide()
    s.board = board
    return board
end

local function Cell(board, i)
    local s = S()
    local cell = s.cells[i]
    if cell then return cell end
    cell = CreateFrame("Frame", nil, board.list)
    cell:SetSize(CELL_W, ROW_H)
    cell.tex = cell:CreateTexture(nil, "ARTWORK")
    cell.tex:SetSize(16, 16)
    cell.tex:SetPoint("CENTER")
    cell.tex:SetTexture(READY_TEX)
    cell.text = Text(cell, "GameFontHighlightSmall")
    cell.text:SetPoint("CENTER")
    cell.text:SetJustifyH("CENTER")
    s.cells[i] = cell
    return cell
end

local function Head(board, i)
    local s = S()
    local head = s.heads[i]
    if head then return head end
    head = Text(board.list, "GameFontNormalSmall")
    head:SetWidth(CELL_W)
    head:SetJustifyH("CENTER")
    s.heads[i] = head
    return head
end

local function Row(board, i)
    local s = S()
    local row = s.rows[i]
    if row then return row end
    row = Text(board.list, "GameFontHighlight")
    row:SetWidth(NAME_W)
    s.rows[i] = row
    return row
end

local function FillBoard(note)
    local s = S()
    local board = Board()
    local chars = CK.Board(note)
    local lines = note.list.lines
    local open = OpenColor()
    for i, charKey in ipairs(chars) do
        local head = Head(board, i)
        head:ClearAllPoints()
        head:SetPoint("TOPLEFT", board.list, "TOPLEFT", NAME_W + (i - 1) * CELL_W, 0)
        head:SetText(CK.CharName(charKey))
        head:Show()
    end
    for i = #chars + 1, #s.heads do s.heads[i]:Hide() end
    local n = 0
    for r, line in ipairs(lines) do
        CK.LineState(note, line)
        local y = 18 + (r - 1) * ROW_H
        local row = Row(board, r)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", board.list, "TOPLEFT", 4, -y - 4)
        row:SetText(CK.LineLabel(line))
        row:SetTextColor(open[1], open[2], open[3], 1)
        row:Show()
        for c, charKey in ipairs(chars) do
            n = n + 1
            local cell = Cell(board, n)
            local done, progress = CK.BoardCell(note, line, charKey)
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", board.list, "TOPLEFT", NAME_W + (c - 1) * CELL_W, -y)
            cell.tex:SetShown(done == true)
            cell.text:SetShown(done ~= true)
            cell.text:SetText(done == nil and "-" or (progress or ""))
            cell:Show()
        end
    end
    for i = #lines + 1, #s.rows do s.rows[i]:Hide() end
    for i = n + 1, #s.cells do s.cells[i]:Hide() end
    local h = 18 + #lines * ROW_H
    board.list:SetSize(mmax(1, NAME_W + #chars * CELL_W), mmax(1, h))
    local viewH = board.scroll:GetHeight() or 0
    if h > viewH + 1 then
        board.bar:Show()
        board.bar:UpdateThumb(h, viewH)
    else
        board.scroll:SetVerticalScroll(0)
        board.bar:Hide()
    end
    board:Show()
end

function Lines.ShowBoard(on)
    local s = S()
    s.boardShown = on and true or false
    local note = Note()
    if s.boardShown and note and CK.Is(note) and Frame() then
        FillBoard(note)
    elseif s.board then
        s.board:Hide()
    end
end

-- The editor view showing or not (the list of notes replaces it).
function Lines.ViewShown(shown)
    local s = S()
    if not shown then
        s.boardShown = false
        if s.board then s.board:Hide() end
        for _, tail in ipairs(s.tails) do tail:Hide() end
    end
end

-- A note drawn again: the board follows it while it shows.
function Lines.Refresh()
    local s = S()
    if s.boardShown then Lines.ShowBoard(true) end
end

-- Shift-clicked items, quests and spells: into the editor at its caret
-- while it has the keyboard, else a line under the note's last in the
-- window used last, when that note has lines. The chat box comes first.
if Utils.HookInsertLink then Utils.HookInsertLink(function(link)
    local chat = (ChatFrameUtil and ChatFrameUtil.GetActiveWindow and ChatFrameUtil.GetActiveWindow())
        or (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow())
    if chat then return end
    local w = W.Focused()
    local frame = w.frame
    if not (frame and frame:IsShown() and not w.paletteShown and frame.editor) then return end
    link = Utils.HexColorNames(link)
    W.Run(w, function()
        if frame.editor:HasFocus() then
            frame.editor:Insert(link)
            return
        end
        local note = Note()
        if note and CK.Is(note) then Lines.AddWords(note, link) end
    end)
end) end

-- The game's answers change: every window on a note with lines draws them again.
local EVENTS = { "BAG_UPDATE_DELAYED", "QUEST_LOG_UPDATE", "QUEST_TURNED_IN", "UPDATE_FACTION", "PLAYER_MONEY",
    "PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED", "UPDATE_INSTANCE_INFO", "SPELL_UPDATE_COOLDOWN",
    "BAG_UPDATE_COOLDOWN", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "GET_ITEM_INFO_RECEIVED" }
local watcher = CreateFrame("Frame")
for _, e in ipairs(EVENTS) do watcher:RegisterEvent(e) end
watcher:SetScript("OnEvent", function()
    if Lines.queued or not W.AnyShown() then return end
    Lines.queued = true
    Utils.SafeAfter(0.3, function()
        Lines.queued = nil
        W.Each(function(w)
            local note = Note()
            if w.frame:IsShown() and not w.paletteShown and note and CK.Is(note) then
                NotesUI:QueueEasyNotesOverlayUpdate()
                Lines.Refresh()
            end
        end)
    end)
end)

-- Each character leaves what its linked lines read, for the board, and
-- schedules clear hand ticks even while no note is open.
function Lines.Sweep()
    local now = time()
    for _, note in ipairs(notesNS.AllNotes and notesNS.AllNotes() or {}) do
        if CK.Is(note) then
            CK.ApplyReset(note, now)
            for _, line in ipairs(note.list.lines) do
                if line.link then CK.LineState(note, line) end
            end
        end
    end
end

local sweeper = CreateFrame("Frame")
sweeper:RegisterEvent("PLAYER_LOGOUT")
sweeper:SetScript("OnEvent", Lines.Sweep)
Utils.SafeAfter(5, Lines.Sweep)

-- A theme change repaints the lines in its colors while they show.
if ns.RegisterThemeCallback then
    ns.RegisterThemeCallback(function()
        W.Each(function(w)
            if w.frame:IsShown() and not w.paletteShown then
                NotesUI:QueueEasyNotesOverlayUpdate()
                Lines.Refresh()
            end
        end)
    end)
end

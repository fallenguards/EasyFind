local _, ns = ...

-- Per-row keybinds ("shortkeys"). A shortkey binds a key to a search row's
-- action so pressing it executes that row even with the search bar closed.
-- Rows are identified by the same stable key as aliases (Aliases:GetEntryKey),
-- so a row's alias and shortkey line up in the combined management table.
--
-- Execution reuses the result-row machinery: a hidden pool of secure buttons
-- gets each row's secure attributes (cast / use / equip / run), and the bound
-- key is routed to the matching button via SetOverrideBindingClick, which takes
-- precedence over game binds. Navigation rows (open a panel, show a guide) have
-- no secure action, so their button runs SelectResult on press instead.

local Shortkeys = {}
ns.Shortkeys = Shortkeys

local Utils = ns.Utils
local InCombatLockdown = InCombatLockdown
local SetOverrideBindingClick = SetOverrideBindingClick
local ClearOverrideBindings = ClearOverrideBindings
local GetBindingAction = GetBindingAction
local pairs = pairs
local wipe = wipe

local function CharKey()
    return ns.CurrentCharacterKey()
end

-- Class/spec-specific rows must not carry across characters; everything else
-- (collections, commands, panels, account macros) is account-wide.
function Shortkeys:IsCharacterSpecific(data)
    if not data then return false end
    local cat = data.category
    if cat == "Ability" or cat == "Talent" then return true end
    if data.macroIndex and data.macroIsChar then return true end
    return false
end

local function AccountStore()
    if not (EasyFind and EasyFind.db) then return nil end
    EasyFind.db.shortkeys = EasyFind.db.shortkeys or {}
    return EasyFind.db.shortkeys
end

local function CharStore()
    if not (EasyFind and EasyFind.db) then return nil end
    EasyFind.db.shortkeysPerChar = EasyFind.db.shortkeysPerChar or {}
    local ck = CharKey()
    EasyFind.db.shortkeysPerChar[ck] = EasyFind.db.shortkeysPerChar[ck] or {}
    return EasyFind.db.shortkeysPerChar[ck]
end

function Shortkeys:GetEntryKey(data)
    return ns.Aliases and ns.Aliases:GetEntryKey(data) or nil
end

-- Returns (info, isCharSpecific) for the shortkey on a given row key, if any.
function Shortkeys:Get(rowKey)
    if not rowKey then return nil end
    local acct = AccountStore()
    if acct and acct[rowKey] then return acct[rowKey], false end
    local perChar = CharStore()
    if perChar and perChar[rowKey] then return perChar[rowKey], true end
    return nil
end

-- Iterate every shortkey active for this character: account-wide plus this
-- character's own. cb(rowKey, info, isCharSpecific).
function Shortkeys:ForEach(cb)
    local acct = AccountStore()
    if acct then for k, info in pairs(acct) do cb(k, info, false) end end
    local perChar = CharStore()
    if perChar then for k, info in pairs(perChar) do cb(k, info, true) end end
end

-- Drop whatever row currently owns this bind, in both stores (one key -> one
-- row, like a normal keybind).
function Shortkeys:RemoveBind(bindKey)
    if not bindKey then return end
    local acct = AccountStore()
    if acct then
        for k, info in pairs(acct) do
            if info.key == bindKey then acct[k] = nil end
        end
    end
    local perChar = CharStore()
    if perChar then
        for k, info in pairs(perChar) do
            if info.key == bindKey then perChar[k] = nil end
        end
    end
end

function Shortkeys:Remove(rowKey)
    if not rowKey then return false end
    local removed = false
    local acct = AccountStore()
    if acct and acct[rowKey] then acct[rowKey] = nil; removed = true end
    local perChar = CharStore()
    if perChar and perChar[rowKey] then perChar[rowKey] = nil; removed = true end
    if removed then self:ApplyAll() end
    return removed
end

-- Clears every shortkey (account-wide + current character) and drops their
-- override bindings via ApplyAll. Mirrors Aliases:ClearAll for the combined
-- management table's "Clear all".
function Shortkeys:ClearAll()
    if not (EasyFind and EasyFind.db) then return end
    local acct = AccountStore()
    if acct then wipe(acct) end
    local pc = CharStore()
    if pc then wipe(pc) end
    self:ApplyAll()
end

-- A shortkey stores its target's action snapshot (the same field set pins
-- persist) so binds work every session without loading the owning provider.
-- Live rows still win at bind/click time, keeping drifting fields (macroIndex)
-- fresh whenever the provider happens to be loaded.
--
-- SNAPSHOT_VER stamps each capture. Bumping it is almost never needed and is NOT
-- free, so avoid it: ApplyAll already re-captures a shortkey's snapshot whenever
-- its live row resolves (the "Live row resolved" branch below), regardless of
-- version. A snapshot therefore picks up newly-persisted fields for free the next
-- time its provider loads -- which every auto-loading category does each reload
-- (eager titles/gearSets, deferred mounts/toys/talents, async appearances). A
-- bump only helps a category whose provider never auto-loads, and it costs a real
-- reload hit: it marks every existing shortkey stale, so _hasUnresolved stays set
-- and ApplyAll re-passes (each rebuilding the key index) run through the whole
-- provider-load window. That is the lever that spiked reload CPU before -- do not
-- bump to roll out a new persisted field; let re-capture-on-resolve heal it.
-- v3: isSpellbookOnly (secure panel-open classification). The later field
-- additions (title/gearSet/talent/appearance IDs, mount summonability, toybox
-- flag, map coords, bindingAction/customToggle) were added WITHOUT a bump for
-- exactly this reason.
local SNAPSHOT_VER = 3
local function SnapshotData(data)
    local clean = ns.UIPins and ns.UIPins.CleanForStorage
    if data and clean then return clean(data) end
    return nil
end

-- Bind bindKey (e.g. "CTRL-1") to a row identified by its stable key. Reassigns
-- the key off any other row first, then routes the row to the right store. Used
-- directly by the options table, where live row data may not be present; an
-- existing snapshot survives a rebind that has none.
function Shortkeys:SetByKey(rowKey, name, charSpecific, bindKey, data)
    if not (EasyFind and EasyFind.db and rowKey) then return false end
    if not bindKey or bindKey == "" then return false end
    local prev = self:Get(rowKey)
    self:RemoveBind(bindKey)
    local acct = AccountStore()
    if acct then acct[rowKey] = nil end
    local pc = CharStore()
    if pc then pc[rowKey] = nil end
    local store = charSpecific and CharStore() or AccountStore()
    if not store then return false end
    local snap = SnapshotData(data)
    store[rowKey] = {
        key = bindKey, name = name, charSpecific = charSpecific or nil,
        data = snap or (prev and prev.data) or nil,
        dataVer = snap and SNAPSHOT_VER or (prev and prev.dataVer) or nil,
    }
    self:ApplyAll()
    return true
end

-- Execution engine: hidden owner frame + secure button pool + override binds.
local owner
local pool = {}
-- Whether any shortkey override is currently bound. Binding writes are
-- dedup'd against it: redundant writes near the combat boundary put
-- Blizzard's key re-attach pass on EasyFind's execution and detonate
-- protected bar updates (PetActionBar:SetShownBase autopsy).
local shortkeysArmed = false
local POOL_PREFIX = "EasyFindShortkeyButton"

local function ResolveData(rowKey)
    return ns.Aliases and ns.Aliases:FindEntryByKey(rowKey) or nil
end

-- Map a shortkey rowKey prefix (Aliases:GetEntryKey format) to the dynamic
-- provider that owns it, for the one-time legacy heal below.
local KEY_PREFIX_PROVIDER = {
    ["mount:"]         = "mounts",
    ["toy:"]           = "toys",
    ["pet:"]           = "pets",
    ["outfit:"]        = "outfits",
    ["appearanceSet:"] = "transmogSets",
    ["macro:"]         = "macros",
    ["reputation:"]    = "reputations",
    ["currency:"]      = "currencies",
    ["loot:"]          = "loot",
    ["catalogitem:"]   = "appearanceItems",
    ["item:"]          = "bags",
}

local function RebindAfterPopulate()
    if Shortkeys.ReapplyIfPending then Shortkeys:ReapplyIfPending() end
end

-- One-time legacy heal: shortkeys saved before they carried an action snapshot
-- can only bind off a live row, so force-load the owning provider(s) even when
-- the category is filtered off. The next ApplyAll snapshots the resolved row,
-- after which the shortkey binds from its snapshot and this path never runs
-- again for it -- the load gate stays honest from then on.
local function RequestProviderForRowKey(rowKey)
    if not (rowKey and ns.Database and ns.Database.RequestDynamicProviderLoaded) then return end
    if rowKey:sub(1, 3) == "ui:" then
        -- Ambiguous legacy prefix: the settings walk, abilities, appearance
        -- items, and static tree rows all mint it. Kick every possible owner.
        pcall(ns.Database.RequestDynamicProviderLoaded, ns.Database, "abilities", nil)
        pcall(ns.Database.RequestDynamicProviderLoaded, ns.Database, "talents", nil)
        pcall(ns.Database.RequestDynamicProviderLoaded, ns.Database, "appearanceItems", nil)
        local options = ns.BlizzOptionsSearch
        if options and options.EnsurePopulatedAsync then
            options:EnsurePopulatedAsync(RebindAfterPopulate)
        end
        if options and options.EnsureLivePopulatedAsync then
            options:EnsureLivePopulatedAsync(RebindAfterPopulate)
        end
        return
    end
    for prefix, provider in pairs(KEY_PREFIX_PROVIDER) do
        if rowKey:sub(1, #prefix) == prefix then
            pcall(ns.Database.RequestDynamicProviderLoaded, ns.Database, provider, nil)
            return
        end
    end
end

-- EasyFind links resolve the same keys from a chat click.
Shortkeys.RequestProviderForRowKey = RequestProviderForRowKey

local function ShortkeyButtonData(self)
    local rowKey = self._rowKey
    local data = rowKey and ResolveData(rowKey)
    if not data and rowKey then
        local info = self._macroInfo or Shortkeys:Get(rowKey)
        data = info and info.data
    end
    return data
end

-- Panel-open macros are armed only while the panel is hidden; re-sync the
-- secure attributes at press time so a stale render (panel toggled by
-- keybind since ApplyAll last ran) cannot leave the wrong action armed.
-- Unconditional like the row PreClick: Apply also disarms when the data
-- has no secure action.
local function OnShortkeyButtonPreClick(self, _, down)
    if not down then return end
    if InCombatLockdown() then return end
    local data = ShortkeyButtonData(self)
    if data and ns.ResultSecureAttributes then
        ns.ResultSecureAttributes.ApplyAtClick(self, data)
    end
end

local function OnShortkeyButtonClick(self, _, down)
    -- Shortkey navigation is silently inert in combat: the paths it drives
    -- (panel opens, guides, hiding the search frame) are protected, and a
    -- chat notice per press was spam. The capture popup and the tutorial
    -- carry the "shortkeys do not work in combat" note instead. Secure cast
    -- rows are unaffected; their action fires from the secure attributes.
    if InCombatLockdown() then return end
    -- Secure rows already fired their action from the secure attributes; this
    -- insecure handler only drives navigation rows (open panel / guide / pin),
    -- resolved live so they never go stale. Panel-opener rows are the
    -- exception: their navigation runs on the RELEASE dispatch, after the
    -- secure open (press) and tab steer (release) both fired, so the
    -- follow-up finds the panel open on the right tab and stays
    -- carrier-free. Everything else acts on the press, as before.
    local data = ShortkeyButtonData(self)
    if not data then return end
    local opensPanel = ns.ResultSecureAttributes
        and ns.ResultSecureAttributes.ActsOnRelease(self, data)
    if opensPanel then
        if down then return end
    elseif not down then
        return
    end
    if not opensPanel and ns.ResultIcons
       and ns.ResultIcons:IsSecureActionResult(data) then return end
    -- Call directly (not deferred): this runs in the key press's hardware-event
    -- context, which ShowUIPanel needs to open protected panels.
    if ns.ResultHandlers and ns.ResultHandlers.SelectResult then
        -- The shortkey's own modifier (e.g. ALT-1 / CTRL-X) is physically held as
        -- this fires. Flag the activation -- exactly like the in-bar result
        -- shortcut -- so the source-modifier checks don't read the bind's
        -- modifier as a deliberate Alt/Ctrl click and take the wrong branch
        -- (e.g. open-the-journal instead of the default hover-dismiss highlight).
        local shortcuts = ns.ResultShortcuts
        if shortcuts then shortcuts._resultShortcutActivation = true end
        -- A setting-toggle row's primary (left-click) action is the inline
        -- toggle. Every other activation path -- row PostClick and keyboard
        -- Enter -- runs ActivateSettingResult first; the shortkey must too, or
        -- it falls through to SelectResult and merely opens the Settings panel
        -- (the Alt fallthrough) instead of flipping the setting.
        -- A snippet's click/Enter action is "open the editor", but its
        -- shortkey FIRES the snippet into chat, exactly as if its keyword
        -- had been typed -- a bound snippet is for using, not editing.
        -- (The create row keeps the default action: it has nothing to fire.)
        if data.category == "Snippet" and not data.snippetCreate and EasyFind.API.HasAction("snippets", "run") then
            EasyFind.API.CallAction("snippets", "run", data.name)
        elseif not (ns.ResultRows and ns.ResultRows.ActivateSettingResult
                and ns.ResultRows:ActivateSettingResult(data)) then
            ns.ResultHandlers:SelectResult(data)
        end
        if shortcuts then shortcuts._resultShortcutActivation = nil end
    end
end

local function EnsureOwner()
    if owner then return owner end
    owner = CreateFrame("Frame", "EasyFindShortkeyOwner", UIParent)
    owner:SetSize(1, 1)
    owner:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
    owner:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            -- Fires before combat lockdown engages, so clearing is legal:
            -- strip every shortkey override for the whole fight. Combat
            -- keypresses fall through to the player's own binds, and
            -- nothing of ours can run or taint. Shortkeys are documented
            -- as not working in combat; this makes that literal.
            if shortkeysArmed then
                ClearOverrideBindings(self)
                shortkeysArmed = false
            end
            return
        end
        if event == "UPDATE_MACROS" then Shortkeys:PruneMacros() end
        Shortkeys:ApplyAll()
    end)
    -- Refresh secure attributes when the things they encode can change. The
    -- only ones that drift are reordered outfits (player-facing index) and
    -- edited macro bodies; ApplyAll defers to PLAYER_REGEN_ENABLED if in
    -- combat. REGEN events stay registered permanently: DISABLED strips the
    -- binds for combat, ENABLED reapplies them after.
    owner:RegisterEvent("PLAYER_REGEN_DISABLED")
    owner:RegisterEvent("PLAYER_REGEN_ENABLED")
    owner:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    owner:RegisterEvent("PLAYER_ENTERING_WORLD")
    owner:RegisterEvent("TRANSMOG_OUTFITS_CHANGED")
    owner:RegisterEvent("UPDATE_MACROS")
    return owner
end

local function GetButton(i)
    if pool[i] then return pool[i] end
    EnsureOwner()
    local b = CreateFrame("Button", POOL_PREFIX .. i, owner, "SecureActionButtonTemplate")
    -- Must stay SHOWN: a hidden secure button won't dispatch its protected
    -- action when triggered by a keybind. Keep it 1px in the corner.
    b:SetSize(1, 1)
    b:SetPoint("BOTTOMLEFT", owner, "BOTTOMLEFT", 0, 0)
    -- Match EasyFind's result rows exactly: register both left edges (press
    -- fires the secure action, release fires the panel-opener tab steer) and
    -- drive our navigation handler from PostClick. SecureActionButtonTemplate
    -- dispatches the protected action through its own OnClick, so we must NOT
    -- replace OnClick; doing so was why the secure action never fired.
    b:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
    b:SetScript("PreClick", OnShortkeyButtonPreClick)
    b:SetScript("PostClick", OnShortkeyButtonClick)
    pool[i] = b
    return b
end

function Shortkeys:ApplyAll()
    if not (EasyFind and EasyFind.db) then return end
    EnsureOwner()
    if InCombatLockdown() then
        owner:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    if shortkeysArmed then
        ClearOverrideBindings(owner)
        shortkeysArmed = false
    end

    local list = {}
    self:ForEach(function(rowKey, info)
        list[#list + 1] = { rowKey = rowKey, key = info.key, info = info }
    end)

    local hadUnresolved = false
    for i = 1, #list do
        local rowKey = list[i].rowKey
        local bindKey = list[i].key
        local info = list[i].info
        local data = ResolveData(rowKey)
        if data then
            -- Live row resolved: (re)capture the snapshot so future sessions
            -- bind without loading this provider, and snapshots saved before
            -- the field list grew (or with drifted fields) self-heal.
            info.data = SnapshotData(data)
            info.dataVer = info.data and SNAPSHOT_VER or nil
        else
            -- Provider not loaded: bind straight from the stored snapshot. A
            -- snapshot stamped by an older field set still binds; flag a re-pass
            -- (ReapplyIfPending only rebinds when something is pending) so it
            -- re-captures current fields once its provider loads on its own --
            -- the login eager/deferred batch, or the user searching that
            -- category. Deliberately does NOT force-load here: pulling every
            -- stale shortkey's provider in at reload was a CPU avalanche.
            data = info.data
            if data and info.dataVer ~= SNAPSHOT_VER then
                hadUnresolved = true
            end
        end
        if data and bindKey and bindKey ~= "" then
            local b = GetButton(i)
            b._rowKey = rowKey
            if ns.ResultIcons and ns.ResultIcons:IsSecureActionResult(data) then
                if ns.ResultSecureAttributes and ns.ResultSecureAttributes.Apply then
                    ns.ResultSecureAttributes.Apply(b, data)
                end
            elseif ns.ResultSecureAttributes then
                -- Navigation row: no secure action, OnClick handles it. Clear
                -- (not a bare type=nil) so the previous binding's attribute
                -- and dedup cache can't disarm a later rebind of this button.
                ns.ResultSecureAttributes.Clear(b)
            end
            local btnName = b:GetName()
            if btnName then
                SetOverrideBindingClick(owner, true, bindKey, btnName, "LeftButton")
                shortkeysArmed = true
            end
        elseif bindKey and bindKey ~= "" then
            -- No live row and no snapshot: a legacy entry saved before
            -- shortkeys carried their action. Force-load its provider once so
            -- it resolves; ReapplyIfPending (Search/Query.lua) rebinds when it
            -- streams in and the resolve pass above snapshots it for good.
            hadUnresolved = true
            RequestProviderForRowKey(rowKey)
        end
    end
    self._hasUnresolved = hadUnresolved
    self:ApplyMacros()
end

-- Re-run ApplyAll only while some shortkey's provider has not loaded yet, so a
-- provider finishing (async) binds the shortkeys that were skipped, without
-- churning every binding on each provider load once everything resolves.
function Shortkeys:ReapplyIfPending()
    if self._hasUnresolved then self:ApplyAll() end
end

-- ==== macros ================================================================
-- A result on an action bar without a key: its macro clicks one of these
-- buttons, pressed then released as a key is, so it does what the row's
-- shortkey would. A button's number never changes: the macro names it.
local MACRO_PREFIX = "EasyFindMacro"
local MACRO_NAME_MAX = 16
local MACRO_FALLBACK_ICON = "Interface\\Icons\\INV_Misc_Spyglass_03"
local macroPool = {}

local function MacroStore()
    if not (EasyFind and EasyFind.db) then return nil end
    local store = EasyFind.db.macroButtons
    if not store then
        store = { nextID = 1, byID = {} }
        EasyFind.db.macroButtons = store
    end
    return store
end

-- A quicklist's macro opens it; a key no row answers yet (a route, an
-- item the bags lack) goes the way its chat link would.
local function OnMacroButtonClick(self, button, down)
    local info = self._macroInfo
    if not info or InCombatLockdown() then return end
    if info.quicklist then
        if down and ns.Quicklists then ns.Quicklists:Toggle(info.quicklist) end
        return
    end
    if not ShortkeyButtonData(self) then
        if down and ns.ResultLinks and ns.ResultLinks.OpenKey then ns.ResultLinks:OpenKey(info.rowKey) end
        return
    end
    OnShortkeyButtonClick(self, button, down)
end

local function MacroButton(id)
    local b = macroPool[id]
    if b then return b end
    EnsureOwner()
    b = CreateFrame("Button", MACRO_PREFIX .. id, owner, "SecureActionButtonTemplate")
    b:SetSize(1, 1)
    b:SetPoint("BOTTOMLEFT", owner, "BOTTOMLEFT", 0, 0)
    b:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
    b:SetScript("PreClick", OnShortkeyButtonPreClick)
    b:SetScript("PostClick", OnMacroButtonClick)
    macroPool[id] = b
    return b
end

-- Every macro's button armed with its row's action; a row not loaded yet
-- arms from its snapshot, and the press re-reads it live.
function Shortkeys:ApplyMacros()
    local store = MacroStore()
    if not store or InCombatLockdown() then return end
    local Secure = ns.ResultSecureAttributes
    for id, info in pairs(store.byID) do
        local b = MacroButton(id)
        b._macroInfo = info
        b._rowKey = not info.quicklist and info.rowKey or nil
        local data = b._rowKey and ResolveData(info.rowKey)
        if data then
            info.data = SnapshotData(data)
            info.dataVer = info.data and SNAPSHOT_VER or nil
        else
            data = b._rowKey and info.data
        end
        if Secure and data and ns.ResultIcons and ns.ResultIcons:IsSecureActionResult(data) then
            Secure.Apply(b, data)
        elseif Secure then
            Secure.Clear(b)
        end
    end
end

-- The macro clicking button id, by its place in the macro window.
local function MacroIndexFor(id)
    local tag = MACRO_PREFIX .. id .. " "
    local numAccount, numChar = GetNumMacros()
    local consts = _G["Constants"] and _G["Constants"].MacroConsts
    local base = consts and consts.MAX_ACCOUNT_MACROS or 120
    for i = 1, (numAccount or 0) do
        local _, _, body = GetMacroInfo(i)
        if body and body:find(tag, 1, true) then return i end
    end
    for i = base + 1, base + (numChar or 0) do
        local _, _, body = GetMacroInfo(i)
        if body and body:find(tag, 1, true) then return i end
    end
    return nil
end

-- A macro deleted in the macro window takes its button along. One on a
-- character tab is only seen by that character.
function Shortkeys:PruneMacros()
    local store = EasyFind and EasyFind.db and EasyFind.db.macroButtons
    if not store or InCombatLockdown() then return end
    local numAccount, numChar = GetNumMacros()
    if (numAccount or 0) + (numChar or 0) == 0 then return end
    local here = CharKey()
    for id, info in pairs(store.byID) do
        if (not info.char or info.char == here) and not MacroIndexFor(id) then
            store.byID[id] = nil
            local b = macroPool[id]
            if b then
                b._macroInfo, b._rowKey = nil, nil
                if ns.ResultSecureAttributes then ns.ResultSecureAttributes.Clear(b) end
            end
        end
    end
end

-- The client takes 16 characters; a cut never splits a letter.
local function MacroName(name)
    name = tostring(name or "")
    local chars = 0
    for pos = 1, #name do
        local c = name:byte(pos)
        if c < 128 or c >= 192 then
            chars = chars + 1
            if chars > MACRO_NAME_MAX then
                name = name:sub(1, pos - 1)
                break
            end
        end
    end
    return name ~= "" and name or (_G["MACRO"] or "Macro")
end

local function MacroIcon(icon)
    if type(icon) == "number" then return icon end
    local GetFileIDFromPath = _G["GetFileIDFromPath"]
    if not GetFileIDFromPath then return 134400 end
    local fileID = type(icon) == "string" and GetFileIDFromPath(icon)
    if fileID and fileID > 0 then return fileID end
    return GetFileIDFromPath(MACRO_FALLBACK_ICON) or 134400
end

-- A row's (or a quicklist's) macro on the cursor, to drop on any bar: the
-- one made before while it exists, else a new one on the account tab (the
-- character tab when that is full). True once it is on the cursor.
function Shortkeys:CreateMacro(rowKey, name, data, quicklistID)
    local store = rowKey and MacroStore()
    if not store then return false end
    if InCombatLockdown() then
        if EasyFind.Print then EasyFind:Print(ns.L["MACRO_IN_COMBAT"]) end
        return false
    end
    local id
    for eid, info in pairs(store.byID) do
        if info.rowKey == rowKey then
            id = eid
            break
        end
    end
    if not id then
        id = store.nextID
        store.nextID = id + 1
        store.byID[id] = { rowKey = rowKey }
    end
    local info = store.byID[id]
    info.name, info.quicklist = name, quicklistID
    local snap = data and SnapshotData(data)
    if snap then info.data, info.dataVer = snap, SNAPSHOT_VER end
    self:ApplyMacros()
    local index = MacroIndexFor(id)
    if not index then
        local button = MACRO_PREFIX .. id
        local body = ("/click %s LeftButton 1\n/click %s LeftButton 0"):format(button, button)
        local macroName, icon = MacroName(name), MacroIcon(data and data.icon)
        local ok, made = pcall(CreateMacro, macroName, icon, body, nil)
        info.char = nil
        if not (ok and made) then
            ok, made = pcall(CreateMacro, macroName, icon, body, true)
            info.char = ok and made and CharKey() or nil
        end
        index = ok and made or nil
    end
    if not index then
        if EasyFind.Print then EasyFind:Print(ns.L["MACRO_NO_ROOM"]) end
        return false
    end
    PickupMacro(index)
    return true
end

-- Capture popup: shown from the row's "Add shortkey" menu option.
local L = ns.L
local capturePopup

-- Conflict detection: returns ("shortkey", otherRowName) if combo already
-- belongs to a different EasyFind shortkey, or ("bind", combo) if combo is a
-- live game/addon keybinding, or nil if free. The shortkey case wins because
-- silently overwriting the player's own shortkey is the more destructive one.
local function DetectBindConflict(rowKey, combo, excludeListID)
    local otherName
    Shortkeys:ForEach(function(k, info)
        if not otherName and k ~= rowKey and info.key == combo then
            otherName = info.name or "?"
        end
    end)
    if not otherName and ns.Quicklists then
        otherName = ns.Quicklists:KeyOwnerName(combo, excludeListID)
    end
    if otherName then return "shortkey", otherName end
    local action = GetBindingAction and GetBindingAction(combo)
    if action and action ~= "" then return "bind", combo end
    return nil
end

local function CommitShortkey(rowKey, name, charSpecific, combo, data)
    if not Shortkeys:SetByKey(rowKey, name, charSpecific, combo, data) then return end
    local sf = ns.Search and ns.Search:GetSearchFrame()
    local eb = sf and sf.editBox
    local typedQuery = ns.Search.GetTypedQuery and ns.Search:GetTypedQuery() or (eb and eb:GetText()) or ""
    if typedQuery ~= "" then ns.Search:OnSearchTextChanged(typedQuery) end
    if ns.RefreshBindTables then ns.RefreshBindTables() end
end

-- "Continue anyway?" confirmation with a "Don't ask me again" checkbox that
-- writes EasyFind.db.shortkeyConflictPrompt = false to suppress all future
-- conflict warnings.
local conflictPopup
local function BuildConflictPopup()
    local f = CreateFrame("Frame", "EasyFindShortkeyConflict", UIParent, "BackdropTemplate")
    f:SetSize(340, 150)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    ns.StyleMenuPanel(f)

    f.message = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.message:SetPoint("TOPLEFT", 16, -18)
    f.message:SetPoint("TOPRIGHT", -16, -18)
    f.message:SetJustifyH("CENTER")
    f.message:SetWordWrap(true)

    local cb = CreateFrame("CheckButton", nil, f)
    cb:SetSize(20, 20)
    cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    f.dontAsk = cb
    local cbLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cbLabel:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    cbLabel:SetText(L["SHORTKEY_CONFLICT_DONT_ASK"])
    -- Center the [checkbox][gap][label] group on the popup's horizontal center:
    -- group width = 20 (box) + 4 (gap) + label, so the box's left edge sits half
    -- the group width left of center.
    local groupHalf = math.floor((20 + 4 + cbLabel:GetStringWidth()) / 2)
    cb:SetPoint("BOTTOMLEFT", f, "BOTTOM", -groupHalf, 46)

    local continueBtn = ns.CreateModernButton(f, _G["CONTINUE"] or "Continue", 110, 24)
    continueBtn:SetPoint("BOTTOM", f, "BOTTOM", -58, 14)
    continueBtn:SetScript("OnClick", function()
        if f.dontAsk:GetChecked() then EasyFind.db.shortkeyConflictPrompt = false end
        local onAccept = f.onAccept
        f:Hide()
        if onAccept then onAccept() end
    end)

    local cancelBtn = ns.CreateModernButton(f, _G["CANCEL"] or "Cancel", 110, 24)
    cancelBtn:SetPoint("BOTTOM", f, "BOTTOM", 58, 14)
    cancelBtn:SetScript("OnClick", function()
        if f.dontAsk:GetChecked() then EasyFind.db.shortkeyConflictPrompt = false end
        f:Hide()
    end)

    local close = ns.CreateCloseX(f, 14)
    close:SetPoint("TOPRIGHT", -8, -8)
    close:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnHide", function(self) self.onAccept = nil end)
    f:Hide()
    return f
end

local function ShowConflictPopup(message, onAccept)
    if not conflictPopup then conflictPopup = BuildConflictPopup() end
    conflictPopup.onAccept = onAccept
    conflictPopup.dontAsk:SetChecked(false)
    conflictPopup.message:SetText(message)
    conflictPopup:SetHeight(conflictPopup.message:GetStringHeight() + 98)
    conflictPopup:Show()
end

local function StopCapture(popup)
    popup.capturing = false
    Utils.DisarmBindingCapture(popup)
    if popup.bindBtn then
        local current = popup.currentCombo
        if not popup.onCombo then
            local existing = popup.rowKey and Shortkeys:Get(popup.rowKey)
            current = existing and existing.key
        end
        popup.bindBtn:SetText(current or L["SHORTKEY_CLICK_TO_BIND"])
    end
end

local function StartCapture(popup)
    popup.capturing = true
    popup.bindBtn:SetText(L["OPT_KB_PRESS_KEY"])
    Utils.ArmBindingCapture(popup, function(self, combo)
        if combo == "stop" then StopCapture(self); return end
        -- A caller's own key (a quicklist): the combo goes to it, after
        -- the same conflict notice.
        if self.onCombo then
            local onCombo, exclude = self.onCombo, self.excludeListID
            StopCapture(self)
            self:Hide()
            local kind, label = DetectBindConflict(nil, combo, exclude)
            if kind and EasyFind and EasyFind.db and EasyFind.db.shortkeyConflictPrompt ~= false then
                local msg = (kind == "shortkey"
                    and L["SHORTKEY_CONFLICT_SHORTKEY"]
                    or L["SHORTKEY_CONFLICT_BIND"]):format(label)
                ShowConflictPopup(msg, function() onCombo(combo) end)
            else
                onCombo(combo)
            end
            return
        end
        local rowKey, name, cs, skData = self.rowKey, self.skName, self.charSpecific, self.skData
        StopCapture(self)
        self:Hide()
        if not rowKey then return end
        local kind, label = DetectBindConflict(rowKey, combo)
        if kind and EasyFind and EasyFind.db and EasyFind.db.shortkeyConflictPrompt ~= false then
            local msg = (kind == "shortkey"
                and L["SHORTKEY_CONFLICT_SHORTKEY"]
                or L["SHORTKEY_CONFLICT_BIND"]):format(label)
            ShowConflictPopup(msg, function() CommitShortkey(rowKey, name, cs, combo, skData) end)
        else
            CommitShortkey(rowKey, name, cs, combo, skData)
        end
    end)
end

-- A caller's own button takes the key itself (a new quicklist's): a click
-- arms it, the next key is the combo (after the conflict notice), Escape
-- stops, a right-click clears. get() reads the key it shows.
function Shortkeys:AttachComboCapture(btn, get, onCombo, onClear, excludeListID)
    local function Label() btn:SetText(get() or L["SHORTKEY_CLICK_TO_BIND"]) end
    local function Stop()
        if not btn.capturing then return end
        btn.capturing = false
        Utils.DisarmBindingCapture(btn)
        Label()
    end
    btn._efStopCapture = Stop
    if not btn._efCaptureHideHooked then
        btn._efCaptureHideHooked = true
        btn:HookScript("OnHide", function(self) if self._efStopCapture then self._efStopCapture() end end)
    end
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            Stop()
            onClear()
            Label()
            return
        end
        if self.capturing then Stop() return end
        -- Keys go to the button, not a box being typed in.
        local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
        if focus then focus:ClearFocus() end
        self.capturing = true
        self:SetText(L["OPT_KB_PRESS_KEY"])
        Utils.ArmBindingCapture(self, function(_, combo)
            Stop()
            if combo == "stop" then return end
            local function Take()
                onCombo(combo)
                Label()
            end
            local kind, label = DetectBindConflict(nil, combo, excludeListID)
            if kind and EasyFind and EasyFind.db and EasyFind.db.shortkeyConflictPrompt ~= false then
                ShowConflictPopup((kind == "shortkey" and L["SHORTKEY_CONFLICT_SHORTKEY"]
                    or L["SHORTKEY_CONFLICT_BIND"]):format(label), Take)
            else
                Take()
            end
        end)
    end)
    Label()
end

local function BuildCapturePopup()
    local f = CreateFrame("Frame", "EasyFindShortkeyCapture", UIParent, "BackdropTemplate")
    f:SetSize(300, 116)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    -- Match the addon's search-window styling (rounded border + translucent fill).
    ns.StyleMenuPanel(f)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 12, -13)
    f.title:SetPoint("TOPRIGHT", -12, -13)
    f.title:SetJustifyH("CENTER")
    f.title:SetWordWrap(true)

    -- Same rounded fill button as the options keybind rows.
    local bindBtn = ns.CreateModernButton(f, L["SHORTKEY_CLICK_TO_BIND"], 190, 24)
    bindBtn:SetNormalFontObject("GameFontHighlightSmall")
    bindBtn:SetHighlightFontObject("GameFontHighlightSmall")
    bindBtn:SetPoint("TOP", f.title, "BOTTOM", 0, -14)
    bindBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    bindBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            if f.onClear then
                f.currentCombo = nil
                StopCapture(f)
                f.onClear()
                return
            end
            if f.rowKey then Shortkeys:Remove(f.rowKey) end
            StopCapture(f)
            if ns.RefreshBindTables then ns.RefreshBindTables() end
            return
        end
        if f.capturing then StopCapture(f) else StartCapture(f) end
    end)
    f.bindBtn = bindBtn

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hint:SetPoint("TOP", bindBtn, "BOTTOM", 0, -8)
    f.hint:SetText(L["OPT_KB_CLEAR_HINT"])

    -- Gold like the title (GameFontNormalSmall is natively that color),
    -- dropped slightly below the gray hint without growing the window.
    f.combatNote = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.combatNote:SetPoint("TOP", f.hint, "BOTTOM", 0, -6)
    f.combatNote:SetText(L["SHORTKEY_COMBAT_NOTE"])

    f.macroBtn = ns.CreateModernButton(f, L["SHORTKEY_MAKE_MACRO"], 190, 22)
    f.macroBtn:SetNormalFontObject("GameFontHighlightSmall")
    f.macroBtn:SetHighlightFontObject("GameFontHighlightSmall")
    -- As wide as its label needs, within the popup.
    local labelW = f.macroBtn._label and f.macroBtn._label:GetStringWidth() or 0
    f.macroBtn:SetSize(math.min(math.max(190, labelW + 24), f:GetWidth() - 24), 22)
    f.macroBtn:SetText(L["SHORTKEY_MAKE_MACRO"])
    f.macroBtn:SetPoint("TOP", f.combatNote, "BOTTOM", 0, -10)
    f.macroBtn:SetScript("OnClick", function()
        local onMacro = f.onMacro
        f:Hide()
        if onMacro then onMacro() end
    end)
    f.macroBtn:HookScript("OnEnter", function(self) ns.ShowHintTooltip(self, "ANCHOR_TOP", nil, L["CTX_CREATE_MACRO_TT"]) end)
    f.macroBtn:HookScript("OnLeave", function(self) ns.HideHintTooltip(self) end)

    local close = ns.CreateCloseX(f, 14)
    close:SetPoint("TOPRIGHT", -8, -8)
    close:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnHide", function(self)
        StopCapture(self)
        self.rowKey = nil
        self.skName = nil
        self.charSpecific = nil
        self.skData = nil
        self.onCombo = nil
        self.onClear = nil
        self.currentCombo = nil
        self.excludeListID = nil
        self.onMacro = nil
    end)
    f:Hide()
    return f
end

-- The macro button shows when the caller has a macro to offer.
local function ShowCapturePopup(f)
    f.macroBtn:SetShown(f.onMacro ~= nil)
    f:SetHeight(f.onMacro and 150 or 116)
    f:Show()
    -- Over a dialog that opened it (a new quicklist's key).
    f:Raise()
end

-- The same capture popup for a key that is not a row's: onCombo(combo)
-- gets the key, onClear runs on a right-click of the bind button.
function Shortkeys:PromptForCombo(title, current, onCombo, onClear, excludeListID, onMacro)
    if not capturePopup then capturePopup = BuildCapturePopup() end
    local f = capturePopup
    f:Hide()
    f.onCombo = onCombo
    f.onClear = onClear
    f.currentCombo = current
    f.excludeListID = excludeListID
    f.onMacro = onMacro
    f.title:SetText(title or "")
    f.bindBtn:SetText(current or L["SHORTKEY_CLICK_TO_BIND"])
    ShowCapturePopup(f)
end

function Shortkeys:PromptForKeyByKey(rowKey, name, charSpecific, data)
    if not rowKey then return end
    if not capturePopup then capturePopup = BuildCapturePopup() end
    capturePopup.rowKey = rowKey
    capturePopup.skName = name
    capturePopup.charSpecific = charSpecific
    capturePopup.skData = data
    capturePopup.title:SetText((L["SHORTKEY_FOR"]):format(name or "?"))
    local existing = self:Get(rowKey)
    capturePopup.bindBtn:SetText((existing and existing.key) or L["SHORTKEY_CLICK_TO_BIND"])
    -- No EasyFind macro for a row that only shows something (a catalog item).
    capturePopup.onMacro = not (data and data.lookupRow) and function()
        if Shortkeys:CreateMacro(rowKey, name, data) and ns.ResultHandlers then
            ns.ResultHandlers:FinishResultSelection()
        end
    end or nil
    ShowCapturePopup(capturePopup)
end

function Shortkeys:PromptForKey(data)
    if not data then return end
    local rowKey = self:GetEntryKey(data)
    if not rowKey then return end
    self:PromptForKeyByKey(rowKey, data.name, self:IsCharacterSpecific(data), data)
end

-- Import / export. Aliases and/or shortkeys serialize to a length-prefixed
-- blob (no delimiter escaping needed) wrapped in base64 so it copy-pastes as a
-- single shareable code: "EF1!<base64>".

local base64enc, base64dec = Utils.Base64Encode, Utils.Base64Decode

-- ==== shared-code rules =====================================================
-- Agreed with the EasyFind website (2026-09-08) so a code the addon accepts
-- is never refused there for a different reason. They apply only to codes
-- that travel: what a player sets up by hand is never limited. A code
-- leaves these rows out (the export says how many) and an import lists
-- them as left out rather than applying them.
local SHARE_CAPS = { aliases = 300, shortkeys = 100, blacklist = 500, snippets = 100, quicklists = 50 }
local SHARE_FIELD_MAX = 80      -- characters, per field
local SHARE_BODY_MAX = 255      -- characters a snippet body shows (a link counts as its bracket text)
local SHARE_BODY_RAW_MAX = 1024 -- bytes a snippet body carries (links travel in full)
-- The last segment of a binding combo a shared code never binds: movement,
-- camera, and the keys the game itself owns.
local REFUSED_KEYS = {
    W = true, A = true, S = true, D = true, Q = true, E = true,
    SPACE = true, ESCAPE = true, ENTER = true, TAB = true,
    UP = true, DOWN = true, LEFT = true, RIGHT = true,
    BUTTON1 = true, BUTTON2 = true, MOUSEWHEELUP = true, MOUSEWHEELDOWN = true,
}
-- Targets (shortkey names, snippet bodies) a shared code never carries.
local REFUSED_COMMANDS = {
    "/logout", "/quit", "/exit", "/camp", "/reload", "/console",
    "/run", "/script", "/dump", "/afk", "/dnd",
}
Shortkeys.SHARE_CAPS, Shortkeys.SHARE_FIELD_MAX, Shortkeys.SHARE_BODY_MAX = SHARE_CAPS, SHARE_FIELD_MAX, SHARE_BODY_MAX
Shortkeys.SHARE_BODY_RAW_MAX = SHARE_BODY_RAW_MAX
Shortkeys.REFUSED_KEYS, Shortkeys.REFUSED_COMMANDS = REFUSED_KEYS, REFUSED_COMMANDS

local function StartsWithRefusedCommand(text)
    if type(text) ~= "string" then return false end
    local lower = strtrim(text):lower()
    for i = 1, #REFUSED_COMMANDS do
        local cmd = REFUSED_COMMANDS[i]
        if lower:sub(1, #cmd) == cmd then
            local after = lower:sub(#cmd + 1, #cmd + 1)
            if after == "" or after == " " or after == "\n" then return true end
        end
    end
    return false
end

-- Every line of a body counts: a macro runs each line.
local function BodyHasRefusedCommand(body)
    if type(body) ~= "string" then return false end
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        if StartsWithRefusedCommand(line) then return true end
    end
    return false
end

local function LineIsCommand(line)
    return type(line) == "string" and strtrim(line):sub(1, 1) == "/"
end

-- True when a row puts a command where it runs on its own: a shortkey on
-- a slash command, or a snippet with a slash-command line. The import
-- preview flags these and warns about the source.
function Shortkeys.RunsCommands(section, row)
    if type(row) ~= "table" then return false end
    if section == "shortkeys" then return LineIsCommand(row.n) end
    if section == "snippets" and type(row.body) == "string" then
        for line in (row.body .. "\n"):gmatch("([^\n]*)\n") do
            if LineIsCommand(line) then return true end
        end
    end
    return false
end

-- Lengths are characters, never bytes: a name in a two- or three-byte
-- script is as long as it reads.
local function Chars(s)
    if strlenutf8 then return strlenutf8(s) end
    return #s
end

local function TooLong(max, ...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" and Chars(v) > max then return true end
    end
    return false
end

-- A snippet body is measured the way its editor counts it: links as
-- their bracket text. The raw text, links and all, has its own cap so a
-- code stays a code.
local function BodyTooLong(body)
    if type(body) ~= "string" then return false end
    if #body > SHARE_BODY_RAW_MAX then return true end
    local visible = Utils.ClipboardSafeText and Utils.ClipboardSafeText(body) or body
    return Chars(visible) > SHARE_BODY_MAX
end

-- Human-readable identity for a row, shown in the import conflict prompt
-- and the export's left-out list. Values are the user's own data, never
-- translated.
local function AliasRowLabel(r)
    return '"' .. (r.text or "?") .. '"  (' .. (r.name or "?") .. ")"
end

local function ShortkeyRowLabel(r)
    return (r.b or "?") .. "  (" .. (r.n or "?") .. ")"
end

local function SnippetRowLabel(r)
    local keyword = type(r.keyword) == "string" and r.keyword ~= "" and (r.keyword .. "  ") or ""
    return keyword .. (r.name or "?")
end

local function ShareRowLabel(section, r)
    if section == "aliases" then return AliasRowLabel(r) end
    if section == "shortkeys" then return ShortkeyRowLabel(r) end
    if section == "snippets" then return SnippetRowLabel(r) end
    return r.name or "?"
end

-- Why a row cannot travel in a shared code ("key", "command", "length"),
-- or nil when it can. section is aliases, shortkeys, blacklist or
-- snippets; row is the codec's row shape for that section.
function Shortkeys.ShareRefusal(section, row)
    if type(row) ~= "table" then return "length" end
    if section == "shortkeys" then
        local combo = type(row.b) == "string" and row.b or ""
        local last = combo:match("([^%-]+)$") or combo
        if REFUSED_KEYS[last:upper()] then return "key" end
        if StartsWithRefusedCommand(row.n) then return "command" end
        if TooLong(SHARE_FIELD_MAX, row.k, row.b, row.n) then return "length" end
    elseif section == "aliases" then
        if TooLong(SHARE_FIELD_MAX, row.text, row.key, row.name) then return "length" end
    elseif section == "blacklist" then
        if TooLong(SHARE_FIELD_MAX, row.key, row.name, row.category) then return "length" end
    elseif section == "snippets" then
        if BodyHasRefusedCommand(row.body) then return "command" end
        if TooLong(SHARE_FIELD_MAX, row.name, row.keyword) or BodyTooLong(row.body) then
            return "length"
        end
    elseif section == "quicklists" then
        local combo = type(row.key) == "string" and row.key or ""
        local last = combo:match("([^%-]+)$") or combo
        if combo ~= "" and REFUSED_KEYS[last:upper()] then return "key" end
        if TooLong(SHARE_FIELD_MAX, row.name) then return "length" end
        local items = type(row.items) == "table" and row.items or {}
        if #items > 60 then return "length" end
        for i = 1, #items do
            if type(items[i]) ~= "table" or TooLong(SHARE_FIELD_MAX, items[i].k, items[i].n) then
                return "length"
            end
        end
    end
    return nil
end

-- length-prefixed field: "<len>:<bytes>"
local function encS(s)
    s = tostring(s or "")
    return #s .. ":" .. s
end

local function decS(blob, pos)
    local colon = blob:find(":", pos, true)
    if not colon then return nil, pos end
    local len = tonumber(blob:sub(pos, colon - 1))
    if not len then return nil, pos end
    local val = blob:sub(colon + 1, colon + len)
    return val, colon + 1 + len
end

-- One code family: theme codes (ThemeShare) frame their fields the same way.
ns.ShareCodec = { base64enc = base64enc, base64dec = base64dec, encS = encS, decS = decS }

function Shortkeys:ExportList()
    local out = {}
    self:ForEach(function(rowKey, info, isChar)
        out[#out + 1] = { k = rowKey, b = info.key, n = info.name, c = isChar }
    end)
    return out
end

-- True if binding this row would displace something the user already has: the
-- row already carries a shortkey, or the combo is taken by another row.
function Shortkeys:ImportWouldOverride(rowKey, combo)
    if self:Get(rowKey) then return true end
    local taken = false
    self:ForEach(function(k, info)
        if not taken and k ~= rowKey and info.key == combo then taken = true end
    end)
    return taken
end

function Shortkeys:ImportList(list, skipExisting)
    if type(list) ~= "table" then return 0 end
    local n = 0
    for i = 1, #list do
        local r = list[i]
        if r and r.k and r.b and r.b ~= "" then
            if not (skipExisting and self:ImportWouldOverride(r.k, r.b)) then
                if self:SetByKey(r.k, r.n, r.c, r.b) then n = n + 1 end
            end
        end
    end
    return n
end

function Shortkeys:BuildExportString(which)
    which = which or "both"
    local parts = { "EFSK1", encS(which) }
    -- Rows the shared-code rules refuse stay home; the export dialog gets
    -- the list (label and reason) so the player knows which and why.
    local leftOut = {}
    local function Keep(section, list)
        local kept = {}
        for i = 1, #list do
            local why = Shortkeys.ShareRefusal(section, list[i])
            if why then
                leftOut[#leftOut + 1] = { section = section, label = ShareRowLabel(section, list[i]), reason = why, row = list[i] }
            else
                kept[#kept + 1] = list[i]
            end
        end
        return kept
    end

    local aliasList = {}
    if (which == "alias" or which == "both") and ns.Aliases and ns.Aliases.ExportList then
        aliasList = Keep("aliases", ns.Aliases:ExportList())
    end
    parts[#parts + 1] = encS(#aliasList)
    for i = 1, #aliasList do
        local r = aliasList[i]
        parts[#parts + 1] = encS(r.text)
        parts[#parts + 1] = encS(r.key)
        parts[#parts + 1] = encS(r.name)
    end

    local skList = {}
    if which == "shortkey" or which == "both" then
        skList = Keep("shortkeys", self:ExportList())
    end
    parts[#parts + 1] = encS(#skList)
    for i = 1, #skList do
        local r = skList[i]
        parts[#parts + 1] = encS(r.k)
        parts[#parts + 1] = encS(r.b)
        parts[#parts + 1] = encS(r.n)
        parts[#parts + 1] = encS(r.c and "1" or "0")
    end

    -- Third section, appended after the original two so old strings decode
    -- with zero blacklist entries and old clients ignore the trailing data.
    local blList = {}
    if which == "blacklist" and ns.Blacklist and ns.Blacklist.ExportList then
        blList = Keep("blacklist", ns.Blacklist:ExportList())
    end
    parts[#parts + 1] = encS(#blList)
    for i = 1, #blList do
        local r = blList[i]
        parts[#parts + 1] = encS(r.key)
        parts[#parts + 1] = encS(r.name)
        parts[#parts + 1] = encS(r.category or "")
    end

    -- Fourth section, snippets, appended for the same reason: plain text
    -- only (name, keyword, flat body).
    local snList = {}
    if which == "snippet" and ns.Snippets and ns.Snippets.ExportList then
        snList = Keep("snippets", ns.Snippets:ExportList())
    end
    parts[#parts + 1] = encS(#snList)
    for i = 1, #snList do
        local r = snList[i]
        parts[#parts + 1] = encS(r.name)
        parts[#parts + 1] = encS(r.keyword or "")
        parts[#parts + 1] = encS(r.body or "")
    end

    -- Fifth section, quicklists: name, key, hold, then the row keys and
    -- names; the rows resolve on the importer's side.
    local qlList = {}
    if which == "quicklist" and ns.QuicklistStore then
        qlList = Keep("quicklists", ns.QuicklistStore.ExportList())
    end
    parts[#parts + 1] = encS(#qlList)
    for i = 1, #qlList do
        local r = qlList[i]
        parts[#parts + 1] = encS(r.name)
        parts[#parts + 1] = encS(r.key or "")
        parts[#parts + 1] = encS(r.hold and "1" or "0")
        parts[#parts + 1] = encS(#r.items)
        for j = 1, #r.items do
            parts[#parts + 1] = encS(r.items[j].k)
            parts[#parts + 1] = encS(r.items[j].n or "")
        end
    end

    return "EF1!" .. base64enc(table.concat(parts)), #leftOut, leftOut
end

function Shortkeys:DecodeString(str)
    if type(str) ~= "string" then return nil end
    local b64 = strtrim(str):match("^EF1!(.+)$")
    if not b64 then return nil end
    local ok, blob = pcall(base64dec, b64)
    if not ok or type(blob) ~= "string" or blob:sub(1, 5) ~= "EFSK1" then return nil end

    -- The counts are attacker-controlled; a huge one would spin the loop even
    -- after decS runs out of blob. Cap it, and bail each loop the moment a
    -- field comes back nil (blob exhausted) so a malformed code can't freeze.
    local MAX_IMPORT_ROWS = 5000
    local pos = 6
    local _, aliasCountStr, skCountStr
    _, pos = decS(blob, pos) -- which marker (unused on import; caller picks)
    aliasCountStr, pos = decS(blob, pos)
    local aliasCount = tonumber(aliasCountStr) or 0
    if aliasCount > MAX_IMPORT_ROWS then aliasCount = MAX_IMPORT_ROWS end
    local aliases = {}
    for _ = 1, aliasCount do
        local text, key, name
        text, pos = decS(blob, pos)
        if not text then break end
        key, pos = decS(blob, pos)
        name, pos = decS(blob, pos)
        if key then aliases[#aliases + 1] = { text = text, key = key, name = name } end
    end

    skCountStr, pos = decS(blob, pos)
    local skCount = tonumber(skCountStr) or 0
    if skCount > MAX_IMPORT_ROWS then skCount = MAX_IMPORT_ROWS end
    local shortkeys = {}
    for _ = 1, skCount do
        local k, b, n, c
        k, pos = decS(blob, pos)
        if not k then break end
        b, pos = decS(blob, pos)
        n, pos = decS(blob, pos)
        c, pos = decS(blob, pos)
        if b then shortkeys[#shortkeys + 1] = { k = k, b = b, n = n, c = (c == "1") } end
    end

    local blCountStr
    blCountStr, pos = decS(blob, pos)
    local blCount = tonumber(blCountStr) or 0
    if blCount > MAX_IMPORT_ROWS then blCount = MAX_IMPORT_ROWS end
    local blacklist = {}
    for _ = 1, blCount do
        local key, name, category
        key, pos = decS(blob, pos)
        if not key then break end
        name, pos = decS(blob, pos)
        category, pos = decS(blob, pos)
        blacklist[#blacklist + 1] = {
            key = key, name = name,
            category = category ~= "" and category or nil,
        }
    end

    local snCountStr
    snCountStr, pos = decS(blob, pos)
    local snCount = tonumber(snCountStr) or 0
    if snCount > MAX_IMPORT_ROWS then snCount = MAX_IMPORT_ROWS end
    local snippets = {}
    for _ = 1, snCount do
        local name, keyword, body
        name, pos = decS(blob, pos)
        if not name then break end
        keyword, pos = decS(blob, pos)
        body, pos = decS(blob, pos)
        if body then snippets[#snippets + 1] = { name = name, keyword = keyword, body = body } end
    end

    local qlCountStr
    qlCountStr, pos = decS(blob, pos)
    local qlCount = tonumber(qlCountStr) or 0
    if qlCount > MAX_IMPORT_ROWS then qlCount = MAX_IMPORT_ROWS end
    local quicklists = {}
    for _ = 1, qlCount do
        local name, key, hold, itemCountStr
        name, pos = decS(blob, pos)
        if not name then break end
        key, pos = decS(blob, pos)
        hold, pos = decS(blob, pos)
        itemCountStr, pos = decS(blob, pos)
        local itemCount = tonumber(itemCountStr) or 0
        if itemCount > 200 then itemCount = 200 end
        local items = {}
        for _ = 1, itemCount do
            local k, n
            k, pos = decS(blob, pos)
            if not k then break end
            n, pos = decS(blob, pos)
            items[#items + 1] = { k = k, n = n }
        end
        quicklists[#quicklists + 1] = {
            name = name, key = key ~= "" and key or nil, hold = hold == "1", items = items,
        }
    end

    return { aliases = aliases, shortkeys = shortkeys, blacklist = blacklist, snippets = snippets,
             quicklists = quicklists }
end

-- The first section over its shared-code cap among those the importing
-- dialog would apply, as { section, count, cap }, or nil.
function Shortkeys:CheckImportLimits(decoded, which)
    if type(decoded) ~= "table" then return nil end
    which = which or "both"
    local checks = {
        { id = "aliases", on = which == "alias" or which == "both" },
        { id = "shortkeys", on = which == "shortkey" or which == "both" },
        { id = "blacklist", on = which == "blacklist" },
        { id = "snippets", on = which == "snippet" },
        { id = "quicklists", on = which == "quicklist" },
    }
    for i = 1, #checks do
        local c = checks[i]
        local list = decoded[c.id]
        if c.on and type(list) == "table" and #list > SHARE_CAPS[c.id] then
            return { section = c.id, count = #list, cap = SHARE_CAPS[c.id] }
        end
    end
    return nil
end

-- Returns the system-command slash a shortkey targets (e.g. "/logout"), or nil.
-- Command shortkeys store the literal slash as their display name (see
-- Search/Commands.lua), so match the name against the shared command set.
local function SystemCommandLabel(name)
    if type(name) ~= "string" then return nil end
    local cmds = ns.SYSTEM_COMMANDS
    if type(cmds) ~= "table" then return nil end
    local lower = strtrim(name):lower()
    for i = 1, #cmds do
        if lower == cmds[i] then return cmds[i] end
    end
    return nil
end


-- Inspect a decoded import against current data without applying it. Returns
-- an ordered list of conflicts (rows that would replace an existing entry,
-- each carrying its section and a display label), the new rows grouped by
-- section (imported unconditionally), the distinct system commands any
-- imported shortkey binds (session-disrupting warning), and the rows the
-- shared-code rules leave out, each with its reason. No side effects.
function Shortkeys:AnalyzeImport(decoded, which)
    which = which or "both"
    local conflicts = {}
    local newRows = { aliases = {}, shortkeys = {}, blacklist = {}, snippets = {}, quicklists = {} }
    local skipped = {}
    local disruptive, seenCmd = {}, {}
    local result = { conflicts = conflicts, newRows = newRows, disruptive = disruptive, skipped = skipped }
    if type(decoded) ~= "table" then return result end

    local function Refused(section, row, label)
        local why = Shortkeys.ShareRefusal(section, row)
        if why then skipped[#skipped + 1] = { section = section, label = label, reason = why } end
        return why ~= nil
    end

    if (which == "alias" or which == "both") and decoded.aliases then
        for i = 1, #decoded.aliases do
            local r = decoded.aliases[i]
            if r and r.text and strtrim(r.text) ~= "" and r.key
               and not Refused("aliases", r, AliasRowLabel(r)) then
                if ns.Aliases and ns.Aliases:HasAlias(r.text) then
                    conflicts[#conflicts + 1] = { section = "aliases", row = r, label = AliasRowLabel(r) }
                else
                    newRows.aliases[#newRows.aliases + 1] = r
                end
            end
        end
    end

    if (which == "shortkey" or which == "both") and decoded.shortkeys then
        for i = 1, #decoded.shortkeys do
            local r = decoded.shortkeys[i]
            if r and r.k and r.b and r.b ~= "" and not Refused("shortkeys", r, ShortkeyRowLabel(r)) then
                if self:ImportWouldOverride(r.k, r.b) then
                    conflicts[#conflicts + 1] = { section = "shortkeys", row = r, label = ShortkeyRowLabel(r) }
                else
                    newRows.shortkeys[#newRows.shortkeys + 1] = r
                end
                local cmd = SystemCommandLabel(r.n)
                if cmd and not seenCmd[cmd] then
                    seenCmd[cmd] = true
                    disruptive[#disruptive + 1] = cmd
                end
            end
        end
    end

    if which == "blacklist" and decoded.blacklist then
        for i = 1, #decoded.blacklist do
            local r = decoded.blacklist[i]
            if r and r.key and not Refused("blacklist", r, r.name or "?") then
                if ns.Blacklist and ns.Blacklist:Has(r.key) then
                    conflicts[#conflicts + 1] = { section = "blacklist", row = r, label = r.name or "?" }
                else
                    newRows.blacklist[#newRows.blacklist + 1] = r
                end
            end
        end
    end

    if which == "snippet" and decoded.snippets then
        for i = 1, #decoded.snippets do
            local r = decoded.snippets[i]
            if r and type(r.name) == "string" and strtrim(r.name) ~= ""
               and not Refused("snippets", r, SnippetRowLabel(r)) then
                -- A snippet clashes on its name or on its keyword: keywords
                -- are unique, so an import with one that exists replaces it.
                local clash = ns.Snippets and ns.Snippets.FindConflict and ns.Snippets:FindConflict(r.name, r.keyword)
                if clash then
                    conflicts[#conflicts + 1] = { section = "snippets", row = r, label = SnippetRowLabel(r) }
                else
                    newRows.snippets[#newRows.snippets + 1] = r
                end
            end
        end
    end

    if which == "quicklist" and decoded.quicklists then
        for i = 1, #decoded.quicklists do
            local r = decoded.quicklists[i]
            if r and type(r.name) == "string" and strtrim(r.name) ~= ""
               and not Refused("quicklists", r, r.name) then
                if ns.QuicklistStore and ns.QuicklistStore.FindByName(r.name) then
                    conflicts[#conflicts + 1] = { section = "quicklists", row = r, label = r.name }
                else
                    newRows.quicklists[#newRows.quicklists + 1] = r
                end
            end
        end
    end

    return result
end

-- Apply an already-decoded import. skipExisting=true keeps existing rows and
-- adds only new ones (the "Skip" choice); default overwrites (the "Replace"
-- choice). Returns aliasCount, shortkeyCount, blacklistCount applied.
function Shortkeys:ApplyDecoded(decoded, which, skipExisting)
    if type(decoded) ~= "table" then return nil end
    which = which or "both"
    local na, nk, nb = 0, 0, 0
    if (which == "alias" or which == "both") and ns.Aliases and ns.Aliases.ImportList then
        na = ns.Aliases:ImportList(decoded.aliases, skipExisting)
    end
    if which == "shortkey" or which == "both" then
        nk = self:ImportList(decoded.shortkeys, skipExisting)
    end
    if which == "blacklist" and ns.Blacklist and ns.Blacklist.ImportList then
        nb = ns.Blacklist:ImportList(decoded.blacklist, skipExisting)
    end
    local nsn = 0
    if which == "snippet" and ns.Snippets and ns.Snippets.ImportList then
        nsn = ns.Snippets:ImportList(decoded.snippets, skipExisting)
    end
    local nq = 0
    if which == "quicklist" and ns.QuicklistStore then
        nq = ns.QuicklistStore.ImportList(decoded.quicklists, skipExisting)
        if ns.Quicklists then ns.Quicklists:Changed() end
    end
    if ns.RefreshBindTables then ns.RefreshBindTables() end
    return na, nk, nb, nsn, nq
end

-- Write a resolved import. applySet.{aliases,shortkeys,blacklist} hold the rows
-- to write (the new rows plus the conflicts the user chose to replace); skipped
-- conflicts were never added, so this overwrites unconditionally. Returns
-- aliasCount, shortkeyCount, blacklistCount applied.
function Shortkeys:ApplyResolvedImport(applySet)
    if type(applySet) ~= "table" then return 0, 0, 0 end
    local na, nb = 0, 0
    if ns.Aliases and ns.Aliases.ImportList then
        na = ns.Aliases:ImportList(applySet.aliases, false)
    end
    local nk = self:ImportList(applySet.shortkeys, false)
    if ns.Blacklist and ns.Blacklist.ImportList then
        nb = ns.Blacklist:ImportList(applySet.blacklist, false)
    end
    local nsn = 0
    if ns.Snippets and ns.Snippets.ImportList then
        nsn = ns.Snippets:ImportList(applySet.snippets, false)
    end
    local nq = 0
    if ns.QuicklistStore and applySet.quicklists then
        nq = ns.QuicklistStore.ImportList(applySet.quicklists, false)
        if ns.Quicklists then ns.Quicklists:Changed() end
    end
    if ns.RefreshBindTables then ns.RefreshBindTables() end
    return na, nk, nb, nsn, nq
end

-- Returns aliasCount, shortkeyCount, blacklistCount applied, or nil on a
-- bad string.
function Shortkeys:ApplyImportString(str, which, skipExisting)
    local decoded = self:DecodeString(str)
    if not decoded then return nil end
    return self:ApplyDecoded(decoded, which, skipExisting)
end

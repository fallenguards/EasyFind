local _, ns = ...

local Utils = ns.Utils
local L = ns.L
local slower, sfind = Utils.slower, Utils.sfind

-- EasyFind.API: what extensions are built on, EasyFind's own included
-- (API/README.md). VERSION rises only for a change that breaks an extension;
-- MINOR for an addition.
local API = { VERSION = 1, MINOR = 0 }
EasyFind.API = API

local Extensions = { byID = {}, order = {} }
ns.Extensions = Extensions

-- Ids EasyFind keeps for itself: the menu's own settings page, groups,
-- single quicklists.
local RESERVED = { menu = true }

-- A stored copy of an extension (a shortkey's snapshot) from before the
-- registry kept a flag per extension, never its id.
local LEGACY_FLAGS = {
    calculatorLauncher = "calculator", iconSearchLauncher = "icons", snippetsLauncher = "snippets",
    clipboardLauncher = "clipboard", notesLauncher = "notes", gpsLauncher = "gps",
    quicklistsLauncher = "quicklists", chatLauncher = "chat",
}
Extensions.LEGACY_FLAGS = LEGACY_FLAGS

local FIELDS = {
    id = "string", name = "string", description = "string", icon = "texture", iconCoords = "table",
    addon = "string", loadInCombat = "boolean", loadAtLogin = "boolean", open = "function", close = "function",
    isOpen = "function", menu = "function", settings = "function", keywords = "table",
    hideFromSearch = "boolean", experimental = "string", scope = "string",
}

local function Fail(fn, msg) error("EasyFind.API." .. fn .. ": " .. msg, 3) end

local function Report(err) return geterrorhandler()(err) end

-- An extension's own code: its error reaches the error frame, EasyFind
-- goes on. Returns ok and the first result.
local function Run(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, result = xpcall(fn, Report, ...)
    return ok, result
end
Extensions.Run = Run

local function CheckFields(fn, def)
    for k, v in pairs(def) do
        local want = FIELDS[k]
        if want == "texture" then
            if type(v) ~= "string" and type(v) ~= "number" then Fail(fn, "icon must be a texture path or file id") end
        elseif want and type(v) ~= want then
            Fail(fn, k .. " must be a " .. want)
        end
    end
end

local function RefreshSurfaces()
    if ns.AppsMenu and ns.AppsMenu.Rebuild then ns.AppsMenu:Rebuild() end
    if ns.ExtensionButtons and ns.ExtensionButtons.RefreshAll then ns.ExtensionButtons:RefreshAll() end
end

function Extensions.Get(id) return id and Extensions.byID[id] or nil end

-- Registered, and its addon (if any) enabled in the AddOns list.
function Extensions.Available(def)
    if not def or not def.name then return false end
    return not def.addon or not ns.IsCompanionLoadable or ns.IsCompanionLoadable(def.addon) or false
end

-- The one row that stands for an extension everywhere: the menu tile, its
-- button on screen, its launcher row in the results.
function Extensions.Entry(id)
    local def = Extensions.byID[id]
    if not def then return nil end
    local entry = def._entry
    if not entry then
        entry = {
            extensionID = id, noPin = true, noLearn = true,
            nativeRun = function() Extensions.Launch(id) end,
        }
        def._entry = entry
    end
    entry.name, entry.nameLower = def.name, def.name and slower(def.name)
    entry.icon, entry.iconCoords = def.icon, def.iconCoords
    entry.experimental = def.experimental
    -- A row key (shortkeys, aliases) names an entry by path and name: a
    -- bundled extension keeps the one its keys were saved under.
    entry.path = def._path
    return entry
end

function Extensions.Entries()
    local out = {}
    for _, id in ipairs(Extensions.order) do
        local def = Extensions.byID[id]
        if Extensions.Available(def) then out[#out + 1] = Extensions.Entry(id) end
    end
    return out
end

-- Typing an extension's name or one of its words (3 letters or more)
-- offers its launcher row.
function Extensions.LauncherMatches(text, out)
    if not text or #text < 3 then return out end
    local q = slower(text)
    for _, id in ipairs(Extensions.order) do
        local def = Extensions.byID[id]
        if not def.hideFromSearch and Extensions.Available(def) then
            local hit = def.name and sfind(slower(def.name), q, 1, true)
            for i = 1, def.keywords and #def.keywords or 0 do
                hit = hit or sfind(slower(def.keywords[i]), q, 1, true)
            end
            if hit then out[#out + 1] = Extensions.Entry(id) end
        end
    end
    return out
end

local function QuickFilterKey()
    local Filters = ns.Filters
    local qf = Filters and Filters.GetQuickFilter and Filters:GetQuickFilter()
    local rf = ns.Search and ns.Search.GetResultsFrame and ns.Search:GetResultsFrame()
    return qf and rf and rf:IsShown() and qf.key or nil
end

function Extensions.IsOpen(id)
    local def = Extensions.byID[id]
    if not def then return false end
    if def.isOpen then
        local ok, open = Run(def.isOpen)
        return ok and open and true or false
    end
    if def.scope then return QuickFilterKey() == def.scope end
    if def.settings then return API.IsSettingsOpen(id) end
    return false
end

function Extensions.Close(id)
    local def = Extensions.byID[id]
    if not def then return end
    if def.close then Run(def.close) return end
    if def.scope then
        if ns.Filters and ns.Filters.ClearQuickFilter then ns.Filters:ClearQuickFilter(false) end
        if ns.Results and ns.Results.HideResults then ns.Results:HideResults() end
        return
    end
    if def.settings then API.CloseSettings() end
end

-- The extension whose surface is the results list (its scope's pill is
-- up), for the outside-click closers.
function Extensions.ScopeShowing()
    local key = QuickFilterKey()
    if not key then return nil end
    for _, id in ipairs(Extensions.order) do
        if Extensions.byID[id].scope == key then return id end
    end
    return nil
end

-- A load-on-demand extension's addon, loaded if it can be now.
local function LoadAddon(def)
    if not (def and def.addon and C_AddOns and C_AddOns.LoadAddOn) then return end
    if C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(def.addon) then return end
    if InCombatLockdown() and not def.loadInCombat then return end
    pcall(C_AddOns.LoadAddOn, def.addon)
end

-- Loads the extension's addon when it has not loaded yet; true when it
-- can open now.
function Extensions.Load(id)
    local def = Extensions.byID[id]
    if not def then return false end
    -- Its window or list comes with its addon: a settings page registered
    -- before it (Notes') is no reason to leave the addon unloaded.
    if not (def.open or def.scope) and def.addon and not (InCombatLockdown() and not def.loadInCombat) then
        LoadAddon(def)
        def = Extensions.byID[id]
    end
    if def.open or def.settings or def.scope then return true end
    if not def.addon or (InCombatLockdown() and not def.loadInCombat) then return false end
    local title = C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(def.addon, "Title") or def.addon
    EasyFind:Print(L["COMPANION_INCOMPLETE_FMT"]:format(title))
    return false
end

-- Extensions that work unopened (Chat records as messages come): their
-- addon loaded as the game comes up, where it is enabled.
function Extensions.LoadAtLogin()
    for _, id in ipairs(Extensions.order) do
        local def = Extensions.byID[id]
        if def.loadAtLogin and Extensions.Available(def) then LoadAddon(def) end
    end
end

function Extensions.Launch(id)
    if not Extensions.Load(id) then return false end
    local def = Extensions.byID[id]
    if def.open then return (Run(def.open)) end
    -- A list is the extension itself; its settings stay in its menu.
    if def.scope then return API.ShowScope(def.scope) end
    if def.settings then return API.OpenSettings(id) end
    return false
end

-- ==== the settings page kit ==================================================
-- What a settings(page, kit) builder gets: the options panel's own controls.
local kitNames = 0
local function Kit(ctx)
    local kit = { ROW_WIDTH = ctx.SELECTOR_ROW_W, BUTTON_WIDTH = ctx.SELECTOR_BTN_W }
    -- The page's title and a line under it; returns what to anchor below.
    function kit.Title(parent, title, hint)
        local head = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        head:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -8)
        head:SetText(title)
        if not hint then return head end
        local line = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -6)
        line:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
        line:SetJustifyH("LEFT")
        line:SetText(hint)
        return line
    end
    -- An extension's get runs guarded: its error never breaks the panel.
    local function Read(get)
        return function()
            local _, value = Run(get)
            return value
        end
    end
    -- Full-width rows, the switch starting where the dropdowns start.
    function kit.Checkbox(parent, label, get, set, tooltip)
        local box = ctx.CreateCheckbox(parent, nil, label, tooltip, true, ctx.SELECTOR_ROW_W,
            ctx.SELECTOR_ROW_W - 8 - ctx.SELECTOR_BTN_W)
        box:SetChecked(Read(get)() and true or false)
        if box.RefreshVisual then box:RefreshVisual() end
        box:SetScript("OnClick", function(self)
            if self.RefreshVisual then self:RefreshVisual() end
            Run(set, self:GetChecked() and true or false)
        end)
        return box
    end
    function kit.Choice(parent, label, choices, get, set, tooltip, default)
        kitNames = kitNames + 1
        return ctx.CreateFlyoutPresetRow(parent, label, choices, Read(get), function(v) Run(set, v) end,
            "EasyFindExtChoice" .. kitNames, default, tooltip)
    end
    function kit.Stepper(parent, label, min, max, step, get, set, tooltip, width)
        return ctx.CreateStepperRow(parent, label, min, max, Read(get), function(v) Run(set, v) end, tooltip, width, step)
    end
    -- One of the addon's key bindings (its Bindings.xml action), set on the
    -- extension's own page as on the general one: a click captures a key,
    -- a right-click unbinds.
    function kit.Keybind(parent, label, action, tooltip)
        local row = CreateFrame("Frame", nil, parent)
        row:SetSize(ctx.SELECTOR_ROW_W, 24)
        local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", row, "LEFT", 8, 0)
        text:SetPoint("RIGHT", row, "RIGHT", -ctx.SELECTOR_BTN_W - 18, 0)
        text:SetJustifyH("LEFT")
        text:SetText(label .. ":")
        local btn = ns.CreateModernButton(row)
        btn:SetNormalFontObject("GameFontHighlightSmall")
        btn:SetHighlightFontObject("GameFontHighlightSmall")
        ns.StyleBgFillButton(btn)
        btn:SetSize(ctx.SELECTOR_BTN_W, 20)
        btn:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        btn:SetText(ctx.GetCurrentKeybindText(action))
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetScript("OnClick", function(self, button)
            -- The release of a click that closed a flyout is no click here.
            if ns._efFlyoutClosedAt and GetTime() - ns._efFlyoutClosedAt < 0.30 then return end
            if button == "RightButton" then
                EasyFind:SetAccountKeybind(action, nil)
                self:SetText(_G["NOT_BOUND"] or "Not Bound")
            else
                ctx.StartCapture(self, action)
            end
        end)
        if tooltip then ctx.MakeKeybindTooltip(btn, label, tooltip) end
        row.button = btn
        return row
    end
    return kit
end

-- ==== public: extensions =====================================================

-- def: id (required, stable: layouts and buttons save it), name and icon
-- (required the first time; the icon is painted in the theme's icon
-- color), iconCoords, description, addon (a load-on-demand addon loaded
-- on first open), loadAtLogin (loaded at login instead: it works unopened),
-- loadInCombat, open, close, isOpen, menu (rows for its right-click menu),
-- settings(page, kit), keywords, hideFromSearch, experimental, scope (its
-- surface is that @scope's list in the results).
-- Registering an id again adds to it: a stub's tile, then the rest.
function API.RegisterExtension(def)
    if type(def) ~= "table" then Fail("RegisterExtension", "expects a table") end
    local id = def.id
    if type(id) ~= "string" or not id:match("^[%w_%-]+$") then
        Fail("RegisterExtension", "id must be letters, digits, - or _")
    end
    if RESERVED[id] then Fail("RegisterExtension", "id '" .. id .. "' is taken by EasyFind") end
    CheckFields("RegisterExtension", def)
    local rec = Extensions.byID[id]
    if not rec then
        if type(def.name) ~= "string" then Fail("RegisterExtension", "name is required") end
        if def.icon == nil then Fail("RegisterExtension", "icon is required") end
        rec = {}
        Extensions.byID[id] = rec
        Extensions.order[#Extensions.order + 1] = id
    end
    for k, v in pairs(def) do rec[k] = v end
    if def.settings and ns.RegisterExtensionPage then
        ns.RegisterExtensionPage({
            id = id, name = rec.name, icon = rec.icon, coords = rec.iconCoords, companion = rec.addon,
            build = function(page, ctx) Run(rec.settings, page, Kit(ctx)) end,
        })
    end
    RefreshSurfaces()
    return true
end

function API.IsExtensionRegistered(id) return Extensions.byID[id] ~= nil end

function API.OpenExtension(id) return Extensions.Launch(id) end
function API.CloseExtension(id) Extensions.Close(id) end
function API.IsExtensionOpen(id) return Extensions.IsOpen(id) end

function API.ToggleExtension(id)
    if Extensions.IsOpen(id) then
        Extensions.Close(id)
        return false
    end
    return Extensions.Launch(id)
end

-- Call when the extension's own window shows or hides, so a button on the
-- game's menu bar shows it pressed or not.
function API.NotifyOpenChanged(id)
    if ns.ExtensionButtons and ns.ExtensionButtons.RefreshOpenStates then ns.ExtensionButtons:RefreshOpenStates() end
end

-- A count on the extension's icon (unread messages): 0 or nil clears it.
function API.SetBadge(id, count)
    if ns.SetApplicationBadge then ns.SetApplicationBadge(id, count) end
end

-- ==== search providers ========================================================

local Providers = { byKey = {}, byCategory = {} }
Extensions.Providers = Providers

local PROVIDER_FIELDS = {
    key = "string", label = "string", category = "string", icon = "texture", iconCoords = "table",
    words = "table", eager = "boolean", lazy = "boolean", lowResults = "boolean",
    aliases = "table", options = "table", rows = "function", select = "function", tooltip = "function",
    leave = "function", extension = "string", loadOnSearch = "any", hint = "any", browse = "function",
    place = "function", link = "table", menu = "function",
}

function Extensions.Provider(key) return key and Providers.byKey[key] or nil end
function Extensions.ProviderOf(data) return data and data.category and Providers.byCategory[data.category] or nil end

-- A provider's rows into the search data. Its extension's addon loads
-- first when it asks to be (loadOnSearch) and has not yet.
local function Populate(key, database)
    local p = Providers.byKey[key]
    if not p.rows and p.extension then
        local load = p.loadOnSearch
        if type(load) == "function" then
            local ok, want = Run(load)
            load = ok and want
        end
        if load then Extensions.Load(p.extension) end
    end
    local rows
    if p.rows then
        local ok, got = Run(p.rows)
        rows = ok and type(got) == "table" and got or nil
    end
    -- Search matches the lowercased name and words: filled in when a row
    -- does not carry them.
    for i = 1, rows and #rows or 0 do
        local row = rows[i]
        row.category = p.category
        if not row.nameLower and type(row.name) == "string" then row.nameLower = slower(row.name) end
        if row.keywords and not row.keywordsLower then
            local low = {}
            for k = 1, #row.keywords do low[k] = slower(tostring(row.keywords[k])) end
            row.keywordsLower = low
        end
    end
    return database:ReplaceCategoryEntries(p.category, rows)
end

-- An option row on an EasyFind.db switch that is on unless set false.
function Extensions.DbOption(key, label, tooltip, onChange)
    return {
        label = label, tooltip = tooltip,
        get = function() return EasyFind.db[key] ~= false end,
        set = function(on)
            EasyFind.db[key] = on
            if onChange then onChange(on) end
        end,
    }
end

-- A click on a provider's row: its select(row), on a copy (finishing the
-- selection may recycle the row). False when it is no provider's.
function Extensions.SelectRow(data, finish)
    local p = Extensions.ProviderOf(data)
    if not p then return false end
    if not p.select and p.extension then Extensions.Load(p.extension) end
    if not p.select then return false end
    local row = {}
    for k, v in pairs(data) do row[k] = v end
    finish()
    Run(p.select, row)
    return true
end

-- ==== public: search ==========================================================

-- def: key (required, stable: the filter and @scope key), label
-- and icon (required the first time; its extension's icon when it has
-- none), category (the name its rows carry; key when not given),
-- iconCoords, words (typing one loads the
-- rows), eager (small: searched from the first keystroke), lazy (only by
-- its words, its filter or its scope), lowResults (also when a search
-- finds little), aliases (an @scope: "@" and one of these lists only its
-- rows), options (its filter row's toggles: { label, tooltip, get, set },
-- { header = text }, { separator = true }), rows() -> list of
-- { name, icon, ... }, select(row), tooltip(row, tooltip) -> true when
-- it filled it, leave(row), extension (the extension whose addon holds
-- the rest), loadOnSearch (true or a function: load that addon for
-- search), hint (what a row's gestures do, under its name on hover: a
-- sentence, { click, alt, ctrl, shift }, or a function of the row giving
-- either; a row's own hint wins), browse(row) -> whether the row is in
-- the scope's list when nothing is typed (every row without it),
-- place(row) -> { name, mapID, x, y, step } where the row is now: its
-- rows are then found from the map search and the GPS too (a row's
-- mapID names the map it is on, for the map's own list), link = { key
-- = fn(row) -> string, resolve = fn(tail) -> row } (a row's EasyFind
-- link carries key(row); the receiver's copy resolves it to a row of its
-- own, the sender's data in it), menu(row) -> rows for the result's
-- right-click menu, in the tile menu's shape. Registering a key again
-- adds to it.
function API.RegisterSearchProvider(def)
    if type(def) ~= "table" then Fail("RegisterSearchProvider", "expects a table") end
    local key = def.key
    if type(key) ~= "string" or not key:match("^[%w_%-]+$") then
        Fail("RegisterSearchProvider", "key must be letters, digits, - or _")
    end
    for k, v in pairs(def) do
        local want = PROVIDER_FIELDS[k]
        if want == "texture" then
            if type(v) ~= "string" and type(v) ~= "number" then Fail("RegisterSearchProvider", "icon must be a texture path or file id") end
        elseif want and want ~= "any" and type(v) ~= want then
            Fail("RegisterSearchProvider", k .. " must be a " .. want)
        end
    end
    if def.link and not (type(def.link.key) == "function" and type(def.link.resolve) == "function") then
        Fail("RegisterSearchProvider", "link needs key(row) and resolve(tail) functions")
    end
    local p = Providers.byKey[key]
    if p then
        for k, v in pairs(def) do
            if k ~= "category" then p[k] = v end
        end
    else
        if type(def.label) ~= "string" then Fail("RegisterSearchProvider", "label is required") end
        local owner = Extensions.Get(def.extension)
        if def.icon == nil and not (owner and owner.icon) then
            Fail("RegisterSearchProvider", "icon is required (or an extension that has one)")
        end
        -- Its extension's addon turned off in the AddOns list: no filter
        -- row or scope for results that can never come.
        if owner and not Extensions.Available(owner) then return false end
        local category = def.category or key
        if ns.CategoryMap.ProviderCategory[key] or Providers.byCategory[category] then
            Fail("RegisterSearchProvider", "key '" .. key .. "' is taken")
        end
        p = {}
        for k, v in pairs(def) do p[k] = v end
        if p.icon == nil then p.icon, p.iconCoords = owner.icon, owner.iconCoords end
        p.category = category
        Providers.byKey[key], Providers.byCategory[category] = p, p
        ns.CategoryMap.Add({ key = key, parent = "extensions", categories = { category } })
        ns.Database:AddDynamicProvider({
            key = key, category = category, eager = p.eager, lazy = p.lazy,
            fn = function(database) return Populate(key, database) end,
        })
        ns.SearchEngine:AddProvider({ key = key, words = p.words or {}, loadOnLowResults = p.lowResults })
        ns.Filters.AddExtensionFilter({
            key = key, label = p.label, iconTex = p.icon, iconCoords = p.iconCoords, glyph = true,
            hasOptions = p.options ~= nil, checkboxOptions = p.options,
        })
        if p.aliases then
            ns.Filters:AddQuickFilter({ key = key, canonical = key, label = p.label, categories = { category }, aliases = p.aliases })
        end
    end
    p.glyph = { tex = p.icon, coords = p.iconCoords, chromeTint = true }
    -- Its links: "<key>:<tail>" resolves through its own resolve, the
    -- row it gives carrying its category so its tooltip and select apply.
    if p.link and ns.Aliases and ns.Aliases.RegisterKeyResolver then
        ns.Aliases:RegisterKeyResolver(key, function(full)
            local link = p.link
            if not link then return nil end
            local ok, row = Run(link.resolve, full:sub(#key + 2))
            if not (ok and type(row) == "table") then return nil end
            if row.category == nil then row.category = p.category end
            return row
        end)
    end
    return true
end

-- The rows changed: rebuilt now, and an open search shows them.
function API.RefreshSearchProvider(key)
    if ns.Database and ns.Database.RefreshDynamicCategory then ns.Database:RefreshDynamicCategory(key) end
end

-- Opens the search bar on an @scope's list (its pill in), text typed after
-- it. A frame later: a launch from a result row closes the bar first.
function API.ShowScope(key, text)
    Utils.SafeAfter(0, function()
        local Search = ns.Search
        if Search and Search.Show then Search:Show(false) end
        local frame = Search and Search.GetSearchFrame and Search:GetSearchFrame()
        local defs = ns.Filters and ns.Filters.quickFilterOptions
        if not (frame and frame:IsShown() and defs) then return end
        for i = 1, #defs do
            if defs[i].key == key then
                ns.Filters:ApplyQuickFilter(defs[i], text or "")
                return
            end
        end
    end)
    return true
end

-- Shows the search bar focused, with this text searched when given.
function API.OpenSearch(text)
    local Search = ns.Search
    if not (Search and Search.Show) then return false end
    Search:Show(true)
    if type(text) == "string" and text ~= "" then
        Utils.SafeAfter(0, function()
            local frame = Search:GetSearchFrame()
            local box = frame and frame:IsShown() and frame.editBox
            if not box then return end
            box:SetText(text)
            box:SetCursorPosition(#text)
        end)
    end
    return true
end

-- ==== public: theme and look ===================================================

-- The theme's colors by role; r, g, b, a.
local THEME_SLOTS = {
    background = "windowFill", panel = "backdropColor", border = "backdropBorder", line = "separator",
    text = "leafColor", textDim = "textFaint", heading = "pathColor", accent = "accent",
    selection = "selection", glyph = "chromeGlyph",
}

function API.GetThemeColor(role)
    local slot = THEME_SLOTS[role]
    if not slot then Fail("GetThemeColor", "no color named '" .. tostring(role) .. "'") end
    local palette = ns.ACTIVE_UI_PALETTE or (ns.UI_THEME_PALETTES and ns.UI_THEME_PALETTES.Black) or {}
    local c = palette[slot] or { 1, 1, 1 }
    return c[1], c[2], c[3], c[4] or 1
end

-- A light theme wants dark text and icons.
function API.IsLightTheme()
    local palette = ns.ACTIVE_UI_PALETTE
    return palette ~= nil and palette.light == true
end

-- fn() runs after the user picks another theme.
function API.OnThemeChanged(fn)
    if type(fn) ~= "function" then Fail("OnThemeChanged", "expects a function") end
    ns.RegisterThemeCallback(function() Run(fn) end)
end

-- Gives a frame EasyFind's panel look: rounded border and the theme's
-- fill, following theme and opacity changes.
function API.StylePanel(frame)
    if type(frame) ~= "table" or not frame.CreateTexture then Fail("StylePanel", "expects a frame") end
    ns.StyleMenuPanel(frame)
    return frame
end

-- A button in EasyFind's look.
function API.CreateButton(parent, text, width, height)
    return ns.CreateModernButton(parent, text, width or 120, height or 22)
end

-- A confirm or input dialog in EasyFind's look. opts: text, acceptText,
-- cancelText, hasEditBox, editBoxDefault, onAccept(value), single (one
-- button only).
function API.ShowDialog(opts)
    if type(opts) ~= "table" then Fail("ShowDialog", "expects a table") end
    local onAccept = opts.onAccept
    ns.ShowThemedDialog({
        text = opts.text, acceptText = opts.acceptText, cancelText = opts.cancelText,
        hasEditBox = opts.hasEditBox, editBoxDefault = opts.editBoxDefault, single = opts.single,
        onAccept = onAccept and function(value) Run(onAccept, value) end,
    })
end

-- ==== public: extensions talking to each other =================================

local actions = {}     -- extension id -> action name -> function
local listeners = {}   -- "id:event" -> list of functions
Extensions.actions, Extensions.listeners = actions, listeners   -- dev tools

local function CheckName(fn, what, v)
    if type(v) ~= "string" or v == "" then Fail(fn, what .. " must be a string") end
end

-- An action other extensions call by name: CallAction(id, name, ...).
function API.RegisterAction(id, name, fn)
    CheckName("RegisterAction", "id", id)
    CheckName("RegisterAction", "name", name)
    if type(fn) ~= "function" then Fail("RegisterAction", "fn must be a function") end
    actions[id] = actions[id] or {}
    actions[id][name] = fn
end

function API.HasAction(id, name)
    local own = actions[id]
    return own ~= nil and own[name] ~= nil
end

local function Results(ok, ...)
    if ok then return ... end
end

-- Loads the extension's addon if it loads on demand; true when the
-- extension is registered and its addon (if any) is in.
function API.LoadExtension(id)
    local def = Extensions.byID[id]
    if not def then return false end
    LoadAddon(def)
    return not def.addon or not (C_AddOns and C_AddOns.IsAddOnLoaded) or C_AddOns.IsAddOnLoaded(def.addon) or false
end

-- Runs another extension's action and returns what it returns: nothing
-- when it has none (or it failed; the error reaches the error frame). One
-- that loads on demand is loaded first.
function API.CallAction(id, name, ...)
    local own = actions[id]
    if not (own and own[name]) then
        LoadAddon(Extensions.byID[id])
        own = actions[id]
        if not (own and own[name]) then return nil end
    end
    return Results(xpcall(own[name], Report, ...))
end

-- fn(...) runs each time the extension fires the event.
function API.On(id, event, fn)
    CheckName("On", "id", id)
    CheckName("On", "event", event)
    if type(fn) ~= "function" then Fail("On", "fn must be a function") end
    local key = id .. ":" .. event
    listeners[key] = listeners[key] or {}
    local list = listeners[key]
    list[#list + 1] = fn
end

function API.Off(id, event, fn)
    local list = listeners[tostring(id) .. ":" .. tostring(event)]
    for i = #(list or {}), 1, -1 do
        if list[i] == fn then table.remove(list, i) end
    end
end

-- Tells every listener the extension's event happened.
function API.Fire(id, event, ...)
    local list = listeners[tostring(id) .. ":" .. tostring(event)]
    if not list then return end
    for i = 1, #list do Run(list[i], ...) end
end

-- ==== public: settings ========================================================

-- Opens the options panel's Extensions tab at this extension's page.
function API.OpenSettings(id)
    if not (ns.RequestOptionsPanel and ns.RequestOptionsPanel()) then return false end
    if ns.Options and ns.Options.OpenAtExtension then ns.Options:OpenAtExtension(id) end
    return true
end

-- A frame that belongs with the game's chat (an opener beside it): hidden
-- and shown along with the chat frames by the "Toggle Chat Frame" entry.
function API.RegisterChatPiece(frame)
    if type(frame) ~= "table" or not frame.Hide then Fail("RegisterChatPiece", "expects a frame") end
    ns.chatPieces = ns.chatPieces or {}
    ns.chatPieces[frame] = true
    if EasyFind.db and EasyFind.db.chatFramesHidden then EasyFind:RestoreChatFramesHidden() end
end

function API.IsSettingsOpen(id)
    local frame = ns.optionsFrame
    return frame ~= nil and frame:IsShown() and ns.Options ~= nil and ns.Options.CurrentExtensionPage ~= nil
        and ns.Options:CurrentExtensionPage() == id
end

function API.CloseSettings()
    if ns.Options and ns.Options.Hide then ns.Options:Hide() end
end

-- Your own window's settings, found from the search bar: rows() returns
-- a list of { name, path, keywords, open }. name is the setting's label,
-- path where it sits in your window (a string or a list of names),
-- keywords more words that find it, open() shows your window at it.
-- Read when the search first needs it. addon is your name as the game's
-- AddOns list shows it, so one filter row covers both.
function API.RegisterSettingsIndex(addon, rows)
    if type(addon) ~= "string" or addon == "" then Fail("RegisterSettingsIndex", "addon must be a name") end
    if type(rows) ~= "function" then Fail("RegisterSettingsIndex", "rows must be a function") end
    ns.settingsFeeds = ns.settingsFeeds or {}
    ns.settingsFeeds[addon] = rows
    if ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.PullSettingsFeed then ns.BlizzOptionsSearch:PullSettingsFeed(addon) end
    return true
end

-- Its rows changed: read again.
function API.RefreshSettingsIndex(addon)
    if ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.PullSettingsFeed then ns.BlizzOptionsSearch:PullSettingsFeed(addon) end
end

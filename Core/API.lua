local _, ns = ...

local Utils = ns.Utils
local L = ns.L
local slower, sfind = Utils.slower, Utils.sfind

-- EasyFind.API: what extensions are built on, EasyFind's own included
-- (docs/API.md). VERSION rises only for a change that breaks an extension;
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
    tint = "boolean", addon = "string", loadInCombat = "boolean", open = "function", close = "function",
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
    return not def.addon or (ns.IsCompanionLoadable and ns.IsCompanionLoadable(def.addon)) or false
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
    entry.icon, entry.iconCoords, entry.iconTint = def.icon, def.iconCoords, def.tint
    entry.experimental = def.experimental
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

-- Loads the extension's addon when it has not loaded yet; true when it
-- can open now.
function Extensions.Load(id)
    local def = Extensions.byID[id]
    if not def then return false end
    if def.open or def.settings or def.scope then return true end
    if not def.addon or not (C_AddOns and C_AddOns.LoadAddOn) then return false end
    if InCombatLockdown() and not def.loadInCombat then return false end
    pcall(C_AddOns.LoadAddOn, def.addon)
    def = Extensions.byID[id]
    if def.open or def.settings or def.scope then return true end
    local title = C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(def.addon, "Title") or def.addon
    EasyFind:Print(L["COMPANION_INCOMPLETE_FMT"]:format(title))
    return false
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
    function kit.Checkbox(parent, label, get, set, tooltip)
        local box = ctx.CreateCheckbox(parent, nil, label, tooltip, true)
        box:SetChecked(get() and true or false)
        if box.RefreshVisual then box:RefreshVisual() end
        box:SetScript("OnClick", function(self)
            if self.RefreshVisual then self:RefreshVisual() end
            Run(set, self:GetChecked() and true or false)
        end)
        return box
    end
    function kit.Choice(parent, label, choices, get, set, tooltip, default)
        kitNames = kitNames + 1
        return ctx.CreateFlyoutPresetRow(parent, label, choices, get, function(v) Run(set, v) end,
            "EasyFindExtChoice" .. kitNames, default, tooltip)
    end
    function kit.Stepper(parent, label, min, max, step, get, set, tooltip)
        return ctx.CreateStepperRow(parent, label, min, max, get, function(v) Run(set, v) end, tooltip, nil, step)
    end
    return kit
end

-- ==== public: extensions =====================================================

-- def: id (required, stable: layouts and buttons save it), name (required
-- the first time), description, icon, iconCoords, tint (white line art
-- tinted to the theme), addon (a load-on-demand addon loaded on first
-- open), loadInCombat, open, close, isOpen, menu (rows for its right-click
-- menu), settings(page, kit), keywords, hideFromSearch, experimental,
-- scope (its surface is that @scope's list in the results).
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
        rec = {}
        Extensions.byID[id] = rec
        Extensions.order[#Extensions.order + 1] = id
    end
    for k, v in pairs(def) do rec[k] = v end
    if def.settings and ns.RegisterExtensionPage then
        ns.RegisterExtensionPage({
            id = id, name = rec.name, icon = rec.icon, coords = rec.iconCoords, companion = rec.addon,
            build = function(ctx, page) Run(rec.settings, page, Kit(ctx)) end,
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

-- ==== public: search ==========================================================

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

-- ==== public: settings ========================================================

-- Opens the options panel's Extensions tab at this extension's page.
function API.OpenSettings(id)
    if not (ns.RequestOptionsPanel and ns.RequestOptionsPanel()) then return false end
    if ns.Options and ns.Options.OpenAtExtension then ns.Options:OpenAtExtension(id) end
    return true
end

function API.IsSettingsOpen(id)
    local frame = ns.optionsFrame
    return frame ~= nil and frame:IsShown() and ns.Options ~= nil and ns.Options.CurrentExtensionPage ~= nil
        and ns.Options:CurrentExtensionPage() == id
end

function API.CloseSettings()
    if ns.Options and ns.Options.Hide then ns.Options:Hide() end
end

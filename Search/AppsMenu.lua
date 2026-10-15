local _, ns = ...
local L = ns.L

local Results = ns.Results
local Utils = ns.Utils

local CreateFrame = CreateFrame
local UIParent = UIParent
local tremove, tinsert, sformat, strtrim, time = table.remove, table.insert, string.format, strtrim, time

-- The apps menu: a 3x3 dot grid beside the filter button that drops a list of
-- apps, exactly as the filter button drops its filters.
local AppsMenu = {}
ns.AppsMenu = AppsMenu

local ROW_H = 24
local PAD = 6
local ICON = 16

-- The launcher list. App entries join this list as they release.
function ns.BuildApplicationEntries()
    local apps = {}
    local calculator = ns.Calculator and ns.Calculator._calculator
    if calculator and calculator.LAUNCHER then
        apps[#apps + 1] = calculator.LAUNCHER
    end
    -- Icon Search (GitHub #22): opens the @icons grid, same entry point as
    -- the searchable launcher row. iconSearchLauncher picks its own glyph in
    -- GetFlatCategoryIcon; without it, nativeRun lands on the command icon.
    -- Hidden when its LoadOnDemand companion is disabled in the AddOns list.
    if not (ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Icons")) then
        apps[#apps + 1] = {
            name = ns.L["ICON_SEARCH_APP"],
            iconSearchLauncher = true,
            noPin = true,
            nativeRun = function()
                if ns.RequestIconSearch and ns.RequestIconSearch() then
                    ns.Results:OpenIconSearch()
                end
            end,
        }
    end
    -- Snippets opens the options panel landed on its tab: the tab is the
    -- one management surface (list, search, create, edit), and the menu is
    -- its discoverable front door. category "Snippet" gives the row its
    -- glyph; nativeRun runs BEFORE the snippet-category branch in
    -- SelectResult, so this opens the list, not the per-snippet editor.
    -- The panel is a LoadOnDemand companion: request it before touching
    -- ns.Options (the options tutorial button shipped broken for skipping
    -- exactly this).
    -- Hidden when the snippets companion is disabled in the AddOns list.
    if not (ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Snippets")) then
        apps[#apps + 1] = {
            name = L["FILTER_SNIPPETS"],
            category = "Snippet",
            snippetsLauncher = true,
            noPin = true,
            nativeRun = function()
                if ns.RequestOptionsPanel and ns.RequestOptionsPanel()
                   and ns.Options and ns.Options.OpenAtSnippets then
                    ns.Options:OpenAtSnippets()
                end
            end,
        }
    end
    -- Clipboard history opens its own list (@clipboard). Hidden when the
    -- clipboard companion is disabled in the AddOns list.
    if not (ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Clipboard")) then
        apps[#apps + 1] = {
            name = L["FILTER_CLIPBOARD"],
            clipboardLauncher = true,
            noPin = true,
            icon = ns.CLIPBOARD_ICON_TEX,
            nativeRun = function()
                if ns.Clipboard and ns.Clipboard.OpenList then ns.Clipboard:OpenList() end
            end,
        }
    end
    -- Notes opens its window. Hidden when the notes companion is disabled.
    if not (ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Notes")) then
        apps[#apps + 1] = {
            name = L["APP_NOTES"],
            notesLauncher = true,
            noPin = true,
            icon = ns.NOTES_ICON_TEX,
            nativeRun = function()
                if ns.RequestNotes() then ns.Notes.Open() end
            end,
        }
    end
    if ns.Quicklists then ns.Quicklists:AppEntries(apps) end
    if not (ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Clock")) then
        apps[#apps + 1] = ns.ClockLauncherEntry()
    end
    if not (ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Alerts")) then
        apps[#apps + 1] = ns.AlertsLauncherEntry()
    end
    -- GPS opens its own page under the map search tab. Hidden when the GPS
    -- companion is disabled in the AddOns list.
    if not (ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_GPS")) then
        apps[#apps + 1] = {
            name = L["APP_GPS"],
            experimental = L["GPS_EXP_TT"],
            gpsLauncher = true,
            noPin = true,
            icon = ns.GPS_ICON_TEX,
            nativeRun = function()
                if ns.GPS and ns.GPS.Open then ns.GPS:Open() end
            end,
        }
    end
    -- Chat opens the messenger. Hidden when its companion is disabled.
    if not (ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Chat")) then
        apps[#apps + 1] = {
            name = L["APP_CHAT"],
            chatLauncher = true,
            noPin = true,
            icon = ns.CHAT_ICON_TEX,
            nativeRun = function()
                if ns.RequestChat and ns.RequestChat() then ns.Chat:Open() end
            end,
        }
    end
    -- Windows opens the task view: every open panel with its zones, and
    -- the saved layouts. Part of the core, never a companion.
    if ns.WindowSnapAssist then
        apps[#apps + 1] = {
            name = L["FILTER_WINDOW"],
            windowsLauncher = true,
            noPin = true,
            nativeRun = function() ns.WindowSnapAssist:ToggleTaskView() end,
        }
    end
    return apps
end

-- Stable ids for the extension buttons (Search/ExtensionButtons.lua): an
-- app is known by its launcher flag, never by its localized name.
local APP_ID_FLAGS = {
    { "calculator", "calculatorLauncher" },
    { "icons", "iconSearchLauncher" },
    { "snippets", "snippetsLauncher" },
    { "clipboard", "clipboardLauncher" },
    { "notes", "notesLauncher" },
    { "gps", "gpsLauncher" },
    { "clock", "clockLauncher" },
    { "alerts", "alertsLauncher" },
    { "quicklists", "quicklistsLauncher" },
    { "windows", "windowsLauncher" },
    { "chat", "chatLauncher" },
}
function ns.ApplicationEntryID(app)
    if not app then return nil end
    if app.quicklistID then return "quicklist:" .. app.quicklistID end
    for i = 1, #APP_ID_FLAGS do
        if app[APP_ID_FLAGS[i][2]] then return APP_ID_FLAGS[i][1] end
    end
    return nil
end
-- The live launcher entry for an id, or for a stored copy of one (a
-- shortkey snapshot keeps the flag but not the run function).
function ns.FindApplicationEntry(idOrData)
    if not idOrData then return nil end
    local id = type(idOrData) == "table" and ns.ApplicationEntryID(idOrData) or idOrData
    if not id then return nil end
    local apps = ns.BuildApplicationEntries()
    for i = 1, #apps do
        if ns.ApplicationEntryID(apps[i]) == id then return apps[i] end
    end
    return nil
end

-- Whether an extension's own surface is up right now, and how to take it
-- down: the calculator popup, the icon grid or the clipboard list in the
-- results (the pill comes off and the results close, leaving the bar),
-- the options panel on the snippets page. Every launch surface (menu row,
-- extension button, compartment) toggles through these, so a second
-- click closes what the first opened.
function ns.IsApplicationOpen(app)
    if not app then return false end
    if app.calculatorLauncher then
        local calc = ns.Calculator and ns.Calculator._calculator
        local frame = calc and calc.popupFrame
        return frame ~= nil and frame:IsShown()
    end
    local Filters = ns.Filters
    local qf = Filters and Filters.GetQuickFilter and Filters:GetQuickFilter()
    local resultsShown = ns.Search and ns.Search.GetResultsFrame and ns.Search:GetResultsFrame()
        and ns.Search:GetResultsFrame():IsShown()
    if app.iconSearchLauncher then
        return resultsShown and qf ~= nil and qf.key == "icons"
    end
    if app.clipboardLauncher then
        return resultsShown and qf ~= nil and qf.key == "clipboard"
    end
    if app.quicklistID then
        return resultsShown and qf ~= nil and qf.quicklistID == app.quicklistID
    end
    if app.quicklistsLauncher then
        local frame = ns.optionsFrame
        return frame ~= nil and frame:IsShown() and ns.Options and ns.Options.CurrentExtensionPage
            and ns.Options:CurrentExtensionPage() == "quicklists"
    end
    if app.notesLauncher then
        return ns.Notes ~= nil and ns.Notes.IsOpen ~= nil and ns.Notes.IsOpen()
    end
    if app.snippetsLauncher then
        local frame = ns.optionsFrame
        return frame ~= nil and frame:IsShown() and ns.Options and ns.Options.CurrentExtensionPage
            and ns.Options:CurrentExtensionPage() == "snippets"
    end
    if app.clockLauncher then
        return ns.Clock ~= nil and ns.Clock.IsOpen() or false
    end
    if app.alertsLauncher then
        return ns.Alerts ~= nil and ns.Alerts.IsOpen() or false
    end
    if app.windowsLauncher then
        local view = _G["EasyFindTaskView"]
        return view ~= nil and view:IsShown()
    end
    if app.chatLauncher then
        return ns.Chat ~= nil and ns.Chat.IsOpen ~= nil and ns.Chat:IsOpen() or false
    end
    return false
end

function ns.CloseApplication(app)
    if not app then return end
    if app.calculatorLauncher then
        local calc = ns.Calculator and ns.Calculator._calculator
        if calc and calc.popupFrame then calc.popupFrame:Hide() end
        return
    end
    if app.iconSearchLauncher or app.clipboardLauncher or app.quicklistID then
        if ns.Filters and ns.Filters.ClearQuickFilter then ns.Filters:ClearQuickFilter(false) end
        if Results and Results.HideResults then Results:HideResults() end
        return
    end
    if app.quicklistsLauncher and ns.Options and ns.Options.Hide then
        ns.Options:Hide()
        return
    end
    if app.notesLauncher then
        if ns.Notes and ns.Notes.Close then ns.Notes.Close() end
        return
    end
    if app.snippetsLauncher and ns.Options and ns.Options.Hide then
        ns.Options:Hide()
    end
    if app.clockLauncher and ns.Clock then ns.Clock.Minimize() end
    if app.alertsLauncher and ns.Alerts then ns.Alerts.Close() end
end

-- The results-based extension showing right now ("icons", "clipboard"),
-- or nil. The outside-click closers ask before they hide.
function ns.CurrentApplicationSurfaceID()
    local Filters = ns.Filters
    local qf = Filters and Filters.GetQuickFilter and Filters:GetQuickFilter()
    local key = qf and qf.key
    if qf and qf.quicklistID then key = "quicklist:" .. qf.quicklistID end
    if key ~= "icons" and key ~= "clipboard" and not (qf and qf.quicklistID) then return nil end
    local rf = ns.Search and ns.Search.GetResultsFrame and ns.Search:GetResultsFrame()
    if not (rf and rf:IsShown()) then return nil end
    return key
end

-- An outside mouse-down takes the icon grid or the clipboard list down a
-- beat before the click on a launch surface (extension button, broker
-- launcher, compartment row) lands, so the toggle would find it closed
-- and reopen what the user meant to close. The closers note what they
-- took down; launching that same extension within the gesture is the
-- close, and does nothing more.
local DISMISS_GRACE = 0.6
local dismissedID, dismissedAt
function ns.NoteApplicationDismissed(id)
    if not id then return end
    dismissedID, dismissedAt = id, GetTime()
end
local function JustDismissed(app)
    if not dismissedID then return false end
    if GetTime() - (dismissedAt or 0) > DISMISS_GRACE then
        dismissedID = nil
        return false
    end
    return ns.ApplicationEntryID(app) == dismissedID
end

-- Whether the bar was hidden when a launch opened it. Closing that
-- extension from a launch surface then takes the bar down too, so the
-- press that opened everything closes everything; opened while the bar
-- was already up, the close leaves the bar where it was.
local launchOpenedBar = {}
-- Visible to the user, not merely Shown: Hover Show keeps the frame
-- shown at alpha 0 while faded out, and a faded-out bar is a hidden
-- bar for this rule.
local function BarShown()
    local sf = ns.Search and ns.Search.GetSearchFrame and ns.Search:GetSearchFrame()
    if not (sf and sf:IsShown()) then return false end
    local db = EasyFind and EasyFind.db
    if db and db.smartShow and not db.autoHide and sf.smartShowVisible then
        return sf.smartShowVisible() and true or false
    end
    return (sf:GetAlpha() or 1) > 0.01
end
local function HideBarIfLaunchOpened(app)
    local id = ns.ApplicationEntryID(app)
    if not (id and launchOpenedBar[id]) then return end
    launchOpenedBar[id] = nil
    if BarShown() and ns.Search.Hide then ns.Search:Hide() end
end

function ns.ToggleApplication(app)
    if not app then return end
    if JustDismissed(app) then
        dismissedID = nil
        HideBarIfLaunchOpened(app)
        return
    end
    if ns.IsApplicationOpen(app) then
        ns.CloseApplication(app)
        HideBarIfLaunchOpened(app)
        return
    end
    local id = ns.ApplicationEntryID(app)
    if id then launchOpenedBar[id] = not BarShown() end
    Results:HideResults()
    ns.ResultHandlers:SelectResult(app)
end

-- Extension settings pages. The options panel's Extensions tab shows one
-- page per registered extension, picked from a strip at the top. Bundled
-- extensions register their pages from the options companion; others
-- register here: { id, name, icon, coords, companion, build = function(page) }.
-- `build` fills `page` (a frame filling the tab under the strip) once.
ns.ExtensionPages = ns.ExtensionPages or {}
function ns.RegisterExtensionPage(def)
    if not (def and def.id and def.build) then return end
    local pages = ns.ExtensionPages
    for i = 1, #pages do
        if pages[i].id == def.id then pages[i] = def; return end
    end
    pages[#pages + 1] = def
    if ns.Options and ns.Options.RefreshExtensionPages then ns.Options:RefreshExtensionPages() end
end

-- The searchable launcher row: typing "icons" / "icon search" (or the
-- localized app name) offers a row that opens the icon grid. CORE-owned:
-- it is an entry point to the LoadOnDemand companion, so it must exist
-- before the companion has ever loaded (and hide when the companion is
-- disabled outright).
local iconLauncherRow
function ns.Results:GetIconSearchLauncherMatch(text)
    if not text or #text < 3 then return nil end
    if ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Icons") then
        return nil
    end
    local q = text:lower()
    local target = (ns.L["ICON_SEARCH_APP"] or ""):lower()
    local sfind = ns.Utils.sfind
    if not (sfind(target, q, 1, true)
            or sfind("icon search", q, 1, true)
            or sfind("icons", q, 1, true)) then
        return nil
    end
    iconLauncherRow = iconLauncherRow or {
        name = ns.L["ICON_SEARCH_APP"],
        iconSearchLauncher = true,
        noPin = true,
        -- Injected at match time, never in uiSearchData: a learned key for
        -- it can never resolve, so the record would only be dead weight.
        noLearn = true,
        nativeRun = function()
            if ns.RequestIconSearch and ns.RequestIconSearch() then
                ns.Results:OpenIconSearch()
            end
        end,
    }
    return iconLauncherRow
end

-- The waffle: 3x3 round dots, drawn rather than shipped so it tints with the
-- theme like the rest of the bar chrome. A white square gets a circular alpha
-- mask -- SetColorTexture alone draws hard squares, which is not a dot grid.
-- The clipboard history launcher row: typing "clipboard" / "clip" /
-- "history" (or the localized app name) offers the row that opens the
-- @clipboard list. Core-owned like the icon launcher: the entries
-- themselves never appear in a search, only this door to them.
local clipboardLauncherRow
function ns.Results:GetClipboardLauncherMatch(text)
    if not text or #text < 3 then return nil end
    if ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Clipboard") then return nil end
    local q = ns.Utils.slower(text)
    local target = ns.Utils.slower(ns.L["FILTER_CLIPBOARD"] or "clipboard")
    local sfind = ns.Utils.sfind
    if not (sfind(target, q, 1, true)
            or sfind("clipboard", q, 1, true)
            or sfind("clipboard history", q, 1, true)
            or sfind("history", q, 1, true)) then
        return nil
    end
    clipboardLauncherRow = clipboardLauncherRow or {
        name = ns.L["FILTER_CLIPBOARD"],
        clipboardLauncher = true,
        noPin = true,
        noLearn = true,
        icon = ns.CLIPBOARD_ICON_TEX,
        nativeRun = function()
            if ns.Clipboard and ns.Clipboard.OpenList then ns.Clipboard:OpenList() end
        end,
    }
    return clipboardLauncherRow
end

-- The chat launcher row: typing "chat" (or the localized app name)
-- offers the row that opens the messenger, before it ever loaded.
local chatLauncherRow
function ns.Results:GetChatLauncherMatch(text)
    if not text or #text < 3 then return nil end
    if ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Chat") then return nil end
    local q = ns.Utils.slower(text)
    local sfind = ns.Utils.sfind
    if not (sfind(ns.Utils.slower(L["APP_CHAT"]), q, 1, true) or sfind("chat", q, 1, true)) then
        return nil
    end
    chatLauncherRow = chatLauncherRow or {
        name = L["APP_CHAT"],
        chatLauncher = true,
        noPin = true,
        noLearn = true,
        icon = ns.CHAT_ICON_TEX,
        nativeRun = function()
            if ns.RequestChat and ns.RequestChat() then ns.Chat:Open() end
        end,
    }
    return chatLauncherRow
end

-- The notes launcher row: typing "notes" (or the localized app name)
-- offers the row that opens the Notes window, before it ever loaded.
local notesLauncherRow
function ns.Results:GetNotesLauncherMatch(text)
    if not text or #text < 3 then return nil end
    if ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Notes") then return nil end
    local q = ns.Utils.slower(text)
    local sfind = ns.Utils.sfind
    if not (sfind(ns.Utils.slower(L["APP_NOTES"]), q, 1, true) or sfind("notes", q, 1, true)) then
        return nil
    end
    notesLauncherRow = notesLauncherRow or {
        name = L["APP_NOTES"],
        notesLauncher = true,
        noPin = true,
        noLearn = true,
        icon = ns.NOTES_ICON_TEX,
        nativeRun = function()
            if ns.RequestNotes() then ns.Notes.Open() end
        end,
    }
    return notesLauncherRow
end

-- The clock's launcher, shared by the extensions menu and the searchable
-- row. A typed word opens it only once it cannot be the start of another
-- search: "tim" and "stop" stay ordinary queries.
local CLOCK_WORDS = {
    { "clock", 4 }, { "timer", 5 }, { "stopwatch", 5 },
    { "pomodoro", 4 }, { "alarm", 4 }, { "countdown", 5 },
}
local clockLauncherEntry
local function OpenClock()
    if ns.RequestClock() then ns.Clock.Open() end
end
function ns.ClockLauncherEntry()
    clockLauncherEntry = clockLauncherEntry or {
        name = ns.CLOCK_NAME,
        clockLauncher = true,
        noPin = true,
        noLearn = true,
        icon = ns.CLOCK_ICON_TEX,
        nativeRun = OpenClock,
    }
    return clockLauncherEntry
end

-- The alerts launcher: "alert", "alerts" or the localized app name.
local alertsLauncherEntry
local function OpenAlerts()
    if ns.RequestAlerts() then ns.Alerts.Open() end
end
function ns.AlertsLauncherEntry()
    alertsLauncherEntry = alertsLauncherEntry or {
        name = L["APP_ALERTS"],
        alertsLauncher = true,
        noPin = true,
        noLearn = true,
        icon = ns.ALERTS_ICON_TEX,
        nativeRun = OpenAlerts,
    }
    return alertsLauncherEntry
end

function ns.Results:GetAlertsLauncherMatch(text)
    if not text or #text < 4 then return nil end
    if ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Alerts") then return nil end
    local q = ns.Utils.slower(text)
    local sfind = ns.Utils.sfind
    if not (sfind(ns.Utils.slower(L["APP_ALERTS"]), q, 1, true) or sfind("alerts", q, 1, true)) then return nil end
    return ns.AlertsLauncherEntry()
end

local function IsWordStart(word, q, minLen)
    return #q >= minLen and #q <= #word and word:sub(1, #q) == q
end

function ns.Results:GetClockLauncherMatch(text)
    if not text or #text < 3 then return nil end
    if ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Clock") then return nil end
    local slower = ns.Utils.slower
    local q = slower(text)
    for i = 1, #CLOCK_WORDS do
        if IsWordStart(CLOCK_WORDS[i][1], q, CLOCK_WORDS[i][2]) then return ns.ClockLauncherEntry() end
    end
    local name = slower(ns.CLOCK_NAME)
    local stopwatch = slower(_G["STOPWATCH_TITLE"] or "stopwatch")
    if q == name or q == stopwatch or IsWordStart(name, q, 4) or IsWordStart(stopwatch, q, 5) then
        return ns.ClockLauncherEntry()
    end
    return nil
end

local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local function CreateGridGlyph(parent, size)
    local glyph = CreateFrame("Frame", nil, parent)
    glyph:SetSize(size, size)
    local cell = size / 3
    local dot = cell * 0.72
    glyph.dots = {}
    for row = 0, 2 do
        for col = 0, 2 do
            local tex = glyph:CreateTexture(nil, "OVERLAY")
            tex:SetColorTexture(1, 1, 1, 1)
            tex:SetSize(dot, dot)
            tex:SetPoint("CENTER", glyph, "TOPLEFT", (col + 0.5) * cell, -(row + 0.5) * cell)
            local mask = glyph:CreateMaskTexture()
            mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(tex)
            tex:AddMaskTexture(mask)
            glyph.dots[#glyph.dots + 1] = tex
        end
    end
    return glyph
end
-- The tutorial's Apps tile draws the same waffle so the tile and the live
-- bar button read as one thing; exported so that replica cannot drift.
ns.CreateGridGlyph = CreateGridGlyph

function AppsMenu:SetGlyphColor(r, g, b, a)
    local glyph = self.button and self.button.glyph
    if not glyph then return end
    for i = 1, #glyph.dots do
        glyph.dots[i]:SetVertexColor(r, g, b, a or 1)
    end
end

-- The menu's settings: columns, where a label sits and its font, the
-- order dragged into place and the groups. Kept with the profile.
local LABEL_POSITIONS = { "right", "below", "above", "left", "hidden" }
AppsMenu.LABEL_POSITIONS = LABEL_POSITIONS
local TILE_ICON = 20      -- the icon of a stacked or bare tile
local GAP = 4             -- between tiles
local BuildRows
local function Settings()
    local db = EasyFind and EasyFind.db
    if not db then return { columns = 1, labels = "right", font = "Default" } end
    local s = db.appsMenu
    if not s then s = {} db.appsMenu = s end
    s.columns = s.columns or 1
    s.labels = s.labels or "right"
    s.font = s.font or "Default"
    return s
end
AppsMenu.Settings = Settings

local function GroupByID(s, id)
    for _, g in ipairs(s.groups or {}) do if g.id == id then return g end end
    return nil
end

local function ByName(a, b) return (a.name or "") < (b.name or "") end

-- The tiles in their order: the saved order first (apps and groups), the
-- rest by name; inside a group, its apps in the group's order.
local function MenuItems(groupID)
    local s = Settings()
    local apps = ns.BuildApplicationEntries and ns.BuildApplicationEntries() or {}
    local byID = {}
    for _, app in ipairs(apps) do
        local id = ns.ApplicationEntryID(app)
        if id then byID[id] = app end
    end
    local items = {}
    if groupID then
        local g = GroupByID(s, groupID)
        for _, id in ipairs(g and g.apps or {}) do
            if byID[id] then items[#items + 1] = { app = byID[id], id = id, name = byID[id].name } end
        end
        return items, g
    end
    local grouped, placed = {}, {}
    for _, g in ipairs(s.groups or {}) do
        for _, id in ipairs(g.apps) do grouped[id] = true end
    end
    for _, id in ipairs(s.order or {}) do
        local gid = id:match("^group:(.+)$")
        local g = gid and GroupByID(s, gid)
        if g and not placed[id] then
            items[#items + 1] = { group = g, id = id, name = g.name }
            placed[id] = true
        elseif not gid and byID[id] and not grouped[id] and not placed[id] then
            items[#items + 1] = { app = byID[id], id = id, name = byID[id].name }
            placed[id] = true
        end
    end
    local rest = {}
    for _, g in ipairs(s.groups or {}) do
        if not placed["group:" .. g.id] then rest[#rest + 1] = { group = g, id = "group:" .. g.id, name = g.name } end
    end
    for id, app in pairs(byID) do
        if not grouped[id] and not placed[id] then rest[#rest + 1] = { app = app, id = id, name = app.name or "" } end
    end
    table.sort(rest, ByName)
    for _, it in ipairs(rest) do items[#items + 1] = it end
    return items, nil
end
AppsMenu.MenuItems = MenuItems

local function TintGlyph(tex)
    local gc = ns.ChromeGlyphColor()
    tex:SetDesaturated(true)
    tex:SetVertexColor(gc[1], gc[2], gc[3], 1)
end

local function AppGlyph(app)
    -- The app's own glyph, not GetFlatCategoryIcon: launcher data resolves
    -- to the apps waffle there (result rows), which says nothing in a menu
    -- where every row is an app.
    local iconDef = ns.ResultIcons and (ns.ResultIcons:GetAppGlyphIcon(app)
        or ns.ResultIcons:GetFlatCategoryIcon(app))
    return (iconDef and iconDef.tex) or app.icon, iconDef and iconDef.coords
end

local function EnsureTile(dropdown, i)
    local row = dropdown.rows[i]
    if row then return row end
    row = CreateFrame("Button", nil, dropdown)
    row:SetSize(100, ROW_H)
    -- Same rounded hover pill as every other menu row; the shared
    -- installer owns the highlight texture and wash behavior.
    Utils.InstallMenuRowHighlight(row)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON, ICON)
    -- A group shows up to four of its members in the icon's place.
    row.minis = {}
    for k = 1, 4 do
        local mini = row:CreateTexture(nil, "ARTWORK")
        mini:Hide()
        row.minis[k] = mini
    end
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetWordWrap(false)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        local item = self.item
        if not item then return end
        if item.back then
            BuildRows(dropdown, nil)
            return
        end
        if button == "RightButton" then
            AppsMenu:ShowTileMenu(self)
            return
        end
        if item.group then
            BuildRows(dropdown, item.group.id)
            return
        end
        if dropdown.arranging then return end
        dropdown:Hide()
        ns.ToggleApplication(item.app)
    end)
    row:HookScript("OnEnter", function(self)
        local item = self.item
        if not item or item.back then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(item.name or "")
        if item.app then GameTooltip:AddLine(L["EXTBTN_DRAG_HINT"], 0.7, 0.7, 0.7, true) end
        GameTooltip:Show()
    end)
    row:HookScript("OnLeave", function() GameTooltip:Hide() end)
    -- Dragging a row out makes a button for that extension on screen
    -- (Search/ExtensionButtons.lua); while arranging, the drag moves the
    -- tile within the menu instead. Press-and-move, not the frame drag
    -- events (those depend on the row keeping the mouse, which a menu row
    -- does not always get): a press followed by movement past a few
    -- pixels while the button is still held starts the drag.
    row:HookScript("OnMouseDown", function(self, button)
        local item = self.item
        if button ~= "LeftButton" or not item or item.back then return end
        if not (dropdown.arranging or (item.app and ns.ExtensionButtons)) then return end
        local sx, sy = GetCursorPosition()
        self._efPress = { x = sx, y = sy }
        self:SetScript("OnUpdate", function(row2)
            local press = row2._efPress
            if not press then row2:SetScript("OnUpdate", nil); return end
            if not IsMouseButtonDown("LeftButton") then
                row2._efPress = nil
                row2:SetScript("OnUpdate", nil)
                return
            end
            local cx, cy = GetCursorPosition()
            if (cx - press.x) ^ 2 + (cy - press.y) ^ 2 < 36 then return end
            row2._efPress = nil
            row2:SetScript("OnUpdate", nil)
            if dropdown.arranging then
                AppsMenu:BeginArrangeDrag(dropdown, row2)
            else
                dropdown:Hide()
                ns.ExtensionButtons:BeginDragFromMenu(row2.item.app)
            end
        end)
    end)
    dropdown.rows[i] = row
    return row
end

-- A tile's icon and label where the labels setting puts them.
local function PlaceTile(row, labels)
    local icon, label = row.icon, row.label
    icon:ClearAllPoints()
    label:ClearAllPoints()
    label:SetShown(labels ~= "hidden")
    if labels == "below" or labels == "above" then
        icon:SetSize(TILE_ICON, TILE_ICON)
        label:SetJustifyH("CENTER")
        label:SetPoint("LEFT", row, "LEFT", 3, 0)
        label:SetPoint("RIGHT", row, "RIGHT", -3, 0)
        if labels == "below" then
            icon:SetPoint("TOP", row, "TOP", 0, -5)
            label:SetPoint("TOP", icon, "BOTTOM", 0, -4)
        else
            label:SetPoint("TOP", row, "TOP", 0, -5)
            icon:SetPoint("TOP", label, "BOTTOM", 0, -4)
        end
    elseif labels == "hidden" then
        icon:SetSize(TILE_ICON, TILE_ICON)
        icon:SetPoint("CENTER", row, "CENTER", 0, 0)
    elseif labels == "left" then
        icon:SetSize(ICON, ICON)
        icon:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        label:SetJustifyH("RIGHT")
        label:SetPoint("RIGHT", icon, "LEFT", -8, 0)
        label:SetPoint("LEFT", row, "LEFT", 4, 0)
    else
        icon:SetSize(ICON, ICON)
        icon:SetPoint("LEFT", row, "LEFT", 2, 0)
        label:SetJustifyH("LEFT")
        label:SetPoint("LEFT", icon, "RIGHT", 8, 0)
        label:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    end
    -- The group's members sit in the icon's box, two by two.
    local half = icon:GetWidth() / 2
    for k = 1, 4 do
        local mini = row.minis[k]
        mini:SetSize(half - 1, half - 1)
        mini:ClearAllPoints()
        mini:SetPoint("TOPLEFT", icon, "TOPLEFT", ((k - 1) % 2) * half, -math.floor((k - 1) / 2) * half)
    end
end

local function PaintTile(row, item, dropdown)
    row.item = item
    local labels = Settings().labels
    PlaceTile(row, labels)
    for k = 1, 4 do row.minis[k]:Hide() end
    if item.back then
        row.icon:SetTexture(nil)
        Utils.SetChevronTexture(row.icon)
        row.icon:SetRotation(-math.pi / 2)
        TintGlyph(row.icon)
        row.icon:Show()
    elseif item.group then
        row.icon:SetRotation(0)
        row.icon:Hide()
        local shown = 0
        for _, id in ipairs(item.group.apps) do
            local app = ns.FindApplicationEntry(id)
            if app and shown < 4 then
                shown = shown + 1
                local mini = row.minis[shown]
                local tex, coords = AppGlyph(app)
                mini:SetTexture(tex or ns.EXTENSIONS_ICON_TEX)
                mini:SetTexCoord(unpack(coords or { 0, 1, 0, 1 }))
                TintGlyph(mini)
                mini:Show()
            end
        end
    else
        row.icon:SetRotation(0)
        local tex, coords = AppGlyph(item.app)
        if tex then
            row.icon:SetTexture(tex)
            row.icon:SetTexCoord(unpack(coords or { 0, 1, 0, 1 }))
            TintGlyph(row.icon)
            row.icon:Show()
        else
            row.icon:Hide()
        end
    end
    row.label:SetText(item.name or "")
    -- Same font as result-row titles (pathFont), like every menu, unless
    -- the labels have a font of their own.
    local theme = Results.GetActiveTheme and Results:GetActiveTheme()
    Results:SetScaledFont(row.label, (theme and theme.pathFont) or ns.LEAF_FONT)
    local path = ns.GetFontChoicePath and ns.GetFontChoicePath(Settings().font)
    if path then
        local _, size, flags = row.label:GetFont()
        row.label:SetFont(path, size, flags)
    end
    -- An experimental app wears the EXP badge after its name.
    local exp = item.app and item.app.experimental
    if exp and not row.expTag then
        row.expTag = ns.CreateFeatureTag(dropdown, "exp", L["TAG_EXP_TITLE"], exp, true)
    end
    if row.expTag then
        ns.SuperscriptTag(row.expTag, row.label)
        row.expTag:SetShown(exp ~= nil and labels ~= "hidden")
    end
    row:Show()
end

-- Tile sizes from the widest label and the labels setting; the grid from
-- the columns setting. Returns the tile width, height and the columns.
local function TileMetrics(dropdown, n)
    local s = Settings()
    local widest, fontH = 0, 12
    for i = 1, n do
        local row = dropdown.rows[i]
        local w = (row.label:GetStringWidth() or 0) + (row.expTag and row.expTag:IsShown() and row.expTag:GetWidth() + 1 or 0)
        if w > widest then widest = w end
        fontH = row.label:GetStringHeight() or fontH
    end
    local cols = math.max(1, math.min(4, s.columns))
    if s.labels == "below" or s.labels == "above" then
        return math.max(52, math.min(140, widest + 12)), TILE_ICON + 4 + fontH + 10, cols
    elseif s.labels == "hidden" then
        return 32, 32, cols
    end
    return math.max(78, math.min(188, ICON + 8 + widest + 10)), ROW_H, cols
end

function BuildRows(dropdown, groupID)
    dropdown.rows = dropdown.rows or {}
    dropdown.groupID = groupID
    local items, group = MenuItems(groupID)
    if group then
        table.insert(items, 1, { back = true, name = group.name, id = "back" })
    end
    for i = 1, #items do
        PaintTile(EnsureTile(dropdown, i), items[i], dropdown)
    end
    for i = #items + 1, #dropdown.rows do
        dropdown.rows[i]:Hide()
        dropdown.rows[i].item = nil
        if dropdown.rows[i].expTag then dropdown.rows[i].expTag:Hide() end
    end
    -- Wash mode and tint follow the active theme; re-run per build so rows
    -- created this open (or a theme swapped since last open) paint right.
    Utils.RefreshMenuRowHighlights(dropdown, dropdown.rows)
    local w, h, cols = TileMetrics(dropdown, #items)
    for i = 1, #items do
        local row = dropdown.rows[i]
        local r, c = math.floor((i - 1) / cols), (i - 1) % cols
        row.index = i
        row:SetSize(w, h)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", dropdown, "TOPLEFT", PAD + c * (w + GAP), -PAD - r * (h + GAP))
    end
    local lines = math.ceil(#items / cols)
    local menuW = PAD * 2 + cols * w + (cols - 1) * GAP
    local contentH = lines * h + (lines - 1) * GAP
    local footH = AppsMenu:LayoutFooter(dropdown, contentH, menuW)
    dropdown:SetSize(menuW, PAD * 2 + contentH + footH)
    return #items
end

-- The menu built again where it stands, after a setting or an arrangement.
function AppsMenu:Rebuild()
    local dropdown = self.dropdown
    if dropdown and dropdown:IsShown() then BuildRows(dropdown, dropdown.groupID) end
end

-- Arranging: the tiles drag into an order; one dropped on another makes
-- a group of the two, or joins the group it lands on; dropped on the back
-- tile inside a group it leaves the group. Entered from a tile's menu or
-- the settings page; a footer with the hint and Done shows meanwhile.

-- The ids as the tiles stand, the back tile left out.
local function TileIDs(dropdown)
    local ids = {}
    for i = 1, #dropdown.rows do
        local item = dropdown.rows[i].item
        if item and not item.back then ids[#ids + 1] = item.id end
    end
    return ids
end

local function RemoveID(list, id)
    for i = #list, 1, -1 do if list[i] == id then tremove(list, i) end end
end

local function WriteIDs(dropdown, ids)
    local s = Settings()
    if dropdown.groupID then
        local g = GroupByID(s, dropdown.groupID)
        if g then g.apps = ids end
    else
        s.order = ids
    end
end

local function DeleteGroupIfEmpty(s, g)
    if #g.apps > 0 then return end
    for i = #s.groups, 1, -1 do if s.groups[i] == g then tremove(s.groups, i) end end
    if s.order then RemoveID(s.order, "group:" .. g.id) end
end

local function PromptGroupName(g, onDone)
    ns.ShowThemedDialog({
        text = L["EXTMENU_GROUP_NAME"], hasEditBox = true, editBoxDefault = g.name, maxLetters = 24,
        acceptText = _G["OKAY"] or "Okay", cancelText = _G["CANCEL"] or "Cancel",
        onAccept = function(value)
            value = strtrim(value or "")
            if value ~= "" then g.name = value end
            if onDone then onDone() end
        end,
    })
end

-- A new group of two tiles, standing where the target stood.
local function MakeGroup(dropdown, targetID, movedID)
    local s = Settings()
    s.groups = s.groups or {}
    local g = { id = sformat("%d.%d", time(), #s.groups + 1), name = L["EXTMENU_GROUP_DEFAULT"], apps = { targetID, movedID } }
    s.groups[#s.groups + 1] = g
    local ids = TileIDs(dropdown)
    RemoveID(ids, movedID)
    for i = 1, #ids do if ids[i] == targetID then ids[i] = "group:" .. g.id end end
    s.order = ids
    PromptGroupName(g, function() AppsMenu:Rebuild() end)
end

-- Where a drag would land: a tile to join (its middle), else the slot
-- before or after the nearest tile along the flow.
local function DropTarget(dropdown, x, y, from)
    local best, bestD
    local dl, db = dropdown:GetLeft(), dropdown:GetBottom()
    for i = 1, #dropdown.rows do
        local row = dropdown.rows[i]
        if row:IsShown() and row ~= from and row.item then
            local cx = row:GetLeft() - dl + row:GetWidth() / 2
            local cy = row:GetBottom() - db + row:GetHeight() / 2
            local d = (x - cx) ^ 2 + (y - cy) ^ 2
            if not bestD or d < bestD then best, bestD = row, d end
        end
    end
    if not best then return nil, nil end
    local l, b = best:GetLeft() - dl, best:GetBottom() - db
    local w, h = best:GetWidth(), best:GetHeight()
    local inside = x >= l and x <= l + w and y >= b and y <= b + h
    local joins = best.item.back or best.item.group or (best.item.app and from.item.app and not dropdown.groupID)
    if inside and joins and math.abs(x - (l + w / 2)) < w * 0.3 and math.abs(y - (b + h / 2)) < h * 0.3 then
        return best, nil
    end
    local after
    if Settings().columns > 1 then after = x > l + w / 2 else after = y < b + h / 2 end
    return nil, after and best.index + 1 or best.index
end

local function EndArrangeDrag(dropdown)
    local ghost = dropdown.ghost
    ghost:SetScript("OnUpdate", nil)
    ghost:Hide()
    ghost.line:Hide()
    ghost.target:Hide()
    local from = ghost.from
    from:SetAlpha(1)
    local moved = from.item
    local s = Settings()
    if ghost.over then
        local t = ghost.over.item
        if t.back then
            -- Out of the group: the app takes its place among the top tiles.
            local g = GroupByID(s, dropdown.groupID)
            if g then
                RemoveID(g.apps, moved.id)
                local top = {}
                for _, it in ipairs(MenuItems(nil)) do top[#top + 1] = it.id end
                s.order = top
                DeleteGroupIfEmpty(s, g)
                if #g.apps == 0 then dropdown.groupID = nil end
            end
        elseif t.group and moved.app then
            local ids = TileIDs(dropdown)
            RemoveID(ids, moved.id)
            s.order = ids
            t.group.apps[#t.group.apps + 1] = moved.id
        elseif t.app and moved.app then
            MakeGroup(dropdown, t.id, moved.id)
        end
    elseif ghost.slot then
        local ids = TileIDs(dropdown)
        local fromIdx
        for i = 1, #ids do if ids[i] == moved.id then fromIdx = i end end
        local to = ghost.slot - (dropdown.groupID and 1 or 0)
        if fromIdx then
            tremove(ids, fromIdx)
            if to > fromIdx then to = to - 1 end
            tinsert(ids, math.max(1, math.min(#ids + 1, to)), moved.id)
            WriteIDs(dropdown, ids)
        end
    end
    BuildRows(dropdown, dropdown.groupID)
end

function AppsMenu:BeginArrangeDrag(dropdown, row)
    local ghost = dropdown.ghost
    if not ghost then
        ghost = CreateFrame("Frame", nil, dropdown)
        ghost:SetFrameLevel(dropdown:GetFrameLevel() + 20)
        ghost:SetSize(TILE_ICON, TILE_ICON)
        ghost.icon = ghost:CreateTexture(nil, "OVERLAY")
        ghost.icon:SetAllPoints()
        ghost.line = dropdown:CreateTexture(nil, "OVERLAY")
        ghost.line:SetColorTexture(1, 0.82, 0, 0.9)
        ghost.target = dropdown:CreateTexture(nil, "ARTWORK")
        ghost.target:SetColorTexture(1, 0.82, 0, 0.22)
        dropdown.ghost = ghost
    end
    local tex, coords
    if row.item.group then tex = ns.EXTENSIONS_ICON_TEX else tex, coords = AppGlyph(row.item.app) end
    ghost.icon:SetTexture(tex or ns.EXTENSIONS_ICON_TEX)
    ghost.icon:SetTexCoord(unpack(coords or { 0, 1, 0, 1 }))
    TintGlyph(ghost.icon)
    ghost.from = row
    row:SetAlpha(0.35)
    ghost:Show()
    ghost:SetScript("OnUpdate", function(self)
        local cx, cy = GetCursorPosition()
        local scale = dropdown:GetEffectiveScale()
        local x, y = cx / scale - dropdown:GetLeft(), cy / scale - dropdown:GetBottom()
        self:ClearAllPoints()
        self:SetPoint("CENTER", dropdown, "BOTTOMLEFT", x, y)
        local over, slot = DropTarget(dropdown, x, y, row)
        self.over, self.slot = over, slot
        self.target:SetShown(over ~= nil)
        if over then
            self.target:ClearAllPoints()
            self.target:SetAllPoints(over)
        end
        local at = slot and dropdown.rows[slot]
        local last = slot and not at and dropdown.rows[slot - 1]
        local beside = at or last
        self.line:SetShown(beside ~= nil)
        if beside then
            self.line:ClearAllPoints()
            if Settings().columns > 1 then
                self.line:SetSize(2, beside:GetHeight())
                if at then self.line:SetPoint("RIGHT", at, "LEFT", -1, 0)
                else self.line:SetPoint("LEFT", last, "RIGHT", 1, 0) end
            else
                self.line:SetSize(beside:GetWidth(), 2)
                if at then self.line:SetPoint("BOTTOM", at, "TOP", 0, 1)
                else self.line:SetPoint("TOP", last, "BOTTOM", 0, -1) end
            end
        end
        if not IsMouseButtonDown("LeftButton") then EndArrangeDrag(dropdown) end
    end)
end

-- The footer while arranging: the hint and Done. Returns its height.
function AppsMenu:LayoutFooter(dropdown, contentH, menuW)
    local foot = dropdown.foot
    if not dropdown.arranging then
        if foot then foot:Hide() end
        return 0
    end
    if not foot then
        foot = CreateFrame("Frame", nil, dropdown)
        foot.hint = foot:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        foot.hint:SetPoint("TOPLEFT", foot, "TOPLEFT", 2, 0)
        foot.hint:SetJustifyH("LEFT")
        foot.hint:SetWordWrap(true)
        foot.hint:SetText(L["EXTMENU_ARRANGE_HINT"])
        foot.done = CreateFrame("Button", nil, foot)
        foot.done:SetHeight(18)
        foot.done.text = foot.done:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        foot.done.text:SetPoint("RIGHT", foot.done, "RIGHT", 0, 0)
        foot.done.text:SetText(L["EXTMENU_DONE"])
        foot.done:SetWidth((foot.done.text:GetStringWidth() or 30) + 4)
        foot.done:SetPoint("BOTTOMRIGHT", foot, "BOTTOMRIGHT", -2, 0)
        foot.done:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 1, 1) end)
        foot.done:SetScript("OnLeave", function(self) self.text:SetTextColor(unpack(ns.TEXT_DIM)) end)
        foot.done.text:SetTextColor(unpack(ns.TEXT_DIM))
        foot.done:SetScript("OnClick", function() AppsMenu:StopArranging() end)
        dropdown.foot = foot
    end
    foot:ClearAllPoints()
    foot:SetPoint("TOPLEFT", dropdown, "TOPLEFT", PAD, -PAD - contentH - 6)
    foot:SetWidth(menuW - PAD * 2)
    foot.hint:SetWidth(menuW - PAD * 2 - 4)
    local h = (foot.hint:GetStringHeight() or 12) + 22
    foot:SetHeight(h)
    foot:Show()
    return h + 6
end

function AppsMenu:StartArranging()
    local dropdown, btn = self.dropdown, self.button
    if not (dropdown and btn) then return end
    -- The menu hangs from the bar: shown first when it is away.
    if not BarShown() and ns.Search and ns.Search.Show then ns.Search:Show(false) end
    if not dropdown:IsShown() then btn:Click() end
    if not dropdown:IsShown() then return end
    dropdown.arranging = true
    BuildRows(dropdown, dropdown.groupID)
end

function AppsMenu:StopArranging()
    local dropdown = self.dropdown
    if not dropdown then return end
    dropdown.arranging = nil
    if dropdown:IsShown() then BuildRows(dropdown, dropdown.groupID) end
end

-- Right-click on a tile: an app's own menu with Arrange added; a group's
-- menu, its name and its members.
function AppsMenu:ShowTileMenu(row)
    local dropdown, item = self.dropdown, row.item
    if item.app then
        if ns.ExtensionButtons then ns.ExtensionButtons:ShowAppMenu(row, item.app, { arrange = true }) end
        return
    end
    local g = item.group
    local s = Settings()
    Utils.ShowCursorMenu("EasyFindAppsTileMenu", {
        { text = L["EXTMENU_RENAME"], onClick = function() PromptGroupName(g, function() AppsMenu:Rebuild() end) end },
        { text = L["EXTMENU_UNGROUP"], onClick = function()
            local ids = s.order or TileIDs(dropdown)
            local at = #ids + 1
            for i = 1, #ids do if ids[i] == "group:" .. g.id then at = i end end
            RemoveID(ids, "group:" .. g.id)
            for k = #g.apps, 1, -1 do tinsert(ids, at, g.apps[k]) end
            s.order = ids
            g.apps = {}
            DeleteGroupIfEmpty(s, g)
            AppsMenu:Rebuild()
        end },
        { isSeparator = true },
        { text = L["EXTMENU_ARRANGE"], onClick = function() AppsMenu:StartArranging() end },
    }, {})
end

function AppsMenu:Create(searchFrame, filterBtn)
    if self.button then return self.button end

    -- No apps available this session (calculator companion disabled, nothing
    -- else installed): no button, and the editbox keeps its full width. Addon
    -- enable state cannot change without a reload, so one check at creation
    -- covers the session.
    local apps = ns.BuildApplicationEntries and ns.BuildApplicationEntries() or {}
    if #apps == 0 then return nil end

    local btn = CreateFrame("Button", "EasyFindUIAppsButton", searchFrame)
    btn:SetPoint("TOP", searchFrame, "TOP", 0, 0)
    btn:SetPoint("BOTTOM", searchFrame, "BOTTOM", 0, 0)
    -- Immediately left of the filter button, so the bar's right-hand controls
    -- read as one cluster. A slightly narrower button pulls the whole control
    -- (glyph AND its hover glow together) closer to the filter button, instead
    -- of nudging just the glyph, which left the glow offset. The +4 tucks it
    -- into the filter button's inner glow margin: with the old gold ring gone
    -- the visible gap between the two glyphs read too wide.
    btn:SetPoint("RIGHT", filterBtn, "LEFT", 4, 0)
    btn:SetWidth(searchFrame:GetHeight() - 6)
    btn:SetFrameLevel(searchFrame:GetFrameLevel() + 50)

    local glyph = CreateGridGlyph(btn, 16)
    glyph:SetPoint("CENTER")
    btn.glyph = glyph
    btn:SetHighlightTexture(130757)

    -- The editBox's right edge is anchored to the filter button, so it lies over
    -- this button's whole footprint. An EditBox is mouse-enabled for typing, so
    -- it eats every click meant for the button and the menu never opens. Pull
    -- the text field in to stop at the apps button's left edge instead.
    if searchFrame.editBox then
        searchFrame.editBox:SetPoint("RIGHT", btn, "LEFT", -4, 0)
    end

    -- Same strata/level as the filter dropdown, its proven sibling.
    local dropdown = CreateFrame("Frame", "EasyFindUIAppsDropdown", UIParent, "BackdropTemplate")
    dropdown:SetFrameStrata("DIALOG")
    -- Children need level headroom (rows +1, hover pill between); at 9999
    -- they clamp against the 10000 ceiling.
    dropdown:SetFrameLevel(9000)
    dropdown:EnableMouse(true)
    dropdown:Hide()
    ns.StyleMenuPanel(dropdown)

    -- Outside-click close, EVENT-driven like AttachOutsideClickClose: the
    -- event registers only while the menu is shown and fires only on actual
    -- clicks, so an open menu costs nothing per frame. (This replaced an
    -- every-frame OnUpdate poll that showed up as constant CPU whenever the
    -- menu was open.) GLOBAL_MOUSE_DOWN dispatches before click handlers
    -- run, so a click on a row still reads as inside.
    dropdown:HookScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    dropdown:HookScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    dropdown:SetScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if not (Utils.IsFrameVisiblyMouseOver(self) or Utils.IsFrameVisiblyMouseOver(btn)) then
            self:Hide()
        end
    end)

    -- Keyboard nav, armed only when the menu is OPENED from the keyboard
    -- (Tab to the apps button, Enter): same row-focus pattern as the filter
    -- popups. ESC/LEFT close just this menu and hand the keys back to the
    -- toolbar ring, so the apps button stays focused for the next press.
    -- Capturing keys here is also half the peer-exclusion fix: Tab cycles
    -- rows instead of walking on to the filter button while this is open.
    local appsFocus = 0
    local function SetAppsFocus(idx)
        local rows = dropdown.rows or {}
        local prev = rows[appsFocus]
        if prev and prev.SetMenuHighlightFocused then prev:SetMenuHighlightFocused(false) end
        appsFocus = idx
        local target = rows[idx]
        if target and target.SetMenuHighlightFocused then target:SetMenuHighlightFocused(true) end
    end
    local function VisibleAppRows()
        local rows = dropdown.rows or {}
        local n = 0
        for i = 1, #rows do
            if rows[i]:IsShown() then n = n + 1 end
        end
        return n
    end
    Utils.SafeCallMethod(dropdown, "EnableKeyboard", false)
    Utils.SafeCallMethod(dropdown, "SetPropagateKeyboardInput", false)
    dropdown:SetScript("OnKeyDown", function(self, key)
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        local count = VisibleAppRows()
        if (key == "DOWN" or key == "TAB") and count > 0 then
            SetAppsFocus(appsFocus % count + 1)
        elseif key == "UP" and count > 0 then
            SetAppsFocus((appsFocus - 2) % count + 1)
        elseif key == "ENTER" then
            local row = dropdown.rows and dropdown.rows[appsFocus]
            if row then row:Click() end
        elseif key == "ESCAPE" or key == "LEFT" then
            self:Hide()
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    end)
    dropdown:HookScript("OnHide", function(self)
        SetAppsFocus(0)
        Utils.SafeCallMethod(self, "EnableKeyboard", false)
        local nav = ns.Search and ns.Search.GetNavFrame and ns.Search:GetNavFrame()
        if nav and btn.keyboardFocused then
            Utils.SafeCallMethod(nav, "EnableKeyboard", true)
        end
    end)

    btn:SetScript("OnClick", function()
        if dropdown:IsShown() then
            dropdown:Hide()
            return
        end
        -- Rebuilt per open: an app that became available must appear without
        -- a reload.
        if BuildRows(dropdown) == 0 then return end

        -- Anchor maths lifted from the filter dropdown, including opening
        -- upward when results grow upward.
        local barScale = EasyFind.db.uiSearchScale or 1.0
        dropdown:SetScale(barScale)
        local scale = searchFrame:GetEffectiveScale() / (UIParent:GetEffectiveScale() * barScale)
        local left = btn:GetLeft() * scale
        dropdown:ClearAllPoints()
        if EasyFind.db.uiResultsAbove then
            dropdown:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, searchFrame:GetTop() * scale)
        else
            dropdown:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, searchFrame:GetBottom() * scale)
        end
        dropdown:Show()
        -- Opened from the toolbar ring (Tab + Enter): move keys from the
        -- nav frame into the menu and focus the first app.
        if btn.keyboardFocused then
            local nav = ns.Search and ns.Search.GetNavFrame and ns.Search:GetNavFrame()
            if nav then Utils.SafeCallMethod(nav, "EnableKeyboard", false) end
            Utils.SafeCallMethod(dropdown, "EnableKeyboard", true)
            SetAppsFocus(1)
        end
    end)

    -- The apps button stays engaged (its highlight locked) while its menu is
    -- open, like every other menu-owner button.
    -- Closed, the menu is back at its top level and locked.
    dropdown:HookScript("OnHide", function(self)
        self.arranging = nil
        self.groupID = nil
    end)
    dropdown:HookScript("OnShow", function() btn:LockHighlight() end)
    dropdown:HookScript("OnHide", function()
        -- The locked highlight doubles as the toolbar-ring focus visual.
        -- After a keyboard close (ESC back to the button) the ring still
        -- owns this button, so the light must stay on; unlocking here was
        -- why focus survived "under the hood" but showed nothing.
        if not btn.keyboardFocused then btn:UnlockHighlight() end
    end)

    -- Hover-reveal when "Show app button" is off: clickable at alpha 0 until
    -- its spot is hovered, focused, or this menu is open.
    Utils.InstallBarControlReveal(btn,
        function() return EasyFind.db.showAppsButton ~= false end,
        function() return dropdown:IsShown() end)
    dropdown:HookScript("OnShow", btn.RefreshReveal)
    dropdown:HookScript("OnHide", btn.RefreshReveal)

    self.button = btn
    self.dropdown = dropdown
    searchFrame.appsBtn = btn
    searchFrame.appsDropdown = dropdown

    -- Filter menu and apps menu are peers: opening one closes the other rather
    -- than stacking two panels over the same bar.
    if Results.CloseFilterDropdownIfOpen then
        btn:HookScript("OnClick", function()
            if dropdown:IsShown() then Results:CloseFilterDropdownIfOpen() end
        end)
    end
    return btn
end

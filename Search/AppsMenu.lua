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
    -- GPS opens its page under the map search tab, or its window by its
    -- menu's choice. Hidden when the GPS
    -- companion is disabled in the AddOns list.
    if not (ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_GPS")) then
        apps[#apps + 1] = {
            name = L["APP_GPS"],
            experimental = L["GPS_EXP_TT"],
            gpsLauncher = true,
            noPin = true,
            icon = ns.GPS_ICON_TEX,
            nativeRun = function()
                if ns.GPS and ns.GPS.Launch then ns.GPS:Launch() end
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
    { "quicklists", "quicklistsLauncher" },
    { "chat", "chatLauncher" },
}
-- What each extension does, one line under its name in its tooltips.
local APP_DESC_KEYS = {
    calculator = "APP_DESC_CALCULATOR", icons = "APP_DESC_ICONS", snippets = "APP_DESC_SNIPPETS",
    clipboard = "APP_DESC_CLIPBOARD", notes = "APP_DESC_NOTES", gps = "APP_DESC_GPS",
    quicklists = "APP_DESC_QUICKLISTS", chat = "APP_DESC_CHAT",
}
function ns.ApplicationDescription(app)
    local key = APP_DESC_KEYS[ns.ApplicationEntryID(app) or ""]
    return key and L[key] or app and app.description or nil
end

function ns.ApplicationEntryID(app)
    if not app then return nil end
    if app.quicklistID then return "quicklist:" .. app.quicklistID end
    for i = 1, #APP_ID_FLAGS do
        if app[APP_ID_FLAGS[i][2]] then return APP_ID_FLAGS[i][1] end
    end
    return nil
end
-- An extension's launcher row (calculator, chat, GPS, ...): the apps glyph
-- on its left, its own on its right. Snippets' menu row and a single
-- quicklist keep their own looks. Every place that asks uses this.
function ns.IsApplicationLauncher(data)
    return data ~= nil and not data.quicklistID and not data.snippetsLauncher
        and ns.ApplicationEntryID(data) ~= nil
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
    if app.chatLauncher then
        return ns.Chat ~= nil and ns.Chat.IsOpen ~= nil and ns.Chat:IsOpen() or false
    end
    if app.gpsLauncher then
        if ns.GPS and ns.GPS.LaunchesWindow and ns.GPS.LaunchesWindow() then return ns.GPS:IsWindowOpen() end
        local MapTab = ns.MapTab
        return WorldMapFrame ~= nil and WorldMapFrame:IsShown() and MapTab ~= nil and MapTab.IsPageShowing ~= nil
            and MapTab:IsPageShowing("gps") or false
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
    if app.chatLauncher then
        if ns.Chat and ns.Chat.Close then ns.Chat:Close() end
        return
    end
    -- The GPS opened the map at its page: the map closes the way it opened.
    if app.gpsLauncher then
        if ns.GPS and ns.GPS.LaunchesWindow and ns.GPS.LaunchesWindow() then return ns.GPS:CloseWindow() end
        if WorldMapFrame and WorldMapFrame:IsShown() and ToggleWorldMap then ToggleWorldMap() end
        return
    end
    if app.snippetsLauncher and ns.Options and ns.Options.Hide then
        ns.Options:Hide()
    end
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

-- Counts an extension reports (Chat: messages unread), drawn as a red
-- count badge on its icon wherever the icon sits: the extensions menu and
-- an extension button on screen.
local appBadges = {}
-- The badge digits: one row of textures/badge-digits.tga (dev tools:
-- badge_digits.py), per glyph its texcoords across and its advance in em;
-- every glyph is the digits' ink band tall, so the group centers by its ink.
local BADGE_DIGIT_TEX = "Interface\\AddOns\\EasyFind\\textures\\badge-digits"
local BADGE_DIGIT_BAND = 0.8106
local BADGE_DIGIT_V0, BADGE_DIGIT_V1 = 0.19603, 0.80397
local BADGE_DIGITS = {
    ["0"] = { 0.01400, 0.07584, 0.6597 },
    ["1"] = { 0.11494, 0.15459, 0.4229 },
    ["2"] = { 0.19540, 0.25381, 0.6230 },
    ["3"] = { 0.28463, 0.34428, 0.6362 },
    ["4"] = { 0.37308, 0.43552, 0.6660 },
    ["5"] = { 0.46544, 0.52284, 0.6123 },
    ["6"] = { 0.55400, 0.61397, 0.6396 },
    ["7"] = { 0.64682, 0.70084, 0.5762 },
    ["8"] = { 0.73367, 0.79368, 0.6401 },
    ["9"] = { 0.82353, 0.88350, 0.6396 },
    ["+"] = { 0.91182, 0.97490, 0.6729 },
}
local badgeTiles = setmetatable({}, { __mode = "k" })
local PaintTileBadge
function ns.SetApplicationBadge(id, count)
    count = (type(count) == "number" and count > 0) and count or nil
    if not id or appBadges[id] == count then return end
    appBadges[id] = count
    for row in pairs(badgeTiles) do
        if row:IsShown() and row.item then PaintTileBadge(row) end
    end
    if ns.ExtensionButtons and ns.ExtensionButtons.RefreshBadges then ns.ExtensionButtons:RefreshBadges() end
end

function ns.GetApplicationBadge(id)
    return id and appBadges[id] or nil
end

-- A count in a pill, as chat apps badge: the number, 99+ past it; hidden
-- at none. SetCount(n, r, g, b) paints it (red when no color is given).
function ns.CreateCountBadge(parent, height)
    local badge = CreateFrame("Frame", nil, parent)
    badge._efNoAutoRetint = true
    badge:SetSize(height, height)
    ns.CreateRoundedRectBorder(badge)
    ns.SetRoundedRectBarHeight(badge, height)
    ns.SetRoundedRectBorderBgAlpha(badge, 1)
    ns.SetRoundedRectBorderEdgeShown(badge, false)
    -- The number from glyph textures, its group centered on the pill.
    local em = height * 0.66
    badge.glyphs = {}
    function badge:SetCount(n, r, g, b)
        if not n or n <= 0 then self:Hide() return end
        local s = n > 99 and "99+" or tostring(n)
        local total = 0
        for i = 1, #s do total = total + BADGE_DIGITS[s:sub(i, i)][3] * em end
        self:SetWidth(math.max(height, math.ceil(total + height * 0.55)))
        local x = -total / 2
        for i = 1, #s do
            local d = BADGE_DIGITS[s:sub(i, i)]
            local glyph = self.glyphs[i]
            if not glyph then
                glyph = self:CreateTexture(nil, "OVERLAY")
                glyph:SetTexture(BADGE_DIGIT_TEX)
                self.glyphs[i] = glyph
            end
            local w = d[3] * em
            glyph:SetTexCoord(d[1], d[2], BADGE_DIGIT_V0, BADGE_DIGIT_V1)
            glyph:SetSize(w, BADGE_DIGIT_BAND * em)
            glyph:ClearAllPoints()
            glyph:SetPoint("CENTER", self, "CENTER", x + w / 2, 0)
            glyph:Show()
            x = x + w
        end
        for i = #s + 1, #self.glyphs do self.glyphs[i]:Hide() end
        ns.SetRoundedRectFill(self, r or 0.89, g or 0.22, b or 0.21, 1, true)
        self:Show()
    end
    badge:Hide()
    return badge
end

PaintTileBadge = function(row)
    local item = row.item
    local n = 0
    if item.group then
        for _, id in ipairs(item.group.apps) do n = n + (appBadges[id] or 0) end
    elseif item.app then
        n = appBadges[ns.ApplicationEntryID(item.app) or ""] or 0
    end
    if n == 0 and not row.badge then return end
    if not row.badge then
        row.badge = ns.CreateCountBadge(row, 11)
        row.badge:SetFrameLevel(row:GetFrameLevel() + 4)
        row.badge:SetPoint("CENTER", row.icon, "TOPRIGHT", -1, -1)
    end
    row.badge:SetCount(n)
end

-- An extension's own rows on its icon's right-click menu (Chat: Mark all
-- as read), as ShowTogglePopup defs: fn() returns a list, or nil for none.
local appMenuRows = {}
function ns.RegisterApplicationMenuRows(id, fn)
    if id then appMenuRows[id] = fn end
end

function ns.ApplicationMenuRows(id)
    local fn = id and appMenuRows[id]
    return fn and fn() or nil
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

-- The menu's settings: columns, where a label sits and its size, the
-- order dragged into place and the groups. Kept with the profile.
local LABEL_POSITIONS = { "right", "below", "above", "left", "hidden" }
AppsMenu.LABEL_POSITIONS = LABEL_POSITIONS
AppsMenu.LABEL_SIZES = { { "OPT_FONT_SMALL", 0.85 }, { "OPT_FONT_MED", 1 }, { "OPT_FONT_LARGE", 1.15 }, { "OPT_FONT_XL", 1.3 } }
local TILE_ICON = 20      -- the icon of a stacked or bare tile
local GAP = 4             -- between tiles
local GROUP_HOLD = 0.45   -- seconds a dragged tile rests on another before they group
local BuildRows
local function Settings()
    local db = EasyFind and EasyFind.db
    if not db then return { columns = 1, labels = "right", labelSize = 1 } end
    local s = db.appsMenu
    if not s then s = {} db.appsMenu = s end
    s.columns = s.columns or 1
    s.labels = s.labels or "right"
    s.labelSize = s.labelSize or 1
    s.font = nil   -- the label font once chosen here; the global font rules now
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
        -- The release that ends a drag is no click.
        if self._efDragged then
            self._efDragged = nil
            return
        end
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
        dropdown:Hide()
        ns.ToggleApplication(item.app)
    end)
    row:HookScript("OnEnter", function(self)
        local item = self.item
        if not item or item.back then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(item.name or "")
        local desc = item.app and ns.ApplicationDescription(item.app)
        if desc then GameTooltip:AddLine(desc, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    row:HookScript("OnLeave", function() GameTooltip:Hide() end)
    -- A drag moves the tile within the menu; carried past the menu's edge
    -- it becomes a button on the screen (Search/ExtensionButtons.lua).
    -- Press-and-move, not the frame drag events (those depend on the row
    -- keeping the mouse, which a menu row does not always get): a press
    -- followed by movement past a few pixels while the button is still
    -- held starts the drag.
    row:HookScript("OnMouseDown", function(self, button)
        local item = self.item
        self._efDragged = nil
        if button ~= "LeftButton" or not item or item.back then return end
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
            row2._efDragged = true
            AppsMenu:BeginArrangeDrag(dropdown, row2)
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
    badgeTiles[row] = true
    if item.back then
        if row.badge then row.badge:Hide() end
    else
        PaintTileBadge(row)
    end
    row.label:SetText(item.name or "")
    -- Same font as result-row titles (pathFont), like every menu, at the
    -- labels' own size.
    local theme = Results.GetActiveTheme and Results:GetActiveTheme()
    Results:SetScaledFont(row.label, (theme and theme.pathFont) or ns.LEAF_FONT)
    local scale = Settings().labelSize
    if scale ~= 1 then
        local file, size, flags = row.label:GetFont()
        if file and size then row.label:SetFont(file, size * scale, flags) end
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

-- A tile's own width: its label and badge beside or under the icon.
local function TileWidth(row, labels)
    if labels == "hidden" then return 32 end
    local w = (row.label:GetStringWidth() or 0) + (row.expTag and row.expTag:IsShown() and row.expTag:GetWidth() + 1 or 0)
    if labels == "below" or labels == "above" then return math.min(140, math.max(TILE_ICON, w) + 12) end
    return math.min(188, ICON + 8 + w + 10)
end

-- The grid: each column as wide as its widest tile, every row as tall as
-- the labels setting makes a tile. Returns the column widths, the tile
-- height and the column count.
local colWidths = {}
local function TileMetrics(dropdown, n)
    local s = Settings()
    local cols = math.max(1, math.min(4, s.columns))
    local fontH = 12
    wipe(colWidths)
    -- One column keeps its old floor so a short list does not shrink to a sliver.
    local floor = (s.labels == "below" or s.labels == "above") and 52 or (s.labels == "hidden" and 32)
        or (cols == 1 and 78 or 0)
    for c = 1, cols do colWidths[c] = floor end
    for i = 1, n do
        local row = dropdown.rows[i]
        local c = (i - 1) % cols + 1
        colWidths[c] = math.max(colWidths[c], TileWidth(row, s.labels))
        fontH = row.label:GetStringHeight() or fontH
    end
    local h
    if s.labels == "below" or s.labels == "above" then h = TILE_ICON + 4 + fontH + 10
    elseif s.labels == "hidden" then h = 32
    else h = math.max(ROW_H, math.ceil(fontH) + 10) end
    return colWidths, h, cols
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
    local widths, h, cols = TileMetrics(dropdown, #items)
    local used = math.min(cols, #items)
    for i = 1, #items do
        local row = dropdown.rows[i]
        local r, c = math.floor((i - 1) / cols), (i - 1) % cols + 1
        local x = PAD
        for k = 1, c - 1 do x = x + widths[k] + GAP end
        row.index = i
        row:SetSize(widths[c], h)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", dropdown, "TOPLEFT", x, -PAD - r * (h + GAP))
    end
    local lines = math.ceil(#items / cols)
    local menuW = PAD * 2 + (used - 1) * GAP
    for k = 1, used do menuW = menuW + widths[k] end
    dropdown:SetSize(menuW, PAD * 2 + lines * h + (lines - 1) * GAP)
    return #items
end

-- The menu built again where it stands, after a setting or an arrangement.
function AppsMenu:Rebuild()
    local dropdown = self.dropdown
    if dropdown and dropdown:IsShown() then BuildRows(dropdown, dropdown.groupID) end
end

-- Arranging, always on: a dragged tile drops between others for an order;
-- held on another a moment it groups with it, or joins the group it rests
-- on; held on the back tile inside a group it leaves the group. Carried
-- past the menu's edge, an extension becomes a button on the screen.

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

-- Where a drag would land: the tile it rests on that it may group with
-- (its middle), and the slot before or after the nearest tile along the
-- flow; the hold decides which of the two the drop takes.
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
    local joins = best.item.back or (best.item.group and from.item.app)
        or (best.item.app and from.item.app and not dropdown.groupID)
    local candidate = joins and math.abs(x - (l + w / 2)) < w * 0.3 and math.abs(y - (b + h / 2)) < h * 0.3
        and best or nil
    if best.item.back then return candidate, nil end
    local after
    if Settings().columns > 1 then after = x > l + w / 2 else after = y < b + h / 2 end
    return candidate, after and best.index + 1 or best.index
end

local function StopGhost(ghost)
    ghost:SetScript("OnUpdate", nil)
    ghost:Hide()
    ghost.line:Hide()
    ghost.target:Hide()
    ghost.from:SetAlpha(1)
end

local function EndArrangeDrag(dropdown)
    local ghost = dropdown.ghost
    StopGhost(ghost)
    local from = ghost.from
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
    ghost.resting, ghost.restSince = nil, nil
    row:SetAlpha(0.35)
    ghost:Show()
    ghost:SetScript("OnUpdate", function(self)
        local cx, cy = GetCursorPosition()
        local scale = dropdown:GetEffectiveScale()
        local x, y = cx / scale - dropdown:GetLeft(), cy / scale - dropdown:GetBottom()
        local outside = x < -8 or y < -8 or x > dropdown:GetWidth() + 8 or y > dropdown:GetHeight() + 8
        -- Past the edge an extension leaves the menu for a button on the
        -- screen; a group stays, and a drop out there changes nothing.
        if outside and row.item.app and ns.ExtensionButtons then
            StopGhost(self)
            dropdown:Hide()
            ns.ExtensionButtons:BeginDragFromMenu(row.item.app)
            return
        end
        self:ClearAllPoints()
        self:SetPoint("CENTER", dropdown, "BOTTOMLEFT", x, y)
        local candidate, slot = nil, nil
        if not outside then candidate, slot = DropTarget(dropdown, x, y, row) end
        -- Resting on a tile a moment groups with it; passing over reorders.
        if candidate ~= self.resting then
            self.resting, self.restSince = candidate, GetTime()
        end
        local over = candidate and GetTime() - self.restSince >= GROUP_HOLD and candidate or nil
        if over then slot = nil end
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

-- Right-click on a tile: an app's own menu; a group's, its name and
-- ungrouping.
function AppsMenu:ShowTileMenu(row)
    local dropdown, item = self.dropdown, row.item
    if item.app then
        if ns.ExtensionButtons then ns.ExtensionButtons:ShowAppMenu(row, item.app) end
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
    -- A setting changed while it is open can widen it: it stays on screen.
    dropdown:SetClampedToScreen(true)
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
        -- A grid wider than the room right of the button opens leftward.
        local room = UIParent:GetWidth() / barScale
        if left + dropdown:GetWidth() > room then left = math.max(0, room - dropdown:GetWidth()) end
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

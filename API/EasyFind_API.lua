---@meta
-- EasyFind.API for the Lua language server: put this file in your
-- workspace and EasyFind.API completes with its functions and fields.
-- Not loaded by the game. The guide: API/README.md.

---@class EasyFindExtension
---@field id string Required. Letters, digits, - and _; keep it stable.
---@field name? string Required the first time: the tile's name.
---@field description? string One line under the name in tooltips.
---@field icon? string|number Required the first time: white line art, painted in the theme's icon color.
---@field iconCoords? number[] { left, right, top, bottom }
---@field open? fun() Opens the extension.
---@field close? fun() Closes it.
---@field isOpen? fun(): boolean
---@field menu? fun(): EasyFindMenuRow[] Rows for the tile's right-click menu.
---@field settings? fun(page: Frame, kit: EasyFindSettingsKit) Builds its settings page.
---@field keywords? string[] Words that find its launcher row.
---@field hideFromSearch? boolean No launcher row in the search bar.
---@field scope? string Its surface is that @scope's list in the search bar.
---@field experimental? string A line of warning in its tooltip.
---@field addon? string A load-on-demand addon holding the rest.
---@field loadInCombat? boolean Its addon may load, and it may open, in combat.
---@field loadAtLogin? boolean Its addon loads at login, not on first open.

---@class EasyFindMenuRow
---@field kind "action"|"check"|"separator"|"menu"
---@field label? string
---@field tooltip? string
---@field onClick? fun() An action row's command.
---@field get? fun(): boolean A check row's state.
---@field set? fun(on: boolean) Stores a check row's state.
---@field rows? EasyFindMenuRow[]|fun(): EasyFindMenuRow[] A menu row's flyout.

---@class EasyFindSearchProvider
---@field key string Required: its filter key and @scope key.
---@field label? string Required the first time: what its rows are, on its scope pill; the Extensions flyout shows its extension's name.
---@field category? string The name its rows carry; key when not given.
---@field icon? string|number Required the first time, unless its extension has one: the glyph left of each of its rows.
---@field iconCoords? number[]
---@field rows? fun(): EasyFindRow[] Its rows.
---@field select? fun(row: EasyFindRow) A click or Enter on a row (a copy).
---@field tooltip? fun(row: EasyFindRow, tooltip: GameTooltip): boolean Fill it; true shows it.
---@field leave? fun(row: EasyFindRow) The cursor left a row.
---@field words? string[] Typing one loads its rows.
---@field eager? boolean Searched from the first keystroke (small lists).
---@field lazy? boolean Only through its words, filter or scope.
---@field lowResults? boolean Also loaded when a search finds little.
---@field aliases? string[] An @scope: @ and one of these lists only its rows.
---@field browse? fun(row: EasyFindRow): boolean Whether the row is in the scope's list while nothing is typed; every row without it.
---@field place? fun(row: EasyFindRow): { name: string, mapID: number, x: number, y: number, step: string? }|nil Where the row is now: its rows are found from the map search and the GPS too.
---@field link? EasyFindLink A row's EasyFind link carries your key; the receiver's copy resolves it.
---@field menu? fun(row: EasyFindRow): EasyFindMenuRow[]|nil Rows for the result's right-click menu, under your extension's name.

---@class EasyFindAddTarget
---@field key string Required; registering it again replaces it.
---@field extension string Required, registered first: its icon marks the entry.
---@field label string Required: its name in the Add flyout.
---@field fullLabel? string Its name as the menu's only Add entry; label when not given.
---@field applies? fun(row: EasyFindRow): boolean The rows it takes; every row without it.
---@field rows fun(row: EasyFindRow): EasyFindMenuRow[]|nil Required: the flyout's rows.
---@field onClick? fun(row: EasyFindRow) A click on the entry itself; its flyout opens on hover.
---@field new? fun() Makes a new, empty one: Notes' + menu lists it, with newLabel.
---@field newLabel? string Its New entry's name ("New shopping list"); needed with new.

---@class EasyFindLink
---@field key fun(row: EasyFindRow): string|nil A short string the link carries (an id, the sender's progress).
---@field resolve fun(tail: string): EasyFindRow|nil The row the receiver shows for it.
---@field options? EasyFindOption[] Toggles on its filter row's flyout.
---@field extension? string The extension it belongs to.
---@field loadOnSearch? boolean|fun(): boolean Load that extension's addon for its rows.
---@field hint? string|EasyFindHint|fun(row: EasyFindRow): string|EasyFindHint What a row's gestures do, under its name on hover.

---@class EasyFindHint
---@field click? string The click's target ("Directions").
---@field alt? string
---@field ctrl? string
---@field shift? string

---@class EasyFindRow
---@field name string What is searched and shown.
---@field icon? string|number Shown at the row's right, in its own colors.
---@field keywords? string[] More words that find it.
---@field searchCommandDesc? string Its subtext.
---@field hint? string|EasyFindHint|fun(row: EasyFindRow): string|EasyFindHint This row's own hint.
---@field mapID? number The map it is on, for the map search's list of that map.

---@class EasyFindOption
---@field label? string|fun(): string
---@field tooltip? string|fun(): string
---@field get? fun(): boolean
---@field set? fun(on: boolean)
---@field header? string A caption over the rows that follow.
---@field separator? boolean A line between groups.

---@class EasyFindSettingsKit
---@field Font fun(name: string): string The settings window's own font for a game font's name (2 pt larger); use it for any text a page makes itself.
---@field ROW_WIDTH number
---@field BUTTON_WIDTH number
local kit = {}
---@return Region below Anchor the next control to it.
function kit.Title(page, title, hint) end
---@param get fun(): boolean
---@param set fun(on: boolean)
---@return CheckButton
function kit.Checkbox(page, label, get, set, tooltip) end
---@param choices { label: string, value: any, disabled?: fun(): boolean }[] disabled: grayed, no click.
---@param get fun(): any
---@param set fun(value: any)
---@return Frame
function kit.Choice(page, label, choices, get, set, tooltip, default) end
---@param get fun(): number
---@param set fun(value: number)
---@return Frame
function kit.Stepper(page, label, min, max, step, get, set, tooltip, width) end

---@class EasyFindSettingsRow
---@field name string The setting's label.
---@field path? string|string[] Where it sits in your window.
---@field keywords? string[] More words that find it.
---@field open fun() Shows your window at it.
---@field control? EasyFindSettingsControl Changed on the row itself.

---@class EasyFindSettingsControl
---@field kind "check"|"radio"|"slider"|"choice"|"button"
---@field get? fun(): any check and radio: boolean; slider: number; choice: a choice's value.
---@field set? fun(value: any)
---@field min? number slider
---@field max? number slider
---@field step? number slider
---@field format? fun(n: number): string slider: the value text.
---@field choices? { value: any, label: string }[]|fun(): { value: any, label: string }[] choice
---@field press? fun() button
---@field tooltip? string Under the name.

---@class EasyFindDialog
---@field text string
---@field acceptText? string
---@field cancelText? string
---@field hasEditBox? boolean
---@field editBoxDefault? string
---@field onAccept? fun(value: string?)
---@field single? boolean One button only.

---@alias EasyFindThemeRole "background"|"panel"|"border"|"line"|"text"|"textDim"|"heading"|"accent"|"selection"|"glyph"

EasyFind = {}

---@class EasyFindAPI
EasyFind.API = {
    ---Rises only for a change that breaks an extension.
    VERSION = 1,
    ---Rises when something is added.
    MINOR = 0,
}
local API = EasyFind.API

-- ==== extensions ==============================================================

---Adds the extension, or adds to one registered with the same id.
---@param def EasyFindExtension
---@return boolean
function API.RegisterExtension(def) end
---@return boolean
function API.IsExtensionRegistered(id) end
---Opens it as a click on its tile would.
---@return boolean
function API.OpenExtension(id) end
function API.CloseExtension(id) end
---@return boolean
function API.ToggleExtension(id) end
---@return boolean
function API.IsExtensionOpen(id) end
---Loads its addon if it loads on demand; true when it is in.
---@return boolean
function API.LoadExtension(id) end
---A count on its icon; 0 or nil clears it.
---@param count integer?
function API.SetBadge(id, count) end
---Your window showed or hid: its micro menu button follows.
function API.NotifyOpenChanged(id) end

-- ==== search ==================================================================

---Adds search results, or adds to a provider registered with the same key.
---@param def EasyFindSearchProvider
---@return boolean
function API.RegisterSearchProvider(def) end
---An entry in a result's right-click Add flyout, wearing its extension's icon.
---@param def EasyFindAddTarget
---@return boolean
function API.RegisterAddTarget(def) end
---Its rows changed: rebuilt now, and an open search shows them.
function API.RefreshSearchProvider(key) end
---Shows the search bar focused, with text searched when given.
---@param text string?
---@return boolean
function API.OpenSearch(text) end
---Shows the search bar on that @scope's list.
---@param text string?
---@return boolean
function API.ShowScope(key, text) end

-- ==== actions and events ======================================================

---@param fn fun(...): any
function API.RegisterAction(id, name, fn) end
---Runs another extension's action (loading it first if needed) and
---returns what it returns; nothing when there is no such action.
---@return any ...
function API.CallAction(id, name, ...) end
---@return boolean
function API.HasAction(id, name) end
---@param fn fun(...)
function API.On(id, event, fn) end
function API.Off(id, event, fn) end
function API.Fire(id, event, ...) end

-- ==== linked checklists ========================================================

---@class EasyFindChecklistEntry
---@field ref string        the extension's own key for the entry
---@field line { item: integer?, link: string?, target: number?, text: string? }

---@class EasyFindChecklistLinks
---@field changed fun(noteID: integer, key: string, lines: table[])? the player's edits, every line in order
---@field shown fun(noteID: integer, key: string)? the note opened in Notes: sync it now
---@field category { key: string, label: string }? a note category of your own, your notes filed under it
---@field items boolean? names typed in your notes are items, each with a count, and the editor suggests them

---Hears a linked checklist's edits and openings for this extension.
---@param handlers EasyFindChecklistLinks
function API.LinkChecklists(id, handlers) end
---The extension's checklist note for key; made (titled) when make.
---@return integer? noteID
function API.LinkedChecklist(id, key, title, make) end
---The extension's list into the note, by ref: lines added, updated, dropped.
---@param entries EasyFindChecklistEntry[]
---@return boolean
function API.SyncChecklist(noteID, entries) end
---@param refs table<integer, string> lineID -> ref
function API.SetChecklistRefs(noteID, refs) end
function API.OpenNote(noteID) end

-- ==== settings ================================================================

---@return boolean
function API.OpenSettings(id) end
---@return boolean
function API.IsSettingsOpen(id) end
function API.CloseSettings() end
---Settings of your own window, found from the search bar.
---@param addon string Your name as the game's AddOns list shows it.
---@param rows fun(): EasyFindSettingsRow[]
---@return boolean
function API.RegisterSettingsIndex(addon, rows) end
---Its rows changed: read again.
function API.RefreshSettingsIndex(addon) end

-- ==== chat ====================================================================

-- A frame of yours that belongs beside the game's chat (an opener, a
-- button): hidden and shown with the chat frames by "Toggle Chat Frame".
---@param frame Frame
function API.RegisterChatPiece(frame) end

-- ==== theme and look ==========================================================

---@param role EasyFindThemeRole
---@return number r, number g, number b, number a
function API.GetThemeColor(role) end
---@return boolean
function API.IsLightTheme() end
---@param fn fun()
function API.OnThemeChanged(fn) end
---@generic F : Frame
---@param frame F
---@return F
function API.StylePanel(frame) end
---@return Button
function API.CreateButton(parent, text, width, height) end
---@param opts EasyFindDialog
function API.ShowDialog(opts) end

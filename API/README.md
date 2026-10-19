# EasyFind extension API

EasyFind is a search bar for World of Warcraft. Its extensions menu, search results, filter menu and settings panel are open to other addons through `EasyFind.API`. EasyFind's own extensions (Calculator, Icon Search, Snippets, Clipboard History, Notes, GPS, Quicklists, Chat) are built on the same API, so anything they do, yours can do.

What an extension can add:

- A tile in the extensions menu, with its icon, a description, a count badge and its own right-click rows. Users can drag it onto the screen or the micro menu like any other.
- Search results: its own rows in the search bar, a row under Extensions in the filter menu, an `@scope` that lists only its rows, and what a click on a row does.
- A settings page in Options > Extensions, built with EasyFind's own controls.
- Actions other extensions can call, and events they can listen to.

## Version

```lua
EasyFind.API.VERSION -- 1
EasyFind.API.MINOR   -- rises when something is added
```

`VERSION` changes only for a change that would break an extension. Check it once at load if you use something added later:

```lua
local API = EasyFind and EasyFind.API
if not (API and API.VERSION == 1) then return end
```

## Quick start

A complete extension: a tile that prints a line, found by typing its name.

`EasyFind_Hello.toc`:

```
## Interface: 120105, 16001
## Title: Hello for EasyFind
## Dependencies: EasyFind

Hello.lua
```

`Hello.lua`:

```lua
local API = EasyFind.API

API.RegisterExtension({
    id = "hello",
    name = "Hello",
    description = "Says hello.",
    icon = 134400,
    open = function() print("Hello from an EasyFind extension") end,
})
```

Type `hel` in the search bar, or open the extensions menu: the tile is there.

A fuller example, a bookmarks extension with its own search results, scope, settings page, action and event, is in [`API/example/EasyFind_Bookmarks`](example/EasyFind_Bookmarks).

## Supporting EasyFind without requiring it

Most addons that add EasyFind support should keep working without it. List EasyFind as an optional dependency, and register only when it is there:

```
## OptionalDeps: EasyFind
```

```lua
if EasyFind and EasyFind.API then
    EasyFind.API.RegisterSearchProvider({ ... })
end
```

That is the whole cost: users without EasyFind see nothing different.

## Extensions

### RegisterExtension(def)

| Field | Type | |
| --- | --- | --- |
| `id` | string | Required. Letters, digits, `-` and `_`. Keep it the same across versions: menu layouts and buttons on screen save it. |
| `name` | string | Required the first time. Shown on the tile, its tooltip and its launcher row. |
| `description` | string | One line under the name in tooltips. |
| `icon` | texture path or file id | The tile's icon. |
| `iconCoords` | `{ left, right, top, bottom }` | Texture coordinates for `icon`. |
| `tint` | boolean | `true` for white line art: drawn in the theme's icon color, like EasyFind's own. Otherwise the icon keeps its colors. |
| `open` | function | Opens the extension. |
| `close` | function | Closes it. |
| `isOpen` | function | Returns whether it is open. With `close`, a second click on the tile closes what the first opened. |
| `menu` | function | Returns rows for the tile's right-click menu (below). |
| `settings` | function `(page, kit)` | Builds its settings page. See [Settings pages](#settings-pages). |
| `keywords` | string list | Words that find its launcher row in the search bar. Its name always does. |
| `hideFromSearch` | boolean | No launcher row in the search bar (for an extension whose own rows already stand there). |
| `scope` | string | Its surface is that `@scope`'s list in the search bar: opening shows it, the tile is open while it is up. No `open` needed. |
| `experimental` | string | A line of warning in its tooltip. |
| `addon` | string | A load-on-demand addon holding the rest. See [Load on demand](#load-on-demand). |
| `loadInCombat` | boolean | Its addon may load in combat. Leave it off if your addon creates secure frames at load. |

An extension with only `settings` opens its settings page when clicked.

Menu rows, on top of EasyFind's own (its settings, its button on screen):

| Row | |
| --- | --- |
| `{ kind = "action", label = text, onClick = fn, tooltip = text }` | A command. |
| `{ kind = "check", label = text, get = fn, set = fn }` | A switch: `get()` returns it, `set(on)` stores it. |
| `{ kind = "separator" }` | A line between groups. |

Registering an id again adds to it, which is how a load-on-demand extension fills in its tile later.

### Other extension functions

| Function | |
| --- | --- |
| `OpenExtension(id)` | Opens it as a click on its tile would. |
| `CloseExtension(id)` | |
| `ToggleExtension(id)` | |
| `IsExtensionOpen(id)` | |
| `IsExtensionRegistered(id)` | |
| `LoadExtension(id)` | Loads its addon if it loads on demand. True when it is registered and its addon (if any) is loaded. |
| `SetBadge(id, count)` | A count on its icon wherever the icon shows. `0` or `nil` clears it. |
| `NotifyOpenChanged(id)` | Call when your window shows or hides, so its button on the micro menu shows pressed or not. |

## Search results

### RegisterSearchProvider(def)

| Field | Type | |
| --- | --- | --- |
| `key` | string | Required. Its filter key, and its `@scope` key when it has `aliases`. |
| `label` | string | Required the first time. Its row in the filter menu and its scope's pill. |
| `category` | string | The name its rows carry. Defaults to `key`. |
| `icon`, `iconCoords`, `tint` | | The glyph left of each of its rows, as for an extension. |
| `rows` | function | Returns its rows (below). Called when its rows are first needed and after `RefreshSearchProvider`. |
| `select` | function `(row)` | A click or Enter on one of its rows. Gets a copy of the row. |
| `tooltip` | function `(row, tooltip)` | Fills `GameTooltip` for a row. Return `true` to show it. |
| `leave` | function `(row)` | The cursor left one of its rows. |
| `words` | string list | Typing one loads its rows. |
| `eager` | boolean | Its rows are searched from the first keystroke. For small lists only. |
| `lazy` | boolean | Its rows show only through its words, its filter or its scope, never in plain results. |
| `lowResults` | boolean | Also loaded when a search finds little. |
| `aliases` | string list | An `@scope`: `@` and one of these lists only its rows. |
| `options` | list | Toggles on its filter row's flyout: `{ label, tooltip, get, set }`, `{ header = text }`, `{ separator = true }`. `label` and `tooltip` may be functions. |
| `extension` | string | The extension it belongs to. Its addon loading on demand, `select` loads it first. An extension whose addon is turned off shows no filter row or scope. |
| `loadOnSearch` | boolean or function | Load the extension's addon when its rows are first needed. |

A row is a table:

| Field | |
| --- | --- |
| `name` | Required. What is searched and shown. |
| `icon` | Texture path or file id, shown at the row's right. |
| `keywords` | More words that find it. |
| `searchCommandDesc` | Its subtext: a dim note shown with the name. |
| anything else | Kept on the row: `select` and `tooltip` get it back. |

```lua
API.RegisterSearchProvider({
    key = "bookmarks", label = "Bookmarks", icon = 134400,
    words = { "bookmark", "bookmarks" }, eager = true, aliases = { "bm" },
    rows = function()
        local out = {}
        for i, b in ipairs(MyBookmarks) do
            out[i] = { name = b.name, bookmarkIndex = i }
        end
        return out
    end,
    select = function(row) GoTo(MyBookmarks[row.bookmarkIndex]) end,
})
```

### RefreshSearchProvider(key)

Your rows changed: they are rebuilt now, and an open search shows them.

### The search bar

| Function | |
| --- | --- |
| `OpenSearch(text)` | Shows the search bar focused, with `text` searched when given. |
| `ShowScope(key, text)` | Shows the search bar on that `@scope`'s list. |

## Actions and events

Extensions talk to each other through actions (functions called by name) and events (news others listen for). The caller never needs the other addon loaded: calling an action of a load-on-demand extension loads it first.

| Function | |
| --- | --- |
| `RegisterAction(id, name, fn)` | Offers `fn` as an action of your extension. |
| `CallAction(id, name, ...)` | Runs it and returns what it returns, or nothing when there is no such action. |
| `HasAction(id, name)` | |
| `On(id, event, fn)` | Runs `fn(...)` each time that extension fires the event. |
| `Off(id, event, fn)` | |
| `Fire(id, event, ...)` | Tells every listener of your extension's event. |

```lua
-- Directions to a spot, if the GPS is installed.
API.CallAction("gps", "navigate", { name = "Booty Bay", mapID = 210, x = 0.41, y = 0.73 })

-- Hear when a route ends.
API.On("gps", "arrived", function(dest) print("Arrived at", dest.name) end)
```

What EasyFind's own extensions offer:

| Extension | Action | |
| --- | --- | --- |
| `gps` | `navigate(dest, opts)` | Directions to `dest` = `{ name, mapID, x, y }`, map coordinates 0 to 1. `opts.popout` opens them in the GPS window. Returns true when a route is planned. |
| `gps` | `canNavigate(dest)` | Whether the GPS can find a way there. |
| `gps` | `setStart(dest)` | Plans the next route from there, not from the player. |
| `gps` | `clear()` | Ends the route. |
| `notes` | `openUnitNote(entry)` | Opens the note on a player or thing: `{ type = "player", id = "Name-Realm", name = "Name" }`. |
| `notes` | `findUnitNote(entry)` | Whether there is one. |
| `notes` | `insertText(text)` | Puts text into the open note at its cursor. |
| `snippets` | `run(name)` | Fires a snippet by name, as typing its keyword would. |
| `snippets` | `create(body, name)` | Opens the snippet editor on a new snippet. |
| `snippets` | `attachExpansion(editBox)` | Snippet keywords typed into that edit box expand, as in the chat box. |
| `chat` | `compose(text, conversation)` | Starts a message in the messenger. |

| Extension | Event | |
| --- | --- | --- |
| `gps` | `routeStarted(dest)` | A route was planned. |
| `gps` | `arrived(dest)` | The player reached the end. |
| `gps` | `routeCleared()` | The route was ended. |

Actions not listed here are EasyFind's own and may change.

## Settings pages

`settings(page, kit)` builds your page in Options > Extensions on its first visit. The page scrolls when it grows taller than the panel. `kit` makes controls in the panel's own look:

| Function | |
| --- | --- |
| `kit.Title(page, title, hint)` | The page's title, and a line under it. Returns what to anchor the next control to. |
| `kit.Checkbox(page, label, get, set, tooltip)` | `get()` returns the state, `set(on)` stores it. |
| `kit.Choice(page, label, choices, get, set, tooltip, default)` | A flyout of `{ { label, value }, ... }`. |
| `kit.Stepper(page, label, min, max, step, get, set, tooltip, width)` | A number with - and + buttons. |
| `kit.ROW_WIDTH`, `kit.BUTTON_WIDTH` | Widths the panel's rows use. |

Anchor each control below the one before it:

```lua
settings = function(page, kit)
    local below = kit.Title(page, "Bookmarks", "Spots you saved, found by name.")
    local box = kit.Checkbox(page, "Show the zone",
        function() return MyDB.showZone end,
        function(on) MyDB.showZone = on end)
    box:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -8)
end,
```

| Function | |
| --- | --- |
| `OpenSettings(id)` | Opens Options > Extensions at your page. |
| `IsSettingsOpen(id)` | |
| `CloseSettings()` | |

## Looking like EasyFind

| Function | |
| --- | --- |
| `GetThemeColor(role)` | `r, g, b, a` of the user's theme. Roles: `background`, `panel`, `border`, `line`, `text`, `textDim`, `heading`, `accent`, `selection`, `glyph`. |
| `IsLightTheme()` | A light theme wants dark text and icons. |
| `OnThemeChanged(fn)` | Runs `fn()` after the user picks another theme. |
| `StylePanel(frame)` | EasyFind's panel look for your frame: rounded border and the theme's fill, following theme and opacity changes. |
| `CreateButton(parent, text, width, height)` | A button in EasyFind's look. |
| `ShowDialog(opts)` | A confirm or input dialog: `text`, `acceptText`, `cancelText`, `hasEditBox`, `editBoxDefault`, `onAccept(value)`, `single` (one button). |

## Load on demand

An extension whose addon loads on demand registers its tile from a small part that always loads, and the rest from the load-on-demand addon:

```lua
-- Always loaded:
API.RegisterExtension({ id = "big", name = "Big", icon = 134400, addon = "MyBig_LoD" })
API.RegisterSearchProvider({ key = "big", label = "Big", extension = "big", loadOnSearch = true })

-- In MyBig_LoD, loaded on the first click:
API.RegisterExtension({ id = "big", open = OpenBigWindow })
API.RegisterSearchProvider({ key = "big", rows = BigRows, select = OpenBigItem })
```

The tile, its launcher row, the filter row and the scope are there before the addon ever loads. A click loads it, then opens. EasyFind's Notes, Chat and Icon Search work this way.

## Rules EasyFind keeps for you

- An error in your code (`open`, `rows`, an action, a listener) reaches the game's error frame, and EasyFind carries on.
- A function you register is called with `select`'s row as a copy: change it freely.
- A misuse of the API (a missing name, a wrong type) raises an error at once, naming the field.

## Editor support

[`API/EasyFind_API.lua`](EasyFind_API.lua) describes every function and field for the Lua language server (VS Code's Lua extension, and others built on it). Put it in your workspace: `EasyFind.API.` then completes with each function, and each field of the tables you pass.

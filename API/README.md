# EasyFind extension API

EasyFind is a search bar for World of Warcraft. Its extensions menu, search results, filter menu and settings panel are open to other addons through `EasyFind.API`. EasyFind's own extensions (Calculator, Icon Search, Snippets, Clipboard History, Notes, GPS, Quicklists, Chat) are built on the same API, so anything they do, yours can do.

What an extension can add:

- A tile in the extensions menu, with its icon, a description, a count badge and its own right-click rows. Users can drag it onto the screen or the micro menu like any other.
- Search results: its own rows in the search bar, a row under Extensions in the filter menu, an `@scope` that lists only its rows, and what a click on a row does.
- A settings page in Options > Extensions, built with EasyFind's own controls.
- Actions other extensions can call, and events they can listen to.

Most of this guide is reference. Start with [Fitting in](#fitting-in): what EasyFind requires is short, and the rest is how to make an extension feel like part of EasyFind.

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
    icon = "Interface\\AddOns\\EasyFind\\textures\\apps-icon", -- EasyFind's own, until you draw yours
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

## Fitting in

Your extension sits right next to EasyFind's own: in the extensions menu, in search results, in the filter menu and in the settings panel. Users notice when something matches, and an extension that looks and behaves like the rest feels like part of EasyFind rather than something bolted on. EasyFind requires very little; the rest of this section is what makes the difference.

### What EasyFind requires

Only a few things, and EasyFind checks them when you register, with an error that names what is missing:

- An extension has an `id`, a `name` and an `icon`.
- A search provider has a `key`, a `label` and an icon. One that names its extension with `extension` and has no icon of its own uses the extension's.
- Each field has the type this guide gives it.

One thing EasyFind does for every extension: it paints the icon in the theme's icon color wherever it shows (the menu tile, buttons on screen, launcher rows, the glyph by your rows, your filter row). That is how every icon follows the user's theme, dark or light, with no work from you. Icons you put on your own rows, such as an item's icon, keep their colors.

### Icons

![EasyFind's icons in three themes, with the example's bookmark at the end](icons/easyfind-icons.png)

EasyFind's icons share one simple style, and an icon drawn the same way looks like it always belonged in the menu. Since EasyFind paints it, it changes with every theme just like the others.

| | |
| --- | --- |
| Size | 64x64 pixels, a TGA file with transparency. |
| Color | White. EasyFind paints it, so any other color is lost. |
| Lines | Outlines about 5 px wide, with rounded ends and corners. Small dots and short bars inside a shape can be filled. |
| Margin | 5 to 10 px clear on each side, the drawing centered. A small detail can come closer, but not touch the edge. |
| Subject | One simple object that says what the extension does. No text, no background square, no shading. |

A game icon (the square pictures in your spellbook) still works, but painted in one color it turns into a solid square, so a drawn one is worth it. You don't need to be an artist; the kit in [`API/icons`](icons) does the fiddly parts:

- [`template.svg`](icons/template.svg): a 64x64 canvas with the margins marked and a sample drawn at the right line width. It opens in Inkscape, Figma, Illustrator or any editor that reads SVG.
- [`make_icon.py`](icons/make_icon.py) (Python 3 with Pillow) turns your drawing into the icon file and tells you how close it is to the style:

```
python make_icon.py convert my-drawing.png icon.tga
python make_icon.py check icon.tga
```

It also draws in code at EasyFind's line width: the example's bookmark is `draw_bookmark()` in that file, ready to copy and change.

Ship the `.tga` in your addon's folder and give its path without the extension:

```lua
icon = "Interface\\AddOns\\MyAddon\\icon",
```

### Colors and windows

- Take colors from `GetThemeColor` instead of fixed values, and repaint in `OnThemeChanged`. Users pick from many themes, light ones included, and your window then changes along with EasyFind's.
- `StylePanel` gives a window EasyFind's border and fill, and keeps them in step with theme and opacity changes for you. `CreateButton` and `ShowDialog` match EasyFind's own. See [Looking like EasyFind](#looking-like-easyfind).
- Build a settings page with the kit `settings` receives: the same checkboxes, flyouts and steppers as the rest of the panel.

### Text

- A name of one or two words reads best on a tile. The description is one short sentence.
- Text should fit at the largest font and in EasyFind's narrowest window: anchor wrapping text to both sides of what holds it rather than giving it a fixed width.
- Translating what users see (names, descriptions, menu rows, settings) makes an extension feel at home for players in every language.

### Staying light

EasyFind loads with every character, so an extension is at its best when it costs nothing until it is used.

- Put a large extension's work in a load-on-demand addon (see [Load on demand](#load-on-demand)).
- Run no per-frame code while your window is closed.
- Mark a provider `eager` only for a small list; a large one waits for its `words`, its filter or its scope (`lazy`).
- Call `NotifyOpenChanged` when your window shows or hides, so buttons users placed on screen show it right.

## Extensions

### RegisterExtension(def)

| Field | Type | |
| --- | --- | --- |
| `id` | string | Required. Letters, digits, `-` and `_`. Keep it the same across versions: menu layouts and buttons on screen save it. |
| `name` | string | Required the first time. Shown on the tile, its tooltip and its launcher row. |
| `description` | string | One line under the name in tooltips. |
| `icon` | texture path or file id | Required the first time. Painted in the theme's icon color wherever it shows. See [Icons](#icons). |
| `iconCoords` | `{ left, right, top, bottom }` | Texture coordinates for `icon`. |
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
| `loadInCombat` | boolean | Its addon may load, and it may open, in combat. Leave it off if your addon creates secure frames at load. |
| `loadAtLogin` | boolean | Its addon loads at login, not on first open: for one that works unopened, such as recording. |

An extension with only `settings` opens its settings page when clicked.

Menu rows, on top of EasyFind's own (its settings, its button on screen):

| Row | |
| --- | --- |
| `{ kind = "action", label = text, onClick = fn, tooltip = text }` | A command. |
| `{ kind = "check", label = text, get = fn, set = fn }` | A switch: `get()` returns it, `set(on)` stores it. |
| `{ kind = "separator" }` | A line between groups. |
| `{ kind = "menu", label, rows }` | A flyout of more rows: a list, or a function returning one. |

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
| `label` | string | Required the first time. What its rows are ("Shopping Lists"): its scope's pill and quick filter. With `extension`, the filter menu's Extensions flyout shows the extension's name instead, or "Name: label" when the extension has more than one provider, so a player sees which addon a filter belongs to. |
| `category` | string | The name its rows carry. Defaults to `key`. |
| `icon`, `iconCoords` | | Required the first time, unless `extension` names one with an icon: then that one is used. The glyph left of each of its rows, painted like an extension's. |
| `rows` | function | Returns its rows (below). Called when its rows are first needed and after `RefreshSearchProvider`. |
| `select` | function `(row)` | A click or Enter on one of its rows. Gets a copy of the row. |
| `tooltip` | function `(row, tooltip)` | Fills `GameTooltip` for a row. Return `true` to show it. |
| `leave` | function `(row)` | The cursor left one of its rows. |
| `words` | string list | Typing one loads its rows. |
| `eager` | boolean | Its rows are searched from the first keystroke. For small lists only. |
| `lazy` | boolean | Its rows show only through its words, its filter or its scope, never in plain results. |
| `lowResults` | boolean | Also loaded when a search finds little. |
| `aliases` | string list | An `@scope`: `@` and one of these lists only its rows. |
| `browse` | function | `browse(row)` returns whether the row is in the scope's list while nothing is typed (a quest log, not every quest). Without it, every row is. Typing searches all rows either way. |
| `place` | function | `place(row)` returns where the row is right now, `{ name, mapID, x, y, step }` as `navigate` takes, or nil. Its rows are then found from the map search and the GPS window too, and a pick there pins or routes to that spot. A row's `mapID` names the map it is on, for the map's own list. |
| `link` | table | `{ key = function(row), resolve = function(tail) }`. A row's EasyFind link (Send, the Ctrl+Shift+C copy) carries `key(row)`, a short string of yours, such as an id and the sender's progress. On the receiver, whose copy of your extension resolves it, `resolve(tail)` returns the row to show: its tooltip, hint and click are yours as for any row, so the tooltip can show what the sender sent. Without `link`, a row's link finds the receiver's own row by name. Keep the key short: it travels inside a chat message. |
| `menu` | function | `menu(row)` returns rows for the result's right-click menu, in the tile menu's shape (`{ kind = "action", label, onClick, tooltip }`, `{ kind = "check", label, get, set }`, `{ kind = "separator" }`, `{ kind = "menu", label, rows }` for a flyout within). They sit under one row named after your extension, with its glyph. Return nothing for a row with no rows of its own. |
| `options` | list | Toggles on its filter row's flyout: `{ label, tooltip, get, set }`, `{ header = text }`, `{ separator = true }`. `label` and `tooltip` may be functions. |
| `hint` | string, table or function | What a row's gestures do, shown under its name on hover: a sentence, or `{ click, alt, ctrl, shift }` with each gesture's target ("Click: Directions \| Alt: Quest log"), or a function of the row returning either. A row's own `hint` wins. |
| `extension` | string | The extension it belongs to. Its addon loading on demand, `select` loads it first. An extension whose addon is turned off shows no filter row or scope. |
| `loadOnSearch` | boolean or function | Load the extension's addon when its rows are first needed. |

A row is a table:

| Field | |
| --- | --- |
| `name` | Required. What is searched and shown. |
| `icon` | Texture path or file id, shown at the row's right in its own colors. |
| `keywords` | More words that find it. |
| `searchCommandDesc` | Its subtext: a dim note shown with the name. |
| `hint` | What its gestures do, as the provider's `hint`, for this row alone. |
| anything else | Kept on the row: `select` and `tooltip` get it back. |

```lua
API.RegisterSearchProvider({
    key = "bookmarks", label = "Bookmarks", icon = "Interface\\AddOns\\MyBookmarks\\icon",
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

### RegisterAddTarget(def)

An entry in a result's right-click Add flyout, beside Note and Quicklist: a place the row can be added to.

| Field | Type | |
| --- | --- | --- |
| `key` | string | Required. Registering a key again replaces it. |
| `extension` | string | Required, registered first. Its icon marks the entry, so a player sees which addon it comes from. |
| `label` | string | Required. Its name in the Add flyout ("Shopping list"). |
| `fullLabel` | string | Its name when it is the menu's only Add entry ("Add to shopping list"). Defaults to `label`. |
| `applies` | function `(row)` | True for the rows it takes. Without it, every row. |
| `rows` | function `(row)` | Required. The flyout's rows, in the tile menu's shape (the provider `menu` above). Nothing returned: no entry. |
| `onClick` | function `(row)` | A click on the entry itself, for its most common use (a new list); its flyout still opens on hover. |

```lua
API.RegisterAddTarget({
    key = "wishlist", extension = "mywishlist", label = "Wishlist", fullLabel = "Add to wishlist",
    applies = function(row) return row.itemID ~= nil end,
    rows = function(row)
        return { { kind = "action", label = "Main", onClick = function() AddToWishlist(row.itemID) end } }
    end,
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
| `gps` | `navigate(dest, opts)` | Directions to `dest` = `{ name, mapID, x, y }`, map coordinates 0 to 1. `dest.step` is the last step's own sentence ("Travel to the quest objective") in place of "Travel to name". `opts.popout` opens them in the GPS window. Returns true when a route is planned. |
| `gps` | `canNavigate(dest)` | Whether the GPS can find a way there. |
| `gps` | `setStart(dest)` | Plans the next route from there, not from the player. |
| `gps` | `clear()` | Ends the route. |
| `loot` | `ensure(fn)` | Loads the loot rows and calls `fn()` once they are in (at once when they are). Returns false on a client without loot. |
| `loot` | `entries()` | A fresh list of the cached drops, one table each: `{ itemID, name, icon, slotName, links = { [difficulty] = itemLink }, bossName, encounterID, instanceName, instanceID, isRaid }`. Nil before `ensure`. |
| `loot` | `link(itemID)` | The item link EasyFind's own loot row shows for it (the chosen difficulty, then the best known), or nil when it is not a cached drop. |
| `loot` | `open(itemID)` | What a plain click on that loot row does: its boss's journal page, or directions to the instance on WoW Forever. Returns true when the item is a cached drop. |
| `loot` | event `changed` | Fired after the drops are rebuilt (a scan finished) and when the loot difficulty choice changes. |
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

### Your settings in the search bar

Settings that live in the game's Settings panel or in an AceConfig options table are found from the search bar as they are, under AddOn Options. Settings in a window of your own are found too once `RegisterSettingsIndex(addon, rows)` hands EasyFind their names:

```lua
EasyFind.API.RegisterSettingsIndex("Hello", function()
    return {
        { name = "Show the zone", path = "Bookmarks", keywords = { "map" },
          open = function() HelloOptions:Open("bookmarks", "showZone") end },
    }
end)
```

`rows()` is read when the search first needs it. Each row names one setting (`name`), where it sits in your window (`path`, a string or a list of names, shown under the row), more words that find it (`keywords`) and `open()`, which shows your window at it. Pass the name the game's AddOns list shows for you: one filter row then covers both. `RefreshSettingsIndex(addon)` reads the rows again after they change.

A row with a `control` is changed where it stands, as the game's own settings are: a check box, a slider with its steppers, a drop-down or a button on the row, Alt-click opening your window through `open()`.

```lua
{ name = "Show the zone", path = "Bookmarks", open = ...,
  control = { kind = "check", tooltip = "Puts the zone under each bookmark.",
              get = function() return MyDB.showZone end,
              set = function(on) MyDB.showZone = on end } },
{ name = "Icon size", path = "Bookmarks", open = ...,
  control = { kind = "slider", min = 8, max = 32, step = 2,
              get = function() return MyDB.iconSize end,
              set = function(n) MyDB.iconSize = n end } },
```

| `kind` | On the row | Fields |
| --- | --- | --- |
| `check` | A check box. | `get()` returns true or false, `set(on)`. |
| `radio` | A check box that only turns on. | `get()`, `set(true)`. |
| `slider` | A slider with minus and plus. | `get()` returns a number, `set(n)`, `min`, `max`, `step`, `format(n)` for the value text. |
| `choice` | A drop-down. | `get()` returns a value, `set(value)`, `choices`: `{ { value, label }, ... }` or a function returning that list. |
| `button` | The row presses it. | `press()`. |

`tooltip` on any control is shown under the name. `get` and `set` run on every draw and click, so route them through what your window uses.

## Beside the chat

A button or opener you place beside the game's chat goes with it when the user hides the chat through EasyFind's "Toggle Chat Frame" entry: `RegisterChatPiece(frame)` hides and shows it along with the chat frames, and hides it right away when the chat is already hidden.

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
API.RegisterExtension({ id = "big", name = "Big", icon = "Interface\\AddOns\\MyBig\\icon", addon = "MyBig_LoD" })
API.RegisterSearchProvider({ key = "big", label = "Big", extension = "big", loadOnSearch = true })

-- In MyBig_LoD, loaded on the first click:
API.RegisterExtension({ id = "big", open = OpenBigWindow })
API.RegisterSearchProvider({ key = "big", rows = BigRows, select = OpenBigItem })
```

The tile, its launcher row, the filter row and the scope are there before the addon ever loads. A click loads it, then opens. EasyFind's Notes, Chat and Icon Search work this way.

## Rules EasyFind keeps for you

- An error in your code (`open`, `rows`, an action, a listener) reaches the game's error frame, and EasyFind carries on.
- A function you register is called with `select`'s row as a copy: change it freely.
- A misuse of the API (a missing name or icon, a wrong type) raises an error at once, naming the field.

## Editor support

[`API/EasyFind_API.lua`](EasyFind_API.lua) describes every function and field for the Lua language server (VS Code's Lua extension, and others built on it). Put it in your workspace: `EasyFind.API.` then completes with each function, and each field of the tables you pass.

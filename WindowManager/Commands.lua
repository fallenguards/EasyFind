local _, ns = ...

-- Window position commands as searchable entries. Each becomes a row in the
-- "Window" result category: typing or selecting it applies that snap to the
-- current target window. Entries carry `windowCommand` (a stable English spec
-- key) which the result handlers dispatch through ns.WindowManager.
--
-- Display names come from L[] (localized); the spec key and keywords stay
-- English so a player matches "left half" in any locale. The "windows" dynamic
-- provider injects these into uiSearchData; each row's stable Aliases key
-- (windowcmd:<id>) makes it bindable through the shortkey system for free.

local WindowCommands = {}
ns.WindowCommands = WindowCommands

local L = ns.L

local WINDOW_CATEGORY = "Window"
WindowCommands.CATEGORY = WINDOW_CATEGORY

-- id = SnapMath spec key; nameKey = L[] display; kw = English search terms.
local COMMANDS = {
    { id = "left-half",            nameKey = "WINDOW_CMD_LEFT_HALF",     kw = { "left", "half", "1/2" } },
    { id = "right-half",           nameKey = "WINDOW_CMD_RIGHT_HALF",    kw = { "right", "half", "1/2" } },
    { id = "top-half",             nameKey = "WINDOW_CMD_TOP_HALF",      kw = { "top", "half", "1/2", "upper" } },
    { id = "bottom-half",          nameKey = "WINDOW_CMD_BOTTOM_HALF",   kw = { "bottom", "half", "1/2", "lower" } },
    { id = "left-third",           nameKey = "WINDOW_CMD_LEFT_THIRD",    kw = { "left", "third", "3rd", "first", "1st" } },
    { id = "center-third",         nameKey = "WINDOW_CMD_CENTER_THIRD",  kw = { "center", "centre", "third", "3rd", "middle", "mid" } },
    { id = "right-third",          nameKey = "WINDOW_CMD_RIGHT_THIRD",   kw = { "right", "third", "3rd", "last" } },
    { id = "left-two-thirds",      nameKey = "WINDOW_CMD_LEFT_TWO_THIRDS", kw = { "left", "two", "thirds", "2/3" } },
    { id = "right-two-thirds",     nameKey = "WINDOW_CMD_RIGHT_TWO_THIRDS", kw = { "right", "two", "thirds", "2/3" } },
    { id = "top-left-quarter",     nameKey = "WINDOW_CMD_TOP_LEFT_QUARTER",     kw = { "top", "upper", "left", "quarter", "qtr", "4th", "fourth", "quadrant", "corner" } },
    { id = "top-right-quarter",    nameKey = "WINDOW_CMD_TOP_RIGHT_QUARTER",    kw = { "top", "upper", "right", "quarter", "qtr", "4th", "fourth", "quadrant", "corner" } },
    { id = "bottom-left-quarter",  nameKey = "WINDOW_CMD_BOTTOM_LEFT_QUARTER", kw = { "bottom", "lower", "left", "quarter", "qtr", "4th", "fourth", "quadrant", "corner" } },
    { id = "bottom-right-quarter", nameKey = "WINDOW_CMD_BOTTOM_RIGHT_QUARTER", kw = { "bottom", "lower", "right", "quarter", "qtr", "4th", "fourth", "quadrant", "corner" } },
    { id = "top-left-sixth",       nameKey = "WINDOW_CMD_TOP_LEFT_SIXTH",       kw = { "top", "upper", "left", "sixth", "6th" } },
    { id = "top-center-sixth",     nameKey = "WINDOW_CMD_TOP_CENTER_SIXTH",     kw = { "top", "upper", "center", "centre", "sixth", "6th" } },
    { id = "top-right-sixth",      nameKey = "WINDOW_CMD_TOP_RIGHT_SIXTH",      kw = { "top", "upper", "right", "sixth", "6th" } },
    { id = "bottom-left-sixth",    nameKey = "WINDOW_CMD_BOTTOM_LEFT_SIXTH",    kw = { "bottom", "lower", "left", "sixth", "6th" } },
    { id = "bottom-center-sixth",  nameKey = "WINDOW_CMD_BOTTOM_CENTER_SIXTH",  kw = { "bottom", "lower", "center", "centre", "sixth", "6th" } },
    { id = "bottom-right-sixth",   nameKey = "WINDOW_CMD_BOTTOM_RIGHT_SIXTH",   kw = { "bottom", "lower", "right", "sixth", "6th" } },
    { id = "center",               nameKey = "WINDOW_CMD_CENTER",        kw = { "center", "centre", "middle", "mid", "centered", "middle-screen" } },
    { id = "maximize",             nameKey = "WINDOW_CMD_MAXIMIZE",      kw = { "maximize", "maximise", "full", "fullscreen", "fill" } },
    { id = "reasonable-size",      nameKey = "WINDOW_CMD_REASONABLE",    kw = { "reasonable", "size", "default", "restore" } },
    { id = "restore",              nameKey = "WINDOW_CMD_RESTORE",       kw = { "restore", "reset", "default", "original", "position", "size", "revert", "undo" }, restore = true },
    { id = "restore-all",          nameKey = "WINDOW_CMD_RESTORE_ALL",
      kw = { "restore", "reset", "all", "windows", "default", "positions" }, restoreAll = true },
    { id = "task-view",            nameKey = "WINDOW_CMD_TASKVIEW",
      kw = { "task", "view", "overview", "layout", "arrange", "windows" }, taskView = true },
}

WindowCommands.COMMANDS = COMMANDS
WindowCommands.CATEGORY_LABEL_KEY = "FILTER_WINDOW"

local slower = ns.Utils.slower
local mfloor = ns.Utils.mfloor

-- Per-command region glyphs, Rectangle-style: a screen outline with the
-- target area filled. Sheet cell = COMMANDS array order; the generator
-- (dev/tools/gen_window_actions.py) mirrors this list, so the two MUST
-- change together. Defs are built once and returned by the icon resolver.
local WINDOW_ACTIONS_TEX = "Interface\\AddOns\\EasyFind\\textures\\window-actions"
local CELLS_PER_ROW = 8
local CELL_UV = 32 / 256

local ICON_DEFS = {}
for i = 1, #COMMANDS do
    local col = (i - 1) % CELLS_PER_ROW
    local cellRow = mfloor((i - 1) / CELLS_PER_ROW)
    ICON_DEFS[COMMANDS[i].id] = {
        tex = WINDOW_ACTIONS_TEX,
        coords = { col * CELL_UV, (col + 1) * CELL_UV,
                   cellRow * CELL_UV, (cellRow + 1) * CELL_UV },
    }
end
WindowCommands.ICON_DEFS = ICON_DEFS

-- Path is shared (read-only) so every entry references one table instead of
-- allocating a path array each. Built lazily because L resolves at call time.
local sharedPath

local function GetPath()
    if not sharedPath then sharedPath = { L[WindowCommands.CATEGORY_LABEL_KEY] } end
    return sharedPath
end

-- Build the searchable entries for uiSearchData. Returns a fresh array; the
-- caller appends it into the index. Stable identity per id so Aliases/shortkeys
-- resolve back to the same row. nameLower comes from the LOCALIZED name so a
-- deDE player can type what the row shows; the stable English id words live in
-- keywords, so English typing matches on every locale too.
function WindowCommands:BuildSearchData()
    local out = {}
    local path = GetPath()
    for i = 1, #COMMANDS do
        local def = COMMANDS[i]
        out[#out + 1] = {
            name = L[def.nameKey],
            nameLower = slower(L[def.nameKey]),
            category = WINDOW_CATEGORY,
            path = path,
            keywords = def.kw,
            noPin = true,
            _windowIconDef = ICON_DEFS[def.id],
            windowCommand = (not def.restore and not def.restoreAll and not def.taskView)
                and def.id or nil,
            windowRestore = def.restore or nil,
            windowRestoreAll = def.restoreAll or nil,
            windowTaskView = def.taskView or nil,
            searchCommandDesc = def.restoreAll and L["WINDOW_SUBTEXT_ALL"] or L["WINDOW_SUBTEXT"],
        }
    end
    return out
end

-- Dispatch a window command row's action. Shared by the click and keyboard
-- activation paths so both behave identically. Plain args, no table: the
-- callers capture the two fields before FinishResultSelection recycles the
-- row's data table.
function WindowCommands:Run(cmd, restore, restoreAll, taskView)
    if taskView then
        return ns.WindowSnapAssist and ns.WindowSnapAssist:ToggleTaskView() or false
    end
    if not ns.WindowManager then return false end
    if restoreAll then
        return ns.WindowManager:RestoreAll()
    end
    if restore then
        return ns.WindowManager:Restore()
    end
    if cmd then
        return ns.WindowManager:ApplyCommand(cmd)
    end
    return false
end

return WindowCommands

local _, ns = ...

-- The results panel shows at most one grid in place of its rows (the
-- icons, a character's items). The bar's keys and the renderer reach the
-- shown one through these; each grid registers its own handlers.
local Results = ns.Results

local grids = {}

function ns.RegisterResultGrid(grid)
    grids[#grids + 1] = grid
end

local function Shown()
    for i = 1, #grids do
        if grids[i].IsShown() then return grids[i] end
    end
    return nil
end

function Results:IsGridShown()
    return Shown() ~= nil
end

function Results:IsGridNavActive()
    local grid = Shown()
    return grid ~= nil and grid.IsNavActive()
end

-- dCol/dRow move the focus; from the edit box it lands on the first cell.
function Results:MoveGridFocus(dCol, dRow)
    local grid = Shown()
    return grid ~= nil and grid.MoveFocus(dCol, dRow)
end

function Results:JumpGridFocus(toEnd)
    local grid = Shown()
    if grid then grid.JumpFocus(toEnd) end
end

function Results:ActivateGridFocus()
    local grid = Shown()
    return grid ~= nil and grid.ActivateFocus()
end

function Results:OpenGridFocusMenu()
    local grid = Shown()
    return grid ~= nil and grid.OpenFocusMenu()
end

function Results:ArmGridFocusCopy()
    local grid = Shown()
    return grid ~= nil and grid.ArmFocusCopy()
end

function Results:ExitGridNav(refocus)
    local grid = Shown()
    if grid then grid.ExitNav(refocus) end
end

-- A grid takes the panel from the rows: they hide with their separators
-- and shortcut keys, and the list's later passes place none back.
function Results:ClearRowsForGrid(resultsFrame)
    Results._cachedHierarchical = nil
    local buttons = ns.Search:GetResultButtons()
    for i = 1, buttons and #buttons or 0 do
        if buttons[i] then buttons[i]:Hide() end
    end
    if resultsFrame.pinSeparator then resultsFrame.pinSeparator:Hide() end
    for _, sep in ipairs(resultsFrame.categorySeps or {}) do sep:Hide() end
    if resultsFrame.quickFilterHelp then resultsFrame.quickFilterHelp:Hide() end
    ns.Search:ClearResultShortcutBindings()
    if ns.ResultRender.RetireRows then ns.ResultRender:RetireRows() end
end

-- release: the results closed, so each grid lets its working memory go.
function Results:HideGrids(release)
    for i = 1, #grids do
        local grid = grids[i]
        grid.Hide()
        if release and grid.ReleaseMemory then grid.ReleaseMemory() end
    end
end

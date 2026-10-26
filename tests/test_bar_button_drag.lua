-- A Button spanning the search bar's full height covers its border, and a
-- press there went to the button, never the bar's drag: the border round
-- the apps and filter buttons would not move the bar (2026-10-26). Every
-- such button passes its drags to the bar.
local H = require("Harness")

local FILES = { "Search/SearchBar.lua", "Search/AppsMenu.lua" }

local function Read(rel)
    local fh = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "r"))
    local text = fh:read("a")
    fh:close()
    return text
end

local tests = {}

function tests.fullHeightBarButtonsPassDragsToTheBar()
    local bar = Read("Search/SearchBar.lua")
    local list = bar:match("for _, btn in ipairs%(%{([^}]*)%}%) do%s+btn:RegisterForDrag")
    H.assertTrue(list ~= nil, "the drag pass loop")
    local passed = {}
    for name in list:gmatch("[%w_%.]+") do passed[name] = true end
    local found = 0
    for _, rel in ipairs(FILES) do
        local text = Read(rel)
        for name in text:gmatch('local ([%w_]+) = CreateFrame%("Button", [^,]+, searchFrame%)') do
            local esc = name:gsub("%p", "%%%0")
            local top = text:find(esc .. ':SetPoint%("TOP", searchFrame, "TOP"')
            local bottom = text:find(esc .. ':SetPoint%("BOTTOM", searchFrame, "BOTTOM"')
            if top and bottom then
                found = found + 1
                local field = text:match("searchFrame%.([%w_]+) = " .. esc .. "%s")
                local key = (field and passed["searchFrame." .. field]) and "searchFrame." .. field or name
                H.assertTrue(passed[key] ~= nil, rel .. ": " .. name .. " spans the bar but keeps its drags")
            end
        end
    end
    H.assertTrue(found >= 2, "expected the filter and apps buttons, found " .. found)
end

local pass, fail, failures = H.runSuite("BarButtonDrag", tests)
return { pass = pass, fail = fail, failures = failures }

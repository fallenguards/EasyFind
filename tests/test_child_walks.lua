-- A walk over a frame's children reads them once: `select(i, f:GetChildren())`
-- in a loop fetches every child again for each child. The GPS section's
-- walk did that over every pooled hit row, four times a second: 150 ms a
-- tick (2026-10-25). The counts below are walks that run once on a click
-- or over a few regions; a new one reads the children into a table.
local H = require("Harness")

local KNOWN = {
    ["Apps/Guide/Highlight.lua"] = 7,
    ["Apps/Icons/IconPickerSearch.lua"] = 1,
    ["MapSearch/MapTab.lua"] = 2,
    ["MapSearch/Search/Scanners.lua"] = 2,
    ["MapSearch/Zones/Breadcrumbs.lua"] = 2,
    ["Search/Results/Handlers/Spellbook.lua"] = 1,
    ["Search/Results/Handlers/Talents.lua"] = 1,
    ["Search/Results/Handlers/Toys.lua"] = 1,
    ["Shared/Caps.lua"] = 1,
    ["Shared/Utils.lua"] = 10,
}

local function LuaFiles()
    local out = {}
    local p = assert(io.popen('find "' .. H.ADDON_ROOT .. '" -name "*.lua" -not -path "*/tests/*" -not -path "*/.git/*" -not -path "*/dev/*" 2>/dev/null'))
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end

local tests = {}

function tests.noChildWalkFetchesTheChildrenPerChild()
    local bad = {}
    for _, path in ipairs(LuaFiles()) do
        local f = io.open(path, "rb")
        local src = f and f:read("*a") or ""
        if f then f:close() end
        local _, n = src:gsub("select%(i, [%w_%.:]*Get%a+%(%)%)", "")
        local rel = path:sub(#H.ADDON_ROOT + 2):gsub("\\", "/")
        if n > (KNOWN[rel] or 0) then bad[#bad + 1] = rel .. " (" .. n .. ")" end
    end
    H.assertEq(table.concat(bad, ", "), "", "walks that read a frame's children again per child; read them once")
end

local pass, fail, failures = H.runSuite("ChildWalks", tests)
return { pass = pass, fail = fail, failures = failures }

-- A result row's title is written only through the row text setters
-- (Search/Results/RowText.lua SetClippedText, SetUnclippedText): the clip
-- keeps the title it was given and sets it again a frame later, so a plain
-- SetText on the title is undone (catalog item names went back to the
-- lowercase search name).
local H = require("Harness")

local FILES = {
    "Search/Results/Render/Core.lua", "Search/Results/Render/Layout.lua",
    "Search/Results/Render/Reputation.lua", "Search/Results/Render/RowContent.lua",
    "Search/Results/Render/Shared.lua", "Search/Results/Render/Text.lua",
    "Search/Results/Render/Tree.lua", "Search/Results/Render/Widgets.lua",
    "Search/Results/RowText.lua", "Search/Results/Navigation.lua", "Search/Results/Icons.lua",
}

local tests = {}

function tests.noPlainSetTextOnARowTitle()
    local offenders = {}
    for _, path in ipairs(FILES) do
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
        local n = 0
        for line in f:lines() do
            n = n + 1
            if line:find("[%s%(]resultRow%.text:Set[%a]*Text%(") or line:find("[%s%(]row%.text:Set[%a]*Text%(") then
                if not line:find("SetTextColor", 1, true) then
                    offenders[#offenders + 1] = path .. ":" .. n
                end
            end
        end
        f:close()
    end
    H.assertEq(table.concat(offenders, ", "), "", "titles set past the clip")
end

local pass, fail, failures = H.runSuite("RowTitleWrites", tests)
return { pass = pass, fail = fail, failures = failures }

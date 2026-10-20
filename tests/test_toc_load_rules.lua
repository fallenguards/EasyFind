-- Guardrail: a file that opens by returning on the other client (or in
-- another locale) is kept off it by its toc line, never parsed there
-- just to return. Retail parsed the Forever walk grids (6 MB of strings)
-- at every login under EasyFind_GPS; Forever parsed retail's 7 MB item
-- catalog; every client parsed all ten translations.
local H = require("Harness")

local RULE = {
    forever = "[AllowLoadGameType camelot]",
    retail = "[AllowLoadGameType standard]",
}

local PRELUDE = {
    "^%s*$", "^%-%-", "^local EasyFind = EasyFind%s*$", "^local ns = EasyFind and EasyFind%._ns%s*$",
    "^local _, ns = %.%.%.%s*$", "^if not ns then return end%s*$",
}

local function OpeningGate(path)
    local fh = io.open(H.ADDON_ROOT .. "/" .. path, "r")
    if not fh then return nil end
    local gate
    for line in fh:lines() do
        local prelude = false
        for _, p in ipairs(PRELUDE) do
            if line:find(p) then prelude = true break end
        end
        if not prelude then
            if line:find("^if not %(ns and ns%.Caps and ns%.Caps%.forever%) then return end")
               or line:find("^if not %(ns%.Caps and ns%.Caps%.forever%) then return end") then
                gate = "forever"
            elseif line:find("^if ns%.Caps and ns%.Caps%.forever then return end") then
                gate = "retail"
            else
                local loc = line:match('^if GetLocale%(%) ~= "(%a%a%a%a)" then return end')
                if loc then
                    gate = loc
                    RULE[loc] = "[AllowLoadTextLocale " .. loc .. "]"
                end
            end
            break
        end
    end
    fh:close()
    return gate
end

local tests = {}

function tests.everyClientOnlyFile_isKeptOffTheOtherClient()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        local dir = toc:match("^(.*)/[^/]+$")
        local fh = assert(io.open(H.ADDON_ROOT .. "/" .. toc, "r"))
        for raw in fh:lines() do
            local file, rules = H.TocLine(raw)
            if file:find("%.lua$") and not file:find("^#") then
                local path = dir and (dir .. "/" .. file) or file
                local gate = OpeningGate(path)
                checked = checked + 1
                if gate and rules ~= RULE[gate] then
                    bad[#bad + 1] = toc .. ": " .. file .. " opens " .. gate .. "-only, wants " .. RULE[gate]
                elseif not gate and rules ~= "" then
                    bad[#bad + 1] = toc .. ": " .. file .. " has " .. rules .. " but no opening guard"
                end
            end
        end
        fh:close()
    end
    H.assertTrue(checked > 100, "read the toc file lines")
    H.assertTrue(#bad == 0, table.concat(bad, "\n"))
end

local pass, fail, failures = H.runSuite("TocLoadRules", tests)
return { pass = pass, fail = fail, failures = failures }

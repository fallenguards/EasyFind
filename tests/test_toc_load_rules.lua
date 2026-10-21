-- Guardrail: a file that opens by returning on the other client (or in
-- another locale) is kept off it by its toc line, never parsed there
-- just to return. Retail parsed the Forever walk grids (6 MB of strings)
-- at every login under EasyFind_GPS; Forever parsed retail's 7 MB item
-- catalog; every client parsed all ten translations and every locale's
-- creature names.
local H = require("Harness")

local PRELUDE = {
    "^%s*$", "^%-%-", "^local EasyFind = EasyFind%s*$", "^local ns = EasyFind and EasyFind%._ns%s*$",
    "^local _, ns = %.%.%.%s*$", "^if not ns then return end%s*$",
}

local function IsPrelude(line)
    for _, p in ipairs(PRELUDE) do
        if line:find(p) then return true end
    end
    return false
end

-- The toc rule an opening guard line asks for, or nil.
local function GateRule(line)
    if line:find("^if not %(ns and ns%.Caps and ns%.Caps%.forever%) then return end")
       or line:find("^if not %(ns%.Caps and ns%.Caps%.forever%) then return end") then
        return "[AllowLoadGameType camelot]"
    elseif line:find("^if ns%.Caps and ns%.Caps%.forever then return end") then
        return "[AllowLoadGameType standard]"
    elseif line:find("^if not %(ns%.Caps and ns%.Caps%.era%) then return end") then
        return "[AllowLoadGameType classic]"
    elseif line:find("^if not %(ns%.Caps and ns%.Caps%.tbc%) then return end") then
        return "[AllowLoadGameType tbc]"
    elseif line:find("^if not %(ns%.Caps and %(ns%.Caps%.forever or ns%.Caps%.classic%)%) then return end") then
        return "[AllowLoadGameType camelot, classic, tbc]"
    end
    local loc = line:match('^if GetLocale%(%) ~= "(%a%a%a%a)" then return end')
    return loc and ("[AllowLoadTextLocale " .. loc .. "]") or nil
end

-- The rules a file's opening guards ask for, sorted into one string.
local function WantedRules(path)
    local fh = io.open(H.ADDON_ROOT .. "/" .. path, "r")
    if not fh then return "" end
    local wanted = {}
    for line in fh:lines() do
        local rule = GateRule(line)
        if rule then
            wanted[#wanted + 1] = rule
        elseif not IsPrelude(line) then
            break
        end
    end
    fh:close()
    table.sort(wanted)
    return table.concat(wanted, " ")
end

local function Sorted(rules)
    local list = {}
    for r in rules:gmatch("%[[^%]]*%]") do list[#list + 1] = r end
    table.sort(list)
    return table.concat(list, " ")
end

local tests = {}

function tests.everyClientOnlyFile_isKeptOffTheOtherClient()
    local bad, checked, gated = {}, 0, 0
    for _, toc in ipairs(H.TOCS) do
        local dir = toc:match("^(.*)/[^/]+$")
        local fh = assert(io.open(H.ADDON_ROOT .. "/" .. toc, "r"))
        for raw in fh:lines() do
            local file, rules = H.TocLine(raw)
            if file:find("%.lua$") and not file:find("^#") then
                checked = checked + 1
                local wanted = WantedRules(dir and (dir .. "/" .. file) or file)
                if wanted ~= "" then gated = gated + 1 end
                if Sorted(rules) ~= wanted then
                    bad[#bad + 1] = toc .. ": " .. file .. " has '" .. rules .. "', its guards want '" .. wanted .. "'"
                end
            end
        end
        fh:close()
    end
    H.assertTrue(checked > 100 and gated > 20, "read the toc file lines")
    H.assertTrue(#bad == 0, table.concat(bad, "\n"))
end

local pass, fail, failures = H.runSuite("TocLoadRules", tests)
return { pass = pass, fail = fail, failures = failures }

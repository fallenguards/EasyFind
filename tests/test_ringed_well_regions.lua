-- A ringed well's inset is a frame one level over the well: a texture or
-- text made on the well itself draws under the inset's fill and is lost
-- (2026-10-27: the Notes search box lost its glass and hint, the caret
-- sitting past where the glass had been). Art in a well goes on its inset
-- (CreateRingedWell's return), the box and buttons above it.
local H = require("Harness")

local SPAN = 60   -- lines after the well is made

local tests = {}

function tests.nothingIsDrawnOnTheWellUnderItsInset()
    local bad = {}
    local p = io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "*.lua"')
    for rel in p:lines() do
        if not rel:match("^tests/") then
            local f = io.open(H.ADDON_ROOT .. "/" .. rel, "rb")
            if f then
                local lines = {}
                for line in f:lines() do lines[#lines + 1] = line end
                f:close()
                for i, line in ipairs(lines) do
                    local well = line:match("CreateRingedWell%(([%w_%.]+),")
                    if well and not line:find("function ns.CreateRingedWell", 1, true) then
                        local pat = well:gsub("%.", "%%.") .. ":Create[TF][eo][xn][tt]"
                        for j = i + 1, math.min(#lines, i + SPAN) do
                            if lines[j]:find(pat) and (lines[j]:find(":CreateTexture(", 1, true)
                                or lines[j]:find(":CreateFontString(", 1, true)) then
                                bad[#bad + 1] = rel .. ":" .. j
                            end
                        end
                    end
                end
            end
        end
    end
    p:close()
    H.assertEq(#bad, 0, "drawn under a well's inset: " .. table.concat(bad, ", "))
end

local pass, fail, failures = H.runSuite("RingedWellRegions", tests)
return { pass = pass, fail = fail, failures = failures }

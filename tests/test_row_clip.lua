-- A row title too wide for its row ends in "...": the longest cut that
-- fits, found by halving (it tried one character less at a time, a SetText
-- and a width read each, 30 for a title 30 characters over).
local H = require("Harness")
local env = H.newEnv()
env._G = env
env.Enum = env.Enum or {}
env.Enum.UIMapType = env.Enum.UIMapType or { Continent = 2, Zone = 3 }
env.C_Timer = nil
local ns = H.newNs(env)
ns.Utils.sformat = ns.Utils.sformat or string.format
H.loadModule("Search/Results/RowText.lua", env, ns)
local Text = ns.ResultText

-- A line bounded left and right; its width counts visible characters,
-- "W" wider than the rest and color escapes none.
local function FontString(maxW)
    local fs = { sets = 0, text = "" }
    function fs:SetText(t) self.text, self.sets = t, self.sets + 1 end
    function fs:GetLeft() return 0 end
    function fs:GetRight() return maxW end
    function fs:GetParent() return nil end
    function fs:GetUnboundedStringWidth()
        local shown = self.text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:|]+:", ""):gsub("|r", "")
        local _, wide = shown:gsub("W", "")
        return #shown * 6 + wide * 4
    end
    return fs
end

-- What the one-at-a-time cut chose.
local function OldClip(fs, text)
    fs:SetText(text)
    local maxW = fs:GetRight() - fs:GetLeft()
    if fs:GetUnboundedStringWidth() <= maxW then return fs.text end
    local open, inner = text:match("^(|c%x%x%x%x%x%x%x%x)(.-)|r$")
    if not open then open, inner = text:match("^(|cn[^:|]+:)(.-)|r$") end
    if open then
        for cut = #inner - 1, 1, -1 do
            fs:SetText(open .. inner:sub(1, cut) .. "...|r")
            if fs:GetUnboundedStringWidth() <= maxW then return fs.text end
        end
        return fs.text
    end
    for cut = #text - 1, 1, -1 do
        fs:SetText(text:sub(1, cut) .. "...")
        if fs:GetUnboundedStringWidth() <= maxW then return fs.text end
    end
    return fs.text
end

local tests = {}

function tests.clip_choosesWhatTheOldCutChose()
    local titles = { "Short", "Highland Drake of the Windborne Skies, Reins", "WWWWWWWWWWWWWWWWWWWW",
                     "|cffa335eeAshes of Al'ar and a very long epic name|r", "|cnIQ4:Invincible's Reins of Icecrown|r",
                     "A", "Exactly Thirty Characters!!!!" }
    for _, title in ipairs(titles) do
        for _, maxW in ipairs({ 10, 30, 60, 100, 174, 180, 400 }) do
            local old = OldClip(FontString(maxW), title)
            local fs = FontString(maxW)
            Text:SetClippedText(fs, title)
            H.assertEq(fs.text, old, ("%q in %d"):format(title, maxW))
        end
    end
end

function tests.clip_triesFewTimes()
    local title = "Reins of the Grand Expedition Yak and Everything It Carries Across the World"
    local fs = FontString(120)
    Text:SetClippedText(fs, title)
    H.assertTrue(fs.sets <= 10, "halving: " .. fs.sets .. " tries")
    local old = FontString(120)
    OldClip(old, title)
    H.assertTrue(old.sets > 50, "one at a time: " .. old.sets)
end

-- The clip sets its title again a frame later: a plain SetText in between
-- is undone (catalog names went back to lowercase), the setters are not.
function tests.reclip_keepsWhatTheSettersWrote()
    local queued = {}
    env.C_Timer = { After = function(_, fn) queued[#queued + 1] = fn end }
    local plain, catalog, loot = FontString(400), FontString(400), FontString(400)
    Text:SetClippedText(plain, "linen cloth")
    plain:SetText("|cffffffffLinen Cloth|r")
    Text:SetClippedText(catalog, "linen cloth")
    Text:SetClippedText(catalog, "|cffffffffLinen Cloth|r")
    Text:SetClippedText(loot, "Thunderfury")
    Text:SetUnclippedText(loot, "Thunderfury  |cff888888Ragnaros|r")
    for _, fn in ipairs(queued) do fn() end
    env.C_Timer = nil
    H.assertEq(plain.text, "linen cloth", "a plain SetText is undone")
    H.assertEq(catalog.text, "|cffffffffLinen Cloth|r")
    H.assertEq(loot.text, "Thunderfury  |cff888888Ragnaros|r")
end

local pass, fail, failures = H.runSuite("RowClip", tests)
return { pass = pass, fail = fail, failures = failures }

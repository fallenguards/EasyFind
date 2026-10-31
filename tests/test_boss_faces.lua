-- Boss rows on the classic clients (2026-10-31): the journal's creature
-- call gives them no icon image, only the display id a face is drawn
-- from. The row keeps that id, the cache carries it, and the row paints
-- the face where it has no icon.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local tests = {}

function tests.theRowKeepsTheDisplayID_theCacheCarriesIt()
    local src = Read("Database/Main.lua")
    local s = assert(src:find("local function BossFace(getCreatureInfo, encID)", 1, true))
    local body = src:sub(s, s + 500)
    H.assertTrue(body:find("local ok, _, _, _, displayInfo, iconImage = pcall(getCreatureInfo, 1, encID)", 1, true) ~= nil,
        "the fourth return is the display id, the fifth the icon")
    H.assertTrue(src:find("local icon, displayID = BossFace(getCreatureInfo, boss.enc)", 1, true) ~= nil, "the static bosses ask too")
    H.assertTrue(src:find('{ "instanceName" }, { "name" }, { "encounterID" }, { "icon" }, { "displayID" },', 1, true) ~= nil, "in the cache spec")
    H.assertTrue(src:find("ns.BOSS_CACHE_VER = 4", 1, true) ~= nil, "cached rows scan again")
    H.assertTrue(src:find("displayID = entry and entry.displayID,", 1, true) ~= nil)
end

function tests.theRowPaintsTheFaceWithNoIcon()
    local src = Read("Search/Results/Render/RowContent.lua")
    local s = assert(src:find("elseif Render.IsBossResultData(data) and data.displayID and SetPortraitTextureFromCreatureDisplayID then", 1, true))
    local body = src:sub(s, s + 700)
    H.assertTrue(body:find("DrawFace(resultRow, face)", 1, true) ~= nil, "drawn by the client from the model")
    H.assertTrue(body:find("resultRow._efFacePending = face", 1, true) ~= nil, "a row below the view waits")
    H.assertTrue(s > src:find("elseif iconFileID or data.clipAtlas then", 1, true), "an icon, where there is one, comes first")
end

local pass, fail, failures = H.runSuite("BossFaces", tests)
return { pass = pass, fail = fail, failures = failures }

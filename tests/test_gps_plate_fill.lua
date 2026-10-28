-- The GPS plates (under the beacon and the arrow) wear the theme's own
-- window fill, as menus and windows do: the Classic marble, Forever's
-- page. A flat color left a navy block beside a tree-dressed Notes window
-- (2026-10-27). A picked talent tree's painting is too big for a plate,
-- and the whole tree under the fill showed an arbitrary strip with square
-- corners: a plate shows a window from the middle of the tree's top left
-- piece, cropped round through the art cells; the Classic frame keeps the
-- tree inside it as before.
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.thePlateWearsTheThemesFill()
    local src = Read("Apps/GPS/WorldPin.lua")
    H.assertTrue(src:find('local function PaintPlate%(p%)%s+p%._efArtPath = ns%.ClassicTreePiece%("TopLeft"%)%s+p%._efArtCenter = p%._efArtPath ~= nil%s+ns%.ApplyThemeFill%(p%)') ~= nil,
        "the shared theme fill, a tree piece's window first")
    H.assertNil(src:find("SetRoundedRectBorderFillColor(p,", 1, true), "no flat color of its own")
end

function tests.aFramesOwnArtWindowCropsRound()
    local src = Read("Shared/Utils.lua")
    H.assertTrue(src:find("if frame%._efArtPath or not %(p and p%.chrome == \"classic\" and ns%.ShowsTree%(frame%)%) then") ~= nil,
        "the whole tree under the fill stands back for a frame's own window")
    H.assertTrue(src:find("local artPath = own or %(palette and palette%.fillTexture%)") ~= nil, "the window before the palette's art")
    H.assertTrue(src:find("%(own and ns%.CLASSIC_TREE_PIECE or palette%.fillTile%)") ~= nil, "at the piece's own size")
    H.assertTrue(src:find("if frame%._efArtCenter and tile then%s+x0, y0 = math%.max%(0, %(tile %- w%) / 2%) %* sx, math%.max%(0, %(tile %- fh%) / 2%) %* sy") ~= nil,
        "the window from the painting's middle")
end

-- The crop's texcoords with a centered window: a 190 by 34 frame on a 256
-- piece reads 33 to 223 across and 111 to 145 down, the corners' cells
-- a corner wide.
function tests.theWindowSitsInTheMiddle()
    local src = Read("Shared/Utils.lua"):gsub("\r\n", "\n")
    local s = assert(src:find("\nfunction ns.UpdateThemeArtCrop(frame)", 1, true))
    local _, e = assert(src:find("\nend\n", s, true))
    local ns = {}
    local env = setmetatable({ ns = ns, ART_TEXTURE_SIZE = 512, FOREVER = {} }, { __index = _G })
    assert(load(src:sub(s, e), "=UpdateThemeArtCrop", "t", env))()
    local coords = {}
    local cells = {}
    for _, k in ipairs({ "tl", "tm", "tr", "ml", "mm", "mr", "bl", "bm", "br" }) do
        cells[k] = { SetTexCoord = function(_, a, b, c, d) coords[k] = { a, b, c, d } end }
    end
    local frame = { _efArtCells = cells, _efArtTile = 256, _efArtCenter = true, cbBarHeight = 16,
                    GetWidth = function() return 190 end, GetHeight = function() return 34 end }
    ns.UpdateThemeArtCrop(frame)
    local function near(a, b) return math.abs(a - b) < 1e-6 end
    H.assertTrue(near(coords.tl[1], 33 / 256) and near(coords.tl[2], 41 / 256), "left corner cell: 33 to 41 px in")
    H.assertTrue(near(coords.mm[2], 215 / 256) and near(coords.tr[2], 223 / 256), "the window ends 223 px in")
    H.assertTrue(near(coords.tl[3], 111 / 256) and near(coords.bl[4], 145 / 256), "111 to 145 px down")
end

local pass, fail, failures = H.runSuite("GPSPlateFill", tests)
return { pass = pass, fail = fail, failures = failures }

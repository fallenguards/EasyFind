-- The guide lights a button's own highlight art (Apps/Guide/Highlight.lua):
-- a skill's bar border, a spell's icon, a tab, pulsing, in place of the
-- yellow box round it (on Anniversary's skills the box hugged a 281x32
-- button round a 15-tall bar). Frames with no highlight of their own keep
-- the box; a lock the client holds survives the guide letting go.
local H = require("Harness")

local function Load(combat)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Guide/Highlight.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local s = assert(src:find("local function NativeHighlightOf", 1, true), "NativeHighlightOf")
    local e = assert(src:find("function Highlight:HighlightFrame", s, true), "the highlight's start")
    local hf = {}
    local env = setmetatable({ highlightFrame = hf, InCombatLockdown = function() return combat end },
        { __index = _G })
    local chunk = "local highlightFrame = highlightFrame\n" .. src:sub(s, e - 1)
        .. "\nreturn NativeHighlightOf, ReleaseNativeHighlight"
    local native, release = assert(load(chunk, "=Highlight.lua native", "t", env))()
    return native, release, hf
end

local function Button(opts)
    local b = { locked = opts.locked or false }
    local tex = opts.art and {
        GetAtlas = function() return nil end, GetTexture = function() return opts.art end,
        alpha = 1, SetAlpha = function(t, a) t.alpha = a end, GetAlpha = function(t) return t.alpha end,
    }
    function b:GetHighlightTexture() return tex end
    function b:LockHighlight() self.locked = true end
    function b:UnlockHighlight() self.locked = false end
    function b:IsHighlightLocked() return self.locked end
    function b:IsProtected() return opts.protected or false end
    return b, tex
end

local tests = {}

function tests.aButtonsOwnArtIsLit()
    local native = Load(false)
    local btn, tex = Button({ art = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-BarBorderHighlight" })
    H.assertTrue(native(btn) == tex, "the skill bar's own border highlight")
    H.assertNil(native(Button({})), "no highlight art: the box")
    H.assertNil(native({}), "not a button: the box")
end

function tests.aProtectedButtonInAFightKeepsTheBox()
    local native = Load(true)
    local btn = Button({ art = "x", protected = true })
    H.assertNil(native(btn))
end

function tests.lettingGoKeepsTheClientsOwnLock()
    local _, release, hf = Load(false)
    local mine, myTex = Button({ art = "x" })
    mine:LockHighlight()
    myTex:SetAlpha(0.6)
    hf._nativeTarget, hf._nativeTex, hf._nativeLocked, hf._nativeAlpha = mine, myTex, true, 1
    release()
    H.assertFalse(mine:IsHighlightLocked(), "our lock let go")
    H.assertEq(myTex:GetAlpha(), 1, "its art's alpha back")
    local theirs, theirTex = Button({ art = "x", locked = true })
    hf._nativeTarget, hf._nativeTex, hf._nativeLocked, hf._nativeAlpha = theirs, theirTex, false, 1
    release()
    H.assertTrue(theirs:IsHighlightLocked(), "a selected tab stays selected")
    H.assertNil(hf._nativeTarget)
end

local pass, fail, failures = H.runSuite("NativeHighlight", tests)
return { pass = pass, fail = fail, failures = failures }

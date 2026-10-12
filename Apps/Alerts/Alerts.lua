local addonName, AL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and AL.Store and AL.Engine and AL.Window) then return end

-- What the core calls (ns.Alerts), and the start once saved alerts arrive.
local Alerts = {}
local Utils = ns.Utils
local L = ns.L
local S = { ready = false, openQueued = false }

function Alerts.Open()
    if not S.ready then
        S.openQueued = true
        return
    end
    AL.Window.Show()
end

function Alerts.Close()
    AL.Window.Hide()
end

function Alerts.IsOpen()
    return AL.Window.IsShown()
end

function Alerts.Toggle()
    if Alerts.IsOpen() then Alerts.Close() else Alerts.Open() end
end

-- /alerts opens the window; "/alerts new" opens the new-alert menu.
function Alerts.Slash(msg)
    Alerts.Open()
    if (msg or ""):lower():match("^%s*new") and S.ready then
        Utils.ShowCursorMenu("EasyFindAlertsMenu", AL.Window.NewMenuRows())
    end
end

local function Init()
    EasyAlertsDB = AL.Store:Attach(EasyAlertsDB)
    AL.Engine.Start()
    S.ready = true
    if S.openQueued then
        S.openQueued = false
        AL.Window.Show()
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= addonName then return end
    self:UnregisterEvent("ADDON_LOADED")
    local ok, err = Utils.xpcall(Init, Utils.ErrorHandler)
    if not ok then EasyFind:Print(L["ERR_MODULE_INIT_FAILED"]:format(L["APP_ALERTS"], tostring(err))) end
end)

ns.Alerts = Alerts

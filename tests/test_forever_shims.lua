-- Retail keeps old global names (GetItemInfo, GetItemInfoInstant, ...) in
-- deprecation shims; WoW Forever ships none of these, so a bare call is nil
-- there. A shipped line may name one only beside its C_ replacement, or as a
-- local its file defines. List: every name a retail Blizzard_Deprecated* file
-- defines that the Forever interface code never does (C:/tmp/wow-ui-*).
local H = require("Harness")

local REPLACEMENT = {
    AcceptSockets = "C_ItemSocketInfo.AcceptSockets",
    ActionBindsItem = "C_Item.ActionBindsItem",
    BindEnchant = "C_Item.BindEnchant",
    ClickSocketButton = "C_ItemSocketInfo.ClickSocketButton",
    CloseSocketInfo = "C_ItemSocketInfo.CloseSocketInfo",
    ConfirmBindOnUse = "C_Item.ConfirmBindOnUse",
    ConfirmNoRefundOnUse = "C_Item.ConfirmNoRefundOnUse",
    ConfirmOnUse = "C_Item.ConfirmOnUse",
    DoesItemContainSpec = "C_Item.DoesItemContainSpec",
    DropItemOnUnit = "C_Item.DropItemOnUnit",
    EndBoundTradeable = "C_Item.EndBoundTradeable",
    EndRefund = "C_Item.EndRefund",
    EquipItemByName = "C_Item.EquipItemByName",
    GetCoinIcon = "C_CurrencyInfo.GetCoinIcon",
    GetCoinText = "C_CurrencyInfo.GetCoinText",
    GetCoinTextureString = "C_CurrencyInfo.GetCoinTextureString",
    GetDetailedItemLevelInfo = "C_Item.GetDetailedItemLevelInfo",
    GetExistingSocketInfo = "C_ItemSocketInfo.GetExistingSocketInfo",
    GetExistingSocketLink = "C_ItemSocketInfo.GetExistingSocketLink",
    GetItemChildInfo = "C_Item.GetItemChildInfo",
    GetItemClassInfo = "C_Item.GetItemClassInfo",
    GetItemCooldown = "C_Item.GetItemCooldown",
    GetItemCount = "C_Item.GetItemCount",
    GetItemCreationContext = "C_Item.GetItemCreationContext",
    GetItemFamily = "C_Item.GetItemFamily",
    GetItemGem = "C_Item.GetItemGem",
    GetItemIcon = "C_Item.GetItemIconByID",
    GetItemInfo = "C_Item.GetItemInfo",
    GetItemInfoInstant = "C_Item.GetItemInfoInstant",
    GetItemInventorySlotInfo = "C_Item.GetItemInventorySlotInfo",
    GetItemQualityColor = "C_Item.GetItemQualityColor",
    GetItemSetInfo = "C_Item.GetItemSetInfo",
    GetItemSpecInfo = "C_Item.GetItemSpecInfo",
    GetItemSpell = "C_Item.GetItemSpell",
    GetItemSubClassInfo = "C_Item.GetItemSubClassInfo",
    GetItemUniqueness = "C_Item.GetItemUniqueness",
    GetNewSocketInfo = "C_ItemSocketInfo.GetNewSocketInfo",
    GetNewSocketLink = "C_ItemSocketInfo.GetNewSocketLink",
    GetNumSockets = "C_ItemSocketInfo.GetNumSockets",
    GetPetTalentTree = "C_PetInfo.GetPetTalentTree",
    GetSocketItemBoundTradeable = "C_ItemSocketInfo.GetSocketItemBoundTradeable",
    GetSocketItemInfo = "C_ItemSocketInfo.GetSocketItemInfo",
    GetSocketItemRefundable = "C_ItemSocketInfo.GetSocketItemRefundable",
    GetSocketTypes = "C_ItemSocketInfo.GetSocketTypes",
    GetZonePVPInfo = "C_PvP.GetZonePVPInfo",
    HasBoundGemProposed = "C_ItemSocketInfo.HasBoundGemProposed",
    IsArtifactPowerItem = "C_Item.IsArtifactPowerItem",
    IsConsumableItem = "C_Item.IsConsumableItem",
    IsCorruptedItem = "C_Item.IsCorruptedItem",
    IsCosmeticItem = "C_Item.IsCosmeticItem",
    IsCurrentItem = "C_Item.IsCurrentItem",
    IsDressableItem = "C_Item.IsDressableItem",
    IsEquippableItem = "C_Item.IsEquippableItem",
    IsEquippedItem = "C_Item.IsEquippedItem",
    IsEquippedItemType = "C_Item.IsEquippedItemType",
    IsHarmfulItem = "C_Item.IsHarmfulItem",
    IsHelpfulItem = "C_Item.IsHelpfulItem",
    IsItemInRange = "C_Item.IsItemInRange",
    IsOnGlueScreen = "C_Glue.IsOnGlueScreen",
    IsSubZonePVPPOI = "C_PvP.IsSubZonePVPPOI",
    IsUsableItem = "C_Item.IsUsableItem",
    ItemHasRange = "C_Item.ItemHasRange",
    PetAssistMode = "C_PetInfo.PetAssistMode",
    PickupItem = "C_Item.PickupItem",
    PickupTradeMoney = "C_TradeInfo.PickupTradeMoney",
    PlayVocalErrorSoundID = "C_Sound.PlayVocalErrorSound",
    ReplaceEnchant = "C_Item.ReplaceEnchant",
    ReplaceTradeEnchant = "C_Item.ReplaceTradeEnchant",
    ReplaceTradeskillEnchant = "C_Item.ReplaceTradeskillEnchant",
    SetPVP = "C_PvP.SetPVP",
    TogglePVP = "C_PvP.TogglePVP",
    UseItemByName = "C_Item.UseItemByName",
}

local function scan(text)
    local own, hits, lines = {}, {}, {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        lines[#lines + 1] = (line:gsub("%-%-.*$", ""))
    end
    for _, code in ipairs(lines) do
        local fn = code:match("local%s+function%s+([%a_][%w_]*)")
        if fn and REPLACEMENT[fn] then own[fn] = true end
        local name = code:match("local%s+([%a_][%w_]*)%s*=")
        if name and REPLACEMENT[name] and code:find(REPLACEMENT[name], 1, true) then own[name] = true end
    end
    for n, code in ipairs(lines) do
        for pos, word in code:gmatch("()([%a_][%w_]*)") do
            local target = REPLACEMENT[word]
            local before = pos > 1 and code:sub(pos - 1, pos - 1) or ""
            if target and not before:find("[%w_%.:\"']") and not own[word]
                    and not code:find(target, 1, true) then
                hits[#hits + 1] = n .. ": " .. word .. " (use " .. target .. ")"
            end
        end
    end
    return hits
end

local tests = {}

function tests.noShippedLineCallsARetailOnlyShim()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                for _, hit in ipairs(scan(fh:read("a"))) do bad[#bad + 1] = rel .. ":" .. hit end
                fh:close()
                checked = checked + 1
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "retail-only globals:\n  " .. table.concat(bad, "\n  "))
end

function tests.scan_flagsTheBareName()
    H.assertEq(#scan("local _, _, _, loc = GetItemInfoInstant(id)"), 1)
    H.assertEq(#scan("local f = GetItemInfoInstant"), 1)
    H.assertEq(#scan("local GetItemInfo = GetItemInfo\nlocal n = GetItemInfo(id)"), 3)
end

function tests.scan_acceptsTheReplacementBesideIt()
    H.assertEq(#scan("local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant"), 0)
    H.assertEq(#scan("local GetItemInfo = C_Item.GetItemInfo\nlocal n = GetItemInfo(id)"), 0)
    H.assertEq(#scan("local function IsUsableItem(id) return true end\nif IsUsableItem(1) then end"), 0)
    H.assertEq(#scan("x = C_Item.GetItemInfo(id) -- not GetItemInfo"), 0)
    H.assertEq(#scan('local s = "GetItemInfo"'), 0)
end

local pass, fail, failures = H.runSuite("ForeverShims", tests)
return { pass = pass, fail = fail, failures = failures }

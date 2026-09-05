local DEATH_LOOT_DELAY = 0.10
local defaults = {
    enabled = true,
}

AutoAreaLootDB = AutoAreaLootDB or {}
for key, value in pairs(defaults) do
    if type(AutoAreaLootDB[key]) ~= type(value) then
        AutoAreaLootDB[key] = value
    end
end

local state = {
    pendingLoot = false,
    manualLootOpen = false,
}

local eventFrame
local missingClassicAPIWarningShown = false

local function HasClassicAPILoot()
    if C_Loot and type(C_Loot.LootAllCorpses) == "function" then
        return true
    end
    if not missingClassicAPIWarningShown then
        missingClassicAPIWarningShown = true
        DEFAULT_CHAT_FRAME:AddMessage("Auto Area Loot requires the ClassicAPI DLL with C_Loot.LootAllCorpses.")
    end
    return false
end

local function LootNearbyCorpses()
    if not AutoAreaLootDB.enabled or not HasClassicAPILoot() then return false end

    if state.manualLootOpen then
        state.pendingLoot = true
        return false
    end

    local started = C_Loot.LootAllCorpses() and true or false
    if not started and type(C_Loot.IsScanInProgress) == "function" and C_Loot.IsScanInProgress() then
        state.pendingLoot = true
    end
    return started
end

eventFrame = CreateFrame("Frame")
local function IsEventAvailable(eventName)
    return C_EventUtils
        and type(C_EventUtils.IsEventValid) == "function"
        and C_EventUtils.IsEventValid(eventName)
end

eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
if IsEventAvailable("PLAYER_STOPPED_MOVING") then
    eventFrame:RegisterEvent("PLAYER_STOPPED_MOVING")
end
if IsEventAvailable("LOOT_SCAN_COMPLETED") then
    eventFrame:RegisterEvent("LOOT_SCAN_COMPLETED")
end
if IsEventAvailable("UNIT_DIED") then
    eventFrame:RegisterEvent("UNIT_DIED")
else
    eventFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
end

eventFrame:SetScript("OnEvent", function()
    if event == "PLAYER_LEAVING_WORLD" then
        state.pendingLoot = false
        state.manualLootOpen = false
        return
    end

    if event == "PLAYER_STOPPED_MOVING" then
        LootNearbyCorpses()
        return
    end

    if event == "UNIT_DIED" or event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" then
        C_Timer.After(DEATH_LOOT_DELAY, LootNearbyCorpses)
        return
    end

    if event == "LOOT_OPENED" then
        state.manualLootOpen = true
        return
    end

    if event == "LOOT_CLOSED" then
        state.manualLootOpen = false
        LootNearbyCorpses()
        return
    end

    if event == "LOOT_SCAN_COMPLETED" then
        if state.pendingLoot then
            state.pendingLoot = false
            LootNearbyCorpses()
        end
        return
    end

end)

SLASH_AUTOAREA_LOOT1 = "/aal"
SlashCmdList["AUTOAREA_LOOT"] = function(message)
    local command = string.lower((message or ""):match("^%s*(.-)%s*$"))

    if command == "on" then
        AutoAreaLootDB.enabled = true
        DEFAULT_CHAT_FRAME:AddMessage("Auto Area Loot: enabled.")
    elseif command == "off" then
        AutoAreaLootDB.enabled = false
        DEFAULT_CHAT_FRAME:AddMessage("Auto Area Loot: disabled.")
    elseif command == "status" then
        DEFAULT_CHAT_FRAME:AddMessage("Auto Area Loot is " .. (AutoAreaLootDB.enabled and "enabled" or "disabled") .. ".")
    else
        DEFAULT_CHAT_FRAME:AddMessage("Auto Area Loot commands: /aal on, /aal off, /aal status")
    end
end

HasClassicAPILoot()

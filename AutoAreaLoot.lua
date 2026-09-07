local DEATH_LOOT_DELAY = 0.10
local defaults = {
    enabled = true,
}

local state = {
    initialized = false,
    manualLootOpen = false,
}

local function InitializeSettings()
    if type(AutoAreaLootDB) ~= "table" then
        AutoAreaLootDB = {}
    end
    for key, value in pairs(defaults) do
        if type(AutoAreaLootDB[key]) ~= type(value) then
            AutoAreaLootDB[key] = value
        end
    end
    state.initialized = true
end

local eventFrame
local missingClassicAPIWarningShown = false

local function HasClassicAPILoot()
    if C_Loot and type(C_Loot.LootAllCorpses) == "function" then
        return true
    end
    if not missingClassicAPIWarningShown then
        missingClassicAPIWarningShown = true
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot requires the ClassicAPI DLL with C_Loot.LootAllCorpses.")
    end
    return false
end

local function LootNearbyCorpses()
    if not state.initialized or not AutoAreaLootDB.enabled or not HasClassicAPILoot() then return false end

    if state.manualLootOpen then
        return false
    end

    if type(C_Loot.IsScanInProgress) == "function" and C_Loot.IsScanInProgress() then
        return false
    end

    local started = C_Loot.LootAllCorpses() and true or false
    if started then
        state.deathTimer = nil
    end
    return started
end

local function ScheduleDeathLoot()
    if not state.initialized or not AutoAreaLootDB.enabled or state.deathTimer then return end
    if not HasClassicAPILoot() or not C_Timer or type(C_Timer.After) ~= "function" then return end

    -- One timer per burst; invalidated tokens cannot service a later request.
    local token = {}
    state.deathTimer = token
    C_Timer.After(DEATH_LOOT_DELAY, function()
        if state.deathTimer ~= token then return end
        state.deathTimer = nil
        LootNearbyCorpses()
    end)
end

eventFrame = CreateFrame("Frame")
local function IsEventAvailable(eventName)
    return C_EventUtils
        and type(C_EventUtils.IsEventValid) == "function"
        and C_EventUtils.IsEventValid(eventName)
end

eventFrame:RegisterEvent("ADDON_LOADED")
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
    if event == "ADDON_LOADED" then
        if arg1 == "AutoAreaLoot" then
            InitializeSettings()
            eventFrame:UnregisterEvent("ADDON_LOADED")
            HasClassicAPILoot()
        end
        return
    end

    if event == "PLAYER_LEAVING_WORLD" then
        state.deathTimer = nil
        state.manualLootOpen = false
        return
    end

    if event == "PLAYER_STOPPED_MOVING" then
        LootNearbyCorpses()
        return
    end

    if event == "UNIT_DIED" or event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" then
        ScheduleDeathLoot()
        return
    end

    if event == "LOOT_OPENED" then
        state.manualLootOpen = true
        return
    end

    if event == "LOOT_CLOSED" then
        state.manualLootOpen = false
        return
    end

    if event == "LOOT_SCAN_COMPLETED" then
        -- The completed walk already covered its queued corpses.  Invalidate
        -- a death timer that was scheduled while it was running, and do not
        -- launch a second walk from the completion event.
        state.deathTimer = nil
        return
    end

end)

SLASH_AUTOAREA_LOOT1 = "/aal"
SlashCmdList["AUTOAREA_LOOT"] = function(message)
    if not state.initialized then return end
    local command = string.lower(string.match(message or "", "^%s*(.-)%s*$"))

    if command == "on" then
        AutoAreaLootDB.enabled = true
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot: enabled.")
    elseif command == "off" then
        AutoAreaLootDB.enabled = false
        state.deathTimer = nil
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot: disabled.")
    elseif command == "status" then
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot is " .. (AutoAreaLootDB.enabled and "enabled" or "disabled") .. ".")
    else
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot commands: /aal on, /aal off, /aal status")
    end
end

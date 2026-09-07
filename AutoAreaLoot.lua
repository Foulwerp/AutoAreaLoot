local DEATH_LOOT_DELAY = 0.10
local defaults = {
    enabled = true,
    lootOnDeath = true,
    lootOnStop = true,
    lootInCombat = true,
    settingsVersion = 3,
}

local state = {
    initialized = false,
    manualLootOpen = false,
    pendingCombatLoot = false,
}

local configFrame

local function InitializeSettings()
    if type(AutoAreaLootDB) ~= "table" then
        AutoAreaLootDB = {}
    end

    local settingsVersion = tonumber(AutoAreaLootDB.settingsVersion) or 0
    if settingsVersion < 2 then
        if type(AutoAreaLootDB.autoLootOutOfCombat) == "boolean" then
            AutoAreaLootDB.lootOnStop = AutoAreaLootDB.autoLootOutOfCombat
        end
        AutoAreaLootDB.lootOnDeath = true
    end
    if settingsVersion < 3 then
        AutoAreaLootDB.lootInCombat = true
    end
    if settingsVersion < defaults.settingsVersion then
        AutoAreaLootDB.autoLootOutOfCombat = nil
        AutoAreaLootDB.settingsVersion = defaults.settingsVersion
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

local function IsPlayerInCombat()
    return type(UnitAffectingCombat) == "function" and UnitAffectingCombat("player")
end

local function LootNearbyCorpses()
    if not state.initialized or not AutoAreaLootDB.enabled or not HasClassicAPILoot() then return false end

    if IsPlayerInCombat() and not AutoAreaLootDB.lootInCombat then
        state.pendingCombatLoot = true
        return false
    end

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
    if not state.initialized or not AutoAreaLootDB.enabled then return end
    if state.deathTimer then return end
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

local function SetEnabled(enabled)
    AutoAreaLootDB.enabled = enabled and true or false
    if not AutoAreaLootDB.enabled then
        state.deathTimer = nil
        state.pendingCombatLoot = false
    end
end

local function CreateCheckButton(name, parent, label, y, setting)
    local check = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    check:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    check:SetWidth(24)
    check:SetHeight(24)

    local text = check:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    text:SetPoint("LEFT", check, "RIGHT", 4, 1)
    text:SetText(label)

    check.setting = setting
    check:SetScript("OnClick", function()
        AutoAreaLootDB[this.setting] = this:GetChecked() and true or false
        if this.setting == "enabled" then
            SetEnabled(AutoAreaLootDB.enabled)
        end
    end)
    return check
end

local function RefreshConfigPanel()
    if not configFrame or not state.initialized then return end
    configFrame.enabledCheck:SetChecked(AutoAreaLootDB.enabled)
    configFrame.deathCheck:SetChecked(AutoAreaLootDB.lootOnDeath)
    configFrame.stopCheck:SetChecked(AutoAreaLootDB.lootOnStop)
    configFrame.combatCheck:SetChecked(AutoAreaLootDB.lootInCombat)
end

local function CreateConfigPanel()
    if configFrame then return end

    configFrame = CreateFrame("Frame", "AutoAreaLootConfigFrame", UIParent)
    configFrame:SetWidth(330)
    configFrame:SetHeight(220)
    configFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    configFrame:SetFrameStrata("DIALOG")
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", function() this:StartMoving() end)
    configFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    configFrame:SetScript("OnShow", RefreshConfigPanel)
    configFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    local title = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", configFrame, "TOP", 0, -18)
    title:SetText("AutoAreaLoot")

    local close = CreateFrame("Button", nil, configFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -4, -4)

    configFrame.enabledCheck = CreateCheckButton(
        "AutoAreaLootEnabledCheckButton", configFrame, "Loot enabled", -48, "enabled")
    configFrame.deathCheck = CreateCheckButton(
        "AutoAreaLootDeathCheckButton", configFrame, "Loot on death", -82, "lootOnDeath")
    configFrame.stopCheck = CreateCheckButton(
        "AutoAreaLootStopCheckButton", configFrame, "Loot on movement stop", -116, "lootOnStop")
    configFrame.combatCheck = CreateCheckButton(
        "AutoAreaLootCombatCheckButton", configFrame, "Allow looting in combat", -150, "lootInCombat")

    local note = configFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    note:SetPoint("BOTTOMLEFT", configFrame, "BOTTOMLEFT", 22, 19)
    note:SetText("Combat off: triggers wait for one pass when combat ends.")

    configFrame:Hide()
end

local function ShowConfigPanel()
    CreateConfigPanel()
    if configFrame:IsShown() then
        configFrame:Hide()
    else
        configFrame:Show()
    end
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
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
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
            CreateConfigPanel()
            eventFrame:UnregisterEvent("ADDON_LOADED")
            HasClassicAPILoot()
        end
        return
    end

    if event == "PLAYER_LEAVING_WORLD" then
        state.deathTimer = nil
        state.pendingCombatLoot = false
        state.manualLootOpen = false
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        if state.pendingCombatLoot then
            state.pendingCombatLoot = false
            ScheduleDeathLoot()
        end
        return
    end

    if event == "PLAYER_STOPPED_MOVING" then
        if AutoAreaLootDB.lootOnStop then
            if IsPlayerInCombat() then
                state.pendingCombatLoot = true
                if AutoAreaLootDB.lootInCombat then
                    LootNearbyCorpses()
                end
            else
                LootNearbyCorpses()
            end
        end
        return
    end

    if event == "UNIT_DIED" or event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" then
        if AutoAreaLootDB.lootOnDeath then
            if IsPlayerInCombat() then
                state.pendingCombatLoot = true
                if AutoAreaLootDB.lootInCombat then
                    ScheduleDeathLoot()
                end
            else
                ScheduleDeathLoot()
            end
        end
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
        SetEnabled(true)
        RefreshConfigPanel()
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot: enabled.")
    elseif command == "off" then
        SetEnabled(false)
        RefreshConfigPanel()
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot: disabled.")
    elseif command == "status" then
        DEFAULT_CHAT_FRAME:AddMessage(
            "AutoAreaLoot is " .. (AutoAreaLootDB.enabled and "enabled" or "disabled")
            .. "; death trigger " .. (AutoAreaLootDB.lootOnDeath and "on" or "off")
            .. "; stop trigger " .. (AutoAreaLootDB.lootOnStop and "on" or "off")
            .. "; combat looting " .. (AutoAreaLootDB.lootInCombat and "on" or "off")
            .. ".")
    else
        ShowConfigPanel()
    end
end

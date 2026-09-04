local DEATH_LOOT_DELAY = 0.10
local LOOT_RETRY_DELAY = 0.05
local defaults = {
    enabled = true,
    minimapAngle = 225,
}

AutoAreaLootDB = AutoAreaLootDB or {}
if AutoAreaLootDB.enabled == nil and AutoAreaLootDB.autoLootNearby ~= nil then
    AutoAreaLootDB.enabled = AutoAreaLootDB.autoLootNearby
end
for key, value in pairs(defaults) do
    if type(AutoAreaLootDB[key]) ~= type(value) then
        AutoAreaLootDB[key] = value
    end
end
AutoAreaLootDB.autoLootNearby = nil
AutoAreaLootDB.onDeath = nil
AutoAreaLootDB.onStopMoving = nil
AutoAreaLootDB.onCombatEnd = nil
AutoAreaLootDB.showSummary = nil
AutoAreaLootDB.verboseLogging = nil

local state = {
    walkActive = false,
    pendingLoot = false,
    lootScheduled = false,
    manualLootOpen = false,
    automationID = 0,
}

local settingsMenu
local minimapButton
local eventFrame
local ScheduleAutomaticLoot
local missingClassicAPIWarningShown = false

local function HasClassicAPILoot()
    if C_Loot and type(C_Loot.LootAllCorpses) == "function" then
        return true
    end
    if not missingClassicAPIWarningShown then
        missingClassicAPIWarningShown = true
        DEFAULT_CHAT_FRAME:AddMessage("Auto Area Loot requires !!!ClassicAPI to function.")
    end
    return false
end

local function IsPlayerMoving()
    return GetUnitSpeed and (GetUnitSpeed("player") or 0) > 0
end

local function IsLootWalkInProgress()
    if C_Loot and type(C_Loot.IsScanInProgress) == "function" then
        return C_Loot.IsScanInProgress()
    end
    return state.walkActive
end

local function HasNearbyLootableCorpse()
    if not C_Loot or type(C_Loot.GetNearbyLootableUnits) ~= "function" then return true end
    local units = C_Loot.GetNearbyLootableUnits()
    return units and next(units) ~= nil
end

local function StartLootWalk()
    if not AutoAreaLootDB.enabled or not HasClassicAPILoot() then return false end
    if IsPlayerMoving() then return false end

    if state.manualLootOpen or IsLootWalkInProgress() then
        state.pendingLoot = true
        return false
    end

    if not HasNearbyLootableCorpse() then
        state.pendingLoot = false
        return false
    end

    state.pendingLoot = false
    state.walkActive = true
    if not C_Loot.LootAllCorpses() then
        state.walkActive = false
        state.pendingLoot = IsLootWalkInProgress() and true or false
        return false
    end
    return true
end

ScheduleAutomaticLoot = function(delay)
    if not AutoAreaLootDB.enabled or not HasClassicAPILoot() or state.lootScheduled then return end
    state.lootScheduled = true
    local automationID = state.automationID
    C_Timer.After(delay or 0, function()
        if automationID ~= state.automationID then return end
        state.lootScheduled = false
        StartLootWalk()
    end)
end

eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("LOOT_SCAN_COMPLETED")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("PLAYER_STOPPED_MOVING")
eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
if GetNampowerVersion then
    eventFrame:RegisterEvent("UNIT_DIED")
else
    eventFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
end

eventFrame:SetScript("OnEvent", function()
    if event == "PLAYER_LEAVING_WORLD" then
        state.automationID = state.automationID + 1
        state.walkActive = false
        state.pendingLoot = false
        state.lootScheduled = false
        state.manualLootOpen = false
        return
    end

    if event == "PLAYER_STOPPED_MOVING" then
        if not IsPlayerMoving() then
            ScheduleAutomaticLoot(0)
        end
        return
    end

    if event == "UNIT_DIED" or event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" then
        ScheduleAutomaticLoot(DEATH_LOOT_DELAY)
        return
    end

    if event == "LOOT_OPENED" then
        state.manualLootOpen = true
        return
    end

    if event == "LOOT_CLOSED" then
        state.manualLootOpen = false
        if state.pendingLoot then
            state.pendingLoot = false
            ScheduleAutomaticLoot(LOOT_RETRY_DELAY)
        end
        return
    end

    if event == "LOOT_SCAN_COMPLETED" then
        state.walkActive = false
        if state.pendingLoot then
            state.pendingLoot = false
            ScheduleAutomaticLoot(0)
        end
    end
end)

local function SetMinimapPosition()
    if not minimapButton then return end
    local angle = AutoAreaLootDB.minimapAngle or defaults.minimapAngle
    local radians = angle * math.pi / 180
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(radians) * 80, math.sin(radians) * 80)
end

local function AddMenuToggle(key, text, level)
    local info = UIDropDownMenu_CreateInfo()
    info.text = text
    info.checked = AutoAreaLootDB[key] and 1 or nil
    info.keepShownOnClick = 1
    info.func = function()
        AutoAreaLootDB[key] = not AutoAreaLootDB[key]
        if not AutoAreaLootDB.enabled then
            state.automationID = state.automationID + 1
            state.pendingLoot = false
            state.lootScheduled = false
        end
    end
    UIDropDownMenu_AddButton(info, level)
end

local function InitializeSettingsMenu()
    local level = UIDROPDOWNMENU_MENU_LEVEL or 1
    if level ~= 1 then return end
    AddMenuToggle("enabled", "Enable automatic looting", level)
end

local function CreateSettingsMenu()
    local menu = CreateFrame("Frame", "AutoAreaLootSettingsMenu", UIParent, "UIDropDownMenuTemplate")
    UIDropDownMenu_Initialize(menu, InitializeSettingsMenu, "MENU")
    return menu
end

local function ToggleSettings()
    ToggleDropDownMenu(1, nil, settingsMenu, minimapButton, -5, 0)
end

local function Atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    if x > 0 then return math.atan(y / x) end
    if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
    if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
    if y > 0 then return math.pi / 2 end
    if y < 0 then return -math.pi / 2 end
    return 0
end

local function UpdateMinimapDrag()
    local scale = Minimap:GetEffectiveScale()
    local cursorX, cursorY = GetCursorPosition()
    local centerX, centerY = Minimap:GetCenter()
    AutoAreaLootDB.minimapAngle = math.deg(Atan2(cursorY / scale - centerY, cursorX / scale - centerX))
    SetMinimapPosition()
end

local function CreateMinimapButton()
    local button = CreateFrame("Button", "AutoAreaLootMinimapButton", Minimap)
    button:SetWidth(31)
    button:SetHeight(31)
    button:SetFrameStrata("MEDIUM")
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetPoint("CENTER", button, "CENTER", 0, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(53)
    border:SetHeight(53)
    border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetBlendMode("ADD")
    highlight:SetAllPoints(button)

    button:SetScript("OnClick", ToggleSettings)
    button:SetScript("OnDragStart", function()
        this:SetScript("OnUpdate", UpdateMinimapDrag)
    end)
    button:SetScript("OnDragStop", function()
        this:SetScript("OnUpdate", nil)
    end)
    button:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Auto Area Loot")
        GameTooltip:AddLine("Click: toggle automatic looting", 1, 1, 1)
        GameTooltip:AddLine("Drag: reposition", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return button
end

minimapButton = CreateMinimapButton()
settingsMenu = CreateSettingsMenu()
SetMinimapPosition()
HasClassicAPILoot()

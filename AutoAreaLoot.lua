local LOOT_REQUEST_DELAY = 0.10
local DEATH_LOOT_REQUEST_DELAY = 0.25
local POST_SCAN_SETTLE_MIN = 0.35
local POST_SCAN_SETTLE_MAX = 1.25
local POST_SCAN_SETTLE_CUSHION = 0.25
local POST_SCAN_LATENCY_MULTIPLIER = 2
local STOP_LOOT_GRACE = 0.15
local STOP_LOOT_GRACE_MOVEMENT_TOLERANCE = 0.20
local MOVEMENT_SPEED_EPSILON = 0.01
local STOP_LOOT_SAME_AREA_INTERVAL = 0.50
local STOP_LOOT_MOVEMENT_DISTANCE = 5
local PLAYER_STATE_SAMPLE_INTERVAL = 0.10
local LOOT_SCAN_TIMEOUT = 6.0
-- The engine's loot test includes creature reach. This deliberately generous
-- center-distance limit rejects only deaths that are clearly too far away.
local DEATH_TRIGGER_DISTANCE_LIMIT = 8
local LOOT_EVENT_HISTORY_LIMIT = 500
local LOOT_CONFIRM_GRACE = 3
local LOOT_ROW_FONT_SIZE = 10
local LOOT_TIMESTAMP_WIDTH = 52
local LOOT_LOG_MIN_WIDTH = 240
local LOOT_LOG_MIN_HEIGHT = 140
local DEBUG_HISTORY_LIMIT = 300
local DEBUG_LINE_HEIGHT = 12
local PENDING_LOOT_PRIORITY = { retry = 1, combat = 2, moved = 3, death = 4 }
local LOOT_FONT = "Interface\\AddOns\\AutoAreaLoot\\Fonts\\PTSansNarrow.ttf"
local LOOT_FONT_FALLBACK = "Fonts\\FRIZQT__.TTF"
local CIRCLE_TEXTURE = "Interface\\AddOns\\AutoAreaLoot\\Icons\\Circle.tga"
local defaults = {
    enabled = true,
    lootOnDeath = true,
    lootOnStop = true,
    lootInCombat = true,
    lootCombine = false,
    openLootLogOnLogin = false,
    lootLogWidth = 280,
    lootLogHeight = 195,
    lootLogPoint = "CENTER",
    lootLogRelativePoint = "CENTER",
    lootLogX = 0,
    lootLogY = 20,
    settingsVersion = 6,
}

local state = {
    initialized = false,
    manualLootOpen = false,
    autoLootWindowOpen = false,
    pendingLootReason = nil,
    lootAfterCombat = false,
    lootRequestTimer = nil,
    lootSettleUntil = nil,
    lootEvents = {},
    lootEventCount = 0,
    lootRecords = {},
    lootRecordByKey = {},
    lootWalkActive = false,
    lootWalkStartedAt = nil,
    useSpeedMovement = false,
    movementStateKnown = false,
    playerMoving = false,
    channelStateKnown = false,
    playerStateSampleElapsed = 0,
    playerChanneling = false,
    playerControlLost = false,
    stopGraceTimer = nil,
    lastStopLootRequestAt = nil,
    lastStopPositionX = nil,
    lastStopPositionY = nil,
    lastStopPositionZ = nil,
    activeCapture = nil,
    pendingCaptures = {},
    moneyBaseline = nil,
    lootMoney = 0,
    lootHighlightSerial = 0,
    debugEnabled = false,
    debugLines = {},
    debugDirty = false,
}

local configFrame
local lootLogFrame
local lootLogContent
local lootLogSummary
local lootLogMoneySummary
local debugFrame
local debugEditBox
local RefreshDebugLog

local function DebugLog(message)
    if not state.debugEnabled then return end
    local now = type(GetTime) == "function" and GetTime() or 0
    local cleanMessage = tostring(message or "")
    cleanMessage = string.gsub(cleanMessage, "[\r\n]+", " ")
    table.insert(state.debugLines,
        string.format("[%09.3f] %s", now, cleanMessage))
    while table.getn(state.debugLines) > DEBUG_HISTORY_LIMIT do
        table.remove(state.debugLines, 1)
    end
    state.debugDirty = true
end

local validAnchorPoints = {
    TOPLEFT = true,
    TOP = true,
    TOPRIGHT = true,
    LEFT = true,
    CENTER = true,
    RIGHT = true,
    BOTTOMLEFT = true,
    BOTTOM = true,
    BOTTOMRIGHT = true,
}

local function IsPfUIThemeActive()
    return pfUI and pfUI.api and pfUI.media and pfUI_config
        and pfUI_config.appearance and pfUI_config.appearance.border
end

local function GetPfUIConfigColor(value, fallbackR, fallbackG, fallbackB, fallbackA)
    if IsPfUIThemeActive() and type(pfUI.api.GetStringColor) == "function"
        and type(value) == "string" then
        local ok, r, g, b, a = pcall(pfUI.api.GetStringColor, value)
        if ok and r ~= nil and g ~= nil and b ~= nil then
            return r, g, b, a or 1
        end
    end
    return fallbackR, fallbackG, fallbackB, fallbackA
end

local function GetThemeBackgroundColor()
    local value = IsPfUIThemeActive()
        and pfUI_config.appearance.border.background or nil
    return GetPfUIConfigColor(value, 0.051, 0.067, 0.090, 0.99)
end

local function GetThemeBorderColor()
    local value = IsPfUIThemeActive()
        and pfUI_config.appearance.border.color or nil
    return GetPfUIConfigColor(value, 0.188, 0.212, 0.239, 1)
end

local function GetThemeAccentColor()
    if IsPfUIThemeActive() and PFUI_CLASS_COLORS and type(UnitClass) == "function" then
        local _, class = UnitClass("player")
        local color = class and PFUI_CLASS_COLORS[class] or nil
        if color then
            if type(color.GetRGB) == "function" then
                local r, g, b = color:GetRGB()
                if r ~= nil then return r, g, b, 1 end
            elseif color.r and color.g and color.b then
                return color.r, color.g, color.b, color.a or 1
            end
        end
    end
    return 0.345, 0.651, 1.000, 1
end

local function ApplyThemeBackdrop(frame, transparency, shadow)
    if IsPfUIThemeActive() and type(pfUI.api.CreateBackdrop) == "function" then
        local ok = pcall(pfUI.api.CreateBackdrop,
            frame, nil, true, transparency)
        if ok then
            if shadow and type(pfUI.api.CreateBackdropShadow) == "function" then
                pcall(pfUI.api.CreateBackdropShadow, frame)
            end
            return
        end
    end

    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    local br, bg, bb, ba = GetThemeBackgroundColor()
    local er, eg, eb, ea = GetThemeBorderColor()
    frame:SetBackdropColor(br, bg, bb, transparency or ba)
    frame:SetBackdropBorderColor(er, eg, eb, ea)
end

local function ApplyLootFont(fontString, size)
    if not fontString or type(fontString.SetFont) ~= "function" then return end
    if IsPfUIThemeActive() and type(pfUI.font_default) == "string"
        and fontString:SetFont(pfUI.font_default, size, "OUTLINE") then
        return
    end
    if not fontString:SetFont(LOOT_FONT, size, "") then
        fontString:SetFont(LOOT_FONT_FALLBACK, size, "")
    end
end

local function StyleCloseButton(button)
    if not IsPfUIThemeActive() then return end
    button:SetWidth(15)
    button:SetHeight(15)
    button.label:SetText("")
    local texture = button:CreateTexture(nil, "ARTWORK")
    texture:SetAllPoints(button)
    texture:SetTexture(pfUI.media["img:close"])
    texture:SetVertexColor(1, 0.25, 0.25, 1)
end

local function CreateAALButton(parent, width, height, label)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(width)
    button:SetHeight(height)
    ApplyThemeBackdrop(button, 0.95)

    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
    ApplyLootFont(button.label, 10)
    button.label:SetTextColor(0.902, 0.929, 0.953, 1)
    button.label:SetText(label or "")

    button:SetScript("OnEnter", function()
        local r, g, b = GetThemeAccentColor()
        this:SetBackdropBorderColor(r, g, b, 1)
        if not IsPfUIThemeActive() then
            this:SetBackdropColor(0.090, 0.153, 0.243, 1)
        end
    end)
    button:SetScript("OnLeave", function()
        local r, g, b, a = GetThemeBorderColor()
        this:SetBackdropBorderColor(r, g, b, a)
        if not IsPfUIThemeActive() then
            this:SetBackdropColor(0.129, 0.149, 0.176, 1)
        end
    end)
    return button
end

local function CreateAALToggle(parent, label, checked, callback)
    local toggle = CreateFrame("Button", nil, parent)
    toggle:SetWidth(24)
    toggle:SetHeight(12)
    toggle.checked = checked and true or false

    local radius = 6
    local center = toggle:CreateTexture(nil, "BACKGROUND")
    center:SetTexture("Interface\\Buttons\\WHITE8X8")
    center:SetPoint("TOPLEFT", toggle, "TOPLEFT", radius, 0)
    center:SetPoint("BOTTOMRIGHT", toggle, "BOTTOMRIGHT", -radius, 0)

    local left = toggle:CreateTexture(nil, "BACKGROUND")
    left:SetTexture(CIRCLE_TEXTURE)
    left:SetTexCoord(0, 0.5, 0, 1)
    left:SetPoint("TOPLEFT", toggle, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", toggle, "BOTTOMLEFT", 0, 0)
    left:SetWidth(radius)

    local right = toggle:CreateTexture(nil, "BACKGROUND")
    right:SetTexture(CIRCLE_TEXTURE)
    right:SetTexCoord(0.5, 1, 0, 1)
    right:SetPoint("TOPRIGHT", toggle, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", toggle, "BOTTOMRIGHT", 0, 0)
    right:SetWidth(radius)

    local thumb = toggle:CreateTexture(nil, "ARTWORK")
    thumb:SetTexture(CIRCLE_TEXTURE)
    thumb:SetWidth(12)
    thumb:SetHeight(12)
    thumb:SetVertexColor(1, 1, 1, 1)

    toggle.label = toggle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    toggle.label:SetPoint("LEFT", toggle, "RIGHT", 6, 0)
    ApplyLootFont(toggle.label, 10)
    toggle.label:SetTextColor(0.902, 0.929, 0.953, 1)
    toggle.label:SetText(label or "")
    local function Paint(hovered)
        local r, g, b
        if toggle.checked then
            if IsPfUIThemeActive() then
                r, g, b = GetThemeAccentColor()
            else
                r, g, b = 0.184, 0.506, 0.969
            end
        else
            r, g, b = 0.267, 0.302, 0.345
        end
        if hovered then
            r, g, b = r + 0.08, g + 0.08, b + 0.08
        end
        center:SetVertexColor(r, g, b, 1)
        left:SetVertexColor(r, g, b, 1)
        right:SetVertexColor(r, g, b, 1)
        thumb:ClearAllPoints()
        if toggle.checked then
            thumb:SetPoint("RIGHT", toggle, "RIGHT", 0, 0)
        else
            thumb:SetPoint("LEFT", toggle, "LEFT", 0, 0)
        end
    end

    function toggle:SetChecked(value)
        self.checked = value and true or false
        Paint(false)
    end

    function toggle:GetChecked()
        return self.checked
    end

    toggle:SetScript("OnEnter", function() Paint(true) end)
    toggle:SetScript("OnLeave", function() Paint(false) end)

    toggle:SetScript("OnClick", function()
        toggle.checked = not toggle.checked
        Paint(true)
        if callback then callback(toggle.checked) end
    end)
    Paint(false)
    return toggle
end

local function CreateAALScrollbar(parent, scrollFrame, content)
    local scrollbar = CreateFrame("Frame", nil, parent)
    scrollbar:SetWidth(16)
    scrollbar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -6, -48)
    scrollbar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 32)
    scrollbar:EnableMouse(true)
    scrollbar:EnableMouseWheel(true)

    local trackWidth = 4
    local trackCapHeight = 2
    local trackR, trackG, trackB = GetThemeBorderColor()
    local thumbR, thumbG, thumbB = GetThemeAccentColor()
    local trackTop = scrollbar:CreateTexture(nil, "BACKGROUND")
    trackTop:SetTexture(CIRCLE_TEXTURE)
    trackTop:SetTexCoord(0, 1, 0, 0.5)
    trackTop:SetWidth(trackWidth)
    trackTop:SetHeight(trackCapHeight)
    trackTop:SetPoint("TOP", scrollbar, "TOP", 0, 0)
    trackTop:SetVertexColor(trackR, trackG, trackB, 0.9)

    local trackBottom = scrollbar:CreateTexture(nil, "BACKGROUND")
    trackBottom:SetTexture(CIRCLE_TEXTURE)
    trackBottom:SetTexCoord(0, 1, 0.5, 1)
    trackBottom:SetWidth(trackWidth)
    trackBottom:SetHeight(trackCapHeight)
    trackBottom:SetPoint("BOTTOM", scrollbar, "BOTTOM", 0, 0)
    trackBottom:SetVertexColor(trackR, trackG, trackB, 0.9)

    local trackCenter = scrollbar:CreateTexture(nil, "BACKGROUND")
    trackCenter:SetTexture("Interface\\Buttons\\WHITE8X8")
    trackCenter:SetPoint("TOPLEFT", trackTop, "BOTTOMLEFT", 0, 0)
    trackCenter:SetPoint("BOTTOMRIGHT", trackBottom, "TOPRIGHT", 0, 0)
    trackCenter:SetVertexColor(trackR, trackG, trackB, 0.9)

    local thumb = CreateFrame("Button", nil, scrollbar)
    local pillWidth = 12
    local pillHeight = 26
    thumb:SetWidth(20)
    thumb:SetHeight(pillHeight + 6)
    thumb:SetFrameLevel(scrollbar:GetFrameLevel() + 2)
    thumb:EnableMouse(true)
    thumb:EnableMouseWheel(true)
    local capHeight = pillWidth / 2
    local thumbTop = thumb:CreateTexture(nil, "OVERLAY")
    thumbTop:SetTexture(CIRCLE_TEXTURE)
    thumbTop:SetTexCoord(0, 1, 0, 0.5)
    thumbTop:SetWidth(pillWidth)
    thumbTop:SetHeight(capHeight)
    thumbTop:SetPoint("TOP", thumb, "TOP", 0, -3)
    thumbTop:SetVertexColor(thumbR, thumbG, thumbB, 0.95)

    local thumbBottom = thumb:CreateTexture(nil, "OVERLAY")
    thumbBottom:SetTexture(CIRCLE_TEXTURE)
    thumbBottom:SetTexCoord(0, 1, 0.5, 1)
    thumbBottom:SetWidth(pillWidth)
    thumbBottom:SetHeight(capHeight)
    thumbBottom:SetPoint("BOTTOM", thumb, "BOTTOM", 0, 3)
    thumbBottom:SetVertexColor(thumbR, thumbG, thumbB, 0.95)

    local thumbCenter = thumb:CreateTexture(nil, "OVERLAY")
    thumbCenter:SetTexture("Interface\\Buttons\\WHITE8X8")
    thumbCenter:SetPoint("TOPLEFT", thumbTop, "BOTTOMLEFT", 0, 0)
    thumbCenter:SetPoint("BOTTOMRIGHT", thumbBottom, "TOPRIGHT", 0, 0)
    thumbCenter:SetVertexColor(thumbR, thumbG, thumbB, 0.95)

    local maximum = 0
    local dragOffset = 0

    local function UpdateThumb()
        local viewHeight = scrollFrame:GetHeight() or 1
        local contentHeight = content:GetHeight() or viewHeight
        maximum = math.max(0, contentHeight - viewHeight)
        if maximum <= 0 then
            trackTop:Hide()
            trackBottom:Hide()
            trackCenter:Hide()
            thumb:Hide()
            return
        end
        trackTop:Show()
        trackBottom:Show()
        trackCenter:Show()
        thumb:Show()
        local trackHeight = scrollbar:GetHeight() or 1
        local ratio = scrollFrame:GetVerticalScroll() / maximum
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", scrollbar, "TOP", 0,
            3 - ratio * math.max(0, trackHeight - pillHeight))
    end

    local function SetScroll(value)
        value = math.max(0, math.min(value or 0, maximum))
        scrollFrame:SetVerticalScroll(value)
        UpdateThumb()
        if scrollFrame.aalOnScrollChanged then
            scrollFrame.aalOnScrollChanged()
        end
    end
    scrollFrame.aalSetScroll = SetScroll

    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function()
        SetScroll(scrollFrame:GetVerticalScroll() - arg1 * 14)
    end)
    scrollbar:SetScript("OnMouseWheel", function()
        SetScroll(scrollFrame:GetVerticalScroll() - arg1 * 14)
    end)
    scrollbar:SetScript("OnMouseDown", function()
        if arg1 ~= "LeftButton" or maximum <= 0 then return end
        local _, cursorY = GetCursorPosition()
        local scale = scrollbar:GetEffectiveScale() or 1
        local top = scrollbar:GetTop() or 0
        local trackHeight = scrollbar:GetHeight() or 1
        local travel = math.max(1, trackHeight - pillHeight)
        local ratio = math.max(0, math.min(
            (top - cursorY / scale - pillHeight / 2) / travel, 1))
        SetScroll(ratio * maximum)
    end)
    thumb:SetScript("OnMouseDown", function()
        if arg1 ~= "LeftButton" or maximum <= 0 then return end
        local _, cursorY = GetCursorPosition()
        local scale = scrollbar:GetEffectiveScale() or 1
        local _, thumbY = thumb:GetCenter()
        dragOffset = (cursorY / scale) - (thumbY or cursorY / scale)
        this:SetScript("OnUpdate", function()
            local _, currentY = GetCursorPosition()
            local frameTop = scrollbar:GetTop() or 0
            local frameBottom = scrollbar:GetBottom() or frameTop
            local travelTop = frameTop - pillHeight / 2
            local travelBottom = frameBottom + pillHeight / 2
            local wantedY = currentY / scale - dragOffset
            local travel = math.max(1, travelTop - travelBottom)
            local ratio = math.max(0, math.min(
                (travelTop - wantedY) / travel, 1))
            SetScroll(ratio * maximum)
        end)
    end)
    thumb:SetScript("OnMouseUp", function()
        this:SetScript("OnUpdate", nil)
    end)
    thumb:SetScript("OnMouseWheel", function()
        SetScroll(scrollFrame:GetVerticalScroll() - arg1 * 14)
    end)
    thumb:SetScript("OnHide", function()
        this:SetScript("OnUpdate", nil)
    end)
    scrollbar:SetScript("OnSizeChanged", UpdateThumb)
    scrollbar.Update = UpdateThumb
    return scrollbar
end

RefreshDebugLog = function(scrollToBottom)
    if not debugEditBox or not debugFrame or not debugFrame:IsShown() then return end
    local text = table.concat(state.debugLines, "\n")
    debugEditBox:SetText(text)
    local lineCount = math.max(1, table.getn(state.debugLines))
    local viewHeight = debugFrame.scrollFrame:GetHeight() or 1
    debugEditBox:SetHeight(math.max(viewHeight, lineCount * DEBUG_LINE_HEIGHT + 8))
    debugFrame.scrollFrame:UpdateScrollChildRect()
    if scrollToBottom then
        -- Vanilla updates a ScrollFrame's range over several frames after its
        -- EditBox changes. Follow the bottom until that range has settled.
        debugFrame.scrollToBottomFrames = 3
    end
    if debugFrame.scrollbar then debugFrame.scrollbar:Update() end
    state.debugDirty = false
end

local function UpdateDebugTitle()
    if not debugFrame or not debugFrame.title then return end
    debugFrame.title:SetText("AutoAreaLoot Debug - "
        .. (state.debugEnabled and "CAPTURING" or "PAUSED"))
end

local function CreateDebugWindow()
    if debugFrame then return end

    debugFrame = CreateFrame("Frame", "AutoAreaLootDebugFrame", UIParent)
    debugFrame:SetWidth(560)
    debugFrame:SetHeight(300)
    debugFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    debugFrame:SetFrameStrata("DIALOG")
    debugFrame:SetToplevel(true)
    debugFrame:SetMovable(true)
    debugFrame:EnableMouse(true)
    debugFrame:RegisterForDrag("LeftButton")
    debugFrame:SetScript("OnDragStart", function() this:StartMoving() end)
    debugFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    ApplyThemeBackdrop(debugFrame, 0.94, true)

    local header = debugFrame:CreateTexture(nil, "BACKGROUND")
    header:SetTexture("Interface\\Buttons\\WHITE8X8")
    header:SetPoint("TOPLEFT", debugFrame, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", debugFrame, "TOPRIGHT", -1, -1)
    header:SetHeight(34)
    if IsPfUIThemeActive() then
        local r, g, b = GetThemeBackgroundColor()
        header:SetVertexColor(r, g, b, 0.75)
    else
        header:SetVertexColor(0.090, 0.153, 0.243, 0.55)
    end

    local accent = debugFrame:CreateTexture(nil, "BORDER")
    accent:SetTexture("Interface\\Buttons\\WHITE8X8")
    accent:SetPoint("TOPLEFT", debugFrame, "TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", debugFrame, "TOPRIGHT", -1, -1)
    accent:SetHeight(2)
    local accentR, accentG, accentB = GetThemeAccentColor()
    accent:SetVertexColor(accentR, accentG, accentB, 0.85)

    debugFrame.title = debugFrame:CreateFontString(
        nil, "ARTWORK", "GameFontNormalLarge")
    debugFrame.title:SetPoint("TOP", debugFrame, "TOP", 0, -11)
    ApplyLootFont(debugFrame.title, 12)
    debugFrame.title:SetTextColor(0.902, 0.929, 0.953, 1)

    local close = CreateAALButton(debugFrame, 18, 18, "X")
    close:SetPoint("TOPRIGHT", debugFrame, "TOPRIGHT", -6, -6)
    ApplyLootFont(close.label, 9)
    StyleCloseButton(close)
    close:SetScript("OnClick", function() this:GetParent():Hide() end)

    local scrollFrame = CreateFrame(
        "ScrollFrame", "AutoAreaLootDebugScrollFrame", debugFrame)
    scrollFrame:SetPoint("TOPLEFT", debugFrame, "TOPLEFT", 10, -42)
    scrollFrame:SetPoint("BOTTOMRIGHT", debugFrame, "BOTTOMRIGHT", -24, 32)
    debugFrame.scrollFrame = scrollFrame

    debugEditBox = CreateFrame(
        "EditBox", "AutoAreaLootDebugEditBox", scrollFrame)
    debugEditBox:SetWidth(516)
    debugEditBox:SetHeight(220)
    debugEditBox:SetMultiLine(true)
    debugEditBox:SetMaxLetters(0)
    debugEditBox:SetAutoFocus(false)
    debugEditBox:EnableMouse(true)
    ApplyLootFont(debugEditBox, 10)
    debugEditBox:SetTextColor(0.820, 0.870, 0.920, 1)
    debugEditBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    scrollFrame:SetScrollChild(debugEditBox)
    debugFrame.scrollbar = CreateAALScrollbar(
        debugFrame, scrollFrame, debugEditBox)

    local clear = CreateAALButton(debugFrame, 46, 18, "Clear")
    clear:SetPoint("BOTTOMLEFT", debugFrame, "BOTTOMLEFT", 10, 7)
    clear:SetScript("OnClick", function()
        state.debugLines = {}
        RefreshDebugLog(false)
    end)

    local selectAll = CreateAALButton(debugFrame, 66, 18, "Select All")
    selectAll:SetPoint("LEFT", clear, "RIGHT", 6, 0)
    selectAll:SetScript("OnClick", function()
        state.debugEnabled = false
        debugFrame.pauseButton.label:SetText("Resume")
        UpdateDebugTitle()
        RefreshDebugLog(false)
        debugEditBox:SetFocus()
        debugEditBox:HighlightText()
    end)

    local pause = CreateAALButton(debugFrame, 78, 18, "Pause")
    pause:SetPoint("LEFT", selectAll, "RIGHT", 6, 0)
    pause:SetScript("OnClick", function()
        state.debugEnabled = not state.debugEnabled
        this.label:SetText(state.debugEnabled and "Pause" or "Resume")
        UpdateDebugTitle()
        if state.debugEnabled then DebugLog("Debug capture resumed") end
    end)
    debugFrame.pauseButton = pause

    local hint = debugFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hint:SetPoint("BOTTOMRIGHT", debugFrame, "BOTTOMRIGHT", -10, 10)
    ApplyLootFont(hint, 9)
    hint:SetTextColor(0.55, 0.62, 0.70, 1)
    hint:SetText("Select All pauses capture; then Ctrl+C")

    debugFrame:SetScript("OnShow", function()
        debugFrame.debugRefreshElapsed = 0
        UpdateDebugTitle()
        debugFrame.pauseButton.label:SetText(
            state.debugEnabled and "Pause" or "Resume")
        RefreshDebugLog(true)
    end)
    debugFrame:SetScript("OnUpdate", function()
        this.debugRefreshElapsed = (this.debugRefreshElapsed or 0) + arg1
        if state.debugDirty and this.debugRefreshElapsed >= 0.10 then
            this.debugRefreshElapsed = 0
            RefreshDebugLog(true)
        end
        if this.scrollToBottomFrames and this.scrollToBottomFrames > 0 then
            local scrollFrame = this.scrollFrame
            scrollFrame:UpdateScrollChildRect()
            local maximum
            if type(scrollFrame.GetVerticalScrollRange) == "function" then
                maximum = scrollFrame:GetVerticalScrollRange()
            else
                maximum = math.max(0,
                    (debugEditBox:GetHeight() or 1)
                    - (scrollFrame:GetHeight() or 1))
            end
            scrollFrame:SetVerticalScroll(math.max(0, maximum or 0))
            if type(scrollFrame.Scroll) == "function" then
                scrollFrame:Scroll()
            end
            if this.scrollbar then this.scrollbar:Update() end
            this.scrollToBottomFrames = this.scrollToBottomFrames - 1
        end
    end)
    debugFrame:Hide()
end

local function ShowDebugWindow()
    CreateDebugWindow()
    debugFrame:Show()
    UpdateDebugTitle()
    RefreshDebugLog(true)
end

local function StopLootRowHighlight(row)
    row:SetScript("OnUpdate", nil)
    row.highlightElapsed = nil
    row.highlight:SetAlpha(0)
    row.highlight:Hide()
end

local function StartLootRowHighlight(row)
    local holdTime = 0.20
    local fadeTime = 1.00
    row.highlightElapsed = 0
    row.highlight:SetAlpha(1)
    row.highlight:Show()
    row:SetScript("OnUpdate", function()
        this.highlightElapsed = (this.highlightElapsed or 0) + arg1
        if this.highlightElapsed <= holdTime then
            this.highlight:SetAlpha(1)
            return
        end

        local alpha = 1 - ((this.highlightElapsed - holdTime) / fadeTime)
        if alpha <= 0 then
            StopLootRowHighlight(this)
        else
            this.highlight:SetAlpha(alpha)
        end
    end)
end

local function GetLootDisplayRecordCount()
    if AutoAreaLootDB.lootCombine then
        return table.getn(state.lootRecords)
    end
    return table.getn(state.lootEvents)
end

local function GetLootDisplayRecord(index)
    if AutoAreaLootDB.lootCombine then
        return state.lootRecords[index]
    end
    local eventCount = table.getn(state.lootEvents)
    return state.lootEvents[eventCount - index + 1]
end

local function CreateLootLogRow()
    local row = CreateFrame("Frame", nil, lootLogContent)
    row:EnableMouse(true)
    row:EnableMouseWheel(true)
    row.timestamp = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.timestamp:SetJustifyH("RIGHT")
    row.timestamp:SetTextColor(1.000, 0.820, 0.000, 1)
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.text:SetJustifyH("LEFT")
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints(row)
    local r, g, b = GetThemeAccentColor()
    row.highlight:SetTexture(r, g, b, 0.32)
    row.highlight:SetAlpha(0)
    row.highlight:Hide()
    row:SetScript("OnEnter", function()
        if not this.itemLink or not GameTooltip then return end
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, this.itemLink)
        if not ok then GameTooltip:Hide() end
    end)
    row:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
    row:SetScript("OnMouseWheel", function()
        local scrollFrame = lootLogFrame and lootLogFrame.scrollFrame
        if scrollFrame and scrollFrame.aalSetScroll then
            scrollFrame.aalSetScroll(
                (scrollFrame:GetVerticalScroll() or 0) - arg1 * 14)
        end
    end)
    table.insert(lootLogContent.rows, row)
    return row
end

local function RefreshVisibleLootRows()
    if not lootLogFrame or not lootLogContent or not lootLogFrame:IsShown() then
        return
    end

    local rowHeight = LOOT_ROW_FONT_SIZE + 4
    local rowWidth = math.max(1, lootLogContent:GetWidth() or 222)
    local recordCount = GetLootDisplayRecordCount()
    local scrollFrame = lootLogFrame.scrollFrame
    local scrollOffset = scrollFrame:GetVerticalScroll() or 0
    local firstIndex = math.floor(scrollOffset / rowHeight) + 1
    local visibleCount = math.ceil((scrollFrame:GetHeight() or rowHeight) / rowHeight) + 2

    for poolIndex = 1, visibleCount do
        local recordIndex = firstIndex + poolIndex - 1
        local record = recordIndex <= recordCount
            and GetLootDisplayRecord(recordIndex) or nil
        local row = lootLogContent.rows[poolIndex] or CreateLootLogRow()

        if record then
            row:SetHeight(rowHeight)
            row:SetWidth(rowWidth)
            row.timestamp:SetHeight(rowHeight)
            row.text:SetHeight(rowHeight)
            ApplyLootFont(row.timestamp, LOOT_ROW_FONT_SIZE)
            ApplyLootFont(row.text, LOOT_ROW_FONT_SIZE)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", lootLogContent, "TOPLEFT", 4,
                -(recordIndex - 1) * rowHeight)
            row.timestamp:ClearAllPoints()
            row.text:ClearAllPoints()
            if AutoAreaLootDB.lootCombine then
                row.timestamp:Hide()
                row.text:SetPoint("LEFT", row, "LEFT", 3, 0)
                row.text:SetWidth(math.max(1, rowWidth - 6))
                row.text:SetText(record.label .. " x" .. record.count)
            else
                row.timestamp:SetPoint("LEFT", row, "LEFT", 3, 0)
                row.timestamp:SetWidth(LOOT_TIMESTAMP_WIDTH)
                row.timestamp:SetText("[" .. (record.timestamp or "--:--") .. "]")
                row.timestamp:Show()
                row.text:SetPoint("LEFT", row, "LEFT",
                    LOOT_TIMESTAMP_WIDTH + 8, 0)
                row.text:SetWidth(math.max(1,
                    rowWidth - LOOT_TIMESTAMP_WIDTH - 11))
                row.text:SetText(record.message)
            end
            if record.kind == "item" then
                if type(record.key) == "string" then
                    row.itemLink = record.key
                elseif tonumber(record.key) then
                    row.itemLink = "item:" .. tonumber(record.key)
                else
                    row.itemLink = nil
                end
            else
                row.itemLink = nil
            end

            if row.boundRecord ~= record then
                if GameTooltip and type(GameTooltip.IsOwned) == "function"
                    and GameTooltip:IsOwned(row) then
                    GameTooltip:Hide()
                end
                StopLootRowHighlight(row)
                row.boundRecord = record
                row.highlightSerial = nil
            end
            local now = type(GetTime) == "function" and GetTime() or 0
            if AutoAreaLootDB.lootCombine and record.highlightSerial
                and record.highlightUntil and record.highlightUntil > now
                and row.highlightSerial ~= record.highlightSerial then
                row.highlightSerial = record.highlightSerial
                StartLootRowHighlight(row)
            elseif not AutoAreaLootDB.lootCombine
                or not record.highlightUntil or record.highlightUntil <= now then
                StopLootRowHighlight(row)
            end
            row:Show()
        else
            StopLootRowHighlight(row)
            row.boundRecord = nil
            row.itemLink = nil
            row:Hide()
        end
    end

    for poolIndex = visibleCount + 1, table.getn(lootLogContent.rows) do
        local row = lootLogContent.rows[poolIndex]
        StopLootRowHighlight(row)
        row.boundRecord = nil
        row.itemLink = nil
        row:Hide()
    end
end

local function RefreshLootLog()
    if not lootLogContent or not lootLogFrame or not lootLogFrame:IsShown() then
        return
    end

    local rowHeight = LOOT_ROW_FONT_SIZE + 4
    local recordCount = GetLootDisplayRecordCount()
    local contentHeight = math.max(recordCount * rowHeight, 1)
    lootLogContent:SetHeight(contentHeight)

    local scrollFrame = lootLogFrame.scrollFrame
    local maximum = math.max(0, contentHeight - (scrollFrame:GetHeight() or 1))
    if (scrollFrame:GetVerticalScroll() or 0) > maximum then
        scrollFrame:SetVerticalScroll(maximum)
    end

    local moneyText = type(GetCoinTextureString) == "function"
        and GetCoinTextureString(state.lootMoney, 9)
        or (state.lootMoney .. " copper")
    lootLogSummary:SetText("Session loot: " .. state.lootEventCount)
    lootLogMoneySummary:SetText("Money: " .. moneyText)
    scrollFrame:UpdateScrollChildRect()
    RefreshVisibleLootRows()
    if lootLogFrame.scrollbar then
        lootLogFrame.scrollbar:Update()
    end
end

local function GetLootTimestamp()
    if type(date) == "function" then
        local ok, timestamp = pcall(date, "%H:%M:%S")
        if ok and type(timestamp) == "string" then return timestamp end
    end
    if type(GetGameTime) == "function" then
        local ok, hour, minute = pcall(GetGameTime)
        if ok and hour ~= nil and minute ~= nil then
            return string.format("%02d:%02d", hour, minute)
        end
    end
    return "--:--"
end

local function AppendLootEvent(eventData)
    state.lootEventCount = state.lootEventCount + 1
    table.insert(state.lootEvents, eventData)
    while table.getn(state.lootEvents) > LOOT_EVENT_HISTORY_LIMIT do
        table.remove(state.lootEvents, 1)
    end
end

local function AddLootItem(label, key, count)
    local record = state.lootRecordByKey[key]
    if record then
        record.count = record.count + count
        record.label = label
    else
        record = {
            kind = "item",
            key = key,
            label = label,
            count = count,
        }
        table.insert(state.lootRecords, record)
        state.lootRecordByKey[key] = record
    end

    if AutoAreaLootDB.lootCombine and lootLogFrame
        and lootLogFrame:IsShown() then
        state.lootHighlightSerial = state.lootHighlightSerial + 1
        record.highlightSerial = state.lootHighlightSerial
        record.highlightUntil =
            (type(GetTime) == "function" and GetTime() or 0) + 1.20
    end

    local message = label .. (count > 1 and (" x" .. count) or "")
    AppendLootEvent({
        kind = "item",
        label = label,
        key = key,
        count = count,
        timestamp = GetLootTimestamp(),
        message = message,
    })
end

local function FormatMoney(amount)
    if type(GetCoinTextureString) == "function" then
        return "Money: " .. GetCoinTextureString(amount)
    end
    return "Money: " .. amount .. " copper"
end

local function AddLootMoney(amount)
    amount = tonumber(amount) or 0
    if amount <= 0 then return end
    local message = FormatMoney(amount)
    state.lootMoney = state.lootMoney + amount
    AppendLootEvent({
        kind = "money",
        timestamp = GetLootTimestamp(),
        message = message,
        amount = amount,
    })
end

local function SafeGetMoney()
    if type(GetMoney) ~= "function" then return end
    local ok, value = pcall(GetMoney)
    if ok and value ~= nil then
        return tonumber(value)
    end
end

-- Loot confirmation is deliberately independent from the corpse-walk state.
-- CHAT_MSG_LOOT proves an item reached the player; scan results only identify
-- which of those messages came from the corpses handled by this addon.
local lootSelfPattern
local lootSelfTypes
local lootSelfMultiplePattern
local lootSelfMultipleTypes

local function IsPatternMagic(character)
    return string.find("()%.%+%-%*%?[]^$", character, 1, true) ~= nil
end

local function CompileFormatPattern(formatText)
    if type(formatText) ~= "string" then return nil, nil end
    local output = { "^" }
    local captureTypes = {}
    local index = 1
    local length = string.len(formatText)

    while index <= length do
        local character = string.sub(formatText, index, index)
        if character == "%" then
            local nextCharacter = string.sub(formatText, index + 1, index + 1)
            if nextCharacter == "%" then
                table.insert(output, "%%")
                index = index + 2
            elseif nextCharacter == "s" or nextCharacter == "d" then
                table.insert(captureTypes, nextCharacter)
                table.insert(output, nextCharacter == "s" and "(.+)" or "(%d+)")
                index = index + 2
            else
                -- Also support positional formats such as %1$s.
                local cursor = index + 1
                while string.find(string.sub(formatText, cursor, cursor), "%d") do
                    cursor = cursor + 1
                end
                if string.sub(formatText, cursor, cursor) == "$" then
                    local valueType = string.sub(formatText, cursor + 1, cursor + 1)
                    if valueType == "s" or valueType == "d" then
                        table.insert(captureTypes, valueType)
                        table.insert(output, valueType == "s" and "(.+)" or "(%d+)")
                        index = cursor + 2
                    else
                        table.insert(output, "%%")
                        index = index + 1
                    end
                else
                    table.insert(output, "%%")
                    index = index + 1
                end
            end
        else
            if IsPatternMagic(character) then
                table.insert(output, "%" .. character)
            else
                table.insert(output, character)
            end
            index = index + 1
        end
    end

    table.insert(output, "$")
    return table.concat(output), captureTypes
end

local function InitializeLootPatterns()
    lootSelfPattern, lootSelfTypes = CompileFormatPattern(LOOT_ITEM_SELF)
    lootSelfMultiplePattern, lootSelfMultipleTypes =
        CompileFormatPattern(LOOT_ITEM_SELF_MULTIPLE)
end

local function ReadLootCaptures(message, pattern, captureTypes)
    if not pattern or not captureTypes then return nil end
    local first, second = string.match(message, pattern)
    if first == nil then return nil end

    local itemText
    local count = 1
    if captureTypes[1] == "s" then itemText = first end
    if captureTypes[1] == "d" then count = tonumber(first) or 1 end
    if captureTypes[2] == "s" then itemText = second end
    if captureTypes[2] == "d" then count = tonumber(second) or 1 end
    return itemText, count
end

local function ParseSelfLootMessage(message)
    if type(message) ~= "string" then return nil end
    local itemText, count = ReadLootCaptures(
        message, lootSelfMultiplePattern, lootSelfMultipleTypes)
    if not itemText then
        itemText, count = ReadLootCaptures(message, lootSelfPattern, lootSelfTypes)
    end
    if not itemText then return nil end

    local itemIDText = string.match(itemText, "item:(%d+)")
    local itemID = itemIDText and tonumber(itemIDText) or nil
    if not itemID then return nil end
    return {
        kind = "item",
        itemID = itemID,
        label = itemText,
        count = math.max(1, tonumber(count) or 1),
    }
end

local function RemovePendingCapture(capture)
    capture.expirationToken = nil
    for index = table.getn(state.pendingCaptures), 1, -1 do
        if state.pendingCaptures[index] == capture then
            table.remove(state.pendingCaptures, index)
        end
    end
end

local function PrunePendingCaptures()
    local now = type(GetTime) == "function" and GetTime() or 0
    for index = table.getn(state.pendingCaptures), 1, -1 do
        local capture = state.pendingCaptures[index]
        if capture.expiresAt and capture.expiresAt <= now then
            DebugLog("Confirmation window expired; dropping unmatched expectations")
            capture.expirationToken = nil
            table.remove(state.pendingCaptures, index)
        end
    end
end

local function CaptureHasExpectedLoot(capture)
    for _, count in pairs(capture.expectedItems or {}) do
        if count > 0 then return true end
    end
    for _, entry in ipairs(capture.expectedMoney or {}) do
        if entry.remaining > 0 then return true end
    end
    return false
end

local function ConsumeItemConfirmation(capture, confirmation)
    local remaining = capture.expectedItems[confirmation.itemID] or 0
    if remaining <= 0 then return false, confirmation.count end

    local confirmed = math.min(remaining, confirmation.count)
    local key = string.match(confirmation.label, "|H(item:[^|]+)|h")
        or confirmation.itemID
    AddLootItem(confirmation.label, key, confirmed)
    capture.expectedItems[confirmation.itemID] = remaining - confirmed
    DebugLog("Item confirmed: item=" .. confirmation.itemID
        .. " count=" .. confirmed .. " remaining="
        .. capture.expectedItems[confirmation.itemID])
    return true, confirmation.count - confirmed
end

local function ConsumeMoneyConfirmation(capture, amount)
    local remainingAmount = math.max(0, tonumber(amount) or 0)
    local consumed = false
    for _, entry in ipairs(capture.expectedMoney) do
        if remainingAmount <= 0 then break end
        if entry.remaining > 0 then
            local confirmed = math.min(entry.remaining, remainingAmount)
            AddLootMoney(confirmed)
            entry.remaining = entry.remaining - confirmed
            remainingAmount = remainingAmount - confirmed
            consumed = true
        end
    end
    DebugLog("Money confirmation: gained=" .. (tonumber(amount) or 0)
        .. " matched=" .. (consumed and "yes" or "no")
        .. " unmatched=" .. remainingAmount)
    return consumed, remainingAmount
end

local function MatchPendingEvent(captureEvent)
    PrunePendingCaptures()
    DebugLog("Matching " .. captureEvent.kind .. " confirmation against "
        .. table.getn(state.pendingCaptures) .. " completed capture(s)")

    local remaining
    if captureEvent.kind == "item" then
        remaining = math.max(1, tonumber(captureEvent.count) or 1)
    elseif captureEvent.kind == "money" then
        remaining = math.max(0, tonumber(captureEvent.amount) or 0)
    else
        return false
    end

    local matched = false
    local index = 1
    while index <= table.getn(state.pendingCaptures) and remaining > 0 do
        local capture = state.pendingCaptures[index]
        local consumed
        if captureEvent.kind == "item" then
            local confirmation = {
                itemID = captureEvent.itemID,
                label = captureEvent.label,
                count = remaining,
            }
            consumed, remaining = ConsumeItemConfirmation(capture, confirmation)
        else
            consumed, remaining = ConsumeMoneyConfirmation(capture, remaining)
        end

        if consumed then matched = true end
        if not CaptureHasExpectedLoot(capture) then
            capture.expirationToken = nil
            table.remove(state.pendingCaptures, index)
        else
            index = index + 1
        end
    end

    if matched then
        RefreshLootLog()
    end
    if remaining > 0 then
        DebugLog("Confirmation remainder did not match corpse scans: kind="
            .. captureEvent.kind .. " amount=" .. remaining)
    end
    if not matched then
        DebugLog("Confirmation did not match any pending corpse scan")
    end
    return matched, remaining
end

local function BufferOrMatchCaptureEvent(captureEvent)
    -- Delayed confirmations must reach earlier captures before they expire,
    -- even when another walk is still running.
    local _, remaining = MatchPendingEvent(captureEvent)
    if not remaining or remaining <= 0 then return end
    if state.activeCapture then
        if captureEvent.kind == "item" then
            captureEvent.count = remaining
        else
            captureEvent.amount = remaining
        end
        table.insert(state.activeCapture.events, captureEvent)
        DebugLog("Buffered " .. captureEvent.kind
            .. " confirmation while corpse scan is active")
        return
    end
end

local function GetLiveCaptureGuids()
    local liveGuids = {}
    for _, pendingCapture in ipairs(state.pendingCaptures) do
        for guid in pairs(pendingCapture.guids or {}) do
            liveGuids[guid] = true
        end
    end
    return liveGuids
end

local function ShortCorpseGuid(guid)
    if type(guid) ~= "string" then return "unknown" end
    if string.len(guid) <= 10 then return guid end
    return "..." .. string.sub(guid, -8)
end

local function CompleteLootCapture(capture, results)
    PrunePendingCaptures()
    capture.expectedItems = {}
    capture.expectedMoney = {}
    capture.guids = {}

    local scannedCorpseCount = 0
    local corpseCount = 0
    local duplicateCorpseCount = 0
    local itemCount = 0
    local moneyCount = 0
    local liveGuids = GetLiveCaptureGuids()
    for _, corpse in ipairs(results or {}) do
        scannedCorpseCount = scannedCorpseCount + 1
        local guid = type(corpse.guid) == "string" and corpse.guid or nil
        if guid and liveGuids[guid] then
            duplicateCorpseCount = duplicateCorpseCount + 1
            DebugLog("Duplicate corpse expectations skipped: guid="
                .. ShortCorpseGuid(guid))
        else
            corpseCount = corpseCount + 1
            if guid then
                capture.guids[guid] = true
                liveGuids[guid] = true
            end
            DebugLog("Corpse expectations accepted: guid="
                .. ShortCorpseGuid(guid))
            local coin = math.max(0, tonumber(corpse.coin) or 0)
            if coin > 0 then
                table.insert(capture.expectedMoney, { remaining = coin })
                moneyCount = moneyCount + coin
            end
            for _, item in ipairs(corpse.items or {}) do
                local itemID = tonumber(item.itemID)
                if itemID then
                    local count = math.max(1, tonumber(item.count) or 1)
                    capture.expectedItems[itemID] =
                        (capture.expectedItems[itemID] or 0) + count
                    itemCount = itemCount + count
                end
            end
        end
    end

    DebugLog("Scan results prepared: scanned=" .. scannedCorpseCount
        .. " accepted=" .. corpseCount
        .. " duplicates=" .. duplicateCorpseCount
        .. " items=" .. itemCount .. " money=" .. moneyCount
        .. " bufferedEvents=" .. table.getn(capture.events))

    capture.expiresAt = (type(GetTime) == "function" and GetTime() or 0)
        + LOOT_CONFIRM_GRACE
    table.insert(state.pendingCaptures, capture)
    while table.getn(state.pendingCaptures) > 8 do
        RemovePendingCapture(state.pendingCaptures[1])
    end
    for _, captureEvent in ipairs(capture.events) do
        -- Captures are ordered oldest first. This lets delayed loot from a
        -- preceding walk consume its expectations before the new walk's.
        MatchPendingEvent(captureEvent)
    end
    capture.events = {}
    RefreshLootLog()

    if not CaptureHasExpectedLoot(capture) then
        DebugLog("Capture complete; all expected loot already confirmed")
        RemovePendingCapture(capture)
        return
    end

    local expirationToken = {}
    capture.expirationToken = expirationToken
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(LOOT_CONFIRM_GRACE, function()
            if capture.expirationToken ~= expirationToken then return end
            capture.expirationToken = nil
            DebugLog("Confirmation grace timer ended; removing capture")
            RemovePendingCapture(capture)
        end)
    else
        DebugLog("No timer API; removing pending confirmation capture")
        RemovePendingCapture(capture)
    end
end

local function SaveLootLogGeometry()
    if not lootLogFrame or not AutoAreaLootDB then return end

    local width = lootLogFrame:GetWidth()
    local height = lootLogFrame:GetHeight()
    AutoAreaLootDB.lootLogWidth = math.max(
        LOOT_LOG_MIN_WIDTH, tonumber(width) or LOOT_LOG_MIN_WIDTH)
    AutoAreaLootDB.lootLogHeight = math.max(
        LOOT_LOG_MIN_HEIGHT, tonumber(height) or LOOT_LOG_MIN_HEIGHT)

    local point, _, relativePoint, x, y = lootLogFrame:GetPoint()
    if validAnchorPoints[point] and validAnchorPoints[relativePoint] then
        AutoAreaLootDB.lootLogPoint = point
        AutoAreaLootDB.lootLogRelativePoint = relativePoint
        AutoAreaLootDB.lootLogX = tonumber(x) or 0
        AutoAreaLootDB.lootLogY = tonumber(y) or 0
    end
end

local function CreateLootLog()
    if lootLogFrame then return end

    lootLogFrame = CreateFrame("Frame", "AutoAreaLootLogFrame", UIParent)
    lootLogFrame:SetWidth(math.max(
        LOOT_LOG_MIN_WIDTH, AutoAreaLootDB.lootLogWidth))
    lootLogFrame:SetHeight(math.max(
        LOOT_LOG_MIN_HEIGHT, AutoAreaLootDB.lootLogHeight))
    lootLogFrame:SetPoint(
        AutoAreaLootDB.lootLogPoint,
        UIParent,
        AutoAreaLootDB.lootLogRelativePoint,
        AutoAreaLootDB.lootLogX,
        AutoAreaLootDB.lootLogY)
    lootLogFrame:SetFrameStrata("DIALOG")
    lootLogFrame:SetToplevel(true)
    lootLogFrame:SetMovable(true)
    lootLogFrame:SetResizable(true)
    if lootLogFrame.SetMinResize then
        lootLogFrame:SetMinResize(LOOT_LOG_MIN_WIDTH, LOOT_LOG_MIN_HEIGHT)
    end
    if lootLogFrame.SetClampedToScreen then
        lootLogFrame:SetClampedToScreen(true)
    end
    lootLogFrame:EnableMouse(true)
    lootLogFrame:RegisterForDrag("LeftButton")
    lootLogFrame:SetScript("OnDragStart", function() this:StartMoving() end)
    lootLogFrame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        SaveLootLogGeometry()
    end)
    lootLogFrame:SetScript("OnHide", SaveLootLogGeometry)
    ApplyThemeBackdrop(lootLogFrame, 0.90, true)

    local header = lootLogFrame:CreateTexture(nil, "BACKGROUND")
    header:SetTexture("Interface\\Buttons\\WHITE8X8")
    header:SetPoint("TOPLEFT", lootLogFrame, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", lootLogFrame, "TOPRIGHT", -1, -1)
    header:SetHeight(30)
    if IsPfUIThemeActive() then
        local r, g, b = GetThemeBackgroundColor()
        header:SetVertexColor(r, g, b, 0.75)
    else
        header:SetVertexColor(0.090, 0.153, 0.243, 0.55)
    end

    local accent = lootLogFrame:CreateTexture(nil, "BORDER")
    accent:SetTexture("Interface\\Buttons\\WHITE8X8")
    accent:SetPoint("TOPLEFT", lootLogFrame, "TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", lootLogFrame, "TOPRIGHT", -1, -1)
    accent:SetHeight(2)
    local accentR, accentG, accentB = GetThemeAccentColor()
    accent:SetVertexColor(accentR, accentG, accentB, 0.85)

    local title = lootLogFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", lootLogFrame, "TOP", 0, -12)
    ApplyLootFont(title, 12)
    title:SetTextColor(0.902, 0.929, 0.953, 1)
    title:SetText("AutoAreaLoot Log")

    local close = CreateAALButton(lootLogFrame, 18, 18, "X")
    close:SetPoint("TOPRIGHT", lootLogFrame, "TOPRIGHT", -6, -6)
    ApplyLootFont(close.label, 9)
    StyleCloseButton(close)
    close:SetScript("OnClick", function() this:GetParent():Hide() end)

    lootLogSummary = lootLogFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    lootLogSummary:SetPoint("TOPLEFT", lootLogFrame, "TOPLEFT", 16, -34)
    ApplyLootFont(lootLogSummary, 9)
    lootLogSummary:SetTextColor(0.545, 0.580, 0.620, 1)

    lootLogMoneySummary = lootLogFrame:CreateFontString(
        nil, "ARTWORK", "GameFontHighlightSmall")
    lootLogMoneySummary:SetPoint("TOPRIGHT", lootLogFrame, "TOPRIGHT", -16, -34)
    lootLogMoneySummary:SetJustifyH("RIGHT")
    ApplyLootFont(lootLogMoneySummary, 9)
    lootLogMoneySummary:SetTextColor(0.545, 0.580, 0.620, 1)

    local scrollFrame = CreateFrame("ScrollFrame", "AutoAreaLootLogScrollFrame", lootLogFrame)
    scrollFrame:SetPoint("TOPLEFT", lootLogFrame, "TOPLEFT", 12, -48)
    scrollFrame:SetPoint("BOTTOMRIGHT", lootLogFrame, "BOTTOMRIGHT", -24, 32)
    lootLogFrame.scrollFrame = scrollFrame

    lootLogContent = CreateFrame("Frame", "AutoAreaLootLogContent", scrollFrame)
    lootLogContent:SetWidth(math.max(1, lootLogFrame:GetWidth() - 58))
    lootLogContent:SetHeight(1)
    lootLogContent.rows = {}
    scrollFrame:SetScrollChild(lootLogContent)
    lootLogFrame.scrollbar = CreateAALScrollbar(lootLogFrame, scrollFrame, lootLogContent)
    scrollFrame.aalOnScrollChanged = RefreshVisibleLootRows

    local resizeGrip = CreateFrame("Button", nil, lootLogFrame)
    resizeGrip:SetWidth(16)
    resizeGrip:SetHeight(16)
    resizeGrip:SetPoint("BOTTOMRIGHT", lootLogFrame, "BOTTOMRIGHT", -2, 2)
    resizeGrip:SetFrameLevel(lootLogFrame:GetFrameLevel() + 5)
    resizeGrip:SetNormalTexture(
        "Interface\\AddOns\\AutoAreaLoot\\Icons\\SizeGrabber-Up.tga")
    resizeGrip:SetHighlightTexture(
        "Interface\\AddOns\\AutoAreaLoot\\Icons\\SizeGrabber-Highlight.tga")
    resizeGrip:SetPushedTexture(
        "Interface\\AddOns\\AutoAreaLoot\\Icons\\SizeGrabber-Down.tga")
    resizeGrip:SetScript("OnMouseDown", function()
        if arg1 == "LeftButton" then
            lootLogFrame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        lootLogFrame:StopMovingOrSizing()
        lootLogContent:SetWidth(math.max(1, lootLogFrame:GetWidth() - 58))
        RefreshLootLog()
        SaveLootLogGeometry()
    end)
    resizeGrip:SetScript("OnHide", function()
        lootLogFrame:StopMovingOrSizing()
    end)

    lootLogFrame:SetScript("OnSizeChanged", function()
        if not lootLogContent then return end
        lootLogContent:SetWidth(math.max(1, this:GetWidth() - 58))
        RefreshLootLog()
    end)

    local clear = CreateAALButton(lootLogFrame, 48, 18, "Clear")
    clear:SetPoint("BOTTOMLEFT", lootLogFrame, "BOTTOMLEFT", 12, 7)
    clear:SetScript("OnClick", function()
        state.lootEvents = {}
        state.lootEventCount = 0
        state.lootRecords = {}
        state.lootRecordByKey = {}
        state.lootMoney = 0
        lootLogFrame.scrollFrame:SetVerticalScroll(0)
        RefreshLootLog()
    end)

    local combine = CreateAALToggle(lootLogFrame, "Combine", AutoAreaLootDB.lootCombine, function(checked)
        AutoAreaLootDB.lootCombine = checked
        lootLogFrame.scrollFrame:SetVerticalScroll(0)
        RefreshLootLog()
    end)
    combine:SetPoint("BOTTOMLEFT", lootLogFrame, "BOTTOMLEFT", 70, 9)

    RefreshLootLog()
    lootLogFrame:Hide()
end

local function ShowLootLog()
    CreateLootLog()
    if lootLogFrame:IsShown() then
        lootLogFrame:Hide()
    else
        lootLogFrame:Show()
        RefreshLootLog()
    end
end

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
        AutoAreaLootDB.lootFontSize = nil
        AutoAreaLootDB.settingsVersion = defaults.settingsVersion
    end

    for key, value in pairs(defaults) do
        if type(AutoAreaLootDB[key]) ~= type(value) then
            AutoAreaLootDB[key] = value
        end
    end
    if not validAnchorPoints[AutoAreaLootDB.lootLogPoint] then
        AutoAreaLootDB.lootLogPoint = defaults.lootLogPoint
    end
    if not validAnchorPoints[AutoAreaLootDB.lootLogRelativePoint] then
        AutoAreaLootDB.lootLogRelativePoint = defaults.lootLogRelativePoint
    end
    state.initialized = true
end

local eventFrame
local missingClassicAPIWarningShown = false
local missingNampowerWarningShown = false

local function IsEventAvailable(eventName)
    return C_EventUtils
        and type(C_EventUtils.IsEventValid) == "function"
        and C_EventUtils.IsEventValid(eventName)
end

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

local function IsPlayerChanneling()
    if type(UnitChannelInfo) ~= "function" then return false end
    local ok, channelName = pcall(UnitChannelInfo, "player")
    return ok and channelName ~= nil
end

local function IsPlayerCasting()
    if type(UnitCastingInfo) ~= "function" then return false end
    local ok, castName = pcall(UnitCastingInfo, "player")
    return ok and castName ~= nil
end

local function IsPlayerDeadOrGhost()
    if type(UnitIsDeadOrGhost) ~= "function" then return false end
    local ok, deadOrGhost = pcall(UnitIsDeadOrGhost, "player")
    return ok and deadOrGhost and true or false
end

local function GetPlayerLootRestriction()
    if state.playerControlLost then return "player control is lost" end
    if IsPlayerDeadOrGhost() then return "player is dead or a ghost" end
    if IsPlayerChanneling() then return "player is channeling" end
    if IsPlayerCasting() then return "player is casting" end
    return nil
end

local function GetPlayerSpeedMovementState()
    if type(GetUnitSpeed) ~= "function" then return nil end
    local ok, speed = pcall(GetUnitSpeed, "player")
    speed = tonumber(speed)
    if not ok or not speed then return nil end
    return speed > MOVEMENT_SPEED_EPSILON
end

local function IsPlayerCurrentlyMoving()
    local moving = GetPlayerSpeedMovementState()
    if moving ~= nil then
        return moving
    end
    return state.playerMoving and true or false
end

local function GetUnitWorldPosition(unit)
    if type(UnitPosition) ~= "function" then return nil end
    local ok, first, second, third = pcall(UnitPosition, unit)
    if not ok then return nil end
    local x = tonumber(first)
    local y = tonumber(second)
    local z = tonumber(third) or 0
    if not x or not y then return nil end
    -- ClassicAPI and SuperWoW differ in axis labels, but Euclidean distance
    -- is unchanged when the first two world axes are swapped.
    return x, y, z
end

local function GetPlayerWorldPosition()
    return GetUnitWorldPosition("player")
end

local function GetUnitDistanceFromPlayer(unit)
    if type(UnitDistanceSquared) == "function" then
        local ok, distanceSquared, checked = pcall(UnitDistanceSquared, unit)
        distanceSquared = tonumber(distanceSquared)
        if ok and checked and distanceSquared and distanceSquared >= 0 then
            return math.sqrt(distanceSquared)
        end
    end

    local unitX, unitY, unitZ = GetUnitWorldPosition(unit)
    local playerX, playerY, playerZ = GetPlayerWorldPosition()
    if not unitX or not playerX then return nil end
    local dx = unitX - playerX
    local dy = unitY - playerY
    local dz = unitZ - playerZ
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function ShouldAcceptDeathTrigger(guid)
    if type(guid) ~= "string" then return true, nil end
    local distance = GetUnitDistanceFromPlayer(guid)
    if not distance then return true, nil end
    return distance <= DEATH_TRIGGER_DISTANCE_LIMIT, distance
end

local function GetDistanceFromLastStop(x, y, z)
    if not x or not state.lastStopPositionX then return nil end
    local dx = x - state.lastStopPositionX
    local dy = y - state.lastStopPositionY
    local dz = z - state.lastStopPositionZ
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function IsLootScanInProgress()
    if not C_Loot or type(C_Loot.IsScanInProgress) ~= "function" then
        return false
    end
    local ok, inProgress = pcall(C_Loot.IsScanInProgress)
    return ok and inProgress and true or false
end

local CompleteActiveLootWalk
local ScheduleLootRequest

local function NormalizePendingLootReason(source)
    local reason = source
    if reason ~= "death" and reason ~= "moved" and reason ~= "combat" then
        reason = "retry"
    end
    return reason
end

local function QueuePendingLootRequest(source)
    local reason = NormalizePendingLootReason(source)
    local currentPriority = PENDING_LOOT_PRIORITY[state.pendingLootReason] or 0
    if PENDING_LOOT_PRIORITY[reason] > currentPriority then
        state.pendingLootReason = reason
    end
end

local function GetLootSettleDelay()
    if not state.lootSettleUntil or type(GetTime) ~= "function" then return 0 end
    local remaining = state.lootSettleUntil - GetTime()
    if remaining <= 0 then
        state.lootSettleUntil = nil
        return 0
    end
    return remaining
end

local function GetAdaptiveLootSettleDuration()
    local latency
    if type(GetNetStats) == "function" then
        local ok, bandwidthIn, bandwidthOut, thirdLatency, fourthLatency =
            pcall(GetNetStats)
        if ok then
            -- Vanilla reports latency as the third value. Clients exposing the
            -- newer home/world pair use the fourth value for world latency.
            latency = tonumber(fourthLatency) or tonumber(thirdLatency)
        end
    end

    local duration = POST_SCAN_SETTLE_MIN
    if latency and latency >= 0 then
        duration = POST_SCAN_SETTLE_CUSHION
            + (latency / 1000) * POST_SCAN_LATENCY_MULTIPLIER
    end
    duration = math.max(POST_SCAN_SETTLE_MIN,
        math.min(POST_SCAN_SETTLE_MAX, duration))
    return duration, latency
end

local function LootNearbyCorpses(source)
    source = source or "retry"
    DebugLog("Loot request entered: source=" .. source .. " enabled="
        .. tostring(state.initialized and AutoAreaLootDB.enabled)
        .. " manual=" .. tostring(state.manualLootOpen)
        .. " localWalk=" .. tostring(state.lootWalkActive)
        .. " apiScan=" .. tostring(IsLootScanInProgress())
        .. " combat=" .. tostring(IsPlayerInCombat()))
    if not state.initialized then
        DebugLog("Loot request stopped: addon not initialized")
        return false
    end
    if not AutoAreaLootDB.enabled then
        DebugLog("Loot request stopped: addon disabled")
        return false
    end
    if not HasClassicAPILoot() then
        DebugLog("Loot request stopped: ClassicAPI loot API unavailable")
        return false
    end

    if state.stopGraceTimer then
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: waiting for stable-stop grace; source="
            .. source)
        return false
    end

    if IsPlayerCurrentlyMoving() then
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: player is moving; source=" .. source)
        return false
    end

    local restriction = GetPlayerLootRestriction()
    if restriction then
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: " .. restriction .. "; source=" .. source)
        return false
    end

    if source == "stop" and state.lootRequestTimer then
        DebugLog("Stop request coalesced into pending scheduled request")
        return false
    end

    if IsPlayerInCombat() and not AutoAreaLootDB.lootInCombat then
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: combat looting disabled")
        return false
    end

    if state.manualLootOpen then
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: manual loot window is open")
        return false
    end

    if state.lootWalkActive then
        if IsLootScanInProgress() then
            QueuePendingLootRequest(source)
            DebugLog("Loot request deferred: our ClassicAPI walk is still active; source="
                .. source)
            return false
        end
        -- Recover if a later trigger notices that the completion event was
        -- missed after ClassicAPI already returned to idle.
        DebugLog("Recovering local walk after ClassicAPI returned idle")
        CompleteActiveLootWalk()
        if state.pendingLootReason then
            local pendingReason = state.pendingLootReason
            state.pendingLootReason = nil
            DebugLog("Recovered completion: preserving queued request; source="
                .. pendingReason)
            ScheduleLootRequest(
                pendingReason == "death" and DEATH_LOOT_REQUEST_DELAY or nil,
                pendingReason)
            return false
        end
    end

    if IsLootScanInProgress() then
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: another ClassicAPI scan is active")
        return false
    end

    local settleDelay = GetLootSettleDelay()
    if settleDelay > 0 then
        local sourceReason = NormalizePendingLootReason(source)
        if sourceReason == "retry" then
            if state.pendingLootReason then
                local pendingReason = state.pendingLootReason
                state.pendingLootReason = nil
                DebugLog("Successful scan is settling; scheduling queued request; source="
                    .. pendingReason)
                ScheduleLootRequest(settleDelay, pendingReason)
                return false
            end
            DebugLog("Loot request coalesced: successful scan is still settling; source="
                .. source)
            return false
        end
        QueuePendingLootRequest(source)
        DebugLog("Loot request deferred: waiting "
            .. string.format("%.3f", settleDelay)
            .. " seconds for corpse state to settle")
        ScheduleLootRequest(settleDelay, source)
        return false
    end

    state.pendingLootReason = nil
    local capture = { events = {} }
    state.activeCapture = capture
    state.lootWalkActive = true
    state.lootWalkStartedAt = type(GetTime) == "function" and GetTime() or nil
    DebugLog("Calling C_Loot.LootAllCorpses")
    local callOK, callResult = pcall(C_Loot.LootAllCorpses)
    local started = callOK and callResult and true or false
    DebugLog("LootAllCorpses returned: callOK=" .. tostring(callOK)
        .. " result=" .. tostring(callResult)
        .. " apiScan=" .. tostring(IsLootScanInProgress()))
    if not started then
        if state.activeCapture == capture then
            state.activeCapture = nil
            state.lootWalkActive = false
            state.lootWalkStartedAt = nil
        end
        if IsLootScanInProgress() then
            QueuePendingLootRequest(source)
            DebugLog("Failed call left API scan active; queued one follow-up")
        end
    end
    return started
end

ScheduleLootRequest = function(delay, source)
    source = source or "retry"
    if not state.initialized then
        DebugLog("Schedule skipped: addon not initialized")
        return
    end
    if not AutoAreaLootDB.enabled then
        DebugLog("Schedule skipped: addon disabled")
        return
    end
    if IsPlayerCurrentlyMoving() then
        QueuePendingLootRequest(source)
        DebugLog("Schedule deferred while player is moving; source=" .. source)
        return
    end
    local restriction = GetPlayerLootRestriction()
    if restriction then
        QueuePendingLootRequest(source)
        DebugLog("Schedule deferred while " .. restriction .. "; source=" .. source)
        return
    end
    local settleDelay = GetLootSettleDelay()
    local sourceReason = NormalizePendingLootReason(source)
    if settleDelay > 0 and sourceReason == "retry" then
        DebugLog("Schedule coalesced: successful scan is settling; source="
            .. source)
        return
    end
    if state.lootRequestTimer then
        local timerReason = NormalizePendingLootReason(
            state.lootRequestTimer.source)
        if PENDING_LOOT_PRIORITY[sourceReason]
            > PENDING_LOOT_PRIORITY[timerReason] then
            DebugLog("Scheduled request upgraded: " .. timerReason
                .. " -> " .. sourceReason)
            state.lootRequestTimer = nil
        else
            DebugLog("Schedule coalesced: request timer already pending; source="
                .. state.lootRequestTimer.source)
            return
        end
    end
    if not HasClassicAPILoot() then
        DebugLog("Schedule skipped: ClassicAPI loot API unavailable")
        return
    end
    if not C_Timer or type(C_Timer.After) ~= "function" then
        DebugLog("Schedule skipped: C_Timer.After unavailable")
        return
    end

    local requestedDelay = math.max(0, tonumber(delay) or LOOT_REQUEST_DELAY)
    local effectiveDelay = math.max(requestedDelay, settleDelay)

    -- One timer per burst; invalidated tokens cannot service a later request.
    local token = { source = source }
    state.lootRequestTimer = token
    DebugLog("Loot request scheduled in "
        .. string.format("%.3f", effectiveDelay) .. " seconds; source=" .. source)
    C_Timer.After(effectiveDelay, function()
        if state.lootRequestTimer ~= token then
            DebugLog("Scheduled request discarded: timer token invalidated")
            return
        end
        state.lootRequestTimer = nil
        DebugLog("Scheduled loot request fired; source=" .. token.source)
        LootNearbyCorpses(token.source)
    end)
end

local function ScheduleStableStopLoot(source)
    source = source or "stop"
    if not C_Timer or type(C_Timer.After) ~= "function" then
        DebugLog("Stop grace unavailable; servicing request immediately")
        LootNearbyCorpses(source)
        return
    end

    local startX, startY, startZ = GetPlayerWorldPosition()
    local token = {
        source = source,
        startX = startX,
        startY = startY,
        startZ = startZ,
    }
    state.stopGraceTimer = token
    DebugLog("Waiting " .. string.format("%.3f", STOP_LOOT_GRACE)
        .. " seconds for a stable stop; source=" .. source)
    C_Timer.After(STOP_LOOT_GRACE, function()
        if state.stopGraceTimer ~= token then
            DebugLog("Stable-stop request discarded: token invalidated")
            return
        end
        state.stopGraceTimer = nil
        if IsPlayerCurrentlyMoving() then
            QueuePendingLootRequest(token.source)
            DebugLog("Stable-stop request deferred: movement-start event received")
            return
        end
        local currentX, currentY, currentZ = GetPlayerWorldPosition()
        if token.startX and currentX then
            local dx = currentX - token.startX
            local dy = currentY - token.startY
            local dz = currentZ - token.startZ
            local moved = math.sqrt(dx * dx + dy * dy + dz * dz)
            if moved > STOP_LOOT_GRACE_MOVEMENT_TOLERANCE then
                state.playerMoving = true
                QueuePendingLootRequest(token.source)
                DebugLog("Stable-stop request deferred: moved "
                    .. string.format("%.2f", moved)
                    .. " yards during grace")
                return
            end
        end

        local effectiveSource = token.source
        local pendingReason = state.pendingLootReason
        local effectiveReason = NormalizePendingLootReason(effectiveSource)
        if pendingReason and PENDING_LOOT_PRIORITY[pendingReason]
            > PENDING_LOOT_PRIORITY[effectiveReason] then
            effectiveSource = pendingReason
        end
        DebugLog("Stable stop confirmed; servicing source=" .. effectiveSource)
        LootNearbyCorpses(effectiveSource)
    end)
end

CompleteActiveLootWalk = function()
    if not state.lootWalkActive then
        DebugLog("Completion ignored: no local corpse walk is active")
        return false
    end

    local capture = state.activeCapture
    local completedAt = type(GetTime) == "function" and GetTime() or nil
    local scanDuration
    if completedAt and state.lootWalkStartedAt then
        scanDuration = math.max(0, completedAt - state.lootWalkStartedAt)
    end
    state.lootWalkActive = false
    state.lootWalkStartedAt = nil
    state.activeCapture = nil
    DebugLog("Completing local corpse walk; capture=" .. tostring(capture ~= nil))

    if capture then
        local results = {}
        if type(C_Loot.GetLastScanResults) == "function" then
            local resultsOK, returnedResults = pcall(C_Loot.GetLastScanResults)
            if resultsOK and type(returnedResults) == "table" then
                results = returnedResults
                DebugLog("GetLastScanResults returned "
                    .. table.getn(results) .. " corpse result(s)")
            else
                DebugLog("GetLastScanResults failed or returned no table: "
                    .. tostring(returnedResults))
            end
        else
            DebugLog("GetLastScanResults is unavailable")
        end
        if table.getn(results) > 0 and type(GetTime) == "function" then
            local settleDuration, latency =
                GetAdaptiveLootSettleDuration()
            state.lootSettleUntil = GetTime() + settleDuration
            DebugLog("Non-empty scan: latency=" .. tostring(latency or "unknown")
                .. "ms scanTime=" .. string.format("%.3f", scanDuration or 0)
                .. "s settling=" .. string.format("%.3f", settleDuration)
                .. " seconds")
            if state.pendingLootReason == "retry" then
                state.pendingLootReason = nil
                DebugLog("Discarded redundant stop/combat follow-up after successful scan")
            end
        end
        -- Any logging failure ends here and cannot affect looting.
        local captureOK, captureError = pcall(CompleteLootCapture, capture, results)
        if not captureOK then
            DebugLog("Loot logger completion failed: " .. tostring(captureError))
        end
    end
    return true
end

local function ServicePendingLootRequest()
    if not state.pendingLootReason then
        DebugLog("No queued loot request to service")
        return
    end
    if IsPlayerCurrentlyMoving() then
        DebugLog("Queued loot request retained while player is moving; source="
            .. state.pendingLootReason)
        return
    end
    local restriction = GetPlayerLootRestriction()
    if restriction then
        DebugLog("Queued loot request retained while " .. restriction .. "; source="
            .. state.pendingLootReason)
        return
    end
    if state.stopGraceTimer then
        DebugLog("Queued loot request retained during stable-stop grace; source="
            .. state.pendingLootReason)
        return
    end
    if state.lootWalkActive then
        if IsLootScanInProgress() then
            DebugLog("Queued loot request retained behind active scan; source="
                .. state.pendingLootReason)
            return
        end
        -- Recover if the scan completed but its completion event was missed.
        DebugLog("Recovering queued request after ClassicAPI returned idle")
        CompleteActiveLootWalk()
    end
    if IsLootScanInProgress() then
        DebugLog("Queued loot request retained behind active scan; source="
            .. state.pendingLootReason)
        return
    end

    local source = state.pendingLootReason
    state.pendingLootReason = nil
    DebugLog("Servicing queued loot request; source=" .. source)
    ScheduleLootRequest(
        source == "death" and DEATH_LOOT_REQUEST_DELAY or nil, source)
end

local function RecoverTimedOutLootWalk()
    if not state.lootWalkActive or not state.lootWalkStartedAt
        or type(GetTime) ~= "function" then
        return
    end

    local elapsed = GetTime() - state.lootWalkStartedAt
    if elapsed < LOOT_SCAN_TIMEOUT then return end

    if IsLootScanInProgress() then
        DebugLog("Loot walk exceeded timeout but ClassicAPI still reports it active")
        return
    end

    DebugLog("Recovering loot walk after "
        .. string.format("%.3f", elapsed)
        .. " seconds without a completion event")
    CompleteActiveLootWalk()
    ServicePendingLootRequest()
end

local function SetEnabled(enabled)
    AutoAreaLootDB.enabled = enabled and true or false
    DebugLog("Addon enabled set to " .. tostring(AutoAreaLootDB.enabled))
    if not AutoAreaLootDB.enabled then
        state.lootRequestTimer = nil
        state.lootSettleUntil = nil
        state.pendingLootReason = nil
        state.lootAfterCombat = false
        state.lootWalkActive = false
        state.lootWalkStartedAt = nil
        state.activeCapture = nil
        state.stopGraceTimer = nil
        state.lastStopLootRequestAt = nil
        state.lastStopPositionX = nil
        state.lastStopPositionY = nil
        state.lastStopPositionZ = nil
    end
end

local function CreateCheckButton(parent, label, y, setting)
    local check = CreateAALToggle(parent, label, AutoAreaLootDB[setting], function(checked)
        AutoAreaLootDB[setting] = checked
        if setting == "enabled" then
            SetEnabled(AutoAreaLootDB.enabled)
        end
    end)
    check:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    return check
end

local function RefreshConfigPanel()
    if not configFrame or not state.initialized then return end
    configFrame.enabledCheck:SetChecked(AutoAreaLootDB.enabled)
    configFrame.deathCheck:SetChecked(AutoAreaLootDB.lootOnDeath)
    configFrame.stopCheck:SetChecked(AutoAreaLootDB.lootOnStop)
    configFrame.combatCheck:SetChecked(AutoAreaLootDB.lootInCombat)
    configFrame.openLogCheck:SetChecked(AutoAreaLootDB.openLootLogOnLogin)
end

local function CreateConfigPanel()
    if configFrame then return end

    configFrame = CreateFrame("Frame", "AutoAreaLootConfigFrame", UIParent)
    configFrame:SetWidth(260)
    configFrame:SetHeight(186)
    configFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    configFrame:SetFrameStrata("DIALOG")
    configFrame:SetToplevel(true)
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", function() this:StartMoving() end)
    configFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    configFrame:SetScript("OnShow", RefreshConfigPanel)
    ApplyThemeBackdrop(configFrame, 0.90, true)

    local header = configFrame:CreateTexture(nil, "BACKGROUND")
    header:SetTexture("Interface\\Buttons\\WHITE8X8")
    header:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -1, -1)
    header:SetHeight(34)
    if IsPfUIThemeActive() then
        local r, g, b = GetThemeBackgroundColor()
        header:SetVertexColor(r, g, b, 0.75)
    else
        header:SetVertexColor(0.090, 0.153, 0.243, 0.55)
    end

    local accent = configFrame:CreateTexture(nil, "BORDER")
    accent:SetTexture("Interface\\Buttons\\WHITE8X8")
    accent:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -1, -1)
    accent:SetHeight(2)
    local accentR, accentG, accentB = GetThemeAccentColor()
    accent:SetVertexColor(accentR, accentG, accentB, 0.85)

    local title = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", configFrame, "TOP", 0, -10)
    ApplyLootFont(title, 13)
    title:SetTextColor(0.902, 0.929, 0.953, 1)
    title:SetText("AutoAreaLoot")

    local close = CreateAALButton(configFrame, 18, 18, "X")
    close:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -6, -6)
    ApplyLootFont(close.label, 9)
    StyleCloseButton(close)
    close:SetScript("OnClick", function() this:GetParent():Hide() end)

    configFrame.enabledCheck = CreateCheckButton(
        configFrame, "Loot enabled", -44, "enabled")
    configFrame.deathCheck = CreateCheckButton(
        configFrame, "Loot on death", -68, "lootOnDeath")
    configFrame.stopCheck = CreateCheckButton(
        configFrame, "Loot on movement stop", -92, "lootOnStop")
    configFrame.combatCheck = CreateCheckButton(
        configFrame, "Allow looting in combat", -116, "lootInCombat")
    configFrame.openLogCheck = CreateCheckButton(
        configFrame, "Open loot log on login/reload", -140, "openLootLogOnLogin")

    local logButton = CreateAALButton(configFrame, 118, 18, "Open Loot Log")
    logButton:SetPoint("BOTTOM", configFrame, "BOTTOM", 0, 7)
    ApplyLootFont(logButton.label, 10)
    logButton:SetScript("OnClick", ShowLootLog)

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

local function HandlePlayerMovementStarted(source)
    state.playerMoving = true
    state.movementStateKnown = true
    if state.stopGraceTimer then
        QueuePendingLootRequest(state.stopGraceTimer.source)
        state.stopGraceTimer = nil
        DebugLog("Movement resumed: cancelled stable-stop grace; source="
            .. source)
    else
        DebugLog("Movement started; source=" .. source)
    end
end

local function HandlePlayerMovementStopped(source)
    state.playerMoving = false
    state.movementStateKnown = true
    if AutoAreaLootDB.lootOnStop then
        DebugLog("Stop trigger accepted; source=" .. source)
        local now = type(GetTime) == "function" and GetTime() or nil
        local x, y, z = GetPlayerWorldPosition()
        local moved = GetDistanceFromLastStop(x, y, z)
        local elapsed = now and state.lastStopLootRequestAt
            and now - state.lastStopLootRequestAt or nil
        local withinSameArea = not moved
            or moved < STOP_LOOT_MOVEMENT_DISTANCE
        local withinCooldown = elapsed
            and elapsed < STOP_LOOT_SAME_AREA_INTERVAL
        local coalesced = withinSameArea and withinCooldown
        if coalesced then
            DebugLog("Stop trigger coalesced: elapsed="
                .. (elapsed and string.format("%.3f", elapsed) or "unknown")
                .. " moved=" .. (moved and string.format("%.2f", moved)
                    or "unknown") .. " yards")
            if state.pendingLootReason then
                ScheduleStableStopLoot(state.pendingLootReason)
            end
            return
        end
        state.lastStopLootRequestAt = now
        if x then
            state.lastStopPositionX = x
            state.lastStopPositionY = y
            state.lastStopPositionZ = z
        end
        if moved then
            DebugLog("Stop trigger position accepted: moved="
                .. string.format("%.2f", moved) .. " yards")
        end
        if IsPlayerInCombat() then
            state.lootAfterCombat = true
            DebugLog("Stop trigger marked a post-combat pass")
        end
        local stopSource = moved
            and moved >= STOP_LOOT_MOVEMENT_DISTANCE and "moved" or "stop"
        ScheduleStableStopLoot(stopSource)
    else
        DebugLog("Stop trigger ignored: setting disabled")
        if state.pendingLootReason then
            ScheduleStableStopLoot(state.pendingLootReason)
        end
    end
end

eventFrame = CreateFrame("Frame")

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("PLAYER_MONEY")
if IsEventAvailable("LOOT_SCAN_COMPLETED") then
    eventFrame:RegisterEvent("LOOT_SCAN_COMPLETED")
end
if IsEventAvailable("UNIT_SPELLCAST_CHANNEL_STOP") then
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
end
if IsEventAvailable("UNIT_SPELLCAST_CHANNEL_INTERRUPTED") then
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_INTERRUPTED")
end
if IsEventAvailable("UNIT_SPELLCAST_CHANNEL_FAILED") then
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_FAILED")
end
if IsEventAvailable("PLAYER_CONTROL_LOST") then
    eventFrame:RegisterEvent("PLAYER_CONTROL_LOST")
end
if IsEventAvailable("PLAYER_CONTROL_GAINED") then
    eventFrame:RegisterEvent("PLAYER_CONTROL_GAINED")
end
if IsEventAvailable("UNIT_DIED") then
    eventFrame:RegisterEvent("UNIT_DIED")
else
    eventFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
    if not missingNampowerWarningShown then
        missingNampowerWarningShown = true
        DEFAULT_CHAT_FRAME:AddMessage(
            "AutoAreaLoot: Nampower is recommended for reliable death detection; using combat-text fallback.")
    end
end

eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" then
        if arg1 == "AutoAreaLoot" then
            InitializeSettings()
            InitializeLootPatterns()
            state.useSpeedMovement = type(GetUnitSpeed) == "function"
            state.moneyBaseline = SafeGetMoney()
            CreateConfigPanel()
            eventFrame:UnregisterEvent("ADDON_LOADED")
            HasClassicAPILoot()
            if AutoAreaLootDB.openLootLogOnLogin then
                ShowLootLog()
            end
        end
        return
    end

    DebugLog("Event received: " .. tostring(event))

    if event == "PLAYER_LEAVING_WORLD" then
        DebugLog("Leaving world: clearing transient loot state")
        state.lootRequestTimer = nil
        state.lootSettleUntil = nil
        state.pendingLootReason = nil
        state.lootAfterCombat = false
        state.manualLootOpen = false
        state.autoLootWindowOpen = false
        state.lootWalkActive = false
        state.lootWalkStartedAt = nil
        state.playerMoving = false
        state.movementStateKnown = false
        state.channelStateKnown = false
        state.playerStateSampleElapsed = 0
        state.playerChanneling = false
        state.playerControlLost = false
        state.stopGraceTimer = nil
        state.lastStopLootRequestAt = nil
        state.lastStopPositionX = nil
        state.lastStopPositionY = nil
        state.lastStopPositionZ = nil
        state.activeCapture = nil
        state.pendingCaptures = {}
        state.moneyBaseline = nil
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        if state.lootAfterCombat or state.pendingLootReason then
            DebugLog("Combat ended: preserving one deferred loot request")
            if state.lootAfterCombat then
                QueuePendingLootRequest("combat")
            end
            state.lootAfterCombat = false
            ServicePendingLootRequest()
        else
            DebugLog("Combat ended: no deferred loot request")
        end
        return
    end

    if event == "PLAYER_CONTROL_LOST" then
        state.playerControlLost = true
        DebugLog("Player control lost; deferring loot")
        return
    end

    if event == "PLAYER_CONTROL_GAINED" then
        state.playerControlLost = false
        DebugLog("Player control gained; servicing deferred loot")
        ServicePendingLootRequest()
        return
    end

    if event == "UNIT_DIED" or event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" then
        if AutoAreaLootDB.lootOnDeath then
            local deathGuid = event == "UNIT_DIED" and arg1 or nil
            local accepted, distance = ShouldAcceptDeathTrigger(deathGuid)
            if not accepted then
                DebugLog("Death trigger ignored: guid="
                    .. ShortCorpseGuid(deathGuid) .. " distance="
                    .. string.format("%.2f", distance)
                    .. " yards exceeds " .. DEATH_TRIGGER_DISTANCE_LIMIT)
                return
            end
            DebugLog("Death trigger accepted: guid="
                .. ShortCorpseGuid(deathGuid) .. " distance="
                .. (distance and string.format("%.2f", distance) or "unknown"))
            if IsPlayerInCombat() then
                state.lootAfterCombat = true
                DebugLog("Death trigger marked a post-combat pass")
            end
            if state.stopGraceTimer or state.lootWalkActive
                or IsLootScanInProgress() then
                QueuePendingLootRequest("death")
                DebugLog("Death trigger queued behind active scan or stop grace")
            else
                ScheduleLootRequest(DEATH_LOOT_REQUEST_DELAY, "death")
            end
        else
            DebugLog("Death trigger ignored: setting disabled")
        end
        return
    end

    if event == "LOOT_OPENED" then
        if state.lootWalkActive then
            state.autoLootWindowOpen = true
            DebugLog("Loot window opened during automatic walk; closing it")
            if type(CloseLoot) == "function" then
                pcall(CloseLoot)
            else
                state.manualLootOpen = true
                DebugLog("CloseLoot is unavailable; treating window as manual")
            end
        else
            state.manualLootOpen = true
            DebugLog("Manual loot window marked open")
        end
        return
    end

    if event == "LOOT_CLOSED" then
        state.manualLootOpen = false
        state.autoLootWindowOpen = false
        DebugLog("Manual loot window marked closed")
        ServicePendingLootRequest()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        state.moneyBaseline = SafeGetMoney()
        state.playerMoving = false
        state.movementStateKnown = false
        state.channelStateKnown = false
        state.playerStateSampleElapsed = 0
        state.playerChanneling = false
        state.playerControlLost = false
        state.stopGraceTimer = nil
        state.lastStopLootRequestAt = nil
        state.lastStopPositionX = nil
        state.lastStopPositionY = nil
        state.lastStopPositionZ = nil
        DebugLog("Entered world: money baseline=" .. tostring(state.moneyBaseline))
        return
    end

    if event == "CHAT_MSG_LOOT" then
        local parseOK, confirmation = pcall(ParseSelfLootMessage, arg1)
        DebugLog("Loot chat parse: ok=" .. tostring(parseOK)
            .. " selfItem=" .. tostring(confirmation ~= nil))
        if parseOK and confirmation then
            local matchOK, matchError = pcall(
                BufferOrMatchCaptureEvent, confirmation)
            if not matchOK then
                DebugLog("Loot confirmation handler failed: "
                    .. tostring(matchError))
            end
        elseif not parseOK then
            DebugLog("Loot chat parser failed: " .. tostring(confirmation))
        end
        return
    end

    if event == "PLAYER_MONEY" then
        local currentMoney = SafeGetMoney()
        DebugLog("Money event: before=" .. tostring(state.moneyBaseline)
            .. " after=" .. tostring(currentMoney))
        if currentMoney ~= nil and state.moneyBaseline ~= nil then
            local gained = currentMoney - state.moneyBaseline
            if gained > 0 then
                DebugLog("Positive money change detected: " .. gained)
                local matchOK, matchError = pcall(BufferOrMatchCaptureEvent,
                    { kind = "money", amount = gained })
                if not matchOK then
                    DebugLog("Money confirmation handler failed: "
                        .. tostring(matchError))
                end
            else
                DebugLog("Money change was not a gain: " .. gained)
            end
        end
        state.moneyBaseline = currentMoney
        return
    end

    if event == "LOOT_SCAN_COMPLETED" then
        DebugLog("ClassicAPI reported LOOT_SCAN_COMPLETED")
        CompleteActiveLootWalk()
        ServicePendingLootRequest()
        return
    end

    if event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_CHANNEL_INTERRUPTED"
        or event == "UNIT_SPELLCAST_CHANNEL_FAILED" then
        if arg1 == "player" then
            DebugLog("Player channel ended; servicing deferred loot")
            ServicePendingLootRequest()
        end
        return
    end

end)

eventFrame:SetScript("OnUpdate", function()
    if not state.initialized then return end

    state.playerStateSampleElapsed = state.playerStateSampleElapsed + arg1
    if state.playerStateSampleElapsed >= PLAYER_STATE_SAMPLE_INTERVAL then
        state.playerStateSampleElapsed = 0
        RecoverTimedOutLootWalk()
        local channeling = IsPlayerChanneling()
        if not state.channelStateKnown then
            state.playerChanneling = channeling
            state.channelStateKnown = true
        elseif channeling ~= state.playerChanneling then
            state.playerChanneling = channeling
            if channeling then
                DebugLog("Player channel started")
            else
                DebugLog("Player channel ended; servicing deferred loot")
                ServicePendingLootRequest()
            end
        end
    end

    if not state.useSpeedMovement then return end
    local moving = GetPlayerSpeedMovementState()
    if moving == nil then return end
    if not state.movementStateKnown then
        state.playerMoving = moving
        state.movementStateKnown = true
        DebugLog("Speed movement baseline: moving=" .. tostring(moving))
        return
    end
    if moving == state.playerMoving then return end
    if moving then
        HandlePlayerMovementStarted("speed")
    else
        HandlePlayerMovementStopped("speed")
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
    elseif command == "log" then
        ShowLootLog()
    elseif command == "debug" or command == "debug on" then
        state.debugEnabled = true
        DebugLog("Debug capture enabled")
        ShowDebugWindow()
        DEFAULT_CHAT_FRAME:AddMessage(
            "AutoAreaLoot: debug capture enabled. Use /aal debug off to stop it.")
    elseif command == "debug off" then
        DebugLog("Debug capture disabled")
        state.debugEnabled = false
        UpdateDebugTitle()
        if debugFrame and debugFrame.pauseButton then
            debugFrame.pauseButton.label:SetText("Resume")
        end
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot: debug capture disabled.")
    elseif command == "debug clear" then
        state.debugLines = {}
        RefreshDebugLog(false)
        DEFAULT_CHAT_FRAME:AddMessage("AutoAreaLoot: debug log cleared.")
    else
        ShowConfigPanel()
    end
end

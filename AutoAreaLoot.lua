local LOOT_REQUEST_DELAY = 0.10
local LOOT_EVENT_HISTORY_LIMIT = 500
local LOOT_CONFIRM_GRACE = 3
local LOOT_ROW_FONT_SIZE = 10
local LOOT_TIMESTAMP_WIDTH = 52
local LOOT_LOG_MIN_WIDTH = 240
local LOOT_LOG_MIN_HEIGHT = 140
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
    pendingLootRequest = false,
    lootAfterCombat = false,
    lootRequestTimer = nil,
    lootEvents = {},
    lootEventCount = 0,
    lootRecords = {},
    lootRecordByKey = {},
    lootWalkActive = false,
    activeCapture = nil,
    pendingCaptures = {},
    moneyBaseline = nil,
    lootMoney = 0,
    lootHighlightSerial = 0,
}

local configFrame
local lootLogFrame
local lootLogContent
local lootLogSummary
local lootLogMoneySummary

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
    if remaining <= 0 then return false end

    local confirmed = math.min(remaining, confirmation.count)
    local key = string.match(confirmation.label, "|H(item:[^|]+)|h")
        or confirmation.itemID
    AddLootItem(confirmation.label, key, confirmed)
    capture.expectedItems[confirmation.itemID] = remaining - confirmed
    return true
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
    return consumed
end

local function ConsumeCaptureEvent(capture, captureEvent)
    if captureEvent.kind == "item" then
        return ConsumeItemConfirmation(capture, captureEvent)
    elseif captureEvent.kind == "money" then
        return ConsumeMoneyConfirmation(capture, captureEvent.amount)
    end
    return false
end

local function MatchPendingEvent(captureEvent)
    PrunePendingCaptures()
    for _, capture in ipairs(state.pendingCaptures) do
        if ConsumeCaptureEvent(capture, captureEvent) then
            if not CaptureHasExpectedLoot(capture) then
                RemovePendingCapture(capture)
            end
            RefreshLootLog()
            return true
        end
    end
    return false
end

local function BufferOrMatchCaptureEvent(captureEvent)
    if state.activeCapture then
        table.insert(state.activeCapture.events, captureEvent)
        return
    end
    MatchPendingEvent(captureEvent)
end

local function CompleteLootCapture(capture, results)
    PrunePendingCaptures()
    capture.expectedItems = {}
    capture.expectedMoney = {}

    for _, corpse in ipairs(results or {}) do
        local coin = math.max(0, tonumber(corpse.coin) or 0)
        if coin > 0 then
            table.insert(capture.expectedMoney, { remaining = coin })
        end
        for _, item in ipairs(corpse.items or {}) do
            local itemID = tonumber(item.itemID)
            if itemID then
                capture.expectedItems[itemID] =
                    (capture.expectedItems[itemID] or 0)
                    + math.max(1, tonumber(item.count) or 1)
            end
        end
    end

    capture.expiresAt = (type(GetTime) == "function" and GetTime() or 0)
        + LOOT_CONFIRM_GRACE
    table.insert(state.pendingCaptures, capture)
    while table.getn(state.pendingCaptures) > 8 do
        table.remove(state.pendingCaptures, 1)
    end
    for _, captureEvent in ipairs(capture.events) do
        if not ConsumeCaptureEvent(capture, captureEvent) then
            -- A confirmation delayed from the preceding walk may arrive
            -- while a new walk is active. Give unmatched events to an older
            -- still-live expectation instead of dropping them.
            MatchPendingEvent(captureEvent)
        end
    end
    capture.events = {}
    RefreshLootLog()

    if not CaptureHasExpectedLoot(capture) then
        RemovePendingCapture(capture)
        return
    end

    local expirationToken = {}
    capture.expirationToken = expirationToken
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(LOOT_CONFIRM_GRACE, function()
            if capture.expirationToken ~= expirationToken then return end
            capture.expirationToken = nil
            RemovePendingCapture(capture)
        end)
    else
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

local function IsLootScanInProgress()
    if not C_Loot or type(C_Loot.IsScanInProgress) ~= "function" then
        return false
    end
    local ok, inProgress = pcall(C_Loot.IsScanInProgress)
    return ok and inProgress and true or false
end

local CompleteActiveLootWalk

local function LootNearbyCorpses()
    if not state.initialized or not AutoAreaLootDB.enabled or not HasClassicAPILoot() then return false end

    if IsPlayerInCombat() and not AutoAreaLootDB.lootInCombat then
        state.pendingLootRequest = true
        return false
    end

    if state.manualLootOpen then
        state.pendingLootRequest = true
        return false
    end

    if state.lootWalkActive then
        if IsLootScanInProgress() then
            state.pendingLootRequest = true
            return false
        end
        -- Recover if a later trigger notices that the completion event was
        -- missed after ClassicAPI already returned to idle.
        CompleteActiveLootWalk()
    end

    if IsLootScanInProgress() then
        state.pendingLootRequest = true
        return false
    end

    state.pendingLootRequest = false
    local capture = { events = {} }
    state.activeCapture = capture
    state.lootWalkActive = true
    local callOK, callResult = pcall(C_Loot.LootAllCorpses)
    local started = callOK and callResult and true or false
    if started then
        state.lootRequestTimer = nil
    else
        if state.activeCapture == capture then
            state.activeCapture = nil
            state.lootWalkActive = false
        end
        if IsLootScanInProgress() then
            state.pendingLootRequest = true
        end
    end
    return started
end

local function ScheduleLootRequest()
    if not state.initialized or not AutoAreaLootDB.enabled then return end
    if state.lootRequestTimer then return end
    if not HasClassicAPILoot() or not C_Timer or type(C_Timer.After) ~= "function" then return end

    -- One timer per burst; invalidated tokens cannot service a later request.
    local token = {}
    state.lootRequestTimer = token
    C_Timer.After(LOOT_REQUEST_DELAY, function()
        if state.lootRequestTimer ~= token then return end
        state.lootRequestTimer = nil
        LootNearbyCorpses()
    end)
end

CompleteActiveLootWalk = function()
    if not state.lootWalkActive then return false end

    local capture = state.activeCapture
    state.lootWalkActive = false
    state.activeCapture = nil

    if capture then
        local results = {}
        if type(C_Loot.GetLastScanResults) == "function" then
            local resultsOK, returnedResults = pcall(C_Loot.GetLastScanResults)
            if resultsOK and type(returnedResults) == "table" then
                results = returnedResults
            end
        end
        -- Any logging failure ends here and cannot affect looting.
        pcall(CompleteLootCapture, capture, results)
    end
    return true
end

local function ServicePendingLootRequest()
    if state.pendingLootRequest then
        state.pendingLootRequest = false
        ScheduleLootRequest()
    end
end

local function SetEnabled(enabled)
    AutoAreaLootDB.enabled = enabled and true or false
    if not AutoAreaLootDB.enabled then
        state.lootRequestTimer = nil
        state.pendingLootRequest = false
        state.lootAfterCombat = false
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

eventFrame = CreateFrame("Frame")

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("PLAYER_MONEY")
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
            InitializeLootPatterns()
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

    if event == "PLAYER_LEAVING_WORLD" then
        state.lootRequestTimer = nil
        state.pendingLootRequest = false
        state.lootAfterCombat = false
        state.manualLootOpen = false
        state.lootWalkActive = false
        state.activeCapture = nil
        state.pendingCaptures = {}
        state.moneyBaseline = nil
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        if state.lootAfterCombat or state.pendingLootRequest then
            state.lootAfterCombat = false
            state.pendingLootRequest = false
            ScheduleLootRequest()
        end
        return
    end

    if event == "PLAYER_STOPPED_MOVING" then
        if AutoAreaLootDB.lootOnStop then
            if IsPlayerInCombat() then
                state.lootAfterCombat = true
            end
            LootNearbyCorpses()
        end
        return
    end

    if event == "UNIT_DIED" or event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" then
        if AutoAreaLootDB.lootOnDeath then
            if IsPlayerInCombat() then
                state.lootAfterCombat = true
            end
            ScheduleLootRequest()
        end
        return
    end

    if event == "LOOT_OPENED" then
        state.manualLootOpen = true
        return
    end

    if event == "LOOT_CLOSED" then
        state.manualLootOpen = false
        ServicePendingLootRequest()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        state.moneyBaseline = SafeGetMoney()
        return
    end

    if event == "CHAT_MSG_LOOT" then
        local parseOK, confirmation = pcall(ParseSelfLootMessage, arg1)
        if parseOK and confirmation then
            pcall(BufferOrMatchCaptureEvent, confirmation)
        end
        return
    end

    if event == "PLAYER_MONEY" then
        local currentMoney = SafeGetMoney()
        if currentMoney ~= nil and state.moneyBaseline ~= nil then
            local gained = currentMoney - state.moneyBaseline
            if gained > 0 then
                pcall(BufferOrMatchCaptureEvent,
                    { kind = "money", amount = gained })
            end
        end
        state.moneyBaseline = currentMoney
        return
    end

    if event == "LOOT_SCAN_COMPLETED" then
        CompleteActiveLootWalk()
        ServicePendingLootRequest()
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
    elseif command == "log" then
        ShowLootLog()
    else
        ShowConfigPanel()
    end
end

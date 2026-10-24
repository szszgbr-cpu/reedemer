-- Sources Hub Redeemer - trigger-based cumulative capture, 2026-09-30.
-- Submits through the existing game UI. A submission is NOT a confirmed reward.
-- No guessed server remotes, debounce edits or downloaded executable code.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer
local start = os.clock()
while not LP and os.clock() - start < 15 do
    task.wait(0.1)
    LP = Players.LocalPlayer
end
assert(LP, "[Sources Hub] No LocalPlayer. Join the game before executing.")
local PlayerGui = LP:WaitForChild("PlayerGui", 15)
assert(PlayerGui, "[Sources Hub] PlayerGui did not load. Execute again after loading.")
local env = _G
if type(getgenv) == "function" then
    local ok, result = pcall(getgenv)
    if ok and type(result) == "table" then env = result end
end
local SESSION_KEY = "SourcesHubRedeemerSessionV2"
local old = env[SESSION_KEY]
if type(old) == "table" and type(old.cleanup) == "function" then pcall(old.cleanup) end
local state = {alive = true, connections = {}, remotes = {}, labels = {}}
env[SESSION_KEY] = state
local screenGui
local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(state.connections, connection)
    return connection
end
function state.cleanup()
    if not state.alive then return end
    state.alive = false
    for _, connection in ipairs(state.connections) do pcall(function() connection:Disconnect() end) end
    state.connections = {}
    if screenGui then pcall(function() screenGui:Destroy() end) end
    if env[SESSION_KEY] == state then env[SESSION_KEY] = nil end
end
local getconns = getconnections or (debug and debug.getconnections)
local setStatus = function(message) print("[Sources Hub] " .. message) end
local function isOurGui(instance)
    local current = instance
    while current do
        if current.Name == "SourcesHubRedeemerGui" then return true end
        current = current.Parent
    end
    return false
end
local function isVisibleChain(instance)
    local current = instance
    while current do
        if current:IsA("GuiObject") and not current.Visible then return false end
        if current:IsA("ScreenGui") then return current.Enabled end
        current = current.Parent
    end
    return false
end
local function hasCodeWord(value)
    value = string.lower(value or "")
    return value:find("code", 1, true) ~= nil or value:find("redeem", 1, true) ~= nil
end
local function codeContext(instance)
    local current = instance
    while current and current ~= PlayerGui do
        if hasCodeWord(current.Name) then return true end
        current = current.Parent
    end
    return false
end
local boundBox, boundButton
local lastUiError
local function belongsToPlayerGui(instance)
    local current = instance
    while current do
        if current == PlayerGui then return true end
        current = current.Parent
    end
    return false
end
local function usableGui(instance)
    return instance and belongsToPlayerGui(instance) and isVisibleChain(instance)
        and instance.AbsoluteSize.X > 0 and instance.AbsoluteSize.Y > 0
end
local function findCodeBox()
    lastUiError = nil
    if usableGui(boundBox) then return boundBox end
    boundBox, boundButton = nil, nil
    local best, bestScore, tied = nil, 0, false
    for _, child in ipairs(PlayerGui:GetDescendants()) do
        if child:IsA("TextBox") and not isOurGui(child) and isVisibleChain(child) then
            local score = 0
            if codeContext(child) then score = score + 10 end
            if hasCodeWord(child.PlaceholderText) then score = score + 20 end
            -- Fingerprint supplied by the actual SAB Codes screenshot.
            local placeholder = child.PlaceholderText:lower():gsub("%s+", " ")
            if placeholder:match("^code here") then score = score + 30 end
            if hasCodeWord(child.Name) then score = score + 10 end
            if child.AbsoluteSize.X <= 0 or child.AbsoluteSize.Y <= 0 then score = 0 end
            if score > bestScore then best, bestScore, tied = child, score, false
            elseif score > 0 and score == bestScore then tied = true end
        end
    end
    if tied then
        lastUiError = "Multiple code fields found. Keep only the SAB Codes panel open."
        return nil
    end
    return best
end
local function connectionList(signal)
    if type(getconns) ~= "function" then return nil end
    local ok, result = pcall(getconns, signal)
    if ok and type(result) == "table" then return result end
    return nil
end
local function dispatchSignal(signal, ...)
    local listeners = connectionList(signal)
    if listeners and #listeners == 0 then return false end
    if type(firesignal) == "function" then
        local ok = pcall(firesignal, signal, ...)
        if ok then return true end
    end
    if listeners then
        local count = 0
        for _, listener in ipairs(listeners) do
            local enabled, fire
            local readable = pcall(function() enabled, fire = listener.Enabled, listener.Fire end)
            if readable and enabled ~= false and type(fire) == "function" then
                local ok = pcall(fire, listener, ...)
                if ok then count = count + 1 end
            end
        end
        return count > 0
    end
    return false
end
local function virtualClick(button)
    if not isVisibleChain(button) or button.AbsoluteSize.X <= 0 or button.AbsoluteSize.Y <= 0 then return false end
    local ok = pcall(function()
        local vim = game:GetService("VirtualInputManager")
        local point = button.AbsolutePosition + button.AbsoluteSize / 2
        local root = button:FindFirstAncestorOfClass("ScreenGui")
        if root and not root.IgnoreGuiInset then
            local inset = game:GetService("GuiService"):GetGuiInset()
            point = point + inset
        end
        vim:SendMouseButtonEvent(point.X, point.Y, 0, true, game, 0)
        vim:SendMouseButtonEvent(point.X, point.Y, 0, false, game, 0)
    end)
    return ok
end
local function clickButton(button)
    -- Pick ONE route. Firing Activated and MouseButton1Click both can redeem twice.
    local activated = connectionList(button.Activated)
    local clicked = connectionList(button.MouseButton1Click)
    if activated and #activated > 0 then
        return dispatchSignal(button.Activated, nil, 1)
    end
    if clicked and #clicked > 0 then return dispatchSignal(button.MouseButton1Click) end
    -- Physical input also handles UI libraries with centralized event listeners.
    if virtualClick(button) then return true end
    if not activated and not clicked then return dispatchSignal(button.MouseButton1Click) end
    return false
end
local function visibleSubmitText(button)
    local texts = {}
    local function add(item)
        if (item:IsA("TextLabel") or item:IsA("TextButton")) and isVisibleChain(item) then
            table.insert(texts, (item.Text:gsub("<[^>]*>", "")):lower())
        end
    end
    add(button)
    for _, item in ipairs(button:GetDescendants()) do add(item) end
    -- Some UI layouts put a transparent click target beside its caption.
    -- Only accept sibling captions whose centre lies inside this button.
    if button.Parent and button.Parent:IsA("GuiObject") then
        for _, item in ipairs(button.Parent:GetChildren()) do
            if item:IsA("TextLabel") then
                local centre = item.AbsolutePosition + item.AbsoluteSize / 2
                local pos, size = button.AbsolutePosition, button.AbsoluteSize
                if centre.X >= pos.X and centre.X <= pos.X + size.X
                    and centre.Y >= pos.Y and centre.Y <= pos.Y + size.Y then add(item) end
            end
        end
    end
    return texts
end
local function submitScore(button)
    local name = button.Name:lower()
    if name:find("close", 1, true) or name == "x" or name:find("cancel", 1, true) then return 0 end
    local texts = visibleSubmitText(button)
    for _, text in ipairs(texts) do
        if text:match("^%s*submit%s*$") then return 40 end
    end
    local text = table.concat(texts, " ")
    for _, word in ipairs({"redeem", "submit", "claim", "confirm"}) do
        if name:find(word, 1, true) or text:find(word, 1, true) then return 20 end
    end
    if name == "enter" or name == "ok" or name == "send" or text:match("^%s*enter%s*$") then return 10 end
    return 0
end
local function findSubmitButton(box)
    lastUiError = nil
    if box == boundBox and usableGui(boundButton) then return boundButton end
    local parent = box.Parent
    while parent and parent ~= PlayerGui do
        local best, score, tied = nil, 0, false
        for _, child in ipairs(parent:GetDescendants()) do
            if child:IsA("GuiButton") and not isOurGui(child) and usableGui(child) then
                local candidate = submitScore(child)
                -- At the screen boundary require an exact Submit caption;
                -- unrelated generic Claim/Send controls must not be selected.
                if parent:IsA("ScreenGui") and candidate < 40 then candidate = 0 end
                if candidate > score then best, score, tied = child, candidate, false
                elseif candidate > 0 and candidate == score then tied = true end
            end
        end
        if tied then
            lastUiError = "Multiple submit buttons found. Cannot safely choose one."
            return nil
        end
        if best then return best end
        -- A CodeInput wrapper is not necessarily the entire Codes panel.
        -- Continue to its ancestors, but never leave this ScreenGui.
        if parent:IsA("ScreenGui") then break end
        parent = parent.Parent
    end
    lastUiError = "CHECK UI: Submit not identified. Field: " .. box:GetFullName()
end
local function openCodesPanel()
    -- Use the game's own open button rather than changing visibility behind its controller.
    for _, child in ipairs(PlayerGui:GetDescendants()) do
        if child:IsA("GuiButton") and not isOurGui(child) and isVisibleChain(child) then
            local text = child:IsA("TextButton") and child.Text or ""
            if (hasCodeWord(child.Name) or hasCodeWord(text)) and submitScore(child) == 0 then
                if clickButton(child) then return true end
            end
        end
    end
    return false
end
local function typeAndSubmitCode(code, requestToken)
    local function cancelled()
        return not state.alive or (requestToken ~= nil and requestToken ~= state.captureGeneration)
    end
    if cancelled() then return false, "Cancelled: a new capture round started." end
    local box = findCodeBox()
    if not box then
        openCodesPanel()
        local deadline = os.clock() + 2
        repeat
            task.wait(0.1)
            box = findCodeBox()
        until box or cancelled() or os.clock() >= deadline
    end
    if cancelled() then return false, "Cancelled: a new capture round started." end
    if not box then return false, lastUiError or "Open the game's Codes panel, then press REDEEM." end
    local focused = pcall(function() box:CaptureFocus() end)
    local written = pcall(function() box.Text = code end)
    if not written or box.Text ~= code then return false, "Cannot write to the game's code field." end
    task.wait(0.05)
    if cancelled() then return false, "Cancelled: a new capture round started." end
    local button = findSubmitButton(box)
    if lastUiError then
        if focused then pcall(function() box:ReleaseFocus(false) end) end
        return false, lastUiError
    end
    if button then
        -- A focus change is not an Enter submission when a submit button exists.
        if focused then pcall(function() box:ReleaseFocus(false) end) end
        if clickButton(button) then return true, "Submit attempted; check the game's result." end
        return false, "Code filled. Click the game's redeem button manually." 
    end
    if focused then
        local ok, wasFocused = pcall(function() return box:IsFocused() end)
        if ok and wasFocused then
            local released = pcall(function() box:ReleaseFocus(true) end)
            if released then return true, "Enter submitted; check the game's result." end
        end
    end
    if dispatchSignal(box.FocusLost, true, nil) then return true, "Enter attempted; check the game's result." end
    return false, "Code filled. Press Enter in the game's code field manually."
end
local function callbackSource(fn)
    if type(fn) ~= "function" then return "" end
    if debug and type(debug.getinfo) == "function" then
        local ok, info = pcall(debug.getinfo, fn)
        if ok and type(info) == "table" then return tostring(info.source or info.short_src or "") end
    end
    if debug and type(debug.info) == "function" then
        local ok, source = pcall(debug.info, fn, "s")
        if ok and type(source) == "string" then return source end
    end
    if type(getscriptfromclosure) == "function" then
        local ok, source = pcall(getscriptfromclosure, fn)
        if ok and typeof(source) == "Instance" then return source:GetFullName() end
    end
    return ""
end
local function isNotificationRemote(remote)
    if not remote:IsA("RemoteEvent") then return false end
    if remote == env.PhiNotifyRemote or remote == _G.PhiNotifyRemote then return true end
    local name = remote.Name:lower()
    if name:find("notification", 1, true) or name:find("announcement", 1, true) or name:find("globalmessage", 1, true) then return true end
    local listeners = connectionList(remote.OnClientEvent)
    if listeners then
        for _, listener in ipairs(listeners) do
            local ok, fn = pcall(function() return listener.Function end)
            if ok then
                local source = callbackSource(fn):lower()
                if source:find("notificationcontroller", 1, true) or source:find("announcementcontroller", 1, true) then return true end
            end
        end
    end
    return false
end

if PlayerGui:FindFirstChild("SourcesHubRedeemerGui") then
    PlayerGui.SourcesHubRedeemerGui:Destroy()
end

screenGui = Instance.new("ScreenGui")
screenGui.Name = "SourcesHubRedeemerGui"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 1000
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = PlayerGui

-- Main Container (Translucent White)
local mainFrame = Instance.new("ImageLabel")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, 340, 0, 306)
mainFrame.Position = UDim2.new(0.5, -170, 0.5, -153)
mainFrame.BackgroundColor3 = Color3.fromRGB(245, 245, 248)
mainFrame.BackgroundTransparency = 0.1
mainFrame.Image = "rbxassetid://93857225029776"
mainFrame.ImageTransparency = 0.85 
mainFrame.ScaleType = Enum.ScaleType.Crop
mainFrame.BorderSizePixel = 0
mainFrame.ClipsDescendants = true
mainFrame.Parent = screenGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 16)
mainCorner.Parent = mainFrame

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(255, 255, 255)
mainStroke.Thickness = 1.5
mainStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
mainStroke.Parent = mainFrame

-- Top Bar Header
local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, 44)
topBar.Position = UDim2.new(0, 0, 0, 0)
topBar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
topBar.BackgroundTransparency = 0.4
topBar.BorderSizePixel = 0
topBar.Parent = mainFrame

local topBarCorner = Instance.new("UICorner")
topBarCorner.CornerRadius = UDim.new(0, 16)
topBarCorner.Parent = topBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.Size = UDim2.new(0, 200, 0, 14)
titleLabel.Position = UDim2.new(0, 12, 0, 8)
titleLabel.BackgroundTransparency = 1
titleLabel.Font = Enum.Font.GothamBold
titleLabel.Text = "SOURCES HUB REDEEMER"
titleLabel.TextColor3 = Color3.fromRGB(80, 10, 15) -- Dark Maroon Title
titleLabel.TextSize = 11
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = topBar

local subLabel = Instance.new("TextLabel")
subLabel.Name = "Subtitle"
subLabel.Size = UDim2.new(0, 200, 0, 12)
subLabel.Position = UDim2.new(0, 12, 0, 25)
subLabel.BackgroundTransparency = 1
subLabel.Font = Enum.Font.Gotham
subLabel.Text = "SAB trigger capture / v7"
subLabel.TextColor3 = Color3.fromRGB(120, 30, 35)
subLabel.TextSize = 10
subLabel.TextXAlignment = Enum.TextXAlignment.Left
subLabel.Parent = topBar

local statusDot = Instance.new("TextButton")
statusDot.Name = "StatusDot"
statusDot.Size = UDim2.new(0, 10, 0, 10)
statusDot.Position = UDim2.new(1, -18, 0, 17)
statusDot.BackgroundColor3 = Color3.fromRGB(220, 40, 50)
statusDot.BorderSizePixel = 0
statusDot.Text = ""
statusDot.AutoButtonColor = false
statusDot.Parent = topBar

local dotCorner = Instance.new("UICorner")
dotCorner.CornerRadius = UDim.new(1, 0)
dotCorner.Parent = statusDot

-- Start Scan Button
local scanButton = Instance.new("TextButton")
scanButton.Name = "ScanButton"
scanButton.Size = UDim2.new(1, -24, 0, 30)
scanButton.Position = UDim2.new(0, 12, 0, 52)
scanButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
scanButton.BackgroundTransparency = 0.35
scanButton.BorderSizePixel = 0
scanButton.Font = Enum.Font.GothamBold
scanButton.Text = "START SCAN"
scanButton.TextColor3 = Color3.fromRGB(90, 12, 18)
scanButton.TextSize = 11
scanButton.AutoButtonColor = false
scanButton.Parent = mainFrame

local scanCorner = Instance.new("UICorner")
scanCorner.CornerRadius = UDim.new(0, 10)
scanCorner.Parent = scanButton

local scanStroke = Instance.new("UIStroke")
scanStroke.Color = Color3.fromRGB(255, 255, 255)
scanStroke.Thickness = 1
scanStroke.Parent = scanButton

-- Mode Selection Button
local modeButton = Instance.new("TextButton")
modeButton.Name = "ModeButton"
modeButton.Size = UDim2.new(1, -24, 0, 30)
modeButton.Position = UDim2.new(0, 12, 0, 88)
modeButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
modeButton.BackgroundTransparency = 0.35
modeButton.BorderSizePixel = 0
modeButton.Font = Enum.Font.GothamBold
modeButton.Text = "RIDDLE ANSWER: OFF (CLICK TO START)"
modeButton.TextColor3 = Color3.fromRGB(80, 85, 95)
modeButton.TextSize = 9
modeButton.AutoButtonColor = false
modeButton.Parent = mainFrame

local modeCorner = Instance.new("UICorner")
modeCorner.CornerRadius = UDim.new(0, 10)
modeCorner.Parent = modeButton

local modeStroke = Instance.new("UIStroke")
modeStroke.Color = Color3.fromRGB(255, 255, 255)
modeStroke.Thickness = 1
modeStroke.Parent = modeButton

-- Preview Code Textbox
local previewBox = Instance.new("TextBox")
previewBox.Name = "PreviewBox"
previewBox.Size = UDim2.new(1, -102, 0, 30)
previewBox.Position = UDim2.new(0, 12, 0, 126)
previewBox.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
previewBox.BackgroundTransparency = 0.35
previewBox.BorderSizePixel = 0
previewBox.PlaceholderText = "Captured code..."
previewBox.PlaceholderColor3 = Color3.fromRGB(130, 135, 145)
previewBox.Text = ""
previewBox.TextColor3 = Color3.fromRGB(40, 45, 55)
previewBox.ClearTextOnFocus = false
previewBox.Font = Enum.Font.GothamBold
previewBox.TextSize = 11
previewBox.TextXAlignment = Enum.TextXAlignment.Left
previewBox.Parent = mainFrame

local boxCorner = Instance.new("UICorner")
boxCorner.CornerRadius = UDim.new(0, 10)
boxCorner.Parent = previewBox

local boxStroke = Instance.new("UIStroke")
boxStroke.Color = Color3.fromRGB(255, 255, 255)
boxStroke.Thickness = 1
boxStroke.Parent = previewBox

local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0, 8)
pad.PaddingRight = UDim.new(0, 8)
pad.Parent = previewBox

-- Redeem Pill Button
local redeemButton = Instance.new("TextButton")
redeemButton.Name = "RedeemButton"
redeemButton.Size = UDim2.new(0, 70, 0, 30)
redeemButton.Position = UDim2.new(1, -82, 0, 126)
redeemButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
redeemButton.BorderSizePixel = 0
redeemButton.Text = "REDEEM"
redeemButton.TextColor3 = Color3.fromRGB(90, 12, 18)
redeemButton.Font = Enum.Font.GothamBold
redeemButton.TextSize = 10
redeemButton.AutoButtonColor = true
redeemButton.Parent = mainFrame

local redeemCorner = Instance.new("UICorner")
redeemCorner.CornerRadius = UDim.new(0, 10)
redeemCorner.Parent = redeemButton

local redeemStroke = Instance.new("UIStroke")
redeemStroke.Color = Color3.fromRGB(255, 255, 255)
redeemStroke.Thickness = 1
redeemStroke.Parent = redeemButton

-- Bottom Controls Row
local bottomRow = Instance.new("Frame")
bottomRow.Name = "BottomRow"
bottomRow.Size = UDim2.new(1, -24, 0, 30)
bottomRow.Position = UDim2.new(0, 12, 0, 162)
bottomRow.BackgroundTransparency = 1
bottomRow.Parent = mainFrame

local delayLabel = Instance.new("TextLabel")
delayLabel.Name = "DelayLabel"
delayLabel.Size = UDim2.new(0, 48, 1, 0)
delayLabel.Position = UDim2.new(0, 10, 0, 0)
delayLabel.BackgroundTransparency = 1
delayLabel.Font = Enum.Font.GothamBold
delayLabel.Text = "Delay:"
delayLabel.TextColor3 = Color3.fromRGB(90, 95, 105)
delayLabel.TextSize = 11
delayLabel.TextXAlignment = Enum.TextXAlignment.Left
delayLabel.Parent = bottomRow

local delayBox = Instance.new("TextBox")
delayBox.Name = "DelayBox"
delayBox.Size = UDim2.new(0, 48, 1, 0)
delayBox.Position = UDim2.new(0, 62, 0, 0)
delayBox.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
delayBox.BackgroundTransparency = 0.35
delayBox.BorderSizePixel = 0
delayBox.Text = "0.5"
delayBox.TextColor3 = Color3.fromRGB(40, 45, 55)
delayBox.Font = Enum.Font.GothamBold
delayBox.TextSize = 12
delayBox.TextXAlignment = Enum.TextXAlignment.Center
delayBox.ClearTextOnFocus = false
delayBox.Parent = bottomRow

local delayCorner = Instance.new("UICorner")
delayCorner.CornerRadius = UDim.new(0, 10)
delayCorner.Parent = delayBox

local delayStroke = Instance.new("UIStroke")
delayStroke.Color = Color3.fromRGB(255, 255, 255)
delayStroke.Thickness = 1
delayStroke.Parent = delayBox

local setButton = Instance.new("TextButton")
setButton.Name = "SetButton"
setButton.Size = UDim2.new(0, 70, 1, 0)
setButton.Position = UDim2.new(1, -70, 0, 0)
setButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
setButton.BorderSizePixel = 0
setButton.Text = "SET"
setButton.TextColor3 = Color3.fromRGB(90, 12, 18)
setButton.Font = Enum.Font.GothamBold
setButton.TextSize = 10
setButton.AutoButtonColor = true
setButton.Parent = bottomRow

local setCorner = Instance.new("UICorner")
setCorner.CornerRadius = UDim.new(0, 10)
setCorner.Parent = setButton

local setStroke = Instance.new("UIStroke")
setStroke.Color = Color3.fromRGB(255, 255, 255)
setStroke.Thickness = 1
setStroke.Parent = setButton

-- Hover Animations
local function applyHoverEffect(button)
    local defaultColor = button.BackgroundColor3
    local hoverColor = Color3.fromRGB(255, 255, 255)
    button.MouseEnter:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.2), {BackgroundColor3 = hoverColor, BackgroundTransparency = 0.1}):Play()
    end)
    button.MouseLeave:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.2), {BackgroundColor3 = defaultColor, BackgroundTransparency = 0.35}):Play()
    end)
end
applyHoverEffect(scanButton)
applyHoverEffect(modeButton)

local function whiteHover(btn)
    btn.MouseEnter:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(240, 240, 245)}):Play()
    end)
    btn.MouseLeave:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(255, 255, 255)}):Play()
    end)
end
whiteHover(setButton)
whiteHover(redeemButton)



-- Mobile & PC Smooth Dragging Mechanics
local dragging, dragInput, dragStart, startPos
local function update(input)
    local delta = input.Position - dragStart
    mainFrame.Position = UDim2.new(
        startPos.X.Scale,
        startPos.X.Offset + delta.X,
        startPos.Y.Scale,
        startPos.Y.Offset + delta.Y
    )
end

mainFrame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = mainFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

mainFrame.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)



local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.Position = UDim2.new(0, 12, 0, 242)
statusLabel.Size = UDim2.new(1, -24, 0, 48)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 11
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Top
statusLabel.Parent = mainFrame
setStatus = function(message, isError)
    if not state.alive then return end
    statusLabel.Text = message
    statusLabel.TextColor3 = isError and Color3.fromRGB(170, 30, 40) or Color3.fromRGB(50, 65, 80)
    if isError then warn("[Sources Hub] " .. message) else print("[Sources Hub] " .. message) end
end

local checkButton = Instance.new("TextButton")
checkButton.Name = "CheckUI"
checkButton.Position = UDim2.new(0, 12, 0, 200)
checkButton.Size = UDim2.new(1, -24, 0, 30)
checkButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
checkButton.BorderSizePixel = 0
checkButton.Font = Enum.Font.GothamBold
checkButton.Text = "CHECK UI (NO SUBMISSION)"
checkButton.TextSize = 11
checkButton.TextColor3 = Color3.fromRGB(90, 12, 18)
checkButton.Parent = mainFrame
local checkCorner = Instance.new("UICorner")
checkCorner.CornerRadius = UDim.new(0, 10)
checkCorner.Parent = checkButton
local function checkUi()
    boundBox, boundButton = nil, nil
    local box = findCodeBox()
    if not box then
        setStatus(lastUiError or "CHECK UI: open SAB's Codes panel first.", true)
        return false
    end
    local button = findSubmitButton(box)
    if not button then
        setStatus(lastUiError or "CHECK UI: code field found, but no unique submit button.", true)
        print("[Sources Hub] Code field: " .. box:GetFullName())
        return false
    end
    boundBox, boundButton = box, button
    local activated = connectionList(button.Activated)
    local clicked = connectionList(button.MouseButton1Click)
    local route = "virtual click (not tested)"
    if activated and #activated > 0 then route = "Activated callback"
    elseif clicked and #clicked > 0 then route = "MouseButton1Click callback" end
    -- Diagnostics only: no focus, text change, signal firing or remote sending.
    print("[Sources Hub] CHECK UI - field: " .. box:GetFullName())
    print("[Sources Hub] CHECK UI - button: " .. button:GetFullName() .. "; route: " .. route)
    local remoteCount, labelCount = 0, 0
    for _ in pairs(state.remotes) do remoteCount = remoteCount + 1 end
    for _ in pairs(state.labels) do labelCount = labelCount + 1 end
    print("[Sources Hub] CHECK UI - announcement candidates: " .. remoteCount .. " remotes / " .. labelCount .. " labels")
    setStatus("CHECK UI: field + Submit found. Route: " .. route .. ". This is not a server acceptance test.")
    return true
end
connect(checkButton.MouseButton1Click, checkUi)

local scanning, busy, processing = false, false, false
local manualWatching, manualCount = false, 0
local submittedAnswers = {}
local generation = 0
state.captureGeneration = generation
local MAX_PARTS = 3
local collecting = false
local fragments, submissionQueue = {}, {}
local delay, nextSubmitAt = 0.5, 0
local lastCode = ""
local recent = {}
local function updatePreview()
    previewBox.Text = lastCode
end
local function updateDelay()
    local value = tonumber(delayBox.Text)
    if value and value == value and value >= 0.05 and value <= 60 then
        delay = value
        setStatus("Delay: " .. delay .. " seconds")
    else
        delayBox.Text = tostring(delay)
        setStatus("Delay must be between 0.05 and 60 seconds.", true)
    end
end
connect(delayBox.FocusLost, function() updateDelay() end)
connect(setButton.MouseButton1Click, updateDelay)
local function advanceGeneration()
    generation = generation + 1
    state.captureGeneration = generation
end
local function pauseScan(message)
    scanning, collecting, manualWatching = false, false, false
    modeButton.Text = "RIDDLE ANSWER: OFF (CLICK TO START)"
    advanceGeneration()
    submissionQueue = {}
    scanButton.Text = "START SCAN"
    statusDot.BackgroundColor3 = Color3.fromRGB(220, 40, 50)
    scanButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    setStatus(message, true)
end
local function processBuffer()
    if processing or not scanning or not state.alive then return end
    processing = true
    local token = generation
    local ok, err = pcall(function()
        while state.alive and scanning and token == generation and #submissionQueue > 0 do
            if busy or os.clock() < nextSubmitAt then
                task.wait(0.05)
            else
                -- Snapshot each cumulative value when its fragment arrives.
                -- Rapid arrivals still submit A, then AB, then ABC in that order.
                local item = table.remove(submissionQueue, 1)
                if item.generation == token then
                    busy = true
                    local callOk, submitted, message = pcall(typeAndSubmitCode, item.code, token)
                    if not callOk then message, submitted = tostring(submitted), false end
                    busy = false
                    if not state.alive or token ~= generation then break end
                    if not submitted then
                        -- Keep the MOST COMPLETE captured value for manual retry.
                        updatePreview()
                        if manualWatching then
                            setStatus("RIDDLE ANSWER: submit failed; still watching. " .. message, true)
                        else
                            pauseScan(message)
                            break
                        end
                    end
                    nextSubmitAt = os.clock() + delay
                    if submitted then
                        local tail = manualWatching and "manual watch continues"
                            or (collecting and "waiting for next part" or "waiting for USE CODE / CODE IS")
                        setStatus("Message " .. item.part .. ": submit attempted; " .. tail .. ".")
                    end
                end
            end
        end
    end)
    busy = false
    processing = false
    if not ok then
        pauseScan("Submit error: " .. tostring(err))
    elseif state.alive and scanning and #submissionQueue > 0 then
        task.defer(processBuffer)
    end
end
local function cleanMessage(value)
    if type(value) ~= "string" then return nil end
    return value:gsub("<[^>]*>", ""):match("^%s*(.-)%s*$")
end
local function isTrigger(value)
    local message = cleanMessage(value)
    if not message then return false end
    message = message:lower()
    return message:find("%f[%a]use%s+code%f[%A]") ~= nil
        or message:find("%f[%a]code%s+is%f[%A]") ~= nil
end
local function normalizeMessage(value)
    local message = cleanMessage(value)
    if not message then return nil end
    message = message:match("^[Cc][Oo][Dd][Ee]%s*:%s*([%w_%-]+)$") or message
    if #message < 1 or #message > 96 or not message:match("^[A-Za-z0-9_%-]+$") then return nil end
    return message
end
local function onAnnouncement(value, source, explicitAnswer)
    if not scanning or not state.alive then return end
    -- UI text and ordinary message strings are never answers in riddle mode.
    if manualWatching and not explicitAnswer then return end
    local trigger = not manualWatching and isTrigger(value)
    local message
    if manualWatching then message = cleanMessage(value)
    else message = trigger and cleanMessage(value):lower():gsub("%s+", " ") or normalizeMessage(value) end
    if not message or message == "" or (not manualWatching and not trigger and not collecting) then return end
    local now = os.clock()
    local previous = recent[message]
    -- A UI mirror must not restart a round or add the same fragment twice.
    -- Repeated equal fragments on the SAME source are valid independent arrivals.
    if previous and previous.source ~= source and now - previous.time < 0.75 then return end
    recent[message] = {source = source, time = now}
    for key, entry in pairs(recent) do
        if now - entry.time > 2 then recent[key] = nil end
    end
    if manualWatching then
        if submittedAnswers[message] then return end
        submittedAnswers[message] = true
        manualCount = manualCount + 1
        lastCode = message
        updatePreview()
        table.insert(submissionQueue, {code = message, part = manualCount, generation = generation})
        setStatus("RIDDLE ANSWER: received explicit answer " .. manualCount .. ". Queued for submission.")
        task.defer(processBuffer)
        return
    end
    if trigger then
        advanceGeneration()
        collecting = true
        fragments, submissionQueue = {}, {}
        -- Ignore UI text that was already present before this trigger.
        for _, labelState in pairs(state.labels) do labelState.pending = false end
        lastCode = ""
        updatePreview()
        scanButton.Text = "COLLECTING: 0 / 3"
        setStatus("Trigger seen. Waiting for NEW announcements (max 3 parts).")
        print("[Sources Hub] New round: " .. message)
        -- Neither text before the phrase nor text following it in THIS same
        -- announcement is captured. Only subsequently received messages count.
        return
    end
    table.insert(fragments, message)
    local part = #fragments
    lastCode = table.concat(fragments, "")
    updatePreview()
    table.insert(submissionQueue, {code = lastCode, part = part, generation = generation})
    print("[Sources Hub] Part " .. part .. " (" .. source .. "): " .. message .. " -> " .. lastCode)
    if part >= MAX_PARTS then
        collecting = false
        scanButton.Text = "WAITING FOR TRIGGER"
    else
        scanButton.Text = "COLLECTING: " .. part .. " / 3"
    end
    setStatus("Captured part " .. part .. ": " .. lastCode)
    task.defer(processBuffer)
end

local function payloadText(value, depth)
    if type(value) == "string" then return value end
    if type(value) ~= "table" or depth > 3 then return nil end
    for _, key in ipairs({"Text", "text", "Message", "message", "Content", "content", "Announcement", "announcement"}) do
        local result = payloadText(value[key], depth + 1)
        if result then return result end
    end
    return payloadText(value[1], depth + 1)
end
-- Only inspect explicit answer fields in received notification payloads.
-- Never interpret question/message text, positional strings, or statusCode as answers.
local answerKeys = {answer = true, solution = true, code = true,
    riddleanswer = true, riddle_answer = true, redeemcode = true, redeem_code = true}
local function extractExplicitAnswer(...)
    local seen, answers, paths = {}, {}, {}
    local nodes, fields, exhausted = 0, 0, false
    local function visit(value, path, depth)
        if type(value) ~= "table" or seen[value] then return end
        if depth > 6 or nodes >= 128 then exhausted = true; return end
        seen[value] = true
        nodes = nodes + 1
        for key, child in pairs(value) do
            fields = fields + 1
            if fields > 512 then exhausted = true; return end
            local keyText = type(key) == "string" and key or tostring(key)
            local childPath = path .. "." .. keyText
            if type(key) == "string" and answerKeys[key:lower()] then
                if type(child) == "string" then
                    local candidate = cleanMessage(child)
                    if candidate and #candidate > 0 and #candidate <= 96
                        and candidate:match("^[A-Za-z0-9_%-]+$") then
                        answers[candidate] = true
                        paths[candidate] = childPath
                    end
                end
            end
            if type(child) == "table" then visit(child, childPath, depth + 1) end
        end
    end
    for i = 1, select("#", ...) do visit(select(i, ...), "arg" .. i, 0) end
    if exhausted then return nil, "payload exceeds inspection limit" end
    local answer, count = nil, 0
    for candidate in pairs(answers) do answer, count = candidate, count + 1 end
    if count > 1 then return nil, "multiple different answer fields; not submitted" end
    if answer then return answer, paths[answer] end
    return nil, "no explicit answer/code field in received notification"
end
local function watchRemote(remote)
    if not state.alive then return end
    if state.remotes[remote] or not isNotificationRemote(remote) then return end
    state.remotes[remote] = true
    connect(remote.OnClientEvent, function(...)
        if scanning and manualWatching then
            local answer, detail = extractExplicitAnswer(...)
            if answer then
                if submittedAnswers[answer] then return end
                print("[Sources Hub] Explicit answer field: " .. detail .. " on " .. remote:GetFullName())
                onAnnouncement(answer, "remote:" .. remote:GetFullName(), true)
            else
                setStatus("RIDDLE ANSWER: " .. detail .. ". Still watching.")
            end
            return
        end
        for i = 1, select("#", ...) do
            local message = payloadText(select(i, ...), 0)
            if message and (isTrigger(message) or normalizeMessage(message)) then
                onAnnouncement(message, "remote:" .. remote:GetFullName())
                return
            end
        end
    end)
    print("[Sources Hub] Listening: " .. remote:GetFullName())
end
local function announcementContext(instance)
    local current = instance
    while current and current ~= PlayerGui do
        local name = current.Name:lower()
        if name:find("notification", 1, true) or name:find("announcement", 1, true)
            or name:find("globalmessage", 1, true) or name:find("globalannouncement", 1, true) then return true end
        current = current.Parent
    end
    return false
end
local function watchLabel(label, fresh)
    if not state.alive then return end
    if not label:IsA("TextLabel") or isOurGui(label) or state.labels[label] then return end
    if not announcementContext(label) then return end
    local labelState = {pending = fresh == true}
    state.labels[label] = labelState
    local lastText, lastTime = nil, -math.huge
    local function capture()
        if labelState.pending and isVisibleChain(label) then
            labelState.pending = false
            -- Text, Visible and parent visibility may all change for ONE label.
            -- Count that as one fragment rather than three separate messages.
            local now = os.clock()
            if label.Text == lastText and now - lastTime < 0.75 then return end
            lastText, lastTime = label.Text, now
            onAnnouncement(label.Text, "gui:" .. label:GetFullName())
        end
    end
    connect(label:GetPropertyChangedSignal("Text"), function()
        labelState.pending = true
        capture()
    end)
    connect(label:GetPropertyChangedSignal("Visible"), capture)
    -- A reused notification may become visible through its parent frame.
    local parent = label.Parent
    while parent and parent ~= PlayerGui do
        if parent:IsA("GuiObject") then connect(parent:GetPropertyChangedSignal("Visible"), capture)
        elseif parent:IsA("ScreenGui") then connect(parent:GetPropertyChangedSignal("Enabled"), capture) end
        parent = parent.Parent
    end
    if fresh then task.defer(capture) end
end
connect(ReplicatedStorage.DescendantAdded, function(child)
    if child:IsA("RemoteEvent") then task.defer(watchRemote, child) end
end)
connect(PlayerGui.DescendantAdded, function(child)
    if child:IsA("TextLabel") then task.defer(watchLabel, child, true) end
end)
connect(ReplicatedStorage.DescendantRemoving, function(child) state.remotes[child] = nil end)
connect(PlayerGui.DescendantRemoving, function(child) state.labels[child] = nil end)
local function refreshSources()
    for _, child in ipairs(ReplicatedStorage:GetDescendants()) do
        if child:IsA("RemoteEvent") then watchRemote(child) end
    end
    for _, child in ipairs(PlayerGui:GetDescendants()) do watchLabel(child, false) end
end
local function sourceSummary()
    local remoteCount, labelCount = 0, 0
    for _ in pairs(state.remotes) do remoteCount = remoteCount + 1 end
    for _ in pairs(state.labels) do labelCount = labelCount + 1 end
    return remoteCount, labelCount
end
connect(modeButton.MouseButton1Click, function()
    local enable = not manualWatching
    advanceGeneration()
    scanning, manualWatching, collecting = enable, enable, false
    fragments, submissionQueue, recent = {}, {}, {}
    manualCount = 0
    submittedAnswers = {}
    for _, labelState in pairs(state.labels) do labelState.pending = false end
    modeButton.Text = enable and "RIDDLE ANSWER: ON (CLICK TO STOP)" or "RIDDLE ANSWER: OFF (CLICK TO START)"
    scanButton.Text = enable and "STOP WATCH" or "START SCAN"
    statusDot.BackgroundColor3 = enable and Color3.fromRGB(50, 200, 80) or Color3.fromRGB(220, 40, 50)
    if enable then
        lastCode = ""
        updatePreview()
        setStatus("RIDDLE ANSWER: waiting for an explicit answer/solution/code field in notification data. Question text is ignored.")
    else
        setStatus("Manual watch stopped. Pending submissions cancelled.")
    end
end)
connect(scanButton.MouseButton1Click, function()
    manualWatching = false
    modeButton.Text = "RIDDLE ANSWER: OFF (CLICK TO START)"
    for _, labelState in pairs(state.labels) do labelState.pending = false end
    scanning = not scanning
    advanceGeneration()
    collecting = false
    fragments, submissionQueue, recent = {}, {}, {}
    if scanning then
        lastCode = ""
        updatePreview()
        scanButton.Text = "WAITING FOR TRIGGER"
        scanButton.BackgroundColor3 = Color3.fromRGB(120, 220, 140)
        statusDot.BackgroundColor3 = Color3.fromRGB(50, 200, 80)
        local remoteCount, labelCount = sourceSummary()
        setStatus("Waiting for USE CODE / CODE IS. Sources: " .. remoteCount .. " remotes / " .. labelCount .. " UI labels", remoteCount + labelCount == 0)
    else
        scanButton.Text = "START SCAN"
        scanButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        statusDot.BackgroundColor3 = Color3.fromRGB(220, 40, 50)
        setStatus("Stopped. Last code kept for manual redeem.")
    end
end)
local function manualRedeem()
    if busy then setStatus("A submission is already in progress.", true); return end
    local code = previewBox.Text:match("^%s*(.-)%s*$")
    if code == "" then setStatus("Enter a code first.", true); return end
    busy = true
    lastCode = code
    local ok, submitted, message = pcall(typeAndSubmitCode, code)
    nextSubmitAt = os.clock() + delay
    busy = false
    if state.alive then
        if ok then setStatus(message, not submitted)
        else setStatus("Submit error: " .. tostring(submitted), true) end
    end
    if scanning and #submissionQueue > 0 then task.defer(processBuffer) end
end
connect(redeemButton.MouseButton1Click, manualRedeem)
connect(previewBox.FocusLost, function(enter) if enter then manualRedeem() end end)
connect(statusDot.MouseButton1Click, state.cleanup)
connect(screenGui.Destroying, state.cleanup)
connect(UserInputService.InputChanged, function(input)
    if input == dragInput and dragging then update(input) end
end)
task.spawn(function()
    while state.alive do
        local ok, err = pcall(refreshSources)
        if not ok then warn("[Sources Hub] Source discovery: " .. tostring(err)) end
        task.wait(3)
    end
end)
local executorName = "unknown"
if type(identifyexecutor) == "function" then
    local ok, name = pcall(identifyexecutor)
    if ok then executorName = tostring(name) end
end
print("[Sources Hub] Executor: " .. executorName .. "; getconnections=" .. tostring(type(getconns) == "function")
    .. "; firesignal=" .. tostring(type(firesignal) == "function"))
setStatus("Ready. START SCAN: trigger + 3 parts. RIDDLE ANSWER: explicit answer fields only.")

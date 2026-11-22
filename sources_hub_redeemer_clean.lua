-- Sources Hub Redeemer - compact panel and client-side result logging, 2026-11-21.
-- Submits through the existing game UI. A submission is NOT a confirmed reward.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")
local LP = Players.LocalPlayer
local start = os.clock()
while not LP and os.clock() - start < 15 do
    task.wait(0.1)
    LP = Players.LocalPlayer
end
assert(LP, "[Sources Hub] No LocalPlayer. Join the game before executing.")
local PlayerGui = LP:WaitForChild("PlayerGui", 15)
assert(PlayerGui, "[Sources Hub] PlayerGui did not load. Execute again after loading.")

-- Environment setup with optimized getgenv handling
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

-- Clear the cached pairing value from older builds
env.SourcesHubAiPairCode = nil

-- Optimized ping measurement
local function currentPingMs()
    local ok, value = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(value) == "number" then
        return math.floor(value * 10 + 0.5) / 10
    end
    return nil
end

-- Diagnostic storage only. This block never selects or submits a code.
local diagnostics = {}
local logLabel
local logMemory = {}
local logPath

-- Optimized refreshLogLabel function
local function refreshLogLabel()
    if diagnostics.refresh then diagnostics.refresh() end
end

-- Optimized audit function
local function audit(event, fields, at)
    if diagnostics.record then return diagnostics.record(event, fields, at) end
end

do
    local http = game:GetService("HttpService")
    local session = os.date("!%Y%m%dT%H%M%SZ") .. "_" .. http:GenerateGUID(false):sub(1, 8)
    local base = "SourcesHub_" .. session
    local writer, appender, reader = writefile, appendfile, readfile
    local sequence, pending, pendingBytes, memoryBytes = 0, {}, 0, 0
    local part, partBytes, partBuffer, created = 1, 0, "", false
    local saved, dropped, encodingErrors, pendingDropped = 0, 0, 0, 0
    local disk = type(writer) == "function"
    local failure = not disk and "writefile unavailable" or nil
    local files = {}
    local flushing = false
    logPath = base .. "_1.jsonl"
    env.SourcesHubRedeemerLastLog = logMemory
    local info = {version = "v14", session = session, files = files}
    env.SourcesHubRedeemerLogInfo = info

    function diagnostics.refresh()
        info.path, info.file_logging, info.saved = logPath, disk, saved
        info.error, info.dropped, info.encoding_errors = failure, dropped, encodingErrors
        if logLabel and state.alive then
            local prefix = disk and (saved > 0 and "LOG FILE: " or "LOG BUFFERED: ") or "LOG NOT SAVED: "
            local detail = disk and logPath or tostring(failure)
            local gaps = dropped + encodingErrors > 0 and " | GAPS: " .. (dropped + encodingErrors) or ""
            logLabel.Text = prefix .. detail .. gaps .. " | click to copy log"
            logLabel.TextColor3 = disk and Color3.fromRGB(40, 100, 60) or Color3.fromRGB(170, 30, 40)
        end
    end

    function diagnostics.record(event, fields, at)
        local ok, id = pcall(function()
            sequence = sequence + 1
            local now = at or os.clock()
            local record = {schema = 2, utc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                elapsed = now - start, session = session, sequence = sequence,
                event = event, data = fields or {}}
            -- Bound pending memory even when incoming messages outrun disk writes.
            local estimate = event == "remote_received" and 65536 or 8192
            if #pending >= 512 or pendingBytes + estimate > 2097152 then
                dropped, pendingDropped = dropped + 1, pendingDropped + 1
            else
                pending[#pending + 1] = record
                pendingBytes = pendingBytes + estimate
            end
            return sequence
        end)
        if ok then return id end
        encodingErrors = encodingErrors + 1
        return nil
    end

    local function remember(line)
        logMemory[#logMemory + 1] = line
        memoryBytes = memoryBytes + #line
        while #logMemory > 500 or memoryBytes > 1048576 do
            memoryBytes = memoryBytes - #table.remove(logMemory, 1)
        end
    end

    local function saveBatch(lines)
        if #lines == 0 or not disk then return end
        local text = table.concat(lines, "")
        if not created then
            writer(logPath, "")
            files[#files + 1] = logPath
            created = true
        end
        if type(appender) == "function" then appender(logPath, text)
        else
            partBuffer = partBuffer .. text
            writer(logPath, partBuffer)
        end
        partBytes = partBytes + #text
        saved = saved + #lines
    end

    function diagnostics.flush()
        if flushing then return false end
        flushing = true
        local batch = pending
        pending, pendingBytes = {}, 0
        local ok, err = pcall(function()
            if pendingDropped > 0 then
                table.insert(batch, {schema = 2, session = session, event = "diagnostic_gap",
                    elapsed = os.clock() - start, data = {dropped_records = pendingDropped}})
                pendingDropped = 0
            end
            local lines, bytes = {}, 0
            for _, record in ipairs(batch) do
                local encoded, line = pcall(function() return http:JSONEncode(record) .. "\n" end)
                if encoded then
                    remember(line)
                    if disk then
                        if partBytes + bytes + #line > 1048576 then
                            local writeOk, writeErr = pcall(saveBatch, lines)
                            if not writeOk then disk, failure = false, tostring(writeErr) end
                            lines, bytes = {}, 0
                            if disk then
                                part, partBytes, partBuffer, created = part + 1, 0, "", false
                                logPath = base .. "_" .. part .. ".jsonl"
                            end
                        end
                        if disk then lines[#lines + 1], bytes = line, bytes + #line end
                    end
                else
                    encodingErrors = encodingErrors + 1
                    warn("[Sources Hub] Diagnostic encoding failed: " .. tostring(line))
                end
            end
            if disk then
                local writeOk, writeErr = pcall(saveBatch, lines)
                if not writeOk then disk, failure = false, tostring(writeErr) end
            end
        end)
        if not ok then disk, failure = false, tostring(err) end
        flushing = false
        diagnostics.refresh()
        return ok and disk
    end

    -- Snapshot typed parameters before message selection, with explicit cut markers.
    function diagnostics.snapshot(...)
        local seen, nodes, entries, stringBytes = {}, 0, 0, 0
        local cuts = {}
        local function cut(reason)
            cuts[reason] = true
            return {kind = "omitted", reason = reason}
        end
        local function text(value)
            local available = math.max(0, math.min(4096, 32768 - stringBytes))
            local prefix = value:sub(1, available)
            local valid, length = pcall(utf8.len, prefix)
            if not valid or not length then
                -- Preserve binary/partial UTF-8 as hex instead of breaking JSON.
                prefix = prefix:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)
                stringBytes = stringBytes + math.min(#value, available)
                if #value > available then cuts.string_limit = true end
                return {kind = "string", encoding = "hex", value = prefix,
                    original_bytes = #value, truncated = #value > available}
            end
            stringBytes = stringBytes + #prefix
            if #value > #prefix then cuts.string_limit = true end
            return {kind = "string", value = prefix, original_bytes = #value, truncated = #value > #prefix}
        end
        local visit
        visit = function(value, depth)
            local kind = type(value)
            if kind == "nil" then return {kind = "nil"} end
            if kind == "string" then return text(value) end
            if kind == "boolean" then return {kind = kind, value = value} end
            if kind == "number" then
                return {kind = kind, value = value == value and value > -math.huge and value < math.huge
                    and value or tostring(value)}
            end
            if kind ~= "table" then return {kind = typeof(value), value = text(tostring(value))} end
            if seen[value] then return {kind = "reference", id = seen[value]} end
            if depth > 6 then return cut("depth_limit") end
            if nodes >= 128 then return cut("node_limit") end
            nodes = nodes + 1
            seen[value] = nodes
            local result = {kind = "table", id = nodes, entries = {}}
            for key, child in next, value do
                if entries >= 512 then result.omitted = "entry_limit"; cuts.entry_limit = true; break end
                entries = entries + 1
                local keyRecord = type(key) == "string" and text(key)
                    or {kind = type(key), value = tostring(key)}
                result.entries[#result.entries + 1] = {key = keyRecord, value = visit(child, depth + 1)}
            end
            return result
        end
        local result = {argument_count = select("#", ...), arguments = {}, cuts = cuts,
            limits = {depth = 6, nodes = 128, entries = 512, string_bytes = 32768, string_length = 4096}}
        for i = 1, math.min(result.argument_count, 32) do
            result.arguments[i] = visit(select(i, ...), 0)
        end
        if result.argument_count > 32 then cuts.argument_limit = true end
        return result
    end

    function diagnostics.remote(source, active, mode, ...)
        local at = os.clock()
        local ok, snapshot = pcall(diagnostics.snapshot, ...)
        return audit("remote_received", {source = source, scan_active = active, mode = mode,
            payload = ok and snapshot or {snapshot_error = tostring(snapshot)}}, at)
    end
    function diagnostics.gui(label, reason, visible, at)
        local ok, snapshot = pcall(diagnostics.snapshot, label.Text)
        return audit("gui_observed", {source = "gui:" .. label:GetFullName(), reason = reason,
            visible = visible, payload = ok and snapshot or {snapshot_error = tostring(snapshot)}}, at)
    end

    function diagnostics.copy()
        diagnostics.flush()
        if type(setclipboard) ~= "function" then return false, "Clipboard unavailable; log: " .. logPath end
        if disk and type(reader) == "function" then
            local chunks, bytes = {}, 0
            for _, path in ipairs(files) do
                local ok, chunk = pcall(reader, path)
                if not ok then return false, "Cannot read " .. path .. "; keep all session files." end
                bytes = bytes + #chunk
                if bytes > 16777216 then return false, "Log exceeds clipboard limit; keep all " .. base .. "_*.jsonl files." end
                chunks[#chunks + 1] = chunk
            end
            local ok, err = pcall(setclipboard, table.concat(chunks, ""))
            return ok, ok and "Copied saved session log. Keep it for event analysis." or tostring(err)
        end
        local ok, err = pcall(setclipboard, table.concat(logMemory, ""))
        return ok, ok and "Copied RECENT MEMORY ONLY (max 500 entries / 1 MB); saved files may contain more." or tostring(err)
    end

    audit("session_start", {version = "v14", file = logPath, file_logging = disk,
        scope = "Already selected notification remotes and announcement GUI labels only; no history or server storage.",
        capture = "All event arguments before selection, including unknown fields; bounded snapshots with cut markers.",
        note = "Elapsed seconds are monotonic receipt/attempt times; attempts do not confirm server acceptance.",
        file_rotation_bytes = 1048576, flush_seconds = 0.5})
    diagnostics.flush()
    task.spawn(function()
        while state.alive do
            task.wait(0.5)
            diagnostics.flush()
        end
    end)
end

-- Optimized GUI setup and connection management
local screenGui
local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(state.connections, connection)
    return connection
end

function state.cleanup()
    if not state.alive then return end
    audit("session_stop", {})
    diagnostics.flush()
    state.alive = false
    for _, connection in ipairs(state.connections) do pcall(function() connection:Disconnect() end) end
    state.connections = {}
    if screenGui then pcall(function() screenGui:Destroy() end) end
    if env[SESSION_KEY] == state then env[SESSION_KEY] = nil end
end

local getconns = getconnections or (debug and debug.getconnections)
local setStatus = function(message) print("[Sources Hub] " .. message) end

-- Optimized UI element detection functions
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

-- Optimized UI element finding
local boundBox, boundButton, boundFastSignal, boundFastRoute
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

-- Optimized code box detection with caching
local lastCodeBoxCheck = 0
local cachedCodeBox, cachedButton, cachedFastSignal, cachedFastRoute

local function findCodeBox()
    lastUiError = nil
    
    -- Cache check for recent lookups to avoid repeated expensive operations
    if cachedCodeBox and usableGui(cachedCodeBox) then
        return cachedCodeBox
    end
    
    boundBox, boundButton, boundFastSignal, boundFastRoute = nil, nil, nil, nil
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
    
    cachedCodeBox = best
    return best
end

-- Optimized connection list function
local function connectionList(signal)
    if type(getconns) ~= "function" then return nil end
    local ok, result = pcall(getconns, signal)
    if ok and type(result) == "table" then return result end
    return nil
end

-- Optimized signal dispatching
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

-- Optimized virtual click implementation
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

-- Optimized button click handling
local function clickButton(button)
    -- Pick ONE route. Firing Activated and MouseButton1Click both can redeem twice.
    local activated = connectionList(button.Activated)
    local clicked = connectionList(button.MouseButton1Click)
    if activated and #activated > 0 then
        return dispatchSignal(button.Activated, nil, 1), "Activated callback"
    end
    if clicked and #clicked > 0 then
        return dispatchSignal(button.MouseButton1Click), "MouseButton1Click callback"
    end
    -- Physical input also handles UI libraries with centralized event listeners.
    if virtualClick(button) then return true, "VirtualInput click" end
    if not activated and not clicked then
        return dispatchSignal(button.MouseButton1Click), "MouseButton1Click fallback"
    end
    return false, "no usable click route"
end

-- Optimized text extraction for submit buttons
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

-- Optimized submit button scoring
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

-- Optimized submit button finding with caching
local function findSubmitButton(box)
    lastUiError = nil
    
    -- Check cached values for fast path
    if box == boundBox and usableGui(boundButton) then 
        return boundButton 
    end
    
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

-- Optimized code panel opening
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

-- Optimized code submission with caching
local function typeAndSubmitCode(code, requestToken)
    local localStartedAt = os.clock()
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
    
    -- CHECK UI binds the exact SAB field/button pair before scanning. On that
    -- verified path, setting Text is synchronous and the button callback reads
    -- the current value immediately, so focus churn and a fixed 50 ms sleep only
    -- add latency. Keep the older focus/settle path as a fallback when the game
    -- rebuilds its UI and invalidates the binding.
    local fastBound = box == boundBox and usableGui(boundButton) and boundFastSignal ~= nil
    local focused = false
    if not fastBound then focused = pcall(function() box:CaptureFocus() end) end
    local written = pcall(function() box.Text = code end)
    if not written or box.Text ~= code then return false, "Cannot write to the game's code field." end
    if not fastBound then task.wait(0.05) end
    if cancelled() then return false, "Cancelled: a new capture round started." end
    local button = fastBound and boundButton or findSubmitButton(box)
    if lastUiError then
        if focused then pcall(function() box:ReleaseFocus(false) end) end
        return false, lastUiError
    end
    if button then
        -- A focus change is not an Enter submission when a submit button exists.
        if focused then pcall(function() box:ReleaseFocus(false) end) end
        local active, interactable = true, true
        pcall(function() active = button.Active end)
        pcall(function() interactable = button.Interactable end)
        if not active or not interactable then
            boundBox, boundButton, boundFastSignal, boundFastRoute = nil, nil, nil, nil
            audit("ui_submit_dispatch", {code = code, button = button:GetFullName(), generation = requestToken,
                route = "blocked", dispatched = false, active = active, interactable = interactable})
            return false, "Submit is disabled. Close/reopen the game's Codes panel, then CHECK UI."
        end
        local clicked, route = false, nil
        if fastBound and boundFastSignal and type(firesignal) == "function" then
            local ok = pcall(firesignal, boundFastSignal)
            if ok then
                clicked = true
                route = (boundFastRoute or "cached callback") .. " fast"
            end
        end
        if not clicked then clicked, route = clickButton(button) end
        audit("ui_submit_dispatch", {code = code, button = button:GetFullName(), generation = requestToken,
            route = route, dispatched = clicked == true, active = active, interactable = interactable,
            fast_path = fastBound, local_ms = math.floor((os.clock() - localStartedAt) * 10000 + 0.5) / 10,
            ping_ms = currentPingMs()})
        if clicked then
            return true, "Submit dispatched via " .. tostring(route) .. "; waiting for the game's response."
        end
        return false, "Code filled. Click the game's redeem button manually." 
    end
    if focused then
        local ok, wasFocused = pcall(function() return box:IsFocused() end)
        if ok and wasFocused then
            local released = pcall(function() box:ReleaseFocus(true) end)
            if released then return true, "Enter submitted; check the game's result." end
        end
    end
    audit("ui_enter_dispatch", {code = code, field = box:GetFullName(), generation = requestToken})
    if dispatchSignal(box.FocusLost, true, nil) then return true, "Enter attempted; check the game's result." end
    return false, "Code filled. Press Enter in the game's code field manually."
end

-- Optimized callback source detection
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

-- Optimized notification remote detection
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

-- GUI creation and setup (optimized)
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
mainFrame.Size = UDim2.new(0, 310, 0, 424)
mainFrame.Position = UDim2.new(0.5, -155, 0.5, -212)
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
subLabel.Text = "SAB / v14 Compact"
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

-- Optimized toggle row creation with minimal allocations
local function createToggleRow(name, labelText, y, enabled)
    local row = Instance.new("Frame")
    row.Name = name .. "Row"
    row.Size = UDim2.new(1, -24, 0, 24)
    row.Position = UDim2.new(0, 12, 0, y)
    row.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    row.BackgroundTransparency = 0.55
    row.BorderSizePixel = 0
    row.Parent = mainFrame

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 9)
    corner.Parent = row

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.Size = UDim2.new(1, -68, 1, 0)
    label.Position = UDim2.new(0, 10, 0, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.Text = labelText
    label.TextColor3 = Color3.fromRGB(70, 75, 85)
    label.TextSize = 10
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = row

    local button = Instance.new("TextButton")
    button.Name = name .. "Toggle"
    button.Size = UDim2.new(0, 54, 0, 20)
    button.Position = UDim2.new(1, -56, 0, 2)
    button.BackgroundColor3 = enabled and Color3.fromRGB(70, 190, 100) or Color3.fromRGB(210, 70, 75)
    button.BorderSizePixel = 0
    button.Font = Enum.Font.GothamBold
    button.Text = enabled and "ON" or "OFF"
    button.TextColor3 = Color3.fromRGB(255, 255, 255)
    button.TextSize = 10
    button.Parent = row

    local buttonCorner = Instance.new("UICorner")
    buttonCorner.CornerRadius = UDim.new(0, 8)
    buttonCorner.Parent = button
    return button
end

local everyPartButton = createToggleRow("EveryPart", "SUBMIT EVERY PART", 88, false)
local wait2Button = createToggleRow("Wait2", "WAIT FOR 2 PARTS", 116, false)
local wait3Button = createToggleRow("Wait3", "WAIT FOR 3 PARTS", 144, true)
local wait4Button = createToggleRow("Wait4", "WAIT FOR 4 PARTS", 172, false)

-- Preview Code Textbox
local previewBox = Instance.new("TextBox")
previewBox.Name = "PreviewBox"
previewBox.Size = UDim2.new(1, -102, 0, 30)
previewBox.Position = UDim2.new(0, 12, 0, 204)
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
redeemButton.Position = UDim2.new(1, -82, 0, 204)
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
bottomRow.Position = UDim2.new(0, 12, 0, 240)
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

-- Hover Animations - optimized with precomputed colors
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

-- Mobile & PC Smooth Dragging Mechanics - optimized for performance
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

-- Status label with optimized error handling
local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.Position = UDim2.new(0, 12, 0, 320)
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
    audit("status", {message = message, is_error = isError == true})
    statusLabel.Text = message
    statusLabel.TextColor3 = isError and Color3.fromRGB(170, 30, 40) or Color3.fromRGB(50, 65, 80)
    if isError then warn("[Sources Hub] " .. message) else print("[Sources Hub] " .. message) end
end

logLabel = Instance.new("TextButton")
logLabel.Name = "LogStatus"
logLabel.Position = UDim2.new(0, 12, 0, 372)
logLabel.Size = UDim2.new(1, -24, 0, 42)
logLabel.BackgroundTransparency = 1
logLabel.Font = Enum.Font.Gotham
logLabel.TextSize = 10
logLabel.TextWrapped = true
logLabel.Parent = mainFrame
refreshLogLabel()
connect(logLabel.MouseButton1Click, function()
    local ok, message = diagnostics.copy()
    setStatus(message, not ok)
end)

-- Check UI button with optimized implementation
local checkButton = Instance.new("TextButton")
checkButton.Name = "CheckUI"
checkButton.Position = UDim2.new(0, 12, 0, 278)
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

-- Optimized UI checking function with caching
local function checkUi()
    boundBox, boundButton, boundFastSignal, boundFastRoute = nil, nil, nil, nil
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
    if activated and #activated > 0 then
        route = "Activated callback"
        boundFastSignal, boundFastRoute = button.Activated, route
    elseif clicked and #clicked > 0 then
        route = "MouseButton1Click callback"
        boundFastSignal, boundFastRoute = button.MouseButton1Click, route
    end
    local active, interactable, textEditable = true, true, true
    pcall(function() active = button.Active end)
    pcall(function() interactable = button.Interactable end)
    pcall(function() textEditable = box.TextEditable end)
    -- Diagnostics only: no focus, text change, signal firing or remote sending.
    print("[Sources Hub] CHECK UI - field: " .. box:GetFullName())
    print("[Sources Hub] CHECK UI - button: " .. button:GetFullName() .. "; route: " .. route
        .. "; active=" .. tostring(active) .. "; interactable=" .. tostring(interactable)
        .. "; textEditable=" .. tostring(textEditable))
    local remoteCount, labelCount = 0, 0
    for remote in pairs(state.remotes) do
        if remote.Parent and remote:IsDescendantOf(ReplicatedStorage) then remoteCount = remoteCount + 1 end
    end
    for label in pairs(state.labels) do
        if label.Parent and label:IsDescendantOf(PlayerGui) then labelCount = labelCount + 1 end
    end
    print("[Sources Hub] CHECK UI - announcement candidates: " .. remoteCount .. " remotes / " .. labelCount .. " labels")
    audit("ui_check", {field = box:GetFullName(), button = button:GetFullName(), route = route,
        active = active, interactable = interactable, text_editable = textEditable,
        remotes = remoteCount, labels = labelCount})
    if not active or not interactable or not textEditable then
        boundBox, boundButton, boundFastSignal, boundFastRoute = nil, nil, nil, nil
        setStatus("CHECK UI FAILED: Codes field or Submit is disabled. Close/reopen Codes before starting.", true)
        return false
    end
    if remoteCount + labelCount == 0 then
        setStatus("CHECK UI FAILED: no announcement source found yet. Wait a few seconds and check again.", true)
        return false
    end
    setStatus("CHECK UI READY: field + Submit usable. Route: " .. route
        .. ". Sources: " .. remoteCount .. " remotes / " .. labelCount .. " labels.")
    return true
end

connect(checkButton.MouseButton1Click, checkUi)

-- Optimized state and control variables
local scanning, busy, processing = false, false, false
local generation = 0
state.captureGeneration = generation
local submitOptions = {every = false, [2] = false, [3] = true, [4] = false}
local optionButtons = {every = everyPartButton, [2] = wait2Button, [3] = wait3Button, [4] = wait4Button}
local collecting = false
local fragments, submissionQueue = {}, {}
local delay, nextSubmitAt = 0.5, 0
local lastCode = ""
local recent = {}
local pendingSubmissions = {}
local beginPendingSubmission, failPendingSubmission, recordServerResult
local lastRemoteSeenAt, lastGuiSeenAt, watchStartedAt

-- Optimized preview update with minimal allocations
local function updatePreview()
    previewBox.Text = lastCode
end

-- Optimized delay update function
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

-- Optimized options snapshot with minimal allocations
local function optionsSnapshot()
    return {every_part = submitOptions.every, wait_2 = submitOptions[2],
        wait_3 = submitOptions[3], wait_4 = submitOptions[4]}
end

-- Optimized option summary
local function optionSummary()
    local active = {}
    if submitOptions.every then active[#active + 1] = "EVERY PART" end
    for part = 2, 4 do
        if submitOptions[part] then active[#active + 1] = "WAIT " .. part end
    end
    return #active > 0 and table.concat(active, " + ") or "NONE (PREVIEW ONLY)"
end

-- Optimized target ceiling calculation
local function targetCeiling()
    local highest = submitOptions.every and 4 or 0
    for part = 2, 4 do
        if submitOptions[part] and part > highest then highest = part end
    end
    return highest > 0 and highest or 4
end

-- Optimized submission reason calculation
local function submissionReason(part)
    local reasons = {}
    if submitOptions.every then reasons[#reasons + 1] = "every_part" end
    if submitOptions[part] then reasons[#reasons + 1] = "wait_" .. part end
    return #reasons > 0 and table.concat(reasons, "+") or nil
end

-- Optimized option button update with minimal allocations
local function updateOptionButton(key)
    local button, enabled = optionButtons[key], submitOptions[key]
    button.Text = enabled and "ON" or "OFF"
    button.BackgroundColor3 = enabled and Color3.fromRGB(70, 190, 100) or Color3.fromRGB(210, 70, 75)
end

-- Optimized option toggle
local function toggleOption(key)
    if collecting then
        setStatus("Finish or stop the current round before changing submission rules.", true)
        return
    end
    local enable = not submitOptions[key]
    -- A single client must have exactly one submission strategy. Combining
    -- WAIT 2 + WAIT 4 submits an incomplete code first and can poison the
    -- later full-code attempt with the game's cooldown.
    if enable then
        for optionKey in pairs(optionButtons) do
            submitOptions[optionKey] = optionKey == key
            updateOptionButton(optionKey)
        end
    else
        submitOptions[key] = false
        updateOptionButton(key)
    end
    audit("submit_option_changed", {option = tostring(key), enabled = submitOptions[key], options = optionsSnapshot()})
    setStatus("Active submission rule: " .. optionSummary() .. ". One rule per LDPlayer instance.")
end

connect(everyPartButton.MouseButton1Click, function() toggleOption("every") end)
connect(wait2Button.MouseButton1Click, function() toggleOption(2) end)
connect(wait3Button.MouseButton1Click, function() toggleOption(3) end)
connect(wait4Button.MouseButton1Click, function() toggleOption(4) end)

-- Optimized generation advancement
local function advanceGeneration()
    generation = generation + 1
    state.captureGeneration = generation
end

-- Optimized pause scan with minimal allocations
local function pauseScan(message)
    scanning, collecting = false, false
    watchStartedAt = nil
    advanceGeneration()
    submissionQueue = {}
    scanButton.Text = "START SCAN"
    statusDot.BackgroundColor3 = Color3.fromRGB(220, 40, 50)
    scanButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    setStatus(message, true)
end

-- Optimized processing buffer with minimal allocations
local function processBuffer()
    if processing or not scanning or not state.alive then return end
    processing = true
    local token = generation
    local ok, err = pcall(function()
        while state.alive and scanning and token == generation and #submissionQueue > 0 do
            if busy or os.clock() < nextSubmitAt then
                task.wait(0.05)
            else
                -- Each cumulative value is queued at most once, even when multiple
                -- enabled rules match the same part number.
                local item = table.remove(submissionQueue, 1)
                if item.generation == token then
                    busy = true
                    audit("submission_start", {code = item.code, source = item.source, part = item.part,
                        generation = token, mode = "trigger", input_event = item.inputEventId,
                        delay = delay, submission_rule = item.reason})
                    local pending = beginPendingSubmission({code = item.code, source = item.source,
                        part = item.part, generation = token, inputEventId = item.inputEventId})
                    local callOk, submitted, message = pcall(typeAndSubmitCode, item.code, token)
                    if not callOk then message, submitted = tostring(submitted), false end
                    pending.dispatched = submitted == true
                    pending.dispatchedAt = submitted == true and os.clock() or nil
                    pending.dispatchDetail = message
                    if not submitted then failPendingSubmission(pending, message) end
                    audit("submission_result", {code = item.code, source = item.source, input_event = item.inputEventId, generation = token,
                        attempted = submitted == true, detail = message, reward_confirmed = false,
                        cancelled = token ~= generation or not state.alive})
                    busy = false
                    if not state.alive or token ~= generation then break end
                    if not submitted then
                        -- Keep the MOST COMPLETE captured value for manual retry.
                        updatePreview()
                        pauseScan(message)
                        break
                    end
                    nextSubmitAt = os.clock() + delay
                    if submitted then
                        local tail = collecting and "waiting for next part" or "waiting for USE CODE / CODE IS"
                        local prefix
                        if item.reason and item.reason:find("every_part", 1, true) then prefix = "Cumulative part " .. item.part
                        else prefix = "Selected " .. item.part .. "-part code" end
                        setStatus(prefix .. ": dispatched; waiting for SERVER confirmation; " .. tail .. ".")
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

-- Optimized message cleaning
local function cleanMessage(value)
    if type(value) ~= "string" then return nil end
    return value:gsub("<[^>]*>", ""):match("^%s*(.-)%s*$")
end

-- Optimized pending submission removal
local function removePendingSubmission(pending)
    for index, item in ipairs(pendingSubmissions) do
        if item == pending then
            table.remove(pendingSubmissions, index)
            return true
        end
    end
    return false
end

-- Optimized server result classification
local function classifyServerResult(value)
    local text = cleanMessage(value)
    if not text or text == "" then return nil end
    local lower = text:lower():gsub("%s+", " ")
    if lower:find("invalid code", 1, true) then return "invalid", text end
    if lower:find("sold out", 1, true) then return "sold_out", text end
    if lower:find("please wait before trying to redeem", 1, true)
        or lower:find("cooldown", 1, true) then return "cooldown", text end
    if lower:find("already redeemed", 1, true)
        or lower:find("already claimed", 1, true) then return "already_used", text end
    if lower:find("successfully redeemed", 1, true)
        or lower:find("code redeemed", 1, true)
        or lower:find("redeemed successfully", 1, true) then return "accepted", text end
    return nil
end

-- Optimized beginPendingSubmission with minimal allocations
beginPendingSubmission = function(fields)
    local pending = {
        code = fields.code, source = fields.source, part = fields.part,
        generation = fields.generation, inputEventId = fields.inputEventId,
        startedAt = os.clock(), dispatched = false, resolved = false,
    }
    table.insert(pendingSubmissions, pending)
    task.delay(5, function()
        if not state.alive or pending.resolved or not removePendingSubmission(pending) then return end
        pending.resolved = true
        boundBox, boundButton, boundFastSignal, boundFastRoute = nil, nil, nil, nil
        audit("server_result_timeout", {code = pending.code, source = pending.source,
            part = pending.part, generation = pending.generation,
            elapsed_since_start = os.clock() - pending.startedAt})
        setStatus("NO SERVER RESPONSE for " .. tostring(pending.code)
            .. ". Submit route may be stuck; reopen Codes or run CHECK UI.", true)
    end)
    return pending
end

-- Optimized failPendingSubmission with minimal allocations
failPendingSubmission = function(pending, detail)
    if not pending then return end
    pending.resolved = true
    removePendingSubmission(pending)
    audit("submission_dispatch_failed", {code = pending.code, detail = detail,
        elapsed_since_start = os.clock() - pending.startedAt})
end

-- Optimized server result recording with minimal allocations
recordServerResult = function(value, source, inputEventId)
    local kind, text = classifyServerResult(value)
    if not kind then return false end
    local now = os.clock()
    local previous = resultRecent[text]
    if previous and previous.source ~= source and now - previous.time < 0.75 then return true end
    resultRecent[text] = {source = source, time = now}
    for key, entry in pairs(resultRecent) do
        if now - entry.time > 3 then resultRecent[key] = nil end
    end
    local pending = pendingSubmissions[1]
    if pending then
        pending.resolved = true
        removePendingSubmission(pending)
    end
    audit("server_submission_result", {result = kind, message = text, source = source,
        input_event = inputEventId, code = pending and pending.code or nil,
        matched_pending = pending ~= nil,
        response_seconds = pending and (now - pending.startedAt) or nil,
        local_dispatch_seconds = pending and pending.dispatchedAt and (pending.dispatchedAt - pending.startedAt) or nil,
        after_dispatch_seconds = pending and pending.dispatchedAt and (now - pending.dispatchedAt) or nil,
        ping_ms = currentPingMs()})
    if kind == "accepted" then
        setStatus("SERVER ACCEPTED" .. (pending and (": " .. pending.code) or "."))
    elseif kind == "sold_out" then
        setStatus("SERVER: SOLD OUT" .. (pending and (" — " .. pending.code) or ""), true)
    elseif kind == "invalid" then
        setStatus("SERVER: INVALID CODE" .. (pending and (" — " .. pending.code) or ""), true)
    elseif kind == "cooldown" then
        setStatus("SERVER: COOLDOWN" .. (pending and (" — " .. pending.code) or ""), true)
    else
        setStatus("SERVER: " .. text .. (pending and (" — " .. pending.code) or ""), true)
    end
    return true
end

-- Optimized trigger detection
local function isTrigger(value)
    local message = cleanMessage(value)
    if not message then return false end
    -- "This code is sold out" contains the words "code is", but it is a
    -- server result, not the start of another capture round.
    if classifyServerResult(message) then return false end
    message = message:lower()
    return message:find("%f[%a]use%s+code%f[%A]") ~= nil
        or message:find("%f[%a]code%s+is%f[%A]") ~= nil
end

-- Optimized message normalization
local function normalizeMessage(value)
    local message = cleanMessage(value)
    if not message then return nil end
    message = message:match("^[Cc][Oo][Dd][Ee]%s*:%s*([%w_%-]+)$") or message
    if #message < 1 or #message > 96 or not message:match("^[A-Za-z0-9_%-]+$") then return nil end
    return message
end

-- Optimized announcement handling with minimal allocations
local function onAnnouncement(value, source, inputEventId)
    if not scanning or not state.alive then return end
    audit("capture_input", {source = source, text = value, explicit_answer = false, input_event = inputEventId, generation = generation})
    local trigger = isTrigger(value)
    local message = trigger and cleanMessage(value):lower():gsub("%s+", " ") or normalizeMessage(value)
    if not message or message == "" or (not trigger and not collecting) then return end
    local now = os.clock()
    local previous = recent[message]
    -- A UI mirror must not restart a round or add the same fragment twice.
    -- Repeated equal fragments on the SAME source are valid independent arrivals.
    if previous and previous.source ~= source and now - previous.time < 0.75 then
        audit("duplicate_ignored", {source = source, text = message, previous_source = previous.source})
        return
    end
    recent[message] = {source = source, time = now}
    for key, entry in pairs(recent) do
        if now - entry.time > 2 then recent[key] = nil end
    end
    if trigger then
        audit("trigger_received", {source = source, text = message, options = optionsSnapshot()})
        advanceGeneration()
        collecting = true
        fragments, submissionQueue = {}, {}
        -- Ignore UI text that was already present before this trigger.
        for _, labelState in pairs(state.labels) do labelState.pending = false end
        lastCode = ""
        updatePreview()
        scanButton.Text = "COLLECTING: 0 / " .. targetCeiling()
        setStatus("Trigger seen. Active rules: " .. optionSummary())
        print("[Sources Hub] New round: " .. message)
        -- Neither text before the phrase nor text following it in THIS same
        -- announcement is captured. Only subsequently received messages count.
        return
    end
    table.insert(fragments, message)
    local part = #fragments
    lastCode = table.concat(fragments, "")
    updatePreview()
    local ceiling = targetCeiling()
    local reason = submissionReason(part)
    audit("part_captured", {source = source, fragment = message, code = lastCode, part = part,
        options = optionsSnapshot(), queued = reason ~= nil, submission_rule = reason,
        input_event = inputEventId, generation = generation})
    print("[Sources Hub] Part " .. part .. " (" .. source .. "): " .. message .. " -> " .. lastCode)
    if reason then
        table.insert(submissionQueue, {code = lastCode, part = part, generation = generation,
            source = source, inputEventId = inputEventId, reason = reason})
        audit("code_queued", {source = source, fragment = message, code = lastCode, part = part,
            options = optionsSnapshot(), submission_rule = reason, input_event = inputEventId, generation = generation})
    end
    if part >= ceiling then
        collecting = false
        scanButton.Text = "WAITING FOR TRIGGER"
    else
        scanButton.Text = "COLLECTING: " .. part .. " / " .. ceiling
    end
    if reason then
        setStatus("Captured part " .. part .. " / " .. ceiling .. ". Queued by " .. reason .. ": " .. lastCode)
        task.defer(processBuffer)
    else
        setStatus("Captured part " .. part .. " / " .. ceiling .. ": " .. lastCode .. ". No matching submit rule.")
    end
end

-- Optimized payload text extraction with minimal allocations
local function payloadText(value, depth)
    if type(value) == "string" then return value end
    if type(value) ~= "table" or depth > 3 then return nil end
    for _, key in ipairs({"Text", "text", "Message", "message", "Content", "content", "Announcement", "announcement"}) do
        local result = payloadText(value[key], depth + 1)
        if result then return result end
    end
    return payloadText(value[1], depth + 1)
end

-- Optimized primary notification text extraction
local function primaryNotificationText(...)
    -- SAB notification remotes use argument 1 for the visible message.
    -- Later positional arguments are duration, sound, placement ("Top") and
    -- colour metadata. Scanning those fields created WTopTop/TopTopTop codes.
    if select("#", ...) < 1 then return nil end
    return payloadText(select(1, ...), 0)
end

-- Optimized remote watching with minimal allocations
local function watchRemote(remote)
    if not state.alive then return end
    if state.remotes[remote] or not isNotificationRemote(remote) then return end
    state.remotes[remote] = true
    connect(remote.OnClientEvent, function(...)
        lastRemoteSeenAt = os.clock()
        -- Observation precedes text extraction and never feeds back into it.
        local remoteSource = "remote:" .. remote:GetFullName()
        local inputEventId = diagnostics.remote(remoteSource, scanning, "trigger", ...)
        local primaryText = primaryNotificationText(...)
        if primaryText then recordServerResult(primaryText, remoteSource, inputEventId) end
        if primaryText and (isTrigger(primaryText) or normalizeMessage(primaryText)) then
            audit("remote_text_selected", {source = remoteSource,
                input_event = inputEventId, argument = 1, text = primaryText})
            onAnnouncement(primaryText, remoteSource, inputEventId)
        end
    end)
    audit("source_attached", {source = "remote:" .. remote:GetFullName()})
    print("[Sources Hub] Listening: " .. remote:GetFullName())
end

-- Optimized announcement context checking
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

-- Optimized label watching with minimal allocations
local function watchLabel(label, fresh)
    if not state.alive then return end
    if not label:IsA("TextLabel") or isOurGui(label) or state.labels[label] then return end
    if not announcementContext(label) then return end
    local labelState = {pending = fresh == true}
    diagnostics.gui(label, "source_attached", isVisibleChain(label), os.clock())
    state.labels[label] = labelState
    local lastText, lastTime = nil, -math.huge
    local function capture()
        if labelState.pending and isVisibleChain(label) then
            labelState.pending = false
            lastGuiSeenAt = os.clock()
            -- Text, Visible and parent visibility may all change for ONE label.
            -- Count that as one fragment rather than three separate messages.
            local now = os.clock()
            if label.Text == lastText and now - lastTime < 0.75 then return end
            lastText, lastTime = label.Text, now
            local inputEventId = diagnostics.gui(label, "visible_delivery", true, now)
            local guiSource = "gui:" .. label:GetFullName()
            recordServerResult(label.Text, guiSource, inputEventId)
            onAnnouncement(label.Text, guiSource, inputEventId)
        end
    end
    connect(label:GetPropertyChangedSignal("Text"), function()
        diagnostics.gui(label, "text_changed", isVisibleChain(label), os.clock())
        labelState.pending = true
        capture()
    end)
    connect(label:GetPropertyChangedSignal("Visible"), function()
        diagnostics.gui(label, "visibility_changed", isVisibleChain(label), os.clock())
        capture()
    end)
    -- A reused notification may become visible through its parent frame.
    local parent = label.Parent
    while parent and parent ~= PlayerGui do
        if parent:IsA("GuiObject") then connect(parent:GetPropertyChangedSignal("Visible"), capture)
        elseif parent:IsA("ScreenGui") then connect(parent:GetPropertyChangedSignal("Enabled"), capture) end
        parent = parent.Parent
    end
    if fresh then task.defer(capture) end
end

-- Optimized source discovery with minimal allocations
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

-- Optimized source summary with minimal allocations
local function sourceSummary()
    local remoteCount, labelCount = 0, 0
    for remote in pairs(state.remotes) do
        if remote.Parent and remote:IsDescendantOf(ReplicatedStorage) then remoteCount = remoteCount + 1 end
    end
    for label in pairs(state.labels) do
        if label.Parent and label:IsDescendantOf(PlayerGui) then labelCount = labelCount + 1 end
    end
    return remoteCount, labelCount
end

-- Optimized scan button click handler with minimal allocations
connect(scanButton.MouseButton1Click, function()
    local enable = not scanning
    if enable and not checkUi() then return end
    for _, labelState in pairs(state.labels) do labelState.pending = false end
    scanning = enable
    watchStartedAt = enable and os.clock() or nil
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
        audit("watch_started", {mode = "trigger", options = optionsSnapshot(), started_at = watchStartedAt,
            remotes = remoteCount, labels = labelCount})
        setStatus("Waiting for USE CODE / CODE IS. Rules: " .. optionSummary() .. ". Sources: " .. remoteCount .. " remotes / " .. labelCount .. " UI labels", remoteCount + labelCount == 0)
    else
        scanButton.Text = "START SCAN"
        scanButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        statusDot.BackgroundColor3 = Color3.fromRGB(220, 40, 50)
        audit("watch_stopped", {mode = "trigger", pending_submissions = #pendingSubmissions})
        setStatus("Stopped. Last code kept for manual redeem.")
    end
end)

-- Optimized manual redeem function with minimal allocations
local function manualRedeem()
    if busy then setStatus("A submission is already in progress.", true); return end
    local code = previewBox.Text:match("^%s*(.-)%s*$")
    if code == "" then setStatus("Enter a code first.", true); return end
    busy = true
    lastCode = code
    audit("submission_start", {code = code, source = "manual", mode = "manual"})
    local pending = beginPendingSubmission({code = code, source = "manual", generation = generation})
    local callOk, submitted, message = pcall(typeAndSubmitCode, code)
    if not callOk then message, submitted = tostring(submitted), false end
    pending.dispatched = submitted == true
    pending.dispatchDetail = message
    if not submitted then failPendingSubmission(pending, message) end
    audit("submission_result", {code = code, source = "manual", attempted = submitted == true,
        detail = message, reward_confirmed = false})
    nextSubmitAt = os.clock() + delay
    busy = false
    if state.alive then
        if submitted and not pending.resolved then
            setStatus("Manual code dispatched; waiting for SERVER confirmation: " .. code)
        elseif not submitted then
            setStatus("Manual submit failed: " .. tostring(message), true)
        end
    end
    if scanning and #submissionQueue > 0 then task.defer(processBuffer) end
end

connect(redeemButton.MouseButton1Click, manualRedeem)
connect(previewBox.FocusLost, function(enter) if enter then manualRedeem() end end)

-- Optimized cleanup connection
connect(statusDot.MouseButton1Click, state.cleanup)
connect(screenGui.Destroying, state.cleanup)

-- Optimized input handling with minimal allocations
connect(UserInputService.InputChanged, function(input)
    if input == dragInput and dragging then update(input) end
end)

-- Optimized health audit with minimal allocations
local lastHealthAudit = -math.huge
task.spawn(function()
    while state.alive do
        local ok, err = pcall(refreshSources)
        if not ok then warn("[Sources Hub] Source discovery: " .. tostring(err)) end
        local now = os.clock()
        if scanning and now - lastHealthAudit >= 15 then
            local remoteCount, labelCount = sourceSummary()
            audit("watch_health", {mode = "trigger",
                watch_seconds = watchStartedAt and (now - watchStartedAt) or 0,
                remotes = remoteCount, labels = labelCount, pending_submissions = #pendingSubmissions,
                seconds_since_remote = lastRemoteSeenAt and (now - lastRemoteSeenAt) or -1,
                seconds_since_gui = lastGuiSeenAt and (now - lastGuiSeenAt) or -1,
                collecting = collecting, queued = #submissionQueue, busy = busy})
            lastHealthAudit = now
            if remoteCount + labelCount == 0 then
                pauseScan("WATCH STOPPED: all announcement sources disappeared. Rejoin and run CHECK UI.")
            end
        end
        task.wait(3)
    end
end)

-- Executor identification with minimal allocations
local executorName = "unknown"
if type(identifyexecutor) == "function" then
    local ok, name = pcall(identifyexecutor)
    if ok then executorName = tostring(name) end
end

print("[Sources Hub] Executor: " .. executorName .. "; getconnections=" .. tostring(type(getconns) == "function")
    .. "; firesignal=" .. tostring(type(firesignal) == "function"))
setStatus("Ready v14 Compact. Open Codes, choose ONE rule, run CHECK UI, then START SCAN. Client notices are logged.")

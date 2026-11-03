-- UF orb with experimental local catch attempts. No remote calls or catch guarantees.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local player = Players.LocalPlayer
assert(player, "UF Tracker requires a client")
local playerGui = player:WaitForChild("PlayerGui")
local previous = playerGui:FindFirstChild("UFTracker")
if previous then
    local shutdown = previous:FindFirstChild("Shutdown")
    if shutdown and shutdown:IsA("BindableEvent") then shutdown:Fire() end
    previous:Destroy()
end

local config = { radius = 20, sampleHz = 30, jumpSpeed = 250, maxEvents = 400, approachSeconds = 0.10, holdSeconds = 0.20, tapHoldSeconds = 0.06 }
local running, closed, visible = true, false, true
local records, boxes, connections, events = {}, {}, {}, {}
local nextId, eventCount, lastSample, lastDiscovery, lastUi = 0, 0, 0, 0, 0
local started = os.clock()
local heartbeatIndex = 0
local runtimeError, errorAt, attemptCount = nil, 0, 0
local status
local callbackErrors = {}
local inputAnimationProbes = {}
local animationSnapshot
local boundary = Instance.new("BindableEvent")
boundary.Name = "BoundaryCrossed"
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.ZIndexBehavior = "UFTracker", false, Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui
boundary.Parent = gui
local shutdown = Instance.new("BindableEvent")
shutdown.Name, shutdown.Parent = "Shutdown", gui
local function connect(signal, fn, bucket)
    local connection = signal:Connect(function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            runtimeError = tostring(err)
            table.insert(callbackErrors, { t = os.clock() - started, error = runtimeError })
            if #callbackErrors > 20 then table.remove(callbackErrors, 1) end
            if status then status.Text = "ERROR · " .. runtimeError end
            if os.clock() - errorAt > 2 then
                errorAt = os.clock()
                warn("UF Tracker: " .. runtimeError)
            end
        end
    end)
    table.insert(bucket or connections, connection)
    return connection
end
local function disconnect(bucket)
    for _, connection in ipairs(bucket) do connection:Disconnect() end
    table.clear(bucket)
end
local function vector(v) return { x = v.X, y = v.Y, z = v.Z } end
local function emit(kind, record, data)
    eventCount = eventCount + 1
    table.insert(events, { t = os.clock() - started, kind = kind, id = record and record.id, data = data })
    if #events > config.maxEvents then table.remove(events, 1) end
end
-- Keep a single outstanding move so off/close/respawn can safely cancel it.
local pendingMove
local requestCatchTap
local pendingInput
local function releaseInput(reason)
    local input = pendingInput
    if not input then return end
    pendingInput = nil
    local ok, err = pcall(input.release)
    if not ok then ok, err = pcall(input.release) end
    emit("catch_input_release", input.record, { method = input.method, released = ok,
        reason = reason, heldSeconds = os.clock() - input.startedAt,
        error = not ok and tostring(err) or nil })
end
local function resetBoundaries()
    for _, record in pairs(records) do
        record.relative, record.rootPosition, record.rootRef = nil, nil, nil
    end
end
local function restoreMove(reason)
    releaseInput(reason)
    local saved = pendingMove
    if not saved then return end
    pendingMove = nil
    local parent = saved.ball and saved.ball.Parent
    local associatedWith = parent and parent.Parent == Workspace and parent.Name or nil
    if not associatedWith and saved.record then associatedWith = saved.record.associatedWith end
    local keepPosition = associatedWith ~= nil and associatedWith == player.Name
    local ok, err = false, nil
    -- Never move a replacement character or restore after the original character died.
    if player.Character == saved.character and saved.root:IsDescendantOf(saved.character)
        and saved.humanoid.Health > 0 then
        ok, err = pcall(function()
            if not keepPosition then
                saved.root.CFrame = saved.cframe
                saved.root.AssemblyLinearVelocity = saved.linear
                saved.root.AssemblyAngularVelocity = saved.angular
            end
        end)
    end
    resetBoundaries()
    emit(keepPosition and "catch_attempt_finished" or "catch_attempt_return", nil,
        { id = saved.id, reason = reason, restored = ok and not keepPosition,
        positionKept = ok and keepPosition, associatedPlayer = associatedWith,
        outcome = "Association observed; possession unconfirmed",
        heldSeconds = saved.attemptAt and os.clock() - saved.attemptAt,
        heartbeatDelta = saved.heartbeat and heartbeatIndex - saved.heartbeat,
        error = err and tostring(err) })
end
local function setGate(record, reason)
    if record.lastGate ~= reason then
        record.lastGate = reason
        emit("detection_gate", record, { reason = reason, minDistance = record.minDistance })
    end
end
local function snapshot(ball)
    return { name = ball.Name, path = ball:GetFullName(), position = vector(ball.Position),
        velocity = vector(ball.AssemblyLinearVelocity), anchored = ball.Anchored }
end
local function fieldContainer()
    local node = Workspace
    for _, name in ipairs({ "ParkMatchMap", "Replicated", "Fields", "MatchField", "Replicated" }) do
        node = node:FindFirstChild(name)
        if not node then return nil end
    end
    return node
end
local function association(ball)
    local parent = ball.Parent
    if parent and parent.Parent == Workspace and Players:FindFirstChild(parent.Name) then return parent.Name end
    return nil
end
local function validBox(box)
    if not box:IsA("BasePart") or box.Name ~= "CatchBox" then return nil end
    local owner = box.Parent
    local hitboxes = owner and owner.Parent
    local replicated = hitboxes and hitboxes.Parent
    local session = replicated and replicated.Parent
    local miniGames = Workspace:FindFirstChild("MiniGames")
    if miniGames and session and session.Parent == miniGames and replicated.Name == "Replicated"
        and hitboxes.Name == "Hitboxes" and Players:FindFirstChild(owner.Name) then return owner.Name end
    return nil
end
local function registerBox(box)
    if boxes[box] then return end
    local owner = validBox(box)
    if not owner then return end
    local entry = { owner = owner, connections = {} }
    boxes[box] = entry
    local function remove()
        if not boxes[box] then return end
        disconnect(entry.connections)
        boxes[box] = nil
    end
    connect(box.AncestryChanged, function() if not validBox(box) then remove() end end, entry.connections)
    connect(box.Destroying, remove, entry.connections)
    for _, property in ipairs({ "Size", "CanCollide", "CanTouch", "CanQuery" }) do
        connect(box:GetPropertyChangedSignal(property), function()
            emit("catchbox_property", nil, { owner = owner, property = property,
                value = tostring(box[property]) })
        end, entry.connections)
    end
end
local function registerBall(ball)
    if records[ball] or not ball:IsA("MeshPart") or ball.Name ~= "Football" or ball.Parent ~= fieldContainer() then return end
    nextId = nextId + 1
    local record = { id = string.format("B%04d", nextId), state = "DISCOVERED", connections = {},
        triggered = false, associated = false, shells = {} }
    records[ball] = record
    emit("discovered", record, snapshot(ball))
    local function transition()
        local associatedWith = association(ball)
        record.associatedWith = associatedWith or record.associatedWith
        record.associated = record.associated or associatedWith ~= nil
        if record.associated then record.state = "PLAYER_ASSOCIATED" end
        emit("transition", record, { snapshot = snapshot(ball), player = association(ball) })
    end
    connect(ball:GetPropertyChangedSignal("Name"), transition, record.connections)
    connect(ball.AncestryChanged, transition, record.connections)
    local function shellAdded(child)
        if child.Name == "OuterShell" and child:IsA("MeshPart") and not record.shells[child] then
            record.shells[child] = true
            emit("shell_added", record, snapshot(child))
        end
    end
    connect(ball.ChildAdded, shellAdded, record.connections)
    connect(ball.ChildRemoved, function(child)
        if record.shells[child] then
            record.shells[child] = nil
            emit("shell_removed", record, { name = child.Name })
        end
    end, record.connections)
    for _, child in ipairs(ball:GetChildren()) do shellAdded(child) end
    connect(ball.Touched, function(hit)
        local owner = validBox(hit)
        if owner then
            registerBox(hit)
            if not record.associated then record.state = "CONTACT_OBSERVED" end
            emit("contact_observed", record, { player = owner, snapshot = snapshot(ball),
                elapsed = os.clock() - record.discoveredAt, catchboxSize = vector(hit.Size),
                catchboxPosition = vector(hit.Position) })
            if owner == player.Name and pendingMove and pendingMove.ball == ball and requestCatchTap then
                requestCatchTap(pendingMove, "local_catchbox_contact")
            end
        end
    end, record.connections)
    record.discoveredAt = os.clock()
    connect(ball.Destroying, function()
        record.state = "ENDED"
        emit("destroyed", record, { snapshot = snapshot(ball), lastGate = record.lastGate,
            minDistance = record.minDistance, triggered = record.triggered })
        disconnect(record.connections)
        table.clear(record.shells)
        records[ball] = nil
    end, record.connections)
end
local function discover()
    local field = fieldContainer()
    if field then
        for _, child in ipairs(field:GetChildren()) do registerBall(child) end
    end
    local miniGames = Workspace:FindFirstChild("MiniGames")
    if miniGames then
        for _, session in ipairs(miniGames:GetChildren()) do
            local replicated = session:FindFirstChild("Replicated")
            local hitboxes = replicated and replicated:FindFirstChild("Hitboxes")
            if hitboxes then
                for _, owner in ipairs(hitboxes:GetChildren()) do
                    local box = owner:FindFirstChild("CatchBox")
                    if box then registerBox(box) end
                end
            end
        end
    end
end
-- A relative-position segment catches outside-to-outside crossings between samples.
local function segmentDistance(a, b)
    local d = b - a
    local t = d:Dot(d) > 0 and math.clamp(-a:Dot(d) / d:Dot(d), 0, 1) or 0
    return (a + d * t).Magnitude
end
-- Current overlap also counts: discovery can happen after a fast ball entered the orb.
local function entersOrb(previousRelative, relative, radius, validSegment)
    if relative.Magnitude <= radius then return true end
    return validSegment and previousRelative ~= nil and previousRelative.Magnitude > radius
        and segmentDistance(previousRelative, relative) <= radius or false
end
local orb = Instance.new("SphereHandleAdornment")
orb.Name, orb.Color3, orb.Transparency = "UFDetectionOrb", Color3.fromRGB(175, 70, 255), 0.85
orb.AlwaysOnTop, orb.ZIndex, orb.Parent = false, 0, gui

local frame = Instance.new("Frame")
frame.Size, frame.Position = UDim2.fromOffset(210, 142), UDim2.new(0, 16, 0.2, 0)
frame.BackgroundColor3, frame.Parent = Color3.fromRGB(22, 18, 30), gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
local function label(text, x, y, width, height)
    local item = Instance.new("TextLabel")
    item.Size, item.Position = UDim2.fromOffset(width, height), UDim2.fromOffset(x, y)
    item.BackgroundTransparency, item.TextColor3 = 1, Color3.fromRGB(235, 225, 250)
    item.Font, item.TextSize = Enum.Font.Gotham, 12
    item.TextXAlignment = Enum.TextXAlignment.Left
    item.Text, item.Parent = text, frame
    return item
end
local title = label("UF · CATCH v15", 12, 4, 120, 26)
title.Active = true
local function button(text, x, y, width, height, fn)
    local item = Instance.new("TextButton")
    item.Text, item.Size, item.Position = text, UDim2.fromOffset(width, height), UDim2.fromOffset(x, y)
    item.BackgroundColor3, item.TextColor3 = Color3.fromRGB(85, 40, 120), Color3.new(1, 1, 1)
    item.Font, item.TextSize, item.Parent = Enum.Font.Gotham, 12, frame
    Instance.new("UICorner", item).CornerRadius = UDim.new(0, 6)
    connect(item.Activated, fn)
    return item
end
local radiusLabel = label("Radius · 20 studs", 12, 34, 130, 24)
local toggle
local function setEnabled(enabled)
    running, visible = enabled, enabled
    if not enabled then restoreMove("disabled") end
    toggle.Text = enabled and "ON" or "OFF"
    toggle.BackgroundColor3 = enabled and Color3.fromRGB(123, 56, 185) or Color3.fromRGB(65, 60, 72)
    for _, record in pairs(records) do record.relative = nil end
end
toggle = button("ON", 150, 34, 48, 24, function() setEnabled(not running) end)
setEnabled(running)
-- A wide transparent hit target makes the narrow track usable with a finger.
local slider = Instance.new("TextButton")
slider.Name, slider.Text = "RadiusSlider", ""
slider.Size, slider.Position = UDim2.fromOffset(186, 28), UDim2.fromOffset(12, 60)
slider.BackgroundTransparency, slider.AutoButtonColor, slider.Parent = 1, false, frame
local track = Instance.new("Frame")
track.Size, track.Position = UDim2.new(1, 0, 0, 4), UDim2.new(0, 0, 0.5, -2)
track.BackgroundColor3, track.BorderSizePixel, track.Parent = Color3.fromRGB(60, 48, 75), 0, slider
Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)
local fill = Instance.new("Frame")
fill.BackgroundColor3, fill.BorderSizePixel, fill.Parent = Color3.fromRGB(183, 100, 255), 0, track
Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)
local knob = Instance.new("Frame")
knob.Size, knob.AnchorPoint = UDim2.fromOffset(14, 14), Vector2.new(0.5, 0.5)
knob.BackgroundColor3, knob.BorderSizePixel, knob.Parent = Color3.fromRGB(230, 205, 255), 0, track
Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
local function setRadius(value)
    local rounded = math.clamp(math.floor(value + 0.5), 5, 100)
    if rounded ~= config.radius then
        config.radius = rounded
        for _, record in pairs(records) do record.relative = nil end
    end
    local alpha = (config.radius - 5) / 95
    radiusLabel.Text = "Radius · " .. config.radius .. " studs"
    fill.Size, knob.Position = UDim2.new(alpha, 0, 1, 0), UDim2.new(alpha, 0, 0.5, 0)
    orb.Radius = config.radius
end
setRadius(config.radius)
local sliderInput
local function slide(input)
    local width = slider.AbsoluteSize.X
    if width > 0 then setRadius(5 + 95 * math.clamp((input.Position.X - slider.AbsolutePosition.X) / width, 0, 1)) end
end
connect(slider.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        sliderInput = input
        slide(input)
    end
end)
connect(UserInputService.InputChanged, function(input)
    if sliderInput and (input == sliderInput or
        (sliderInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)) then
        slide(input)
    end
end)
connect(UserInputService.InputEnded, function(input) if input == sliderInput then sliderInput = nil end end)
status = label("Waiting for football", 12, 88, 186, 18)
status.TextSize = 10
local report = Instance.new("TextBox")
report.Name, report.Text = "ResultText", ""
report.PlaceholderText = "Press TEST + COPY to generate a report"
report.TextXAlignment, report.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top
report.Size, report.Position = UDim2.fromOffset(210, 130), UDim2.fromOffset(0, 168)
report.MultiLine, report.ClearTextOnFocus, report.TextEditable = true, false, true
report.TextSize, report.TextColor3, report.BackgroundColor3 = 11, Color3.new(1, 1, 1), Color3.fromRGB(30, 25, 40)
report.TextWrapped, report.Visible, report.Parent = true, false, frame
-- Report encoding helpers. Never let one bad diagnostic value disable export.
local function jsonSafe(value, seen, depth, warnings, path, budget)
    local function mark(reason)
        if #warnings < 50 then table.insert(warnings, path .. ": " .. reason) end
    end
    budget.remaining = budget.remaining - 1
    if budget.remaining < 0 then mark("report size limit"); return "<truncated>" end
    local kind = type(value)
    if kind == "nil" or kind == "boolean" or kind == "string" then return value end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            mark("non-finite number"); return "<non-finite number>"
        end
        return value
    end
    if kind ~= "table" then mark("converted " .. kind); return tostring(value) end
    if seen[value] then mark("cycle to " .. seen[value]); return "<cycle>" end
    if depth >= 16 then mark("depth limit"); return "<depth limit>" end
    seen[value] = path
    local count, maxIndex, isArray = 0, 0, true
    for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key == math.huge then isArray = false
        else maxIndex = math.max(maxIndex, key) end
    end
    isArray = isArray and maxIndex == count
    local out = {}
    for key, entry in pairs(value) do
        if budget.remaining <= 0 then mark("report size limit"); break end
        local safeKey = isArray and key or tostring(key)
        if not isArray and type(key) ~= "string" then mark("converted dictionary key") end
        if out[safeKey] ~= nil then mark("dictionary key collision: " .. tostring(safeKey)) end
        out[safeKey] = jsonSafe(entry, seen, depth + 1, warnings, path .. "." .. tostring(safeKey), budget)
    end
    seen[value] = nil
    return out
end
local function plainReport(value)
    local lines = {}
    local function visit(entry, path)
        if #lines >= 3000 then return end
        if type(entry) ~= "table" then
            table.insert(lines, path .. " = " .. tostring(entry))
            return
        end
        local keys = {}
        for key in pairs(entry) do table.insert(keys, key) end
        table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
        if #keys == 0 then table.insert(lines, path .. " = {}") end
        for _, key in ipairs(keys) do visit(entry[key], path .. "." .. tostring(key)) end
    end
    visit(value, "result")
    if #lines >= 3000 then table.insert(lines, "<plain-text line limit reached>") end
    return table.concat(lines, "\n")
end
local function encodeResult(data)
    local warnings = {}
    local clean = jsonSafe(data, {}, 0, warnings, "result", { remaining = 20000 })
    clean.serializationWarnings = warnings
    local ok, encoded = pcall(function() return HttpService:JSONEncode(clean) end)
    if ok and type(encoded) == "string" then return "UF COPY RESULT v15\n" .. encoded end
    return "UF COPY RESULT v15\nFORMAT: plain-text fallback\nJSON error: " .. tostring(encoded)
        .. "\n" .. plainReport(clean)
end
local lastRealTap, realTapCount, lastInputResult = nil, 0, "not_attempted"
local ignoreTapUntil, ignoredSyntheticTaps = 0, 0
local lastInjectedScreenPoint
local reportSerial, manualTestCount = 0, 0
local scheduledReport
local publishResult
local function collectResult()
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local pathNodes, node = {}, Workspace
    for _, name in ipairs({ "ParkMatchMap", "Replicated", "Fields", "MatchField", "Replicated" }) do
        node = node and node:FindFirstChild(name)
        table.insert(pathNodes, { name = name, found = node ~= nil })
    end
    local balls, catchboxes, fieldChildren = {}, {}, {}
    if node then
        for i, child in ipairs(node:GetChildren()) do
            if i > 32 then break end
            table.insert(fieldChildren, { name = child.Name, class = child.ClassName })
        end
    end
    for ball, record in pairs(records) do
        local ok, info = pcall(function()
            return { id = record.id, state = record.state, triggered = record.triggered,
                associated = record.associated, associatedPlayer = record.associatedWith, lastGate = record.lastGate, minDistance = record.minDistance, snapshot = snapshot(ball),
                distance = root and (ball.Position - root.Position).Magnitude,
                physicsSpeed = ball.AssemblyLinearVelocity.Magnitude, lastDerivedSpeed = record.derivedSpeed,
                lastSampleAge = record.time and os.clock() - record.time,
                inWorkspace = ball:IsDescendantOf(Workspace) }
        end)
        table.insert(balls, ok and info or { id = record.id, error = tostring(info) })
    end
    for box, entry in pairs(boxes) do
        if entry.owner == player.Name then
            local ok, info = pcall(function()
                return { path = box:GetFullName(), position = vector(box.Position), size = vector(box.Size),
                    canTouch = box.CanTouch, canCollide = box.CanCollide }
            end)
            table.insert(catchboxes, ok and info or { error = tostring(info) })
        end
    end
    local data = { schema = 15, build = "paged-report-snapshot-v15", placeId = tostring(game.PlaceId),
        placeVersion = tostring(game.PlaceVersion), elapsed = os.clock() - started,
        enabled = running, config = config, status = status.Text, lastError = runtimeError,
        input = { realTapsObserved = realTapCount, lastResult = lastInputResult,
            ignoredSyntheticTaps = ignoredSyntheticTaps,
            lastInjectedScreenPoint = lastInjectedScreenPoint and { x = lastInjectedScreenPoint.X, y = lastInjectedScreenPoint.Y },
            firesignalAvailable = type(firesignal) == "function",
            pressPending = pendingInput ~= nil, animationsNow = animationSnapshot and animationSnapshot() },
        callbackErrors = callbackErrors, attempts = attemptCount, totalEvents = eventCount,
        retainedEvents = #events, fieldPath = pathNodes, fieldChildren = fieldChildren,
        character = { exists = character ~= nil, rootFound = root ~= nil, humanoidFound = humanoid ~= nil,
            position = root and vector(root.Position), health = humanoid and humanoid.Health,
            seated = humanoid and humanoid.Sit },
        pendingMove = pendingMove and pendingMove.id or "none", activeBalls = balls,
        localCatchboxes = catchboxes, events = events,
        outcome = "Client observations only; catches not confirmed" }
    return data
end
local function buildResult()
    reportSerial = reportSerial + 1
    local ok, data = pcall(collectResult)
    if not ok then
        data = { schema = 15, build = "paged-report-snapshot-v15", collectionError = tostring(data),
            lastError = runtimeError, events = events, callbackErrors = callbackErrors, attempts = attemptCount }
    end
    data.reportId = string.format("v15-%d-%.3f", reportSerial, os.clock() - started)
    data.manualTestCount = manualTestCount
    return encodeResult(data)
end
local latestReportText, reportPage, reportPageCount = "", 1, 1
local reportCaption = label("No report yet", 0, 148, 210, 18)
reportCaption.Visible, reportCaption.TextSize = false, 10
local previousPage, nextPage, refreshReport
local function renderReportPage()
    local pageSize = 1600
    reportPageCount = math.max(1, math.ceil(#latestReportText / pageSize))
    reportPage = math.clamp(reportPage, 1, reportPageCount)
    local first = (reportPage - 1) * pageSize + 1
    local last = math.min(#latestReportText, reportPage * pageSize)
    -- UTF-8 boundaries may overlap by a few bytes across pages; never display broken characters.
    if utf8 and utf8.offset and #latestReportText > 0 then
        local ok, boundary = pcall(utf8.offset, latestReportText, 0, first)
        if ok and boundary then first = boundary end
        if last < #latestReportText then
            ok, boundary = pcall(utf8.offset, latestReportText, 0, last + 1)
            if ok and boundary then last = boundary - 1 end
        end
    end
    report.Text = latestReportText:sub(first, last)
    reportCaption.Text = "Snapshot #" .. reportSerial .. " · page " .. reportPage .. "/" .. reportPageCount
    if previousPage then previousPage.Visible = report.Visible and reportPageCount > 1 end
    if nextPage then nextPage.Visible = report.Visible and reportPageCount > 1 end
end
local function showResult(text, focus)
    latestReportText, reportPage = text, 1
    report.Visible, reportCaption.Visible = true, true
    if refreshReport then refreshReport.Visible = true end
    renderReportPage()
    if focus == false then return end
    report:CaptureFocus()
    pcall(function()
        report.CursorPosition = #report.Text + 1
        report.SelectionStart = 1
    end)
end
previousPage = button("‹", 0, 304, 36, 24, function() reportPage = reportPage - 1; renderReportPage() end)
nextPage = button("›", 42, 304, 36, 24, function() reportPage = reportPage + 1; renderReportPage() end)
refreshReport = button("Refresh", 86, 304, 124, 24, function() publishResult() end)
previousPage.Name, nextPage.Name, refreshReport.Name = "PreviousReportPage", "NextReportPage", "RefreshReport"
previousPage.Visible, nextPage.Visible, refreshReport.Visible = false, false, false

button("…", 146, 4, 24, 24, function()
    if report.Visible then
        report.Visible, reportCaption.Visible = false, false
        previousPage.Visible, nextPage.Visible, refreshReport.Visible = false, false, false
    else showResult(buildResult(), false) end
end)
local copyButton, testCopyButton
publishResult = function()
    local ok, text = pcall(buildResult)
    if not ok then
        text = "UF COPY RESULT v15\nREPORT ERROR: " .. tostring(text)
            .. "\nLast callback error: " .. tostring(runtimeError)
    end
    -- The displayed text is authoritative even if the executor clipboard stays stale.
    showResult(text, false)
    local clipboardError
    for _, name in ipairs({ "setclipboard", "toclipboard" }) do
        local writer = name == "setclipboard" and setclipboard or toclipboard
        if type(writer) == "function" then
            local ok, result = pcall(writer, text)
            if ok and result ~= false then
                copyButton.Text = "Copy sent"
                if testCopyButton then testCopyButton.Text = "Report #" .. reportSerial .. " ready" end
                return
            end
            clipboardError = tostring(result)
        end
    end
    showResult(text .. (clipboardError and ("\nClipboard error: " .. clipboardError) or ""))
    copyButton.Text = "Select text below to copy"
    if testCopyButton then testCopyButton.Text = "Report #" .. reportSerial .. " below" end
end
copyButton = button("Copy", 150, 110, 48, 24, publishResult)
copyButton.Name, copyButton.TextSize, copyButton.TextScaled = "CopyResult", 10, true
-- One activation runs the input test and exports after its release/animation probe.
testCopyButton = button("TEST + COPY", 12, 110, 130, 24, function()
    manualTestCount = manualTestCount + 1
    local test = manualTestCount
    testCopyButton.Text = "Testing #" .. test .. "…"
    showResult("Running input test #" .. test .. "…\nPreparing report; wait one second.", false)
    reportCaption.Text = "Testing #" .. test .. " · report pending"
    pcall(function() report:ReleaseFocus() end)
    emit("ui_test_requested", nil, { test = test })
    -- Schedule before attempting input, independently of the tracking heartbeat.
    scheduledReport = test
    task.delay(0.5, function()
        if closed or scheduledReport ~= test then return end
        scheduledReport = nil
        local ok, err = pcall(publishResult)
        if not ok then
            showResult("UF COPY RESULT v15\nREPORT ERROR: " .. tostring(err), false)
            testCopyButton.Text = "Error shown below"
        end
    end)
    local ok, err = pcall(requestCatchTap, nil, "manual_input_test")
    if not ok then
        runtimeError = tostring(err)
        emit("manual_input_test_error", nil, { error = runtimeError })
    end
end)
testCopyButton.Name = "TestAndCopy"
local function cleanup()
    if closed then return end
    closed = true
    scheduledReport = nil
    restoreMove("closed")
    disconnect(connections)
    for _, record in pairs(records) do disconnect(record.connections) end
    for _, entry in pairs(boxes) do disconnect(entry.connections) end
    table.clear(records)
    table.clear(boxes)
    table.clear(events)
    table.clear(callbackErrors)
    table.clear(inputAnimationProbes)
    gui:Destroy()
end
button("×", 174, 4, 24, 24, cleanup)
connect(shutdown.Event, cleanup)
connect(gui.Destroying, cleanup)
-- Header dragging is independent of slider dragging, for mouse and touch.
local drag, dragStart, frameStart
connect(title.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        drag, dragStart, frameStart = input, input.Position, frame.Position
    end
end)
connect(UserInputService.InputChanged, function(input)
    if drag and (input == drag or
        (drag.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)) then
        local delta = input.Position - dragStart
        local viewport = gui.AbsoluteSize
        frame.Position = UDim2.fromOffset(math.clamp(frameStart.X.Offset + delta.X, 0, math.max(0, viewport.X - 210)),
            math.clamp(frameStart.Y.Scale * viewport.Y + frameStart.Y.Offset + delta.Y, 0, math.max(0, viewport.Y - 142)))
    end
end)
connect(UserInputService.InputEnded, function(input) if input == drag then drag = nil end end)
local function tapHitsPanel(point)
    local position = frame.AbsolutePosition
    local height = report.Visible and 332 or 142
    return point.X >= position.X and point.X <= position.X + 210
        and point.Y >= position.Y and point.Y <= position.Y + height
end
connect(UserInputService.TouchTap, function(positions, processed)
    if os.clock() <= ignoreTapUntil then
        ignoredSyntheticTaps = ignoredSyntheticTaps + 1
        return
    end
    if not processed and not pendingMove and positions[1] and not tapHitsPanel(positions[1]) then
        lastRealTap, realTapCount = positions[1], realTapCount + 1
    end
end)
animationSnapshot = function()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
    if not animator then return { available = false, tracks = {} } end
    local ok, tracks = pcall(function()
        local result = {}
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            table.insert(result, { name = track.Name, id = track.Animation and track.Animation.AnimationId,
                priority = tostring(track.Priority), playing = track.IsPlaying })
        end
        return result
    end)
    return { available = ok, tracks = ok and tracks or {}, error = not ok and tostring(tracks) or nil }
end
for _, name in ipairs({ "InputBegan", "InputEnded" }) do
    connect(UserInputService[name], function(input, processed)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            emit("engine_input_observed", nil, { event = name, type = tostring(input.UserInputType),
                state = tostring(input.UserInputState), processed = processed,
                injectionWindow = os.clock() <= ignoreTapUntil })
        end
    end)
end
requestCatchTap = function(saved, source)
    if closed then return end
    if pendingInput then
        emit("catch_input_skipped", nil, { reason = "press_already_active", source = source })
        return
    end
    local record
    if source ~= "manual_input_test" then
        if not running or not saved or saved ~= pendingMove or saved.tapAttempted then return end
        record = records[saved.ball]
        if not record or record.associated or saved.humanoid.Health <= 0 then return end
        saved.tapAttempted = true -- Exactly one input attempt per movement attempt.
    end
    local viewport = gui.AbsoluteSize
    local beforeAnimations = animationSnapshot()
    local errors, dispatched, method = {}, false, "none"
    local insetOk, inset = pcall(function() return GuiService:GetGuiInset() end)
    if not insetOk then inset = Vector2.new(0, 0); table.insert(errors, "GUI inset unavailable") end
    local point, screenPoint
    local targetChecks = {}
    local coreOk, core = pcall(function() return game:GetService("CoreGui") end)
    -- Recorded taps may have come from game controls; never use them as injection targets.
    for _, candidate in ipairs({ Vector2.new(viewport.X * 0.5, viewport.Y * 0.5),
        Vector2.new(viewport.X * 0.6, viewport.Y * 0.45), Vector2.new(viewport.X * 0.4, viewport.Y * 0.55),
        Vector2.new(viewport.X * 0.7, viewport.Y * 0.5), Vector2.new(viewport.X * 0.3, viewport.Y * 0.5) }) do
        local screen = Vector2.new(candidate.X + inset.X, candidate.Y + inset.Y)
        local check = { point = { x = screen.X, y = screen.Y }, hits = {}, blockers = {},
            playerGuiInspected = false, coreGuiInspected = false }
        if tapHitsPanel(candidate) then table.insert(check.blockers, "UF tracker panel") end
        local function inspect(container, field)
            local ok, hits = pcall(function() return container:GetGuiObjectsAtPosition(screen.X, screen.Y) end)
            check[field] = ok
            if not ok then return end
            for i, object in ipairs(hits) do
                if i > 16 then break end
                local path = object:GetFullName()
                local blocking = object.Visible and (object.Active or object:IsA("TextButton")
                    or object:IsA("ImageButton") or object:IsA("TextBox"))
                table.insert(check.hits, { path = path, class = object.ClassName, active = object.Active,
                    visible = object.Visible, blocking = blocking })
                if blocking then table.insert(check.blockers, path) end
            end
        end
        inspect(playerGui, "playerGuiInspected")
        if coreOk and core then inspect(core, "coreGuiInspected") end
        table.insert(targetChecks, check)
        if #check.blockers == 0 then point, screenPoint = candidate, screen; break end
    end
    if point then
        ignoreTapUntil = os.clock() + 0.35
        lastInjectedScreenPoint = screenPoint
        local ok, service = pcall(function() return game:GetService("VirtualInputManager") end)
        if ok and service then
            -- Engine touch start/end, as used by Roblox's input testing library.
            -- These internal APIs may be unavailable at the executor's permission level.
            local touchId = 123456 + heartbeatIndex
            local down, downError = pcall(function() service:SendTouchEvent(touchId, 0, screenPoint.X, screenPoint.Y) end)
            dispatched, method = down, "VirtualInputManager_touch"
            local release = function() service:SendTouchEvent(touchId, 2, screenPoint.X, screenPoint.Y) end
            if not down then
                table.insert(errors, tostring(downError))
                local mouseDown, mouseDownError = pcall(function() service:SendMouseButtonEvent(screenPoint.X, screenPoint.Y, 0, true, game, 0) end)
                dispatched, method = mouseDown, "VirtualInputManager_mouse"
                release = function() service:SendMouseButtonEvent(screenPoint.X, screenPoint.Y, 0, false, game, 0) end
                if not mouseDown then table.insert(errors, tostring(mouseDownError)) end
            end
            if dispatched then
                pendingInput = { record = record, method = method, startedAt = os.clock(),
                    releaseAt = os.clock() + config.tapHoldSeconds, release = release }
            end
        else table.insert(errors, tostring(service)) end
    else table.insert(errors, "All central tap targets overlap active UI") end
    lastInputResult = dispatched and ("dispatched_" .. method) or "unsupported_or_blocked"
    if #inputAnimationProbes >= 8 then table.remove(inputAnimationProbes, 1) end
    table.insert(inputAnimationProbes, { at = os.clock() + 0.25, record = record,
        source = source, method = method, before = beforeAnimations })
    emit("catch_input", record, { source = source, method = method, dispatched = dispatched,
        point = point and { x = point.X, y = point.Y },
        screenPoint = screenPoint and { x = screenPoint.X, y = screenPoint.Y },
        guiInset = { x = inset.X, y = inset.Y }, targetChecks = targetChecks, errors = errors,
        result = lastInputResult, outcome = "Input dispatch does not prove catch activation" })
end
local function updatePendingMove(now)
    local saved = pendingMove
    if not saved then return end
    if not running or closed then restoreMove("disabled"); return end
    if player.Character ~= saved.character or not saved.root:IsDescendantOf(saved.character)
        or saved.humanoid.Health <= 0 or saved.humanoid.Sit then
        restoreMove("character_unavailable"); return
    end
    local record = records[saved.ball]
    if not record or not saved.ball:IsDescendantOf(Workspace) then restoreMove("ball_ended"); return end
    if record.associated then
        restoreMove(record.associatedWith == player.Name and "local_player_association" or "other_player_association")
        return
    end
    if saved.ball.Anchored then restoreMove("ball_anchored"); return end
    local elapsed = now - saved.attemptAt
    if elapsed >= config.approachSeconds + config.holdSeconds then restoreMove("hold_completed"); return end
    local alpha = math.clamp(elapsed / config.approachSeconds, 0, 1)
    local target = CFrame.new(saved.ball.Position - saved.catchOffset) * saved.cframe.Rotation
    local ok, err = pcall(function()
        -- Track the live ball instead of a position that is already one frame old.
        saved.root.CFrame = saved.cframe:Lerp(target, alpha)
        saved.root.AssemblyLinearVelocity = Vector3.zero
        saved.root.AssemblyAngularVelocity = Vector3.zero
    end)
    if not ok then
        emit("catch_movement_error", record, { error = tostring(err) })
        restoreMove("movement_error")
        return
    end
    if not saved.moved then
        saved.moved = true
        emit("catch_movement_started", record, { localMoveApplied = true, elapsed = elapsed })
    end
    if alpha >= 1 and not saved.arrived then
        saved.arrived = true
        emit("catch_arrived", record, { elapsed = elapsed, rootPosition = vector(saved.root.Position),
            ballPosition = vector(saved.ball.Position), catchOffset = vector(saved.catchOffset) })
        requestCatchTap(saved, "arrival_fallback")
    end
end
connect(player.CharacterRemoving, function() restoreMove("character_removing") end)
connect(boundary.Event, function(payload)
    if closed or not running then return end
    if pendingMove then
        emit("catch_attempt_skipped", nil, { id = payload.id, reason = "another_attempt_active" })
        return
    end
    local ball = payload.instance
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local record = records[ball]
    local reason
    if not root then reason = "no_root"
    elseif not humanoid then reason = "no_humanoid"
    elseif humanoid.Health <= 0 then reason = "dead"
    elseif humanoid.Sit then reason = "seated"
    elseif not record then reason = "ball_not_registered"
    elseif record.associated then reason = "player_associated"
    elseif ball.Anchored then reason = "anchored"
    elseif not ball:IsDescendantOf(Workspace) then reason = "outside_workspace" end
    if reason then
        emit("catch_attempt_skipped", record, { id = payload.id, reason = reason })
        return
    end
    local catchOffset = Vector3.zero
    local catchboxPath
    for box, entry in pairs(boxes) do
        if entry.owner == player.Name and validBox(box) then
            catchOffset, catchboxPath = box.Position - root.Position, box:GetFullName()
            break
        end
    end
    pendingMove = { id = payload.id, character = character, root = root, humanoid = humanoid,
        attemptAt = os.clock(), heartbeat = heartbeatIndex, ball = ball, record = record, catchOffset = catchOffset,
        cframe = root.CFrame, linear = root.AssemblyLinearVelocity, angular = root.AssemblyAngularVelocity }
    attemptCount = attemptCount + 1
    resetBoundaries()
    emit("catch_attempt", record, { position = vector(ball.Position), movementPending = true,
        approachSeconds = config.approachSeconds, holdSeconds = config.holdSeconds,
        catchboxPath = catchboxPath, catchOffset = vector(catchOffset),
        catchInput = "Attempt screen tap at first local contact or arrival", outcome = "unconfirmed" })
end)
connect(Workspace.DescendantAdded, function(item)
    if item.Name == "Football" then registerBall(item)
    elseif item.Name == "CatchBox" then registerBox(item) end
end)
-- A single callback advances the slower approach/hold and then samples detection.
connect(RunService.Heartbeat, function()
    heartbeatIndex = heartbeatIndex + 1
    local now = os.clock()
    if pendingInput and now >= pendingInput.releaseAt then releaseInput("hold_elapsed") end
    for i = #inputAnimationProbes, 1, -1 do
        local probe = inputAnimationProbes[i]
        if now >= probe.at then
            emit("input_animation_probe", probe.record, { source = probe.source, method = probe.method,
                before = probe.before, after = animationSnapshot() })
            table.remove(inputAnimationProbes, i)
        end
    end
    updatePendingMove(now)
    if now - lastDiscovery >= 1 then lastDiscovery = now; discover() end
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    orb.Adornee, orb.Radius, orb.Visible = root, config.radius, visible and root ~= nil
    if now - lastSample < 1 / config.sampleHz then return end
    lastSample = now
    local nearest, nearestDistance, nearestRecord
    for ball, record in pairs(records) do
        local position, velocity = ball.Position, ball.AssemblyLinearVelocity
        local dt = record.time and now - record.time
        local derived = dt and dt > 0 and (position - record.position).Magnitude / dt or nil
        local jump = derived and derived > config.jumpSpeed
        if jump then emit("discontinuity", record, { derivedSpeed = derived, physicsSpeed = velocity.Magnitude }) end
        record.position, record.time, record.derivedSpeed = position, now, derived
        if running and root and ball:IsDescendantOf(Workspace) and not record.associated then
            local relative = position - root.Position
            local distance = relative.Magnitude
            record.minDistance = math.min(record.minDistance or math.huge, distance)
            if not nearestDistance or distance < nearestDistance then
                nearest, nearestDistance, nearestRecord = ball, distance, record
            end
            local rootJump = dt and record.rootPosition and (root.Position - record.rootPosition).Magnitude / dt > config.jumpSpeed
            local eligible = not ball.Anchored and velocity.Magnitude > 5
            local validSegment = dt ~= nil and dt <= 0.25 and record.rootRef == root
            setGate(record, record.triggered and "already_triggered" or (jump and "ball_position_jump"
                or (rootJump and "player_position_jump" or (ball.Anchored and "anchored"
                or (not eligible and "speed_at_or_below_5" or "outside_orb")))))
            if not pendingMove and not record.triggered and not jump and not rootJump and eligible
                and entersOrb(record.relative, relative, config.radius, validSegment) then
                record.triggered, record.state = true, "APPROACHING"
                setGate(record, "boundary_triggered")
                local payload = { instance = ball, id = record.id, position = position, velocity = velocity,
                    distance = distance, timestamp = now - started }
                emit("boundary_crossed", record, { snapshot = snapshot(ball), distance = distance,
                    derivedSpeed = derived })
                boundary:Fire(payload)
            elseif record.state == "DISCOVERED" and eligible then record.state = "AIRBORNE" end
            record.relative, record.rootPosition, record.rootRef = relative, root.Position, root
        else
            setGate(record, not running and "disabled" or (not root and "no_root"
                or (record.associated and "player_associated" or "outside_workspace")))
            record.relative, record.rootPosition = nil, nil
        end
    end
    if now - lastUi >= 0.2 then
        lastUi = now
        status.Text = runtimeError and ("ERROR · " .. runtimeError) or (pendingMove
            and (pendingMove.arrived and "Holding at ball · tries " or "Approaching ball · tries ") .. attemptCount or (not running and "OFF · orb disabled" or (nearestRecord
            and string.format("%s %.0f studs · tries %d", nearestRecord.id, nearestDistance, attemptCount)
            or (fieldContainer() and ("No ball · tries " .. attemptCount) or "UF match path not found"))))
    end
end)
discover()
emit("started", nil, { radius = config.radius, sampleHz = config.sampleHz })

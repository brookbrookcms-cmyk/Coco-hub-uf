-- UF tracking foundation. Observations only; no movement or remote calls.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
assert(player, "UF Tracker requires a client")
local playerGui = player:WaitForChild("PlayerGui")
local previous = playerGui:FindFirstChild("UFTracker")
if previous then
    local shutdown = previous:FindFirstChild("Shutdown")
    if shutdown and shutdown:IsA("BindableEvent") then shutdown:Fire() end
    previous:Destroy()
end

local config = { radius = 20, sampleHz = 30, jumpSpeed = 250, maxEvents = 400 }
local running, closed, visible = true, false, true
local records, boxes, connections, events = {}, {}, {}, {}
local nextId, eventCount, lastSample, lastDiscovery, lastUi = 0, 0, 0, 0, 0
local started = os.clock()
local boundary = Instance.new("BindableEvent")
boundary.Name = "BoundaryCrossed"
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.ZIndexBehavior = "UFTracker", false, Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui
boundary.Parent = gui
local shutdown = Instance.new("BindableEvent")
shutdown.Name, shutdown.Parent = "Shutdown", gui
local function connect(signal, fn, bucket)
    local connection = signal:Connect(fn)
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
        record.associated = record.associated or association(ball) ~= nil
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
        end
    end, record.connections)
    record.discoveredAt = os.clock()
    connect(ball.Destroying, function()
        record.state = "ENDED"
        emit("destroyed", record, snapshot(ball))
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
local orb = Instance.new("SphereHandleAdornment")
orb.Name, orb.Color3, orb.Transparency = "UFDetectionOrb", Color3.fromRGB(175, 70, 255), 0.85
orb.AlwaysOnTop, orb.ZIndex, orb.Parent = false, 0, gui

local frame = Instance.new("Frame")
frame.Size, frame.Position = UDim2.fromOffset(210, 112), UDim2.new(0, 16, 0.2, 0)
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
local title = label("UF · ORB", 12, 4, 120, 26)
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
local status = label("Waiting for football", 12, 88, 186, 18)
status.TextSize = 10
local report = Instance.new("TextBox")
report.Size, report.Position = UDim2.fromOffset(210, 130), UDim2.fromOffset(0, 118)
report.MultiLine, report.ClearTextOnFocus, report.TextEditable = true, false, true
report.TextSize, report.TextColor3, report.BackgroundColor3 = 11, Color3.new(1, 1, 1), Color3.fromRGB(30, 25, 40)
report.TextWrapped, report.Visible, report.Parent = true, false, frame
button("…", 146, 4, 24, 24, function()
    report.Text = HttpService:JSONEncode({ version = 1, config = config, totalEvents = eventCount,
        retainedEvents = #events, outcomes = "Unconfirmed client observations", events = events })
    report.Visible = not report.Visible
    if report.Visible then report:CaptureFocus() end
end)
local function cleanup()
    if closed then return end
    closed = true
    disconnect(connections)
    for _, record in pairs(records) do disconnect(record.connections) end
    for _, entry in pairs(boxes) do disconnect(entry.connections) end
    table.clear(records)
    table.clear(boxes)
    table.clear(events)
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
            math.clamp(frameStart.Y.Scale * viewport.Y + frameStart.Y.Offset + delta.Y, 0, math.max(0, viewport.Y - 112)))
    end
end)
connect(UserInputService.InputEnded, function(input) if input == drag then drag = nil end end)
connect(Workspace.DescendantAdded, function(item)
    if item.Name == "Football" then registerBall(item)
    elseif item.Name == "CatchBox" then registerBox(item) end
end)
connect(RunService.Heartbeat, function()
    local now = os.clock()
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
        record.position, record.time = position, now
        if running and root and ball:IsDescendantOf(Workspace) and not record.associated then
            local relative = position - root.Position
            local distance = relative.Magnitude
            if not nearestDistance or distance < nearestDistance then
                nearest, nearestDistance, nearestRecord = ball, distance, record
            end
            local rootJump = dt and record.rootPosition and (root.Position - record.rootPosition).Magnitude / dt > config.jumpSpeed
            local eligible = not ball.Anchored and velocity.Magnitude > 5
            if not record.triggered and record.relative and record.relative.Magnitude > config.radius
                and dt and dt <= 0.25 and record.rootRef == root
                and not jump and not rootJump and eligible
                and segmentDistance(record.relative, relative) <= config.radius then
                record.triggered, record.state = true, "APPROACHING"
                local payload = { instance = ball, id = record.id, position = position, velocity = velocity,
                    distance = distance, timestamp = now - started }
                emit("boundary_crossed", record, { snapshot = snapshot(ball), distance = distance,
                    derivedSpeed = derived })
                boundary:Fire(payload)
            elseif record.state == "DISCOVERED" and eligible then record.state = "AIRBORNE" end
            record.relative, record.rootPosition, record.rootRef = relative, root.Position, root
        else record.relative, record.rootPosition = nil, nil end
    end
    if now - lastUi >= 0.2 then
        lastUi = now
        status.Text = not running and "OFF · orb disabled" or (nearestRecord
            and string.format("%s · %.1f studs", nearestRecord.id, nearestDistance)
            or (fieldContainer() and "Waiting for football" or "Waiting for UF match"))
    end
end)
discover()
emit("started", nil, { radius = config.radius, sampleHz = config.sampleHz })

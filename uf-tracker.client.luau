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
frame.Size, frame.Position = UDim2.fromOffset(310, 300), UDim2.new(0, 16, 0.2, 0)
frame.BackgroundColor3, frame.Parent = Color3.fromRGB(22, 18, 30), gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 12)
local function label(text, y, height)
    local item = Instance.new("TextLabel")
    item.Size, item.Position = UDim2.new(1, -24, 0, height), UDim2.fromOffset(12, y)
    item.BackgroundTransparency, item.TextColor3 = 1, Color3.fromRGB(235, 225, 250)
    item.Font, item.TextSize, item.TextWrapped = Enum.Font.Gotham, 14, true
    item.Text, item.Parent = text, frame
    return item
end
local title = label("UF · FOOTBALL TRACKER", 8, 32)
title.Active = true
local status = label("Waiting for match structure", 44, 85)
local function button(text, x, y, width, fn)
    local item = Instance.new("TextButton")
    item.Text, item.Size, item.Position = text, UDim2.fromOffset(width, 34), UDim2.fromOffset(x, y)
    item.BackgroundColor3, item.TextColor3 = Color3.fromRGB(85, 40, 120), Color3.new(1, 1, 1)
    item.Font, item.TextSize, item.Parent = Enum.Font.Gotham, 13, frame
    Instance.new("UICorner", item)
    connect(item.Activated, fn)
    return item
end
local radiusLabel = label("Orb radius: 20 studs", 130, 24)
local function radius(delta)
    config.radius = math.clamp(config.radius + delta, 5, 100)
    radiusLabel.Text = "Orb radius: " .. config.radius .. " studs"
    for _, record in pairs(records) do record.relative = nil end
end
button("−5", 12, 160, 65, function() radius(-5) end)
button("+5", 85, 160, 65, function() radius(5) end)
button("Orb", 158, 160, 65, function() visible = not visible end)
local pause
pause = button("Pause", 12, 202, 90, function()
    running = not running
    pause.Text = running and "Pause" or "Resume"
    for _, record in pairs(records) do record.relative = nil end
end)
local report = Instance.new("TextBox")
report.Size, report.Position = UDim2.fromOffset(286, 100), UDim2.fromOffset(12, 300)
report.MultiLine, report.ClearTextOnFocus, report.TextEditable = true, false, true
report.TextSize, report.TextColor3, report.BackgroundColor3 = 12, Color3.new(1, 1, 1), Color3.fromRGB(30, 25, 40)
report.TextWrapped, report.Visible, report.Parent = true, false, frame
button("Report", 110, 202, 90, function()
    report.Text = HttpService:JSONEncode({ version = 1, config = config, totalEvents = eventCount,
        retainedEvents = #events, outcomes = "Unconfirmed client observations", events = events })
    report.Visible = not report.Visible
    frame.Size = UDim2.fromOffset(310, report.Visible and 412 or 300)
    if report.Visible then report:CaptureFocus() end
end)
local reopen = Instance.new("TextButton")
reopen.Text, reopen.Size, reopen.Position = "UF", UDim2.fromOffset(48, 40), UDim2.fromOffset(16, 100)
reopen.Visible, reopen.Parent = false, gui
connect(reopen.Activated, function() frame.Visible, reopen.Visible = true, false end)
button("Hide", 208, 202, 90, function() frame.Visible, reopen.Visible = false, true end)
label("Report opens selectable text. Contacts ≠ catches.", 242, 24)
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
button("Close", 208, 268, 90, cleanup)
connect(shutdown.Event, cleanup)
connect(gui.Destroying, cleanup)
-- Drag from title with either mouse or a single touch.
local drag, dragStart, frameStart
connect(title.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        drag, dragStart, frameStart = input, input.Position, frame.Position
    end
end)
connect(UserInputService.InputChanged, function(input)
    if drag and (input == drag or input.UserInputType == Enum.UserInputType.MouseMovement) then
        local delta = input.Position - dragStart
        local viewport = gui.AbsoluteSize
        frame.Position = UDim2.fromOffset(math.clamp(frameStart.X.Offset + delta.X, 0, math.max(0, viewport.X - 310)),
            math.clamp(frameStart.Y.Scale * viewport.Y + frameStart.Y.Offset + delta.Y, 0, math.max(0, viewport.Y - 40)))
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
        status.Text = string.format("%s · %d events\n%s\n%s", running and "Tracking" or "Paused", eventCount,
            nearestRecord and (nearestRecord.id .. " · " .. nearestRecord.state) or "No eligible football / character",
            nearestDistance and string.format("%.1f studs · %.1f studs/s", nearestDistance, nearest.AssemblyLinearVelocity.Magnitude)
                or (fieldContainer() and "Match structure found" or "Waiting for observed UF match hierarchy"))
    end
end)
discover()
emit("started", nil, { radius = config.radius, sampleHz = config.sampleHz })

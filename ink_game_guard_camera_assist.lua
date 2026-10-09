-- Ink Game Guard Camera Assist
-- Marker-based targeting, configurable input, single-target snapline.
-- Client-side only. Does not alter server weapon permissions.

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local env = (getgenv and getgenv()) or _G

if env.UnloadCameraAssist then
    pcall(env.UnloadCameraAssist)
end

local config = {
    Enabled = false,
    FOV = 70,
    Smoothness = 1,
    MaxDistance = 1000,
    HitPart = "Head",
    TeamCheck = true,
    WallCheck = true,
    ShowFOV = true,
    Snaplines = false,
    Priority = "Crosshair",
    AimOrigin = "Center", -- best starting point for the G3SG1 scope
    GUIKey = Enum.KeyCode.RightAlt,
    AimKey = Enum.UserInputType.MouseButton2
}

local connections = {}
local markers = {} -- only GuardCanKillLockOn objects; no per-frame world scan
local unloaded = false
local aimHeld = false
local capturing = nil -- "gui" / "aim" / nil
local didAcquireThisHold = false
local lockedMarker, lockedPart = nil, nil
local previewMarker, previewPart = nil, nil
local previewAccumulator = 0
local lockAccumulator = 0
local previewInterval = 0.10
local lockCheckInterval = 0.05
local renderName = "InkGuardCameraAssistRender"

local function connect(signal, fn)
    local conn = signal:Connect(fn)
    table.insert(connections, conn)
    return conn
end

local function create(class, properties, parent)
    local obj = Instance.new(class)
    for prop, value in pairs(properties) do
        obj[prop] = value
    end
    obj.Parent = parent
    return obj
end

-- All interface objects are destroyed together on unload.
local gui = create("ScreenGui", {
    Name = "InkGuardCameraAssist",
    IgnoreGuiInset = true,
    ResetOnSpawn = false,
    DisplayOrder = 100,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling
}, player:WaitForChild("PlayerGui"))

local fovCircle = create("Frame", {
    Name = "FOVCircle",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Size = UDim2.fromOffset(config.FOV * 2, config.FOV * 2),
    BackgroundTransparency = 1,
    Visible = config.ShowFOV,
    ZIndex = 1
}, gui)
create("UICorner", {CornerRadius = UDim.new(1, 0)}, fovCircle)
create("UIStroke", {
    Color = Color3.fromRGB(95, 170, 255),
    Thickness = 2,
    Transparency = 0.15
}, fovCircle)

local snapline = create("Frame", {
    Name = "SingleTargetSnapline",
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = Color3.fromRGB(90, 170, 255),
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 2
}, gui)

local main = create("Frame", {
    Name = "Menu",
    Size = UDim2.fromOffset(310, 540),
    Position = UDim2.new(0.5, -155, 0.5, -270),
    BackgroundColor3 = Color3.fromRGB(21, 23, 31),
    BorderSizePixel = 0,
    Active = true,
    ZIndex = 5
}, gui)
create("UICorner", {CornerRadius = UDim.new(0, 10)}, main)
create("UIStroke", {
    Color = Color3.fromRGB(55, 65, 85),
    Thickness = 1
}, main)

local header = create("Frame", {
    Size = UDim2.new(1, 0, 0, 43),
    BackgroundTransparency = 1,
    Active = true,
    ZIndex = 6
}, main)
create("TextLabel", {
    Position = UDim2.fromOffset(13, 0),
    Size = UDim2.new(1, -60, 1, 0),
    BackgroundTransparency = 1,
    Text = "INK GUARD ASSIST",
    TextColor3 = Color3.fromRGB(120, 185, 255),
    TextSize = 16,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 6
}, header)

local close = create("TextButton", {
    Position = UDim2.new(1, -39, 0, 7),
    Size = UDim2.fromOffset(30, 28),
    BackgroundColor3 = Color3.fromRGB(150, 45, 55),
    Text = "X",
    TextColor3 = Color3.new(1, 1, 1),
    TextSize = 14,
    Font = Enum.Font.GothamBold,
    ZIndex = 7
}, header)
create("UICorner", {CornerRadius = UDim.new(0, 6)}, close)

local content = create("ScrollingFrame", {
    Position = UDim2.fromOffset(12, 47),
    Size = UDim2.new(1, -24, 1, -58),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ZIndex = 6
}, main)
create("UIListLayout", {
    Padding = UDim.new(0, 9),
    SortOrder = Enum.SortOrder.LayoutOrder
}, content)

local function resetHold()
    aimHeld = false
    didAcquireThisHold = false
    lockedMarker, lockedPart = nil, nil
end

local function unload()
    if unloaded then return end
    unloaded = true
    resetHold()
    RunService:UnbindFromRenderStep(renderName)
    for _, conn in ipairs(connections) do
        conn:Disconnect()
    end
    table.clear(connections)
    table.clear(markers)
    gui:Destroy()
    if env.UnloadCameraAssist == unload then
        env.UnloadCameraAssist = nil
    end
end

env.UnloadCameraAssist = unload
connect(close.MouseButton1Click, unload)

-- GUI controls
local function createButton(getText, callback)
    local button = create("TextButton", {
        Size = UDim2.new(1, -4, 0, 32),
        BackgroundColor3 = Color3.fromRGB(39, 43, 56),
        TextColor3 = Color3.fromRGB(240, 242, 250),
        TextSize = 12,
        Font = Enum.Font.GothamMedium,
        Text = getText(),
        ZIndex = 7
    }, content)
    create("UICorner", {CornerRadius = UDim.new(0, 6)}, button)
    connect(button.MouseButton1Click, function()
        callback(button)
        if capturing == nil then
            button.Text = getText()
        end
    end)
    return button
end

local function toggleButton(label, key)
    return createButton(function()
        return label .. ": " .. (config[key] and "ON" or "OFF")
    end, function()
        config[key] = not config[key]
        if key == "Enabled" and not config.Enabled then
            resetHold()
        end
    end)
end

local function createSlider(label, key, min, max, step)
    local frame = create("Frame", {
        Size = UDim2.new(1, -4, 0, 47),
        BackgroundTransparency = 1,
        ZIndex = 7
    }, content)
    local textLabel = create("TextLabel", {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        TextColor3 = Color3.fromRGB(235, 240, 250),
        TextSize = 12,
        Font = Enum.Font.GothamMedium,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 7
    }, frame)
    local track = create("Frame", {
        Position = UDim2.fromOffset(0, 31),
        Size = UDim2.new(1, 0, 0, 7),
        BackgroundColor3 = Color3.fromRGB(55, 60, 78),
        BorderSizePixel = 0,
        ZIndex = 7
    }, frame)
    create("UICorner", {CornerRadius = UDim.new(1, 0)}, track)
    local fill = create("Frame", {
        BackgroundColor3 = Color3.fromRGB(90, 160, 255),
        BorderSizePixel = 0,
        ZIndex = 8
    }, track)
    create("UICorner", {CornerRadius = UDim.new(1, 0)}, fill)
    local knob = create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(15, 15),
        BackgroundColor3 = Color3.fromRGB(215, 230, 255),
        BorderSizePixel = 0,
        ZIndex = 9
    }, track)
    create("UICorner", {CornerRadius = UDim.new(1, 0)}, knob)
    local hitbox = create("TextButton", {
        Position = UDim2.new(0, 0, 0, -10),
        Size = UDim2.new(1, 0, 1, 20),
        BackgroundTransparency = 1,
        Text = "",
        ZIndex = 10
    }, track)

    local dragging = false
    local function refresh()
        local value = config[key]
        local ratio = math.clamp((value - min) / (max - min), 0, 1)
        fill.Size = UDim2.new(ratio, 0, 1, 0)
        knob.Position = UDim2.new(ratio, 0, 0.5, 0)
        textLabel.Text = label .. ": " .. tostring(value)
    end
    local function updateFromX(x)
        local width = track.AbsoluteSize.X
        if width <= 0 then return end
        local ratio = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
        local raw = min + ratio * (max - min)
        local value = min + math.floor((raw - min) / step + 0.5) * step
        config[key] = math.clamp(value, min, max)
        refresh()
    end
    connect(hitbox.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            updateFromX(input.Position.X)
        end
    end)
    connect(UIS.InputChanged, function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            updateFromX(input.Position.X)
        end
    end)
    connect(UIS.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)
    refresh()
end

toggleButton("Aimbot", "Enabled")
createSlider("FOV Radius", "FOV", 25, 500, 5)
createSlider("Smoothness", "Smoothness", 1, 20, 1)
createSlider("Max Distance", "MaxDistance", 50, 2000, 50)

local hitParts = {"Head", "HumanoidRootPart", "UpperTorso", "Torso"}
createButton(function()
    return "Hit Part: " .. config.HitPart
end, function()
    local index = table.find(hitParts, config.HitPart) or 1
    config.HitPart = hitParts[index % #hitParts + 1]
end)

toggleButton("Team Check", "TeamCheck")
toggleButton("Wall Check", "WallCheck")
toggleButton("Show FOV", "ShowFOV")
toggleButton("Snaplines", "Snaplines")

createButton(function()
    return "Priority: " .. config.Priority
end, function()
    config.Priority = config.Priority == "Crosshair" and "Distance" or "Crosshair"
end)

createButton(function()
    return "Crosshair Origin: " .. config.AimOrigin
end, function()
    config.AimOrigin = config.AimOrigin == "Center" and "Mouse" or "Center"
    previewAccumulator = previewInterval
end)

local guiKeyButton = createButton(function()
    return "GUI Key: " .. config.GUIKey.Name
end, function(button)
    capturing = "gui"
    button.Text = "Press a GUI key..."
end)

local aimKeyButton = createButton(function()
    return "Aim Key: " .. config.AimKey.Name
end, function(button)
    capturing = "aim"
    button.Text = "Press a keyboard/mouse button..."
end)

local function isAimInput(input)
    return input.KeyCode == config.AimKey
        or input.UserInputType == config.AimKey
end

local function mouseOverMenu(pos)
    if not main.Visible then return false end
    local top = main.AbsolutePosition
    local size = main.AbsoluteSize
    return pos.X >= top.X and pos.X <= top.X + size.X
        and pos.Y >= top.Y and pos.Y <= top.Y + size.Y
end

-- Binding keys; ignore processed status for the scope's RMB input.
connect(UIS.InputBegan, function(input)
    if capturing == "gui" then
        if input.UserInputType == Enum.UserInputType.Keyboard
            and input.KeyCode ~= Enum.KeyCode.Unknown then
            config.GUIKey = input.KeyCode
            guiKeyButton.Text = "GUI Key: " .. config.GUIKey.Name
            capturing = nil
        end
        return
    elseif capturing == "aim" then
        local key
        if input.UserInputType == Enum.UserInputType.Keyboard
            and input.KeyCode ~= Enum.KeyCode.Unknown then
            key = input.KeyCode
        elseif input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.MouseButton2
            or input.UserInputType == Enum.UserInputType.MouseButton3 then
            key = input.UserInputType
        end
        if key then
            config.AimKey = key
            aimKeyButton.Text = "Aim Key: " .. config.AimKey.Name
            capturing = nil
            resetHold()
        end
        return
    end

    if input.KeyCode == config.GUIKey then
        main.Visible = not main.Visible
        return
    end
    if UIS:GetFocusedTextBox() then return end
    if isAimInput(input) then
        if input.UserInputType == Enum.UserInputType.MouseButton1
            and mouseOverMenu(input.Position) then
            return
        end
        aimHeld = true
    end
end)

connect(UIS.InputEnded, function(input)
    if isAimInput(input) then
        resetHold()
    end
end)

-- Dragging (the X button is separate from the header).
local draggingMenu = false
local dragStart, menuStart
connect(header.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        draggingMenu = true
        dragStart = input.Position
        menuStart = main.Position
    end
end)
connect(UIS.InputChanged, function(input)
    if draggingMenu and input.UserInputType == Enum.UserInputType.MouseMovement then
        local delta = input.Position - dragStart
        main.Position = UDim2.new(
            menuStart.X.Scale, menuStart.X.Offset + delta.X,
            menuStart.Y.Scale, menuStart.Y.Offset + delta.Y
        )
    end
end)
connect(UIS.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        draggingMenu = false
    end
end)

-- Marker cache: GUI objects come and go as players become shootable.
local MARKER_NAME = "GuardCanKillLockOn"
local function addMarker(obj)
    if obj.Name == MARKER_NAME and obj:IsA("BillboardGui") then
        markers[obj] = true
    end
end

connect(Workspace.DescendantAdded, addMarker)
connect(Workspace.DescendantRemoving, function(obj)
    markers[obj] = nil
    if lockedMarker == obj then
        lockedMarker, lockedPart = nil, nil
    end
    if previewMarker == obj then
        previewMarker, previewPart = nil, nil
    end
end)

-- Populate objects already present at execution time, with periodic yielding.
task.spawn(function()
    local descendants = Workspace:GetDescendants()
    for i, obj in ipairs(descendants) do
        if unloaded then return end
        addMarker(obj)
        if i % 400 == 0 then
            task.wait()
        end
    end
end)

local function getAimPoint(camera)
    if config.AimOrigin == "Mouse" then
        return UIS:GetMouseLocation()
    end
    return camera.ViewportSize / 2
end

local function getTargetPart(character, root)
    local part = character:FindFirstChild(config.HitPart)
        or character:FindFirstChild("Head")
        or root
    if part and part:IsA("BasePart") then
        return part
    end
    return nil
end

-- Return character and hit part only while the shootable marker is active.
local function resolveMarker(marker)
    if not marker or not markers[marker] then return nil end
    if not marker.Parent or not marker:IsDescendantOf(Workspace) then
        markers[marker] = nil
        return nil
    end
    if not marker.Enabled then return nil end

    local root = marker.Parent
    if not root:IsA("BasePart") then return nil end
    local character = root.Parent
    if not character or not character:IsA("Model") then return nil end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return nil end

    local timerLabel = marker:FindFirstChild("TextLabel", true)
    if timerLabel and timerLabel:IsA("TextLabel") then
        if not timerLabel.Visible then return nil end
        -- 0S / 0.0S counts as expired; missing numbers are allowed
        -- because some rounds may show the marker without a countdown.
        local time = tonumber(timerLabel.Text:match("%d+%.?%d*"))
        if time and time <= 0 then return nil end
    end

    local other = Players:GetPlayerFromCharacter(character)
    if other == player then return nil end
    if config.TeamCheck and other
        and player.Team ~= nil and other.Team == player.Team then
        return nil
    end

    return character, getTargetPart(character, root)
end

local function wallVisible(camera, character, part)
    if not config.WallCheck then return true end

    local excluded = {camera}
    if player.Character then
        table.insert(excluded, player.Character)
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = excluded

    local origin = camera.CFrame.Position
    local hit = Workspace:Raycast(origin, part.Position - origin, params)
    return not hit or hit.Instance:IsDescendantOf(character)
end

-- The only candidates are active GuardCanKillLockOn markers.
local function acquireTarget(camera)
    local origin = getAimPoint(camera)
    local candidates = {}

    for marker in pairs(markers) do
        local character, part = resolveMarker(marker)
        if not character or not part then continue end

        local distance = (camera.CFrame.Position - part.Position).Magnitude
        if distance > config.MaxDistance then continue end

        local point, visible = camera:WorldToViewportPoint(part.Position)
        if not visible or point.Z <= 0 then continue end

        local screenDistance = (Vector2.new(point.X, point.Y) - origin).Magnitude
        if screenDistance > config.FOV then continue end

        table.insert(candidates, {
            marker = marker,
            part = part,
            character = character,
            score = config.Priority == "Distance" and distance or screenDistance
        })
    end

    table.sort(candidates, function(a, b)
        return a.score < b.score
    end)

    for _, candidate in ipairs(candidates) do
        if wallVisible(camera, candidate.character, candidate.part) then
            return candidate.marker, candidate.part
        end
    end
    return nil, nil
end

local function updateSnapline(camera, point, part)
    snapline.Visible = false
    if not config.Snaplines or not part or not part.Parent then return end
    if not part:IsDescendantOf(Workspace) then return end
    local projected, visible = camera:WorldToViewportPoint(part.Position)
    if not visible or projected.Z <= 0 then return end

    local endPoint = Vector2.new(projected.X, projected.Y)
    local delta = endPoint - point
    snapline.Size = UDim2.fromOffset(delta.Magnitude, 2)
    snapline.Position = UDim2.fromOffset(
        (point.X + endPoint.X) / 2,
        (point.Y + endPoint.Y) / 2
    )
    snapline.Rotation = math.deg(math.atan2(delta.Y, delta.X))
    snapline.Visible = true
end

-- Runs after Roblox's usual camera update, for better scoped camera support.
RunService:BindToRenderStep(renderName, Enum.RenderPriority.Camera.Value + 100, function(dt)
    if unloaded then return end
    local camera = Workspace.CurrentCamera
    if not camera then return end

    local active = config.Enabled and aimHeld

    if active then
        if not didAcquireThisHold then
            lockedMarker, lockedPart = acquireTarget(camera)
            didAcquireThisHold = true
            lockAccumulator = 0
        end

        if lockedMarker then
            lockAccumulator += dt
            if lockAccumulator >= lockCheckInterval then
                lockAccumulator = 0
                local _, currentPart = resolveMarker(lockedMarker)
                if not currentPart then
                    lockedMarker, lockedPart = nil, nil
                else
                    lockedPart = currentPart
                end
            end
        end

        -- Never pick a second target during the same key hold.
        if lockedPart and lockedPart:IsDescendantOf(Workspace) then
            local current = camera.CFrame
            local desired = CFrame.lookAt(current.Position, lockedPart.Position)
            local alpha = config.Smoothness == 1
                and 1
                or (1 - math.exp(-dt * (60 / config.Smoothness)))
            camera.CFrame = current:Lerp(desired, alpha)
        end
    else
        lockedMarker, lockedPart = nil, nil
        didAcquireThisHold = false
        if config.Snaplines then
            previewAccumulator += dt
            if previewAccumulator >= previewInterval then
                previewAccumulator = 0
                previewMarker, previewPart = acquireTarget(camera)
            end
        else
            previewMarker, previewPart = nil, nil
        end
    end

    local aimPoint = getAimPoint(camera)
    fovCircle.Position = UDim2.fromOffset(aimPoint.X, aimPoint.Y)
    fovCircle.Size = UDim2.fromOffset(config.FOV * 2, config.FOV * 2)
    fovCircle.Visible = config.ShowFOV

    updateSnapline(camera, aimPoint, active and lockedPart or previewPart)
end)

print("[INK GUARD] Loaded. Menu: RightAlt | Aim: RMB")
print("[INK GUARD] Targeting only active GuardCanKillLockOn markers")
print("[INK GUARD] Center origin is recommended for G3SG1 scope")

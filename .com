-- Hello Kitty Lock v6.1 - Full Polished GUI + Silent Aim + ESP + Triggerbot

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()
local Camera = workspace.CurrentCamera
local RS = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")

-- Settings and states
local config = {
    CamlockPrediction = 0.1,
    CamlockFOV = 120,
    SilentAimFOV = 120,
    SilentAimPrediction = 0.1,
    ESPBoxes = true,
    ESPNames = true,
    ESPRainbowSpeed = 1,
    AutoJump = false,
    SpeedMultiplier = 1,
    Triggerbot = false,
    SoundFX = true,
}

local toggleStates = {
    Camlock = false,
    SilentAim = false,
    ESPBoxes = config.ESPBoxes,
    ESPNames = config.ESPNames,
    AutoJump = false,
    Speed = false,
    Triggerbot = false,
}

local camlockActive = false
local lockedTarget = nil

-- Load local saved config if any (basic)
local function loadConfig()
    local saved = LocalPlayer:FindFirstChild("HKLockConfig")
    if saved and saved:IsA("StringValue") then
        local success, data = pcall(function() return game:GetService("HttpService"):JSONDecode(saved.Value) end)
        if success and data then
            for k,v in pairs(data) do
                config[k] = v
                toggleStates[k] = v
            end
        end
    end
end

local function saveConfig()
    local HttpService = game:GetService("HttpService")
    local configStr = HttpService:JSONEncode(config)
    local saved = LocalPlayer:FindFirstChild("HKLockConfig")
    if not saved then
        saved = Instance.new("StringValue")
        saved.Name = "HKLockConfig"
        saved.Parent = LocalPlayer
    end
    saved.Value = configStr
end

-- Utility functions
local function createUICorner(parent, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius or 12)
    corner.Parent = parent
end

local function playSound(parent)
    if not config.SoundFX then return end
    local s = Instance.new("Sound", parent)
    s.SoundId = "rbxassetid://9118824604"
    s.Volume = 0.5
    s:Play()
    game:GetService("Debris"):AddItem(s, 2)
end

local function notify(title, text, duration)
    StarterGui:SetCore("SendNotification", {Title = title, Text = text, Duration = duration or 3})
end

local function findNearestPlayer(fov)
    local mousePos = UIS:GetMouseLocation()
    local closestPlayer = nil
    local shortestDist = fov or 120

    for _, player in pairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("HumanoidRootPart") and player.Character:FindFirstChild("Humanoid") and player.Character.Humanoid.Health > 0 then
            local hrp = player.Character.HumanoidRootPart
            local screenPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
            if onScreen then
                local dist = (Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude
                if dist < shortestDist then
                    shortestDist = dist
                    closestPlayer = player
                end
            end
        end
    end
    return closestPlayer
end

local function getClosestHitbox(player)
    -- Try to return HumanoidRootPart or Head as target hitbox for aiming
    if not player or not player.Character then return nil end
    local hrp = player.Character:FindFirstChild("HumanoidRootPart")
    local head = player.Character:FindFirstChild("Head")
    if hrp then return hrp end
    if head then return head end
    return nil
end

-- ESP Drawing
local ESPFolder = Instance.new("Folder")
ESPFolder.Name = "HKLockESP"
ESPFolder.Parent = LocalPlayer:WaitForChild("PlayerGui")

local ESPObjects = {}

local function createESPForPlayer(player)
    if ESPObjects[player] then return end

    local box = Drawing.new("Square")
    box.Visible = false
    box.Color = Color3.fromRGB(255, 105, 180)
    box.Thickness = 2
    box.Filled = false
    box.Transparency = 1

    local nameText = Drawing.new("Text")
    nameText.Visible = false
    nameText.Center = true
    nameText.Color = Color3.fromRGB(255, 105, 180)
    nameText.Size = 16
    nameText.Font = 2
    nameText.Outline = true

    ESPObjects[player] = {
        Box = box,
        Name = nameText,
    }
end

local function removeESPForPlayer(player)
    if ESPObjects[player] then
        ESPObjects[player].Box:Remove()
        ESPObjects[player].Name:Remove()
        ESPObjects[player] = nil
    end
end

-- Rainbow color helper
local function rainbowColor(t)
    local frequency = config.ESPRainbowSpeed
    local r = math.floor(math.sin(frequency * t + 0) * 127 + 128)
    local g = math.floor(math.sin(frequency * t + 2) * 127 + 128)
    local b = math.floor(math.sin(frequency * t + 4) * 127 + 128)
    return Color3.fromRGB(r, g, b)
end

-- Update ESP every frame
RS.RenderStepped:Connect(function(delta)
    local time = tick()
    for _, player in pairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("HumanoidRootPart") and player.Character:FindFirstChild("Humanoid") and player.Character.Humanoid.Health > 0 then
            createESPForPlayer(player)
            local hrp = player.Character.HumanoidRootPart
            local screenPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
            local esp = ESPObjects[player]
            if onScreen and toggleStates.ESPBoxes then
                local sizeFactor = 1500 / (Camera.CFrame.Position - hrp.Position).Magnitude
                esp.Box.Visible = true
                esp.Box.Size = Vector2.new(60 * sizeFactor, 80 * sizeFactor)
                esp.Box.Position = Vector2.new(screenPos.X - esp.Box.Size.X / 2, screenPos.Y - esp.Box.Size.Y / 2)
                esp.Box.Color = rainbowColor(time)
            else
                esp.Box.Visible = false
            end

            if onScreen and toggleStates.ESPNames then
                esp.Name.Visible = true
                esp.Name.Text = player.Name
                esp.Name.Position = Vector2.new(screenPos.X, screenPos.Y - 50)
                esp.Name.Color = rainbowColor(time)
            else
                esp.Name.Visible = false
            end
        else
            removeESPForPlayer(player)
        end
    end
end)

-- Silent Aim (camera aim assistance)
local function silentAim()
    if not toggleStates.SilentAim then return end
    local target = findNearestPlayer(config.SilentAimFOV)
    if not target or not target.Character then return end
    local hitbox = getClosestHitbox(target)
    if not hitbox then return end
    local predictedPos = hitbox.Position + (hitbox.Velocity * config.SilentAimPrediction)
    local cf = Camera.CFrame
    Camera.CFrame = CFrame.new(cf.Position, predictedPos)
end

-- Camlock loop (locks on activated target)
RS.RenderStepped:Connect(function()
    if toggleStates.Camlock and camlockActive and lockedTarget and lockedTarget.Character and lockedTarget.Character:FindFirstChild("HumanoidRootPart") then
        local hrp = lockedTarget.Character.HumanoidRootPart
        local predictedPos = hrp.Position + (hrp.Velocity * config.CamlockPrediction)
        Camera.CFrame = CFrame.new(Camera.CFrame.Position, predictedPos)
    end
end)

-- Triggerbot implementation (fires if mouse is over enemy)
local UserInputService = UIS
local mouseDown = false

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        mouseDown = true
    end
end)

UserInputService.InputEnded:Connect(function(input, gpe)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        mouseDown = false
    end
end)

RS.RenderStepped:Connect(function()
    if toggleStates.Triggerbot and mouseDown then
        local target = findNearestPlayer(config.SilentAimFOV)
        if target and target.Character and target.Character:FindFirstChild("HumanoidRootPart") then
            local hrp = target.Character.HumanoidRootPart
            local mousePos = UIS:GetMouseLocation()
            local screenPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
            if onScreen and (Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude < config.SilentAimFOV then
                -- Fire tool or mouse click simulation (simulate click)
                local tool = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
                if tool then
                    -- Try activating tool to shoot
                    if tool:FindFirstChild("RemoteEvent") then
                        tool.RemoteEvent:FireServer()
                    elseif tool:FindFirstChild("RemoteFunction") then
                        tool.RemoteFunction:InvokeServer()
                    else
                        tool:Activate()
                    end
                end
            end
        end
    end
end)

-- Auto Jump & Speed (simplified example, can be improved)
local UISConnection
local function updateAutoJumpSpeed()
    if toggleStates.AutoJump or toggleStates.Speed then
        if UISConnection then UISConnection:Disconnect() UISConnection=nil end
        UISConnection = RS.Stepped:Connect(function()
            if toggleStates.AutoJump then
                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                    local humanoid = LocalPlayer.Character.Humanoid
                    if humanoid:GetState() == Enum.HumanoidStateType.Running or humanoid:GetState() == Enum.HumanoidStateType.Landed then
                        humanoid.Jump = true
                    end
                end
            end
            if toggleStates.Speed then
                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                    local humanoid = LocalPlayer.Character.Humanoid
                    humanoid.WalkSpeed = 16 * config.SpeedMultiplier
                end
            else
                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                    local humanoid = LocalPlayer.Character.Humanoid
                    humanoid.WalkSpeed = 16
                end
            end
        end)
    else
        if UISConnection then UISConnection:Disconnect() UISConnection=nil end
        if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
            LocalPlayer.Character.Humanoid.WalkSpeed = 16
        end
    end
end

-- GUI creation function (reusing previous with additions for new toggles)

local function buildGUI()
    local gui = Instance.new("ScreenGui")
    gui.Name = "HelloKittyLockGUI"
    gui.ResetOnSpawn = false
    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

    local main = Instance.new("Frame", gui)
    main.Size = UDim2.new(0, 440, 0, 340)
    main.Position = UDim2.new(0.5, -220, 0.5, -170)
    main.BackgroundColor3 = Color3.fromRGB(255, 230, 245)
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    createUICorner(main, 20)

    local title = Instance.new("TextLabel", main)
    title.Size = UDim2.new(1, 0, 0, 50)
    title.Position = UDim2.new(0, 0, 0, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 28
    title.TextColor3 = Color3.fromRGB(255, 80, 140)
    title.TextStrokeTransparency = 0.5
    title.Text = "🌸 Hello Kitty Lock"

    local closeBtn = Instance.new("TextButton", main)
    closeBtn.Size = UDim2.new(0, 40, 0, 40)
    closeBtn.Position = UDim2.new(1, -50, 0, 10)
    closeBtn.BackgroundColor3 = Color3.fromRGB(255, 90, 120)
    closeBtn.Text = "❌"
    closeBtn.TextColor3 = Color3.new(1,1,1)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 24
    closeBtn.BorderSizePixel = 0
    createUICorner(closeBtn, 10)
    closeBtn.MouseEnter:Connect(function()
        closeBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 180)
    end)
    closeBtn.MouseLeave:Connect(function()
        closeBtn.BackgroundColor3 = Color3.fromRGB(255, 90, 120)
    end)
    closeBtn.MouseButton1Click:Connect(function()
        gui.Enabled = false
        if config.SoundFX then playSound(closeBtn) end
    end)

    local tabsFrame = Instance.new("Frame", main)
    tabsFrame.Size = UDim2.new(1, -40, 0, 40)
    tabsFrame.Position = UDim2.new(0, 20, 0, 60)
    tabsFrame.BackgroundTransparency = 1

    local tabNames = {"Aimbot", "Camlock", "Visuals", "Rage", "Promo", "Settings"}
    local tabs = {}
    local contents = {}

    for i, name in ipairs(tabNames) do
        local btn = Instance.new("TextButton", tabsFrame)
        btn.Size = UDim2.new(0, 70, 1, 0)
        btn.Position = UDim2.new(0, (i-1)*75, 0, 0)
        btn.BackgroundColor3 = Color3.fromRGB(255, 170, 220)
        btn.TextColor3 = Color3.new(0,0,0)
        btn.Text = name
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 16
        btn.BorderSizePixel = 0
        createUICorner(btn, 12)

        tabs[name] = btn

        local content = Instance.new("Frame", main)
        content.Name = name .. "Content"
        content.Size = UDim2.new(1, -40, 1, -120)
        content.Position = UDim2.new(0, 20, 0, 110)
        content.BackgroundTransparency = 1
        content.Visible = false

        contents[name] = content

        btn.MouseButton1Click:Connect(function()
            for _, c in pairs(contents) do c.Visible = false end
            content.Visible = true
            if config.SoundFX then playSound(main) end
        end)
    end

    contents["Aimbot"].Visible = true

    local function createToggle(name, parent, y, default, callback)
        local toggle = Instance.new("TextButton", parent)
        toggle.Size = UDim2.new(0, 190, 0, 38)
        toggle.Position = UDim2.new(0, 10, 0, y)
        toggle.BackgroundColor3 = Color3.fromRGB(255, 185, 220)
        toggle.BorderSizePixel = 0
        createUICorner(toggle, 12)
        toggle.Font = Enum.Font.Gotham
        toggle.TextSize = 18
        toggle.TextColor3 = Color3.new(0, 0, 0)
        toggle.Text = (default and "On: " or "Off: ") .. name
        toggleStates[name] = default

        toggle.MouseButton1Click:Connect(function()
            toggleStates[name] = not toggleStates[name]
            toggle.Text = (toggleStates[name] and "On: " or "Off: ") .. name
            if callback then callback(toggleStates[name]) end
            if config.SoundFX then playSound(toggle) end
            saveConfig()
        end)

        return toggle
    end

    local function createSlider(labelText, parent, y, min, max, step, default, callback)
        local label = Instance.new("TextLabel", parent)
        label.Size = UDim2.new(0, 190, 0, 20)
        label.Position = UDim2.new(0, 10, 0, y)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.TextSize = 14
        label.TextColor3 = Color3.fromRGB(50, 50, 50)
        label.Text = labelText

        local sliderBar = Instance.new("Frame", parent)
        sliderBar.Size = UDim2.new(0, 190, 0, 12)
        sliderBar.Position = UDim2.new(0, 10, 0, y + 22)
        sliderBar.BackgroundColor3 = Color3.fromRGB(230, 180, 230)
        sliderBar.BorderSizePixel = 0
        createUICorner(sliderBar, 6)

        local fill = Instance.new("Frame", sliderBar)
        fill.Size = UDim2.new((default - min) / (max - min), 0, 1, 0)
        fill.BackgroundColor3 = Color3.fromRGB(255, 105, 180)
        fill.BorderSizePixel = 0
        createUICorner(fill, 6)

        local sliderValue = Instance.new("TextLabel", sliderBar)
        sliderValue.Size = UDim2.new(0, 40, 1, 0)
        sliderValue.Position = UDim2.new(1, 5, 0, 0)
        sliderValue.BackgroundTransparency = 1
        sliderValue.Font = Enum.Font.GothamBold
        sliderValue.TextSize = 14
        sliderValue.TextColor3 = Color3.fromRGB(80, 20, 60)
        sliderValue.Text = tostring(default)

        local dragging = false

        sliderBar.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true
            end
        end)
        sliderBar.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = false
            end
        end)
        sliderBar.InputChanged:Connect(function(input)
            if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
                local pos = math.clamp(input.Position.X - sliderBar.AbsolutePosition.X, 0, sliderBar.AbsoluteSize.X)
                local val = min + (pos / sliderBar.AbsoluteSize.X) * (max - min)
                val = math.floor(val / step + 0.5) * step
                fill.Size = UDim2.new((val - min) / (max - min), 0, 1, 0)
                sliderValue.Text = tostring(val)
                if callback then callback(val) end
            end
        end)
        return label
    end

    -- Aimbot tab
    createToggle("SilentAim", contents["Aimbot"], 10, toggleStates.SilentAim, function(v) 
        config.SilentAim = v 
        toggleStates.SilentAim = v
        notify("Silent Aim", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createSlider("Silent Aim FOV", contents["Aimbot"], 60, 10, 180, 5, config.SilentAimFOV, function(val)
        config.SilentAimFOV = val
        saveConfig()
    end)

    createSlider("Silent Aim Prediction", contents["Aimbot"], 100, 0, 1, 0.05, config.SilentAimPrediction, function(val)
        config.SilentAimPrediction = val
        saveConfig()
    end)

    createToggle("Triggerbot", contents["Aimbot"], 140, toggleStates.Triggerbot, function(v)
        config.Triggerbot = v
        toggleStates.Triggerbot = v
        notify("Triggerbot", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    -- Camlock tab
    local camlockToggle = createToggle("Enable Camlock", contents["Camlock"], 10, toggleStates.Camlock, function(v)
        toggleStates.Camlock = v
        if not v then
            camlockActive = false
            lockedTarget = nil
            activateBtn.Visible = false
            deactivateBtn.Visible = false
        else
            activateBtn.Visible = true
            deactivateBtn.Visible = false
        end
        notify("Camlock", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    local activateBtn = Instance.new("TextButton", contents["Camlock"])
    activateBtn.Size = UDim2.new(0, 150, 0, 38)
    activateBtn.Position = UDim2.new(0, 10, 0, 60)
    activateBtn.BackgroundColor3 = Color3.fromRGB(255, 105, 180)
    activateBtn.TextColor3 = Color3.new(1,1,1)
    activateBtn.Font = Enum.Font.GothamBold
    activateBtn.TextSize = 18
    activateBtn.Text = "Activate Camlock"
    activateBtn.Visible = false
    createUICorner(activateBtn, 12)

    local deactivateBtn = Instance.new("TextButton", contents["Camlock"])
    deactivateBtn.Size = UDim2.new(0, 150, 0, 38)
    deactivateBtn.Position = UDim2.new(0, 180, 0, 60)
    deactivateBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 100)
    deactivateBtn.TextColor3 = Color3.new(1,1,1)
    deactivateBtn.Font = Enum.Font.GothamBold
    deactivateBtn.TextSize = 18
    deactivateBtn.Text = "Deactivate Camlock"
    deactivateBtn.Visible = false
    createUICorner(deactivateBtn, 12)

    activateBtn.MouseButton1Click:Connect(function()
        local target = findNearestPlayer(config.CamlockFOV)
        if target then
            lockedTarget = target
            camlockActive = true
            activateBtn.Visible = false
            deactivateBtn.Visible = true
            notify("Camlock", "Locked on " .. target.Name, 3)
            if config.SoundFX then playSound(activateBtn) end
        else
            notify("Camlock", "No target in range", 3)
        end
    end)

    deactivateBtn.MouseButton1Click:Connect(function()
        camlockActive = false
        lockedTarget = nil
        activateBtn.Visible = true
        deactivateBtn.Visible = false
        notify("Camlock", "Camlock Deactivated", 3)
        if config.SoundFX then playSound(deactivateBtn) end
    end)

    createSlider("Camlock FOV", contents["Camlock"], 110, 10, 180, 5, config.CamlockFOV, function(val)
        config.CamlockFOV = val
        saveConfig()
    end)

    createSlider("Camlock Prediction", contents["Camlock"], 150, 0, 1, 0.05, config.CamlockPrediction, function(val)
        config.CamlockPrediction = val
        saveConfig()
    end)

    -- Visuals tab
    createToggle("ESP Boxes", contents["Visuals"], 10, toggleStates.ESPBoxes, function(v)
        config.ESPBoxes = v
        toggleStates.ESPBoxes = v
        notify("ESP", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createToggle("ESP Names", contents["Visuals"], 60, toggleStates.ESPNames, function(v)
        config.ESPNames = v
        toggleStates.ESPNames = v
        notify("ESP", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createSlider("ESP Rainbow Speed", contents["Visuals"], 100, 0, 5, 0.1, config.ESPRainbowSpeed, function(val)
        config.ESPRainbowSpeed = val
        saveConfig()
    end)

    -- Rage tab (just placeholders)
    createToggle("Auto Jump", contents["Rage"], 10, toggleStates.AutoJump, function(v)
        toggleStates.AutoJump = v
        config.AutoJump = v
        updateAutoJumpSpeed()
        notify("Auto Jump", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createToggle("Speed Hack", contents["Rage"], 60, toggleStates.Speed, function(v)
        toggleStates.Speed = v
        config.Speed = v
        updateAutoJumpSpeed()
        notify("Speed Hack", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createSlider("Speed Multiplier", contents["Rage"], 100, 1, 5, 0.1, config.SpeedMultiplier, function(val)
        config.SpeedMultiplier = val
        saveConfig()
    end)

    -- Promo tab text
    local promoText = Instance.new("TextLabel", contents["Promo"])
    promoText.Size = UDim2.new(1, -20, 1, -20)
    promoText.Position = UDim2.new(0, 10, 0, 10)
    promoText.BackgroundTransparency = 1
    promoText.TextColor3 = Color3.fromRGB(255, 60, 110)
    promoText.Font = Enum.Font.GothamBold
    promoText.TextSize = 18
    promoText.Text = "🌸 Thanks for using Hello Kitty Lock!\nStay safe and have fun!"
    promoText.TextWrapped = true

    -- Settings tab
    createToggle("Sound FX", contents["Settings"], 10, config.SoundFX, function(enabled)
        config.SoundFX = enabled
        saveConfig()
    end)

    return gui
end

loadConfig()
local gui = buildGUI()
notify("Hello Kitty Lock", "GUI Loaded - Welcome!", 3)
-- Hello Kitty Lock v6.1 - Full Polished GUI + Silent Aim + ESP + Triggerbot

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()
local Camera = workspace.CurrentCamera
local RS = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")

-- Settings and states
local config = {
    CamlockPrediction = 0.1,
    CamlockFOV = 120,
    SilentAimFOV = 120,
    SilentAimPrediction = 0.1,
    ESPBoxes = true,
    ESPNames = true,
    ESPRainbowSpeed = 1,
    AutoJump = false,
    SpeedMultiplier = 1,
    Triggerbot = false,
    SoundFX = true,
}

local toggleStates = {
    Camlock = false,
    SilentAim = false,
    ESPBoxes = config.ESPBoxes,
    ESPNames = config.ESPNames,
    AutoJump = false,
    Speed = false,
    Triggerbot = false,
}

local camlockActive = false
local lockedTarget = nil

-- Load local saved config if any (basic)
local function loadConfig()
    local saved = LocalPlayer:FindFirstChild("HKLockConfig")
    if saved and saved:IsA("StringValue") then
        local success, data = pcall(function() return game:GetService("HttpService"):JSONDecode(saved.Value) end)
        if success and data then
            for k,v in pairs(data) do
                config[k] = v
                toggleStates[k] = v
            end
        end
    end
end

local function saveConfig()
    local HttpService = game:GetService("HttpService")
    local configStr = HttpService:JSONEncode(config)
    local saved = LocalPlayer:FindFirstChild("HKLockConfig")
    if not saved then
        saved = Instance.new("StringValue")
        saved.Name = "HKLockConfig"
        saved.Parent = LocalPlayer
    end
    saved.Value = configStr
end

-- Utility functions
local function createUICorner(parent, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius or 12)
    corner.Parent = parent
end

local function playSound(parent)
    if not config.SoundFX then return end
    local s = Instance.new("Sound", parent)
    s.SoundId = "rbxassetid://9118824604"
    s.Volume = 0.5
    s:Play()
    game:GetService("Debris"):AddItem(s, 2)
end

local function notify(title, text, duration)
    StarterGui:SetCore("SendNotification", {Title = title, Text = text, Duration = duration or 3})
end

local function findNearestPlayer(fov)
    local mousePos = UIS:GetMouseLocation()
    local closestPlayer = nil
    local shortestDist = fov or 120

    for _, player in pairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("HumanoidRootPart") and player.Character:FindFirstChild("Humanoid") and player.Character.Humanoid.Health > 0 then
            local hrp = player.Character.HumanoidRootPart
            local screenPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
            if onScreen then
                local dist = (Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude
                if dist < shortestDist then
                    shortestDist = dist
                    closestPlayer = player
                end
            end
        end
    end
    return closestPlayer
end

local function getClosestHitbox(player)
    -- Try to return HumanoidRootPart or Head as target hitbox for aiming
    if not player or not player.Character then return nil end
    local hrp = player.Character:FindFirstChild("HumanoidRootPart")
    local head = player.Character:FindFirstChild("Head")
    if hrp then return hrp end
    if head then return head end
    return nil
end

-- ESP Drawing
local ESPFolder = Instance.new("Folder")
ESPFolder.Name = "HKLockESP"
ESPFolder.Parent = LocalPlayer:WaitForChild("PlayerGui")

local ESPObjects = {}

local function createESPForPlayer(player)
    if ESPObjects[player] then return end

    local box = Drawing.new("Square")
    box.Visible = false
    box.Color = Color3.fromRGB(255, 105, 180)
    box.Thickness = 2
    box.Filled = false
    box.Transparency = 1

    local nameText = Drawing.new("Text")
    nameText.Visible = false
    nameText.Center = true
    nameText.Color = Color3.fromRGB(255, 105, 180)
    nameText.Size = 16
    nameText.Font = 2
    nameText.Outline = true

    ESPObjects[player] = {
        Box = box,
        Name = nameText,
    }
end

local function removeESPForPlayer(player)
    if ESPObjects[player] then
        ESPObjects[player].Box:Remove()
        ESPObjects[player].Name:Remove()
        ESPObjects[player] = nil
    end
end

-- Rainbow color helper
local function rainbowColor(t)
    local frequency = config.ESPRainbowSpeed
    local r = math.floor(math.sin(frequency * t + 0) * 127 + 128)
    local g = math.floor(math.sin(frequency * t + 2) * 127 + 128)
    local b = math.floor(math.sin(frequency * t + 4) * 127 + 128)
    return Color3.fromRGB(r, g, b)
end

-- Update ESP every frame
RS.RenderStepped:Connect(function(delta)
    local time = tick()
    for _, player in pairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("HumanoidRootPart") and player.Character:FindFirstChild("Humanoid") and player.Character.Humanoid.Health > 0 then
            createESPForPlayer(player)
            local hrp = player.Character.HumanoidRootPart
            local screenPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
            local esp = ESPObjects[player]
            if onScreen and toggleStates.ESPBoxes then
                local sizeFactor = 1500 / (Camera.CFrame.Position - hrp.Position).Magnitude
                esp.Box.Visible = true
                esp.Box.Size = Vector2.new(60 * sizeFactor, 80 * sizeFactor)
                esp.Box.Position = Vector2.new(screenPos.X - esp.Box.Size.X / 2, screenPos.Y - esp.Box.Size.Y / 2)
                esp.Box.Color = rainbowColor(time)
            else
                esp.Box.Visible = false
            end

            if onScreen and toggleStates.ESPNames then
                esp.Name.Visible = true
                esp.Name.Text = player.Name
                esp.Name.Position = Vector2.new(screenPos.X, screenPos.Y - 50)
                esp.Name.Color = rainbowColor(time)
            else
                esp.Name.Visible = false
            end
        else
            removeESPForPlayer(player)
        end
    end
end)

-- Silent Aim (camera aim assistance)
local function silentAim()
    if not toggleStates.SilentAim then return end
    local target = findNearestPlayer(config.SilentAimFOV)
    if not target or not target.Character then return end
    local hitbox = getClosestHitbox(target)
    if not hitbox then return end
    local predictedPos = hitbox.Position + (hitbox.Velocity * config.SilentAimPrediction)
    local cf = Camera.CFrame
    Camera.CFrame = CFrame.new(cf.Position, predictedPos)
end

-- Camlock loop (locks on activated target)
RS.RenderStepped:Connect(function()
    if toggleStates.Camlock and camlockActive and lockedTarget and lockedTarget.Character and lockedTarget.Character:FindFirstChild("HumanoidRootPart") then
        local hrp = lockedTarget.Character.HumanoidRootPart
        local predictedPos = hrp.Position + (hrp.Velocity * config.CamlockPrediction)
        Camera.CFrame = CFrame.new(Camera.CFrame.Position, predictedPos)
    end
end)

-- Triggerbot implementation (fires if mouse is over enemy)
local UserInputService = UIS
local mouseDown = false

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        mouseDown = true
    end
end)

UserInputService.InputEnded:Connect(function(input, gpe)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        mouseDown = false
    end
end)

RS.RenderStepped:Connect(function()
    if toggleStates.Triggerbot and mouseDown then
        local target = findNearestPlayer(config.SilentAimFOV)
        if target and target.Character and target.Character:FindFirstChild("HumanoidRootPart") then
            local hrp = target.Character.HumanoidRootPart
            local mousePos = UIS:GetMouseLocation()
            local screenPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
            if onScreen and (Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude < config.SilentAimFOV then
                -- Fire tool or mouse click simulation (simulate click)
                local tool = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
                if tool then
                    -- Try activating tool to shoot
                    if tool:FindFirstChild("RemoteEvent") then
                        tool.RemoteEvent:FireServer()
                    elseif tool:FindFirstChild("RemoteFunction") then
                        tool.RemoteFunction:InvokeServer()
                    else
                        tool:Activate()
                    end
                end
            end
        end
    end
end)

-- Auto Jump & Speed (simplified example, can be improved)
local UISConnection
local function updateAutoJumpSpeed()
    if toggleStates.AutoJump or toggleStates.Speed then
        if UISConnection then UISConnection:Disconnect() UISConnection=nil end
        UISConnection = RS.Stepped:Connect(function()
            if toggleStates.AutoJump then
                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                    local humanoid = LocalPlayer.Character.Humanoid
                    if humanoid:GetState() == Enum.HumanoidStateType.Running or humanoid:GetState() == Enum.HumanoidStateType.Landed then
                        humanoid.Jump = true
                    end
                end
            end
            if toggleStates.Speed then
                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                    local humanoid = LocalPlayer.Character.Humanoid
                    humanoid.WalkSpeed = 16 * config.SpeedMultiplier
                end
            else
                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                    local humanoid = LocalPlayer.Character.Humanoid
                    humanoid.WalkSpeed = 16
                end
            end
        end)
    else
        if UISConnection then UISConnection:Disconnect() UISConnection=nil end
        if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
            LocalPlayer.Character.Humanoid.WalkSpeed = 16
        end
    end
end

-- GUI creation function (reusing previous with additions for new toggles)

local function buildGUI()
    local gui = Instance.new("ScreenGui")
    gui.Name = "HelloKittyLockGUI"
    gui.ResetOnSpawn = false
    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

    local main = Instance.new("Frame", gui)
    main.Size = UDim2.new(0, 440, 0, 340)
    main.Position = UDim2.new(0.5, -220, 0.5, -170)
    main.BackgroundColor3 = Color3.fromRGB(255, 230, 245)
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    createUICorner(main, 20)

    local title = Instance.new("TextLabel", main)
    title.Size = UDim2.new(1, 0, 0, 50)
    title.Position = UDim2.new(0, 0, 0, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 28
    title.TextColor3 = Color3.fromRGB(255, 80, 140)
    title.TextStrokeTransparency = 0.5
    title.Text = "🌸 Hello Kitty Lock"

    local closeBtn = Instance.new("TextButton", main)
    closeBtn.Size = UDim2.new(0, 40, 0, 40)
    closeBtn.Position = UDim2.new(1, -50, 0, 10)
    closeBtn.BackgroundColor3 = Color3.fromRGB(255, 90, 120)
    closeBtn.Text = "❌"
    closeBtn.TextColor3 = Color3.new(1,1,1)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 24
    closeBtn.BorderSizePixel = 0
    createUICorner(closeBtn, 10)
    closeBtn.MouseEnter:Connect(function()
        closeBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 180)
    end)
    closeBtn.MouseLeave:Connect(function()
        closeBtn.BackgroundColor3 = Color3.fromRGB(255, 90, 120)
    end)
    closeBtn.MouseButton1Click:Connect(function()
        gui.Enabled = false
        if config.SoundFX then playSound(closeBtn) end
    end)

    local tabsFrame = Instance.new("Frame", main)
    tabsFrame.Size = UDim2.new(1, -40, 0, 40)
    tabsFrame.Position = UDim2.new(0, 20, 0, 60)
    tabsFrame.BackgroundTransparency = 1

    local tabNames = {"Aimbot", "Camlock", "Visuals", "Rage", "Promo", "Settings"}
    local tabs = {}
    local contents = {}

    for i, name in ipairs(tabNames) do
        local btn = Instance.new("TextButton", tabsFrame)
        btn.Size = UDim2.new(0, 70, 1, 0)
        btn.Position = UDim2.new(0, (i-1)*75, 0, 0)
        btn.BackgroundColor3 = Color3.fromRGB(255, 170, 220)
        btn.TextColor3 = Color3.new(0,0,0)
        btn.Text = name
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 16
        btn.BorderSizePixel = 0
        createUICorner(btn, 12)

        tabs[name] = btn

        local content = Instance.new("Frame", main)
        content.Name = name .. "Content"
        content.Size = UDim2.new(1, -40, 1, -120)
        content.Position = UDim2.new(0, 20, 0, 110)
        content.BackgroundTransparency = 1
        content.Visible = false

        contents[name] = content

        btn.MouseButton1Click:Connect(function()
            for _, c in pairs(contents) do c.Visible = false end
            content.Visible = true
            if config.SoundFX then playSound(main) end
        end)
    end

    contents["Aimbot"].Visible = true

    local function createToggle(name, parent, y, default, callback)
        local toggle = Instance.new("TextButton", parent)
        toggle.Size = UDim2.new(0, 190, 0, 38)
        toggle.Position = UDim2.new(0, 10, 0, y)
        toggle.BackgroundColor3 = Color3.fromRGB(255, 185, 220)
        toggle.BorderSizePixel = 0
        createUICorner(toggle, 12)
        toggle.Font = Enum.Font.Gotham
        toggle.TextSize = 18
        toggle.TextColor3 = Color3.new(0, 0, 0)
        toggle.Text = (default and "On: " or "Off: ") .. name
        toggleStates[name] = default

        toggle.MouseButton1Click:Connect(function()
            toggleStates[name] = not toggleStates[name]
            toggle.Text = (toggleStates[name] and "On: " or "Off: ") .. name
            if callback then callback(toggleStates[name]) end
            if config.SoundFX then playSound(toggle) end
            saveConfig()
        end)

        return toggle
    end

    local function createSlider(labelText, parent, y, min, max, step, default, callback)
        local label = Instance.new("TextLabel", parent)
        label.Size = UDim2.new(0, 190, 0, 20)
        label.Position = UDim2.new(0, 10, 0, y)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.TextSize = 14
        label.TextColor3 = Color3.fromRGB(50, 50, 50)
        label.Text = labelText

        local sliderBar = Instance.new("Frame", parent)
        sliderBar.Size = UDim2.new(0, 190, 0, 12)
        sliderBar.Position = UDim2.new(0, 10, 0, y + 22)
        sliderBar.BackgroundColor3 = Color3.fromRGB(230, 180, 230)
        sliderBar.BorderSizePixel = 0
        createUICorner(sliderBar, 6)

        local fill = Instance.new("Frame", sliderBar)
        fill.Size = UDim2.new((default - min) / (max - min), 0, 1, 0)
        fill.BackgroundColor3 = Color3.fromRGB(255, 105, 180)
        fill.BorderSizePixel = 0
        createUICorner(fill, 6)

        local sliderValue = Instance.new("TextLabel", sliderBar)
        sliderValue.Size = UDim2.new(0, 40, 1, 0)
        sliderValue.Position = UDim2.new(1, 5, 0, 0)
        sliderValue.BackgroundTransparency = 1
        sliderValue.Font = Enum.Font.GothamBold
        sliderValue.TextSize = 14
        sliderValue.TextColor3 = Color3.fromRGB(80, 20, 60)
        sliderValue.Text = tostring(default)

        local dragging = false

        sliderBar.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true
            end
        end)
        sliderBar.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = false
            end
        end)
        sliderBar.InputChanged:Connect(function(input)
            if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
                local pos = math.clamp(input.Position.X - sliderBar.AbsolutePosition.X, 0, sliderBar.AbsoluteSize.X)
                local val = min + (pos / sliderBar.AbsoluteSize.X) * (max - min)
                val = math.floor(val / step + 0.5) * step
                fill.Size = UDim2.new((val - min) / (max - min), 0, 1, 0)
                sliderValue.Text = tostring(val)
                if callback then callback(val) end
            end
        end)
        return label
    end

    -- Aimbot tab
    createToggle("SilentAim", contents["Aimbot"], 10, toggleStates.SilentAim, function(v) 
        config.SilentAim = v 
        toggleStates.SilentAim = v
        notify("Silent Aim", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createSlider("Silent Aim FOV", contents["Aimbot"], 60, 10, 180, 5, config.SilentAimFOV, function(val)
        config.SilentAimFOV = val
        saveConfig()
    end)

    createSlider("Silent Aim Prediction", contents["Aimbot"], 100, 0, 1, 0.05, config.SilentAimPrediction, function(val)
        config.SilentAimPrediction = val
        saveConfig()
    end)

    createToggle("Triggerbot", contents["Aimbot"], 140, toggleStates.Triggerbot, function(v)
        config.Triggerbot = v
        toggleStates.Triggerbot = v
        notify("Triggerbot", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    -- Camlock tab
    local camlockToggle = createToggle("Enable Camlock", contents["Camlock"], 10, toggleStates.Camlock, function(v)
        toggleStates.Camlock = v
        if not v then
            camlockActive = false
            lockedTarget = nil
            activateBtn.Visible = false
            deactivateBtn.Visible = false
        else
            activateBtn.Visible = true
            deactivateBtn.Visible = false
        end
        notify("Camlock", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    local activateBtn = Instance.new("TextButton", contents["Camlock"])
    activateBtn.Size = UDim2.new(0, 150, 0, 38)
    activateBtn.Position = UDim2.new(0, 10, 0, 60)
    activateBtn.BackgroundColor3 = Color3.fromRGB(255, 105, 180)
    activateBtn.TextColor3 = Color3.new(1,1,1)
    activateBtn.Font = Enum.Font.GothamBold
    activateBtn.TextSize = 18
    activateBtn.Text = "Activate Camlock"
    activateBtn.Visible = false
    createUICorner(activateBtn, 12)

    local deactivateBtn = Instance.new("TextButton", contents["Camlock"])
    deactivateBtn.Size = UDim2.new(0, 150, 0, 38)
    deactivateBtn.Position = UDim2.new(0, 180, 0, 60)
    deactivateBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 100)
    deactivateBtn.TextColor3 = Color3.new(1,1,1)
    deactivateBtn.Font = Enum.Font.GothamBold
    deactivateBtn.TextSize = 18
    deactivateBtn.Text = "Deactivate Camlock"
    deactivateBtn.Visible = false
    createUICorner(deactivateBtn, 12)

    activateBtn.MouseButton1Click:Connect(function()
        local target = findNearestPlayer(config.CamlockFOV)
        if target then
            lockedTarget = target
            camlockActive = true
            activateBtn.Visible = false
            deactivateBtn.Visible = true
            notify("Camlock", "Locked on " .. target.Name, 3)
            if config.SoundFX then playSound(activateBtn) end
        else
            notify("Camlock", "No target in range", 3)
        end
    end)

    deactivateBtn.MouseButton1Click:Connect(function()
        camlockActive = false
        lockedTarget = nil
        activateBtn.Visible = true
        deactivateBtn.Visible = false
        notify("Camlock", "Camlock Deactivated", 3)
        if config.SoundFX then playSound(deactivateBtn) end
    end)

    createSlider("Camlock FOV", contents["Camlock"], 110, 10, 180, 5, config.CamlockFOV, function(val)
        config.CamlockFOV = val
        saveConfig()
    end)

    createSlider("Camlock Prediction", contents["Camlock"], 150, 0, 1, 0.05, config.CamlockPrediction, function(val)
        config.CamlockPrediction = val
        saveConfig()
    end)

    -- Visuals tab
    createToggle("ESP Boxes", contents["Visuals"], 10, toggleStates.ESPBoxes, function(v)
        config.ESPBoxes = v
        toggleStates.ESPBoxes = v
        notify("ESP", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createToggle("ESP Names", contents["Visuals"], 60, toggleStates.ESPNames, function(v)
        config.ESPNames = v
        toggleStates.ESPNames = v
        notify("ESP", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createSlider("ESP Rainbow Speed", contents["Visuals"], 100, 0, 5, 0.1, config.ESPRainbowSpeed, function(val)
        config.ESPRainbowSpeed = val
        saveConfig()
    end)

    -- Rage tab (just placeholders)
    createToggle("Auto Jump", contents["Rage"], 10, toggleStates.AutoJump, function(v)
        toggleStates.AutoJump = v
        config.AutoJump = v
        updateAutoJumpSpeed()
        notify("Auto Jump", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createToggle("Speed Hack", contents["Rage"], 60, toggleStates.Speed, function(v)
        toggleStates.Speed = v
        config.Speed = v
        updateAutoJumpSpeed()
        notify("Speed Hack", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createSlider("Speed Multiplier", contents["Rage"], 100, 1, 5, 0.1, config.SpeedMultiplier, function(val)
        config.SpeedMultiplier = val
        saveConfig()
    end)

    -- Promo tab text
    local promoText = Instance.new("TextLabel", contents["Promo"])
    promoText.Size = UDim2.new(1, -20, 1, -20)
    promoText.Position = UDim2.new(0, 10, 0, 10)
    promoText.BackgroundTransparency = 1
    promoText.TextColor3 = Color3.fromRGB(255, 60, 110)
    promoText.Font = Enum.Font.GothamBold
    promoText.TextSize = 18
    promoText.Text = "🌸 Thanks for using Hello Kitty Lock!\nStay safe and have fun!"
    promoText.TextWrapped = true

    -- Settings tab
    createToggle("Sound FX", contents["Settings"], 10, config.SoundFX, function(enabled)
        config.SoundFX = enabled
        saveConfig()
    end)

    return gui
end

loadConfig()
local gui = buildGUI()
notify("Hello Kitty Lock", "GUI Loaded - Welcome!", 3)
-- Hello Kitty Lock v6.1 - Full Polished GUI + Silent Aim + ESP + Triggerbot

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()
local Camera = workspace.CurrentCamera
local RS = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")

-- Settings and states
local config = {
    CamlockPrediction = 0.1,
    CamlockFOV = 120,
    SilentAimFOV = 120,
    SilentAimPrediction = 0.1,
    ESPBoxes = true,
    ESPNames = true,
    ESPRainbowSpeed = 1,
    AutoJump = false,
    SpeedMultiplier = 1,
    Triggerbot = false,
    SoundFX = true,
}

local toggleStates = {
    Camlock = false,
    SilentAim = false,
    ESPBoxes = config.ESPBoxes,
    ESPNames = config.ESPNames,
    AutoJump = false,
    Speed = false,
    Triggerbot = false,
}

local camlockActive = false
local lockedTarget = nil

-- Load local saved config if any (basic)
local function loadConfig()
    local saved = LocalPlayer:FindFirstChild("HKLockConfig")
    if saved and saved:IsA("StringValue") then
        local success, data = pcall(function() return game:GetService("HttpService"):JSONDecode(saved.Value) end)
        if success and data then
            for k,v in pairs(data) do
                config[k] = v
                toggleStates[k] = v
            end
        end
    end
end

local function saveConfig()
    local HttpService = game:GetService("HttpService")
    local configStr = HttpService:JSONEncode(config)
    local saved = LocalPlayer:FindFirstChild("HKLockConfig")
    if not saved then
        saved = Instance.new("StringValue")
        saved.Name = "HKLockConfig"
        saved.Parent = LocalPlayer
    end
    saved.Value = configStr
end

-- Utility functions
local function createUICorner(parent, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius or 12)
    corner.Parent = parent
end

local function playSound(parent)
    if not config.SoundFX then return end
    local s = Instance.new("Sound", parent)
    s.SoundId = "rbxassetid://9118824604"
    s.Volume = 0.5
    s:Play()
    game:GetService("Debris"):AddItem(s, 2)
end

local function notify(title, text, duration)
    StarterGui:SetCore("SendNotification", {Title = title, Text = text, Duration = duration or 3})
end

local function findNearestPlayer(fov)
    local mousePos = UIS:GetMouseLocation()
    local closestPlayer = nil
    local shortestDist = fov or 120

    for _, player in pairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("HumanoidRootPart") and player.Character:FindFirstChild("Humanoid") and player.Character.Humanoid.Health > 0 then
            local hrp = player.Character.HumanoidRootPart
            local screenPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
            if onScreen then
                local dist = (Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude
                if dist < shortestDist then
                    shortestDist = dist
                    closestPlayer = player
                end
            end
        end
    end
    return closestPlayer
end

local function getClosestHitbox(player)
    -- Try to return HumanoidRootPart or Head as target hitbox for aiming
    if not player or not player.Character then return nil end
    local hrp = player.Character:FindFirstChild("HumanoidRootPart")
    local head = player.Character:FindFirstChild("Head")
    if hrp then return hrp end
    if head then return head end
    return nil
end

-- ESP Drawing
local ESPFolder = Instance.new("Folder")
ESPFolder.Name = "HKLockESP"
ESPFolder.Parent = LocalPlayer:WaitForChild("PlayerGui")

local ESPObjects = {}

local function createESPForPlayer(player)
    if ESPObjects[player] then return end

    local box = Drawing.new("Square")
    box.Visible = false
    box.Color = Color3.fromRGB(255, 105, 180)
    box.Thickness = 2
    box.Filled = false
    box.Transparency = 1

    local nameText = Drawing.new("Text")
    nameText.Visible = false
    nameText.Center = true
    nameText.Color = Color3.fromRGB(255, 105, 180)
    nameText.Size = 16
    nameText.Font = 2
    nameText.Outline = true

    ESPObjects[player] = {
        Box = box,
        Name = nameText,
    }
end

local function removeESPForPlayer(player)
    if ESPObjects[player] then
        ESPObjects[player].Box:Remove()
        ESPObjects[player].Name:Remove()
        ESPObjects[player] = nil
    end
end

-- Rainbow color helper
local function rainbowColor(t)
    local frequency = config.ESPRainbowSpeed
    local r = math.floor(math.sin(frequency * t + 0) * 127 + 128)
    local g = math.floor(math.sin(frequency * t + 2) * 127 + 128)
    local b = math.floor(math.sin(frequency * t + 4) * 127 + 128)
    return Color3.fromRGB(r, g, b)
end

-- Update ESP every frame
RS.RenderStepped:Connect(function(delta)
    local time = tick()
    for _, player in pairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("HumanoidRootPart") and player.Character:FindFirstChild("Humanoid") and player.Character.Humanoid.Health > 0 then
            createESPForPlayer(player)
            local hrp = player.Character.HumanoidRootPart
            local screenPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
            local esp = ESPObjects[player]
            if onScreen and toggleStates.ESPBoxes then
                local sizeFactor = 1500 / (Camera.CFrame.Position - hrp.Position).Magnitude
                esp.Box.Visible = true
                esp.Box.Size = Vector2.new(60 * sizeFactor, 80 * sizeFactor)
                esp.Box.Position = Vector2.new(screenPos.X - esp.Box.Size.X / 2, screenPos.Y - esp.Box.Size.Y / 2)
                esp.Box.Color = rainbowColor(time)
            else
                esp.Box.Visible = false
            end

            if onScreen and toggleStates.ESPNames then
                esp.Name.Visible = true
                esp.Name.Text = player.Name
                esp.Name.Position = Vector2.new(screenPos.X, screenPos.Y - 50)
                esp.Name.Color = rainbowColor(time)
            else
                esp.Name.Visible = false
            end
        else
            removeESPForPlayer(player)
        end
    end
end)

-- Silent Aim (camera aim assistance)
local function silentAim()
    if not toggleStates.SilentAim then return end
    local target = findNearestPlayer(config.SilentAimFOV)
    if not target or not target.Character then return end
    local hitbox = getClosestHitbox(target)
    if not hitbox then return end
    local predictedPos = hitbox.Position + (hitbox.Velocity * config.SilentAimPrediction)
    local cf = Camera.CFrame
    Camera.CFrame = CFrame.new(cf.Position, predictedPos)
end

-- Camlock loop (locks on activated target)
RS.RenderStepped:Connect(function()
    if toggleStates.Camlock and camlockActive and lockedTarget and lockedTarget.Character and lockedTarget.Character:FindFirstChild("HumanoidRootPart") then
        local hrp = lockedTarget.Character.HumanoidRootPart
        local predictedPos = hrp.Position + (hrp.Velocity * config.CamlockPrediction)
        Camera.CFrame = CFrame.new(Camera.CFrame.Position, predictedPos)
    end
end)

-- Triggerbot implementation (fires if mouse is over enemy)
local UserInputService = UIS
local mouseDown = false

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        mouseDown = true
    end
end)

UserInputService.InputEnded:Connect(function(input, gpe)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        mouseDown = false
    end
end)

RS.RenderStepped:Connect(function()
    if toggleStates.Triggerbot and mouseDown then
        local target = findNearestPlayer(config.SilentAimFOV)
        if target and target.Character and target.Character:FindFirstChild("HumanoidRootPart") then
            local hrp = target.Character.HumanoidRootPart
            local mousePos = UIS:GetMouseLocation()
            local screenPos, onScreen = Camera:WorldToViewportPoint(hrp.Position)
            if onScreen and (Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude < config.SilentAimFOV then
                -- Fire tool or mouse click simulation (simulate click)
                local tool = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
                if tool then
                    -- Try activating tool to shoot
                    if tool:FindFirstChild("RemoteEvent") then
                        tool.RemoteEvent:FireServer()
                    elseif tool:FindFirstChild("RemoteFunction") then
                        tool.RemoteFunction:InvokeServer()
                    else
                        tool:Activate()
                    end
                end
            end
        end
    end
end)

-- Auto Jump & Speed (simplified example, can be improved)
local UISConnection
local function updateAutoJumpSpeed()
    if toggleStates.AutoJump or toggleStates.Speed then
        if UISConnection then UISConnection:Disconnect() UISConnection=nil end
        UISConnection = RS.Stepped:Connect(function()
            if toggleStates.AutoJump then
                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                    local humanoid = LocalPlayer.Character.Humanoid
                    if humanoid:GetState() == Enum.HumanoidStateType.Running or humanoid:GetState() == Enum.HumanoidStateType.Landed then
                        humanoid.Jump = true
                    end
                end
            end
            if toggleStates.Speed then
                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                    local humanoid = LocalPlayer.Character.Humanoid
                    humanoid.WalkSpeed = 16 * config.SpeedMultiplier
                end
            else
                if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
                    local humanoid = LocalPlayer.Character.Humanoid
                    humanoid.WalkSpeed = 16
                end
            end
        end)
    else
        if UISConnection then UISConnection:Disconnect() UISConnection=nil end
        if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
            LocalPlayer.Character.Humanoid.WalkSpeed = 16
        end
    end
end

-- GUI creation function (reusing previous with additions for new toggles)

local function buildGUI()
    local gui = Instance.new("ScreenGui")
    gui.Name = "HelloKittyLockGUI"
    gui.ResetOnSpawn = false
    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

    local main = Instance.new("Frame", gui)
    main.Size = UDim2.new(0, 440, 0, 340)
    main.Position = UDim2.new(0.5, -220, 0.5, -170)
    main.BackgroundColor3 = Color3.fromRGB(255, 230, 245)
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    createUICorner(main, 20)

    local title = Instance.new("TextLabel", main)
    title.Size = UDim2.new(1, 0, 0, 50)
    title.Position = UDim2.new(0, 0, 0, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 28
    title.TextColor3 = Color3.fromRGB(255, 80, 140)
    title.TextStrokeTransparency = 0.5
    title.Text = "🌸 Hello Kitty Lock"

    local closeBtn = Instance.new("TextButton", main)
    closeBtn.Size = UDim2.new(0, 40, 0, 40)
    closeBtn.Position = UDim2.new(1, -50, 0, 10)
    closeBtn.BackgroundColor3 = Color3.fromRGB(255, 90, 120)
    closeBtn.Text = "❌"
    closeBtn.TextColor3 = Color3.new(1,1,1)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 24
    closeBtn.BorderSizePixel = 0
    createUICorner(closeBtn, 10)
    closeBtn.MouseEnter:Connect(function()
        closeBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 180)
    end)
    closeBtn.MouseLeave:Connect(function()
        closeBtn.BackgroundColor3 = Color3.fromRGB(255, 90, 120)
    end)
    closeBtn.MouseButton1Click:Connect(function()
        gui.Enabled = false
        if config.SoundFX then playSound(closeBtn) end
    end)

    local tabsFrame = Instance.new("Frame", main)
    tabsFrame.Size = UDim2.new(1, -40, 0, 40)
    tabsFrame.Position = UDim2.new(0, 20, 0, 60)
    tabsFrame.BackgroundTransparency = 1

    local tabNames = {"Aimbot", "Camlock", "Visuals", "Rage", "Promo", "Settings"}
    local tabs = {}
    local contents = {}

    for i, name in ipairs(tabNames) do
        local btn = Instance.new("TextButton", tabsFrame)
        btn.Size = UDim2.new(0, 70, 1, 0)
        btn.Position = UDim2.new(0, (i-1)*75, 0, 0)
        btn.BackgroundColor3 = Color3.fromRGB(255, 170, 220)
        btn.TextColor3 = Color3.new(0,0,0)
        btn.Text = name
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 16
        btn.BorderSizePixel = 0
        createUICorner(btn, 12)

        tabs[name] = btn

        local content = Instance.new("Frame", main)
        content.Name = name .. "Content"
        content.Size = UDim2.new(1, -40, 1, -120)
        content.Position = UDim2.new(0, 20, 0, 110)
        content.BackgroundTransparency = 1
        content.Visible = false

        contents[name] = content

        btn.MouseButton1Click:Connect(function()
            for _, c in pairs(contents) do c.Visible = false end
            content.Visible = true
            if config.SoundFX then playSound(main) end
        end)
    end

    contents["Aimbot"].Visible = true

    local function createToggle(name, parent, y, default, callback)
        local toggle = Instance.new("TextButton", parent)
        toggle.Size = UDim2.new(0, 190, 0, 38)
        toggle.Position = UDim2.new(0, 10, 0, y)
        toggle.BackgroundColor3 = Color3.fromRGB(255, 185, 220)
        toggle.BorderSizePixel = 0
        createUICorner(toggle, 12)
        toggle.Font = Enum.Font.Gotham
        toggle.TextSize = 18
        toggle.TextColor3 = Color3.new(0, 0, 0)
        toggle.Text = (default and "On: " or "Off: ") .. name
        toggleStates[name] = default

        toggle.MouseButton1Click:Connect(function()
            toggleStates[name] = not toggleStates[name]
            toggle.Text = (toggleStates[name] and "On: " or "Off: ") .. name
            if callback then callback(toggleStates[name]) end
            if config.SoundFX then playSound(toggle) end
            saveConfig()
        end)

        return toggle
    end

    local function createSlider(labelText, parent, y, min, max, step, default, callback)
        local label = Instance.new("TextLabel", parent)
        label.Size = UDim2.new(0, 190, 0, 20)
        label.Position = UDim2.new(0, 10, 0, y)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.TextSize = 14
        label.TextColor3 = Color3.fromRGB(50, 50, 50)
        label.Text = labelText

        local sliderBar = Instance.new("Frame", parent)
        sliderBar.Size = UDim2.new(0, 190, 0, 12)
        sliderBar.Position = UDim2.new(0, 10, 0, y + 22)
        sliderBar.BackgroundColor3 = Color3.fromRGB(230, 180, 230)
        sliderBar.BorderSizePixel = 0
        createUICorner(sliderBar, 6)

        local fill = Instance.new("Frame", sliderBar)
        fill.Size = UDim2.new((default - min) / (max - min), 0, 1, 0)
        fill.BackgroundColor3 = Color3.fromRGB(255, 105, 180)
        fill.BorderSizePixel = 0
        createUICorner(fill, 6)

        local sliderValue = Instance.new("TextLabel", sliderBar)
        sliderValue.Size = UDim2.new(0, 40, 1, 0)
        sliderValue.Position = UDim2.new(1, 5, 0, 0)
        sliderValue.BackgroundTransparency = 1
        sliderValue.Font = Enum.Font.GothamBold
        sliderValue.TextSize = 14
        sliderValue.TextColor3 = Color3.fromRGB(80, 20, 60)
        sliderValue.Text = tostring(default)

        local dragging = false

        sliderBar.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true
            end
        end)
        sliderBar.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = false
            end
        end)
        sliderBar.InputChanged:Connect(function(input)
            if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
                local pos = math.clamp(input.Position.X - sliderBar.AbsolutePosition.X, 0, sliderBar.AbsoluteSize.X)
                local val = min + (pos / sliderBar.AbsoluteSize.X) * (max - min)
                val = math.floor(val / step + 0.5) * step
                fill.Size = UDim2.new((val - min) / (max - min), 0, 1, 0)
                sliderValue.Text = tostring(val)
                if callback then callback(val) end
            end
        end)
        return label
    end

    -- Aimbot tab
    createToggle("SilentAim", contents["Aimbot"], 10, toggleStates.SilentAim, function(v) 
        config.SilentAim = v 
        toggleStates.SilentAim = v
        notify("Silent Aim", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createSlider("Silent Aim FOV", contents["Aimbot"], 60, 10, 180, 5, config.SilentAimFOV, function(val)
        config.SilentAimFOV = val
        saveConfig()
    end)

    createSlider("Silent Aim Prediction", contents["Aimbot"], 100, 0, 1, 0.05, config.SilentAimPrediction, function(val)
        config.SilentAimPrediction = val
        saveConfig()
    end)

    createToggle("Triggerbot", contents["Aimbot"], 140, toggleStates.Triggerbot, function(v)
        config.Triggerbot = v
        toggleStates.Triggerbot = v
        notify("Triggerbot", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    -- Camlock tab
    local camlockToggle = createToggle("Enable Camlock", contents["Camlock"], 10, toggleStates.Camlock, function(v)
        toggleStates.Camlock = v
        if not v then
            camlockActive = false
            lockedTarget = nil
            activateBtn.Visible = false
            deactivateBtn.Visible = false
        else
            activateBtn.Visible = true
            deactivateBtn.Visible = false
        end
        notify("Camlock", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    local activateBtn = Instance.new("TextButton", contents["Camlock"])
    activateBtn.Size = UDim2.new(0, 150, 0, 38)
    activateBtn.Position = UDim2.new(0, 10, 0, 60)
    activateBtn.BackgroundColor3 = Color3.fromRGB(255, 105, 180)
    activateBtn.TextColor3 = Color3.new(1,1,1)
    activateBtn.Font = Enum.Font.GothamBold
    activateBtn.TextSize = 18
    activateBtn.Text = "Activate Camlock"
    activateBtn.Visible = false
    createUICorner(activateBtn, 12)

    local deactivateBtn = Instance.new("TextButton", contents["Camlock"])
    deactivateBtn.Size = UDim2.new(0, 150, 0, 38)
    deactivateBtn.Position = UDim2.new(0, 180, 0, 60)
    deactivateBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 100)
    deactivateBtn.TextColor3 = Color3.new(1,1,1)
    deactivateBtn.Font = Enum.Font.GothamBold
    deactivateBtn.TextSize = 18
    deactivateBtn.Text = "Deactivate Camlock"
    deactivateBtn.Visible = false
    createUICorner(deactivateBtn, 12)

    activateBtn.MouseButton1Click:Connect(function()
        local target = findNearestPlayer(config.CamlockFOV)
        if target then
            lockedTarget = target
            camlockActive = true
            activateBtn.Visible = false
            deactivateBtn.Visible = true
            notify("Camlock", "Locked on " .. target.Name, 3)
            if config.SoundFX then playSound(activateBtn) end
        else
            notify("Camlock", "No target in range", 3)
        end
    end)

    deactivateBtn.MouseButton1Click:Connect(function()
        camlockActive = false
        lockedTarget = nil
        activateBtn.Visible = true
        deactivateBtn.Visible = false
        notify("Camlock", "Camlock Deactivated", 3)
        if config.SoundFX then playSound(deactivateBtn) end
    end)

    createSlider("Camlock FOV", contents["Camlock"], 110, 10, 180, 5, config.CamlockFOV, function(val)
        config.CamlockFOV = val
        saveConfig()
    end)

    createSlider("Camlock Prediction", contents["Camlock"], 150, 0, 1, 0.05, config.CamlockPrediction, function(val)
        config.CamlockPrediction = val
        saveConfig()
    end)

    -- Visuals tab
    createToggle("ESP Boxes", contents["Visuals"], 10, toggleStates.ESPBoxes, function(v)
        config.ESPBoxes = v
        toggleStates.ESPBoxes = v
        notify("ESP", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createToggle("ESP Names", contents["Visuals"], 60, toggleStates.ESPNames, function(v)
        config.ESPNames = v
        toggleStates.ESPNames = v
        notify("ESP", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createSlider("ESP Rainbow Speed", contents["Visuals"], 100, 0, 5, 0.1, config.ESPRainbowSpeed, function(val)
        config.ESPRainbowSpeed = val
        saveConfig()
    end)

    -- Rage tab (just placeholders)
    createToggle("Auto Jump", contents["Rage"], 10, toggleStates.AutoJump, function(v)
        toggleStates.AutoJump = v
        config.AutoJump = v
        updateAutoJumpSpeed()
        notify("Auto Jump", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createToggle("Speed Hack", contents["Rage"], 60, toggleStates.Speed, function(v)
        toggleStates.Speed = v
        config.Speed = v
        updateAutoJumpSpeed()
        notify("Speed Hack", v and "Enabled" or "Disabled", 2)
        saveConfig()
    end)

    createSlider("Speed Multiplier", contents["Rage"], 100, 1, 5, 0.1, config.SpeedMultiplier, function(val)
        config.SpeedMultiplier = val
        saveConfig()
    end)

    -- Promo tab text
    local promoText = Instance.new("TextLabel", contents["Promo"])
    promoText.Size = UDim2.new(1, -20, 1, -20)
    promoText.Position = UDim2.new(0, 10, 0, 10)
    promoText.BackgroundTransparency = 1
    promoText.TextColor3 = Color3.fromRGB(255, 60, 110)
    promoText.Font = Enum.Font.GothamBold
    promoText.TextSize = 18
    promoText.Text = "🌸 Thanks for using Hello Kitty Lock!\nStay safe and have fun!"
    promoText.TextWrapped = true

    -- Settings tab
    createToggle("Sound FX", contents["Settings"], 10, config.SoundFX, function(enabled)
        config.SoundFX = enabled
        saveConfig()
    end)

    return gui
end

loadConfig()
local gui = buildGUI()
notify("Hello Kitty Lock", "GUI Loaded - Welcome!", 3)

getgenv().ConfirmLuna = true

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local lp = Players.LocalPlayer

local Luna = loadstring(game:HttpGet("https://raw.githubusercontent.com/Nebula-Softworks/Luna-Interface-Suite/master/source.lua"))()

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------
local S = {
    enabled      = false,
    setServerPos = false,
    active       = false,   -- enabled AND setServerPos
    mode         = "Delay",
    delayMs      = 200,
    history      = {},      -- { {t=, cf=, vel=}, ... } true positions
    frozenCF     = nil,
    realCF       = nil,     -- latest TRUE cframe (what the hook hands back)
    spoofCF      = nil,     -- latest FAKE cframe (what the server saw) -> ring
    hrp          = nil,     -- cached root
    head         = nil,
}

local oldIndex, oldNamecall

local function getRoot()
    local char = lp.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

-- Read a property bypassing our own hook (true engine value).
local function trueProp(inst, name)
    if oldIndex then
        return oldIndex(inst, name)
    end
    return inst[name]
end

local function refreshCache()
    local char = lp.Character
    S.hrp  = char and char:FindFirstChild("HumanoidRootPart")
    S.head = char and char:FindFirstChild("Head")
end

--------------------------------------------------------------------------
-- Spoof value for the current mode
--------------------------------------------------------------------------
local function computeSpoof(realCF, realVel)
    if S.mode == "Freeze" then
        return S.frozenCF or realCF, Vector3.zero
    end
    local want = os.clock() - S.delayMs / 1000
    local pick = S.history[1]
    for i = 1, #S.history do
        if S.history[i].t <= want then
            pick = S.history[i]
        else
            break
        end
    end
    if pick then
        return pick.cf, pick.vel
    end
    return realCF, realVel
end

--------------------------------------------------------------------------
-- Install metamethod hooks  (return REAL cframe to local readers)
--------------------------------------------------------------------------
local hookOk, hookErr = pcall(function()
    oldIndex = hookmetamethod(game, "__index", newcclosure(function(self, key)
        if S.active and not checkcaller() and key == "CFrame" and S.hrp then
            if self == S.hrp then
                return S.realCF or trueProp(self, "CFrame")
            elseif S.head and self == S.head then
                local sizeY = trueProp(S.hrp, "Size").Y
                return (S.realCF or trueProp(S.hrp, "CFrame")) + Vector3.new(0, sizeY / 2 + 0.5, 0)
            end
        end
        return oldIndex(self, key)
    end))

    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if S.active and not checkcaller() and self == S.hrp then
            local method = getnamecallmethod()
            if method == "GetPivot" then
                return S.realCF or oldNamecall(self, ...)
            end
        end
        return oldNamecall(self, ...)
    end))
end)

--------------------------------------------------------------------------
-- Stay network-authoritative over our own character
--------------------------------------------------------------------------
RunService.Stepped:Connect(function()
    if S.active and S.hrp then
        pcall(function() S.hrp:SetNetworkOwner(lp) end)
    end
end)

--------------------------------------------------------------------------
-- Main loop: record history, then physical-spoof for one replication tick
--------------------------------------------------------------------------
RunService.Heartbeat:Connect(function()
    local hrp = getRoot()
    if not hrp then return end
    if S.hrp ~= hrp then refreshCache() end

    local now     = os.clock()
    local realCF  = trueProp(hrp, "CFrame")
    local realVel = trueProp(hrp, "AssemblyLinearVelocity")
    S.realCF = realCF

    -- record the true trail (used by Delay)
    table.insert(S.history, { t = now, cf = realCF, vel = realVel })
    local keepBefore = now - (S.delayMs / 1000) - 0.5
    while #S.history > 0 and S.history[1].t < keepBefore do
        table.remove(S.history, 1)
    end

    if not S.active then
        S.spoofCF = nil
        if ring then ring.Visible = false end
        return
    end

    local spoofCF, spoofVel = computeSpoof(realCF, realVel)
    S.spoofCF = spoofCF

    -- put the FAKE on the real part so the engine replicates it...
    pcall(function()
        hrp.CFrame = spoofCF
        hrp.AssemblyLinearVelocity = spoofVel
    end)

    RunService.RenderStepped:Wait()

    -- ...then snap back to the REAL position for the client.
    local hrp2 = getRoot()
    if hrp2 then
        pcall(function()
            hrp2.CFrame = realCF
            hrp2.AssemblyLinearVelocity = realVel
        end)
    end

    if ring then
        ring.Visible = true
        ring.CFrame = CFrame.new(spoofCF.Position)
    end
end)

--------------------------------------------------------------------------
-- Server-position ring (world space)
--------------------------------------------------------------------------
local ring
local function ensureRing()
    if ring and ring.Parent then return end
    ring = Instance.new("Part")
    ring.Name            = "DesyncServerRing"
    ring.Anchored        = true
    ring.CanCollide      = false
    ring.CanQuery        = false
    ring.CanTouch        = false
    ring.Massless        = true
    ring.CastShadow      = false
    ring.Material        = Enum.Material.Neon
    ring.Color           = Color3.fromRGB(120, 220, 255)
    ring.Transparency    = 0.35
    ring.Size            = Vector3.new(7, 0.25, 7)
    ring.Parent          = workspace

    local bb = Instance.new("BillboardGui")
    bb.Name        = "Label"
    bb.AlwaysOnTop = true
    bb.Size        = UDim2.fromOffset(180, 34)
    bb.StudsOffset = Vector3.new(0, 2.5, 0)
    bb.Parent      = ring

    local t = Instance.new("TextLabel")
    t.BackgroundTransparency = 1
    t.Size                   = UDim2.fromScale(1, 1)
    t.Font                   = Enum.Font.GothamBold
    t.Text                   = "\226\156\130 Server Position"
    t.TextColor3             = Color3.fromRGB(200, 240, 255)
    t.TextScaled             = true
    t.Parent                 = bb
end

--------------------------------------------------------------------------
-- Glowing snowflake "Server Position" badge (screen space)
--------------------------------------------------------------------------
local badgeGui, badgeCircle, badgeStroke, badgeRunning
local function makeBadge()
    if badgeGui then return end

    local parent
    if typeof(gethui) == "function" then
        parent = gethui()
    else
        parent = lp:WaitForChild("PlayerGui")
    end

    badgeGui = Instance.new("ScreenGui")
    badgeGui.Name           = "DesyncServerPosBadge"
    badgeGui.ResetOnSpawn   = false
    badgeGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    badgeGui.IgnoreGuiInset = true
    badgeGui.Parent         = parent

    local holder = Instance.new("Frame")
    holder.Name                   = "Holder"
    holder.AnchorPoint            = Vector2.new(0.5, 0)
    holder.Position               = UDim2.new(0.5, 0, 0, 12)
    holder.Size                   = UDim2.new(0, 230, 0, 46)
    holder.BackgroundTransparency = 1
    holder.Parent                 = badgeGui

    local layout = Instance.new("UIListLayout")
    layout.FillDirection       = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.VerticalAlignment   = Enum.VerticalAlignment.Center
    layout.Padding             = UDim.new(0, 10)
    layout.Parent              = holder

    badgeCircle = Instance.new("Frame")
    badgeCircle.Name                   = "Snowflake"
    badgeCircle.Size                   = UDim2.fromOffset(34, 34)
    badgeCircle.BackgroundColor3       = Color3.fromRGB(20, 28, 46)
    badgeCircle.BackgroundTransparency = 0.15
    badgeCircle.Parent                 = holder

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent       = badgeCircle

    badgeStroke = Instance.new("UIStroke")
    badgeStroke.Color        = Color3.fromRGB(150, 210, 255)
    badgeStroke.Thickness    = 2
    badgeStroke.Transparency = 0.2
    badgeStroke.Parent       = badgeCircle

    local glow = Instance.new("ImageLabel")
    glow.Name                   = "Glow"
    glow.BackgroundTransparency = 1
    glow.Image                  = "rbxassetid://5554247695"
    glow.ImageColor3            = Color3.fromRGB(150, 210, 255)
    glow.ImageTransparency      = 0.4
    glow.ScaleType               = Enum.ScaleType.Fit
    glow.Size                   = UDim2.new(2.2, 0, 2.2, 0)
    glow.Position               = UDim2.new(-0.6, 0, -0.6, 0)
    glow.Parent                 = badgeCircle

    local flake = Instance.new("TextLabel")
    flake.Name                   = "Flake"
    flake.BackgroundTransparency = 1
    flake.Size                   = UDim2.fromScale(1, 1)
    flake.Font                   = Enum.Font.GothamBold
    flake.Text                   = "\226\156\130"
    flake.TextColor3             = Color3.fromRGB(225, 245, 255)
    flake.TextScaled             = true
    flake.Parent                 = badgeCircle

    local label = Instance.new("TextLabel")
    label.Name                   = "Label"
    label.BackgroundTransparency = 1
    label.Size                   = UDim2.new(0, 170, 1, 0)
    label.Font                   = Enum.Font.GothamBold
    label.Text                   = "Server Position"
    label.TextColor3             = Color3.fromRGB(225, 245, 255)
    label.TextXAlignment         = Enum.TextXAlignment.Left
    label.TextScaled             = true
    label.Parent                 = holder

    task.spawn(function()
        badgeRunning = true
        while badgeRunning and badgeCircle and badgeCircle.Parent do
            local up = TweenService:Create(badgeStroke,
                TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
                { Transparency = 0, Color = Color3.fromRGB(190, 235, 255) })
            local upGlow = TweenService:Create(glow,
                TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
                { ImageTransparency = 0.15 })
            up:Play(); upGlow:Play()
            up.Completed:Wait()
            if not badgeRunning then break end
            local down = TweenService:Create(badgeStroke,
                TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
                { Transparency = 0.6, Color = Color3.fromRGB(120, 180, 235) })
            local downGlow = TweenService:Create(glow,
                TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
                { ImageTransparency = 0.7 })
            down:Play(); downGlow:Play()
            down.Completed:Wait()
        end
    end)
end

local function setBadgeVisible(on)
    if on then
        makeBadge()
        if badgeGui then badgeGui.Enabled = true end
    elseif badgeGui then
        badgeGui.Enabled = false
    end
end

--------------------------------------------------------------------------
-- Active-state helper
--------------------------------------------------------------------------
local function updateActive()
    S.active = S.enabled and S.setServerPos
    refreshCache()
    if S.active then
        ensureRing()
        if S.mode == "Freeze" and not S.frozenCF and S.hrp then
            S.frozenCF = trueProp(S.hrp, "CFrame")
        end
    else
        S.frozenCF = nil
        S.spoofCF  = nil
        if ring then ring.Visible = false end
    end
    setBadgeVisible(S.active)
end

local function resetBuffers()
    S.history  = {}
    S.frozenCF = nil
end

lp.CharacterAdded:Connect(function()
    task.wait(0.5)
    refreshCache()
    resetBuffers()
    updateActive()
end)

--------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------
local Window = Luna:CreateWindow({
    Name           = "Desync Hub",
    Subtitle       = "Luna Interface",
    LoadingEnabled = false,
})

local Tab = Window:CreateTab({
    Name        = "Desync",
    Icon        = "ac_unit",
    ImageSource = "Material",
    ShowTitle   = true,
})

Tab:CreateSection("Master")

Tab:CreateToggle({
    Name         = "Desync",
    Description  = "Master switch for the CFrame desync.",
    CurrentValue = false,
    Callback = function(v)
        S.enabled = v
        if not v then resetBuffers() end
        updateActive()
        Luna:Notification({
            Title  = "Desync",
            Content = v and "Desync enabled." or "Desync disabled.",
            Icon   = "ac_unit",
            ImageSource = "Material",
        })
    end,
})

Tab:CreateToggle({
    Name         = "Set Server Position",
    Description  = "Spoof the replicated CFrame (server sees fake).",
    CurrentValue = false,
    Callback = function(v)
        S.setServerPos = v
        updateActive()
    end,
})

Tab:CreateSection("Mode")

Tab:CreateDropdown({
    Name            = "Desync Mode",
    Description     = "Delay = trail by N ms.  Freeze = hold the saved spot.",
    Options         = { "Delay", "Freeze" },
    CurrentOption   = "Delay",
    MultipleOptions = false,
    Callback = function(opt)
        if type(opt) == "table" then opt = opt[1] end
        S.mode = opt
        resetBuffers()
        updateActive()
    end,
})

Tab:CreateSlider({
    Name         = "Delay (ms)",
    Range        = { 0, 1000 },
    Increment    = 10,
    CurrentValue = 200,
    Flag         = "DesyncDelay",
    Callback = function(v)
        S.delayMs = math.clamp(math.floor(v + 0.5), 0, 1000)
    end,
})

Tab:CreateLabel({
    Text  = "Ring = server position, character = your client position.",
    Style = 2,
})

Tab:CreateButton({
    Name        = "Re-Freeze Here",
    Description = "Move the Freeze ghost to your current position.",
    Callback = function()
        if S.mode == "Freeze" and S.active and S.hrp then
            S.frozenCF = trueProp(S.hrp, "CFrame")
        end
    end,
})

--------------------------------------------------------------------------
-- Startup notice
--------------------------------------------------------------------------
if hookOk then
    Luna:Notification({
        Title  = "Desync Hub",
        Content = "Hook installed. Enable Desync + Set Server Position. Ring shows server pos.",
        Icon   = "ac_unit",
        ImageSource = "Material",
    })
else
    Luna:Notification({
        Title  = "Desync Hub",
        Content = "hookmetamethod failed: " .. tostring(hookErr),
        Icon   = "error",
        ImageSource = "Material",
    })
    warn("[Desync Hub] hookmetamethod failed:", hookErr)
end

--------------------------------------------------------------------------
-- Cleanup (for live-reload / re-run)
--------------------------------------------------------------------------
local STATE = getgenv().__DESYNC_STATE
if STATE and STATE.onCleanup then
    STATE.onCleanup(function()
        S.enabled, S.setServerPos, S.active = false, false, false
        S.hrp, S.head, S.frozenCF, S.spoofCF, S.realCF = nil, nil, nil, nil, nil
        badgeRunning = false
        if badgeGui then badgeGui:Destroy() end
        if ring then ring:Destroy() end
    end)
end

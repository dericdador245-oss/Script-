-- Karinderya hub by DEV_TONYO

local AUTO_START = true                   -- farm and hop turn on by themselves
local SCRIPT_FILE = "karinderya_hub.lua"  -- save this script under this name in your executor's workspace folder
local SCRIPT_URL = ""                     -- or paste a raw link to the script here instead
local DEFAULT_WEBHOOK = ""
local MAX_TRIES = 5                       -- tries per stall before we skip it

local FOLDER = "DEV_TONYO_Hub"
local CONFIG_FILE = FOLDER .. "/config.json"
local STATS_FILE = FOLDER .. "/session.json"
local VISITED_FILE = FOLDER .. "/visited.json"

-- if the script gets run twice, kill the old copy first
local env = (getgenv and getgenv()) or _G
if env.DEV_TONYO_HUB_STOP then
    pcall(env.DEV_TONYO_HUB_STOP)
end

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local TextChatService = game:GetService("TextChatService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")
local VirtualUser = game:GetService("VirtualUser")
local plr = Players.LocalPlayer

local OWNER_NAME = "dador_1234567"
local isOwner = (plr.Name == OWNER_NAME) or (plr.DisplayName == OWNER_NAME)
local DISCORD_LINK = "https://discord.gg/tCvbWrtbN"

-- these only exist on some executors
local http = request or http_request or (syn and syn.request) or (fluxus and fluxus.request)
local queueTp = queue_on_teleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
local hasFiles = (isfile and readfile and writefile) and true or false

local function readJson(path, default)
    if not hasFiles then return default end
    local ok, data = pcall(function()
        if isfile(path) then
            return HttpService:JSONDecode(readfile(path))
        end
    end)
    if ok and type(data) == "table" then
        return data
    end
    return default
end

local function writeJson(path, data)
    if not hasFiles then return end
    pcall(function()
        if makefolder and isfolder and not isfolder(FOLDER) then
            makefolder(FOLDER)
        end
        writefile(path, HttpService:JSONEncode(data))
    end)
end

local function debounced(fn, delay)
    local queued = false
    return function()
        if queued then return end
        queued = true
        task.delay(delay, function()
            queued = false
            fn()
        end)
    end
end

local cfg = {
    hopMinutes = 5,
    maxPlayers = 3,        -- counts you too
    chat = true,
    chatMessage = "Plss like it",
    chatCount = 1,
    chatDelay = 3,
    hopWhenDone = false,
    antiAfk = true,
    autoRejoin = true,
    webhookUrl = DEFAULT_WEBHOOK,
    webhookOn = true,
    hookStart = true,
    hookHop = true,
    hookDone = true,
    reportEvery = 0,       -- minutes, 0 = off
    accepted = false,      -- join community accept
}

for k, v in pairs(readJson(CONFIG_FILE, {})) do
    if cfg[k] ~= nil and type(v) == type(cfg[k]) then
        cfg[k] = v
    end
end
local saveCfg = debounced(function() writeJson(CONFIG_FILE, cfg) end, 1)

-- session numbers carry over between hops
local stats = readJson(STATS_FILE, {})
if type(stats.start) ~= "number" or type(stats.updated) ~= "number" or os.time() - stats.updated > 1800 then
    stats = { start = os.time(), hops = 0, fired = 0 }
end
stats.hops = tonumber(stats.hops) or 0
stats.fired = tonumber(stats.fired) or 0

local function saveStatsNow()
    stats.updated = os.time()
    writeJson(STATS_FILE, stats)
end
local saveStats = debounced(saveStatsNow, 2)

local function visitedSet()
    local set = {}
    for _, id in ipairs(readJson(VISITED_FILE, {})) do
        set[id] = true
    end
    return set
end

local function addVisited(id)
    if not id or id == "" then return end
    local list = readJson(VISITED_FILE, {})
    table.insert(list, id)
    while #list > 40 do
        table.remove(list, 1)
    end
    writeJson(VISITED_FILE, list)
end

local function reloadCode()
    if SCRIPT_URL ~= "" then
        return ('loadstring(game:HttpGet("%s"))()'):format(SCRIPT_URL), "link"
    end
    if hasFiles then
        local ok, exists = pcall(isfile, SCRIPT_FILE)
        if ok and exists then
            return ('loadstring(readfile("%s"))()'):format(SCRIPT_FILE), "file"
        end
    end
end

-- state
local alive = true
local farmOn, hopOn = false, false
local farmId, hopId = 0, 0
local hopping = false
local hopStart = os.clock()
local doneStalls, tries = {}, {}
local status = "Starting..."
local doneCount, totalCount = 0, 0
local allDone, doneSent, busy = false, false, false
local noFireWarned = false
local chatBusy, chatIdx = false, 0

local conns = {}
local function on(signal, fn)
    local c = signal:Connect(fn)
    table.insert(conns, c)
    return c
end

local function farming(id)
    return alive and farmOn and farmId == id
end

-- filled in further down
local startFarm, startHopTimer, hop, buildEmbed, postWebhook, queueWebhook

-- chat
local function sendChat(msg)
    pcall(function()
        if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
            local ch = TextChatService.TextChannels:FindFirstChild("RBXGeneral")
            if ch then ch:SendAsync(msg) end
        else
            local ev = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
            local say = ev and ev:FindFirstChild("SayMessageRequest")
            if say then say:FireServer(msg, "All") end
        end
    end)
end

-- "hello | plss like | thanks" turns into three messages that get rotated
local function messageList()
    local list = {}
    for part in string.gmatch(cfg.chatMessage, "[^|]+") do
        local msg = part:match("^%s*(.-)%s*$")
        if msg ~= "" then
            table.insert(list, msg:sub(1, 200))
        end
    end
    return list
end

local function chatBurst()
    if chatBusy then return end
    local list = messageList()
    if #list == 0 then return end
    chatBusy = true
    task.spawn(function()
        for i = 1, cfg.chatCount do
            if not alive then break end
            chatIdx = chatIdx % #list + 1
            sendChat(list[chatIdx])
            if i < cfg.chatCount then
                task.wait(cfg.chatDelay)
            end
        end
        chatBusy = false
    end)
end

-- ui
local pal = {
    wood = Color3.fromRGB(62, 40, 24),
    dark = Color3.fromRGB(30, 18, 10),
    tan1 = Color3.fromRGB(201, 156, 92),
    tan2 = Color3.fromRGB(158, 112, 58),
    white = Color3.new(1, 1, 1),
    gold = Color3.fromRGB(255, 196, 60),
    orange = Color3.fromRGB(246, 140, 34),
    green = Color3.fromRGB(70, 200, 70),
    red = Color3.fromRGB(232, 64, 64),
    blue = Color3.fromRGB(64, 160, 255),
    purple = Color3.fromRGB(170, 80, 230),
    grey = Color3.fromRGB(140, 140, 148),
    cash = Color3.fromRGB(96, 255, 80),
}

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props or {}) do
        o[k] = v
    end
    if parent then o.Parent = parent end
    return o
end

local function corner(o, r)
    return new("UICorner", { CornerRadius = UDim.new(0, r or 8) }, o)
end

local function outline(o, color, thickness)
    return new("UIStroke", {
        Color = color or pal.dark,
        Thickness = thickness or 2,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, o)
end

local function grad(o, top, bottom)
    return new("UIGradient", { Color = ColorSequence.new(top, bottom), Rotation = 90 }, o)
end

local function shade(c, amount)
    return c:Lerp(pal.white, amount)
end

local function text(parent, str, props)
    local t = new("TextLabel", {
        BackgroundTransparency = 1,
        Text = str,
        Font = Enum.Font.FredokaOne,
        TextSize = 14,
        TextColor3 = pal.white,
        TextStrokeColor3 = pal.dark,
        TextStrokeTransparency = 0.35,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    for k, v in pairs(props or {}) do
        t[k] = v
    end
    t.Parent = parent
    return t
end

-- gradients tint text too, so the button text lives in a separate TextButton on top of the frame
local function chunky(parent, str, color, size, textSize)
    local holder = new("Frame", {
        Size = size,
        BackgroundColor3 = pal.white,
        BorderSizePixel = 0,
    }, parent)
    corner(holder, 8)
    grad(holder, shade(color, 0.3), color)
    local line = outline(holder, color:Lerp(pal.dark, 0.65), 2)
    local btn = new("TextButton", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = str,
        Font = Enum.Font.FredokaOne,
        TextSize = textSize or 15,
        TextColor3 = pal.white,
        TextStrokeColor3 = pal.dark,
        TextStrokeTransparency = 0.25,
        AutoButtonColor = false,
    }, holder)
    return holder, btn, line
end

local function pop(o)
    local s = o:FindFirstChildOfClass("UIScale") or new("UIScale", {}, o)
    s.Scale = 0.94
    TweenService:Create(s, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local gui = new("ScreenGui", {
    Name = "DEV_TONYO_Hub",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 999,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
if not pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end) or not gui.Parent then
    gui.Parent = plr:WaitForChild("PlayerGui")
end

local WIDTH, HEIGHT = 500, 350

local win = new("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(WIDTH, HEIGHT),
    BackgroundColor3 = pal.wood,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, gui)
corner(win, 12)
outline(win, pal.dark, 3)
local winScale = new("UIScale", {}, win)

local function fitToScreen()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local vp = cam.ViewportSize
    winScale.Scale = math.clamp(math.min(vp.X / (WIDTH + 40), vp.Y / (HEIGHT + 40)), 0.55, 1)
end
fitToScreen()
if workspace.CurrentCamera then
    on(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"), fitToScreen)
end

-- header with your profile
local header = new("Frame", {
    Size = UDim2.new(1, 0, 0, 56),
    BackgroundColor3 = pal.white,
    BorderSizePixel = 0,
}, win)
grad(header, Color3.fromRGB(255, 216, 96), Color3.fromRGB(240, 148, 30))
new("Frame", {
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.fromScale(0, 1),
    Size = UDim2.new(1, 0, 0, 3),
    BackgroundColor3 = pal.dark,
    BorderSizePixel = 0,
}, header)

local avatar = new("Frame", {
    Position = UDim2.fromOffset(10, 8),
    Size = UDim2.fromOffset(40, 40),
    BackgroundColor3 = Color3.fromRGB(90, 60, 36),
    BorderSizePixel = 0,
}, header)
corner(avatar, 20)
outline(avatar, pal.white, 2)
text(avatar, "Tonyo", {
    Size = UDim2.fromScale(1, 1),
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Center,
    TextYAlignment = Enum.TextYAlignment.Center,
    TextColor3 = pal.gold,
    TextStrokeTransparency = 0.2,
})

local dot = new("Frame", {
    Position = UDim2.fromOffset(38, 36),
    Size = UDim2.fromOffset(12, 12),
    BackgroundColor3 = pal.cash,
    BorderSizePixel = 0,
    ZIndex = 3,
}, header)
corner(dot, 6)
outline(dot, pal.dark, 2)

text(header, "Karinderya Hub", {
    Position = UDim2.fromOffset(60, 5),
    Size = UDim2.new(1, -150, 0, 26),
    TextSize = 21,
})
text(header, "@" .. plr.Name .. "  -  " .. plr.DisplayName, {
    Position = UDim2.fromOffset(60, 31),
    Size = UDim2.new(1, -150, 0, 16),
    TextSize = 12,
    TextColor3 = Color3.fromRGB(255, 244, 205),
    TextTruncate = Enum.TextTruncate.AtEnd,
})

local minHolder, minBtn = chunky(header, "-", pal.blue, UDim2.fromOffset(30, 30), 20)
minHolder.AnchorPoint = Vector2.new(1, 0.5)
minHolder.Position = UDim2.new(1, -46, 0.5, -1)
local closeHolder, closeBtn = chunky(header, "X", pal.red, UDim2.fromOffset(30, 30), 16)
closeHolder.AnchorPoint = Vector2.new(1, 0.5)
closeHolder.Position = UDim2.new(1, -10, 0.5, -1)

-- small bubble when minimized
local bubble = new("TextButton", {
    Position = UDim2.new(0, 14, 0.5, -24),
    Size = UDim2.fromOffset(48, 48),
    BackgroundColor3 = pal.wood,
    BorderSizePixel = 0,
    Visible = false,
    Text = "Tonyo",
    Font = Enum.Font.FredokaOne,
    TextSize = 12,
    TextColor3 = pal.gold,
    TextStrokeColor3 = pal.dark,
    TextStrokeTransparency = 0.2,
}, gui)
corner(bubble, 24)
outline(bubble, pal.gold, 3)

local function minimize(state)
    win.Visible = not state
    bubble.Visible = state
end
on(minBtn.Activated, function() pop(minHolder) minimize(true) end)
on(bubble.Activated, function() minimize(false) end)
on(UserInputService.InputBegan, function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightShift then
        minimize(win.Visible)
    end
end)

-- drag the window by the header
do
    local dragging, startInput, startPos
    on(header.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startInput = input.Position
            startPos = win.Position
        end
    end)
    on(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - startInput
            win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    on(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

-- tabs
local tabBar = new("Frame", {
    Position = UDim2.fromOffset(8, 64),
    Size = UDim2.new(1, -16, 0, 30),
    BackgroundTransparency = 1,
}, win)
new("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 4),
}, tabBar)

local body = new("Frame", {
    Position = UDim2.fromOffset(0, 100),
    Size = UDim2.new(1, 0, 1, -100),
    BackgroundTransparency = 1,
}, win)

local tabs = {}
local showTab

local function addTab(name, color)
    local page = new("ScrollingFrame", {
        Position = UDim2.fromOffset(8, 0),
        Size = UDim2.new(1, -16, 1, -8),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 6,
        ScrollBarImageColor3 = pal.gold,
        ScrollBarImageTransparency = 0,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        ScrollingEnabled = true,
        Visible = false,
    }, body)
    local layout = new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, page)
    new("UIPadding", { PaddingRight = UDim.new(0, 10), PaddingBottom = UDim.new(0, 20), PaddingTop = UDim.new(0, 2) }, page)
    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        page.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 30)
    end)

    local holder, btn, line = chunky(tabBar, name, color, UDim2.new(0.16, -3, 1, 0), 12)
    tabs[name] = { page = page, holder = holder, line = line, dark = color:Lerp(pal.dark, 0.65) }
    on(btn.Activated, function()
        pop(holder)
        showTab(name)
    end)
    return page
end

showTab = function(name)
    for n, t in pairs(tabs) do
        local selected = n == name
        t.page.Visible = selected
        t.holder.BackgroundColor3 = selected and pal.white or Color3.fromRGB(125, 125, 125)
        t.line.Color = selected and pal.white or t.dark
    end
end

local mainPage = addTab("Main", pal.green)
local chatPage = addTab("Chat", pal.orange)
local setPage = addTab("Settings", pal.blue)
local hookPage = addTab("Webhook", pal.purple)
local logPage = addTab("Log", pal.grey)
local globalPage = addTab("Global", pal.purple)

-- building blocks for the pages
local function card(page, height)
    local f = new("Frame", {
        Size = UDim2.new(1, 0, 0, height),
        BackgroundColor3 = pal.white,
        BorderSizePixel = 0,
    }, page)
    corner(f, 9)
    grad(f, pal.tan1, pal.tan2)
    outline(f, pal.dark, 2)
    return f
end

local function section(page, str)
    text(page, str, { Size = UDim2.new(1, 0, 0, 22), TextSize = 15, TextColor3 = pal.gold })
end

local function infoRow(page, key)
    local row = card(page, 30)
    text(row, key, { Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0.35, 0, 1, 0) })
    local val = text(row, "-", {
        Position = UDim2.new(0.35, 0, 0, 0),
        Size = UDim2.new(0.65, -10, 1, 0),
        TextXAlignment = Enum.TextXAlignment.Right,
        TextColor3 = pal.cash,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
    return function(str, color)
        val.Text = str
        val.TextColor3 = color or pal.cash
    end
end

local function toggle(page, name, default, callback)
    local row = card(page, 38)
    text(row, name, { Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -80, 1, 0), TextSize = 15 })

    local track = new("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -10, 0.5, 0),
        Size = UDim2.fromOffset(52, 24),
        BackgroundColor3 = pal.white,
        BorderSizePixel = 0,
    }, row)
    corner(track, 12)
    grad(track, pal.white, Color3.fromRGB(200, 200, 200))
    outline(track, pal.dark, 2)
    local knob = new("Frame", {
        Size = UDim2.fromOffset(18, 18),
        BackgroundColor3 = pal.white,
        BorderSizePixel = 0,
    }, track)
    corner(knob, 9)
    outline(knob, pal.dark, 2)

    local state = default and true or false
    local function draw(animate)
        local pos = state and UDim2.fromOffset(31, 3) or UDim2.fromOffset(3, 3)
        local col = state and pal.green or pal.grey
        if animate then
            TweenService:Create(knob, TweenInfo.new(0.15), { Position = pos }):Play()
            TweenService:Create(track, TweenInfo.new(0.15), { BackgroundColor3 = col }):Play()
        else
            knob.Position = pos
            track.BackgroundColor3 = col
        end
    end
    draw(false)

    local hit = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 3 }, row)
    on(hit.Activated, function()
        state = not state
        draw(true)
        task.spawn(callback, state)
    end)
end

local function slider(page, name, min, max, default, suffix, callback)
    local row = card(page, 54)
    text(row, name, { Position = UDim2.fromOffset(10, 3), Size = UDim2.new(1, -100, 0, 22), TextSize = 15 })
    local valText = text(row, "", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -10, 0, 3),
        Size = UDim2.fromOffset(90, 22),
        TextXAlignment = Enum.TextXAlignment.Right,
        TextColor3 = pal.cash,
        TextSize = 15,
    })

    local track = new("Frame", {
        Position = UDim2.new(0, 12, 0, 35),
        Size = UDim2.new(1, -24, 0, 8),
        BackgroundColor3 = Color3.fromRGB(70, 44, 24),
        BorderSizePixel = 0,
    }, row)
    corner(track, 4)
    outline(track, pal.dark, 2)
    local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = pal.white, BorderSizePixel = 0 }, track)
    corner(fill, 4)
    grad(fill, pal.cash, pal.green)
    local knob = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(18, 18),
        BackgroundColor3 = pal.white,
        BorderSizePixel = 0,
        ZIndex = 2,
    }, track)
    corner(knob, 9)
    outline(knob, pal.dark, 2)
    local hit = new("TextButton", {
        Position = UDim2.new(0, 4, 0, 24),
        Size = UDim2.new(1, -8, 0, 30),
        BackgroundTransparency = 1,
        Text = "",
        ZIndex = 3,
    }, row)

    local value = default
    local function draw()
        local rel = (value - min) / (max - min)
        fill.Size = UDim2.fromScale(rel, 1)
        knob.Position = UDim2.new(rel, 0, 0.5, 0)
        valText.Text = value .. suffix
    end
    draw()

    local function setFromX(x)
        local rel = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
        local v = math.floor(min + (max - min) * rel + 0.5)
        if v ~= value then
            value = v
            draw()
            callback(v)
        end
    end

    local dragging = false
    on(hit.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            page.ScrollingEnabled = false -- stops the page from scrolling while you slide
            setFromX(input.Position.X)
        end
    end)
    on(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            setFromX(input.Position.X)
        end
    end)
    on(UserInputService.InputEnded, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
            dragging = false
            page.ScrollingEnabled = true
        end
    end)
end

local function button(page, str, color, callback)
    local holder, btn = chunky(page, str, color, UDim2.new(1, 0, 0, 38), 16)
    on(btn.Activated, function()
        pop(holder)
        task.spawn(callback)
    end)
    return btn
end

local function textBox(page, title, placeholder, default)
    local row = card(page, 62)
    text(row, title, { Position = UDim2.fromOffset(10, 3), Size = UDim2.new(1, -20, 0, 22), TextSize = 15 })
    local box = new("TextBox", {
        Position = UDim2.new(0, 10, 0, 29),
        Size = UDim2.new(1, -20, 0, 26),
        BackgroundColor3 = Color3.fromRGB(48, 30, 17),
        Text = default or "",
        PlaceholderText = placeholder,
        PlaceholderColor3 = Color3.fromRGB(160, 135, 105),
        TextColor3 = pal.white,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        ClearTextOnFocus = false,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)
    corner(box, 7)
    outline(box, pal.dark, 2)
    new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, box)
    return box
end

-- toasts and log
local toasts = new("Frame", {
    Position = UDim2.new(1, -250, 0, 12),
    Size = UDim2.new(0, 238, 1, -24),
    BackgroundTransparency = 1,
}, gui)
new("UIListLayout", { Padding = UDim.new(0, 6) }, toasts)

local function notify(title, msg, secs)
    if not alive then return end
    local t = card(toasts, 48)
    local a = text(t, title, { Position = UDim2.fromOffset(10, 4), Size = UDim2.new(1, -20, 0, 20), TextColor3 = pal.gold, TextSize = 14 })
    local b = text(t, msg, { Position = UDim2.fromOffset(10, 24), Size = UDim2.new(1, -20, 0, 18), TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd })
    task.delay(secs or 3, function()
        if not t.Parent then return end
        local info = TweenInfo.new(0.25)
        TweenService:Create(t, info, { BackgroundTransparency = 1 }):Play()
        TweenService:Create(a, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
        TweenService:Create(b, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
        task.wait(0.3)
        t:Destroy()
    end)
end

local logN = 0
local function log(msg)
    if not alive then return end
    logN = logN + 1
    new("TextLabel", {
        LayoutOrder = logN,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Text = os.date("%H:%M:%S") .. "  " .. msg,
        Font = Enum.Font.Code,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(240, 225, 195),
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, logPage)

    local lines = {}
    for _, c in ipairs(logPage:GetChildren()) do
        if c:IsA("TextLabel") then table.insert(lines, c) end
    end
    table.sort(lines, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
    while #lines > 80 do
        table.remove(lines, 1):Destroy()
    end
    task.defer(function()
        logPage.CanvasPosition = Vector2.new(0, logPage.AbsoluteCanvasSize.Y)
    end)
end

-- main page
section(mainPage, "Live Status")
local setStatus = infoRow(mainPage, "Status")
local setTimer = infoRow(mainPage, "Next hop")
local setServer = infoRow(mainPage, "Server")
local setStalls = infoRow(mainPage, "Stalls")
local setSession = infoRow(mainPage, "Session")

section(mainPage, "Controls")
toggle(mainPage, "Auto walk and press prompts", AUTO_START, function(v)
    farmOn = v
    if v then
        startFarm()
    else
        status = "Auto farm is off"
    end
end)
toggle(mainPage, "Auto server hop", AUTO_START, function(v)
    hopOn = v
    if v then startHopTimer() end
end)
toggle(mainPage, "Hop as soon as every stall is done", cfg.hopWhenDone, function(v)
    cfg.hopWhenDone = v
    saveCfg()
end)
button(mainPage, "Redo every stall in this server", pal.gold, function()
    doneStalls, tries = {}, {}
    allDone, doneSent = false, false
    doneCount = 0
    log("Stalls reset, doing them all again")
end)
button(mainPage, "Hop to a new server now", pal.orange, function()
    hop()
end)

-- chat page
section(chatPage, "Chat Message")
toggle(chatPage, "Send chat messages", cfg.chat, function(v)
    cfg.chat = v
    saveCfg()
end)
local msgBox = textBox(chatPage, "Your message", "Type it here. Use | to rotate a few messages", cfg.chatMessage)
on(msgBox.FocusLost, function()
    cfg.chatMessage = msgBox.Text
    saveCfg()
    local n = #messageList()
    notify("Chat", n == 0 and "No message set" or (n .. (n == 1 and " message saved" or " messages saved")), 2)
end)
slider(chatPage, "Times to chat per stall", 1, 10, cfg.chatCount, "x", function(v)
    cfg.chatCount = v
    saveCfg()
end)
slider(chatPage, "Delay between messages", 2, 10, cfg.chatDelay, "s", function(v)
    cfg.chatDelay = v
    saveCfg()
end)
button(chatPage, "Send it now (test)", pal.gold, function()
    if #messageList() == 0 then
        notify("Chat", "Type a message first", 2)
        return
    end
    chatBurst()
end)

-- settings page
section(setPage, "Server Hop")
slider(setPage, "Hop timer", 1, 30, cfg.hopMinutes, " min", function(v)
    cfg.hopMinutes = v
    saveCfg()
end)
slider(setPage, "Max players in new server", 1, 10, cfg.maxPlayers, " players", function(v)
    cfg.maxPlayers = v
    saveCfg()
end)

section(setPage, "Safety")
local afkConn
local function setAntiAfk(v)
    if afkConn then
        afkConn:Disconnect()
        afkConn = nil
    end
    if v then
        afkConn = plr.Idled:Connect(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end
toggle(setPage, "Anti-AFK", cfg.antiAfk, function(v)
    cfg.antiAfk = v
    setAntiAfk(v)
    saveCfg()
end)
toggle(setPage, "Rejoin if disconnected", cfg.autoRejoin, function(v)
    cfg.autoRejoin = v
    saveCfg()
end)

section(setPage, "Auto-reload")
local setReload = infoRow(setPage, "After a hop")
text(setPage, "To restart in every new server, save this script as " .. SCRIPT_FILE .. " in your executor's workspace folder, or drop it in the autoexec folder.", {
    Size = UDim2.new(1, 0, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    TextWrapped = true,
    TextSize = 12,
    TextColor3 = Color3.fromRGB(235, 215, 180),
})
button(setPage, "Reset session stats", pal.red, function()
    stats = { start = os.time(), hops = 0, fired = 0 }
    saveStatsNow()
    log("Session stats reset")
end)

-- webhook page
local function maskUrl(url)
    if url == "" then return "" end
    return url:sub(1, 36) .. "........"
end

section(hookPage, "Discord Webhook")
toggle(hookPage, "Send webhook messages", cfg.webhookOn, function(v)
    cfg.webhookOn = v
    saveCfg()
end)
local urlBox = textBox(hookPage, "Webhook URL", "https://discord.com/api/webhooks/...", maskUrl(cfg.webhookUrl))
local setHook = infoRow(hookPage, "Status")

section(hookPage, "Message me when")
toggle(hookPage, "The script starts in a server", cfg.hookStart, function(v)
    cfg.hookStart = v
    saveCfg()
end)
toggle(hookPage, "It hops to a new server", cfg.hookHop, function(v)
    cfg.hookHop = v
    saveCfg()
end)
toggle(hookPage, "Every stall is done", cfg.hookDone, function(v)
    cfg.hookDone = v
    saveCfg()
end)
slider(hookPage, "Status report every (0 = off)", 0, 60, cfg.reportEvery, " min", function(v)
    cfg.reportEvery = v
    saveCfg()
end)
local testBtn = button(hookPage, "Send a test message", pal.purple, function() end)

-- global page
section(globalPage, "Community Discord")
text(globalPage, "Join the global chat and get updates. All script users share this Discord.", {
    Size = UDim2.new(1, 0, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    TextWrapped = true,
    TextSize = 13,
    TextColor3 = Color3.fromRGB(235, 215, 180),
})
button(globalPage, "Copy Discord Link", pal.purple, function()
    if setclipboard then
        setclipboard(DISCORD_LINK)
        notify("Discord", "Link copied to clipboard", 3)
    else
        notify("Discord", DISCORD_LINK, 5)
    end
    log("Discord link: " .. DISCORD_LINK)
end)
text(globalPage, DISCORD_LINK, {
    Size = UDim2.new(1, 0, 0, 20),
    TextSize = 12,
    TextColor3 = pal.cash,
    TextXAlignment = Enum.TextXAlignment.Center,
})

section(globalPage, "Global Chat")
text(globalPage, "Messages you send appear here and go out to all script users via the shared channel. Join Discord to talk live with everyone.", {
    Size = UDim2.new(1, 0, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    TextWrapped = true,
    TextSize = 12,
    TextColor3 = Color3.fromRGB(235, 215, 180),
})

local chatLog = new("ScrollingFrame", {
    Size = UDim2.new(1, 0, 0, 140),
    BackgroundColor3 = Color3.fromRGB(40, 25, 14),
    BorderSizePixel = 0,
    ScrollBarThickness = 5,
    ScrollBarImageColor3 = pal.gold,
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    CanvasSize = UDim2.new(),
}, globalPage)
corner(chatLog, 8)
outline(chatLog, pal.dark, 2)
local chatLayout = new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, chatLog)
new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4) }, chatLog)
chatLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    chatLog.CanvasSize = UDim2.new(0, 0, 0, chatLayout.AbsoluteContentSize.Y + 10)
    chatLog.CanvasPosition = Vector2.new(0, chatLog.AbsoluteCanvasSize.Y)
end)

local chatMsgN = 0
local function addChatMsg(from, msg, isAnn)
    chatMsgN = chatMsgN + 1
    local color = isAnn and pal.gold or pal.white
    local label = new("TextLabel", {
        LayoutOrder = chatMsgN,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Text = (isAnn and "[ANNOUNCEMENT] " or "") .. from .. ": " .. msg,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = color,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, chatLog)
    while #chatLog:GetChildren() > 60 do
        for _, c in ipairs(chatLog:GetChildren()) do
            if c:IsA("TextLabel") then
                c:Destroy()
                break
            end
        end
    end
end

addChatMsg("System", "Global chat ready. Type below and send.", false)

local chatInput = textBox(globalPage, "Your message", "Type global message here", "")
local sendChatBtn = button(globalPage, "Send Global Message", pal.green, function() end)

showTab("Main")

on(closeBtn.Activated, function()
    if env.DEV_TONYO_HUB_STOP then
        env.DEV_TONYO_HUB_STOP()
    end
end)

-- movement
local function flatDist(a, b)
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function moveTo(humanoid, pos, timeout)
    local finished = false
    local c = humanoid.MoveToFinished:Connect(function() finished = true end)
    humanoid:MoveTo(pos)
    local t = os.clock()
    while not finished and os.clock() - t < timeout do
        task.wait(0.1)
    end
    c:Disconnect()
    return finished
end

-- signs are usually floating a bit, so also try the floor under them
local function groundBelow(pos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { plr.Character }
    local hit = workspace:Raycast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -40, 0), params)
    return hit and hit.Position
end

local function getWaypoints(from, goals)
    for _, goal in ipairs(goals) do
        local path = PathfindingService:CreatePath({
            AgentRadius = 2,
            AgentHeight = 5,
            AgentCanJump = true,
            AgentJumpHeight = 10,
        })
        local ok = pcall(function() path:ComputeAsync(from, goal) end)
        if ok and path.Status == Enum.PathStatus.Success then
            return path:GetWaypoints()
        end
    end
end

-- doesn't wait for MoveToFinished on every waypoint, otherwise the character
-- slows down at each one and the walk looks choppy
local function followWaypoints(humanoid, root, waypoints, close, id)
    for i = 2, #waypoints do
        local wp = waypoints[i]
        if not farming(id) or humanoid.Health <= 0 then return false end
        if close() then return true end

        if wp.Action == Enum.PathWaypointAction.Jump then
            humanoid.Jump = true
        end
        humanoid:MoveTo(wp.Position)

        local started = os.clock()
        local lastPos, lastCheck = root.Position, os.clock()
        while true do
            if not farming(id) or humanoid.Health <= 0 then return false end
            if close() then return true end
            if flatDist(root.Position, wp.Position) < 2.5 then break end

            local now = os.clock()
            if now - started > 5 then return false end
            if now - lastCheck > 0.7 then
                if (root.Position - lastPos).Magnitude < 0.4 then
                    humanoid.Jump = true
                    humanoid:MoveTo(wp.Position)
                end
                lastPos, lastCheck = root.Position, now
            end
            task.wait()
        end
    end
    return true
end

local function walkTo(target, stopDist, id)
    local char = plr.Character
    if not char then return false end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root or humanoid.Health <= 0 then return false end

    local function close()
        return (root.Position - target).Magnitude <= stopDist
    end
    if close() then return true end

    local goals = { target }
    local ground = groundBelow(target)
    if ground then table.insert(goals, ground) end

    for _ = 1, 3 do
        if not farming(id) or humanoid.Health <= 0 then return false end
        local waypoints = getWaypoints(root.Position, goals)
        if not waypoints then
            moveTo(humanoid, target, 5)
            return close()
        end
        if followWaypoints(humanoid, root, waypoints, close, id) then
            return true
        end
    end
    return close()
end

local function faceTarget(humanoid, root, pos)
    humanoid:MoveTo(Vector3.new(pos.X, root.Position.Y, pos.Z))
    task.wait(0.2)
    humanoid:MoveTo(root.Position)
end

-- stalls are called Karenderya, Karenderya1, Karenderya2...
local function getStalls()
    local list = {}
    for _, c in ipairs(workspace:GetChildren()) do
        if c.Name:match("^Kar[ei]nderya%d*$") then
            table.insert(list, c)
        end
    end
    table.sort(list, function(a, b)
        return (tonumber(a.Name:match("%d+")) or 0) < (tonumber(b.Name:match("%d+")) or 0)
    end)
    return list
end

-- the prompt sits in Sign.<Default/CommonSignage/UncommonSignage>.Sign1 and similar
local function findPrompt(root)
    for _, o in ipairs(root:GetDescendants()) do
        if o:IsA("ProximityPrompt") and o.Enabled then
            return o
        end
    end
end

local function stallPrompt(stall)
    local sign = stall:FindFirstChild("Sign")
    return (sign and findPrompt(sign)) or findPrompt(stall)
end

local function promptPosition(prompt)
    local p = prompt.Parent
    if not p then return end
    if p:IsA("Attachment") then return p.WorldPosition end
    if p:IsA("BasePart") then return p.Position end
    if p:IsA("Model") then return p:GetPivot().Position end

    local part = p:FindFirstChildWhichIsA("BasePart", true)
    if part then return part.Position end
    local model = prompt:FindFirstAncestorOfClass("Model")
    if model then return model:GetPivot().Position end
end

local function press(prompt)
    if fireproximityprompt then
        fireproximityprompt(prompt)
        return true
    end
    return (pcall(function()
        prompt:InputHoldBegin()
        task.wait(math.max(prompt.HoldDuration, 0) + 0.1)
        prompt:InputHoldEnd()
    end))
end

-- gives back "fired", "noprompt" or "failed"
local function visitStall(stall, id)
    local prompt = stallPrompt(stall)
    if not prompt or not prompt.Parent then return "noprompt" end

    local dest = promptPosition(prompt)
    if not dest then return "failed" end

    if cfg.chat then
        chatBurst()
    end

    status = "Walking to " .. stall.Name
    local range = prompt.MaxActivationDistance
    walkTo(dest, math.max(range - 2 - math.random() * 1.5, 2.5), id)
    if not farming(id) then return "failed" end

    local char = plr.Character
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then return "failed" end
    if (root.Position - dest).Magnitude > range + 2 then return "failed" end

    status = "Pressing prompt at " .. stall.Name
    faceTarget(humanoid, root, dest)
    task.wait(0.25 + math.random() * 0.45)
    if not farming(id) or not prompt.Parent or not prompt.Enabled then return "failed" end

    if press(prompt) then
        return "fired"
    end

    if not noFireWarned then
        noFireWarned = true
        notify("Error", "Your executor can't press proximity prompts", 4)
        log("No fireproximityprompt, and the hold fallback failed too")
    end
    return "failed"
end

-- every stall gets done once per server, then it just waits for the hop timer
startFarm = function()
    farmId = farmId + 1
    local id = farmId
    log("Auto farm started")

    task.spawn(function()
        while farming(id) do
            local stalls = getStalls()
            local pending = {}
            for _, s in ipairs(stalls) do
                if not doneStalls[s] then table.insert(pending, s) end
            end
            totalCount = #stalls
            doneCount = #stalls - #pending

            if #pending == 0 then
                allDone = totalCount > 0
                if totalCount == 0 then
                    status = "Waiting for stalls to load..."
                else
                    status = hopOn and "All done, waiting for the hop timer" or "All stalls done"
                    if not doneSent then
                        doneSent = true
                        log("All stalls done (" .. totalCount .. ")")
                        if cfg.webhookOn and cfg.hookDone then
                            task.spawn(function()
                                queueWebhook(buildEmbed("All stalls done", 0x50C878, "Waiting for the hop timer."))
                            end)
                        end
                    end
                end
                task.wait(2)
            else
                allDone, doneSent = false, false
                local progress = false

                for _, stall in ipairs(pending) do
                    if not farming(id) then break end

                    busy = true
                    local ok, result = pcall(visitStall, stall, id)
                    busy = false
                    if not farming(id) then break end

                    if ok and result == "fired" then
                        doneStalls[stall] = true
                        doneCount = doneCount + 1
                        progress = true
                        stats.fired = stats.fired + 1
                        saveStats()
                        log("Pressed prompt at " .. stall.Name)
                        notify("Done", "Pressed " .. stall.Name, 2)
                    else
                        if not ok then
                            warn("[DEV_TONYO] " .. stall.Name .. ":", result)
                        end
                        tries[stall] = (tries[stall] or 0) + 1
                        if tries[stall] >= MAX_TRIES then
                            doneStalls[stall] = true
                            doneCount = doneCount + 1
                            log("Skipping " .. stall.Name .. " (" .. tostring(ok and result or "error") .. ")")
                        end
                    end

                    task.wait(1.5 + math.random() * 1.5)
                end

                if not progress and farming(id) then
                    task.wait(3)
                end
            end
        end
    end)
end

-- webhook
local function validHook(url)
    if type(url) ~= "string" then return false end
    return url:match("^https://discord%.com/api/webhooks/%d+/[%w%-_]+") ~= nil
        or url:match("^https://discordapp%.com/api/webhooks/%d+/[%w%-_]+") ~= nil
        or url:match("^https://canary%.discord%.com/api/webhooks/%d+/[%w%-_]+") ~= nil
        or url:match("^https://ptb%.discord%.com/api/webhooks/%d+/[%w%-_]+") ~= nil
end

local function fmtTime(sec)
    sec = math.max(0, math.floor(sec))
    local h, m = math.floor(sec / 3600), math.floor(sec % 3600 / 60)
    if h > 0 then
        return string.format("%dh %02dm", h, m)
    end
    return string.format("%dm %02ds", m, sec % 60)
end

local function clock(sec)
    sec = math.max(0, math.floor(sec))
    return string.format("%02d:%02d", math.floor(sec / 60), sec % 60)
end

local function nextHop()
    if not hopOn then return "Auto hop is off" end
    return clock(cfg.hopMinutes * 60 - (os.clock() - hopStart))
end

local avatarUrl
local function getAvatarUrl()
    if avatarUrl or not http then return avatarUrl end
    pcall(function()
        local res = http({
            Url = "https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=" .. plr.UserId .. "&size=150x150&format=Png&isCircular=true",
            Method = "GET",
        })
        local item = HttpService:JSONDecode(res.Body).data[1]
        avatarUrl = item and item.imageUrl
    end)
    return avatarUrl
end

local gameName
local function getGameName()
    if gameName then return gameName end
    local ok, info = pcall(function() return MarketplaceService:GetProductInfo(game.PlaceId) end)
    gameName = ok and info and info.Name or ("Place " .. game.PlaceId)
    return gameName
end

buildEmbed = function(title, color, desc)
    local pic = getAvatarUrl()
    return {
        title = title,
        description = desc,
        color = color,
        thumbnail = pic and { url = pic } or nil,
        fields = {
            { name = "Player", value = plr.DisplayName .. " (@" .. plr.Name .. ")", inline = true },
            { name = "Game", value = getGameName(), inline = true },
            { name = "Server", value = #Players:GetPlayers() .. "/" .. Players.MaxPlayers .. " players", inline = true },
            { name = "Stalls", value = doneCount .. "/" .. totalCount .. " done", inline = true },
            {
                name = "Session",
                value = string.format("%d prompts, %d hops, %s", stats.fired, stats.hops, fmtTime(os.time() - stats.start)),
                inline = true,
            },
            { name = "Next hop", value = nextHop(), inline = true },
            { name = "Job ID", value = "`" .. tostring(game.JobId) .. "`", inline = false },
        },
        footer = { text = "DEV_TONYO Karinderya Hub" },
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
end

-- returns true if it went through, otherwise false and a reason
postWebhook = function(embed)
    if not http then
        setHook("No request function", pal.red)
        return false, "Your executor has no request function"
    end
    if not validHook(cfg.webhookUrl) then
        setHook("Invalid URL", pal.red)
        return false, "Invalid webhook URL"
    end

    local res = http({
        Url = cfg.webhookUrl,
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = HttpService:JSONEncode({
            username = "DEV_TONYO Hub",
            avatar_url = getAvatarUrl(),
            embeds = { embed },
        }),
    })

    local code = res and (res.StatusCode or res.status_code)
    if code and code >= 200 and code < 300 then
        setHook("Sent at " .. os.date("%H:%M:%S"), pal.cash)
        return true
    end
    if code == 429 then
        local wait = 2
        pcall(function() wait = tonumber(HttpService:JSONDecode(res.Body).retry_after) or 2 end)
        task.wait(math.min(wait, 10))
        setHook("Rate limited", pal.red)
        return false, "Rate limited"
    end
    setHook("Failed (HTTP " .. tostring(code) .. ")", pal.red)
    return false, "HTTP " .. tostring(code)
end

local hookQueue, hookWorker = {}, false
queueWebhook = function(embed)
    if not cfg.webhookOn or not validHook(cfg.webhookUrl) then return end
    if #hookQueue >= 10 then table.remove(hookQueue, 1) end
    table.insert(hookQueue, embed)
    if hookWorker then return end

    hookWorker = true
    task.spawn(function()
        while alive and #hookQueue > 0 do
            local ok, err = pcall(postWebhook, table.remove(hookQueue, 1))
            if not ok then
                setHook("Error", pal.red)
                log("Webhook error: " .. tostring(err))
            end
            task.wait(1.2)
        end
        hookWorker = false
    end)
end

-- the box shows a masked link unless you're typing in it
on(urlBox.Focused, function()
    urlBox.Text = cfg.webhookUrl
end)
on(urlBox.FocusLost, function()
    local url = urlBox.Text:gsub("%s+", "")
    if url == "" then
        cfg.webhookUrl = ""
        setHook("No URL set", pal.white)
    elseif validHook(url) then
        cfg.webhookUrl = url
        setHook("URL saved", pal.cash)
        log("Webhook URL saved")
    else
        setHook("Invalid URL", pal.red)
        notify("Webhook", "That isn't a Discord webhook link", 3)
    end
    saveCfg()
    urlBox.Text = maskUrl(cfg.webhookUrl)
end)

on(testBtn.Activated, function()
    task.spawn(function()
        if not validHook(cfg.webhookUrl) then
            notify("Webhook", "Add a webhook URL first", 3)
            return
        end
        local ok, sent, err = pcall(postWebhook, buildEmbed("Test message", 0xFF8C42, "Your webhook works."))
        if ok and sent then
            notify("Webhook", "Test message sent", 3)
        else
            notify("Webhook", "Failed: " .. tostring(ok and err or sent), 4)
        end
    end)
end)

on(sendChatBtn.Activated, function()
    local msg = chatInput.Text:match("^%s*(.-)%s*$") or ""
    if msg == "" then
        notify("Chat", "Type a message first", 2)
        return
    end
    chatInput.Text = ""
    addChatMsg(plr.DisplayName, msg, false)
    log("Global chat: " .. msg)
    if cfg.webhookOn and validHook(cfg.webhookUrl) then
        task.spawn(function()
            pcall(postWebhook, buildEmbed("Global Chat", 0x9B59B6, "**" .. plr.DisplayName .. "**: " .. msg))
        end)
    end
    notify("Chat", "Message sent", 2)
end)

if isOwner then
    section(globalPage, "Owner Announcement")
    local annBox = textBox(globalPage, "Announcement text", "Type your global announcement here", "")
    button(globalPage, "Send Global Announcement", pal.gold, function()
        local msg = annBox.Text:match("^%s*(.-)%s*$") or ""
        if msg == "" then
            notify("Announcement", "Type a message first", 2)
            return
        end
        addChatMsg("OWNER", msg, true)
        log("Owner announcement: " .. msg)
        if validHook(cfg.webhookUrl) then
            task.spawn(function()
                local ok, sent, err = pcall(postWebhook, buildEmbed("GLOBAL ANNOUNCEMENT", 0xFFD700, msg))
                if ok and sent then
                    notify("Announcement", "Sent to all users", 3)
                else
                    notify("Announcement", "Local only: " .. tostring(ok and err or sent), 4)
                end
            end)
        else
            notify("Announcement", "Sent locally (set webhook for all users)", 3)
        end
    end)
else
    text(globalPage, "Only the owner can send global announcements.", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        TextWrapped = true,
        TextSize = 13,
        TextColor3 = Color3.fromRGB(235, 215, 180),
    })
end

-- server hop
on(TeleportService.TeleportInitFailed, function()
    hopping = false
end)

local function getPage(url)
    for _ = 1, 2 do
        local ok, data = pcall(function()
            local res = http({ Url = url, Method = "GET" })
            if res.StatusCode and res.StatusCode ~= 200 then
                error("HTTP " .. res.StatusCode)
            end
            return HttpService:JSONDecode(res.Body)
        end)
        if ok and type(data) == "table" then
            return data
        end
        task.wait(2)
    end
end

-- gives back servers we haven't been in, and ones we have
local function findServers()
    local fresh, seen = {}, {}
    if not http then return fresh, seen end

    local visited = visitedSet()
    local cursor
    for _ = 1, 3 do
        local url = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100"
        if cursor then
            url = url .. "&cursor=" .. HttpService:UrlEncode(cursor)
        end

        local page = getPage(url)
        if not page then break end

        for _, s in ipairs(page.data or {}) do
            if type(s) == "table" and s.id ~= game.JobId and s.playing and s.maxPlayers and s.playing < s.maxPlayers then
                table.insert(visited[s.id] and seen or fresh, s)
            end
        end

        cursor = page.nextPageCursor
        if not cursor then break end
        task.wait(0.5)
    end
    return fresh, seen
end

local function pickSmall(list)
    local small = {}
    for _, s in ipairs(list) do
        if s.playing + 1 <= cfg.maxPlayers then
            table.insert(small, s)
        end
    end
    if #small > 0 then
        return small[math.random(#small)]
    end
end

local function pickEmptiest(list)
    if #list == 0 then return end
    table.sort(list, function(a, b) return a.playing < b.playing end)
    return list[math.random(math.min(#list, 5))]
end

local reloadWarned = false

hop = function()
    if hopping then return end
    hopping = true
    task.delay(25, function() hopping = false end)

    status = "Hopping..."
    notify("Server hop", "Looking for a new server...", 3)
    log("Looking for a server with " .. cfg.maxPlayers .. " players or less (you included)")

    local fresh, seen = findServers()
    local pick = pickSmall(fresh) or pickSmall(seen) or pickEmptiest(fresh) or pickEmptiest(seen)
    if pick then
        log("Found one with " .. pick.playing .. " player(s)")
    else
        log("Couldn't get a server list, doing a normal teleport")
    end

    local code = reloadCode()
    if queueTp and code then
        pcall(queueTp, code)
    elseif not reloadWarned then
        reloadWarned = true
        log("Auto-reload is off, save the script as " .. SCRIPT_FILE .. " in your workspace folder")
        notify("Auto-reload is off", "Save the script as " .. SCRIPT_FILE, 5)
    end

    stats.hops = stats.hops + 1
    saveStatsNow()
    addVisited(game.JobId)

    if cfg.webhookOn and cfg.hookHop and validHook(cfg.webhookUrl) then
        local desc = pick and ("Hopping to a server with " .. pick.playing .. " player(s).") or "Hopping with a normal teleport."
        pcall(postWebhook, buildEmbed("Server hop", 0x6366F1, desc))
    end

    local ok = pcall(function()
        if pick then
            TeleportService:TeleportToPlaceInstance(game.PlaceId, pick.id, plr)
        else
            TeleportService:Teleport(game.PlaceId, plr)
        end
    end)
    if not ok then
        hopping = false
    end
end

-- waits for the timer, lets the current stall finish, then hops
startHopTimer = function()
    hopId = hopId + 1
    local id = hopId
    hopStart = os.clock()
    log("Hop timer started (" .. cfg.hopMinutes .. " min)")

    task.spawn(function()
        while alive and hopOn and hopId == id do
            local timeUp = os.clock() - hopStart >= cfg.hopMinutes * 60
            local finishedEarly = cfg.hopWhenDone and allDone and farmOn

            if timeUp or finishedEarly then
                local waited = 0
                while busy and waited < 20 do
                    task.wait(0.5)
                    waited = waited + 0.5
                end
                if alive and hopOn and hopId == id then
                    hop()
                    task.wait(15) -- still here means the hop failed, so try again in a bit
                end
            else
                task.wait(1)
            end
        end
    end)
end

-- rejoin when we get kicked or disconnected
task.spawn(function()
    local lastTry = 0
    local ok = pcall(function()
        local prompts = game:GetService("CoreGui"):WaitForChild("RobloxPromptGui", 30)
        local overlay = prompts and prompts:WaitForChild("promptOverlay", 30)
        if not overlay then return end
        on(overlay.ChildAdded, function(child)
            if child.Name == "ErrorPrompt" and cfg.autoRejoin and alive and os.clock() - lastTry > 10 then
                lastTry = os.clock()
                log("Got disconnected, rejoining...")
                task.wait(3)
                hop()
            end
        end)
    end)
    if not ok then
        log("Rejoin on disconnect doesn't work on this executor")
    end
end)

-- periodic webhook report
task.spawn(function()
    local last = os.clock()
    while alive do
        task.wait(5)
        if cfg.reportEvery > 0 and cfg.webhookOn and os.clock() - last >= cfg.reportEvery * 60 then
            last = os.clock()
            queueWebhook(buildEmbed("Status report", 0xFF8C42, status))
        end
    end
end)

-- keeps the status rows up to date
task.spawn(function()
    while alive do
        pcall(function()
            setStatus(status)
            setTimer(nextHop())
            setServer(#Players:GetPlayers() .. "/" .. Players.MaxPlayers .. " players")
            setStalls(doneCount .. "/" .. totalCount .. " done")
            setSession(string.format("%d pressed, %d hops, %s", stats.fired, stats.hops, fmtTime(os.time() - stats.start)))
        end)
        task.wait(1)
    end
end)

local function shutdown()
    if not alive then return end
    alive = false
    farmOn, hopOn = false, false
    farmId = farmId + 1
    hopId = hopId + 1
    writeJson(CONFIG_FILE, cfg)
    saveStatsNow()
    for _, c in ipairs(conns) do
        pcall(function() c:Disconnect() end)
    end
    if afkConn then afkConn:Disconnect() end
    gui:Destroy()
    if env.DEV_TONYO_HUB_STOP == shutdown then
        env.DEV_TONYO_HUB_STOP = nil
    end
end
env.DEV_TONYO_HUB_STOP = shutdown

-- start
setAntiAfk(cfg.antiAfk)

local code, kind = reloadCode()
if not queueTp then
    setReload("Off (no queue_on_teleport)", pal.red)
elseif code then
    setReload("On (" .. kind .. ")", pal.cash)
else
    setReload("Off, save as " .. SCRIPT_FILE, pal.red)
end

if validHook(cfg.webhookUrl) then
    setHook("Ready", pal.cash)
else
    setHook("No URL set", pal.white)
end

log("Hub loaded")
if not hasFiles then
    log("No file functions here, so settings won't be saved")
end

local function startHub()
    if AUTO_START then
        farmOn = true
        startFarm()
        hopOn = true
        startHopTimer()
    end
    if cfg.hookStart then
        task.delay(5, function()
            if alive then
                queueWebhook(buildEmbed("Hub started", 0xFF8C42, "Script loaded in this server."))
            end
        end)
    end
end

if isOwner or cfg.accepted then
    startHub()
else
    local joinFrame = new("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BackgroundTransparency = 0.4,
        ZIndex = 50,
    }, gui)
    local joinCard = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(360, 220),
        BackgroundColor3 = pal.wood,
        BorderSizePixel = 0,
        ZIndex = 51,
    }, joinFrame)
    corner(joinCard, 12)
    outline(joinCard, pal.gold, 3)
    text(joinCard, "Join Karinderya Hub", {
        Position = UDim2.fromOffset(0, 16),
        Size = UDim2.new(1, 0, 0, 28),
        TextSize = 20,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextColor3 = pal.gold,
        ZIndex = 52,
    })
    text(joinCard, "Accept to join the community and unlock the script. You get access to global chat on Discord.", {
        Position = UDim2.fromOffset(20, 52),
        Size = UDim2.new(1, -40, 0, 60),
        TextSize = 13,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextColor3 = Color3.fromRGB(235, 215, 180),
        ZIndex = 52,
    })
    text(joinCard, DISCORD_LINK, {
        Position = UDim2.fromOffset(0, 115),
        Size = UDim2.new(1, 0, 0, 18),
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextColor3 = pal.cash,
        ZIndex = 52,
    })
    local acceptHolder, acceptBtn = chunky(joinCard, "Accept and Join", pal.green, UDim2.new(0.7, 0, 0, 40), 16)
    acceptHolder.AnchorPoint = Vector2.new(0.5, 1)
    acceptHolder.Position = UDim2.new(0.5, 0, 1, -20)
    acceptHolder.ZIndex = 52
    acceptBtn.ZIndex = 53
    on(acceptBtn.Activated, function()
        pop(acceptHolder)
        cfg.accepted = true
        saveCfg()
        joinFrame:Destroy()
        notify("Welcome", "You joined the community", 3)
        log("Community accepted")
        startHub()
    end)
end

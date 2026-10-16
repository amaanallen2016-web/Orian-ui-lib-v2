--[[
    UI Library (improved)

    Changes vs. original:
      * Every connection/instance is tracked and cleaned up -> Window:Destroy()
      * Single window-level drag + outside-click handlers (no per-component global listeners)
      * Window drags by the bottom bar only (UIDragDetector made sliders/pickers drag the window)
      * Only one popup (dropdown / colorpicker) open at a time; popups close on drag, tab switch, scroll
      * Touch support in sliders and colorpicker
      * Theme bindings are declarative (Themed) instead of hand-written update functions
      * Working config system (Save / Load / List) + live theme editor in the Configuration tab
      * Keybind: Callback = key pressed, OnChanged = key rebound, Escape clears
      * New: Label, Section, Window:Notify, Window:Destroy, Library:Unload, Numeric textbox
      * Toggle has a real checkmark; Toggle:Colorpicker returns the picker object
      * Fixed: Create() sets Parent last, deprecated TextService removed, duplicate-flag warnings,
        dropdown returns a copy of its selection, SetValue(val, silent) everywhere
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local Theme = {
	Body = Color3.fromRGB(20, 20, 26),
	Sidebar = Color3.fromRGB(26, 26, 34),
	Main = Color3.fromRGB(30, 30, 40),
	Search = Color3.fromRGB(35, 35, 45),
	TextPrimary = Color3.fromRGB(240, 240, 245),
	TextSecondary = Color3.fromRGB(130, 130, 145),
	Accent = Color3.fromRGB(225, 225, 245),
	Border = Color3.fromRGB(45, 45, 58),
	Font = Enum.Font.GothamMedium,
}

local Icons = {
	Placeholder = "rbxassetid://11419709766",
	Save = "rbxassetid://11419703493",
	Search = "rbxassetid://11293977875",
	Keyboard = "rbxassetid://12974370712",
	ChevronDown = "rbxassetid://11421095840",
	Pipette = "rbxassetid://11419718822",
	Checkmark = "rbxassetid://10709790644",
}

local TweenFast = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TweenSmooth = TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local TweenDrag = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DarkIcon = Color3.fromRGB(17, 17, 17)

-- Global, user-tweakable settings (changed through Library:SetSetting, type-checked)
local Settings = {
	Performance = "High",      -- High | Balanced | Low
	AnimSpeed = 1,             -- 0 = (almost) instant
	UIScale = 1,
	CornerScale = 1,
	WindowTransparency = 0,    -- acrylic look (needs Blur for the full effect)
	Blur = false, BlurSize = 18,
	DOF = false, DOFFocusDistance = 0, DOFInFocusRadius = 40, DOFFarIntensity = 0.4, DOFNearIntensity = 0,
	Tilt = false, TiltStrength = 3, TiltSmoothness = 10, TiltParallax = true,
	HighlightMaxLength = 20000, MaxCodeLength = 60000,
	PollInterval = 0.2,
	LogicMaxPerSecond = 20,
	AllowRemote = false,
	SafeCallbacks = true,
}

---------------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------------

local function Create(Class, Props)
	local Inst = Instance.new(Class)
	local Parent = Props.Parent
	for Key, Value in Props do
		if Key ~= "Parent" then Inst[Key] = Value end
	end
	if Parent then Inst.Parent = Parent end
	return Inst
end

local Corners = setmetatable({}, {__mode = "k"})
local function Corner(Parent, Radius, Round)
	local Scaled = Round and Radius or math.floor(Radius * Settings.CornerScale + 0.5)
	local C = Create("UICorner", {CornerRadius = UDim.new(0, Scaled), Parent = Parent})
	if not Round then Corners[C] = Radius end
	return C
end

local function Tween(Inst, Info, Props)
	local Speed = Settings.AnimSpeed
	local Time = Speed > 0 and math.max(Info.Time / Speed, 0.01) or 0.01
	local Tw = TweenService:Create(Inst, TweenInfo.new(Time, Info.EasingStyle, Info.EasingDirection), Props)
	Tw:Play()
	return Tw
end

-- Tween, or apply instantly
local function Set(Inst, Props, Instant, Info)
	if Instant then
		for Key, Value in Props do Inst[Key] = Value end
	else
		Tween(Inst, Info or TweenFast, Props)
	end
end

local function IsPress(Input)
	return Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch
end

local function IsMove(Input)
	return Input.UserInputType == Enum.UserInputType.MouseMovement or Input.UserInputType == Enum.UserInputType.Touch
end

local function Inside(Gui, Pos)
	local A, S = Gui.AbsolutePosition, Gui.AbsoluteSize
	return Pos.X >= A.X and Pos.X <= A.X + S.X and Pos.Y >= A.Y and Pos.Y <= A.Y + S.Y
end

local function FormatKeyName(Key)
	if not Key then return "None" end
	local Name = Key.Name
	if Name == "MouseButton1" then return "MB1" end
	if Name == "MouseButton2" then return "MB2" end
	if Name == "MouseButton3" then return "MB3" end
	return Name
end

local function Noop() end

-- Wraps user callbacks so one bad callback can't break the UI
local function Safe(Fn)
	if type(Fn) ~= "function" then return Noop end
	return function(...)
		if not Settings.SafeCallbacks then return Fn(...) end
		local Ok, Err = pcall(Fn, ...)
		if not Ok then warn("[UILibrary] callback error: " .. tostring(Err)) end
	end
end

-- Connection / instance bookkeeping
local Maid = {}
Maid.__index = Maid
function Maid.new() return setmetatable({Tasks = {}}, Maid) end
function Maid:Give(Task) table.insert(self.Tasks, Task); return Task end
function Maid:Clean()
	for _, Task in self.Tasks do
		local Kind = typeof(Task)
		if Kind == "RBXScriptConnection" then Task:Disconnect()
		elseif Kind == "Instance" then Task:Destroy()
		elseif Kind == "function" then pcall(Task) end
	end
	table.clear(self.Tasks)
end

-- Theme hooks (functions re-run when the theme changes)
local ThemeHooks = {}
local function AddThemeHook(Fn)
	table.insert(ThemeHooks, Fn)
	return function()
		local I = table.find(ThemeHooks, Fn)
		if I then table.remove(ThemeHooks, I) end
	end
end

local Library = {
	ToggleKey = nil,
	Flags = {},
	Windows = {},
	ConfigFolder = "UILibrary",
	Settings = Settings,
	SettingHooks = {},
	TabExtensions = {},
	WindowExtensions = {},
}

function Library:FireEvent() end -- replaced by the logic engine below

function Library:SetSetting(Key, Value)
	if Settings[Key] == nil or type(Settings[Key]) ~= type(Value) then return false end
	Settings[Key] = Value
	if Key == "CornerScale" then Library:ApplyCorners() end
	for _, Fn in table.clone(Library.SettingHooks) do pcall(Fn, Key, Value) end
	return true
end

function Library:ApplyCorners()
	for C, R in Corners do C.CornerRadius = UDim.new(0, math.floor(R * Settings.CornerScale + 0.5)) end
end

function Library:SetWindowKeybind(KeyEnum) self.ToggleKey = KeyEnum end
function Library:GetTheme() return Theme end

function Library:SetTheme(NewTheme)
	for Key, Value in NewTheme do
		if Theme[Key] ~= nil then Theme[Key] = Value end
	end
	for _, Fn in table.clone(ThemeHooks) do pcall(Fn) end
end

---------------------------------------------------------------------------
-- Config (needs an executor/environment with file functions; otherwise returns false)
---------------------------------------------------------------------------

local function HasFiles()
	return typeof(writefile) == "function" and typeof(readfile) == "function"
		and typeof(isfile) == "function" and typeof(makefolder) == "function" and typeof(isfolder) == "function"
end

function Library:Serialize()
	local Out = {}
	for Flag, Obj in self.Flags do
		if string.sub(Flag, 1, 1) == "_" then continue end
		local Kind = Obj:GetComponentType()
		if Kind == "Button" then continue end
		local Value = Obj:GetValue()
		if Kind == "Colorpicker" then
			Out[Flag] = {Color = Value:ToHex(), Alpha = Obj:GetTransparency()}
		elseif Kind == "Keybind" then
			Out[Flag] = Value and {Type = tostring(Value.EnumType), Name = Value.Name} or false
		else
			Out[Flag] = Value
		end
	end
	return HttpService:JSONEncode(Out)
end

function Library:Deserialize(Json)
	local Ok, Data = pcall(function() return HttpService:JSONDecode(Json) end)
	if not Ok or type(Data) ~= "table" then return false end
	for Flag, Value in Data do
		local Obj = self.Flags[Flag]
		if not Obj then continue end
		pcall(function()
			local Kind = Obj:GetComponentType()
			if Kind == "Colorpicker" then
				Obj:SetValue(Color3.fromHex(Value.Color))
				Obj:SetTransparency(Value.Alpha)
			elseif Kind == "Keybind" then
				Obj:SetValue(Value and Enum[Value.Type][Value.Name] or nil)
			elseif Kind ~= "Button" then
				Obj:SetValue(Value)
			end
		end)
	end
	return true
end

function Library:SaveConfig(Name)
	if not HasFiles() then return false, "File API not available" end
	if not isfolder(self.ConfigFolder) then makefolder(self.ConfigFolder) end
	Name = string.gsub(Name or "default", "[^%w_%- ]", "")
	if Name == "" then return false, "Invalid name" end
	writefile(`{self.ConfigFolder}/{Name}.json`, self:Serialize())
	return true
end

function Library:LoadConfig(Name)
	if not HasFiles() then return false, "File API not available" end
	local Path = `{self.ConfigFolder}/{Name}.json`
	if not isfile(Path) then return false, "Config not found" end
	return self:Deserialize(readfile(Path))
end

function Library:ListConfigs()
	local Out = {}
	if HasFiles() and typeof(listfiles) == "function" and isfolder(self.ConfigFolder) then
		for _, Path in listfiles(self.ConfigFolder) do
			local Name = string.match(Path, "([^/\\]+)%.json$")
			if Name then table.insert(Out, Name) end
		end
	end
	return Out
end

function Library:Unload()
	for _, Win in table.clone(self.Windows) do Win:Destroy() end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

function Library:Window(Options)
	Options = Options or {}
	local SubTitle = Options.SubTitle or "v1.0.0"
	local Janitor = Maid.new()
	local FlagNames = {}

	if Options.ToggleKey then Library.ToggleKey = Options.ToggleKey end

	local ScreenGui = Create("ScreenGui", {
		Name = Options.Name or "UILibrary",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 100,
	})
	if not pcall(function() ScreenGui.Parent = CoreGui end) then
		ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	end
	Janitor:Give(ScreenGui)

	-- Bind instance properties to theme keys: Themed(label, {TextColor3 = "TextPrimary"})
	local function Themed(Inst, Map)
		local function Apply()
			for Prop, Key in Map do Inst[Prop] = Theme[Key] end
		end
		Apply()
		Janitor:Give(AddThemeHook(Apply))
	end
	local function OnTheme(Fn) Janitor:Give(AddThemeHook(Fn)) end

	local function Register(Flag, Obj)
		if Library.Flags[Flag] and not FlagNames[Flag] then
			warn(`[UILibrary] Duplicate flag "{Flag}" - give one of them a unique Flag option`)
		end
		Library.Flags[Flag] = Obj
		FlagNames[Flag] = true
	end

	local Screen = ScreenGui.AbsoluteSize
	local WinW = Screen.X > 0 and math.min(Options.Width or 850, Screen.X - 20) or (Options.Width or 850)
	local WinH = Screen.Y > 0 and math.min(Options.Height or 550, Screen.Y - 20) or (Options.Height or 550)

	local MainFrame = Create("CanvasGroup", {
		Size = UDim2.fromOffset(WinW, WinH),
		Position = UDim2.fromOffset(math.max((Screen.X - WinW) / 2, 0), math.max((Screen.Y - WinH) / 2, 0)),
		BackgroundColor3 = Theme.Body, BorderSizePixel = 0, GroupTransparency = 0, Parent = ScreenGui,
	})
	Corner(MainFrame, 8)
	Themed(MainFrame, {BackgroundColor3 = "Body"})

	local BottomBar = Create("Frame", {Size = UDim2.new(1, 0, 0, 64), Position = UDim2.new(0, 0, 1, -64), BackgroundColor3 = Theme.Sidebar, BorderSizePixel = 0, Parent = MainFrame})
	Themed(BottomBar, {BackgroundColor3 = "Sidebar"})

	-- Profile
	local ProfileFrame = Create("Frame", {Size = UDim2.new(0, 200, 1, 0), Position = UDim2.new(0, 20, 0, 0), BackgroundTransparency = 1, Parent = BottomBar})
	local Avatar = Create("ImageLabel", {Size = UDim2.fromOffset(40, 40), Position = UDim2.new(0, 0, 0.5, -20), BackgroundColor3 = Theme.Search, Parent = ProfileFrame})
	Corner(Avatar, 20, true)
	Themed(Avatar, {BackgroundColor3 = "Search"})
	task.spawn(function()
		local Ok, Thumb = pcall(function()
			return Players:GetUserThumbnailAsync(LocalPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
		end)
		if Ok and Avatar.Parent then Avatar.Image = Thumb end
	end)
	local ProfileName = Create("TextLabel", {Size = UDim2.new(1, -52, 0, 20), Position = UDim2.new(0, 52, 0.5, -18), BackgroundTransparency = 1, Text = LocalPlayer.DisplayName or "User", TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = ProfileFrame})
	local ProfileSub = Create("TextLabel", {Size = UDim2.new(1, -52, 0, 16), Position = UDim2.new(0, 52, 0.5, 2), BackgroundTransparency = 1, Text = SubTitle, TextColor3 = Theme.TextSecondary, Font = Theme.Font, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, Parent = ProfileFrame})
	Themed(ProfileName, {TextColor3 = "TextPrimary", Font = "Font"})
	Themed(ProfileSub, {TextColor3 = "TextSecondary", Font = "Font"})

	-- Tab nav (grows with the number of tabs)
	local TabNav = Create("Frame", {Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Position = UDim2.fromScale(0.5, 0), AnchorPoint = Vector2.new(0.5, 0), BackgroundTransparency = 1, Parent = BottomBar})
	Create("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12), Parent = TabNav})

	-- Actions (save + search)
	local ActionContainer = Create("Frame", {Size = UDim2.new(0, 250, 1, 0), Position = UDim2.new(1, -270, 0, 0), BackgroundTransparency = 1, Parent = BottomBar})
	Create("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 12), Parent = ActionContainer})

	local SaveBtn = Create("TextButton", {Size = UDim2.fromOffset(40, 40), BackgroundColor3 = Theme.Search, Text = "", AutoButtonColor = false, LayoutOrder = 2, Parent = ActionContainer})
	Corner(SaveBtn, 8)
	local SaveIcon = Create("ImageLabel", {Size = UDim2.fromOffset(20, 20), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Image = Icons.Save, ImageColor3 = Theme.TextSecondary, Parent = SaveBtn})

	local SearchBar = Create("Frame", {Size = UDim2.fromOffset(160, 40), BackgroundColor3 = Theme.Search, LayoutOrder = 1, Parent = ActionContainer})
	Corner(SearchBar, 8)
	Themed(SearchBar, {BackgroundColor3 = "Search"})
	local SearchIcon = Create("ImageLabel", {Size = UDim2.fromOffset(16, 16), Position = UDim2.new(0, 12, 0.5, -8), BackgroundTransparency = 1, Image = Icons.Search, ImageColor3 = Theme.TextSecondary, Parent = SearchBar})
	Themed(SearchIcon, {ImageColor3 = "TextSecondary"})
	local SearchBox = Create("TextBox", {Size = UDim2.new(1, -40, 1, 0), Position = UDim2.new(0, 36, 0, 0), BackgroundTransparency = 1, Text = "", PlaceholderText = "Search...", ClearTextOnFocus = false, TextColor3 = Theme.TextPrimary, PlaceholderColor3 = Theme.TextSecondary, Font = Theme.Font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, Parent = SearchBar})
	Themed(SearchBox, {TextColor3 = "TextPrimary", PlaceholderColor3 = "TextSecondary", Font = "Font"})

	-- Content
	local ContentArea = Create("Frame", {Size = UDim2.new(1, 0, 1, -64), BackgroundTransparency = 1, Parent = MainFrame})
	local TabContainer = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = ContentArea})

	local SearchContent = Create("ScrollingFrame", {Size = UDim2.new(1, -40, 1, -40), Position = UDim2.fromOffset(20, 20), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4, ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false, Parent = TabContainer})
	Themed(SearchContent, {ScrollBarImageColor3 = "Accent"})
	Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = SearchContent})

	local NoResults = Create("TextLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "No results found", TextColor3 = Theme.TextSecondary, Font = Theme.Font, TextSize = 16, Visible = false, Parent = TabContainer})
	Themed(NoResults, {TextColor3 = "TextSecondary", Font = "Font"})

	local WindowObj = {
		ScreenGui = ScreenGui,
		Tabs = {},
		AllRows = {},
		CurrentTab = nil,
		Watermarks = {},
		ActivePopup = nil,
		Binding = false,
		Visible = true,
	}

	-----------------------------------------------------------------------
	-- Popups (only one open at a time)
	-----------------------------------------------------------------------
	function WindowObj:OpenPopup(Popup)
		if self.ActivePopup and self.ActivePopup ~= Popup then self.ActivePopup.Close() end
		self.ActivePopup = Popup
	end
	function WindowObj:ClosePopup()
		local P = self.ActivePopup
		self.ActivePopup = nil
		if P then P.Close() end
	end

	Janitor:Give(UserInputService.InputBegan:Connect(function(Input)
		local P = WindowObj.ActivePopup
		if not P or not IsPress(Input) then return end
		for _, Frame in P.Frames do
			if Inside(Frame, Input.Position) then return end
		end
		WindowObj:ClosePopup()
	end))

	-----------------------------------------------------------------------
	-- Single shared drag handler (window drag, sliders, color picker)
	-----------------------------------------------------------------------
	local ActiveDrag = nil
	local function BeginDrag(Fn) ActiveDrag = Fn end
	Janitor:Give(UserInputService.InputChanged:Connect(function(Input)
		if ActiveDrag and IsMove(Input) then ActiveDrag(Input) end
	end))
	Janitor:Give(UserInputService.InputEnded:Connect(function(Input)
		if ActiveDrag and IsPress(Input) then ActiveDrag = nil end
	end))

	Janitor:Give(BottomBar.InputBegan:Connect(function(Input)
		if not IsPress(Input) then return end
		WindowObj:ClosePopup()
		local StartMouse = Vector2.new(Input.Position.X, Input.Position.Y)
		local StartX, StartY = MainFrame.Position.X.Offset, MainFrame.Position.Y.Offset
		BeginDrag(function(Move)
			local Bounds, Size = ScreenGui.AbsoluteSize, MainFrame.AbsoluteSize
			local X = math.clamp(StartX + Move.Position.X - StartMouse.X, 0, math.max(Bounds.X - Size.X, 0))
			local Y = math.clamp(StartY + Move.Position.Y - StartMouse.Y, 0, math.max(Bounds.Y - Size.Y, 0))
			MainFrame.Position = UDim2.fromOffset(X, Y)
		end)
	end))

	-----------------------------------------------------------------------
	-- Visibility
	-----------------------------------------------------------------------
	function WindowObj:SetVisible(State)
		if self.Visible == State then return end
		self.Visible = State
		if State then
			MainFrame.Visible = true
			Tween(MainFrame, TweenSmooth, {GroupTransparency = 0})
		else
			self:ClosePopup()
			local Tw = Tween(MainFrame, TweenSmooth, {GroupTransparency = 1})
			Tw.Completed:Once(function()
				if not self.Visible then MainFrame.Visible = false end
			end)
		end
		for _, Wm in self.Watermarks do Wm:UpdatePosition() end
	end
	function WindowObj:ToggleVisibility() self:SetVisible(not self.Visible) end

	Janitor:Give(UserInputService.InputBegan:Connect(function(Input, Processed)
		if Processed or WindowObj.Binding then return end
		if Library.ToggleKey and Input.KeyCode == Library.ToggleKey then WindowObj:ToggleVisibility() end
	end))

	-----------------------------------------------------------------------
	-- Watermark
	-----------------------------------------------------------------------
	local function WatermarkReposition()
		for _, Wm in WindowObj.Watermarks do Wm:UpdatePosition() end
	end
	Janitor:Give(MainFrame:GetPropertyChangedSignal("AbsolutePosition"):Connect(WatermarkReposition))
	Janitor:Give(MainFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(WatermarkReposition))

	function WindowObj:Watermark(InitialText)
		local Frame = Create("Frame", {BackgroundColor3 = Theme.Sidebar, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, ClipsDescendants = true, ZIndex = 5000, Parent = ScreenGui})
		Corner(Frame, 6)
		Create("UIPadding", {PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = Frame})
		local Stroke = Create("UIStroke", {Color = Theme.Border, Thickness = 1, Parent = Frame})
		local TopAccent = Create("Frame", {BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1), ZIndex = 5001, Parent = Frame})
		Create("UIGradient", {Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.15, 0),
			NumberSequenceKeypoint.new(0.85, 0), NumberSequenceKeypoint.new(1, 1),
		}), Parent = TopAccent})
		local Text = Create("TextLabel", {BackgroundTransparency = 1, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Text = InitialText or "", RichText = true, TextColor3 = Theme.TextPrimary, Font = Enum.Font.Code, TextSize = 13, ZIndex = 5001, Parent = Frame})
		Themed(Frame, {BackgroundColor3 = "Sidebar"})
		Themed(Stroke, {Color = "Border"})
		Themed(TopAccent, {BackgroundColor3 = "Accent"})
		Themed(Text, {TextColor3 = "TextPrimary"})

		local Wm = {Frame = Frame, Position = "TopLeft"}

		function Wm:SetText(NewText) Text.Text = NewText end
		function Wm:SetVisible(State) Frame.Visible = State end
		function Wm:UpdatePosition()
			local Right = string.find(self.Position, "Right") ~= nil
			local Bottom = string.find(self.Position, "Bottom") ~= nil
			if WindowObj.Visible then
				local P, S, W = MainFrame.AbsolutePosition, MainFrame.AbsoluteSize, Frame.AbsoluteSize
				local X = P.X + (Right and S.X or 0)
				local Y = Bottom and (P.Y + S.Y + 8) or (P.Y - W.Y - 8)
				Frame.AnchorPoint = Vector2.new(Right and 1 or 0, 0)
				Frame.Position = UDim2.fromOffset(X, Y)
			else
				Frame.AnchorPoint = Vector2.new(Right and 1 or 0, Bottom and 1 or 0)
				Frame.Position = UDim2.new(Right and 1 or 0, Right and -15 or 15, Bottom and 1 or 0, Bottom and -15 or 15)
			end
		end
		function Wm:SetPosition(Pos) self.Position = Pos; self:UpdatePosition() end

		Janitor:Give(Frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() Wm:UpdatePosition() end))
		table.insert(WindowObj.Watermarks, Wm)
		task.defer(function() Wm:UpdatePosition() end)
		return Wm
	end

	-----------------------------------------------------------------------
	-- Notifications
	-----------------------------------------------------------------------
	local NotifyHolder = Create("Frame", {Size = UDim2.new(0, 280, 1, -20), Position = UDim2.new(1, -290, 0, 10), BackgroundTransparency = 1, ZIndex = 6000, Parent = ScreenGui})
	Create("UIListLayout", {VerticalAlignment = Enum.VerticalAlignment.Bottom, HorizontalAlignment = Enum.HorizontalAlignment.Right, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6), Parent = NotifyHolder})

	function WindowObj:Notify(Opts)
		Opts = type(Opts) == "string" and {Content = Opts} or Opts
		local Card = Create("CanvasGroup", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = Theme.Main, GroupTransparency = 1, ZIndex = 6001, Parent = NotifyHolder})
		Corner(Card, 6)
		Create("UIStroke", {Color = Theme.Border, Thickness = 1, Parent = Card})
		Create("UIPadding", {PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), Parent = Card})
		Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 3), Parent = Card})
		if Opts.Title then
			Create("TextLabel", {Size = UDim2.new(1, 0, 0, 16), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Text = Opts.Title, TextColor3 = Theme.Accent, Font = Theme.Font, TextSize = 13, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1, Parent = Card})
		end
		if Opts.Content then
			Create("TextLabel", {Size = UDim2.new(1, 0, 0, 14), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Text = Opts.Content, TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 12, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 2, Parent = Card})
		end
		Tween(Card, TweenSmooth, {GroupTransparency = 0})
		task.delay(Opts.Duration or 4, function()
			if not Card.Parent then return end
			local Tw = Tween(Card, TweenSmooth, {GroupTransparency = 1})
			Tw.Completed:Once(function() Card:Destroy() end)
		end)
	end

	-----------------------------------------------------------------------
	-- Search
	-----------------------------------------------------------------------
	local Tip = Create("TextLabel", {Visible = false, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), BackgroundColor3 = Theme.Main, TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 12, ZIndex = 7000, Parent = ScreenGui})
	Corner(Tip, 4)
	Create("UIPadding", {PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), Parent = Tip})
	Themed(Tip, {BackgroundColor3 = "Main", TextColor3 = "TextPrimary", Font = "Font"})
	function WindowObj:ShowTip(Text, Gui)
		Tip.Text = Text
		Tip.AnchorPoint = Vector2.new(0.5, 1)
		Tip.Position = UDim2.fromOffset(Gui.AbsolutePosition.X + Gui.AbsoluteSize.X / 2, Gui.AbsolutePosition.Y - 8)
		Tip.Visible = true
	end
	function WindowObj:HideTip() Tip.Visible = false end

	Janitor:Give(SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		local Query = string.lower(SearchBox.Text)
		for _, Comp in WindowObj.AllRows do Comp.Row.Parent = Comp.OriginalParent end

		if Query == "" then
			SearchContent.Visible = false
			NoResults.Visible = false
			if WindowObj.CurrentTab then WindowObj.CurrentTab.Canvas.Visible = true end
			return
		end

		if WindowObj.CurrentTab then WindowObj.CurrentTab.Canvas.Visible = false end
		SearchContent.Visible = true
		local Found = 0
		for _, Comp in WindowObj.AllRows do
			local Haystack = string.lower(Comp.Title .. " " .. (Comp.Keywords or ""))
			if string.find(Haystack, Query, 1, true) then
				Comp.Row.Parent = SearchContent
				Found += 1
			end
		end
		NoResults.Visible = Found == 0
	end))

	-----------------------------------------------------------------------
	-- Tabs
	-----------------------------------------------------------------------
	function WindowObj:Tab(Opts)
		local TabTitle = Opts.Title or "Tab"
		local TabIcon = Opts.Icon or Icons.Placeholder
		local IsConfig = Opts.IsConfig or false

		local TabBtn = Create("TextButton", {Name = TabTitle, Size = UDim2.fromOffset(40, 40), BackgroundTransparency = 1, BackgroundColor3 = Theme.Search, Text = "", AutoButtonColor = false})
		if not IsConfig then TabBtn.Parent = TabNav end
		Janitor:Give(TabBtn)
		Corner(TabBtn, 8)
		Janitor:Give(TabBtn.MouseEnter:Connect(function() WindowObj:ShowTip(TabTitle, TabBtn) end))
		Janitor:Give(TabBtn.MouseLeave:Connect(function() WindowObj:HideTip() end))
		local TabIconImage = Create("ImageLabel", {Size = UDim2.fromOffset(20, 20), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Image = TabIcon, ImageColor3 = Theme.TextSecondary, Parent = TabBtn})

		local TabCanvas = Create("CanvasGroup", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, GroupTransparency = 1, Visible = false, Parent = TabContainer})
		local TabContent = Create("ScrollingFrame", {Size = UDim2.new(1, -40, 1, -40), Position = UDim2.fromOffset(20, 20), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4, ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = TabCanvas})
		Themed(TabContent, {ScrollBarImageColor3 = "Accent"})
		Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = TabContent})
		-- popups are positioned in screen space, so close them when the page scrolls
		Janitor:Give(TabContent:GetPropertyChangedSignal("CanvasPosition"):Connect(function() WindowObj:ClosePopup() end))

		local TabObj = {Canvas = TabCanvas, Container = TabContent, TabButton = TabBtn, Title = TabTitle, Icon = TabIcon, IsConfig = IsConfig, LayoutOrder = 0}
		table.insert(WindowObj.Tabs, TabObj)

		function TabObj.SetActive(Active, Instant)
			if IsConfig then
				Set(SaveBtn, {BackgroundColor3 = Active and Theme.Accent or Theme.Search}, Instant)
				Set(SaveIcon, {ImageColor3 = Active and DarkIcon or Theme.TextSecondary}, Instant)
			else
				Set(TabBtn, {BackgroundTransparency = Active and 0 or 1, BackgroundColor3 = Theme.Search}, Instant)
				Set(TabIconImage, {ImageColor3 = Active and Theme.Accent or Theme.TextSecondary}, Instant)
			end
		end
		OnTheme(function() TabObj.SetActive(WindowObj.CurrentTab == TabObj, true) end)

		local function ActivateTab()
			if WindowObj.CurrentTab == TabObj then return end
			if SearchBox.Text ~= "" then SearchBox.Text = "" end
			WindowObj:ClosePopup()

			local Prev = WindowObj.CurrentTab
			if Prev then
				Prev.Canvas.Visible = false
				Prev.SetActive(false)
			end
			TabCanvas.GroupTransparency = Prev and 1 or 0
			TabCanvas.Visible = true
			Tween(TabCanvas, TweenSmooth, {GroupTransparency = 0})
			TabObj.SetActive(true)
			WindowObj.CurrentTab = TabObj
		end
		function TabObj:Activate() ActivateTab() end

		if not IsConfig then
			Janitor:Give(TabBtn.MouseButton1Click:Connect(ActivateTab))
			local Count = 0
			for _, T in WindowObj.Tabs do if not T.IsConfig then Count += 1 end end
			if Count == 1 then ActivateTab() end
		end

		-------------------------------------------------------------------
		-- Row helpers
		-------------------------------------------------------------------
		local function CreateRow(Title, Height, NoSeparator, Keywords)
			TabObj.LayoutOrder += 1
			local Row = Create("Frame", {Size = UDim2.new(1, 0, 0, Height or 40), BackgroundTransparency = 1, LayoutOrder = TabObj.LayoutOrder, Parent = TabContent})
			if not NoSeparator then
				local Sep = Create("Frame", {Size = UDim2.new(1, -16, 0, 1), Position = UDim2.new(0, 8, 1, -1), BackgroundColor3 = Theme.Border, BackgroundTransparency = 0.5, BorderSizePixel = 0, Parent = Row})
				Themed(Sep, {BackgroundColor3 = "Border"})
			end
			table.insert(WindowObj.AllRows, {Row = Row, OriginalParent = TabContent, Title = Title or "", Keywords = Keywords})
			return Row
		end

		local function RowTitle(Row, Title, Reserve)
			local L = Create("TextLabel", {Size = UDim2.new(1, -(Reserve or 200), 1, 0), Position = UDim2.fromOffset(8, 0), BackgroundTransparency = 1, Text = Title, TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = Row})
			Themed(L, {TextColor3 = "TextPrimary", Font = "Font"})
			return L
		end

		local function FlagFor(Opts2, Kind, Title)
			return Opts2.Flag or string.format("%s/%s/%s", TabTitle, Kind, Title)
		end

		-------------------------------------------------------------------
		-- Label / Section
		-------------------------------------------------------------------
		function TabObj:Label(Text)
			local Row = CreateRow(Text, 28, true)
			local L = Create("TextLabel", {Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(8, 0), BackgroundTransparency = 1, Text = Text, TextColor3 = Theme.TextSecondary, Font = Theme.Font, TextSize = 12, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Parent = Row})
			Themed(L, {TextColor3 = "TextSecondary", Font = "Font"})
			local Obj = {Row = Row}
			function Obj:SetText(T) L.Text = T end
			return Obj
		end

		function TabObj:Section(Title)
			local Row = CreateRow("", 30, true)
			Row.Visible = true
			local L = Create("TextLabel", {Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(8, 4), BackgroundTransparency = 1, Text = string.upper(Title), TextColor3 = Theme.Accent, Font = Theme.Font, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, Parent = Row})
			Themed(L, {TextColor3 = "Accent", Font = "Font"})
			-- sections are not searchable
			WindowObj.AllRows[#WindowObj.AllRows].Title = "\0never-matches"
			return {Row = Row}
		end

		-------------------------------------------------------------------
		-- Color picker (shared by Colorpicker and Toggle:Colorpicker)
		-------------------------------------------------------------------
		local function AttachColorPicker(TargetRow, CompTitle, P, RightOffset)
			P = P or {}
			local Callback = Safe(P.Callback)
			local Flag = FlagFor(P, "Colorpicker", CompTitle)
			local Color = P.Default or Color3.new(1, 1, 1)
			local Alpha = (P.Transparency or 100) / 100
			local H, S, V = Color:ToHSV()

			local Holder = Create("Frame", {Size = UDim2.new(0, 250, 1, 0), Position = UDim2.new(1, -RightOffset, 0, 0), AnchorPoint = Vector2.new(1, 0), BackgroundTransparency = 1, ZIndex = 10, Parent = TargetRow})
			Create("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 12), Parent = Holder})

			local CopyBtn = Create("TextButton", {Size = UDim2.fromOffset(16, 16), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, LayoutOrder = 1, ZIndex = 10, Visible = typeof(setclipboard) == "function", Parent = Holder})
			local CopyIcon = Create("ImageLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Image = Icons.Pipette, ImageColor3 = Theme.TextSecondary, ZIndex = 10, Parent = CopyBtn})
			Themed(CopyIcon, {ImageColor3 = "TextSecondary"})

			local ColorBtn = Create("TextButton", {Size = UDim2.fromOffset(18, 18), BackgroundColor3 = Color, Text = "", AutoButtonColor = false, LayoutOrder = 2, ZIndex = 10, Parent = Holder})
			Corner(ColorBtn, 4)
			local HexBox = Create("TextBox", {Size = UDim2.new(0, 0, 0, 20), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, Text = "", TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 13, ClearTextOnFocus = false, LayoutOrder = 3, ZIndex = 10, Parent = Holder})
			local AlphaLabel = Create("TextLabel", {Size = UDim2.new(0, 0, 0, 20), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, Text = "", TextColor3 = Theme.TextSecondary, Font = Theme.Font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, LayoutOrder = 4, ZIndex = 10, Parent = Holder})
			Themed(HexBox, {TextColor3 = "TextPrimary", Font = "Font"})
			Themed(AlphaLabel, {TextColor3 = "TextSecondary", Font = "Font"})

			local Picker = Create("Frame", {BackgroundColor3 = Theme.Main, BorderSizePixel = 0, Size = UDim2.fromOffset(220, 0), Visible = false, ClipsDescendants = true, ZIndex = 3000, Parent = ScreenGui})
			Corner(Picker, 6)
			local PickerStroke = Create("UIStroke", {Color = Theme.Border, Thickness = 1, Parent = Picker})
			Create("UIPadding", {PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), Parent = Picker})
			Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 5), Parent = Picker})
			Themed(Picker, {BackgroundColor3 = "Main"})
			Themed(PickerStroke, {Color = "Border"})

			local ColorMap = Create("TextButton", {Size = UDim2.new(1, 0, 0, 120), BackgroundColor3 = Color3.fromHSV(H, 1, 1), AutoButtonColor = false, Text = "", LayoutOrder = 1, ZIndex = 3001, Parent = Picker})
			Corner(ColorMap, 4)
			local SatOverlay = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 3002, Parent = ColorMap})
			Create("UIGradient", {Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1)}), Parent = SatOverlay})
			Corner(SatOverlay, 4)
			local ValOverlay = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, ZIndex = 3003, Parent = ColorMap})
			Create("UIGradient", {Rotation = 90, Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0)}), Parent = ValOverlay})
			Corner(ValOverlay, 4)
			local Marker = Create("Frame", {Size = UDim2.fromOffset(12, 12), BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(S, 1 - V), ZIndex = 3004, Parent = ColorMap})
			Corner(Marker, 6, true)
			Create("UIStroke", {Color = Color3.new(1, 1, 1), Thickness = 2, Parent = Marker})

			local function PickerSlider(Name, Order)
				local Frame = Create("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 35), LayoutOrder = Order, ZIndex = 3001, Parent = Picker})
				local TitleLab = Create("TextLabel", {Text = Name, Size = UDim2.new(1, -40, 0, 15), BackgroundTransparency = 1, Font = Theme.Font, TextSize = 12, TextColor3 = Theme.TextSecondary, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 3001, Parent = Frame})
				local ValLab = Create("TextLabel", {Text = "0", Size = UDim2.new(0, 40, 0, 15), Position = UDim2.new(1, -40, 0, 0), BackgroundTransparency = 1, Font = Theme.Font, TextSize = 12, TextColor3 = Theme.TextPrimary, TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 3001, Parent = Frame})
				local Track = Create("TextButton", {BackgroundColor3 = Theme.Search, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 4), Text = "", AutoButtonColor = false, ZIndex = 3001, Parent = Frame})
				Corner(Track, 2)
				local Fill = Create("Frame", {BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), BackgroundColor3 = Theme.Accent, ZIndex = 3002, Parent = Track})
				Corner(Fill, 2)
				Themed(TitleLab, {TextColor3 = "TextSecondary", Font = "Font"})
				Themed(ValLab, {TextColor3 = "TextPrimary", Font = "Font"})
				Themed(Track, {BackgroundColor3 = "Search"})
				Themed(Fill, {BackgroundColor3 = "Accent"})
				return {Track = Track, Fill = Fill, Label = ValLab}
			end
			local HueSlider = PickerSlider("Hue", 2)
			local AlphaSlider = PickerSlider("Transparency", 3)

			local function Render(Fire)
				Color = Color3.fromHSV(H, S, V)
				ColorBtn.BackgroundColor3 = Color
				HexBox.Text = string.upper(Color:ToHex())
				AlphaLabel.Text = math.floor(Alpha * 100) .. "%"
				ColorMap.BackgroundColor3 = Color3.fromHSV(H, 1, 1)
				Marker.Position = UDim2.fromScale(S, 1 - V)
				HueSlider.Fill.Size = UDim2.fromScale(H, 1)
				HueSlider.Label.Text = tostring(math.floor(H * 360))
				AlphaSlider.Fill.Size = UDim2.fromScale(Alpha, 1)
				AlphaSlider.Label.Text = math.floor(Alpha * 100) .. "%"
				if Fire then Callback(Color, Alpha) end
			end

			Janitor:Give(HexBox.FocusLost:Connect(function()
				local Ok, Parsed = pcall(Color3.fromHex, HexBox.Text)
				if Ok then
					H, S, V = Parsed:ToHSV()
					Render(true)
				else
					HexBox.Text = string.upper(Color:ToHex())
				end
			end))

			Janitor:Give(CopyBtn.MouseButton1Click:Connect(function()
				if typeof(setclipboard) == "function" then
					setclipboard("#" .. string.upper(Color:ToHex()))
					WindowObj:Notify({Content = "Copied #" .. string.upper(Color:ToHex()), Duration = 2})
				end
			end))

			local function Hook(Gui, Kind)
				Janitor:Give(Gui.InputBegan:Connect(function(Input)
					if not IsPress(Input) then return end
					local function Update(In)
						local Size, Pos = Gui.AbsoluteSize, Gui.AbsolutePosition
						local X = math.clamp((In.Position.X - Pos.X) / math.max(Size.X, 1), 0, 1)
						local Y = math.clamp((In.Position.Y - Pos.Y) / math.max(Size.Y, 1), 0, 1)
						if Kind == "Map" then S, V = X, 1 - Y
						elseif Kind == "Hue" then H = X
						else Alpha = X end
						Render(true)
					end
					Update(Input)
					BeginDrag(Update)
				end))
			end
			Hook(ColorMap, "Map"); Hook(HueSlider.Track, "Hue"); Hook(AlphaSlider.Track, "Alpha")

			local IsOpen = false
			local function Close()
				if not IsOpen then return end
				IsOpen = false
				local Tw = Tween(Picker, TweenSmooth, {Size = UDim2.fromOffset(220, 0)})
				Tw.Completed:Once(function() if not IsOpen then Picker.Visible = false end end)
			end
			local Popup = {Close = Close, Frames = {Picker, ColorBtn}}

			Janitor:Give(ColorBtn.MouseButton1Click:Connect(function()
				if IsOpen then WindowObj:ClosePopup(); Close(); return end
				WindowObj:OpenPopup(Popup)
				local Pos, Size, Bounds = ColorBtn.AbsolutePosition, ColorBtn.AbsoluteSize, ScreenGui.AbsoluteSize
				local X = Pos.X - 230
				if X < 0 then X = Pos.X + Size.X + 10 end
				X = math.clamp(X, 0, math.max(Bounds.X - 220, 0))
				local Y = math.clamp(Pos.Y + Size.Y + 6, 0, math.max(Bounds.Y - 220, 0))
				Picker.Position = UDim2.fromOffset(X, Y)
				Picker.Visible = true
				IsOpen = true
				Tween(Picker, TweenSmooth, {Size = UDim2.fromOffset(220, 220)})
			end))

			Render(false)

			local Obj = {}
			function Obj:GetComponentType() return "Colorpicker" end
			function Obj:GetValue() return Color end
			function Obj:GetTransparency() return Alpha * 100 end
			function Obj:SetValue(NewColor, Silent) H, S, V = NewColor:ToHSV(); Render(not Silent) end
			function Obj:SetTransparency(Trans, Silent) Alpha = math.clamp(Trans, 0, 100) / 100; Render(not Silent) end
			Register(Flag, Obj)
			return Obj
		end

		function TabObj:Colorpicker(O)
			local Title = O.Title or "Colorpicker"
			local Row = CreateRow(Title, 40)
			RowTitle(Row, Title, 250)
			local Obj = AttachColorPicker(Row, Title, O, 8)
			Obj.Row = Row
			return Obj
		end

		-------------------------------------------------------------------
		-- Button
		-------------------------------------------------------------------
		function TabObj:Button(O)
			local Title = O.Title or "Button"
			local Callback = Safe(O.Callback)
			local Row = CreateRow(Title, 40)
			RowTitle(Row, Title, 200)

			local Btn = Create("TextButton", {Size = UDim2.new(0, 0, 0, 26), Position = UDim2.new(1, -8, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = Theme.Search, Text = O.Action or "Click", TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 12, AutoButtonColor = false, Parent = Row})
			Corner(Btn, 4)
			Create("UIPadding", {PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16), Parent = Btn})
			Themed(Btn, {BackgroundColor3 = "Search", TextColor3 = "TextPrimary", Font = "Font"})

			Janitor:Give(Btn.MouseEnter:Connect(function() Tween(Btn, TweenFast, {BackgroundColor3 = Theme.Border}) end))
			Janitor:Give(Btn.MouseLeave:Connect(function() Tween(Btn, TweenFast, {BackgroundColor3 = Theme.Search}) end))
			local BtnFlag = FlagFor(O, "Button", Title)
			Janitor:Give(Btn.MouseButton1Click:Connect(function()
				Callback()
				Library:FireEvent("ButtonPressed", BtnFlag)
			end))

			local Obj = {Row = Row}
			function Obj:GetComponentType() return "Button" end
			function Obj:Fire() Callback() end
			Register(FlagFor(O, "Button", Title), Obj)
			return Obj
		end

		-------------------------------------------------------------------
		-- Textbox
		-------------------------------------------------------------------
		function TabObj:Textbox(O)
			local Title = O.Title or "Textbox"
			local Callback = Safe(O.Callback)
			local Row = CreateRow(Title, 40)
			RowTitle(Row, Title, 200)

			local Input = Create("TextBox", {Size = UDim2.fromOffset(100, 26), Position = UDim2.new(1, -8, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), BackgroundColor3 = Theme.Search, Text = O.Default or "", PlaceholderText = O.Placeholder or "Type here", TextColor3 = Theme.TextPrimary, PlaceholderColor3 = Theme.TextSecondary, Font = Enum.Font.Code, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, AutomaticSize = Enum.AutomaticSize.X, ClearTextOnFocus = false, ClipsDescendants = true, Parent = Row})
			Corner(Input, 4)
			local Stroke = Create("UIStroke", {Color = Theme.Border, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = Input})
			Create("UIPadding", {PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = Input})
			Create("UISizeConstraint", {MinSize = Vector2.new(100, 26), MaxSize = Vector2.new(300, 26), Parent = Input})
			Themed(Input, {BackgroundColor3 = "Search", TextColor3 = "TextPrimary", PlaceholderColor3 = "TextSecondary"})
			Themed(Stroke, {Color = "Border"})

			if O.Numeric then
				Janitor:Give(Input:GetPropertyChangedSignal("Text"):Connect(function()
					local Clean = string.gsub(Input.Text, "[^%d%.%-]", "")
					if Clean ~= Input.Text then Input.Text = Clean end
				end))
			end

			local Value = O.Default or ""
			Janitor:Give(Input.Focused:Connect(function() Tween(Stroke, TweenFast, {Color = Theme.Accent}) end))
			Janitor:Give(Input.FocusLost:Connect(function()
				Tween(Stroke, TweenFast, {Color = Theme.Border})
				Value = Input.Text
				Callback(Value)
			end))

			local Obj = {Row = Row}
			function Obj:GetComponentType() return "Textbox" end
			function Obj:GetValue() return Value end
			function Obj:SetValue(Val, Silent)
				Value = tostring(Val)
				Input.Text = Value
				if not Silent then Callback(Value) end
			end
			Register(FlagFor(O, "Textbox", Title), Obj)
			return Obj
		end

		-------------------------------------------------------------------
		-- Keybind  (Callback = pressed, OnChanged = rebound)
		-------------------------------------------------------------------
		function TabObj:Keybind(O)
			local Title = O.Title or "Keybind"
			local Callback = Safe(O.Callback)
			local OnChanged = Safe(O.OnChanged)
			local Key = O.Default
			local Binding, BindConn = false, nil

			local Row = CreateRow(Title, 40)
			RowTitle(Row, Title, 200)

			local Container = Create("TextButton", {Size = UDim2.new(0, 150, 1, 0), Position = UDim2.new(1, -8, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Parent = Row})
			Create("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8), Parent = Container})
			local KeyText = Create("TextLabel", {Size = UDim2.new(0, 0, 0, 20), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, Text = FormatKeyName(Key), TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 13, LayoutOrder = 2, Parent = Container})
			local IconHolder = Create("Frame", {Size = UDim2.fromOffset(24, 18), BackgroundTransparency = 1, LayoutOrder = 1, Parent = Container})
			local Icon = Create("ImageLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Image = Icons.Keyboard, ImageColor3 = Theme.TextPrimary, Parent = IconHolder})

			local function Refresh(Instant)
				KeyText.Text = Binding and "..." or FormatKeyName(Key)
				local Col = Binding and Theme.Accent or Theme.TextPrimary
				Set(KeyText, {TextColor3 = Col}, Instant)
				Set(Icon, {ImageColor3 = Col}, Instant)
			end
			OnTheme(function() Refresh(true); KeyText.Font = Theme.Font end)

			Janitor:Give(Container.MouseButton1Click:Connect(function()
				if Binding then return end
				Binding = true
				WindowObj.Binding = true
				Refresh()
				BindConn = UserInputService.InputBegan:Connect(function(Input)
					local New
					if Input.UserInputType == Enum.UserInputType.Keyboard then
						New = Input.KeyCode ~= Enum.KeyCode.Escape and Input.KeyCode or false
					elseif string.find(Input.UserInputType.Name, "MouseButton") then
						New = Input.UserInputType
					else
						return
					end
					BindConn:Disconnect(); BindConn = nil
					Binding = false
					task.defer(function() WindowObj.Binding = false end) -- swallow this press
					Key = New or nil
					Refresh()
					OnChanged(Key)
				end)
			end))
			Janitor:Give(function() if BindConn then BindConn:Disconnect() end end)

			Janitor:Give(UserInputService.InputBegan:Connect(function(Input, Processed)
				if Processed or WindowObj.Binding or not Key then return end
				if Input.KeyCode == Key or Input.UserInputType == Key then
					Callback(Key)
					Library:FireEvent("KeyPressed", FlagFor(O, "Keybind", Title), Key)
				end
			end))

			local Obj = {Row = Row}
			function Obj:GetComponentType() return "Keybind" end
			function Obj:GetValue() return Key end
			function Obj:SetValue(Val, Silent)
				Key = Val
				Refresh()
				if not Silent then OnChanged(Key) end
			end
			Register(FlagFor(O, "Keybind", Title), Obj)
			return Obj
		end

		-------------------------------------------------------------------
		-- Slider
		-------------------------------------------------------------------
		function TabObj:Slider(O)
			local Title = O.Title or "Slider"
			local Min, Max = O.Min or 0, O.Max or 100
			local Range = math.max(Max - Min, 1e-9)
			local Decimal = O.Decimal or 0
			local Prefix, Suffix = O.Prefix or "", O.Suffix or ""
			local Dual = O.Dual or false
			local Callback = Safe(O.Callback)
			local ZeroAlpha = math.clamp(((O.ZeroNumber or Min) - Min) / Range, 0, 1)

			local Current
			if Dual then
				local D = type(O.Default) == "table" and O.Default or {}
				Current = {math.clamp(D[1] or Min, Min, Max), math.clamp(D[2] or Max, Min, Max)}
			else
				Current = math.clamp(O.Default or Min, Min, Max)
			end

			local Row = CreateRow(Title, 52)
			local TitleLabel = Create("TextLabel", {Size = UDim2.fromOffset(200, 20), Position = UDim2.fromOffset(8, 8), BackgroundTransparency = 1, Text = Title, TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, Parent = Row})
			local ValueLabel = Create("TextLabel", {Size = UDim2.fromOffset(150, 20), Position = UDim2.new(1, -158, 0, 8), BackgroundTransparency = 1, Text = "", TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right, Parent = Row})
			Themed(TitleLabel, {TextColor3 = "TextPrimary", Font = "Font"})
			Themed(ValueLabel, {TextColor3 = "TextPrimary", Font = "Font"})

			local TrackBtn = Create("TextButton", {Size = UDim2.new(1, -16, 0, 20), Position = UDim2.fromOffset(8, 28), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Parent = Row})
			local Track = Create("Frame", {Size = UDim2.new(1, 0, 0, 4), Position = UDim2.new(0, 0, 0.5, -2), BackgroundColor3 = Theme.Search, Parent = TrackBtn})
			Corner(Track, 2)
			local Fill = Create("Frame", {Size = UDim2.fromScale(0, 1), BackgroundColor3 = Theme.Accent, Parent = Track})
			Corner(Fill, 2)
			local Handle1 = Create("Frame", {Size = UDim2.fromOffset(12, 12), Position = UDim2.fromScale(Dual and 0 or 1, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Theme.TextPrimary, Parent = Fill})
			Corner(Handle1, 6, true)
			local Handle2
			if Dual then
				Handle2 = Create("Frame", {Size = UDim2.fromOffset(12, 12), Position = UDim2.fromScale(1, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Theme.TextPrimary, Parent = Fill})
				Corner(Handle2, 6, true)
			end
			Themed(Track, {BackgroundColor3 = "Search"})
			Themed(Fill, {BackgroundColor3 = "Accent"})
			Themed(Handle1, {BackgroundColor3 = "TextPrimary"})
			if Handle2 then Themed(Handle2, {BackgroundColor3 = "TextPrimary"}) end

			local function Fmt(Val) return Prefix .. string.format("%." .. Decimal .. "f", Val) .. Suffix end

			local function Render(Instant)
				if Dual then
					local A1, A2 = (Current[1] - Min) / Range, (Current[2] - Min) / Range
					Set(Fill, {Position = UDim2.fromScale(A1, 0), Size = UDim2.new(A2 - A1, 0, 1, 0)}, Instant, TweenDrag)
					ValueLabel.Text = string.format("( %s, %s )", Fmt(Current[1]), Fmt(Current[2]))
				else
					local A = (Current - Min) / Range
					Set(Fill, {Position = UDim2.fromScale(math.min(A, ZeroAlpha), 0), Size = UDim2.new(math.abs(A - ZeroAlpha), 0, 1, 0)}, Instant, TweenDrag)
					Handle1.Position = UDim2.fromScale(A < ZeroAlpha and 0 or 1, 0.5)
					ValueLabel.Text = string.format("( %s )", Fmt(Current))
				end
			end

			local function SetValue(Value, Fire)
				if Dual then
					local V = type(Value) == "table" and Value or {Min, Max}
					local A, B = math.clamp(V[1] or Min, Min, Max), math.clamp(V[2] or Max, Min, Max)
					if A > B then A, B = B, A end
					if Current[1] == A and Current[2] == B and Fire then return end
					Current = {A, B}
				else
					local N = math.clamp(tonumber(Value) or Min, Min, Max)
					if Current == N and Fire then return end
					Current = N
				end
				Render(false)
				if Fire then Callback(Dual and table.clone(Current) or Current) end
			end

			local function AlphaOf(Input)
				return math.clamp((Input.Position.X - Track.AbsolutePosition.X) / math.max(Track.AbsoluteSize.X, 1), 0, 1)
			end
			local function Snap(Alpha)
				local Mult = 10 ^ Decimal
				return math.clamp(math.round((Min + Range * Alpha) * Mult) / Mult, Min, Max)
			end

			Janitor:Give(TrackBtn.InputBegan:Connect(function(Input)
				if not IsPress(Input) then return end
				local Handle = 1
				if Dual then
					local A = AlphaOf(Input)
					local D1, D2 = math.abs(A - (Current[1] - Min) / Range), math.abs(A - (Current[2] - Min) / Range)
					Handle = (D1 == D2) and (A > (Current[1] - Min) / Range and 2 or 1) or (D1 < D2 and 1 or 2)
				end
				local function Apply(In)
					local Value = Snap(AlphaOf(In))
					if Dual then
						local New = {Current[1], Current[2]}
						New[Handle] = Value
						SetValue(New, true)
					else
						SetValue(Value, true)
					end
				end
				Apply(Input)
				BeginDrag(Apply)
			end))

			Render(true)
			local Obj = {Row = Row}
			function Obj:GetComponentType() return "Slider" end
			function Obj:GetValue() return Dual and table.clone(Current) or Current end
			function Obj:SetValue(Val, Silent) SetValue(Val, not Silent) if Silent then Render(false) end end
			Register(FlagFor(O, "Slider", Title), Obj)
			return Obj
		end

		-------------------------------------------------------------------
		-- Toggle
		-------------------------------------------------------------------
		function TabObj:Toggle(O)
			local Title = O.Title or "Toggle"
			local Callback = Safe(O.Callback)
			local State = O.Default or false

			local Row = CreateRow(Title, 40)
			RowTitle(Row, Title, 60)

			local Box = Create("Frame", {Size = UDim2.fromOffset(18, 18), Position = UDim2.new(1, -8, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), BackgroundColor3 = State and Theme.Accent or Theme.Search, Parent = Row})
			Corner(Box, 4)
			local Check = Create("ImageLabel", {Size = UDim2.fromOffset(12, 12), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Image = Icons.Checkmark, ImageColor3 = DarkIcon, ImageTransparency = State and 0 or 1, Parent = Box})

			local function Render(Instant)
				Set(Box, {BackgroundColor3 = State and Theme.Accent or Theme.Search}, Instant)
				Set(Check, {ImageTransparency = State and 0 or 1}, Instant)
			end
			OnTheme(function() Render(true) end)

			local function SetState(New, Fire)
				State = New and true or false
				Render(false)
				if Fire then Callback(State) end
			end

			local Click = Create("TextButton", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 5, Parent = Row})
			Janitor:Give(Click.MouseButton1Click:Connect(function() SetState(not State, true) end))

			local Obj = {Row = Row, Pickers = {}}
			function Obj:GetComponentType() return "Toggle" end
			function Obj:GetValue() return State end
			function Obj:SetValue(Val, Silent) SetState(Val, not Silent) end
			function Obj:Colorpicker(Props)
				local Picker = AttachColorPicker(Row, Title, Props, 36)
				table.insert(self.Pickers, Picker)
				return Picker
			end
			Register(FlagFor(O, "Toggle", Title), Obj)
			return Obj
		end

		-------------------------------------------------------------------
		-- Dropdown
		-------------------------------------------------------------------
		function TabObj:Dropdown(O)
			local Title = O.Title or "Dropdown"
			local OptionsList = O.Options or {}
			local Multi = O.Multi or false
			local Callback = Safe(O.Callback)
			local MaxHeight = O.MaxHeight or 160
			local Selected = {}

			local function Normalize(Val)
				local Out = {}
				if Multi then
					if type(Val) == "table" then for _, V in Val do table.insert(Out, V) end end
				else
					if type(Val) == "string" and Val ~= "" then table.insert(Out, Val)
					elseif type(Val) == "table" and #Val > 0 then table.insert(Out, Val[1]) end
				end
				return Out
			end
			Selected = Normalize(O.Default)

			local Row = CreateRow(Title, 40)
			RowTitle(Row, Title, 200)

			local DropBtn = Create("TextButton", {Size = UDim2.fromOffset(160, 26), Position = UDim2.new(1, -8, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), BackgroundColor3 = Theme.Search, Text = "", AutoButtonColor = false, Parent = Row})
			Corner(DropBtn, 4)
			local DropText = Create("TextLabel", {Size = UDim2.new(1, -30, 1, 0), Position = UDim2.fromOffset(10, 0), BackgroundTransparency = 1, Text = "", TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = DropBtn})
			local Chevron = Create("ImageLabel", {Size = UDim2.fromOffset(16, 16), Position = UDim2.new(1, -20, 0.5, -8), BackgroundTransparency = 1, Image = Icons.ChevronDown, ImageColor3 = Theme.TextSecondary, Parent = DropBtn})
			Themed(DropBtn, {BackgroundColor3 = "Search"})
			Themed(DropText, {TextColor3 = "TextPrimary", Font = "Font"})
			Themed(Chevron, {ImageColor3 = "TextSecondary"})

			local Menu = Create("ScrollingFrame", {Size = UDim2.fromOffset(160, 0), BackgroundColor3 = Theme.Main, Visible = false, ClipsDescendants = true, ZIndex = 10, BorderSizePixel = 0, ScrollBarThickness = 2, ScrollBarImageColor3 = Theme.Border, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = ScreenGui})
			Corner(Menu, 6)
			local MenuStroke = Create("UIStroke", {Color = Theme.Border, Thickness = 1, Parent = Menu})
			Create("UIPadding", {PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), Parent = Menu})
			local Layout = Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = Menu})
			Themed(Menu, {BackgroundColor3 = "Main", ScrollBarImageColor3 = "Border"})
			Themed(MenuStroke, {Color = "Border"})

			local Buttons, IsOpen = {}, false

			local function UpdateText()
				DropText.Text = #Selected > 0 and table.concat(Selected, ", ") or "None"
			end

			local function Close()
				if not IsOpen then return end
				IsOpen = false
				Tween(Chevron, TweenSmooth, {Rotation = 0})
				local Tw = Tween(Menu, TweenSmooth, {Size = UDim2.fromOffset(160, 0)})
				Tw.Completed:Once(function() if not IsOpen then Menu.Visible = false end end)
			end
			local Popup = {Close = Close, Frames = {Menu, DropBtn}}

			local function Paint(Instant)
				for Option, Btn in Buttons do
					Set(Btn, {TextColor3 = table.find(Selected, Option) and Theme.Accent or Theme.TextSecondary}, Instant)
				end
			end
			OnTheme(function() Paint(true) end)

			local function SetValue(Val, Fire)
				Selected = Normalize(Val)
				Paint(false)
				UpdateText()
				if Fire then Callback(Multi and table.clone(Selected) or Selected[1]) end
			end

			local function Rebuild(NewOptions)
				OptionsList = type(NewOptions) == "table" and NewOptions or {}
				for _, Btn in Buttons do Btn:Destroy() end
				table.clear(Buttons)
				local Keep = {}
				for _, Item in Selected do if table.find(OptionsList, Item) then table.insert(Keep, Item) end end
				Selected = Keep

				for Index, Option in OptionsList do
					local Btn = Create("TextButton", {Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, Text = Option, TextColor3 = table.find(Selected, Option) and Theme.Accent or Theme.TextSecondary, Font = Theme.Font, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = Index, ZIndex = 11, Parent = Menu})
					Create("UIPadding", {PaddingLeft = UDim.new(0, 10), Parent = Btn})
					Buttons[Option] = Btn
					Btn.MouseButton1Click:Connect(function()
						if Multi then
							local New = table.clone(Selected)
							local I = table.find(New, Option)
							if I then table.remove(New, I) else table.insert(New, Option) end
							SetValue(New, true)
						else
							SetValue(Option, true)
							WindowObj:ClosePopup(); Close()
						end
					end)
				end
				UpdateText()
			end
			Rebuild(OptionsList)

			Janitor:Give(DropBtn.MouseButton1Click:Connect(function()
				if IsOpen then WindowObj:ClosePopup(); Close(); return end
				WindowObj:OpenPopup(Popup)
				local Pos, Size, Bounds = DropBtn.AbsolutePosition, DropBtn.AbsoluteSize, ScreenGui.AbsoluteSize
				local Height = math.min(Layout.AbsoluteContentSize.Y + 8, MaxHeight)
				local Y = Pos.Y + Size.Y + 6
				if Y + Height > Bounds.Y then Y = Pos.Y - Height - 6 end
				Menu.Position = UDim2.fromOffset(Pos.X, Y)
				Menu.Visible = true
				IsOpen = true
				Tween(Chevron, TweenSmooth, {Rotation = 180})
				Tween(Menu, TweenSmooth, {Size = UDim2.fromOffset(160, Height)})
			end))

			local Obj = {Row = Row}
			function Obj:GetComponentType() return "Dropdown" end
			function Obj:GetValue() return Multi and table.clone(Selected) or Selected[1] end
			function Obj:SetValue(Val, Silent) SetValue(Val, not Silent) end
			function Obj:SetOptions(New) Rebuild(New) end
			function Obj:GetOptions() return OptionsList end
			Register(FlagFor(O, "Dropdown", Title), Obj)
			return Obj
		end

		local TabCtx = {
			Tab = TabObj, Window = WindowObj, Janitor = Janitor, ScreenGui = ScreenGui, TabContent = TabContent,
			CreateRow = CreateRow, RowTitle = RowTitle, FlagFor = FlagFor, Register = Register,
			Themed = Themed, OnTheme = OnTheme, BeginDrag = BeginDrag, Safe = Safe,
			TabTitle = TabTitle,
		}
		for _, Ext in Library.TabExtensions do Ext(TabObj, TabCtx) end

		return TabObj
	end

	-----------------------------------------------------------------------
	-- Destroy
	-----------------------------------------------------------------------
	function WindowObj:Destroy()
		Janitor:Clean()
		for Flag in FlagNames do Library.Flags[Flag] = nil end
		local I = table.find(Library.Windows, WindowObj)
		if I then table.remove(Library.Windows, I) end
	end
	table.insert(Library.Windows, WindowObj)

	-----------------------------------------------------------------------
	-- Configuration tab (config files + live theme editor)
	-----------------------------------------------------------------------
	local Config = WindowObj:Tab({Title = "Configuration", Icon = Icons.Save, IsConfig = true})
	WindowObj.ConfigTab = Config
	Janitor:Give(SaveBtn.MouseButton1Click:Connect(function() Config:Activate() end))
	Config.SetActive(false, true)

	Config:Section("Configs")
	local NameBox = Config:Textbox({Title = "Config name", Default = "default", Flag = "_Config/Name"})
	local ConfigList = Config:Dropdown({Title = "Saved configs", Options = Library:ListConfigs(), Flag = "_Config/List"})
	Config:Button({Title = "Save config", Action = "Save", Flag = "_Config/Save", Callback = function()
		local Ok, Err = Library:SaveConfig(NameBox:GetValue())
		WindowObj:Notify({Title = "Config", Content = Ok and "Saved." or ("Save failed: " .. tostring(Err))})
		ConfigList:SetOptions(Library:ListConfigs())
	end})
	Config:Button({Title = "Load selected", Action = "Load", Flag = "_Config/Load", Callback = function()
		local Name = ConfigList:GetValue()
		if not Name then WindowObj:Notify({Title = "Config", Content = "Select a config first."}) return end
		local Ok, Err = Library:LoadConfig(Name)
		WindowObj:Notify({Title = "Config", Content = Ok and ("Loaded " .. Name) or ("Load failed: " .. tostring(Err))})
	end})
	Config:Button({Title = "Refresh list", Action = "Refresh", Flag = "_Config/Refresh", Callback = function()
		ConfigList:SetOptions(Library:ListConfigs())
	end})

	Config:Section("Theme")
	for _, Key in {"Accent", "Body", "Sidebar", "Main", "Search", "TextPrimary", "TextSecondary", "Border"} do
		Config:Colorpicker({Title = Key, Default = Theme[Key], Flag = "Theme/" .. Key, Callback = function(Col)
			Library:SetTheme({[Key] = Col})
		end})
	end

	local WinCtx = {
		Janitor = Janitor, ScreenGui = ScreenGui, MainFrame = MainFrame, BottomBar = BottomBar,
		SaveBtn = SaveBtn, ConfigTab = Config, Themed = Themed, OnTheme = OnTheme,
		Register = Register, Safe = Safe, Options = Options,
	}
	for _, Ext in Library.WindowExtensions do Ext(WindowObj, WinCtx) end

	return WindowObj
end

---------------------------------------------------------------------------
-- EXTENSIONS: SliderBox, Codebox, Logic editor, themes/presets, effects,
-- tilt, settings tab, security helpers
---------------------------------------------------------------------------
do
	local RunService = game:GetService("RunService")
	local Lighting = game:GetService("Lighting")
	local TextService = game:GetService("TextService")

	local function ToSet(List)
		local T = {}
		for _, V in List do T[V] = true end
		return T
	end
	local function RGB(R, G, B) return Color3.fromRGB(R, G, B) end

	-----------------------------------------------------------------------
	-- Syntax colors + theme presets
	-----------------------------------------------------------------------
	local ThemeKeys = {"Body", "Sidebar", "Main", "Search", "TextPrimary", "TextSecondary", "Accent", "Border"}
	local SyntaxKeys = {"Text", "Keyword", "Builtin", "String", "Number", "Comment", "Function"}

	local DefaultSyntax = {
		Text = RGB(220, 220, 230), Keyword = RGB(255, 110, 140), Builtin = RGB(120, 190, 255),
		String = RGB(170, 230, 140), Number = RGB(255, 190, 110), Comment = RGB(105, 110, 130), Function = RGB(210, 170, 255),
	}
	Library.Syntax = table.clone(DefaultSyntax)

	Library.ThemePresets = {
		Midnight = {Body = RGB(20, 20, 26), Sidebar = RGB(26, 26, 34), Main = RGB(30, 30, 40), Search = RGB(35, 35, 45), TextPrimary = RGB(240, 240, 245), TextSecondary = RGB(130, 130, 145), Accent = RGB(225, 225, 245), Border = RGB(45, 45, 58)},
		Light = {Body = RGB(238, 238, 244), Sidebar = RGB(228, 228, 236), Main = RGB(246, 246, 250), Search = RGB(220, 220, 230), TextPrimary = RGB(25, 25, 32), TextSecondary = RGB(105, 105, 120), Accent = RGB(90, 110, 240), Border = RGB(200, 200, 212),
			Syntax = {Text = RGB(40, 40, 50), Keyword = RGB(200, 40, 90), Builtin = RGB(20, 110, 200), String = RGB(40, 140, 60), Number = RGB(200, 110, 20), Comment = RGB(140, 140, 155), Function = RGB(130, 70, 200)}},
		Ocean = {Body = RGB(9, 22, 36), Sidebar = RGB(13, 30, 48), Main = RGB(17, 38, 60), Search = RGB(23, 48, 74), TextPrimary = RGB(228, 242, 252), TextSecondary = RGB(118, 150, 176), Accent = RGB(64, 200, 255), Border = RGB(33, 63, 92)},
		Rose = {Body = RGB(28, 18, 22), Sidebar = RGB(36, 22, 28), Main = RGB(42, 26, 33), Search = RGB(52, 32, 40), TextPrimary = RGB(250, 236, 240), TextSecondary = RGB(170, 130, 142), Accent = RGB(255, 120, 160), Border = RGB(72, 44, 56)},
		Forest = {Body = RGB(16, 24, 18), Sidebar = RGB(21, 31, 24), Main = RGB(26, 38, 29), Search = RGB(33, 48, 37), TextPrimary = RGB(232, 246, 234), TextSecondary = RGB(132, 160, 138), Accent = RGB(120, 230, 140), Border = RGB(44, 64, 50)},
		Dracula = {Body = RGB(40, 42, 54), Sidebar = RGB(33, 34, 44), Main = RGB(44, 46, 60), Search = RGB(52, 55, 72), TextPrimary = RGB(248, 248, 242), TextSecondary = RGB(140, 145, 180), Accent = RGB(189, 147, 249), Border = RGB(68, 71, 90),
			Syntax = {Text = RGB(248, 248, 242), Keyword = RGB(255, 121, 198), Builtin = RGB(139, 233, 253), String = RGB(241, 250, 140), Number = RGB(189, 147, 249), Comment = RGB(98, 114, 164), Function = RGB(80, 250, 123)}},
		Sunset = {Body = RGB(26, 18, 28), Sidebar = RGB(34, 22, 34), Main = RGB(42, 26, 40), Search = RGB(54, 32, 48), TextPrimary = RGB(255, 240, 230), TextSecondary = RGB(180, 140, 140), Accent = RGB(255, 150, 80), Border = RGB(76, 46, 62)},
		["High Contrast"] = {Body = RGB(0, 0, 0), Sidebar = RGB(10, 10, 10), Main = RGB(18, 18, 18), Search = RGB(30, 30, 30), TextPrimary = RGB(255, 255, 255), TextSecondary = RGB(190, 190, 190), Accent = RGB(255, 230, 0), Border = RGB(120, 120, 120)},
	}
	Library.CustomPresets = {}

	function Library:ApplyPreset(Name)
		local P = Library.ThemePresets[Name] or Library.CustomPresets[Name]
		if not P then return false end
		local Syn = P.Syntax or DefaultSyntax
		for _, K in SyntaxKeys do
			if typeof(Syn[K]) == "Color3" then Library.Syntax[K] = Syn[K] end
		end
		Library:SetTheme(P)
		for _, K in ThemeKeys do
			local F = Library.Flags["Theme/" .. K]
			if F and P[K] then F:SetValue(P[K], true) end
		end
		for _, K in SyntaxKeys do
			local F = Library.Flags["Syntax/" .. K]
			if F then F:SetValue(Library.Syntax[K], true) end
		end
		return true
	end

	function Library:ListPresets()
		local Out = {}
		for Name in Library.ThemePresets do table.insert(Out, Name) end
		table.sort(Out)
		local Custom = {}
		for Name in Library.CustomPresets do table.insert(Custom, Name) end
		table.sort(Custom)
		for _, Name in Custom do table.insert(Out, Name) end
		return Out
	end

	function Library:ExportTheme()
		local Out = {Theme = {}, Syntax = {}, Font = Theme.Font.Name}
		for _, K in ThemeKeys do Out.Theme[K] = Theme[K]:ToHex() end
		for _, K in SyntaxKeys do Out.Syntax[K] = Library.Syntax[K]:ToHex() end
		return HttpService:JSONEncode(Out)
	end

	local function IsHex(S) return type(S) == "string" and string.match(S, "^%x%x%x%x%x%x$") ~= nil end

	function Library:ParseTheme(Json)
		if type(Json) ~= "string" or #Json > 20000 then return nil, "Invalid theme" end
		local Ok, Data = pcall(function() return HttpService:JSONDecode(Json) end)
		if not Ok or type(Data) ~= "table" or type(Data.Theme) ~= "table" then return nil, "Invalid theme JSON" end
		local P = {}
		for _, K in ThemeKeys do
			if not IsHex(Data.Theme[K]) then return nil, "Bad color for " .. K end
			P[K] = Color3.fromHex(Data.Theme[K])
		end
		if type(Data.Syntax) == "table" then
			P.Syntax = {}
			for _, K in SyntaxKeys do
				if IsHex(Data.Syntax[K]) then P.Syntax[K] = Color3.fromHex(Data.Syntax[K]) end
			end
		end
		if type(Data.Font) == "string" then
			local FOk, F = pcall(function() return Enum.Font[Data.Font] end)
			if FOk and typeof(F) == "EnumItem" then P.Font = F end
		end
		return P
	end

	function Library:ImportTheme(Json)
		local P, Err = Library:ParseTheme(Json)
		if not P then return false, Err end
		Library.CustomPresets["Imported"] = P
		return Library:ApplyPreset("Imported")
	end

	function Library:SavePreset(Name)
		Name = string.gsub(tostring(Name or ""), "[^%w_%- ]", "")
		if Name == "" or #Name > 40 or Library.ThemePresets[Name] then return false, "Invalid or reserved name" end
		local P = {Syntax = table.clone(Library.Syntax)}
		for _, K in ThemeKeys do P[K] = Theme[K] end
		P.Font = Theme.Font
		Library.CustomPresets[Name] = P
		if HasFiles() then
			local Dir = Library.ConfigFolder .. "/themes"
			if not isfolder(Library.ConfigFolder) then makefolder(Library.ConfigFolder) end
			if not isfolder(Dir) then makefolder(Dir) end
			writefile(Dir .. "/" .. Name .. ".json", Library:ExportTheme())
		end
		return true
	end

	function Library:LoadCustomPresets()
		if not (HasFiles() and typeof(listfiles) == "function") then return end
		local Dir = Library.ConfigFolder .. "/themes"
		if not isfolder(Dir) then return end
		for _, Path in listfiles(Dir) do
			local Name = string.match(Path, "([^/\\]+)%.json$")
			if Name and not Library.ThemePresets[Name] then
				local P = Library:ParseTheme(readfile(Path))
				if P then Library.CustomPresets[Name] = P end
			end
		end
	end
	pcall(Library.LoadCustomPresets, Library)

	-- apply everything at once: Library:ApplyStyle({Preset = "Ocean", Settings = {CornerScale = 1.4}})
	function Library:ApplyStyle(Style)
		if type(Style) ~= "table" then return end
		if Style.Preset then Library:ApplyPreset(Style.Preset) end
		if type(Style.Theme) == "table" then Library:SetTheme(Style.Theme) end
		if type(Style.Settings) == "table" then
			for K, V in Style.Settings do Library:SetSetting(K, V) end
		end
	end

	-----------------------------------------------------------------------
	-- Security helpers: SHA-256 + verified remote loading
	-----------------------------------------------------------------------
	local K256 = {
		0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
		0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
		0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
		0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
		0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
		0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
		0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
		0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
	}

	function Library:Sha256(Message)
		local Bxor, Band, Bnot, Rrot, Rshift = bit32.bxor, bit32.band, bit32.bnot, bit32.rrotate, bit32.rshift
		local Len = #Message
		local Msg = Message .. "\128" .. string.rep("\0", (55 - Len) % 64) .. string.pack(">I8", Len * 8)
		local H = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}
		local W = table.create(64, 0)
		for Pos = 1, #Msg, 64 do
			for I = 1, 16 do W[I] = string.unpack(">I4", Msg, Pos + (I - 1) * 4) end
			for I = 17, 64 do
				local A, B = W[I - 15], W[I - 2]
				local S0 = Bxor(Rrot(A, 7), Rrot(A, 18), Rshift(A, 3))
				local S1 = Bxor(Rrot(B, 17), Rrot(B, 19), Rshift(B, 10))
				W[I] = (W[I - 16] + S0 + W[I - 7] + S1) % 0x100000000
			end
			local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
			for I = 1, 64 do
				local S1 = Bxor(Rrot(e, 6), Rrot(e, 11), Rrot(e, 25))
				local Ch = Bxor(Band(e, f), Band(Bnot(e), g))
				local T1 = (h + S1 + Ch + K256[I] + W[I]) % 0x100000000
				local S0 = Bxor(Rrot(a, 2), Rrot(a, 13), Rrot(a, 22))
				local Mj = Bxor(Band(a, b), Band(a, c), Band(b, c))
				local T2 = (S0 + Mj) % 0x100000000
				h = g; g = f; f = e
				e = (d + T1) % 0x100000000
				d = c; c = b; b = a
				a = (T1 + T2) % 0x100000000
			end
			H[1] = (H[1] + a) % 0x100000000; H[2] = (H[2] + b) % 0x100000000
			H[3] = (H[3] + c) % 0x100000000; H[4] = (H[4] + d) % 0x100000000
			H[5] = (H[5] + e) % 0x100000000; H[6] = (H[6] + f) % 0x100000000
			H[7] = (H[7] + g) % 0x100000000; H[8] = (H[8] + h) % 0x100000000
		end
		local Out = table.create(8)
		for I = 1, 8 do Out[I] = string.format("%08x", H[I]) end
		return table.concat(Out)
	end

	Library.Security = {
		AllowedHosts = {"raw.githubusercontent.com", "gist.githubusercontent.com"},
		MaxBytes = 500000,
	}

	-- Downloads over HttpService, only from allow-listed https hosts, only if the SHA-256 matches.
	function Library:FetchVerified(Url, ExpectedSha256)
		if not Settings.AllowRemote then return nil, "Remote loading is disabled (Settings > Security)" end
		if type(Url) ~= "string" or #Url > 500 then return nil, "Invalid URL" end
		local Host = string.match(Url, "^https://([%w%.%-]+)/")
		if not Host or not table.find(Library.Security.AllowedHosts, string.lower(Host)) then return nil, "Host is not allow-listed" end
		if type(ExpectedSha256) ~= "string" or #ExpectedSha256 ~= 64 or not string.match(ExpectedSha256, "^%x+$") then
			return nil, "A SHA-256 hash (64 hex chars) is required"
		end
		local Ok, Body = pcall(function() return HttpService:GetAsync(Url, true) end)
		if not Ok then return nil, "Request failed: " .. tostring(Body) end
		if #Body > Library.Security.MaxBytes then return nil, "Response too large" end
		if Library:Sha256(Body) ~= string.lower(ExpectedSha256) then return nil, "Hash mismatch - download rejected" end
		return Body
	end

	function Library:LoadRemote(Url, ExpectedSha256)
		local Body, Err = Library:FetchVerified(Url, ExpectedSha256)
		if not Body then return nil, Err end
		if typeof(loadstring) ~= "function" then return nil, "loadstring is not available in this environment" end
		local Fn, CompileErr = loadstring(Body, "=UILibrary.Remote")
		if not Fn then return nil, CompileErr end
		local Ok, Result = pcall(Fn)
		if not Ok then return nil, tostring(Result) end
		return Result
	end

	function Library:LoadRemoteConfig(Url, ExpectedSha256)
		local Body, Err = Library:FetchVerified(Url, ExpectedSha256)
		if not Body then return false, Err end
		return Library:Deserialize(Body)
	end

	-----------------------------------------------------------------------
	-- Validated config loading (replaces the simple Deserialize above)
	-----------------------------------------------------------------------
	local function Sane(N) return type(N) == "number" and N == N and math.abs(N) < 1e9 end

	local function Validate(Obj, Kind, V)
		if Kind == "Toggle" then return type(V) == "boolean" end
		if Kind == "Slider" then
			if type(Obj:GetValue()) == "table" then return type(V) == "table" and Sane(V[1]) and Sane(V[2]) end
			return Sane(V)
		end
		if Kind == "SliderBox" then return type(V) == "table" and Sane(V[1]) and Sane(V[2]) end
		if Kind == "Textbox" then return type(V) == "string" and #V <= 2000 end
		if Kind == "Codebox" then return type(V) == "string" and #V <= Settings.MaxCodeLength end
		if Kind == "Dropdown" then
			local Options = Obj:GetOptions()
			if type(V) == "string" then return table.find(Options, V) ~= nil end
			if type(V) ~= "table" or #V > 200 then return false end
			for _, X in V do
				if type(X) ~= "string" or not table.find(Options, X) then return false end
			end
			return true
		end
		if Kind == "Colorpicker" then return type(V) == "table" and IsHex(V.Color) and Sane(V.Alpha) end
		if Kind == "Keybind" then
			return V == false or (type(V) == "table" and (V.Type == "KeyCode" or V.Type == "UserInputType") and type(V.Name) == "string")
		end
		return false
	end

	local SecurityFlags = {["Settings/AllowRemote"] = true, ["Settings/SafeCallbacks"] = true, ["Settings/LogicMaxPerSecond"] = true}

	function Library:Deserialize(Json)
		if type(Json) ~= "string" or #Json > 400000 then return false, "Invalid config" end
		local Ok, Data = pcall(function() return HttpService:JSONDecode(Json) end)
		if not Ok or type(Data) ~= "table" then return false, "Config is not valid JSON" end
		local Applied = 0
		for Flag, Value in Data do
			if type(Flag) ~= "string" or string.sub(Flag, 1, 1) == "_" or SecurityFlags[Flag] then continue end
			local Obj = self.Flags[Flag]
			if not Obj then continue end
			local KOk, Kind = pcall(Obj.GetComponentType, Obj)
			if not KOk or Kind == "Button" then continue end
			local VOk, Valid = pcall(Validate, Obj, Kind, Value)
			if not (VOk and Valid) then
				warn("[UILibrary] Skipped invalid config value for " .. Flag)
				continue
			end
			local AOk = pcall(function()
				if Kind == "Colorpicker" then
					Obj:SetValue(Color3.fromHex(Value.Color))
					Obj:SetTransparency(Value.Alpha)
				elseif Kind == "Keybind" then
					Obj:SetValue(Value and Enum[Value.Type][Value.Name] or nil)
				else
					Obj:SetValue(Value)
				end
			end)
			if AOk then Applied += 1 end
		end
		return true, Applied
	end

	-----------------------------------------------------------------------
	-- Languages / syntax highlighting
	-----------------------------------------------------------------------
	local Members = {
		string = {"format", "sub", "find", "match", "gmatch", "gsub", "rep", "len", "lower", "upper", "byte", "char", "split", "reverse", "pack", "unpack"},
		table = {"insert", "remove", "concat", "sort", "find", "clear", "clone", "unpack", "pack", "move", "freeze", "isfrozen", "create"},
		math = {"abs", "ceil", "floor", "max", "min", "sqrt", "sin", "cos", "tan", "pi", "huge", "random", "randomseed", "clamp", "round", "sign", "log", "exp", "rad", "deg", "noise", "lerp"},
		task = {"spawn", "defer", "delay", "wait", "cancel", "synchronize", "desynchronize"},
		game = {"GetService", "Players", "Workspace", "Lighting", "ReplicatedStorage", "RunService", "FindFirstChild", "FindFirstChildOfClass", "GetChildren", "GetDescendants", "IsA", "Destroy", "Clone", "Name", "Parent", "ClassName", "Changed", "ChildAdded", "PlaceId", "JobId"},
		workspace = {"CurrentCamera", "Gravity", "Terrain", "FindFirstChild", "GetChildren", "Raycast", "GetServerTimeNow"},
		Instance = {"new", "fromExisting"},
		Vector3 = {"new", "zero", "one", "xAxis", "yAxis", "zAxis"},
		Vector2 = {"new", "zero", "one"},
		CFrame = {"new", "Angles", "lookAt", "identity", "fromEulerAnglesXYZ", "fromOrientation"},
		Color3 = {"new", "fromRGB", "fromHSV", "fromHex"},
		UDim2 = {"new", "fromScale", "fromOffset"},
		Enum = {"KeyCode", "UserInputType", "Font", "EasingStyle", "EasingDirection", "Material"},
	}

	local Languages = {
		Lua = {
			Keywords = ToSet({"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "continue", "export", "type"}),
			Builtins = ToSet({"print", "warn", "error", "assert", "pcall", "xpcall", "pairs", "ipairs", "next", "select", "tostring", "tonumber", "type", "typeof", "setmetatable", "getmetatable", "rawget", "rawset", "require", "game", "workspace", "script", "Instance", "Enum", "Vector2", "Vector3", "CFrame", "Color3", "UDim", "UDim2", "BrickColor", "TweenInfo", "NumberSequence", "Ray", "task", "math", "string", "table", "os", "coroutine", "utf8", "bit32", "buffer", "wait", "spawn", "delay", "tick", "time", "shared", "_G", "Random", "Rect"}),
			Comment = "--", LongComments = true, LongStrings = true, AutoIndent = true, Members = Members,
		},
		Logic = {
			Keywords = ToSet({"on", "if", "do", "then"}),
			Builtins = {},
			Comment = "#", LongComments = false, LongStrings = false, AutoIndent = false, QuoteFlags = true,
		},
	}

	local EscMap = {["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&apos;"}
	local function Esc(S) return (string.gsub(S, "[&<>\"']", EscMap)) end

	local function ToHex(C3)
		return string.format("#%02X%02X%02X", math.floor(C3.R * 255 + 0.5), math.floor(C3.G * 255 + 0.5), math.floor(C3.B * 255 + 0.5))
	end

	local function HighlightCode(Src, Lang)
		local Syn = Library.Syntax
		local HText, HKey, HBuiltin = ToHex(Syn.Text), ToHex(Syn.Keyword), ToHex(Syn.Builtin)
		local HString, HNumber, HComment, HFunc = ToHex(Syn.String), ToHex(Syn.Number), ToHex(Syn.Comment), ToHex(Syn.Function)

		local Out, N = {}, 0
		local Buf, Cur = {}, HText
		local function Flush()
			if #Buf == 0 then return end
			local S = Esc(table.concat(Buf))
			N += 1
			if Cur == HText then Out[N] = S else Out[N] = '<font color="' .. Cur .. '">' .. S .. "</font>" end
			table.clear(Buf)
		end
		local function Push(Txt, Hex)
			if Hex ~= Cur then Flush(); Cur = Hex end
			Buf[#Buf + 1] = Txt
		end

		local Len = #Src
		local CL = Lang.Comment
		local CLLen = #CL
		local I = 1
		while I <= Len do
			local C = string.sub(Src, I, I)
			if string.sub(Src, I, I + CLLen - 1) == CL then
				local Eq = Lang.LongComments and string.match(Src, "^%-%-%[(=*)%[", I)
				if Eq then
					local _, E = string.find(Src, "]" .. Eq .. "]", I + 4 + #Eq, true)
					E = E or Len
					Push(string.sub(Src, I, E), HComment)
					I = E + 1
				else
					local E = string.find(Src, "\n", I, true)
					E = E and E - 1 or Len
					Push(string.sub(Src, I, E), HComment)
					I = E + 1
				end
			elseif C == '"' or C == "'" then
				local Pat = C == '"' and '[\\"\n]' or "[\\'\n]"
				local J, E = I + 1, nil
				while true do
					local Kpos = string.find(Src, Pat, J)
					if not Kpos then E = Len; break end
					local D = string.sub(Src, Kpos, Kpos)
					if D == "\\" then J = Kpos + 2
					elseif D == "\n" then E = Kpos - 1; break
					else E = Kpos; break end
				end
				Push(string.sub(Src, I, E), HString)
				I = E + 1
			elseif C == "[" and Lang.LongStrings and string.match(Src, "^%[=*%[", I) then
				local Eq = string.match(Src, "^%[(=*)%[", I)
				local _, E = string.find(Src, "]" .. Eq .. "]", I + 2 + #Eq, true)
				E = E or Len
				Push(string.sub(Src, I, E), HString)
				I = E + 1
			elseif string.find(C, "^%d") or (C == "." and string.find(string.sub(Src, I + 1, I + 1), "^%d")) then
				local _, E = string.find(Src, "^0[xX][%x_]+", I)
				if not E then _, E = string.find(Src, "^%d[%d_]*%.?%d*[eE][%+%-]?%d+", I) end
				if not E then _, E = string.find(Src, "^%d[%d_]*%.?%d*", I) end
				if not E then _, E = string.find(Src, "^%.%d+", I) end
				E = E or I
				Push(string.sub(Src, I, E), HNumber)
				I = E + 1
			elseif string.find(C, "^[%a_]") then
				local _, E = string.find(Src, "^[%w_]+", I)
				local Word = string.sub(Src, I, E)
				local Hex = HText
				if Lang.Keywords[Word] then Hex = HKey
				elseif Lang.Builtins[Word] then Hex = HBuiltin
				else
					local NextC = string.match(Src, "^[ \t]*(.)", E + 1)
					if NextC == "(" then Hex = HFunc end
				end
				Push(Word, Hex)
				I = E + 1
			else
				local E = string.find(Src, "[%w_\"'%-%[#%.]", I + 1)
				E = (E or Len + 1) - 1
				Push(string.sub(Src, I, E), HText)
				I = E + 1
			end
		end
		Flush()
		return table.concat(Out)
	end

	-----------------------------------------------------------------------
	-- Logic engine (event binds): "on <Event> [arg] [if <x> <op> <y>] do <Action> [args] [then <Action> ...]"
	-----------------------------------------------------------------------
	local Logic = {Rules = {}, Events = {}, Actions = {}, EventLookup = {}, ActionLookup = {}, Depth = 0, NeedsPoll = false}
	Library.Logic = Logic

	function Library:RegisterEvent(Name, Description)
		Logic.Events[Name] = Description or ""
		Logic.EventLookup[string.lower(Name)] = Name
		Languages.Logic.Builtins[Name] = true
	end

	function Library:RegisterAction(Name, Run, Usage)
		Logic.Actions[Name] = {Run = Run, Usage = Usage or Name}
		Logic.ActionLookup[string.lower(Name)] = Name
		Languages.Logic.Builtins[Name] = true
	end

	local Operators = ToSet({"==", "~=", "!=", ">", "<", ">=", "<=", "contains"})

	local function Tokenize(Line)
		local Tokens, I = {}, 1
		while I <= #Line do
			local C = string.sub(Line, I, I)
			if string.find(C, "^%s") then
				I += 1
			elseif C == '"' then
				local E = string.find(Line, '"', I + 1, true)
				if not E then return nil, "unterminated string" end
				table.insert(Tokens, {Text = string.sub(Line, I + 1, E - 1), Quoted = true})
				I = E + 1
			else
				local _, E = string.find(Line, '^[^%s"]+', I)
				table.insert(Tokens, {Text = string.sub(Line, I, E)})
				I = E + 1
			end
		end
		return Tokens
	end

	local function Coerce(Tok)
		if Tok.Quoted then return Tok.Text end
		local L = string.lower(Tok.Text)
		if L == "true" then return true end
		if L == "false" then return false end
		return tonumber(Tok.Text) or Tok.Text
	end

	local function IsKw(Tok, Word) return Tok ~= nil and not Tok.Quoted and string.lower(Tok.Text) == Word end

	local function ParseLine(Line)
		local Tokens, Err = Tokenize(Line)
		if not Tokens then return nil, Err end
		if #Tokens < 4 then return nil, "incomplete rule" end
		if not IsKw(Tokens[1], "on") then return nil, "rule must start with 'on'" end
		local Event = Logic.EventLookup[string.lower(Tokens[2].Text)]
		if not Event then return nil, "unknown event '" .. Tokens[2].Text .. "'" end

		local Rule = {Event = Event, Actions = {}, Enabled = true}
		local I = 3
		if Tokens[I] and not IsKw(Tokens[I], "if") and not IsKw(Tokens[I], "do") then
			Rule.Arg = Tokens[I].Text
			I += 1
		end
		if IsKw(Tokens[I], "if") then
			local L, Op, R = Tokens[I + 1], Tokens[I + 2], Tokens[I + 3]
			if not (L and Op and R) then return nil, "incomplete condition" end
			if not Operators[Op.Text] then return nil, "unknown operator '" .. Op.Text .. "'" end
			Rule.Cond = {Left = L.Text, LeftQuoted = L.Quoted, Op = Op.Text, Right = Coerce(R)}
			I += 4
		end
		if not IsKw(Tokens[I], "do") then return nil, "expected 'do'" end
		I += 1

		local Current
		while Tokens[I] do
			local T = Tokens[I]
			if IsKw(T, "then") then
				Current = nil
			elseif not Current then
				local Name = Logic.ActionLookup[string.lower(T.Text)]
				if not Name then return nil, "unknown action '" .. T.Text .. "'" end
				Current = {Name = Name, Args = {}}
				table.insert(Rule.Actions, Current)
			else
				table.insert(Current.Args, Coerce(T))
			end
			I += 1
		end
		if #Rule.Actions == 0 then return nil, "no action" end
		if #Rule.Actions > 8 then return nil, "too many actions (max 8)" end
		return Rule
	end

	function Library:ParseLogic(Source)
		local Rules, Errors, Count = {}, {}, 0
		for LineNo, Line in string.split(tostring(Source), "\n") do
			local Trim = string.match(Line, "^%s*(.-)%s*$")
			if Trim ~= "" and string.sub(Trim, 1, 1) ~= "#" then
				Count += 1
				if Count > 100 then
					table.insert(Errors, "line " .. LineNo .. ": rule limit (100) reached")
					break
				end
				local Rule, Err = ParseLine(Trim)
				if Rule then
					Rule.Line = LineNo
					table.insert(Rules, Rule)
				else
					table.insert(Errors, "line " .. LineNo .. ": " .. Err)
				end
			end
		end
		return Rules, Errors
	end

	local function Compare(Left, Op, Right)
		if Op == "==" then return Left == Right or tostring(Left) == tostring(Right) end
		if Op == "~=" or Op == "!=" then return not (Left == Right or tostring(Left) == tostring(Right)) end
		if Op == "contains" then return string.find(tostring(Left), tostring(Right), 1, true) ~= nil end
		local A, B = tonumber(Left), tonumber(Right)
		if not A or not B then return false end
		if Op == ">" then return A > B end
		if Op == "<" then return A < B end
		if Op == ">=" then return A >= B end
		if Op == "<=" then return A <= B end
		return false
	end

	local function EvalCond(Rule, EvArgs)
		local C = Rule.Cond
		if not C then return true end
		local Left
		if not C.LeftQuoted and string.lower(C.Left) == "value" then
			Left = (EvArgs.n or 0) >= 2 and EvArgs[2] or EvArgs[1]
		else
			local F = Library.Flags[C.Left]
			if not F or F:GetComponentType() == "Button" then return false end
			Left = F:GetValue()
			if typeof(Left) == "Color3" then Left = Left:ToHex() end
		end
		return Compare(Left, C.Op, C.Right)
	end

	local function Execute(Rule, EvArgs)
		local Now = os.clock()
		if Now - (Rule.WindowStart or 0) >= 1 then
			Rule.WindowStart = Now
			Rule.Hits = 0
			Rule.Warned = false
		end
		Rule.Hits = (Rule.Hits or 0) + 1
		if Rule.Hits > Settings.LogicMaxPerSecond then
			if not Rule.Warned then
				Rule.Warned = true
				warn("[UILibrary] Logic rule on line " .. tostring(Rule.Line) .. " exceeded the rate limit and is being throttled")
			end
			return
		end
		if not EvalCond(Rule, EvArgs) then return end
		for _, A in Rule.Actions do
			local Action = Logic.Actions[A.Name]
			if Action then
				local Ok, Err = pcall(Action.Run, A.Args, EvArgs, Rule)
				if not Ok then warn("[UILibrary] Logic action '" .. A.Name .. "' failed: " .. tostring(Err)) end
			end
		end
	end

	function Library:FireEvent(Name, ...)
		if #Logic.Rules == 0 or Logic.Depth >= 4 then return end
		local Key = string.lower(Name)
		local Args = table.pack(...)
		Logic.Depth += 1
		for _, Rule in Logic.Rules do
			if Rule.Enabled and Rule.Event ~= "Tick" and string.lower(Rule.Event) == Key then
				if Rule.Arg == nil or Rule.Arg == "*" or tostring(Args[1]) == Rule.Arg then
					Execute(Rule, Args)
				end
			end
		end
		Logic.Depth -= 1
	end

	local LastValues, PollAcc, LogicConn = {}, 0, nil

	local function Snapshot(V)
		if typeof(V) == "table" then
			local Ok, J = pcall(function() return HttpService:JSONEncode(V) end)
			return Ok and J or tostring(V)
		end
		return tostring(V)
	end

	local function OnHeartbeat(Dt)
		for _, Rule in Logic.Rules do
			if Rule.Enabled and Rule.Event == "Tick" then
				Rule.Timer = (Rule.Timer or 0) + Dt
				if Rule.Timer >= math.max(tonumber(Rule.Arg) or 1, 0.1) then
					Rule.Timer = 0
					Execute(Rule, table.pack())
				end
			end
		end
		PollAcc += Dt
		if Logic.NeedsPoll and PollAcc >= Settings.PollInterval then
			PollAcc = 0
			for Flag, Obj in Library.Flags do
				if string.sub(Flag, 1, 1) == "_" then continue end
				local Ok, Kind = pcall(Obj.GetComponentType, Obj)
				if Ok and Kind ~= "Button" and Kind ~= "Codebox" then
					local V = Obj:GetValue()
					local Snap = Snapshot(V)
					if LastValues[Flag] ~= nil and LastValues[Flag] ~= Snap then
						Library:FireEvent("FlagChanged", Flag, V)
					end
					LastValues[Flag] = Snap
				end
			end
		end
	end

	local function UpdateLogicLoop()
		local Needs = false
		Logic.NeedsPoll = false
		for _, R in Logic.Rules do
			if R.Event == "Tick" then Needs = true end
			if R.Event == "FlagChanged" then Needs = true; Logic.NeedsPoll = true end
		end
		if Needs and not LogicConn then
			LogicConn = RunService.Heartbeat:Connect(OnHeartbeat)
		elseif not Needs and LogicConn then
			LogicConn:Disconnect()
			LogicConn = nil
		end
	end

	function Library:SetLogic(Source)
		local Rules, Errors = Library:ParseLogic(Source or "")
		Logic.Rules = Rules
		table.clear(LastValues)
		UpdateLogicLoop()
		return #Rules, Errors
	end

	-- built-in events
	Library:RegisterEvent("FlagChanged", "flag, value - a component's value changed")
	Library:RegisterEvent("ButtonPressed", "flag - a Button was clicked")
	Library:RegisterEvent("KeyPressed", "flag - a Keybind was pressed")
	Library:RegisterEvent("WindowToggled", "visible - the window was shown/hidden")
	Library:RegisterEvent("Tick", "seconds - repeating timer (arg = interval)")
	Library:RegisterEvent("PlayerAdded", "name - a player joined")
	Library:RegisterEvent("PlayerRemoving", "name - a player left")
	Library:RegisterEvent("CharacterAdded", "your character spawned")

	local EventConns = {
		Players.PlayerAdded:Connect(function(P) Library:FireEvent("PlayerAdded", P.Name) end),
		Players.PlayerRemoving:Connect(function(P) Library:FireEvent("PlayerRemoving", P.Name) end),
		LocalPlayer.CharacterAdded:Connect(function() Library:FireEvent("CharacterAdded") end),
	}

	local Protected = {Keybind = true, Codebox = true} -- logic can't rewrite these (stops logic from editing logic)

	Library:RegisterAction("SetFlag", function(A)
		local F = Library.Flags[tostring(A[1])]
		if not F then return end
		local Kind = F:GetComponentType()
		if Kind == "Button" or Protected[Kind] then return end
		local V = A[2]
		if Kind == "Colorpicker" then
			if type(V) ~= "string" or not IsHex(V) then return end
			V = Color3.fromHex(V)
		end
		F:SetValue(V)
	end, 'SetFlag "flag" value')

	Library:RegisterAction("ToggleFlag", function(A)
		local F = Library.Flags[tostring(A[1])]
		if F and F:GetComponentType() == "Toggle" then F:SetValue(not F:GetValue()) end
	end, 'ToggleFlag "flag"')

	Library:RegisterAction("Press", function(A)
		local F = Library.Flags[tostring(A[1])]
		if F and F:GetComponentType() == "Button" then F:Fire() end
	end, 'Press "button flag"')

	Library:RegisterAction("Notify", function(A)
		local Win = Library.Windows[1]
		if not Win then return end
		local Parts = {}
		for _, V in A do table.insert(Parts, tostring(V)) end
		Win:Notify({Title = "Logic", Content = table.concat(Parts, " ")})
	end, 'Notify "text"')

	Library:RegisterAction("Log", function(A)
		local Parts = {}
		for _, V in A do table.insert(Parts, tostring(V)) end
		print("[Logic]", table.concat(Parts, " "))
	end, 'Log "text"')

	Library:RegisterAction("ToggleWindow", function()
		local Win = Library.Windows[1]
		if Win then Win:ToggleVisibility() end
	end, "ToggleWindow")

	Library:RegisterAction("ApplyPreset", function(A) Library:ApplyPreset(tostring(A[1])) end, 'ApplyPreset "name"')

	Library:RegisterAction("SetSetting", function(A)
		local Key = tostring(A[1])
		if Key == "AllowRemote" or Key == "SafeCallbacks" or Key == "LogicMaxPerSecond" then return end -- security settings are not scriptable
		Library:SetSetting(Key, A[2])
	end, "SetSetting Key value")

	local CoreUnload = Library.Unload
	function Library:Unload()
		CoreUnload(self)
		if LogicConn then LogicConn:Disconnect(); LogicConn = nil end
		for _, Conn in EventConns do Conn:Disconnect() end
		table.clear(EventConns)
		table.clear(Logic.Rules)
	end

	-----------------------------------------------------------------------
	-- Blur / Depth of Field
	-----------------------------------------------------------------------
	local Effects = {}

	function Library:UpdateEffects()
		if #Library.Windows == 0 then
			for Key, Inst in Effects do Inst:Destroy(); Effects[Key] = nil end
			return
		end
		local Active = false
		for _, W in Library.Windows do
			if W.Visible then Active = true; break end
		end
		local NotLow = Settings.Performance ~= "Low"
		local WantBlur = Active and Settings.Blur and NotLow
		local WantDOF = Active and Settings.DOF and NotLow

		if WantBlur and not Effects.Blur then
			Effects.Blur = Create("BlurEffect", {Name = "UILibBlur", Size = 0, Parent = Lighting})
		end
		if Effects.Blur then
			Tween(Effects.Blur, TweenSmooth, {Size = WantBlur and Settings.BlurSize or 0})
		end

		if WantDOF and not Effects.DOF then
			Effects.DOF = Create("DepthOfFieldEffect", {Name = "UILibDOF", FarIntensity = 0, NearIntensity = 0, FocusDistance = Settings.DOFFocusDistance, InFocusRadius = Settings.DOFInFocusRadius, Parent = Lighting})
		end
		if Effects.DOF then
			Effects.DOF.FocusDistance = Settings.DOFFocusDistance
			Effects.DOF.InFocusRadius = Settings.DOFInFocusRadius
			Tween(Effects.DOF, TweenSmooth, {
				FarIntensity = WantDOF and Settings.DOFFarIntensity or 0,
				NearIntensity = WantDOF and Settings.DOFNearIntensity or 0,
			})
		end
	end

	-----------------------------------------------------------------------
	-- Performance presets
	-----------------------------------------------------------------------
	local PerfPresets = {
		High = {AnimSpeed = 1, HighlightMaxLength = 20000, PollInterval = 0.2},
		Balanced = {AnimSpeed = 1.6, Tilt = false, DOF = false, HighlightMaxLength = 10000, PollInterval = 0.3},
		Low = {AnimSpeed = 0, Tilt = false, Blur = false, DOF = false, WindowTransparency = 0, HighlightMaxLength = 4000, PollInterval = 0.5},
	}

	function Library:SetPerformance(Mode)
		local P = PerfPresets[Mode]
		if not P then return false end
		Library:SetSetting("Performance", Mode)
		for Key, Value in P do Library:SetSetting(Key, Value) end
		return true
	end

	-----------------------------------------------------------------------
	-- TAB EXTENSION: SliderBox, Codebox, LogicEditor
	-----------------------------------------------------------------------
	table.insert(Library.TabExtensions, function(TabObj, C)
		local function Fmt(V, Dec) return string.format("%." .. Dec .. "f", V) end

		-------------------------------------------------------------------
		-- SliderBox (XY pad)
		-------------------------------------------------------------------
		function TabObj:SliderBox(O)
			O = O or {}
			local Title = O.Title or "SliderBox"
			local MinX, MaxX = O.MinX or 0, O.MaxX or 100
			local MinY, MaxY = O.MinY or 0, O.MaxY or 100
			local RX, RY = math.max(MaxX - MinX, 1e-9), math.max(MaxY - MinY, 1e-9)
			local DecX, DecY = O.DecimalX or 0, O.DecimalY or 0
			local NameX, NameY = O.NameX or "X", O.NameY or "Y"
			local Callback = C.Safe(O.Callback)
			local PadH = O.Height or 140

			local D = type(O.Default) == "table" and O.Default or {}
			local Current = {math.clamp(D[1] or MinX, MinX, MaxX), math.clamp(D[2] or MinY, MinY, MaxY)}

			local Row = C.CreateRow(Title, PadH + 44)
			local TitleLabel = C.RowTitle(Row, Title, 240)
			TitleLabel.Size = UDim2.new(1, -240, 0, 30)
			local ValueLabel = Create("TextLabel", {Size = UDim2.fromOffset(230, 30), Position = UDim2.new(1, -238, 0, 0), BackgroundTransparency = 1, Text = "", TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right, Parent = Row})
			C.Themed(ValueLabel, {TextColor3 = "TextPrimary", Font = "Font"})

			local Pad = Create("TextButton", {Size = UDim2.new(1, -16, 0, PadH), Position = UDim2.fromOffset(8, 34), BackgroundColor3 = Theme.Search, Text = "", AutoButtonColor = false, ClipsDescendants = true, Parent = Row})
			Corner(Pad, 6)
			local PadStroke = Create("UIStroke", {Color = Theme.Border, Thickness = 1, Parent = Pad})
			C.Themed(Pad, {BackgroundColor3 = "Search"})
			C.Themed(PadStroke, {Color = "Border"})

			for I = 1, 3 do
				local V = Create("Frame", {Size = UDim2.new(0, 1, 1, 0), Position = UDim2.fromScale(I / 4, 0), BackgroundColor3 = Theme.Border, BackgroundTransparency = 0.5, BorderSizePixel = 0, Parent = Pad})
				local H = Create("Frame", {Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromScale(0, I / 4), BackgroundColor3 = Theme.Border, BackgroundTransparency = 0.5, BorderSizePixel = 0, Parent = Pad})
				C.Themed(V, {BackgroundColor3 = "Border"})
				C.Themed(H, {BackgroundColor3 = "Border"})
			end
			local GuideV = Create("Frame", {Size = UDim2.new(0, 1, 1, 0), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 0.6, BorderSizePixel = 0, Parent = Pad})
			local GuideH = Create("Frame", {Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 0.6, BorderSizePixel = 0, Parent = Pad})
			local Handle = Create("Frame", {Size = UDim2.fromOffset(14, 14), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Theme.Accent, Parent = Pad})
			Corner(Handle, 7, true)
			local HandleStroke = Create("UIStroke", {Color = Theme.TextPrimary, Thickness = 2, Parent = Handle})
			C.Themed(GuideV, {BackgroundColor3 = "Accent"})
			C.Themed(GuideH, {BackgroundColor3 = "Accent"})
			C.Themed(Handle, {BackgroundColor3 = "Accent"})
			C.Themed(HandleStroke, {Color = "TextPrimary"})

			local function Render()
				local AX = (Current[1] - MinX) / RX
				local AY = 1 - (Current[2] - MinY) / RY
				Handle.Position = UDim2.fromScale(AX, AY)
				GuideV.Position = UDim2.fromScale(AX, 0)
				GuideH.Position = UDim2.fromScale(0, AY)
				ValueLabel.Text = string.format("%s: %s    %s: %s", NameX, Fmt(Current[1], DecX), NameY, Fmt(Current[2], DecY))
			end

			local function SetXY(X, Y, Fire)
				X = math.clamp(tonumber(X) or MinX, MinX, MaxX)
				Y = math.clamp(tonumber(Y) or MinY, MinY, MaxY)
				if Fire and X == Current[1] and Y == Current[2] then return end
				Current = {X, Y}
				Render()
				if Fire then Callback(X, Y) end
			end

			local function Apply(Input)
				local Pos, Size = Pad.AbsolutePosition, Pad.AbsoluteSize
				local AX = math.clamp((Input.Position.X - Pos.X) / math.max(Size.X, 1), 0, 1)
				local AY = math.clamp((Input.Position.Y - Pos.Y) / math.max(Size.Y, 1), 0, 1)
				local MX, MY = 10 ^ DecX, 10 ^ DecY
				SetXY(math.round((MinX + RX * AX) * MX) / MX, math.round((MinY + RY * (1 - AY)) * MY) / MY, true)
			end

			C.Janitor:Give(Pad.InputBegan:Connect(function(Input)
				if Input.UserInputType ~= Enum.UserInputType.MouseButton1 and Input.UserInputType ~= Enum.UserInputType.Touch then return end
				Apply(Input)
				C.BeginDrag(Apply)
			end))

			Render()
			local Obj = {Row = Row}
			function Obj:GetComponentType() return "SliderBox" end
			function Obj:GetValue() return {Current[1], Current[2]} end
			function Obj:SetValue(Val, Silent)
				if type(Val) ~= "table" then return end
				SetXY(Val[1], Val[2], not Silent)
			end
			C.Register(C.FlagFor(O, "SliderBox", Title), Obj)
			return Obj
		end

		-------------------------------------------------------------------
		-- Codebox
		-------------------------------------------------------------------
		function TabObj:Codebox(O)
			O = O or {}
			local Title = O.Title or "Codebox"
			local Lang = Languages[O.Language or "Lua"] or Languages.Lua
			local Height = O.Height or 220
			local ReadOnly = O.ReadOnly or false
			local Callback = C.Safe(O.Callback)
			local GutterW = 38
			local FontEnum = Enum.Font.Code

			local Row = C.CreateRow(Title, Height + 40)
			local TitleLabel = C.RowTitle(Row, Title, 200)
			TitleLabel.Size = UDim2.new(1, -16, 0, 30)

			local Editor = Create("Frame", {Size = UDim2.new(1, -16, 0, Height), Position = UDim2.fromOffset(8, 34), BackgroundColor3 = Theme.Search, ClipsDescendants = true, Parent = Row})
			Corner(Editor, 6)
			local EditorStroke = Create("UIStroke", {Color = Theme.Border, Thickness = 1, Parent = Editor})
			C.Themed(Editor, {BackgroundColor3 = "Search"})
			C.Themed(EditorStroke, {Color = "Border"})

			local Gutter = Create("Frame", {Size = UDim2.new(0, GutterW, 1, 0), BackgroundColor3 = Theme.Main, BorderSizePixel = 0, ClipsDescendants = true, Parent = Editor})
			C.Themed(Gutter, {BackgroundColor3 = "Main"})
			local GutterText = Create("TextLabel", {Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.fromOffset(0, 4), BackgroundTransparency = 1, Text = "1", TextColor3 = Theme.TextSecondary, Font = FontEnum, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Top, Parent = Gutter})
			C.Themed(GutterText, {TextColor3 = "TextSecondary"})

			local Scroller = Create("ScrollingFrame", {Size = UDim2.new(1, -GutterW, 1, 0), Position = UDim2.fromOffset(GutterW, 0), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6, ScrollBarImageColor3 = Theme.Border, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.XY, ScrollingDirection = Enum.ScrollingDirection.XY, Parent = Editor})
			C.Themed(Scroller, {ScrollBarImageColor3 = "Border"})

			local function Pad(Inst)
				Create("UIPadding", {PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), Parent = Inst})
			end

			local Highlight = Create("TextLabel", {Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, BackgroundTransparency = 1, Text = "", RichText = true, TextColor3 = Library.Syntax.Text, Font = FontEnum, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = false, Parent = Scroller})
			Pad(Highlight)
			local HighlightMin = Create("UISizeConstraint", {Parent = Highlight})

			local Box = Create("TextBox", {Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, BackgroundTransparency = 1, Text = "", TextTransparency = 1, TextColor3 = Theme.TextPrimary, Font = FontEnum, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = false, MultiLine = true, ClearTextOnFocus = false, TextEditable = not ReadOnly, ZIndex = 2, Parent = Scroller})
			Pad(Box)
			local BoxMin = Create("UISizeConstraint", {Parent = Box})

			-- autocomplete popup
			local Pop = Create("Frame", {Size = UDim2.fromOffset(190, 24), BackgroundColor3 = Theme.Main, Visible = false, ZIndex = 30, Parent = Editor})
			Corner(Pop, 4)
			local PopStroke = Create("UIStroke", {Color = Theme.Border, Thickness = 1, Parent = Pop})
			Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = Pop})
			C.Themed(Pop, {BackgroundColor3 = "Main"})
			C.Themed(PopStroke, {Color = "Border"})

			-- metrics (measured once, falls back to sane defaults)
			local CharW, LineH = 7.8, 13
			local function ScaleOf()
				local H = Scroller.AbsoluteSize.Y
				return H > 0 and H / Height or 1
			end
			local function ViewSize()
				local S = ScaleOf()
				local W = Scroller.AbsoluteWindowSize
				return W.X / S, W.Y / S
			end
			local function FitMin()
				local S = ScaleOf()
				local W = Scroller.AbsoluteSize
				local Min = Vector2.new(math.max(W.X / S - 14, 10), math.max(W.Y / S - 14, 10))
				HighlightMin.MinSize = Min
				BoxMin.MinSize = Min
			end
			C.Janitor:Give(Scroller:GetPropertyChangedSignal("AbsoluteSize"):Connect(FitMin))
			FitMin()

			local Busy, LastLen, CursorMemo = false, 0, 1
			local LineCount = 0
			local Items, ItemLen, Sel, Shown = {}, 0, 1, false

			local function Draw()
				local Text = Box.Text
				if #Text <= Settings.HighlightMaxLength then
					Highlight.Text = HighlightCode(Text, Lang)
				else
					Highlight.Text = Esc(Text)
				end
				local Lines = select(2, string.gsub(Text, "\n", "")) + 1
				if Lines ~= LineCount then
					LineCount = Lines
					local T = table.create(Lines)
					for I = 1, Lines do T[I] = I end
					GutterText.Text = table.concat(T, "\n")
				end
			end

			local function CaretXY()
				if Box.CursorPosition > 0 then CursorMemo = Box.CursorPosition end
				local Before = string.sub(Box.Text, 1, CursorMemo - 1)
				local _, Nl = string.gsub(Before, "\n", "")
				local LastNl = string.find(Before, "\n[^\n]*$")
				local Col = CursorMemo - 1 - (LastNl or 0)
				return 6 + Col * CharW, 4 + Nl * LineH
			end

			local function ScrollToCaret()
				local X, Y = CaretXY()
				local VX, VY = ViewSize()
				local CP = Scroller.CanvasPosition
				local NX, NY = CP.X, CP.Y
				if Y < NY then NY = Y elseif Y + LineH + 8 > NY + VY then NY = Y + LineH + 8 - VY end
				if X < NX + 8 then NX = math.max(X - 8, 0) elseif X + CharW + 12 > NX + VX then NX = X + CharW + 12 - VX end
				if NX ~= CP.X or NY ~= CP.Y then Scroller.CanvasPosition = Vector2.new(NX, NY) end
			end

			local function Hide()
				Shown = false
				Pop.Visible = false
			end

			local function PositionPopup()
				local X, Y = CaretXY()
				local CP = Scroller.CanvasPosition
				local H = #Items * 20 + 4
				local EdW = Editor.AbsoluteSize.X / ScaleOf()
				local Px = math.clamp(GutterW + X - CP.X, GutterW, math.max(EdW - 194, GutterW))
				local Py = Y - CP.Y + LineH + 2
				if Py + H > Height then Py = Y - CP.Y - H - 2 end
				Pop.Position = UDim2.fromOffset(Px, math.max(Py, 0))
				Pop.Size = UDim2.fromOffset(190, H)
			end

			C.Janitor:Give(Scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
				GutterText.Position = UDim2.fromOffset(0, 4 - Scroller.CanvasPosition.Y)
				if Shown then PositionPopup() end
			end))

			local function Accept(Word, Len)
				local Pos, Text = CursorMemo, Box.Text
				local New = string.sub(Text, 1, Pos - 1 - Len) .. Word .. string.sub(Text, Pos)
				Busy = true
				Box.Text = New
				if not Box:IsFocused() then Box:CaptureFocus() end
				Box.CursorPosition = Pos - Len + #Word
				Busy = false
				LastLen = #New
				Hide()
				Draw()
				CursorMemo = Pos - Len + #Word
			end

			local function PaintSelection()
				for I, Btn in Pop:GetChildren() do
					if Btn:IsA("TextButton") then
						Btn.BackgroundTransparency = (Btn.LayoutOrder == Sel) and 0.7 or 1
					end
				end
			end

			local function ShowPopup()
				for _, Ch in Pop:GetChildren() do
					if Ch:IsA("TextButton") then Ch:Destroy() end
				end
				for I, Word in Items do
					local Btn = Create("TextButton", {Size = UDim2.new(1, 0, 0, 20), BackgroundColor3 = Theme.Accent, BackgroundTransparency = I == Sel and 0.7 or 1, Text = "  " .. Word, TextColor3 = Theme.TextPrimary, Font = FontEnum, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, AutoButtonColor = false, LayoutOrder = I, ZIndex = 31, Parent = Pop})
					Btn.MouseEnter:Connect(function() Sel = I; PaintSelection() end)
					Btn.MouseButton1Click:Connect(function() Accept(Word, ItemLen) end)
				end
				Shown = true
				Pop.Visible = true
				PositionPopup()
			end

			local function BaseWords(Text, Typed)
				local Seen, List = {}, {}
				local function Add(W)
					if not Seen[W] and W ~= Typed and #W > 1 then Seen[W] = true; List[#List + 1] = W end
				end
				for W in Lang.Keywords do Add(W) end
				for W in Lang.Builtins do Add(W) end
				if O.Words then for _, W in O.Words do Add(W) end end
				for W in string.gmatch(string.sub(Text, 1, 20000), "[%a_][%w_]*") do Add(W) end
				return List
			end

			local function Candidates(Text, Pos)
				local Before = string.sub(Text, 1, Pos - 1)
				local Out = {}
				if Lang.QuoteFlags then
					local LineBefore = string.match(Before, "[^\n]*$") or ""
					local _, QuoteCount = string.gsub(LineBefore, '"', "")
					local InQuote = QuoteCount % 2 == 1 and string.match(LineBefore, '"([^"]*)$') or nil
					if InQuote then
						local Q = string.lower(InQuote)
						for Flag in Library.Flags do
							if string.sub(Flag, 1, 1) ~= "_" and Flag ~= InQuote and (Q == "" or string.find(string.lower(Flag), Q, 1, true)) then
								Out[#Out + 1] = Flag
							end
						end
						table.sort(Out)
						while #Out > 6 do table.remove(Out) end
						return Out, #InQuote
					end
				end
				local Prefix = string.match(Before, "[%w_%.:]*$") or ""
				local Obj, Member = string.match(Prefix, "^([%w_]+)[%.:]([%w_]*)$")
				local Typed, List
				if Obj then
					if not (Lang.Members and Lang.Members[Obj]) then return Out, 0 end
					Typed, List = Member, Lang.Members[Obj]
				elseif string.find(Prefix, "[%.:]") then
					return Out, 0
				else
					Typed = Prefix
					if #Typed < 2 then return Out, 0 end
					List = BaseWords(Text, Typed)
				end
				local Low = string.lower(Typed)
				for _, W in List do
					if W ~= Typed and string.lower(string.sub(W, 1, #Typed)) == Low then Out[#Out + 1] = W end
				end
				table.sort(Out, function(A, B) if #A ~= #B then return #A < #B end return A < B end)
				while #Out > 6 do table.remove(Out) end
				return Out, #Typed
			end

			local function Suggest()
				if O.Autocomplete == false or ReadOnly or not Box:IsFocused() then Hide() return end
				local Pos = Box.CursorPosition
				if Pos < 1 then return end
				CursorMemo = Pos
				local List, Len = Candidates(Box.Text, Pos)
				if #List == 0 then Hide() return end
				Items, ItemLen, Sel = List, Len, 1
				ShowPopup()
			end

			local Pending = false
			local function Update()
				if Pending then return end
				Pending = true
				task.defer(function()
					Pending = false
					if not Box.Parent then return end
					Draw()
					ScrollToCaret()
					Suggest()
				end)
			end

			local OpenerPatterns = {"%f[%w]then%s*$", "%f[%w]do%s*$", "%f[%w]else%s*$", "%f[%w]repeat%s*$", "function%s*[%w_%.:]*%b()%s*$", "[{%(]%s*$"}

			C.Janitor:Give(Box:GetPropertyChangedSignal("Text"):Connect(function()
				if Busy then return end
				local Text, Pos = Box.Text, Box.CursorPosition
				if #Text > Settings.MaxCodeLength then
					Text = string.sub(Text, 1, Settings.MaxCodeLength)
					Busy = true; Box.Text = Text; Busy = false
					Pos = math.min(Pos, #Text + 1)
				end
				if not ReadOnly and Pos > 1 then
					local PrevChar = string.sub(Text, Pos - 1, Pos - 1)
					if PrevChar == "\t" then
						local Without = string.sub(Text, 1, Pos - 2) .. string.sub(Text, Pos)
						if Shown and Items[Sel] then
							Busy = true; Box.Text = Without; Box.CursorPosition = Pos - 1; Busy = false
							LastLen = #Without
							CursorMemo = Pos - 1
							Accept(Items[Sel], ItemLen)
							Update()
							return
						end
						local Spaced = string.sub(Text, 1, Pos - 2) .. "    " .. string.sub(Text, Pos)
						Busy = true; Box.Text = Spaced; Box.CursorPosition = Pos + 3; Busy = false
						LastLen = #Spaced
						Update()
						return
					elseif PrevChar == "\n" and #Text == LastLen + 1 and Lang.AutoIndent then
						local Before = string.sub(Text, 1, Pos - 2)
						local LastNl = string.find(Before, "\n[^\n]*$")
						local PrevLine = LastNl and string.sub(Before, LastNl + 1) or Before
						local Indent = string.match(PrevLine, "^[ \t]*") or ""
						for _, Pattern in OpenerPatterns do
							if string.find(PrevLine, Pattern) then Indent = Indent .. "    "; break end
						end
						if #Indent > 0 then
							local New = string.sub(Text, 1, Pos - 1) .. Indent .. string.sub(Text, Pos)
							Busy = true; Box.Text = New; Box.CursorPosition = Pos + #Indent; Busy = false
							LastLen = #New
							Update()
							return
						end
					end
				end
				LastLen = #Text
				Update()
			end))

			C.Janitor:Give(Box:GetPropertyChangedSignal("CursorPosition"):Connect(function()
				if Box.CursorPosition > 0 then CursorMemo = Box.CursorPosition end
				if not Busy then Update() end
			end))

			C.Janitor:Give(Box.Focused:Connect(function() Tween(EditorStroke, TweenFast, {Color = Theme.Accent}) end))
			C.Janitor:Give(Box.FocusLost:Connect(function(Enter)
				Tween(EditorStroke, TweenFast, {Color = Theme.Border})
				task.delay(0.15, Hide)
				Callback(Box.Text, Enter)
			end))

			C.OnTheme(function()
				Highlight.TextColor3 = Library.Syntax.Text
				Draw()
			end)

			local function SetText(Val)
				local S = tostring(Val or "")
				if #S > Settings.MaxCodeLength then S = string.sub(S, 1, Settings.MaxCodeLength) end
				Busy = true; Box.Text = S; Busy = false
				LastLen = #S
				Draw()
			end
			SetText(O.Default or "")

			task.spawn(function()
				local Ok, W1, W2 = pcall(function()
					local P = Instance.new("GetTextBoundsParams")
					P.Text = "WWWWWWWWWW"
					P.Font = Font.fromEnum(FontEnum)
					P.Size = 13
					P.Width = 10000
					local A = TextService:GetTextBoundsAsync(P)
					P.Text = "W\nW"
					local B = TextService:GetTextBoundsAsync(P)
					return A, B
				end)
				if Ok and W1.X > 0 and W2.Y > 0 then
					CharW, LineH = W1.X / 10, W2.Y / 2
				end
			end)

			local Obj = {Row = Row}
			function Obj:GetComponentType() return "Codebox" end
			function Obj:GetValue() return Box.Text end
			function Obj:SetValue(Val, Silent)
				SetText(Val)
				if not Silent then Callback(Box.Text, false) end
			end
			function Obj:Append(Line) SetText(Box.Text .. (Box.Text ~= "" and "\n" or "") .. tostring(Line)) end
			function Obj:Clear() SetText("") end
			C.Register(C.FlagFor(O, "Codebox", Title), Obj)
			return Obj
		end

		-------------------------------------------------------------------
		-- Logic editor (Codebox + rule engine + status)
		-------------------------------------------------------------------
		local LogicExample = table.concat({
			"# One rule per line:",
			"#   on <Event> [arg] [if <flag|value> <op> <value>] do <Action> [args] [then <Action> ...]",
			"# Examples:",
			'#   on FlagChanged "Main/Toggle/Enabled" if value == true do Notify "Enabled!"',
			'#   on ButtonPressed "Main/Button/Reset" do SetFlag "Main/Toggle/Enabled" false',
			'#   on Tick 30 do Press "Main/Button/Refresh"',
			'#   on WindowToggled if value == false do Log "UI hidden"',
			"",
		}, "\n")

		function TabObj:LogicEditor(O)
			O = O or {}
			local Title = O.Title or "Logic"
			local Status
			local function Apply(Text)
				local Count, Errors = Library:SetLogic(Text)
				local Msg = Count .. " rule(s) active"
				if #Errors > 0 then Msg = Msg .. "  |  " .. #Errors .. " error(s): " .. table.concat(Errors, "; ") end
				if Status then Status:SetText(Msg) end
				return Count, Errors
			end
			local Code = TabObj:Codebox({
				Title = Title, Language = "Logic", Height = O.Height or 200, Default = O.Default or LogicExample,
				Flag = O.Flag or (C.TabTitle .. "/Logic/" .. Title), Callback = Apply,
			})
			Status = TabObj:Label("Rules not applied yet")
			Status.Row.Size = UDim2.new(1, 0, 0, 56)
			TabObj:Button({Title = "Apply rules", Action = "Apply", Flag = "_Logic/Apply/" .. Title, Callback = function()
				local Count, Errors = Apply(Code:GetValue())
				C.Window:Notify({Title = "Logic", Content = Count .. " rule(s) active" .. (#Errors > 0 and (", " .. #Errors .. " error(s)") or "")})
			end})
			TabObj:Button({Title = "Show reference", Action = "Show", Flag = "_Logic/Reference/" .. Title, Callback = function()
				local Events, Actions = {}, {}
				for Name in Logic.Events do table.insert(Events, Name) end
				for Name in Logic.Actions do table.insert(Actions, Name) end
				table.sort(Events); table.sort(Actions)
				C.Window:Notify({Title = "Logic reference", Content = "Events: " .. table.concat(Events, ", ") .. "\nActions: " .. table.concat(Actions, ", ") .. "\nOperators: == ~= > < >= <= contains", Duration = 14})
			end})
			Apply(Code:GetValue())
			return Code
		end
	end)

	-----------------------------------------------------------------------
	-- WINDOW EXTENSION: scale, acrylic, tilt, settings tab, presets UI
	-----------------------------------------------------------------------
	table.insert(Library.WindowExtensions, function(Window, C)
		local Janitor, MainFrame, BottomBar, ScreenGui = C.Janitor, C.MainFrame, C.BottomBar, C.ScreenGui
		local Cfg = C.ConfigTab

		local function Hook(Fn)
			table.insert(Library.SettingHooks, Fn)
			Janitor:Give(function()
				local I = table.find(Library.SettingHooks, Fn)
				if I then table.remove(Library.SettingHooks, I) end
			end)
		end

		C.SaveBtn.MouseEnter:Connect(function() Window:ShowTip("Configuration", C.SaveBtn) end)
		C.SaveBtn.MouseLeave:Connect(function() Window:HideTip() end)

		-- UI scale + acrylic transparency
		local Scale = Create("UIScale", {Scale = Settings.UIScale, Parent = MainFrame})
		local function ApplyLook()
			Scale.Scale = Settings.UIScale
			MainFrame.BackgroundTransparency = Settings.WindowTransparency
			BottomBar.BackgroundTransparency = Settings.WindowTransparency
		end
		ApplyLook()

		-- pseudo-3D tilt: a backdrop card that rotates/shifts toward the mouse + a moving light sheen.
		-- (Rotating the real window would break the slider/popup hit-testing, so the window itself stays flat.)
		local Backdrop = Create("Frame", {Name = "TiltBackdrop", AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 0.88, BorderSizePixel = 0, ZIndex = 0, Visible = false, Parent = ScreenGui})
		Corner(Backdrop, 12)
		local BackdropStroke = Create("UIStroke", {Color = Theme.Accent, Transparency = 0.6, Thickness = 1, Parent = Backdrop})
		C.Themed(Backdrop, {BackgroundColor3 = "Accent"})
		C.Themed(BackdropStroke, {Color = "Accent"})
		local Glare = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 500, Visible = false, Parent = MainFrame})
		Corner(Glare, 8)
		local GlareGradient = Create("UIGradient", {Rotation = 20, Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.93), NumberSequenceKeypoint.new(1, 1)}), Parent = Glare})

		local TX, TY, TiltConn = 0, 0, nil
		local function StopTilt()
			if TiltConn then TiltConn:Disconnect(); TiltConn = nil end
			Backdrop.Visible = false
			Glare.Visible = false
		end
		local function StartTilt()
			if TiltConn then return end
			Backdrop.Visible = true
			Glare.Visible = true
			TiltConn = RunService.RenderStepped:Connect(function(Dt)
				if not Window.Visible then return end
				local M = UserInputService:GetMouseLocation()
				local P, S = MainFrame.AbsolutePosition, MainFrame.AbsoluteSize
				local Cx, Cy = P.X + S.X / 2, P.Y + S.Y / 2
				local Nx = math.clamp((M.X - Cx) / math.max(S.X / 2, 1), -1, 1)
				local Ny = math.clamp((M.Y - Cy) / math.max(S.Y / 2, 1), -1, 1)
				local A = 1 - math.exp(-Settings.TiltSmoothness * Dt)
				TX += (Nx - TX) * A
				TY += (Ny - TY) * A
				local Str = Settings.TiltStrength
				local Shift = Settings.TiltParallax and Str * 3 or 0
				Backdrop.Rotation = TX * Str * 0.6
				Backdrop.Position = UDim2.fromOffset(Cx - TX * Shift, Cy - TY * Shift)
				Backdrop.Size = UDim2.fromOffset(S.X + 14 + math.abs(TX) * Str * 2, S.Y + 14 + math.abs(TY) * Str * 2)
				GlareGradient.Offset = Vector2.new(TX * 0.6, TY * 0.3)
			end)
		end
		local function ApplyTilt()
			if Settings.Tilt and Settings.Performance ~= "Low" then StartTilt() else StopTilt() end
		end
		Janitor:Give(StopTilt)
		ApplyTilt()

		-- react to setting changes
		Hook(function(Key)
			if Key == "UIScale" or Key == "WindowTransparency" or Key == "Performance" then ApplyLook() end
			if string.sub(Key, 1, 4) == "Tilt" or Key == "Performance" then ApplyTilt() end
			if Key == "Blur" or Key == "BlurSize" or string.sub(Key, 1, 3) == "DOF" or Key == "Performance" then Library:UpdateEffects() end
		end)

		-- visibility: effects + logic event
		local OriginalSetVisible = Window.SetVisible
		function Window:SetVisible(State)
			local Before = self.Visible
			OriginalSetVisible(self, State)
			if Before ~= self.Visible then
				Library:UpdateEffects()
				Library:FireEvent("WindowToggled", self.Visible)
			end
		end
		Janitor:Give(function() task.defer(function() Library:UpdateEffects() end) end)
		Library:UpdateEffects()

		-------------------------------------------------------------------
		-- Theme presets / import / export / syntax colors (Configuration tab)
		-------------------------------------------------------------------
		Cfg:Section("Theme presets")
		local PresetDrop = Cfg:Dropdown({Title = "Preset", Options = Library:ListPresets(), Default = "Midnight", Flag = "_Preset/Selected", Callback = function(V)
			if V then Library:ApplyPreset(V) end
		end})
		local PresetName = Cfg:Textbox({Title = "Save current as", Default = "", Placeholder = "preset name", Flag = "_Preset/Name"})
		Cfg:Button({Title = "Save preset", Action = "Save", Flag = "_Preset/Save", Callback = function()
			local Ok, Err = Library:SavePreset(PresetName:GetValue())
			Window:Notify({Title = "Presets", Content = Ok and "Preset saved." or ("Could not save: " .. tostring(Err))})
			PresetDrop:SetOptions(Library:ListPresets())
		end})
		Cfg:Button({Title = "Export theme", Action = "Copy", Flag = "_Preset/Export", Callback = function()
			local Json = Library:ExportTheme()
			if typeof(setclipboard) == "function" then
				setclipboard(Json)
				Window:Notify({Title = "Presets", Content = "Theme JSON copied to clipboard."})
			else
				print(Json)
				Window:Notify({Title = "Presets", Content = "No clipboard API - theme JSON printed to output."})
			end
		end})
		local ImportBox = Cfg:Textbox({Title = "Import theme (JSON)", Default = "", Placeholder = "paste JSON", Flag = "_Preset/Import"})
		Cfg:Button({Title = "Import theme", Action = "Import", Flag = "_Preset/ImportBtn", Callback = function()
			local Ok, Err = Library:ImportTheme(ImportBox:GetValue())
			Window:Notify({Title = "Presets", Content = Ok and "Theme imported." or ("Import failed: " .. tostring(Err))})
			PresetDrop:SetOptions(Library:ListPresets())
		end})

		Cfg:Section("Syntax colors")
		for _, Key in SyntaxKeys do
			Cfg:Colorpicker({Title = "Syntax " .. Key, Default = Library.Syntax[Key], Flag = "Syntax/" .. Key, Callback = function(Col)
				Library.Syntax[Key] = Col
				Library:SetTheme({})
			end})
		end

		-------------------------------------------------------------------
		-- System tabs (Logic + Settings), created after the user's own tabs
		-------------------------------------------------------------------
		local Added = false
		function Window:AddSystemTabs()
			if Added then return end
			Added = true

			local LogicTab = Window:Tab({Title = "Logic", Icon = Icons.Placeholder})
			LogicTab:Section("Logic editor")
			LogicTab:LogicEditor({Title = "Rules", Height = 220})

			local Tab = Window:Tab({Title = "Settings", Icon = Icons.Placeholder})
			local UI = {}
			Hook(function(Key, Value)
				local Comp = UI[Key]
				if Comp and Comp:GetValue() ~= Value then Comp:SetValue(Value, true) end
			end)

			local function SettingSlider(Key, Title, Min, Max, Decimal, Suffix)
				UI[Key] = Tab:Slider({Title = Title, Min = Min, Max = Max, Decimal = Decimal, Suffix = Suffix or "", Default = Settings[Key], Flag = "Settings/" .. Key, Callback = function(V) Library:SetSetting(Key, V) end})
			end
			local function SettingToggle(Key, Title)
				UI[Key] = Tab:Toggle({Title = Title, Default = Settings[Key], Flag = "Settings/" .. Key, Callback = function(V) Library:SetSetting(Key, V) end})
			end

			Tab:Section("Performance")
			UI.Performance = Tab:Dropdown({Title = "Performance mode", Options = {"High", "Balanced", "Low"}, Default = Settings.Performance, Flag = "Settings/Performance", Callback = function(V) Library:SetPerformance(V) end})
			SettingSlider("AnimSpeed", "Animation speed (0 = instant)", 0, 3, 1, "x")
			SettingSlider("HighlightMaxLength", "Max highlighted code length", 1000, 60000, 0)
			SettingSlider("PollInterval", "Logic poll interval", 0.05, 1, 2, "s")

			Tab:Section("Appearance")
			SettingSlider("UIScale", "UI scale", 0.6, 1.4, 2, "x")
			SettingSlider("CornerScale", "Corner roundness", 0, 2, 2, "x")
			SettingSlider("WindowTransparency", "Window transparency (acrylic)", 0, 0.8, 2)
			Tab:Dropdown({Title = "Font", Options = {"GothamMedium", "Gotham", "GothamBold", "SourceSans", "Ubuntu", "Arimo", "Roboto", "Nunito", "Montserrat", "Code"}, Default = Theme.Font.Name, Flag = "Settings/Font", Callback = function(V)
				local Ok, F = pcall(function() return Enum.Font[V] end)
				if Ok and typeof(F) == "EnumItem" then Library:SetTheme({Font = F}) end
			end})
			Tab:Slider({Title = "Window width", Min = 560, Max = 1400, Default = MainFrame.Size.X.Offset, Flag = "Settings/WindowWidth", Callback = function(V)
				MainFrame.Size = UDim2.fromOffset(V, MainFrame.Size.Y.Offset)
			end})
			Tab:Slider({Title = "Window height", Min = 380, Max = 900, Default = MainFrame.Size.Y.Offset, Flag = "Settings/WindowHeight", Callback = function(V)
				MainFrame.Size = UDim2.fromOffset(MainFrame.Size.X.Offset, V)
			end})
			UI.ToggleKey = Tab:Keybind({Title = "Toggle UI key", Default = Library.ToggleKey, Flag = "Settings/ToggleKey", OnChanged = function(Key)
				if Key then
					Library.ToggleKey = Key
				else
					Window:Notify({Title = "Settings", Content = "A toggle key is required so you can reopen the UI."})
					UI.ToggleKey:SetValue(Library.ToggleKey, true)
				end
			end})

			Tab:Section("Acrylic blur and depth of field")
			SettingToggle("Blur", "Background blur")
			SettingSlider("BlurSize", "Blur size", 0, 56, 0)
			SettingToggle("DOF", "Depth of field")
			SettingSlider("DOFFocusDistance", "Focus distance", 0, 200, 0)
			SettingSlider("DOFInFocusRadius", "In-focus radius", 0, 200, 0)
			SettingSlider("DOFFarIntensity", "Far intensity", 0, 1, 2)
			SettingSlider("DOFNearIntensity", "Near intensity", 0, 1, 2)

			Tab:Section("3D tilt")
			SettingToggle("Tilt", "Enable tilt")
			SettingSlider("TiltStrength", "Tilt strength", 0, 10, 1, "deg")
			SettingSlider("TiltSmoothness", "Smoothness", 1, 30, 0)
			SettingToggle("TiltParallax", "Parallax shift")

			Tab:Section("Security")
			SettingToggle("SafeCallbacks", "Protect against callback errors")
			SettingSlider("LogicMaxPerSecond", "Logic rule rate limit (per second)", 1, 100, 0)
			SettingToggle("AllowRemote", "Allow verified remote loading (allow-listed hosts + SHA-256)")
		end

		if not (C.Options and C.Options.SystemTabs == false) then
			task.defer(function() Window:AddSystemTabs() end)
		end
	end)
end


return Library

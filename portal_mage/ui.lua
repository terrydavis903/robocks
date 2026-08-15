-- portal_mage/ui.lua — multi-tab ScreenGui (Bot / Waypoints / Claw / Config)
return function(S)
	local CoreGui = S.Services.CoreGui
	local UserInputService = S.Services.UserInputService
	local M = {}

	local function parentGui(gui: ScreenGui)
		pcall(function()
			if syn and syn.protect_gui then
				syn.protect_gui(gui)
			end
		end)
		local ok = pcall(function()
			if gethui then
				gui.Parent = gethui()
			else
				error("no gethui")
			end
		end)
		if not ok then
			gui.Parent = CoreGui
		end
	end

	local function corner(inst: Instance, r: number?)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, r or 6)
		c.Parent = inst
		return c
	end

	local function mkButton(parent: Instance, text: string, y: number, color: Color3, h: number?): TextButton
		local btn = Instance.new("TextButton")
		btn.Name = text:gsub("%s+", ""):sub(1, 48)
		btn.Size = UDim2.new(1, -16, 0, h or 30)
		btn.Position = UDim2.fromOffset(8, y)
		btn.BackgroundColor3 = color
		btn.BorderSizePixel = 0
		btn.Font = Enum.Font.GothamMedium
		btn.TextSize = 13
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.Text = text
		btn.AutoButtonColor = true
		btn.Parent = parent
		corner(btn)
		return btn
	end

	local function mkSmall(parent: Instance, text: string, x: number, y: number, w: number, color: Color3): TextButton
		local btn = Instance.new("TextButton")
		btn.Name = text:gsub("%s+", ""):sub(1, 40)
		btn.Size = UDim2.fromOffset(w, 28)
		btn.Position = UDim2.fromOffset(x, y)
		btn.BackgroundColor3 = color
		btn.BorderSizePixel = 0
		btn.Font = Enum.Font.GothamMedium
		btn.TextSize = 12
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.Text = text
		btn.AutoButtonColor = true
		btn.Parent = parent
		corner(btn)
		return btn
	end

	local function mkBox(parent: Instance, y: number, placeholder: string): TextBox
		local box = Instance.new("TextBox")
		box.Size = UDim2.new(1, -16, 0, 28)
		box.Position = UDim2.fromOffset(8, y)
		box.BackgroundColor3 = Color3.fromRGB(32, 32, 40)
		box.BorderSizePixel = 0
		box.Font = Enum.Font.Gotham
		box.TextSize = 13
		box.TextColor3 = Color3.new(1, 1, 1)
		box.PlaceholderText = placeholder
		box.PlaceholderColor3 = Color3.fromRGB(100, 100, 115)
		box.Text = ""
		box.ClearTextOnFocus = false
		box.Parent = parent
		corner(box)
		return box
	end

	local function mkLabel(parent: Instance, text: string, y: number): TextLabel
		local lab = Instance.new("TextLabel")
		lab.Size = UDim2.new(1, -16, 0, 18)
		lab.Position = UDim2.fromOffset(8, y)
		lab.BackgroundTransparency = 1
		lab.Font = Enum.Font.GothamBold
		lab.TextSize = 12
		lab.TextColor3 = Color3.fromRGB(180, 180, 200)
		lab.TextXAlignment = Enum.TextXAlignment.Left
		lab.Text = text
		lab.Parent = parent
		return lab
	end

	-- Shared dropdown pattern for waypoints
	local function buildPicker(
		parent: Instance,
		y0: number,
		opts: {
			getList: () -> { any },
			getSelectedId: () -> string?,
			setSelected: (string) -> (),
			getSelectedName: () -> string?,
			onSelect: ((any) -> ())?,
		}
	)
		local y = y0
		local nameBox = mkBox(parent, y, "Name…")
		y += 32

		local saveBtn = mkSmall(parent, "Save", 8, y, 82, Color3.fromRGB(50, 110, 150))
		local renameBtn = mkSmall(parent, "Rename", 94, y, 82, Color3.fromRGB(90, 90, 140))
		local delBtn = mkSmall(parent, "Delete", 180, y, 84, Color3.fromRGB(120, 55, 55))
		y += 34

		local dropBtn = Instance.new("TextButton")
		dropBtn.Size = UDim2.new(1, -16, 0, 30)
		dropBtn.Position = UDim2.fromOffset(8, y)
		dropBtn.BackgroundColor3 = Color3.fromRGB(36, 36, 48)
		dropBtn.BorderSizePixel = 0
		dropBtn.Font = Enum.Font.Gotham
		dropBtn.TextSize = 12
		dropBtn.TextColor3 = Color3.new(1, 1, 1)
		dropBtn.TextXAlignment = Enum.TextXAlignment.Left
		dropBtn.Text = "  (none)"
		dropBtn.Parent = parent
		corner(dropBtn)
		local arrow = Instance.new("TextLabel")
		arrow.Size = UDim2.fromOffset(20, 30)
		arrow.Position = UDim2.new(1, -24, 0, 0)
		arrow.BackgroundTransparency = 1
		arrow.Font = Enum.Font.GothamBold
		arrow.TextSize = 12
		arrow.TextColor3 = Color3.fromRGB(160, 160, 180)
		arrow.Text = "▾"
		arrow.Parent = dropBtn
		y += 34

		local listFrame = Instance.new("ScrollingFrame")
		listFrame.Size = UDim2.new(1, -16, 0, 140)
		listFrame.Position = UDim2.fromOffset(8, y)
		listFrame.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
		listFrame.BorderSizePixel = 0
		listFrame.ScrollBarThickness = 4
		listFrame.Visible = false
		listFrame.ZIndex = 30
		listFrame.CanvasSize = UDim2.fromOffset(0, 0)
		listFrame.Parent = parent
		corner(listFrame)
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 2)
		layout.Parent = listFrame
		y += 146

		local function refreshDisplay()
			local nm = opts.getSelectedName()
			if nm then
				dropBtn.Text = "  " .. nm
				if UserInputService:GetFocusedTextBox() ~= nameBox then
					nameBox.Text = nm
				end
			else
				dropBtn.Text = "  (none)"
			end
		end

		local function rebuildList()
			for _, child in ipairs(listFrame:GetChildren()) do
				if child:IsA("TextButton") then
					child:Destroy()
				end
			end
			local list = opts.getList()
			local sel = opts.getSelectedId()
			for i, item in ipairs(list) do
				local row = Instance.new("TextButton")
				row.Size = UDim2.new(1, -6, 0, 26)
				row.BackgroundColor3 = if item.id == sel
					then Color3.fromRGB(55, 70, 100)
					else Color3.fromRGB(38, 38, 50)
				row.BorderSizePixel = 0
				row.Font = Enum.Font.Gotham
				row.TextSize = 12
				row.TextColor3 = Color3.new(1, 1, 1)
				row.TextXAlignment = Enum.TextXAlignment.Left
				row.Text = "  " .. (item.name or item.id)
				row.LayoutOrder = i
				row.ZIndex = 31
				row.Parent = listFrame
				corner(row, 4)
				row.MouseButton1Click:Connect(function()
					opts.setSelected(item.id)
					nameBox.Text = item.name or ""
					listFrame.Visible = false
					refreshDisplay()
					rebuildList()
					if opts.onSelect then
						opts.onSelect(item)
					end
				end)
			end
			listFrame.CanvasSize = UDim2.fromOffset(0, math.max(0, #list * 28))
			refreshDisplay()
		end

		dropBtn.MouseButton1Click:Connect(function()
			listFrame.Visible = not listFrame.Visible
			if listFrame.Visible then
				rebuildList()
			end
		end)

		return {
			y = y,
			nameBox = nameBox,
			saveBtn = saveBtn,
			renameBtn = renameBtn,
			delBtn = delBtn,
			dropBtn = dropBtn,
			listFrame = listFrame,
			refresh = rebuildList,
			getName = function()
				return nameBox.Text
			end,
			setName = function(t: string)
				nameBox.Text = t
			end,
		}
	end

	function M.build()
		pcall(function()
			local host = gethui and gethui() or CoreGui
			local old = host:FindFirstChild("PortalMageUI")
			if old then
				old:Destroy()
			end
		end)

		local gui = Instance.new("ScreenGui")
		gui.Name = "PortalMageUI"
		gui.ResetOnSpawn = false
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.DisplayOrder = 100000
		gui.IgnoreGuiInset = true
		gui.Enabled = true
		pcall(function()
			(gui :: any).ClipToDeviceSafeArea = false
		end)
		-- Never modal — modal ScreenGuis can trap/sink mouse input
		pcall(function()
			(gui :: any).Modal = false
		end)
		parentGui(gui)

		local PANEL_W, PANEL_H = 500, 740
		local frame = Instance.new("Frame")
		frame.Name = "Panel"
		frame.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
		frame.Position = UDim2.new(0, 20, 0.5, -PANEL_H / 2)
		frame.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
		frame.BorderSizePixel = 0
		frame.Active = true
		frame.Selectable = false
		frame.Draggable = true
		frame.ZIndex = 10
		frame.Parent = gui
		corner(frame, 10)

		-- Cursor drawn INSIDE this ScreenGui (max ZIndex) so it paints on top of the
		-- panel. Game custom cursors live in lower DisplayOrder GUIs and otherwise
		-- render *under* our modal. We do NOT change MouseBehavior / lock state.
		local RunService = game:GetService("RunService")
		local hudCursor = Instance.new("ImageLabel")
		hudCursor.Name = "HudCursor"
		hudCursor.BackgroundTransparency = 1
		hudCursor.Size = UDim2.fromOffset(32, 32)
		hudCursor.AnchorPoint = Vector2.new(0, 0)
		hudCursor.Image = "rbxasset://textures/Cursors/KeyboardMouse/ArrowFarCursor.png"
		hudCursor.ZIndex = 100000
		hudCursor.Visible = false
		hudCursor.Active = false -- never block clicks
		hudCursor.Parent = gui

		local function mouseOverPanel(): boolean
			if not frame.Visible or not gui.Enabled then
				return false
			end
			local m = UserInputService:GetMouseLocation()
			local p = frame.AbsolutePosition
			local s = frame.AbsoluteSize
			return m.X >= p.X and m.X <= p.X + s.X and m.Y >= p.Y and m.Y <= p.Y + s.Y
		end

		local hudCursorConn: RBXScriptConnection? = nil
		local function startHudCursorLayer()
			if hudCursorConn then
				return
			end
			hudCursorConn = RunService.RenderStepped:Connect(function()
				if not gui.Parent or not frame.Visible or not gui.Enabled then
					hudCursor.Visible = false
					return
				end
				local m = UserInputService:GetMouseLocation()
				-- IgnoreGuiInset: GetMouseLocation is screen-space from top-left
				hudCursor.Position = UDim2.fromOffset(m.X, m.Y)
				local over = mouseOverPanel()
				hudCursor.Visible = over
				-- Hide the under-drawing game/system icon while over panel so only
				-- the on-top HUD cursor shows (no double cursor).
				if over then
					pcall(function()
						UserInputService.MouseIconEnabled = false
					end)
				end
			end)
		end
		local function stopHudCursorLayer()
			if hudCursorConn then
				hudCursorConn:Disconnect()
				hudCursorConn = nil
			end
			hudCursor.Visible = false
			pcall(function()
				UserInputService.MouseIconEnabled = true
			end)
		end
		startHudCursorLayer()
		frame:GetPropertyChangedSignal("Visible"):Connect(function()
			if frame.Visible then
				startHudCursorLayer()
			else
				stopHudCursorLayer()
			end
		end)
		gui.Destroying:Connect(function()
			stopHudCursorLayer()
		end)

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(70, 70, 90)
		stroke.Thickness = 1
		stroke.Parent = frame

		local title = Instance.new("TextLabel")
		title.Size = UDim2.new(1, -16, 0, 24)
		title.Position = UDim2.fromOffset(8, 6)
		title.BackgroundTransparency = 1
		title.Font = Enum.Font.GothamBold
		title.TextSize = 15
		title.TextColor3 = Color3.fromRGB(230, 230, 240)
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Text = "Portal Mage"
		title.Parent = frame

		-- Tab bar (4 tabs — slightly thinner so they fit without widening the panel)
		local tabBarY = 32
		local tabNames = { "Bot", "Waypoints", "Claw", "Config" }
		local tabs: { [string]: Frame } = {}
		local tabBtns: { [string]: TextButton } = {}
		local activeTab = "Bot"

		local contentTop = 60
		local contentH = PANEL_H - contentTop - 48

		local function showTab(name: string)
			activeTab = name
			for n, f in pairs(tabs) do
				f.Visible = (n == name)
			end
			for n, b in pairs(tabBtns) do
				if n == name then
					b.BackgroundColor3 = Color3.fromRGB(60, 70, 110)
				else
					b.BackgroundColor3 = Color3.fromRGB(36, 36, 46)
				end
			end
			if name == "Config" and S.ui.refreshClawConfig then
				pcall(S.ui.refreshClawConfig)
			end
		end

		for i, name in ipairs(tabNames) do
			local tw = (PANEL_W - 16) / #tabNames
			local b = Instance.new("TextButton")
			b.Size = UDim2.fromOffset(math.floor(tw - 2), 22)
			b.Position = UDim2.fromOffset(8 + math.floor((i - 1) * tw), tabBarY)
			b.BackgroundColor3 = Color3.fromRGB(36, 36, 46)
			b.BorderSizePixel = 0
			b.Font = Enum.Font.GothamMedium
			b.TextSize = 11
			b.TextColor3 = Color3.new(1, 1, 1)
			b.Text = name
			b.Parent = frame
			corner(b, 4)
			tabBtns[name] = b
			b.MouseButton1Click:Connect(function()
				showTab(name)
			end)

			local page = Instance.new("Frame")
			page.Name = "Tab_" .. name
			page.Size = UDim2.new(1, 0, 0, contentH)
			page.Position = UDim2.fromOffset(0, contentTop)
			page.BackgroundTransparency = 1
			page.Visible = false
			page.Parent = frame
			tabs[name] = page
		end

		local status = Instance.new("TextLabel")
		status.Size = UDim2.new(1, -16, 0, 40)
		status.Position = UDim2.new(0, 8, 1, -46)
		status.BackgroundTransparency = 1
		status.Font = Enum.Font.Gotham
		status.TextSize = 11
		status.TextColor3 = Color3.fromRGB(160, 160, 175)
		status.TextXAlignment = Enum.TextXAlignment.Left
		status.TextYAlignment = Enum.TextYAlignment.Top
		status.TextWrapped = true
		status.Text = "Ready"
		status.Parent = frame

		S.ui.setStatus = function(text: string)
			status.Text = text
		end

		-- Shared Kill Aura toggle buttons (stay in sync if multiple)
		local killAuraButtons: { TextButton } = {}
		local function applyKillAuraLabel(on: boolean)
			for _, btn in ipairs(killAuraButtons) do
				btn.Text = on and "Kill Aura: ON (click stop)" or "Kill Aura: OFF"
				btn.BackgroundColor3 = on and Color3.fromRGB(160, 70, 90) or Color3.fromRGB(70, 70, 80)
			end
		end
		S.ui.setWalkLabel = applyKillAuraLabel
		S.ui.setKillAuraLabel = applyKillAuraLabel
		S.ui.registerWalkToggle = function(btn: TextButton, _opts: any?)
			table.insert(killAuraButtons, btn)
			applyKillAuraLabel(S.walking)
			btn.MouseButton1Click:Connect(function()
				S.Pathing.toggleWalk()
			end)
		end

		---------------------------------------------------------------------------
		-- Bot tab
		---------------------------------------------------------------------------
		local bot = tabs.Bot
		local by = 4
		local dumpBtn = mkButton(bot, "Dump World", by, Color3.fromRGB(50, 120, 70))
		by += 34
		local dumpMeshBtn = mkButton(bot, "Dump Mesh (walls/floor)", by, Color3.fromRGB(30, 100, 110))
		by += 34
		local meshOutlineBtn = mkButton(bot, "Outline Mesh: OFF", by, Color3.fromRGB(70, 70, 80))
		by += 34
		local pathVizBtn = mkButton(bot, "Path Viz (A*): OFF", by, Color3.fromRGB(70, 70, 80))
		by += 34
		local pathRecBtn = mkButton(bot, "A* Rec: OFF", by, Color3.fromRGB(70, 70, 80))
		by += 34
		local dumpGuiBtn = mkButton(bot, "Dump GUI", by, Color3.fromRGB(40, 130, 90))
		by += 34
		local stopBtn = mkButton(bot, "Stop All", by, Color3.fromRGB(140, 50, 50))
		by += 34
		local killAuraBtn = mkButton(bot, "Kill Aura: OFF", by, Color3.fromRGB(70, 70, 80))
		by += 34
		local proxBtn = mkButton(bot, "Prox Guard: ON", by, Color3.fromRGB(160, 70, 50))
		by += 34
		local antiAfkBtn = mkButton(bot, "Anti-AFK Jump: OFF", by, Color3.fromRGB(70, 70, 80))
		by += 34
		local oreEspBtn = mkButton(bot, "Ore ESP: OFF", by, Color3.fromRGB(70, 70, 80))
		by += 34
		local playerEspBtn = mkButton(bot, "Player ESP: OFF", by, Color3.fromRGB(70, 70, 80))
		by += 34
		local enemyEspBtn = mkButton(bot, "Enemy ESP: OFF", by, Color3.fromRGB(70, 70, 80))
		by += 34
		local autoOreBtn = mkButton(bot, "Auto Ore: OFF", by, Color3.fromRGB(70, 70, 80))
		by += 34

		S.ui.setProxLabel = function(on: boolean)
			proxBtn.Text = on and "Prox Guard: ON" or "Prox Guard: OFF"
			proxBtn.BackgroundColor3 = on and Color3.fromRGB(160, 70, 50) or Color3.fromRGB(70, 70, 80)
		end
		S.ui.setAntiAfkLabel = function(on: boolean)
			antiAfkBtn.Text = on and "Anti-AFK Jump: ON" or "Anti-AFK Jump: OFF"
			antiAfkBtn.BackgroundColor3 = on and Color3.fromRGB(90, 140, 80) or Color3.fromRGB(70, 70, 80)
		end
		S.ui.setOreEspLabel = function(on: boolean)
			oreEspBtn.Text = on and "Ore ESP: ON" or "Ore ESP: OFF"
			-- dark orange when on (matches aurorite ore color, not cyan)
			oreEspBtn.BackgroundColor3 = on and Color3.fromRGB(180, 100, 35) or Color3.fromRGB(70, 70, 80)
		end
		S.ui.setPlayerEspLabel = function(on: boolean)
			playerEspBtn.Text = on and "Player ESP: ON" or "Player ESP: OFF"
			playerEspBtn.BackgroundColor3 = on and Color3.fromRGB(40, 170, 200) or Color3.fromRGB(70, 70, 80)
		end
		S.ui.setEnemyEspLabel = function(on: boolean)
			enemyEspBtn.Text = on and "Enemy ESP: ON" or "Enemy ESP: OFF"
			enemyEspBtn.BackgroundColor3 = on and Color3.fromRGB(180, 45, 45) or Color3.fromRGB(70, 70, 80)
		end
		S.ui.setAutoOreLabel = function(on: boolean)
			autoOreBtn.Text = on and "Auto Ore: ON" or "Auto Ore: OFF"
			autoOreBtn.BackgroundColor3 = on and Color3.fromRGB(180, 120, 40) or Color3.fromRGB(70, 70, 80)
		end
		S.ui.setMeshOutlineLabel = function(on: boolean)
			meshOutlineBtn.Text = on and "Outline Mesh: ON" or "Outline Mesh: OFF"
			meshOutlineBtn.BackgroundColor3 = on and Color3.fromRGB(40, 140, 160) or Color3.fromRGB(70, 70, 80)
		end
		S.ui.setPathVizLabel = function(on: boolean)
			pathVizBtn.Text = on and "Path Viz (A*): ON" or "Path Viz (A*): OFF"
			pathVizBtn.BackgroundColor3 = on and Color3.fromRGB(40, 120, 180) or Color3.fromRGB(70, 70, 80)
		end
		S.ui.setPathRecLabel = function(on: boolean)
			pathRecBtn.Text = on and "A* Rec: ON" or "A* Rec: OFF"
			pathRecBtn.BackgroundColor3 = on and Color3.fromRGB(50, 160, 90) or Color3.fromRGB(70, 70, 80)
		end
		-- WalkSpeed force removed — never write Humanoid.WalkSpeed
		S.ui.setWalkSpeedLabel = function(_on: boolean, _speed: number?) end

		dumpBtn.MouseButton1Click:Connect(function()
			task.spawn(S.Dump.dumpWorld)
		end)
		dumpMeshBtn.MouseButton1Click:Connect(function()
			if S.Dump and S.Dump.dumpWorldMesh then
				task.spawn(S.Dump.dumpWorldMesh)
			else
				S.Util.setStatus("Mesh dump not available — reload script")
			end
		end)
		meshOutlineBtn.MouseButton1Click:Connect(function()
			if S.MeshOutline and S.MeshOutline.toggleMeshOutline then
				S.MeshOutline.toggleMeshOutline()
			else
				S.Util.setStatus("Outline Mesh not loaded — reload script")
			end
		end)
		pathVizBtn.MouseButton1Click:Connect(function()
			if S.Pathing and S.Pathing.togglePathViz then
				S.Pathing.togglePathViz()
			elseif S.Nav and S.Nav.togglePathViz then
				S.Nav.togglePathViz()
			else
				S.Util.setStatus("Path Viz not loaded — reload script")
			end
		end)
		pathRecBtn.MouseButton1Click:Connect(function()
			if S.PathRecord and S.PathRecord.toggle then
				-- If auto-ore is running, pause it so human walk is clean
				if not S.pathRecEnabled and S.autoOreEnabled and S.AutoOre and S.AutoOre.stop then
					S.AutoOre.stop()
					S.Util.setStatus("Auto Ore paused for A* Rec — walk the route, toggle OFF to save")
				end
				S.PathRecord.toggle()
			else
				S.Util.setStatus("Path recorder not loaded — reload script")
			end
		end)
		dumpGuiBtn.MouseButton1Click:Connect(function()
			task.spawn(S.Dump.dumpGuiOnly)
		end)
		stopBtn.MouseButton1Click:Connect(function()
			-- Bot-only stop (kill aura / combat / auto ore). Claw is separate — use Claw tab Cancel.
			S.proximityResumeWalk = false
			S.respawnResumeWalk = false
			if S.AutoOre and S.AutoOre.stop then
				S.AutoOre.stop()
			end
			S.Combat.stopAll()
			S.ui.setWalkLabel(false)
			if S.ui.setAutoOreLabel then
				S.ui.setAutoOreLabel(false)
			end
			S.Util.setStatus("Stopped kill aura/combat/auto-ore (claw unaffected)")
		end)
		S.ui.registerWalkToggle(killAuraBtn, nil)
		proxBtn.MouseButton1Click:Connect(function()
			if S.Proximity then
				S.Proximity.toggleGuard()
			end
		end)
		antiAfkBtn.MouseButton1Click:Connect(function()
			if S.Util and S.Util.toggleAntiAfk then
				S.Util.toggleAntiAfk()
			end
		end)
		oreEspBtn.MouseButton1Click:Connect(function()
			if S.Ore and S.Ore.toggleOreEsp then
				S.Ore.toggleOreEsp()
			else
				S.Util.setStatus("Ore module not loaded")
			end
		end)
		playerEspBtn.MouseButton1Click:Connect(function()
			if S.Esp and S.Esp.togglePlayerEsp then
				S.Esp.togglePlayerEsp()
			else
				S.Util.setStatus("ESP module not loaded — reload script")
			end
		end)
		enemyEspBtn.MouseButton1Click:Connect(function()
			if S.Esp and S.Esp.toggleEnemyEsp then
				S.Esp.toggleEnemyEsp()
			else
				S.Util.setStatus("ESP module not loaded — reload script")
			end
		end)
		autoOreBtn.MouseButton1Click:Connect(function()
			if S.AutoOre and S.AutoOre.toggle then
				S.AutoOre.toggle()
			else
				S.Util.setStatus("Auto Ore module not loaded — reload script")
			end
		end)

		---------------------------------------------------------------------------
		-- Waypoints tab
		---------------------------------------------------------------------------
		local wpPage = tabs.Waypoints
		mkLabel(wpPage, "Saved positions (teleport)", 4)
		local wpPicker = buildPicker(wpPage, 24, {
			getList = function()
				return S.Waypoints and S.Waypoints.list() or {}
			end,
			getSelectedId = function()
				return S.selectedWaypointId
			end,
			setSelected = function(id)
				if S.Waypoints then
					S.Waypoints.setSelected(id)
				end
			end,
			getSelectedName = function()
				local wp = S.Waypoints and S.Waypoints.getSelected()
				return wp and wp.name or nil
			end,
			onSelect = function(item)
				S.Util.setStatus("Selected waypoint: " .. (item.name or "?"))
			end,
		})
		local recallBtn = mkButton(wpPage, "Recall (teleport)", wpPicker.y, Color3.fromRGB(70, 100, 160))

		-- Live players
		local py = wpPicker.y + 36
		mkLabel(wpPage, "Teleport to player", py)
		py += 20

		local playerDrop = Instance.new("TextButton")
		playerDrop.Name = "PlayerDropdown"
		playerDrop.Size = UDim2.new(1, -16, 0, 30)
		playerDrop.Position = UDim2.fromOffset(8, py)
		playerDrop.BackgroundColor3 = Color3.fromRGB(36, 36, 48)
		playerDrop.BorderSizePixel = 0
		playerDrop.Font = Enum.Font.Gotham
		playerDrop.TextSize = 12
		playerDrop.TextColor3 = Color3.new(1, 1, 1)
		playerDrop.TextXAlignment = Enum.TextXAlignment.Left
		playerDrop.Text = "  (scan for players)"
		playerDrop.Parent = wpPage
		corner(playerDrop)
		local playerArrow = Instance.new("TextLabel")
		playerArrow.Size = UDim2.fromOffset(20, 30)
		playerArrow.Position = UDim2.new(1, -24, 0, 0)
		playerArrow.BackgroundTransparency = 1
		playerArrow.Font = Enum.Font.GothamBold
		playerArrow.TextSize = 12
		playerArrow.TextColor3 = Color3.fromRGB(160, 160, 180)
		playerArrow.Text = "▾"
		playerArrow.Parent = playerDrop
		py += 34

		local playerList = Instance.new("ScrollingFrame")
		playerList.Name = "PlayerList"
		playerList.Size = UDim2.new(1, -16, 0, 120)
		playerList.Position = UDim2.fromOffset(8, py)
		playerList.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
		playerList.BorderSizePixel = 0
		playerList.ScrollBarThickness = 4
		playerList.Visible = false
		playerList.ZIndex = 35
		playerList.CanvasSize = UDim2.fromOffset(0, 0)
		playerList.Parent = wpPage
		corner(playerList)
		local playerLayout = Instance.new("UIListLayout")
		playerLayout.SortOrder = Enum.SortOrder.LayoutOrder
		playerLayout.Padding = UDim.new(0, 2)
		playerLayout.Parent = playerList

		local selectedPlayerName: string? = nil
		local lastPlayerScan: { any } = {}

		local function refreshPlayerDrop()
			if selectedPlayerName then
				playerDrop.Text = "  " .. selectedPlayerName
			else
				playerDrop.Text = "  (scan for players)"
			end
		end

		local function rebuildPlayerList()
			for _, child in ipairs(playerList:GetChildren()) do
				if child:IsA("TextButton") then
					child:Destroy()
				end
			end
			lastPlayerScan = S.Waypoints and S.Waypoints.scanPlayers() or {}
			for i, pl in ipairs(lastPlayerScan) do
				local row = Instance.new("TextButton")
				row.Size = UDim2.new(1, -6, 0, 26)
				row.BackgroundColor3 = if pl.name == selectedPlayerName
					then Color3.fromRGB(55, 70, 100)
					else Color3.fromRGB(38, 38, 50)
				row.BorderSizePixel = 0
				row.Font = Enum.Font.Gotham
				row.TextSize = 12
				row.TextColor3 = Color3.new(1, 1, 1)
				row.TextXAlignment = Enum.TextXAlignment.Left
				local posStr = if pl.x
					then string.format("  %s  (%.0f, %.0f, %.0f)", pl.name, pl.x, pl.y, pl.z)
					else string.format("  %s  (no pos)", pl.name)
				row.Text = posStr
				row.LayoutOrder = i
				row.ZIndex = 36
				row.Parent = playerList
				corner(row, 4)
				row.MouseButton1Click:Connect(function()
					selectedPlayerName = pl.name
					playerList.Visible = false
					refreshPlayerDrop()
					S.Util.setStatus("Selected player: " .. pl.name)
				end)
			end
			playerList.CanvasSize = UDim2.fromOffset(0, math.max(0, #lastPlayerScan * 28))
			if #lastPlayerScan == 0 then
				playerDrop.Text = "  (no other players)"
				selectedPlayerName = nil
			elseif selectedPlayerName then
				-- keep selection if still present
				local still = false
				for _, pl in ipairs(lastPlayerScan) do
					if pl.name == selectedPlayerName then
						still = true
						break
					end
				end
				if not still then
					selectedPlayerName = nil
					refreshPlayerDrop()
				else
					refreshPlayerDrop()
				end
			else
				refreshPlayerDrop()
			end
			S.Util.setStatus(string.format("Player scan: %d other player(s)", #lastPlayerScan))
		end

		local scanBtn = mkSmall(wpPage, "Scan", 8, py + 126, 90, Color3.fromRGB(70, 90, 120))
		local tpPlayerBtn = mkSmall(wpPage, "TP to player", 104, py + 126, 200, Color3.fromRGB(70, 100, 160))

		playerDrop.MouseButton1Click:Connect(function()
			-- Always rescan when opening
			rebuildPlayerList()
			playerList.Visible = not playerList.Visible
		end)
		scanBtn.MouseButton1Click:Connect(function()
			playerList.Visible = true
			rebuildPlayerList()
		end)
		tpPlayerBtn.MouseButton1Click:Connect(function()
			if S.Waypoints then
				playerList.Visible = false
				wpPicker.listFrame.Visible = false
				S.Waypoints.teleportToPlayer(selectedPlayerName)
			end
		end)

		wpPicker.saveBtn.MouseButton1Click:Connect(function()
			if S.Waypoints then
				S.Waypoints.mark(wpPicker.getName())
				wpPicker.refresh()
			end
		end)
		wpPicker.renameBtn.MouseButton1Click:Connect(function()
			if not S.Waypoints then
				return
			end
			local wp = S.Waypoints.getSelected()
			if not wp then
				S.Util.setStatus("Rename: select a waypoint first")
				return
			end
			S.Waypoints.rename(wp.id, wpPicker.getName())
			wpPicker.refresh()
		end)
		wpPicker.delBtn.MouseButton1Click:Connect(function()
			if S.Waypoints then
				S.Waypoints.delete(S.selectedWaypointId)
				wpPicker.setName("")
				wpPicker.refresh()
			end
		end)
		recallBtn.MouseButton1Click:Connect(function()
			if S.Waypoints then
				wpPicker.listFrame.Visible = false
				playerList.Visible = false
				S.Waypoints.recall(S.selectedWaypointId)
			end
		end)
		S.ui.refreshWaypoints = function()
			wpPicker.refresh()
		end

		---------------------------------------------------------------------------
		-- Claw tab (one-shot prize grab)
		---------------------------------------------------------------------------
		local clawPage = tabs.Claw
		mkLabel(clawPage, "Claw (separate map module)", 4)
		local clawInfo = Instance.new("TextLabel")
		clawInfo.Size = UDim2.new(1, -16, 0, 100)
		clawInfo.Position = UDim2.fromOffset(8, 24)
		clawInfo.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
		clawInfo.BorderSizePixel = 0
		clawInfo.Font = Enum.Font.Gotham
		clawInfo.TextSize = 11
		clawInfo.TextColor3 = Color3.fromRGB(180, 180, 195)
		clawInfo.TextXAlignment = Enum.TextXAlignment.Left
		clawInfo.TextYAlignment = Enum.TextYAlignment.Top
		clawInfo.TextWrapped = true
		clawInfo.Text = "Isolated from walk/combat/prox (safe map).\n"
			.. "Prize priority: Config tab (10 tiers). Empty tiers = others.\n"
			.. "W=+Z S=-Z A=+X D=-X → Space drop\n"
			.. "Cyan=claw. Pyramids=all. Amber rod=reachable best. Green rod=global best (no walls)."
		clawInfo.Parent = clawPage
		corner(clawInfo, 6)
		local clawPad = Instance.new("UIPadding")
		clawPad.PaddingTop = UDim.new(0, 6)
		clawPad.PaddingLeft = UDim.new(0, 8)
		clawPad.PaddingRight = UDim.new(0, 8)
		clawPad.Parent = clawInfo

		local clawY = 130
		local clawStartBtn = mkButton(clawPage, "Start (scan → aim → drop)", clawY, Color3.fromRGB(50, 130, 90))
		clawY += 34
		local clawCancelBtn = mkButton(clawPage, "Cancel", clawY, Color3.fromRGB(140, 55, 55))
		clawY += 34
		local clawScanBtn = mkButton(clawPage, "Scan prizes only", clawY, Color3.fromRGB(70, 90, 130))
		clawY += 34
		local clawBeamBtn = mkButton(clawPage, "Claw Beam: OFF", clawY, Color3.fromRGB(70, 70, 80))
		clawY += 34
		local clawPrizeBeamsBtn = mkButton(clawPage, "Prize Beams: OFF", clawY, Color3.fromRGB(70, 70, 80))
		clawY += 34
		local clawBestPrizeBtn = mkButton(clawPage, "Best Prize Only: OFF", clawY, Color3.fromRGB(70, 70, 80))
		clawY += 34
		local clawDumpBtn = mkButton(clawPage, "Dump claw / prizes", clawY, Color3.fromRGB(90, 80, 130))
		clawY += 38

		local clawStateLab = Instance.new("TextLabel")
		clawStateLab.Size = UDim2.new(1, -16, 0, 20)
		clawStateLab.Position = UDim2.fromOffset(8, clawY)
		clawStateLab.BackgroundTransparency = 1
		clawStateLab.Font = Enum.Font.GothamBold
		clawStateLab.TextSize = 12
		clawStateLab.TextColor3 = Color3.fromRGB(160, 170, 190)
		clawStateLab.TextXAlignment = Enum.TextXAlignment.Left
		clawStateLab.Text = "State: idle"
		clawStateLab.Parent = clawPage
		clawY += 22

		mkLabel(clawPage, "Run log (also dumps/claw_run_*.log)", clawY)
		clawY += 18
		local clawLogBox = Instance.new("TextLabel")
		clawLogBox.Name = "ClawLog"
		clawLogBox.Size = UDim2.new(1, -16, 0, 90)
		clawLogBox.Position = UDim2.fromOffset(8, clawY)
		clawLogBox.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
		clawLogBox.BorderSizePixel = 0
		clawLogBox.Font = Enum.Font.Code
		clawLogBox.TextSize = 10
		clawLogBox.TextColor3 = Color3.fromRGB(170, 200, 170)
		clawLogBox.TextXAlignment = Enum.TextXAlignment.Left
		clawLogBox.TextYAlignment = Enum.TextYAlignment.Top
		clawLogBox.TextWrapped = true
		clawLogBox.Text = "(no claw logs yet)"
		clawLogBox.Parent = clawPage
		corner(clawLogBox, 6)
		local clawLogPad = Instance.new("UIPadding")
		clawLogPad.PaddingTop = UDim.new(0, 4)
		clawLogPad.PaddingLeft = UDim.new(0, 6)
		clawLogPad.PaddingRight = UDim.new(0, 6)
		clawLogPad.Parent = clawLogBox

		S.ui.setClawBeamLabel = function(on: boolean)
			clawBeamBtn.Text = on and "Claw Beam: ON" or "Claw Beam: OFF"
			clawBeamBtn.BackgroundColor3 = on and Color3.fromRGB(0, 180, 170) or Color3.fromRGB(70, 70, 80)
		end
		S.ui.setClawPrizeBeamsLabel = function(on: boolean)
			clawPrizeBeamsBtn.Text = on and "Prize Beams: ON" or "Prize Beams: OFF"
			clawPrizeBeamsBtn.BackgroundColor3 = on and Color3.fromRGB(200, 120, 40) or Color3.fromRGB(70, 70, 80)
		end
		S.ui.setClawBestPrizeLabel = function(on: boolean)
			clawBestPrizeBtn.Text = on and "Best Prize Only: ON" or "Best Prize Only: OFF"
			clawBestPrizeBtn.BackgroundColor3 = on and Color3.fromRGB(180, 100, 160) or Color3.fromRGB(70, 70, 80)
		end
		S.ui.setClawRunLabel = function(text: string)
			clawStateLab.Text = "State: " .. tostring(text)
			if text == "running" then
				clawStartBtn.Text = "Running… (one-shot)"
				clawStartBtn.BackgroundColor3 = Color3.fromRGB(160, 120, 40)
			else
				clawStartBtn.Text = "Start (scan → aim → drop)"
				clawStartBtn.BackgroundColor3 = Color3.fromRGB(50, 130, 90)
			end
		end
		S.ui.setClawLog = function(text: string)
			clawLogBox.Text = text
		end

		clawStartBtn.MouseButton1Click:Connect(function()
			if S.Claw then
				S.Claw.startSequence()
			else
				S.Util.setStatus("Claw module not loaded")
			end
		end)
		clawCancelBtn.MouseButton1Click:Connect(function()
			if S.Claw then
				S.Claw.cancelSequence("Claw: cancelled by user")
			end
		end)
		clawScanBtn.MouseButton1Click:Connect(function()
			task.spawn(function()
				if not S.Claw then
					S.Util.setStatus("Claw module not loaded")
					return
				end
				if S.Claw.log then
					S.Claw.log("PHASE", "manual scan + lock best (one-shot)…", false)
				end
				-- One-shot scan + lock (same path as Best Prize / Start)
				local best, tag = S.Claw.lockBestPrizeFromScan({ requireReachable = true })
				local prizes = S.Claw.scanPrizes()
				local okR, badR = 0, 0
				if S.Claw.countReachable then
					okR, badR = S.Claw.countReachable(prizes)
				end
				local bounds = S.Claw.formatReachBounds and S.Claw.formatReachBounds() or "?"
				if not best then
					local msg = string.format(
						"scan: %d prizes, 0 in machine (outside walls=%d) box=%s | %s",
						#prizes,
						badR,
						bounds,
						tostring(tag)
					)
					if S.Claw.log then
						S.Claw.log("WARN", msg)
					else
						S.Util.setStatus("Claw " .. msg)
					end
					return
				end
				if S.clawPrizeBeamsBestOnly or S.clawPrizeBeamsEnabled then
					pcall(function()
						S.Claw.ensurePrizeBeams()
					end)
				end
				local thr = S.Config.CLAW_ALIGN_THRESHOLD or 0.5
				local d = best.distXZ or -1
				local msg = string.format(
					"scan+lock: %d prizes reach=%d wall=%d | %s dXZ=%.3f thr=%.3f box=%s",
					#prizes,
					okR,
					badR,
					tag,
					d,
					thr,
					bounds
				)
				if S.Claw.log then
					S.Claw.log("INFO", msg)
				else
					S.Util.setStatus("Claw " .. msg)
				end
			end)
		end)
		clawBeamBtn.MouseButton1Click:Connect(function()
			if S.Claw then
				S.Claw.toggle()
			else
				S.Util.setStatus("Claw module not loaded")
			end
		end)
		clawPrizeBeamsBtn.MouseButton1Click:Connect(function()
			if S.Claw then
				S.Claw.togglePrizeBeams()
			else
				S.Util.setStatus("Claw module not loaded")
			end
		end)
		clawBestPrizeBtn.MouseButton1Click:Connect(function()
			if S.Claw then
				S.Claw.toggleBestPrizeOnly()
			else
				S.Util.setStatus("Claw module not loaded")
			end
		end)
		clawDumpBtn.MouseButton1Click:Connect(function()
			task.spawn(function()
				if S.Claw then
					if S.Claw.log then
						S.Claw.log("INFO", "manual dump claw…", false)
					end
					S.Claw.reportStatus()
					S.Claw.dumpClaw()
				else
					S.Util.setStatus("Claw module not loaded")
				end
			end)
		end)

		---------------------------------------------------------------------------
		-- Config tab (claw prize priority tiers)
		---------------------------------------------------------------------------
		local configPage = tabs.Config
		local TIER_COUNT = (S.ClawPriority and S.ClawPriority.TIER_COUNT) or 10
		-- All pixel sizes (no scale). Large hit targets so hover matches the box.
		local CFG_ROW_H = 36
		local CFG_HDR_H = 38
		local CFG_BTN = 34
		local CFG_GAP = 6
		local CFG_PAD = 10

		local cfgHint = Instance.new("TextLabel")
		cfgHint.Size = UDim2.new(1, -16, 0, 44)
		cfgHint.Position = UDim2.fromOffset(8, 4)
		cfgHint.BackgroundTransparency = 1
		cfgHint.Font = Enum.Font.Gotham
		cfgHint.TextSize = 15
		cfgHint.TextColor3 = Color3.fromRGB(150, 155, 175)
		cfgHint.TextXAlignment = Enum.TextXAlignment.Left
		cfgHint.TextYAlignment = Enum.TextYAlignment.Top
		cfgHint.TextWrapped = true
		cfgHint.Text = "Claw priority — lower tier first. + adds a keyword. Empty tiers = others (unlisted prizes)."
		cfgHint.Parent = configPage

		local othersLab = Instance.new("TextLabel")
		othersLab.Size = UDim2.new(1, -16, 0, 20)
		othersLab.Position = UDim2.fromOffset(8, 48)
		othersLab.BackgroundTransparency = 1
		othersLab.Font = Enum.Font.GothamBold
		othersLab.TextSize = 15
		othersLab.TextColor3 = Color3.fromRGB(200, 170, 100)
		othersLab.TextXAlignment = Enum.TextXAlignment.Left
		othersLab.Text = "Others → T?"
		othersLab.Parent = configPage

		local cfgScroll = Instance.new("ScrollingFrame")
		cfgScroll.Name = "ClawPriorityScroll"
		cfgScroll.Size = UDim2.new(1, -12, 1, -76)
		cfgScroll.Position = UDim2.fromOffset(6, 72)
		cfgScroll.BackgroundColor3 = Color3.fromRGB(26, 26, 34)
		cfgScroll.BorderSizePixel = 0
		cfgScroll.ScrollBarThickness = 6
		cfgScroll.ScrollBarImageColor3 = Color3.fromRGB(90, 90, 120)
		cfgScroll.ScrollingDirection = Enum.ScrollingDirection.Y
		cfgScroll.CanvasSize = UDim2.fromOffset(0, 0)
		cfgScroll.Parent = configPage
		corner(cfgScroll, 6)

		local cfgList = Instance.new("Frame")
		cfgList.Name = "TierList"
		cfgList.BackgroundTransparency = 1
		cfgList.BorderSizePixel = 0
		cfgList.Position = UDim2.fromOffset(0, 0)
		cfgList.Size = UDim2.fromOffset(100, 0)
		cfgList.Parent = cfgScroll

		-- Working copy: tier -> { keyword, ... }
		local tierKeywords: { [number]: { string } } = {}
		local openAddTier: number? = nil

		local function normalizeKey(s: string): string
			return (string.lower(s):gsub("[^%w]", ""))
		end

		local function keywordsFromTiers(): { { key: string, tier: number } }
			local list = {}
			for t = 1, TIER_COUNT do
				for _, key in ipairs(tierKeywords[t] or {}) do
					table.insert(list, { key = key, tier = t })
				end
			end
			return list
		end

		local function loadTiersFromConfig()
			for t = 1, TIER_COUNT do
				tierKeywords[t] = {}
			end
			local list = (S.ClawPriority and S.ClawPriority.getKeywords and S.ClawPriority.getKeywords())
				or (S.Config.CLAW_PRIORITY_KEYWORDS or {})
			for _, e in ipairs(list) do
				local t = tonumber(e.tier)
				local key = type(e.key) == "string" and normalizeKey(e.key) or ""
				if key ~= "" and t and t >= 1 and t <= TIER_COUNT then
					table.insert(tierKeywords[t], key)
				end
			end
			for t = 1, TIER_COUNT do
				table.sort(tierKeywords[t])
			end
		end

		local function updateOthersLabel()
			local list = keywordsFromTiers()
			local ot = 11
			if S.ClawPriority and S.ClawPriority.othersTier then
				ot = S.ClawPriority.othersTier(list)
			else
				local used = {}
				for _, e in ipairs(list) do
					used[e.tier] = true
				end
				for t = 1, TIER_COUNT do
					if not used[t] then
						ot = t
						break
					end
				end
			end
			othersLab.Text = string.format("Others (unlisted) → T%d", ot)
		end

		local function persistTiers()
			local list = keywordsFromTiers()
			if S.ClawPriority and S.ClawPriority.save then
				local ok, info = S.ClawPriority.save(list)
				if ok then
					S.Util.setStatus(string.format("Claw priority saved (%d keywords)", #list))
				else
					S.Util.setStatus("Claw priority save failed: " .. tostring(info))
				end
			else
				S.Config.CLAW_PRIORITY_KEYWORDS = list
				S.Util.setStatus("Claw priority applied (no disk save API)")
			end
			updateOthersLabel()
		end

		local function listInnerWidth(): number
			local w = cfgScroll.AbsoluteSize.X - cfgScroll.ScrollBarThickness - 4
			if w < 120 then
				w = math.max(PANEL_W - 40, 120)
			end
			return math.floor(w)
		end

		local rebuildTierUi: () -> ()

		local function addKeywordToTier(tier: number, raw: string)
			local key = normalizeKey(raw)
			if key == "" then
				return
			end
			for t = 1, TIER_COUNT do
				local arr = tierKeywords[t]
				for i = #arr, 1, -1 do
					if arr[i] == key then
						table.remove(arr, i)
					end
				end
			end
			table.insert(tierKeywords[tier], key)
			table.sort(tierKeywords[tier])
			openAddTier = nil
			persistTiers()
			rebuildTierUi()
		end

		local function removeKeyword(tier: number, key: string)
			local arr = tierKeywords[tier]
			if not arr then
				return
			end
			for i = #arr, 1, -1 do
				if arr[i] == key then
					table.remove(arr, i)
				end
			end
			persistTiers()
			rebuildTierUi()
		end

		-- Absolute left/top pixel placement only (no UDim scale / AnchorPoint right tricks)
		local function mkCfgBtn(parent: Instance, x: number, y: number, size: number, text: string, color: Color3): TextButton
			local btn = Instance.new("TextButton")
			btn.Size = UDim2.fromOffset(size, size)
			btn.Position = UDim2.fromOffset(x, y)
			btn.BackgroundColor3 = color
			btn.BorderSizePixel = 0
			btn.Font = Enum.Font.GothamBold
			btn.TextSize = math.floor(size * 0.55)
			btn.TextColor3 = Color3.new(1, 1, 1)
			btn.Text = text
			btn.AutoButtonColor = true
			btn.Active = true
			btn.Selectable = false
			btn.ZIndex = 5
			btn.Parent = parent
			corner(btn, 6)
			return btn
		end

		rebuildTierUi = function()
			for _, child in ipairs(cfgList:GetChildren()) do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end

			local width = listInnerWidth()
			local y = CFG_PAD

			for t = 1, TIER_COUNT do
				local keys = tierKeywords[t] or {}
				local showAdd = openAddTier == t
				local innerH = CFG_HDR_H
					+ (showAdd and (CFG_ROW_H + CFG_GAP) or 0)
					+ #keys * (CFG_ROW_H + CFG_GAP)
					+ CFG_PAD
				local blockH = innerH + CFG_PAD

				local block = Instance.new("Frame")
				block.Name = "Tier" .. t
				block.Size = UDim2.fromOffset(width - CFG_PAD * 2, blockH)
				block.Position = UDim2.fromOffset(CFG_PAD, y)
				block.BackgroundColor3 = Color3.fromRGB(32, 32, 42)
				block.BorderSizePixel = 0
				block.ClipsDescendants = false
				block.Parent = cfgList
				corner(block, 6)

				local innerW = width - CFG_PAD * 4
				local rowY = CFG_PAD
				local btnX = innerW - CFG_BTN

				-- Header
				local header = Instance.new("Frame")
				header.Size = UDim2.fromOffset(innerW, CFG_HDR_H)
				header.Position = UDim2.fromOffset(CFG_PAD, rowY)
				header.BackgroundTransparency = 1
				header.ClipsDescendants = false
				header.Parent = block

				local titleLab = Instance.new("TextLabel")
				titleLab.Size = UDim2.fromOffset(math.max(btnX - 8, 40), CFG_HDR_H)
				titleLab.Position = UDim2.fromOffset(2, 0)
				titleLab.BackgroundTransparency = 1
				titleLab.Font = Enum.Font.GothamBold
				titleLab.TextSize = 16
				titleLab.TextColor3 = Color3.fromRGB(200, 205, 230)
				titleLab.TextXAlignment = Enum.TextXAlignment.Left
				titleLab.TextYAlignment = Enum.TextYAlignment.Center
				titleLab.Active = false
				titleLab.ZIndex = 1
				local emptyMark = (#keys == 0) and "  · empty" or string.format("  (%d)", #keys)
				titleLab.Text = "Tier " .. t .. emptyMark
				titleLab.Parent = header

				local addBtn = mkCfgBtn(
					header,
					btnX,
					math.floor((CFG_HDR_H - CFG_BTN) / 2),
					CFG_BTN,
					"+",
					Color3.fromRGB(50, 110, 80)
				)
				addBtn.MouseButton1Click:Connect(function()
					if openAddTier == t then
						openAddTier = nil
					else
						openAddTier = t
					end
					rebuildTierUi()
				end)

				rowY += CFG_HDR_H + CFG_GAP

				if showAdd then
					local addRow = Instance.new("Frame")
					addRow.Size = UDim2.fromOffset(innerW, CFG_ROW_H)
					addRow.Position = UDim2.fromOffset(CFG_PAD, rowY)
					addRow.BackgroundTransparency = 1
					addRow.Parent = block

					local addW = 64
					local box = Instance.new("TextBox")
					box.Size = UDim2.fromOffset(innerW - addW - 8, CFG_ROW_H)
					box.Position = UDim2.fromOffset(0, 0)
					box.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
					box.BorderSizePixel = 0
					box.Font = Enum.Font.Gotham
					box.TextSize = 15
					box.TextColor3 = Color3.new(1, 1, 1)
					box.PlaceholderText = "keyword…"
					box.PlaceholderColor3 = Color3.fromRGB(100, 100, 120)
					box.Text = ""
					box.ClearTextOnFocus = false
					box.Parent = addRow
					corner(box, 5)

					local okBtn = Instance.new("TextButton")
					okBtn.Size = UDim2.fromOffset(addW, CFG_ROW_H)
					okBtn.Position = UDim2.fromOffset(innerW - addW, 0)
					okBtn.BackgroundColor3 = Color3.fromRGB(55, 100, 150)
					okBtn.BorderSizePixel = 0
					okBtn.Font = Enum.Font.GothamMedium
					okBtn.TextSize = 14
					okBtn.TextColor3 = Color3.new(1, 1, 1)
					okBtn.Text = "Add"
					okBtn.AutoButtonColor = true
					okBtn.ZIndex = 5
					okBtn.Parent = addRow
					corner(okBtn, 5)

					local function commit()
						addKeywordToTier(t, box.Text)
					end
					okBtn.MouseButton1Click:Connect(commit)
					box.FocusLost:Connect(function(enter)
						if enter then
							commit()
						end
					end)
					task.defer(function()
						pcall(function()
							box:CaptureFocus()
						end)
					end)

					rowY += CFG_ROW_H + CFG_GAP
				end

				for _, key in ipairs(keys) do
					local row = Instance.new("Frame")
					row.Size = UDim2.fromOffset(innerW, CFG_ROW_H)
					row.Position = UDim2.fromOffset(CFG_PAD, rowY)
					row.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
					row.BorderSizePixel = 0
					row.ClipsDescendants = false
					row.Parent = block
					corner(row, 5)

					local keyLab = Instance.new("TextLabel")
					keyLab.Size = UDim2.fromOffset(math.max(btnX - 12, 40), CFG_ROW_H)
					keyLab.Position = UDim2.fromOffset(10, 0)
					keyLab.BackgroundTransparency = 1
					keyLab.Font = Enum.Font.Code
					keyLab.TextSize = 15
					keyLab.TextColor3 = Color3.fromRGB(210, 210, 225)
					keyLab.TextXAlignment = Enum.TextXAlignment.Left
					keyLab.TextYAlignment = Enum.TextYAlignment.Center
					keyLab.Text = key
					keyLab.Active = false
					keyLab.ZIndex = 1
					keyLab.Parent = row

					local xBtn = mkCfgBtn(
						row,
						btnX,
						math.floor((CFG_ROW_H - CFG_BTN) / 2),
						CFG_BTN,
						"×",
						Color3.fromRGB(120, 50, 55)
					)
					xBtn.MouseButton1Click:Connect(function()
						removeKeyword(t, key)
					end)

					rowY += CFG_ROW_H + CFG_GAP
				end

				y += blockH + CFG_GAP + 2
			end

			cfgList.Size = UDim2.fromOffset(width, y + CFG_PAD)
			cfgScroll.CanvasSize = UDim2.fromOffset(0, y + CFG_PAD)
			updateOthersLabel()
		end

		cfgScroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if activeTab == "Config" then
				rebuildTierUi()
			end
		end)

		S.ui.refreshClawConfig = function()
			loadTiersFromConfig()
			openAddTier = nil
			rebuildTierUi()
		end

		loadTiersFromConfig()
		rebuildTierUi()

		---------------------------------------------------------------------------
		UserInputService.InputBegan:Connect(function(input, processed)
			if processed then
				return
			end
			if input.KeyCode == Enum.KeyCode.RightShift then
				frame.Visible = not frame.Visible
			end
		end)

		UserInputService.InputBegan:Connect(function(input, processed)
			if processed then
				return
			end
			if not UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
				return
			end
			if input.KeyCode == Enum.KeyCode.T then
				task.spawn(S.Dump.dumpWorld)
			elseif input.KeyCode == Enum.KeyCode.G then
				task.spawn(S.Dump.dumpGuiOnly)
			end
		end)

		showTab("Bot")
		wpPicker.refresh()
		S.Util.setStatus("Ready — Kill Aura: face→W/A/D(+Space)→stand@30→R→cast")
	end

	return M
end

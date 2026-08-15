-- portal_mage/esp.lua — Player ESP (cyan) + Enemy ESP (red)
-- Through-wall Highlights, independent toggles. Ore ESP stays in ore.lua.
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local M = {}

	local PLAYER_HL = "PortalMage_PlayerESP"
	local ENEMY_HL = "PortalMage_EnemyESP"

	local function setStatus(t: string)
		if U and U.setStatus then
			U.setStatus(t)
		end
	end

	local function refreshPlayerLabel()
		if S.ui and S.ui.setPlayerEspLabel then
			S.ui.setPlayerEspLabel(S.playerEspEnabled == true)
		end
	end

	local function refreshEnemyLabel()
		if S.ui and S.ui.setEnemyEspLabel then
			S.ui.setEnemyEspLabel(S.enemyEspEnabled == true)
		end
	end

	local function destroyNamed(inst: Instance, name: string)
		local h = inst:FindFirstChild(name)
		if h then
			h:Destroy()
		end
	end

	local function ensureHighlight(
		host: Instance,
		name: string,
		fill: Color3,
		outline: Color3,
		fillT: number?,
		outlineT: number?
	)
		local h = host:FindFirstChild(name)
		if not (h and h:IsA("Highlight")) then
			if h then
				h:Destroy()
			end
			h = Instance.new("Highlight")
			h.Name = name
			h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			h.Parent = host
		end
		local hl = h :: Highlight
		hl.Adornee = host
		hl.Enabled = true
		hl.FillColor = fill
		hl.OutlineColor = outline
		hl.FillTransparency = fillT or 0.65
		hl.OutlineTransparency = outlineT or 0.0
	end

	local function sweepName(name: string)
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == name and d:IsA("Highlight") then
				d:Destroy()
			end
		end
	end

	---------------------------------------------------------------------------
	-- Colors
	---------------------------------------------------------------------------

	local function playerColors(): (Color3, Color3)
		local cfg = C.PLAYER_ESP_COLORS
		if type(cfg) == "table" and cfg.fill and cfg.outline then
			return cfg.fill, cfg.outline
		end
		-- cyan
		return Color3.fromRGB(40, 200, 230), Color3.fromRGB(120, 240, 255)
	end

	local function enemyColors(): (Color3, Color3)
		local cfg = C.ENEMY_ESP_COLORS
		if type(cfg) == "table" and cfg.fill and cfg.outline then
			return cfg.fill, cfg.outline
		end
		-- red
		return Color3.fromRGB(220, 40, 40), Color3.fromRGB(255, 90, 90)
	end

	---------------------------------------------------------------------------
	-- Players
	---------------------------------------------------------------------------

	function M.collectOtherPlayers(): { Model }
		local out = {}
		local lp = Players.LocalPlayer
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= lp then
				local char = plr.Character
				if char and char:IsA("Model") then
					local hum = char:FindFirstChildOfClass("Humanoid")
					if hum and hum.Health > 0 then
						table.insert(out, char)
					end
				end
			end
		end
		return out
	end

	function M.clearPlayerHighlights()
		for _, char in ipairs(M.collectOtherPlayers()) do
			destroyNamed(char, PLAYER_HL)
		end
		sweepName(PLAYER_HL)
	end

	function M.refreshPlayerEsp(): number
		local live: { [Instance]: boolean } = {}
		local fill, outline = playerColors()
		local fillT = C.PLAYER_ESP_FILL_T
		if fillT == nil then
			fillT = 0.65
		end
		local outlineT = C.PLAYER_ESP_OUTLINE_T
		if outlineT == nil then
			outlineT = 0.0
		end
		local n = 0
		for _, char in ipairs(M.collectOtherPlayers()) do
			live[char] = true
			ensureHighlight(char, PLAYER_HL, fill, outline, fillT, outlineT)
			n += 1
		end
		-- drop orphans on stale characters still in workspace
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == PLAYER_HL and d:IsA("Highlight") then
				local host = d.Parent
				if host and not live[host] then
					d:Destroy()
				end
			end
		end
		return n
	end

	local function playerLoop()
		while S.playerEspEnabled do
			pcall(function()
				M.refreshPlayerEsp()
			end)
			task.wait(C.PLAYER_ESP_INTERVAL or 0.5)
		end
		S.playerEspThread = nil
	end

	function M.setPlayerEspEnabled(on: boolean)
		S.playerEspEnabled = on and true or false
		refreshPlayerLabel()
		if S.playerEspEnabled then
			local n = M.refreshPlayerEsp()
			setStatus(string.format("Player ESP ON — %d others", n))
			if not S.playerEspThread then
				S.playerEspThread = task.spawn(playerLoop)
			end
		else
			M.clearPlayerHighlights()
			setStatus("Player ESP OFF")
		end
	end

	function M.togglePlayerEsp()
		M.setPlayerEspEnabled(not S.playerEspEnabled)
	end

	---------------------------------------------------------------------------
	-- Enemies (Mobs.Active living models)
	---------------------------------------------------------------------------

	function M.collectEnemies(): { Model }
		if S.Targets and S.Targets.listActive then
			return S.Targets.listActive()
		end
		local out = {}
		local mobs = workspace:FindFirstChild("Mobs")
		local active = mobs and mobs:FindFirstChild("Active")
		if not active then
			return out
		end
		for _, child in ipairs(active:GetChildren()) do
			if child:IsA("Model") then
				local hum = child:FindFirstChildOfClass("Humanoid")
					or child:FindFirstChildWhichIsA("Humanoid", true)
				if hum and hum.Health > 0 then
					table.insert(out, child)
				end
			end
		end
		return out
	end

	function M.clearEnemyHighlights()
		for _, m in ipairs(M.collectEnemies()) do
			destroyNamed(m, ENEMY_HL)
		end
		sweepName(ENEMY_HL)
	end

	function M.refreshEnemyEsp(): number
		local live: { [Instance]: boolean } = {}
		local fill, outline = enemyColors()
		local fillT = C.ENEMY_ESP_FILL_T
		if fillT == nil then
			fillT = 0.65
		end
		local outlineT = C.ENEMY_ESP_OUTLINE_T
		if outlineT == nil then
			outlineT = 0.0
		end
		local n = 0
		for _, model in ipairs(M.collectEnemies()) do
			live[model] = true
			ensureHighlight(model, ENEMY_HL, fill, outline, fillT, outlineT)
			n += 1
		end
		local mobs = workspace:FindFirstChild("Mobs")
		local root = mobs or workspace
		for _, d in ipairs(root:GetDescendants()) do
			if d.Name == ENEMY_HL and d:IsA("Highlight") then
				local host = d.Parent
				if host and not live[host] then
					d:Destroy()
				end
			end
		end
		return n
	end

	local function enemyLoop()
		while S.enemyEspEnabled do
			pcall(function()
				M.refreshEnemyEsp()
			end)
			task.wait(C.ENEMY_ESP_INTERVAL or 0.5)
		end
		S.enemyEspThread = nil
	end

	function M.setEnemyEspEnabled(on: boolean)
		S.enemyEspEnabled = on and true or false
		refreshEnemyLabel()
		if S.enemyEspEnabled then
			local n = M.refreshEnemyEsp()
			setStatus(string.format("Enemy ESP ON — %d mobs", n))
			if not S.enemyEspThread then
				S.enemyEspThread = task.spawn(enemyLoop)
			end
		else
			M.clearEnemyHighlights()
			setStatus("Enemy ESP OFF")
		end
	end

	function M.toggleEnemyEsp()
		M.setEnemyEspEnabled(not S.enemyEspEnabled)
	end

	return M
end

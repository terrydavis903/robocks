-- portal_mage/dump.lua — world + combat + GUI dumps + full mesh export
return function(S)
	local C = S.Config
	local U = S.Util
	local HttpService = S.Services.HttpService
	local Players = S.Services.Players
	local CollectionService = S.Services.CollectionService
	local M = {}

	local function setStatus(t)
		U.setStatus(t)
	end

	local function color3Table(c: Color3)
		return { r = c.R, g = c.G, b = c.B }
	end

	-- Coarse label for nameplate analysis (red / green / white / other)
	local function classifyColor(c: Color3?): string
		if not c then
			return "unknown"
		end
		local r, g, b = c.R, c.G, c.B
		-- red: high R, clearly above G and B
		if r >= 0.55 and r > g + 0.12 and r > b + 0.12 then
			return "red"
		end
		-- green: high G
		if g >= 0.45 and g > r + 0.08 and g >= b - 0.05 then
			return "green"
		end
		-- white / near-white
		if r >= 0.85 and g >= 0.85 and b >= 0.85 then
			return "white"
		end
		-- yellow/gold (sometimes elite)
		if r >= 0.7 and g >= 0.55 and b <= 0.45 then
			return "yellow"
		end
		return "other"
	end

	local function snapGuiTextNode(inst: GuiObject)
		local entry: any = {
			name = inst.Name,
			className = inst.ClassName,
			path = inst:GetFullName(),
			visible = inst.Visible,
			backgroundColor3 = color3Table(inst.BackgroundColor3),
			backgroundTransparency = inst.BackgroundTransparency,
			zIndex = inst.ZIndex,
		}
		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			local t = inst :: TextLabel
			entry.text = t.Text
			entry.textColor3 = color3Table(t.TextColor3)
			entry.textTransparency = t.TextTransparency
			entry.textStrokeColor3 = color3Table(t.TextStrokeColor3)
			entry.textStrokeTransparency = t.TextStrokeTransparency
			entry.font = tostring(t.Font)
			entry.textColorClass = classifyColor(t.TextColor3)
			entry.strokeColorClass = classifyColor(t.TextStrokeColor3)
		end
		if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
			local img = inst :: ImageLabel
			entry.image = img.Image
			entry.imageColor3 = color3Table(img.ImageColor3)
			entry.imageTransparency = img.ImageTransparency
			entry.imageColorClass = classifyColor(img.ImageColor3)
		end
		if inst:IsA("UIStroke") then
			-- not GuiObject usually; handled separately
		end
		return entry
	end

	-- Walk OverheadHud (or any billboard under a mob) for name-tag text + colors.
	local function collectOverheadFromModel(model: Model): any
		local overhead = model:FindFirstChild("OverheadHud")
			or model:FindFirstChild("OverheadHUD")
			or model:FindFirstChild("Nameplate")
			or model:FindFirstChildWhichIsA("BillboardGui", true)

		if not overhead then
			return nil
		end

		local billboard = if overhead:IsA("BillboardGui") then overhead else overhead:FindFirstChildWhichIsA("BillboardGui")
		local root: Instance = billboard or overhead

		local nodes = {}
		local texts = {}
		local colorClasses = {}

		local function consider(inst: Instance)
			if inst:IsA("UIStroke") then
				local stroke = inst :: UIStroke
				local entry = {
					name = stroke.Name,
					className = "UIStroke",
					path = stroke:GetFullName(),
					color3 = color3Table(stroke.Color),
					transparency = stroke.Transparency,
					thickness = stroke.Thickness,
					colorClass = classifyColor(stroke.Color),
				}
				table.insert(nodes, entry)
				table.insert(colorClasses, entry.colorClass)
				return
			end
			if not inst:IsA("GuiObject") then
				return
			end
			local entry = snapGuiTextNode(inst)
			table.insert(nodes, entry)
			if entry.text and entry.text ~= "" then
				table.insert(texts, {
					name = entry.name,
					text = entry.text,
					textColor3 = entry.textColor3,
					textColorClass = entry.textColorClass,
					strokeColorClass = entry.strokeColorClass,
					visible = entry.visible,
				})
				if entry.textColorClass then
					table.insert(colorClasses, entry.textColorClass)
				end
			end
			if entry.imageColorClass then
				table.insert(colorClasses, entry.imageColorClass)
			end
		end

		consider(root)
		for _, d in ipairs(root:GetDescendants()) do
			consider(d)
		end

		-- Primary name color: prefer NameLabel (aggro is on the name, not LevelLabel)
		local primaryText, primaryClass, primaryColor = nil, nil, nil
		for _, t in ipairs(texts) do
			if t.visible ~= false and t.text and t.text ~= "" and t.name == "NameLabel" then
				primaryText = t.text
				primaryClass = t.textColorClass
				primaryColor = t.textColor3
				break
			end
		end
		if not primaryClass then
			for _, t in ipairs(texts) do
				if t.visible ~= false and t.text and t.text ~= "" then
					primaryText = t.text
					primaryClass = t.textColorClass
					primaryColor = t.textColor3
					break
				end
			end
		end
		if not primaryClass then
			for _, c in ipairs(colorClasses) do
				if c == "red" or c == "green" or c == "white" or c == "yellow" then
					primaryClass = c
					break
				end
			end
		end

		return {
			rootName = root.Name,
			rootClass = root.ClassName,
			rootPath = root:GetFullName(),
			enabled = if root:IsA("BillboardGui") then (root :: BillboardGui).Enabled else nil,
			nodeCount = #nodes,
			nodes = nodes,
			texts = texts,
			primaryText = primaryText,
			primaryColorClass = primaryClass or "unknown",
			primaryTextColor3 = primaryColor,
			colorClasses = colorClasses,
		}
	end

	local function collectEnemies()
		local enemies = {}
		local mobs = workspace:FindFirstChild("Mobs")
		local active = mobs and mobs:FindFirstChild("Active")
		if not active then
			return enemies
		end
		for _, child in ipairs(active:GetChildren()) do
			if child:IsA("Model") then
				local pos = U.getCharacterLikePosition(child)
				if pos then
					local humanoid = child:FindFirstChildOfClass("Humanoid")
					local overhead = nil
					pcall(function()
						overhead = collectOverheadFromModel(child)
					end)
					table.insert(enemies, {
						name = child.Name,
						className = child.ClassName,
						path = child:GetFullName(),
						position = U.vec3Table(pos),
						health = humanoid and humanoid.Health or nil,
						maxHealth = humanoid and humanoid.MaxHealth or nil,
						-- Nameplate / overhead (for red vs white/green analysis)
						overhead = overhead,
						nameColorClass = overhead and overhead.primaryColorClass or nil,
						nameText = overhead and overhead.primaryText or nil,
					})
				end
			end
		end
		return enemies
	end

	-- Flat list of nameplates for easy filtering (red vs green vs white)
	local function collectNameplates(enemies)
		local plates = {}
		local summary = { red = 0, green = 0, white = 0, yellow = 0, other = 0, unknown = 0, total = 0 }
		for _, e in ipairs(enemies) do
			local oh = e.overhead
			if oh then
				local cls = oh.primaryColorClass or "unknown"
				summary[cls] = (summary[cls] or 0) + 1
				summary.total += 1
				table.insert(plates, {
					enemyName = e.name,
					enemyPath = e.path,
					position = e.position,
					health = e.health,
					maxHealth = e.maxHealth,
					primaryText = oh.primaryText,
					primaryColorClass = cls,
					primaryTextColor3 = oh.primaryTextColor3,
					texts = oh.texts,
					rootPath = oh.rootPath,
				})
			end
		end
		return plates, summary
	end

	local function collectOtherPlayers()
		local others = {}
		local localPlayer = Players.LocalPlayer
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= localPlayer then
				local char = plr.Character
				local pos = char and U.getCharacterLikePosition(char)
				table.insert(others, {
					name = plr.Name,
					userId = plr.UserId,
					path = char and char:GetFullName() or nil,
					position = pos and U.vec3Table(pos) or nil,
				})
			end
		end
		return others
	end

	local function isIndicatorClass(inst: Instance): boolean
		return inst:IsA("Highlight")
			or inst:IsA("BillboardGui")
			or inst:IsA("SurfaceGui")
			or inst:IsA("Beam")
			or inst:IsA("Trail")
			or inst:IsA("ParticleEmitter")
			or inst:IsA("SelectionBox")
			or inst:IsA("SelectionSphere")
			or inst:IsA("BoxHandleAdornment")
			or inst:IsA("ConeHandleAdornment")
			or inst:IsA("SphereHandleAdornment")
			or inst:IsA("CylinderHandleAdornment")
			or inst:IsA("LineHandleAdornment")
			or inst:IsA("ImageHandleAdornment")
			or inst:IsA("WireframeHandleAdornment")
	end

	local function resolveAdorneePosition(adornee: Instance?): Vector3?
		if not adornee then
			return nil
		end
		if adornee:IsA("Model") then
			return U.getCharacterLikePosition(adornee)
		end
		return U.getInstancePosition(adornee)
	end

	local function getIndicatorPosition(inst: Instance): Vector3?
		if inst:IsA("Highlight") then
			return resolveAdorneePosition(inst.Adornee) or resolveAdorneePosition(inst.Parent)
		end
		if inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") then
			return resolveAdorneePosition(inst.Adornee) or resolveAdorneePosition(inst.Parent)
		end
		if inst:IsA("Beam") then
			local a0, a1 = inst.Attachment0, inst.Attachment1
			if a0 and a1 then
				return (a0.WorldPosition + a1.WorldPosition) * 0.5
			end
			if a0 then
				return a0.WorldPosition
			end
			if a1 then
				return a1.WorldPosition
			end
			return resolveAdorneePosition(inst.Parent)
		end
		if inst:IsA("Trail") then
			local a0, a1 = inst.Attachment0, inst.Attachment1
			if a0 and a1 then
				return (a0.WorldPosition + a1.WorldPosition) * 0.5
			end
			if a0 then
				return a0.WorldPosition
			end
			return resolveAdorneePosition(inst.Parent)
		end
		if inst:IsA("ParticleEmitter") then
			return resolveAdorneePosition(inst.Parent)
		end
		if inst:IsA("HandleAdornment") or inst:IsA("SelectionBox") or inst:IsA("SelectionSphere") then
			local adornee = (inst :: any).Adornee
			return resolveAdorneePosition(adornee) or resolveAdorneePosition(inst.Parent)
		end
		return U.getInstancePosition(inst) or resolveAdorneePosition(inst.Parent)
	end

	local function collectIndicators()
		local indicators = {}
		local function push(inst: Instance)
			if not isIndicatorClass(inst) then
				return
			end
			local ok, entry = pcall(function()
				local pos = getIndicatorPosition(inst)
				local adornee = nil
				pcall(function()
					local a = (inst :: any).Adornee
					if typeof(a) == "Instance" then
						adornee = a:GetFullName()
					end
				end)
				local enabled = nil
				pcall(function()
					if (inst :: any).Enabled ~= nil then
						enabled = (inst :: any).Enabled
					end
				end)
				local extra: any = {}
				if inst:IsA("Beam") then
					local beam = inst :: Beam
					local t0, t1 = nil, nil
					pcall(function()
						local kp = beam.Transparency.Keypoints
						if #kp >= 1 then
							t0 = kp[1].Value
						end
						if #kp >= 2 then
							t1 = kp[#kp].Value
						end
					end)
					pcall(function()
						if (beam :: any).Transparency0 ~= nil then
							t0 = (beam :: any).Transparency0
						end
						if (beam :: any).Transparency1 ~= nil then
							t1 = (beam :: any).Transparency1
						end
					end)
					extra.transparency0 = t0
					extra.transparency1 = t1
					extra.width0 = beam.Width0
					extra.width1 = beam.Width1
					extra.hasAttachment0 = beam.Attachment0 ~= nil
					extra.hasAttachment1 = beam.Attachment1 ~= nil
					extra.attachment0 = beam.Attachment0 and beam.Attachment0:GetFullName() or nil
					extra.attachment1 = beam.Attachment1 and beam.Attachment1:GetFullName() or nil
					-- Player-visible heuristic (Enabled alone is not enough)
					local visible = true
					local reason = nil
					if not beam.Enabled then
						visible = false
						reason = "Enabled=false"
					elseif not beam.Attachment0 or not beam.Attachment1 then
						visible = false
						reason = "missing attachments"
					elseif (t0 or 0) >= 0.99 and (t1 or 0) >= 0.99 then
						visible = false
						reason = "full transparency"
					elseif (beam.Width0 or 0) <= 0.001 and (beam.Width1 or 0) <= 0.001 then
						visible = false
						reason = "zero width"
					end
					extra.playerVisible = visible
					extra.invisibleReason = reason
				end
				return {
					name = inst.Name,
					className = inst.ClassName,
					path = inst:GetFullName(),
					position = pos and U.vec3Table(pos) or nil,
					adornee = adornee,
					parent = inst.Parent and inst.Parent:GetFullName() or nil,
					enabled = enabled,
					beam = if next(extra) then extra else nil,
				}
			end)
			if ok and entry then
				table.insert(indicators, entry)
			end
		end
		for _, inst in ipairs(workspace:GetDescendants()) do
			push(inst)
		end
		pcall(function()
			local cam = workspace.CurrentCamera
			if cam then
				for _, inst in ipairs(cam:GetDescendants()) do
					push(inst)
				end
			end
		end)
		local lp = Players.LocalPlayer
		if lp then
			pcall(function()
				for _, inst in ipairs(lp:GetDescendants()) do
					push(inst)
				end
			end)
		end
		return indicators
	end

	local function guiRect(gui: GuiObject)
		return {
			x = gui.AbsolutePosition.X,
			y = gui.AbsolutePosition.Y,
			w = gui.AbsoluteSize.X,
			h = gui.AbsoluteSize.Y,
		}
	end

	local function safeGuiText(inst: Instance): string?
		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			return inst.Text
		end
		return nil
	end

	local function nameLooksLikeBar(nameL: string, pathL: string): boolean
		local hay = nameL .. " " .. pathL
		return string.find(hay, "health", 1, true) ~= nil
			or string.find(hay, "mana", 1, true) ~= nil
			or string.find(hay, "energy", 1, true) ~= nil
			or string.find(hay, "stamina", 1, true) ~= nil
			or string.find(hay, "hp", 1, true) ~= nil
			or string.find(hay, "mp", 1, true) ~= nil
			or string.find(hay, "bar", 1, true) ~= nil
			or string.find(hay, "fill", 1, true) ~= nil
			or string.find(hay, "meter", 1, true) ~= nil
			or string.find(hay, "progress", 1, true) ~= nil
			or string.find(hay, "gauge", 1, true) ~= nil
	end

	local function tagGuiMatch(nameL: string, pathL: string, text: string?): { string }
		local tags = {}
		local hay = nameL .. " " .. pathL .. " " .. string.lower(text or "")
		if string.find(hay, "respawn", 1, true) then
			table.insert(tags, "respawn")
		end
		if string.find(hay, "health", 1, true) or string.find(hay, "hp", 1, true) then
			table.insert(tags, "health")
		end
		if string.find(hay, "mana", 1, true) or string.find(hay, "mp", 1, true) then
			table.insert(tags, "mana")
		end
		if string.find(hay, "energy", 1, true) then
			table.insert(tags, "energy")
		end
		if string.find(hay, "bar", 1, true) or string.find(hay, "fill", 1, true) then
			table.insert(tags, "bar")
		end
		if string.find(hay, "timer", 1, true)
			or string.find(hay, "cooldown", 1, true)
			or string.find(hay, "countdown", 1, true)
		then
			table.insert(tags, "timer")
		end
		return tags
	end

	local function isMmSsText(text: string?): boolean
		if not text then
			return false
		end
		return string.match(text, "^%s*%d%d:%d%d%s*$") ~= nil
	end

	local function isUnderPortalHud(path: string): boolean
		return string.find(path, "ThePortalUI.HUD", 1, true) ~= nil
	end

	local function collectGuiDump()
		local buttons, bars, labels, roots = {}, {}, {}, {}
		local lp = Players.LocalPlayer
		if lp then
			local pg = lp:FindFirstChildOfClass("PlayerGui") or lp:FindFirstChild("PlayerGui")
			if pg then
				table.insert(roots, pg)
			end
		end
		pcall(function()
			table.insert(roots, game:GetService("CoreGui"))
		end)

		for _, root in ipairs(roots) do
			local okDesc, descs = pcall(function()
				return root:GetDescendants()
			end)
			if not okDesc or type(descs) ~= "table" then
				continue
			end
			for _, inst in ipairs(descs) do
				pcall(function()
					if not inst:IsA("GuiObject") then
						return
					end
					local nameL = string.lower(inst.Name)
					local path = inst:GetFullName()
					local pathL = string.lower(path)
					local text = safeGuiText(inst)
					local tags = tagGuiMatch(nameL, pathL, text)
					if isMmSsText(text) then
						table.insert(tags, "timer")
					end
					local visible = inst.Visible
					local shown = visible
					local p = inst.Parent
					while p and p ~= root do
						if p:IsA("GuiObject") and not p.Visible then
							shown = false
							break
						end
						if p:IsA("LayerCollector") and p:IsA("ScreenGui") and not (p :: ScreenGui).Enabled then
							shown = false
							break
						end
						p = p.Parent
					end
					local base = {
						name = inst.Name,
						className = inst.ClassName,
						path = path,
						visible = visible,
						shown = shown,
						text = text,
						rect = guiRect(inst),
						backgroundColor3 = color3Table(inst.BackgroundColor3),
						backgroundTransparency = inst.BackgroundTransparency,
						zIndex = inst.ZIndex,
						tags = tags,
						root = root.Name,
					}
					if inst:IsA("GuiButton") then
						base.active = (inst :: GuiButton).Active
						base.autoButtonColor = (inst :: GuiButton).AutoButtonColor
						table.insert(buttons, base)
					elseif nameLooksLikeBar(nameL, pathL) then
						local parent = inst.Parent
						local fillRatioX, fillRatioY = nil, nil
						if parent and parent:IsA("GuiObject") then
							local pw, ph = parent.AbsoluteSize.X, parent.AbsoluteSize.Y
							if pw > 0 then
								fillRatioX = inst.AbsoluteSize.X / pw
							end
							if ph > 0 then
								fillRatioY = inst.AbsoluteSize.Y / ph
							end
						end
						base.fillRatioX = fillRatioX
						base.fillRatioY = fillRatioY
						if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
							base.image = (inst :: ImageLabel).Image
						end
						table.insert(bars, base)
					elseif inst:IsA("TextLabel")
						and (
							isMmSsText(text)
							or isUnderPortalHud(path)
							or (
								text
								and (
									string.find(string.lower(text), "respawn", 1, true)
									or string.find(string.lower(text), "health", 1, true)
									or string.find(string.lower(text), "mana", 1, true)
								)
							)
							or #tags > 0
						)
					then
						table.insert(labels, base)
					end
				end)
			end
		end

		local vitals: any = { health = nil, maxHealth = nil, values = {} }
		if lp then
			local char = lp.Character
			if char then
				local hum = char:FindFirstChildOfClass("Humanoid")
				if hum then
					vitals.health = hum.Health
					vitals.maxHealth = hum.MaxHealth
				end
			end
		end

		local respawnButtons = {}
		for _, b in ipairs(buttons) do
			local t = string.lower(b.text or "")
			local tagged = false
			for _, tag in ipairs(b.tags or {}) do
				if tag == "respawn" then
					tagged = true
					break
				end
			end
			if tagged or string.find(t, "respawn", 1, true) then
				table.insert(respawnButtons, b)
			end
		end

		local healthBars, manaBars = {}, {}
		for _, b in ipairs(bars) do
			local hasHealth, hasMana = false, false
			for _, tag in ipairs(b.tags or {}) do
				if tag == "health" then
					hasHealth = true
				end
				if tag == "mana" or tag == "energy" then
					hasMana = true
				end
			end
			if hasHealth then
				table.insert(healthBars, b)
			end
			if hasMana then
				table.insert(manaBars, b)
			end
		end

		local timers = {}
		local function collectTimers(list)
			for _, b in ipairs(list) do
				if isMmSsText(b.text) then
					table.insert(timers, b)
				end
			end
		end
		collectTimers(labels)
		collectTimers(bars)
		collectTimers(buttons)

		-- Full QuickSlot subtree (includes ImageLabels for the yellow diamond indicator)
		local quickSlots = {}
		if lp then
			local pg = lp:FindFirstChildOfClass("PlayerGui") or lp:FindFirstChild("PlayerGui")
			local ui = pg and pg:FindFirstChild("ThePortalUI")
			local hud = ui and ui:FindFirstChild("HUD")
			local container = hud and hud:FindFirstChild("QuickSlotContainer")
			if container then
				for _, slotFrame in ipairs(container:GetChildren()) do
					if string.find(slotFrame.Name, "QuickSlot", 1, true) == 1 then
						local nodes = {}
						local function snapGui(inst: Instance)
							if not inst:IsA("GuiObject") then
								return
							end
							local entry: any = {
								name = inst.Name,
								className = inst.ClassName,
								path = inst:GetFullName(),
								visible = inst.Visible,
								backgroundColor3 = color3Table(inst.BackgroundColor3),
								backgroundTransparency = inst.BackgroundTransparency,
								zIndex = inst.ZIndex,
								rect = guiRect(inst),
								text = safeGuiText(inst),
							}
							if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
								local img = inst :: ImageLabel
								entry.image = img.Image
								entry.imageColor3 = color3Table(img.ImageColor3)
								entry.imageTransparency = img.ImageTransparency
							end
							table.insert(nodes, entry)
						end
						snapGui(slotFrame)
						for _, d in ipairs(slotFrame:GetDescendants()) do
							snapGui(d)
						end
						-- Also siblings that sit above this slot (diamond often not nested)
						local slotPos = if slotFrame:IsA("GuiObject") then slotFrame.AbsolutePosition else Vector2.zero
						local slotSize = if slotFrame:IsA("GuiObject") then slotFrame.AbsoluteSize else Vector2.zero
						local near = {}
						for _, sib in ipairs(container:GetChildren()) do
							if sib ~= slotFrame and sib:IsA("GuiObject") then
								local cx = sib.AbsolutePosition.X + sib.AbsoluteSize.X * 0.5
								local cy = sib.AbsolutePosition.Y + sib.AbsoluteSize.Y * 0.5
								if cx >= slotPos.X - 8
									and cx <= slotPos.X + slotSize.X + 8
									and cy >= slotPos.Y - 48
									and cy <= slotPos.Y + 20
								then
									snapGui(sib)
									for _, d in ipairs(sib:GetDescendants()) do
										snapGui(d)
									end
									table.insert(near, sib.Name)
								end
							end
						end
						table.insert(quickSlots, {
							name = slotFrame.Name,
							nodeCount = #nodes,
							nearSiblingNames = near,
							nodes = nodes,
						})
					end
				end
			end
		end

		return {
			buttonCount = #buttons,
			barCount = #bars,
			labelCount = #labels,
			timerCount = #timers,
			buttons = buttons,
			bars = bars,
			labels = labels,
			timers = timers,
			respawnButtons = respawnButtons,
			healthBars = healthBars,
			manaBars = manaBars,
			vitals = vitals,
			quickSlots = quickSlots,
		}
	end

	---------------------------------------------------------------------------
	-- Non-combat world assets (ores, farms, NPCs, pickups, map structure, …)
	---------------------------------------------------------------------------

	local function instancePosition(inst: Instance): Vector3?
		if U.getInstancePosition then
			local p = U.getInstancePosition(inst)
			if p then
				return p
			end
		end
		if inst:IsA("Model") then
			local ok, pivot = pcall(function()
				return (inst :: Model):GetPivot()
			end)
			if ok and pivot then
				return pivot.Position
			end
		end
		if inst:IsA("BasePart") then
			return inst.Position
		end
		return nil
	end

	local function snapWorldNode(inst: Instance, extra: any?): any
		local pos = instancePosition(inst)
		local entry: any = {
			name = inst.Name,
			className = inst.ClassName,
			path = inst:GetFullName(),
			childCount = #inst:GetChildren(),
			position = pos and U.vec3Table(pos) or nil,
		}
		if extra then
			for k, v in pairs(extra) do
				entry[k] = v
			end
		end
		if inst:IsA("BasePart") then
			local bp = inst :: BasePart
			entry.size = U.vec3Table(bp.Size)
			entry.material = tostring(bp.Material)
			entry.transparency = bp.Transparency
			entry.canCollide = bp.CanCollide
			entry.color = color3Table(bp.Color)
		elseif inst:IsA("Model") then
			local m = inst :: Model
			entry.primaryPart = m.PrimaryPart and m.PrimaryPart.Name or nil
		end
		-- Mesh / texture ids when present (identify rock vs fancy ore)
		pcall(function()
			if inst:IsA("MeshPart") then
				entry.meshId = (inst :: MeshPart).MeshId
				entry.textureId = (inst :: MeshPart).TextureID
			elseif inst:IsA("SpecialMesh") then
				entry.meshId = (inst :: SpecialMesh).MeshId
				entry.textureId = (inst :: SpecialMesh).TextureId
			end
		end)
		return entry
	end

	local function isPlayerCharacter(inst: Instance): boolean
		local cur: Instance? = inst
		while cur and cur ~= workspace do
			if cur:IsA("Model") and Players:GetPlayerFromCharacter(cur) then
				return true
			end
			cur = cur.Parent
		end
		return false
	end

	local function nameLooksInteresting(name: string): boolean
		local n = string.lower(name)
		-- Common interactive / resource / map structure tokens
		local keys = {
			"ore", "rock", "stone", "mine", "vein", "spawn",
			"farm", "soil", "crop", "plant", "harvest",
			"chest", "crate", "loot", "pickup", "item", "drop",
			"npc", "quest", "vendor", "shop", "merchant",
			"portal", "door", "gate", "ladder", "teleport",
			"boss", "king", "tortoise", "barrel", "champion",
			"tree", "bush", "herb", "flower", "resource",
			"machine", "claw", "prize", "event",
			"lamp", "light", "sign", "board",
			"worlditem", "world_item",
		}
		for _, k in ipairs(keys) do
			if string.find(n, k, 1, true) then
				return true
			end
		end
		-- Ore_*, FarmSoils_*, SP##, T1_ patterns
		if string.find(n, "ore_", 1, true) == 1 then
			return true
		end
		if string.find(n, "farmsoils", 1, true) == 1 then
			return true
		end
		if string.match(n, "^sp%d+$") then
			return true
		end
		return false
	end

	local function shouldExpandRoot(name: string): boolean
		local n = string.lower(name)
		if n == "maps" or n == "mobs" or n == "npcs" or n == "pets" or n == "mounts" then
			return true
		end
		if n == "worlditems" or n == "world_items" then
			return true
		end
		if string.find(n, "event_", 1, true) == 1 then
			return true
		end
		if string.find(n, "farmsoils", 1, true) == 1 then
			return true
		end
		if string.find(n, "spawn", 1, true) then
			return true
		end
		if nameLooksInteresting(name) then
			return true
		end
		return false
	end

	local function collectCollectionTags(): any
		local tags = {}
		local tagCounts: { [string]: number } = {}
		local samples: { [string]: { any } } = {}
		local ok, allTags = pcall(function()
			return CollectionService:GetAllTags()
		end)
		if not ok or type(allTags) ~= "table" then
			return { available = false, tags = {}, tagCounts = {}, samples = {} }
		end
		for _, tag in ipairs(allTags) do
			local tagged = {}
			pcall(function()
				tagged = CollectionService:GetTagged(tag)
			end)
			tagCounts[tag] = #tagged
			table.insert(tags, tag)
			local sample = {}
			for i = 1, math.min(8, #tagged) do
				local inst = tagged[i]
				if inst and inst:IsDescendantOf(workspace) then
					table.insert(sample, snapWorldNode(inst, { tag = tag }))
				end
			end
			if #sample > 0 then
				samples[tag] = sample
			end
		end
		table.sort(tags)
		return {
			available = true,
			tagCount = #tags,
			tags = tags,
			tagCounts = tagCounts,
			samples = samples,
		}
	end

	-- Shallow inventory of every workspace direct child (discover new roots).
	local function collectWorkspaceRoots(): { any }
		local list = {}
		for _, ch in ipairs(workspace:GetChildren()) do
			if isPlayerCharacter(ch) then
				continue
			end
			local pos = instancePosition(ch)
			table.insert(list, {
				name = ch.Name,
				className = ch.ClassName,
				path = ch:GetFullName(),
				childCount = #ch:GetChildren(),
				descendantHint = nil, -- filled cheaply only for containers
				position = pos and U.vec3Table(pos) or nil,
				interesting = shouldExpandRoot(ch.Name) or nameLooksInteresting(ch.Name),
			})
		end
		table.sort(list, function(a, b)
			return a.name < b.name
		end)
		return list
	end

	-- Bounded tree of interesting folders (Maps/World/Spawn_Ore etc.).
	local function collectInterestingTree(): any
		local maxNodes = C.WORLD_DUMP_TREE_MAX_NODES or 2500
		local maxDepth = C.WORLD_DUMP_TREE_MAX_DEPTH or 6
		local nodes = {}
		local byName: { [string]: number } = {}
		local truncated = false

		local function walk(inst: Instance, depth: number)
			if #nodes >= maxNodes then
				truncated = true
				return
			end
			if depth > maxDepth then
				return
			end
			if isPlayerCharacter(inst) then
				return
			end
			-- Always record containers + anything with an interesting name
			local record = inst:IsA("Folder")
				or inst:IsA("Model")
				or inst:IsA("BasePart")
				or nameLooksInteresting(inst.Name)
			if record and depth > 0 then
				local entry = snapWorldNode(inst, { depth = depth })
				table.insert(nodes, entry)
				byName[inst.Name] = (byName[inst.Name] or 0) + 1
			end
			if depth >= maxDepth then
				return
			end
			-- Expand children for folders/models (not every mesh leaf)
			if inst:IsA("Folder") or inst:IsA("Model") or inst:IsA("Configuration") then
				for _, ch in ipairs(inst:GetChildren()) do
					if #nodes >= maxNodes then
						truncated = true
						return
					end
					walk(ch, depth + 1)
				end
			end
		end

		for _, ch in ipairs(workspace:GetChildren()) do
			if shouldExpandRoot(ch.Name) then
				-- Root itself
				table.insert(nodes, snapWorldNode(ch, { depth = 0, root = true }))
				byName[ch.Name] = (byName[ch.Name] or 0) + 1
				walk(ch, 0)
			end
			if truncated then
				break
			end
		end

		return {
			nodeCount = #nodes,
			truncated = truncated,
			maxNodes = maxNodes,
			maxDepth = maxDepth,
			nameCounts = byName,
			nodes = nodes,
		}
	end

	-- Name-pattern hits anywhere under workspace (catch Ore_Rock with no VFX).
	local function collectNameMatches(): any
		local maxHits = C.WORLD_DUMP_NAME_MATCH_MAX or 800
		local hits = {}
		local byKey: { [string]: number } = {}
		local truncated = false
		for _, d in ipairs(workspace:GetDescendants()) do
			if #hits >= maxHits then
				truncated = true
				break
			end
			if isPlayerCharacter(d) then
				continue
			end
			if not nameLooksInteresting(d.Name) then
				continue
			end
			-- Prefer Models / named containers over every leaf MeshPart named "Glow"
			local prefer = d:IsA("Model")
				or d:IsA("Folder")
				or d:IsA("BasePart")
			if not prefer then
				continue
			end
			-- Skip pure VFX noise leaves unless parent is interesting
			local lower = string.lower(d.Name)
			if lower == "glow" or lower == "shine" or lower == "ember"
				or lower == "smoke" or lower == "particleemitter"
			then
				continue
			end
			table.insert(hits, snapWorldNode(d))
			byKey[d.Name] = (byKey[d.Name] or 0) + 1
		end
		return {
			hitCount = #hits,
			truncated = truncated,
			maxHits = maxHits,
			nameCounts = byKey,
			hits = hits,
		}
	end

	-- Everything near the player (best for "what am I standing on?").
	local function collectNearby(playerPos: Vector3?): any
		local radius = C.WORLD_DUMP_NEAR_STUDS or 80
		local maxN = C.WORLD_DUMP_NEAR_MAX or 400
		local list = {}
		if not playerPos then
			return { radius = radius, count = 0, items = {} }
		end
		for _, d in ipairs(workspace:GetDescendants()) do
			if #list >= maxN then
				break
			end
			if isPlayerCharacter(d) then
				continue
			end
			if not (d:IsA("Model") or d:IsA("BasePart") or d:IsA("Folder")) then
				continue
			end
			-- Folders rarely have positions; only keep if interesting
			if d:IsA("Folder") and not nameLooksInteresting(d.Name) then
				continue
			end
			local pos = instancePosition(d)
			if not pos then
				continue
			end
			local dist = (pos - playerPos).Magnitude
			if dist <= radius then
				local entry = snapWorldNode(d, {
					distance = dist,
					interesting = nameLooksInteresting(d.Name),
				})
				table.insert(list, entry)
			end
		end
		table.sort(list, function(a, b)
			return (a.distance or 0) < (b.distance or 0)
		end)
		return {
			radius = radius,
			count = #list,
			truncated = #list >= maxN,
			items = list,
		}
	end

	function M.collectWorld(playerPosTable: any?): any
		local playerPos: Vector3? = nil
		if playerPosTable and playerPosTable.x then
			playerPos = Vector3.new(playerPosTable.x, playerPosTable.y, playerPosTable.z)
		else
			local _, p = U.getPlayerPosition()
			if p then
				playerPos = Vector3.new(p.x, p.y, p.z)
			end
		end

		local roots = collectWorkspaceRoots()
		local tree = collectInterestingTree()
		local nameMatches = collectNameMatches()
		local nearby = collectNearby(playerPos)
		local tags = collectCollectionTags()

		-- Specialized fragments (already structured)
		local ores = nil
		pcall(function()
			if S.Ore and S.Ore.snapshotFragment then
				ores = S.Ore.snapshotFragment()
			end
		end)
		local farm = nil
		pcall(function()
			if S.Farm and S.Farm.scanEmptySoils then
				local empty, total, planted = S.Farm.scanEmptySoils()
				farm = {
					soilTotal = total,
					planted = planted,
					empty = #empty,
				}
			end
		end)

		return {
			workspaceRootCount = #roots,
			workspaceRoots = roots,
			interestingTree = tree,
			nameMatches = nameMatches,
			nearby = nearby,
			collectionTags = tags,
			ores = ores,
			farm = farm,
		}
	end

	function M.dumpWorld()
		setStatus("Dumping world + combat snapshot…")
		local playerName, playerPos = U.getPlayerPosition()
		local facing = nil
		pcall(function()
			if U.getPlayerFacingSnapshot then
				facing = U.getPlayerFacingSnapshot()
			end
		end)
		local enemies = collectEnemies()
		local nameplates, nameplateSummary = collectNameplates(enemies)
		local otherPlayers = collectOtherPlayers()
		local indicators = collectIndicators()
		local gui = collectGuiDump()
		local claw = nil
		pcall(function()
			if S.Claw and S.Claw.snapshotFragment then
				claw = S.Claw.snapshotFragment()
			end
		end)
		local world = nil
		pcall(function()
			world = M.collectWorld(playerPos)
		end)
		-- Convenience alias (also nested under world.ores)
		local ores = world and world.ores or nil
		local stamp = os.date("%Y-%m-%d_%H-%M-%S")
		local payload = {
			type = "world_snapshot",
			timestamp = stamp,
			player = {
				name = playerName,
				position = playerPos,
				-- Facing debug: root LookVector / yaw + camera look
				facing = facing,
			},
			-- Non-combat: Maps structure, Spawn_Ore, nearby Models/Parts, tags, name hits
			world = world,
			ores = ores,
			enemyCount = #enemies,
			enemies = enemies,
			-- Flat nameplate index: filter primaryColorClass == "red" | "green" | "white"
			nameplateCount = #nameplates,
			nameplateSummary = nameplateSummary,
			nameplates = nameplates,
			otherPlayers = otherPlayers,
			indicatorCount = #indicators,
			indicators = indicators,
			claw = claw,
			gui = gui,
		}
		local path = string.format("%s/snapshot_%s.json", C.DUMP_DIR, stamp)
		local ok, err = pcall(function()
			U.ensureDir(C.DUMP_DIR)
			writefile(path, HttpService:JSONEncode(payload))
		end)
		if ok then
			local nearN = world and world.nearby and world.nearby.count or 0
			local matchN = world and world.nameMatches and world.nameMatches.hitCount or 0
			local oreN = ores and ores.count or 0
			local rootN = world and world.workspaceRootCount or 0
			setStatus(string.format(
				"Dump OK: %s | world roots=%d near=%d nameHits=%d ores=%d | enemies=%d plates R%d/G%d/W%d",
				path,
				rootN,
				nearN,
				matchN,
				oreN,
				#enemies,
				nameplateSummary.red or 0,
				nameplateSummary.green or 0,
				nameplateSummary.white or 0
			))
		else
			setStatus("Dump failed: " .. tostring(err))
		end
	end

	function M.dumpGuiOnly()
		setStatus("Dumping GUI…")
		local playerName, playerPos = U.getPlayerPosition()
		local gui = collectGuiDump()
		local stamp = os.date("%Y-%m-%d_%H-%M-%S")
		local payload = {
			type = "gui_only",
			timestamp = stamp,
			player = { name = playerName, position = playerPos },
			gui = gui,
		}
		local path = string.format("%s/gui_%s.json", C.DUMP_DIR, stamp)
		local ok, err = pcall(function()
			U.ensureDir(C.DUMP_DIR)
			writefile(path, HttpService:JSONEncode(payload))
		end)
		if ok then
			setStatus(string.format(
				"GUI dump OK: %s (%d btns, %d bars, %d labels, %d timers)",
				path,
				gui.buttonCount or 0,
				gui.barCount or 0,
				gui.labelCount or 0,
				gui.timerCount or 0
			))
		else
			setStatus("GUI dump failed: " .. tostring(err))
		end
	end

	---------------------------------------------------------------------------
	-- Full world mesh export (walls / floors / collision + visual solids)
	-- Writes dumps/mesh_<stamp>/manifest.json + parts_XXXX.json + terrain + floor_grid
	-- Roblox does not expose raw triangle soups for CSG; MeshParts include meshId.
	-- Parts are exported as oriented boxes (CFrame + size) — reconstructible OBB mesh.
	---------------------------------------------------------------------------

	local function cfComponents(cf: CFrame): any
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
		return {
			position = { x = x, y = y, z = z },
			-- Column-major 3x3 rotation (Roblox CFrame basis)
			matrix = {
				r00, r01, r02,
				r10, r11, r12,
				r20, r21, r22,
			},
			lookVector = U.vec3Table(cf.LookVector),
			rightVector = U.vec3Table(cf.RightVector),
			upVector = U.vec3Table(cf.UpVector),
		}
	end

	local function partVolume(size: Vector3): number
		return math.abs(size.X * size.Y * size.Z)
	end

	local function snapMeshPart(bp: BasePart): any
		local cf = bp.CFrame
		local size = bp.Size
		local entry: any = {
			name = bp.Name,
			className = bp.ClassName,
			path = bp:GetFullName(),
			cframe = cfComponents(cf),
			size = U.vec3Table(size),
			volume = partVolume(size),
			canCollide = bp.CanCollide,
			canQuery = (bp :: any).CanQuery,
			canTouch = (bp :: any).CanTouch,
			anchored = bp.Anchored,
			transparency = bp.Transparency,
			material = tostring(bp.Material),
			color = color3Table(bp.Color),
			castShadow = bp.CastShadow,
		}
		pcall(function()
			entry.collisionGroup = bp.CollisionGroup
		end)
		pcall(function()
			if bp:IsA("Part") then
				entry.shape = tostring((bp :: Part).Shape)
			end
		end)
		pcall(function()
			if bp:IsA("WedgePart") then
				entry.shape = "Wedge"
			elseif bp:IsA("CornerWedgePart") then
				entry.shape = "CornerWedge"
			elseif bp:IsA("TrussPart") then
				entry.shape = "Truss"
			elseif bp:IsA("SpawnLocation") then
				entry.shape = "SpawnLocation"
			end
		end)
		-- Mesh asset ids (true external mesh reference when present)
		pcall(function()
			if bp:IsA("MeshPart") then
				local mp = bp :: MeshPart
				entry.meshId = mp.MeshId
				entry.textureId = mp.TextureID
				entry.meshSize = U.vec3Table(mp.MeshSize)
			end
		end)
		-- FileMesh / SpecialMesh child on a Part
		pcall(function()
			local sm = bp:FindFirstChildOfClass("SpecialMesh")
				or bp:FindFirstChildOfClass("FileMesh")
			if sm then
				entry.specialMesh = {
					className = sm.ClassName,
					meshId = (sm :: any).MeshId,
					textureId = (sm :: any).TextureId,
					scale = (sm :: any).Scale and U.vec3Table((sm :: any).Scale) or nil,
					meshType = (sm :: any).MeshType and tostring((sm :: any).MeshType) or nil,
				}
			end
		end)
		-- 8 OBB corners in world space (handy without rebuilding CFrame)
		pcall(function()
			local corners = {}
			local sx, sy, sz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
			for _, ox in ipairs({ -sx, sx }) do
				for _, oy in ipairs({ -sy, sy }) do
					for _, oz in ipairs({ -sz, sz }) do
						local w = cf:PointToWorldSpace(Vector3.new(ox, oy, oz))
						table.insert(corners, U.vec3Table(w))
					end
				end
			end
			entry.corners = corners
		end)
		return entry
	end

	local function writeJsonFile(path: string, payload: any): (boolean, string?)
		local okEncode, encoded = pcall(function()
			return HttpService:JSONEncode(payload)
		end)
		if not okEncode then
			return false, "JSONEncode: " .. tostring(encoded)
		end
		local okWrite, err = pcall(function()
			writefile(path, encoded)
		end)
		if not okWrite then
			return false, "writefile: " .. tostring(err)
		end
		return true, nil
	end

	local function expandAabbWithPart(aabb: any, bp: BasePart)
		local cf = bp.CFrame
		local size = bp.Size
		local sx, sy, sz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
		for _, ox in ipairs({ -sx, sx }) do
			for _, oy in ipairs({ -sy, sy }) do
				for _, oz in ipairs({ -sz, sz }) do
					local w = cf:PointToWorldSpace(Vector3.new(ox, oy, oz))
					if w.X < aabb.minX then aabb.minX = w.X end
					if w.Y < aabb.minY then aabb.minY = w.Y end
					if w.Z < aabb.minZ then aabb.minZ = w.Z end
					if w.X > aabb.maxX then aabb.maxX = w.X end
					if w.Y > aabb.maxY then aabb.maxY = w.Y end
					if w.Z > aabb.maxZ then aabb.maxZ = w.Z end
				end
			end
		end
		aabb.count += 1
	end

	-- Flat walkable slab (building floors, hub tiles) — NOT barrier shells.
	local function isFloorLikePart(bp: BasePart): boolean
		local s = bp.Size
		local minA = math.min(s.X, s.Y, s.Z)
		local maxA = math.max(s.X, s.Y, s.Z)
		if minA > 8 or maxA < 3 then
			return false
		end
		-- Mostly aligned with world up (horizontal surface)
		local upY = math.abs(bp.CFrame.UpVector.Y)
		if upY < 0.7 then
			return false
		end
		local n = string.lower(bp.Name)
		if string.find(n, "floor", 1, true)
			or string.find(n, "ground", 1, true)
			or string.find(n, "path", 1, true)
			or string.find(n, "road", 1, true)
			or string.find(n, "tile", 1, true)
			or string.find(n, "soil", 1, true)
		then
			return true
		end
		-- Thin relative to horizontal extent
		local horiz = math.sqrt(s.X * s.X + s.Z * s.Z)
		return minA <= 4 and horiz >= 6
	end

	-- Sky/barrier shells (InvisibleWall folder, giant translucent slabs) blow AABB to ±1024
	-- and steal floor raycasts. Still exported as parts; excluded from playable bounds.
	local function isBarrierPart(bp: BasePart): boolean
		local path = bp:GetFullName()
		local n = string.lower(bp.Name)
		if string.find(path, "InvisibleWall", 1, true) then
			return true
		end
		if string.find(n, "invisible wall", 1, true) or string.find(n, "invisiblewall", 1, true) then
			return true
		end
		if string.find(n, "kill ?brick", 1, true) then
			return true
		end
		-- Walkable floor slabs must never be classified as barriers
		if bp.CanCollide and isFloorLikePart(bp) then
			return false
		end
		local s = bp.Size
		local maxd = math.max(s.X, s.Y, s.Z)
		local mind = math.min(s.X, s.Y, s.Z)
		local cap = C.MESH_DUMP_PLAYABLE_MAX_DIM or 180
		-- Huge thin forcefields / transparent *vertical* shells only
		local upY = math.abs(bp.CFrame.UpVector.Y)
		local flat = upY >= 0.7
		if maxd >= cap and mind <= 12 and (bp.Transparency >= 0.4 or bp.Material == Enum.Material.ForceField) then
			-- Flat transparent canCollide = invisible floor, keep as floor not barrier
			if flat and bp.CanCollide then
				return false
			end
			return true
		end
		if maxd >= 500 and not (flat and bp.CanCollide) then
			return true
		end
		return false
	end

	-- Public: same filters as dumpWorldMesh (for Outline Mesh / future Save Map).
	-- Returns "barrier" | "floor" | "collide" | "visual" | nil (skipped).
	function M.classifyMeshExportPart(bp: BasePart): string?
		if not bp or not bp:IsA("BasePart") then
			return nil
		end
		if isPlayerCharacter(bp) then
			return nil
		end
		local cam = workspace.CurrentCamera
		if cam and bp:IsDescendantOf(cam) then
			return nil
		end
		local vol = partVolume(bp.Size)
		if vol < (C.MESH_DUMP_MIN_VOLUME or 0.001) then
			return nil
		end
		if isBarrierPart(bp) then
			return "barrier"
		end
		if bp.CanCollide and isFloorLikePart(bp) then
			return "floor"
		end
		if bp.CanCollide then
			return "collide"
		end
		if C.MESH_DUMP_INCLUDE_NONCOLLIDE == false then
			return nil
		end
		if (C.MESH_DUMP_SKIP_FULLY_INVISIBLE ~= false) and bp.Transparency >= 0.999 then
			return nil
		end
		-- Decorative grass patches etc. still useful as floor-adjacent visuals
		local n = string.lower(bp.Name)
		if string.find(n, "grass", 1, true) and isFloorLikePart(bp) then
			return "floor"
		end
		return "visual"
	end

	function M.isMeshBarrierPart(bp: BasePart): boolean
		return isBarrierPart(bp)
	end

	local function newAabb()
		return {
			minX = math.huge,
			minY = math.huge,
			minZ = math.huge,
			maxX = -math.huge,
			maxY = -math.huge,
			maxZ = -math.huge,
			count = 0,
		}
	end

	local function collectTerrainSparse(aabb: any, centerHint: Vector3?): any
		local terrain = workspace:FindFirstChildOfClass("Terrain")
		if not terrain then
			return { available = false, reason = "no Terrain" }
		end
		local res = C.MESH_DUMP_TERRAIN_RES or 4
		local pad = C.MESH_DUMP_TERRAIN_PAD or 16
		-- Hard cap: Roblox errors "Region is too large" well below 2048³ voxels
		local maxAxis = C.MESH_DUMP_TERRAIN_MAX_AXIS or 256

		local minV = Vector3.new(aabb.minX - pad, aabb.minY - pad, aabb.minZ - pad)
		local maxV = Vector3.new(aabb.maxX + pad, aabb.maxY + pad, aabb.maxZ + pad)
		-- Prefer player-centered box so we always get local terrain even if AABB is weird
		local center = centerHint or ((minV + maxV) * 0.5)
		local ext = (maxV - minV)
		local function clampAxis(v: number): number
			return math.clamp(v, res, maxAxis)
		end
		ext = Vector3.new(clampAxis(ext.X), clampAxis(ext.Y), clampAxis(ext.Z))
		-- If playable AABB collapsed, use maxAxis cube around player
		if aabb.count == 0 or ext.X ~= ext.X then
			ext = Vector3.new(maxAxis, math.min(maxAxis, 128), maxAxis)
		end
		minV = center - ext * 0.5
		maxV = center + ext * 0.5

		local region = Region3.new(minV, maxV)
		local okExpand, expanded = pcall(function()
			return region:ExpandToGrid(res)
		end)
		if okExpand and expanded then
			region = expanded
		end

		local okRead, materials, occupancies = pcall(function()
			return terrain:ReadVoxels(region, res)
		end)
		if not okRead then
			return {
				available = false,
				reason = "ReadVoxels failed: " .. tostring(materials),
				regionMin = U.vec3Table(minV),
				regionMax = U.vec3Table(maxV),
				resolution = res,
			}
		end

		local cells = {}
		local matCounts: { [string]: number } = {}
		-- materials.Size is Vector3 on voxel channel maps; fall back to table length
		local sizeX, sizeY, sizeZ = 0, 0, 0
		pcall(function()
			local sz = materials.Size
			sizeX, sizeY, sizeZ = sz.X, sz.Y, sz.Z
		end)
		if sizeX == 0 then
			sizeX = #materials
			sizeY = sizeX > 0 and #materials[1] or 0
			sizeZ = (sizeY > 0 and materials[1][1]) and #materials[1][1] or 0
		end
		local scanned = 0
		local solid = 0
		-- Region3 after ExpandToGrid — use CFrame/Size if available
		local rMin = minV
		local rSize = maxV - minV
		pcall(function()
			local cf = region.CFrame
			local sz = region.Size
			rMin = cf.Position - sz * 0.5
			rSize = sz
		end)

		for ix = 1, sizeX do
			local plane = materials[ix]
			local oplane = occupancies and occupancies[ix]
			if plane then
				for iy = 1, sizeY do
					local col = plane[iy]
					local ocol = oplane and oplane[iy]
					if col then
						for iz = 1, sizeZ do
							scanned += 1
							local mat = col[iz]
							local occ = ocol and ocol[iz] or 0
							if mat and mat ~= Enum.Material.Air and occ > 0.01 then
								solid += 1
								local matName = tostring(mat)
								matCounts[matName] = (matCounts[matName] or 0) + 1
								local wx = rMin.X + (ix - 0.5) * res
								local wy = rMin.Y + (iy - 0.5) * res
								local wz = rMin.Z + (iz - 0.5) * res
								table.insert(cells, {
									i = ix,
									j = iy,
									k = iz,
									material = matName,
									occupancy = occ,
									position = { x = wx, y = wy, z = wz },
								})
							end
							if scanned % 8000 == 0 then
								task.wait()
							end
						end
					end
				end
			end
		end

		return {
			available = true,
			resolution = res,
			regionMin = U.vec3Table(rMin),
			regionMax = U.vec3Table(rMin + rSize),
			gridSize = { x = sizeX, y = sizeY, z = sizeZ },
			scannedVoxels = scanned,
			solidVoxels = solid,
			materialCounts = matCounts,
			-- Sparse solid cells only (not full dense grid)
			cells = cells,
		}
	end

	local function collectFloorGrid(aabb: any): any
		local step = C.MESH_DUMP_FLOOR_STEP or 4
		local maxSamples = C.MESH_DUMP_FLOOR_MAX_SAMPLES or 80000
		local rayUp = C.MESH_DUMP_FLOOR_RAY_UP or 40
		local rayDown = C.MESH_DUMP_FLOOR_RAY_DOWN or 250
		local pad = C.MESH_DUMP_TERRAIN_PAD or 16

		local minX = aabb.minX - pad
		local maxX = aabb.maxX + pad
		local minZ = aabb.minZ - pad
		local maxZ = aabb.maxZ + pad
		local topY = aabb.maxY + rayUp

		local nx = math.max(1, math.floor((maxX - minX) / step) + 1)
		local nz = math.max(1, math.floor((maxZ - minZ) / step) + 1)
		if nx * nz > maxSamples then
			local area = math.max(1, (maxX - minX) * (maxZ - minZ))
			step = math.max(step, math.sqrt(area / maxSamples))
			nx = math.max(1, math.floor((maxX - minX) / step) + 1)
			nz = math.max(1, math.floor((maxZ - minZ) / step) + 1)
		end

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local exclude: { Instance } = {}
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr.Character then
				table.insert(exclude, plr.Character)
			end
		end
		-- Exclude map barrier shells so rays reach real floors
		pcall(function()
			local maps = workspace:FindFirstChild("Maps")
			local inv = maps and maps:FindFirstChild("InvisibleWall")
			if inv then
				table.insert(exclude, inv)
			end
		end)
		params.FilterDescendantsInstances = exclude
		params.IgnoreWater = false

		local samples = {}
		local hitCount = 0
		local castCount = 0
		local skippedBarrierHits = 0
		local materialCounts: { [string]: number } = {}

		local function raycastFloor(x: number, z: number)
			local origin = Vector3.new(x, topY, z)
			local remaining = rayDown
			local yCursor = topY
			-- Multi-hit: skip residual barrier parts not under InvisibleWall folder
			for _ = 1, 6 do
				castCount += 1
				local result = workspace:Raycast(origin, Vector3.new(0, -remaining, 0), params)
				if not result then
					return nil
				end
				local inst = result.Instance
				if inst and inst:IsA("BasePart") and isBarrierPart(inst :: BasePart) then
					skippedBarrierHits += 1
					-- Continue below this hit
					local hitY = result.Position.Y
					yCursor = hitY - 0.05
					origin = Vector3.new(x, yCursor, z)
					remaining = rayDown - (topY - yCursor)
					if remaining <= 1 then
						return nil
					end
					-- Also permanently exclude this instance
					table.insert(exclude, inst)
					params.FilterDescendantsInstances = exclude
				else
					return result
				end
			end
			return nil
		end

		for ix = 0, nx - 1 do
			for iz = 0, nz - 1 do
				local x = minX + ix * step
				local z = minZ + iz * step
				local result = raycastFloor(x, z)
				if result then
					hitCount += 1
					local matName = result.Material and tostring(result.Material) or "unknown"
					materialCounts[matName] = (materialCounts[matName] or 0) + 1
					local inst = result.Instance
					table.insert(samples, {
						x = x,
						z = z,
						y = result.Position.Y,
						material = matName,
						normal = U.vec3Table(result.Normal),
						distance = result.Distance,
						instance = inst and inst:GetFullName() or nil,
						instanceClass = inst and inst.ClassName or nil,
						canCollide = inst and inst:IsA("BasePart") and (inst :: BasePart).CanCollide or nil,
					})
				else
					table.insert(samples, {
						x = x,
						z = z,
						y = nil,
						miss = true,
					})
				end
				if (ix * nz + iz) % 200 == 0 then
					task.wait()
				end
			end
		end

		return {
			step = step,
			rayOriginY = topY,
			rayLength = rayDown,
			minX = minX,
			maxX = maxX,
			minZ = minZ,
			maxZ = maxZ,
			gridNX = nx,
			gridNZ = nz,
			castCount = castCount,
			hitCount = hitCount,
			skippedBarrierHits = skippedBarrierHits,
			materialCounts = materialCounts,
			samples = samples,
			note = "playable AABB; InvisibleWall folder excluded; multi-hit skips barrier slabs",
		}
	end

	function M.dumpWorldMesh()
		setStatus("Mesh export: scanning BaseParts…")
		local stamp = os.date("%Y-%m-%d_%H-%M-%S")
		local playerName, playerPos = U.getPlayerPosition()
		local dir = string.format("%s/mesh_%s", C.DUMP_DIR or "dumps", stamp)
		local includeNonCollide = C.MESH_DUMP_INCLUDE_NONCOLLIDE ~= false
		local skipInvisible = C.MESH_DUMP_SKIP_FULLY_INVISIBLE ~= false
		local minVol = C.MESH_DUMP_MIN_VOLUME or 0.001
		local chunkSize = C.MESH_DUMP_CHUNK_SIZE or 1500
		local yieldEvery = C.MESH_DUMP_YIELD_EVERY or 350

		local okDir, dirErr = pcall(function()
			U.ensureDir(C.DUMP_DIR or "dumps")
			U.ensureDir(dir)
		end)
		if not okDir then
			setStatus("Mesh export failed: mkdir " .. tostring(dirErr))
			return
		end

		local stats = {
			scanned = 0,
			exported = 0,
			canCollide = 0,
			nonCollide = 0,
			meshParts = 0,
			unions = 0,
			skippedPlayer = 0,
			skippedInvisible = 0,
			skippedVolume = 0,
			byClass = {} :: { [string]: number },
		}

		local aabb = newAabb() -- all exported parts
		local playableAabb = newAabb() -- excludes InvisibleWall / giant shells (for floor+terrain)
		local barrierCount = 0

		local chunk = {}
		local chunkIndex = 0
		local chunkFiles = {}
		local scanN = 0

		local function flushChunk()
			if #chunk == 0 then
				return true
			end
			chunkIndex += 1
			local fileName = string.format("parts_%04d.json", chunkIndex)
			local path = string.format("%s/%s", dir, fileName)
			local payload = {
				type = "world_mesh_parts_chunk",
				timestamp = stamp,
				chunkIndex = chunkIndex,
				partCount = #chunk,
				parts = chunk,
			}
			local ok, err = writeJsonFile(path, payload)
			if not ok then
				return false, err
			end
			table.insert(chunkFiles, {
				file = fileName,
				partCount = #chunk,
				index = chunkIndex,
			})
			chunk = {}
			task.wait()
			return true
		end

		for _, d in ipairs(workspace:GetDescendants()) do
			if not d:IsA("BasePart") then
				continue
			end
			stats.scanned += 1
			scanN += 1
			if scanN % yieldEvery == 0 then
				setStatus(string.format(
					"Mesh export: scan %d… exported %d",
					stats.scanned,
					stats.exported
				))
				task.wait()
			end

			local bp = d :: BasePart
			if isPlayerCharacter(bp) then
				stats.skippedPlayer += 1
				continue
			end
			-- Skip camera-only junk
			if bp:IsDescendantOf(workspace.CurrentCamera) then
				continue
			end

			local vol = partVolume(bp.Size)
			if vol < minVol then
				stats.skippedVolume += 1
				continue
			end

			if not bp.CanCollide then
				if not includeNonCollide then
					continue
				end
				if skipInvisible and bp.Transparency >= 0.999 then
					stats.skippedInvisible += 1
					continue
				end
			end

			local kind = M.classifyMeshExportPart(bp)
			if not kind then
				continue
			end
			local entry = snapMeshPart(bp)
			local barrier = kind == "barrier"
			entry.barrier = barrier
			entry.kind = kind
			if barrier then
				barrierCount += 1
			end
			table.insert(chunk, entry)
			stats.exported += 1
			if kind == "floor" then
				stats.floors = (stats.floors or 0) + 1
			end
			if bp.CanCollide then
				stats.canCollide += 1
			else
				stats.nonCollide += 1
			end
			if bp:IsA("MeshPart") then
				stats.meshParts += 1
			end
			if bp:IsA("UnionOperation") or bp:IsA("PartOperation") then
				stats.unions += 1
			end
			local cn = bp.ClassName
			stats.byClass[cn] = (stats.byClass[cn] or 0) + 1
			expandAabbWithPart(aabb, bp)
			if not barrier then
				expandAabbWithPart(playableAabb, bp)
			end

			if #chunk >= chunkSize then
				local okFlush, ferr = flushChunk()
				if not okFlush then
					setStatus("Mesh export failed mid-write: " .. tostring(ferr))
					return
				end
			end
		end

		local okFlush, ferr = flushChunk()
		if not okFlush then
			setStatus("Mesh export failed final chunk: " .. tostring(ferr))
			return
		end

		local playerCenter: Vector3? = nil
		if playerPos then
			playerCenter = Vector3.new(playerPos.x, playerPos.y, playerPos.z)
		end

		if playableAabb.count == 0 then
			-- Fallback playable AABB around player so terrain/floor still run
			local px = playerPos and playerPos.x or 0
			local py = playerPos and playerPos.y or 0
			local pz = playerPos and playerPos.z or 0
			playableAabb.minX, playableAabb.maxX = px - 120, px + 120
			playableAabb.minY, playableAabb.maxY = py - 40, py + 40
			playableAabb.minZ, playableAabb.maxZ = pz - 120, pz + 120
			playableAabb.count = 0
		end

		setStatus("Mesh export: terrain voxels (player-centered)…")
		local terrain = collectTerrainSparse(playableAabb, playerCenter)
		local terrainPath = string.format("%s/terrain.json", dir)
		local okT, errT = writeJsonFile(terrainPath, {
			type = "world_mesh_terrain",
			timestamp = stamp,
			terrain = terrain,
		})
		if not okT then
			setStatus("Mesh export terrain write failed: " .. tostring(errT))
			-- continue; parts already saved
		end

		setStatus("Mesh export: floor raycast grid (playable AABB)…")
		local floorGrid = collectFloorGrid(playableAabb)
		local floorPath = string.format("%s/floor_grid.json", dir)
		local okF, errF = writeJsonFile(floorPath, {
			type = "world_mesh_floor_grid",
			timestamp = stamp,
			floor = floorGrid,
		})
		if not okF then
			setStatus("Mesh export floor write failed: " .. tostring(errF))
		end

		-- Dense under-feet floor (what player is actually standing on — often Terrain)
		local standingFloor = nil
		if playerCenter then
			setStatus("Mesh export: standing-floor probe…")
			local standAabb = {
				minX = playerCenter.X - 40,
				maxX = playerCenter.X + 40,
				minY = playerCenter.Y - 30,
				maxY = playerCenter.Y + 20,
				minZ = playerCenter.Z - 40,
				maxZ = playerCenter.Z + 40,
				count = 1,
			}
			local localFloor = collectFloorGrid(standAabb)
			-- Single feet ray
			local feet = nil
			pcall(function()
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				local ex = {}
				for _, plr in ipairs(Players:GetPlayers()) do
					if plr.Character then
						table.insert(ex, plr.Character)
					end
				end
				local maps = workspace:FindFirstChild("Maps")
				local inv = maps and maps:FindFirstChild("InvisibleWall")
				if inv then
					table.insert(ex, inv)
				end
				params.FilterDescendantsInstances = ex
				local origin = playerCenter + Vector3.new(0, 3, 0)
				local hit = workspace:Raycast(origin, Vector3.new(0, -30, 0), params)
				if hit then
					feet = {
						position = U.vec3Table(hit.Position),
						normal = U.vec3Table(hit.Normal),
						material = hit.Material and tostring(hit.Material) or nil,
						distance = hit.Distance,
						instance = hit.Instance and hit.Instance:GetFullName() or nil,
						className = hit.Instance and hit.Instance.ClassName or nil,
						isTerrain = hit.Instance and hit.Instance:IsA("Terrain") or false,
					}
				end
			end)
			standingFloor = {
				feet = feet,
				localGrid = localFloor,
				note = "Outdoor walk surface is often Workspace.Terrain — see feet + localGrid, not only parts_*.",
			}
			writeJsonFile(string.format("%s/standing_floor.json", dir), {
				type = "world_mesh_standing_floor",
				timestamp = stamp,
				standingFloor = standingFloor,
			})
		end

		local manifest = {
			type = "world_mesh_export",
			timestamp = stamp,
			directory = dir,
			player = { name = playerName, position = playerPos },
			standingFloor = standingFloor and standingFloor.feet or nil,
			note = table.concat({
				"Best-effort full mesh export.",
				"Parts = oriented boxes (CFrame+size); MeshParts include meshId asset refs.",
				"CSG UnionOperation has no client triangle API — exported as OBB only.",
				"kind=floor|collide|visual|barrier on each part.",
				"Outdoor ground is often Terrain — standing_floor.json + terrain.json required for floors.",
			}, " "),
			options = {
				includeNonCollide = includeNonCollide,
				skipFullyInvisible = skipInvisible,
				minVolume = minVol,
				chunkSize = chunkSize,
				floorStep = C.MESH_DUMP_FLOOR_STEP or 4,
				terrainRes = C.MESH_DUMP_TERRAIN_RES or 4,
				terrainMaxAxis = C.MESH_DUMP_TERRAIN_MAX_AXIS or 256,
			},
			stats = stats,
			barrierCount = barrierCount,
			aabb = {
				min = { x = aabb.minX, y = aabb.minY, z = aabb.minZ },
				max = { x = aabb.maxX, y = aabb.maxY, z = aabb.maxZ },
				partCount = aabb.count,
			},
			playableAabb = {
				min = { x = playableAabb.minX, y = playableAabb.minY, z = playableAabb.minZ },
				max = { x = playableAabb.maxX, y = playableAabb.maxY, z = playableAabb.maxZ },
				partCount = playableAabb.count,
			},
			files = {
				parts = chunkFiles,
				terrain = "terrain.json",
				floorGrid = "floor_grid.json",
				standingFloor = "standing_floor.json",
				manifest = "manifest.json",
			},
			summary = {
				partChunks = #chunkFiles,
				partsExported = stats.exported,
				canCollide = stats.canCollide,
				nonCollide = stats.nonCollide,
				meshParts = stats.meshParts,
				floors = stats.floors or 0,
				barriers = barrierCount,
				terrainSolidVoxels = terrain and terrain.solidVoxels or 0,
				terrainAvailable = terrain and terrain.available == true,
				floorHits = floorGrid and floorGrid.hitCount or 0,
				floorCasts = floorGrid and floorGrid.castCount or 0,
				standingOn = standingFloor and standingFloor.feet and (
					standingFloor.feet.isTerrain and "Terrain" or standingFloor.feet.instance
				) or nil,
			},
		}

		local manPath = string.format("%s/manifest.json", dir)
		local okM, errM = writeJsonFile(manPath, manifest)
		if not okM then
			setStatus("Mesh export manifest failed: " .. tostring(errM))
			return
		end

		local feetLabel = "?"
		if standingFloor and standingFloor.feet then
			feetLabel = if standingFloor.feet.isTerrain
				then ("Terrain/" .. tostring(standingFloor.feet.material or "?"))
				else tostring(standingFloor.feet.instance or "part")
		end
		setStatus(string.format(
			"Mesh export OK: %s | parts=%d floorParts=%d mesh=%d terrainSolid=%d floorHits=%d | feet=%s",
			dir,
			stats.exported,
			stats.floors or 0,
			stats.meshParts,
			terrain and terrain.solidVoxels or 0,
			floorGrid and floorGrid.hitCount or 0,
			feetLabel
		))
	end

	return M
end

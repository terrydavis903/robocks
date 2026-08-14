-- portal_mage/ore.lua — Ore ESP (through-wall neon outlines)
--
-- Hierarchy (from dump snapshot_2026-08-09_15-35-49):
--   Workspace.Maps.World.Spawn_Ore
--     └── SP{n}                    e.g. SP3, SP12
--           └── Ore_{Type}         e.g. Ore_Aurorite, Ore_Lumite, Ore_Rock
--                 └── {Type}       mesh/VFX (Aurorite.Glow etc.)
--
-- Basic rock form often has no particle indicators, so dump-only scans miss it.
-- We enumerate Spawn_Ore children at runtime instead.
return function(S)
	local C = S.Config
	local U = S.Util
	local M = {}

	local HL_NAME = "PortalMage_OreESP"
	local MAINTAIN = 0.75
	local SPAWN_NAME = "Spawn_Ore"

	local function setStatus(t: string)
		if U and U.setStatus then
			U.setStatus(t)
		end
	end

	local function refreshLabel()
		if S.ui and S.ui.setOreEspLabel then
			S.ui.setOreEspLabel(S.oreEspEnabled == true)
		end
	end

	---------------------------------------------------------------------------
	-- Ore discovery
	---------------------------------------------------------------------------

	function M.findSpawnOreRoot(): Instance?
		local maps = workspace:FindFirstChild("Maps")
		local world = maps and maps:FindFirstChild("World")
		local spawn = world and world:FindFirstChild(SPAWN_NAME)
		if spawn then
			return spawn
		end
		-- Fallback: rare map layout variance
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == SPAWN_NAME and (d:IsA("Folder") or d:IsA("Model")) then
				return d
			end
		end
		return nil
	end

	-- True if this looks like a mineable ore model under an SP node.
	function M.isOreModel(inst: Instance): boolean
		if not inst or not inst.Parent then
			return false
		end
		local n = inst.Name
		local lower = string.lower(n)
		if string.sub(n, 1, 4) == "Ore_" then
			return true
		end
		-- Basic rock form (player often stands on it; little/no VFX in dumps)
		if lower == "rock" or lower == "ore" or lower == "stone" then
			return true
		end
		if string.find(lower, "ore_", 1, true) == 1 then
			return true
		end
		return false
	end

	-- Type key for coloring: "rock" | "aurorite" | "lumite" | lower type
	function M.oreTypeKey(ore: Instance): string
		local n = ore.Name
		if string.sub(n, 1, 4) == "Ore_" then
			return string.lower(string.sub(n, 5))
		end
		return string.lower(n)
	end

	function M.oreHasGeometry(ore: Instance): boolean
		if ore:IsA("BasePart") then
			return true
		end
		for _, d in ipairs(ore:GetDescendants()) do
			if d:IsA("BasePart") then
				return true
			end
		end
		return false
	end

	function M.getOrePosition(ore: Instance): Vector3?
		if U and U.getInstancePosition then
			local p = U.getInstancePosition(ore)
			if p then
				return p
			end
		end
		if ore:IsA("Model") then
			local ok, pivot = pcall(function()
				return (ore :: Model):GetPivot()
			end)
			if ok and pivot then
				return pivot.Position
			end
		end
		if ore:IsA("BasePart") then
			return ore.Position
		end
		return nil
	end

	-- Returns list of ore host Instances (Ore_* models).
	function M.collectOres(): { Instance }
		local list = {}
		local root = M.findSpawnOreRoot()
		if not root then
			return list
		end
		for _, sp in ipairs(root:GetChildren()) do
			-- SP{n} container, or ore directly under Spawn_Ore
			if M.isOreModel(sp) and M.oreHasGeometry(sp) then
				table.insert(list, sp)
			else
				for _, child in ipairs(sp:GetChildren()) do
					if M.isOreModel(child) and M.oreHasGeometry(child) then
						table.insert(list, child)
					end
				end
			end
		end
		return list
	end

	function M.snapshotFragment(): any
		local ores = M.collectOres()
		local entries = {}
		local byType: { [string]: number } = {}
		for _, ore in ipairs(ores) do
			local key = M.oreTypeKey(ore)
			byType[key] = (byType[key] or 0) + 1
			local pos = M.getOrePosition(ore)
			table.insert(entries, {
				name = ore.Name,
				type = key,
				className = ore.ClassName,
				path = ore:GetFullName(),
				position = pos and U.vec3Table(pos) or nil,
			})
		end
		return {
			spawnPath = (function()
				local r = M.findSpawnOreRoot()
				return r and r:GetFullName() or nil
			end)(),
			count = #entries,
			byType = byType,
			ores = entries,
		}
	end

	---------------------------------------------------------------------------
	-- Colors (neon-style outlines; AlwaysOnTop = through walls)
	---------------------------------------------------------------------------

	local DEFAULT_COLORS = {
		rock = {
			fill = Color3.fromRGB(160, 160, 175),
			outline = Color3.fromRGB(220, 230, 255),
		},
		stone = {
			fill = Color3.fromRGB(160, 160, 175),
			outline = Color3.fromRGB(220, 230, 255),
		},
		aurorite = {
			fill = Color3.fromRGB(40, 160, 220),
			outline = Color3.fromRGB(80, 230, 255),
		},
		lumite = {
			fill = Color3.fromRGB(200, 170, 40),
			outline = Color3.fromRGB(255, 240, 90),
		},
		default = {
			fill = Color3.fromRGB(180, 60, 220),
			outline = Color3.fromRGB(255, 120, 255),
		},
	}

	function M.colorsForType(typeKey: string): (Color3, Color3)
		local map = C.ORE_ESP_COLORS or DEFAULT_COLORS
		local entry = map[typeKey] or map.default or DEFAULT_COLORS.default
		if typeof(entry) == "table" and entry.fill and entry.outline then
			return entry.fill, entry.outline
		end
		-- config may store plain Color3 pairs as { fill = ..., outline = ... }
		return DEFAULT_COLORS.default.fill, DEFAULT_COLORS.default.outline
	end

	---------------------------------------------------------------------------
	-- Highlights
	---------------------------------------------------------------------------

	local function destroyHighlightOn(inst: Instance)
		local h = inst:FindFirstChild(HL_NAME)
		if h then
			h:Destroy()
		end
	end

	function M.clearAllHighlights()
		-- Active ores
		for _, ore in ipairs(M.collectOres()) do
			destroyHighlightOn(ore)
		end
		-- Orphans (mined / respawned under new instances)
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == HL_NAME then
				d:Destroy()
			end
		end
	end

	function M.ensureHighlight(ore: Instance)
		if not M.oreHasGeometry(ore) then
			destroyHighlightOn(ore)
			return
		end
		local h = ore:FindFirstChild(HL_NAME)
		if not (h and h:IsA("Highlight")) then
			if h then
				h:Destroy()
			end
			h = Instance.new("Highlight")
			h.Name = HL_NAME
			h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			h.Parent = ore
		end
		local hl = h :: Highlight
		hl.Adornee = ore
		hl.Enabled = true
		local typeKey = M.oreTypeKey(ore)
		local fill, outline = M.colorsForType(typeKey)
		hl.FillColor = fill
		hl.OutlineColor = outline
		hl.FillTransparency = C.ORE_ESP_FILL_T or 0.65
		hl.OutlineTransparency = C.ORE_ESP_OUTLINE_T or 0.0
	end

	function M.refreshHighlights(): (number, { [string]: number })
		local ores = M.collectOres()
		local live: { [Instance]: boolean } = {}
		local byType: { [string]: number } = {}
		for _, ore in ipairs(ores) do
			live[ore] = true
			local key = M.oreTypeKey(ore)
			byType[key] = (byType[key] or 0) + 1
			M.ensureHighlight(ore)
		end
		-- Drop highlights on ores that despawned (handled by clear orphans periodically)
		-- Light orphan sweep under Spawn_Ore only
		local root = M.findSpawnOreRoot()
		if root then
			for _, d in ipairs(root:GetDescendants()) do
				if d.Name == HL_NAME and d:IsA("Highlight") then
					local host = d.Parent
					if host and not live[host] then
						d:Destroy()
					end
				end
			end
		end
		return #ores, byType
	end

	---------------------------------------------------------------------------
	-- Toggle / maintain
	---------------------------------------------------------------------------

	local function formatByType(byType: { [string]: number }): string
		local parts = {}
		for k, v in pairs(byType) do
			table.insert(parts, string.format("%s=%d", k, v))
		end
		table.sort(parts)
		if #parts == 0 then
			return "none"
		end
		return table.concat(parts, " ")
	end

	local function maintainLoop()
		while S.oreEspEnabled do
			pcall(function()
				M.refreshHighlights()
			end)
			task.wait(C.ORE_ESP_INTERVAL or MAINTAIN)
		end
		S.oreEspThread = nil
	end

	function M.setOreEspEnabled(on: boolean)
		S.oreEspEnabled = on and true or false
		refreshLabel()
		if S.oreEspEnabled then
			local n, byType = M.refreshHighlights()
			setStatus(string.format("Ore ESP ON — %d ores (%s)", n, formatByType(byType)))
			if not S.oreEspThread then
				S.oreEspThread = task.spawn(maintainLoop)
			end
		else
			M.clearAllHighlights()
			setStatus("Ore ESP OFF")
		end
	end

	function M.toggleOreEsp()
		M.setOreEspEnabled(not S.oreEspEnabled)
	end

	return M
end

-- portal_mage/mesh_outline.lua — dev Outline Mesh (verify dump coverage)
--
-- Through-wall neon highlights using the same filters as dumpWorldMesh:
--   lime  = floor (BasePart slabs + under-feet hits)
--   cyan  = canCollide solid (walls/props)
--   amber = visual non-collide structure
--   red   = barrier / InvisibleWall
--   green tiles = Terrain ground samples (outdoor walk surface is often Terrain)
--
-- Range uses closest-point on OBB (large floors aren't missed when center is far).
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local M = {}

	local HL_NAME = "PortalMage_MeshOutline"
	local TERRAIN_FOLDER = "PortalMage_TerrainFloorOutline"
	local MAINTAIN = 1.0

	local function setStatus(t: string)
		if U and U.setStatus then
			U.setStatus(t)
		end
	end

	local function refreshLabel()
		if S.ui and S.ui.setMeshOutlineLabel then
			S.ui.setMeshOutlineLabel(S.meshOutlineEnabled == true)
		end
	end

	---------------------------------------------------------------------------
	-- Map fingerprint (foundation for future Save Map uniqueness)
	---------------------------------------------------------------------------

	function M.getMapFingerprint(): any
		local player = Players.LocalPlayer
		local pos = U.getLivePlayerVector and U.getLivePlayerVector() or nil
		local zoneName: string? = nil
		local zonePath: string? = nil
		pcall(function()
			local zones = workspace:FindFirstChild("Zones")
			if not zones or not pos then
				return
			end
			local bestDist = math.huge
			for _, z in ipairs(zones:GetDescendants()) do
				if z:IsA("BasePart") then
					local half = z.Size * 0.5
					local lp = z.CFrame:PointToObjectSpace(pos)
					local inside = math.abs(lp.X) <= half.X
						and math.abs(lp.Y) <= half.Y
						and math.abs(lp.Z) <= half.Z
					local d = (z.Position - pos).Magnitude
					if inside or d < bestDist then
						bestDist = if inside then 0 else d
						zoneName = z.Name
						zonePath = z:GetFullName()
						if inside then
							break
						end
					end
				end
			end
		end)
		local mapsHint = nil
		pcall(function()
			local maps = workspace:FindFirstChild("Maps")
			if maps then
				local kids = {}
				for _, ch in ipairs(maps:GetChildren()) do
					table.insert(kids, ch.Name)
				end
				table.sort(kids)
				mapsHint = table.concat(kids, ",")
			end
		end)
		local placeId = game.PlaceId
		local name = zoneName or ("place_" .. tostring(placeId))
		local seed = string.format("%s|%s|%s", name, tostring(placeId), mapsHint or "")
		local hash = 2166136261
		for i = 1, #seed do
			hash = (hash * 16777619 + string.byte(seed, i) * 131) % 4294967296
		end
		return {
			name = name,
			hash = string.format("%08x", hash),
			placeId = placeId,
			zonePath = zonePath,
			mapsChildren = mapsHint,
			playerPosition = pos and U.vec3Table(pos) or nil,
			playerName = player and player.Name or nil,
		}
	end

	---------------------------------------------------------------------------
	-- Colors
	---------------------------------------------------------------------------

	local COLORS = {
		floor = {
			fill = Color3.fromRGB(60, 220, 90),
			outline = Color3.fromRGB(120, 255, 140),
		},
		collide = {
			fill = Color3.fromRGB(40, 180, 220),
			outline = Color3.fromRGB(80, 240, 255),
		},
		visual = {
			fill = Color3.fromRGB(200, 140, 40),
			outline = Color3.fromRGB(255, 200, 80),
		},
		barrier = {
			fill = Color3.fromRGB(180, 40, 60),
			outline = Color3.fromRGB(255, 80, 100),
		},
		terrain = {
			fill = Color3.fromRGB(40, 200, 70),
			outline = Color3.fromRGB(100, 255, 130),
		},
	}

	local function colorsForKind(kind: string): (Color3, Color3)
		local c = COLORS[kind] or COLORS.collide
		return c.fill, c.outline
	end

	---------------------------------------------------------------------------
	-- Geometry helpers
	---------------------------------------------------------------------------

	-- Closest-point distance to part OBB (so large floors count when you're on the edge).
	local function distToPart(playerPos: Vector3, bp: BasePart): number
		local cf = bp.CFrame
		local half = bp.Size * 0.5
		local lp = cf:PointToObjectSpace(playerPos)
		local cx = math.clamp(lp.X, -half.X, half.X)
		local cy = math.clamp(lp.Y, -half.Y, half.Y)
		local cz = math.clamp(lp.Z, -half.Z, half.Z)
		local closest = cf:PointToWorldSpace(Vector3.new(cx, cy, cz))
		return (closest - playerPos).Magnitude
	end

	local function raycastParamsExcludeCharsAndBarriers(): RaycastParams
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local exclude: { Instance } = {}
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr.Character then
				table.insert(exclude, plr.Character)
			end
		end
		pcall(function()
			local maps = workspace:FindFirstChild("Maps")
			local inv = maps and maps:FindFirstChild("InvisibleWall")
			if inv then
				table.insert(exclude, inv)
			end
		end)
		-- Don't hit our own terrain tiles
		local folder = workspace:FindFirstChild(TERRAIN_FOLDER)
		if folder then
			table.insert(exclude, folder)
		end
		params.FilterDescendantsInstances = exclude
		params.IgnoreWater = false
		return params
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

	function M.clearTerrainFloorVis()
		local folder = workspace:FindFirstChild(TERRAIN_FOLDER)
		if folder then
			folder:Destroy()
		end
	end

	function M.clearAllHighlights()
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == HL_NAME then
				d:Destroy()
			end
		end
		M.clearTerrainFloorVis()
	end

	function M.ensureHighlight(bp: BasePart, kind: string)
		local h = bp:FindFirstChild(HL_NAME)
		if not (h and h:IsA("Highlight")) then
			if h then
				h:Destroy()
			end
			h = Instance.new("Highlight")
			h.Name = HL_NAME
			h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			h.Parent = bp
		end
		local hl = h :: Highlight
		hl.Adornee = bp
		hl.Enabled = true
		local fill, outline = colorsForKind(kind)
		hl.FillColor = fill
		hl.OutlineColor = outline
		-- Floors: slightly more solid so thin slabs read clearly
		if kind == "floor" then
			hl.FillTransparency = math.min(C.MESH_OUTLINE_FILL_T or 0.75, 0.55)
			hl.OutlineTransparency = 0
		else
			hl.FillTransparency = C.MESH_OUTLINE_FILL_T or 0.75
			hl.OutlineTransparency = C.MESH_OUTLINE_OUTLINE_T or 0.05
		end
	end

	local function classify(bp: BasePart): string?
		if S.Dump and S.Dump.classifyMeshExportPart then
			return S.Dump.classifyMeshExportPart(bp)
		end
		if bp.CanCollide then
			return "collide"
		end
		return nil
	end

	---------------------------------------------------------------------------
	-- Terrain floor sample grid (outdoor ground)
	---------------------------------------------------------------------------

	function M.updateTerrainFloorVis(playerPos: Vector3): (number, number)
		if C.MESH_OUTLINE_TERRAIN_FLOOR == false then
			M.clearTerrainFloorVis()
			return 0, 0
		end
		local radius = C.MESH_OUTLINE_TERRAIN_RADIUS or 48
		local step = C.MESH_OUTLINE_TERRAIN_STEP or 4
		local cell = C.MESH_OUTLINE_TERRAIN_CELL or 3.6
		local params = raycastParamsExcludeCharsAndBarriers()

		local folder = workspace:FindFirstChild(TERRAIN_FOLDER)
		if not (folder and folder:IsA("Folder")) then
			if folder then
				folder:Destroy()
			end
			folder = Instance.new("Folder")
			folder.Name = TERRAIN_FOLDER
			folder.Parent = workspace
		end

		local hits = {}
		local partFloorHits = 0
		local terrainHits = 0
		for ox = -radius, radius, step do
			for oz = -radius, radius, step do
				local origin = Vector3.new(playerPos.X + ox, playerPos.Y + 12, playerPos.Z + oz)
				local result = workspace:Raycast(origin, Vector3.new(0, -80, 0), params)
				if result then
					if result.Instance:IsA("Terrain") then
						terrainHits += 1
						table.insert(hits, {
							pos = result.Position,
							normal = result.Normal,
							material = result.Material,
						})
					elseif result.Instance:IsA("BasePart") then
						partFloorHits += 1
						-- Force outline whatever we're standing/walking on
						M.ensureHighlight(result.Instance :: BasePart, "floor")
					end
				end
			end
		end

		-- Rebuild tiles (simple: clear + recreate — radius 48 / step 4 ≈ 25² = 625 max)
		for _, ch in ipairs(folder:GetChildren()) do
			ch:Destroy()
		end
		local fill, outline = colorsForKind("terrain")
		for i, h in ipairs(hits) do
			local p = Instance.new("Part")
			p.Name = "TerrainFloorCell_" .. tostring(i)
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.CastShadow = false
			p.Material = Enum.Material.Neon
			p.Color = fill
			p.Transparency = 0.35
			p.Size = Vector3.new(cell, 0.15, cell)
			-- Flat neon tile slightly above hit (good enough for floor coverage check)
			p.CFrame = CFrame.new(h.pos + Vector3.new(0, 0.12, 0))
			p.Parent = folder
			-- Selection outline via Highlight on cell for through-wall
			local hl = Instance.new("Highlight")
			hl.Name = HL_NAME
			hl.Adornee = p
			hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			hl.FillColor = fill
			hl.OutlineColor = outline
			hl.FillTransparency = 0.55
			hl.OutlineTransparency = 0
			hl.Parent = p
		end

		return terrainHits, partFloorHits
	end

	-- Single under-feet probe (status + guarantee)
	function M.probeStandingFloor(playerPos: Vector3): any?
		local params = raycastParamsExcludeCharsAndBarriers()
		local origin = playerPos + Vector3.new(0, 3, 0)
		local result = workspace:Raycast(origin, Vector3.new(0, -25, 0), params)
		if not result then
			return nil
		end
		local inst = result.Instance
		local info: any = {
			y = result.Position.Y,
			material = result.Material and tostring(result.Material) or nil,
			position = U.vec3Table(result.Position),
			normal = U.vec3Table(result.Normal),
			distance = result.Distance,
		}
		if inst:IsA("Terrain") then
			info.kind = "terrain"
			info.path = "Workspace.Terrain"
		elseif inst:IsA("BasePart") then
			info.kind = "part"
			info.path = inst:GetFullName()
			info.name = inst.Name
			info.className = inst.ClassName
			info.canCollide = (inst :: BasePart).CanCollide
			M.ensureHighlight(inst :: BasePart, "floor")
		else
			info.kind = inst.ClassName
			info.path = inst:GetFullName()
		end
		return info
	end

	---------------------------------------------------------------------------
	-- Main refresh
	---------------------------------------------------------------------------

	function M.refreshOutlines(): (number, { [string]: number }, number, any?)
		local range = C.MESH_OUTLINE_RANGE or 220
		local maxN = C.MESH_OUTLINE_MAX or 700
		local showBarriers = C.MESH_OUTLINE_SHOW_BARRIERS ~= false
		local playerPos = U.getLivePlayerVector and U.getLivePlayerVector() or nil

		local standing = nil
		local terrainCells, partFloorRays = 0, 0
		if playerPos then
			standing = M.probeStandingFloor(playerPos)
			terrainCells, partFloorRays = M.updateTerrainFloorVis(playerPos)
		else
			M.clearTerrainFloorVis()
		end

		local candidates = {}
		local totalClassified = 0
		local byKindAll: { [string]: number } = {
			collide = 0,
			visual = 0,
			barrier = 0,
			floor = 0,
		}

		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("BasePart") then
				local bp = d :: BasePart
				-- Skip our terrain vis tiles
				if bp.Parent and bp.Parent.Name == TERRAIN_FOLDER then
					continue
				end
				local kind = classify(bp)
				if kind then
					totalClassified += 1
					byKindAll[kind] = (byKindAll[kind] or 0) + 1
					if kind == "barrier" and not showBarriers then
						destroyHighlightOn(bp)
						continue
					end
					local dist = 0
					if playerPos then
						dist = distToPart(playerPos, bp)
						if dist > range then
							destroyHighlightOn(bp)
							continue
						end
					end
					-- Prefer floor rank when under feet
					if standing and standing.kind == "part" and standing.path == bp:GetFullName() then
						kind = "floor"
						dist = 0
					end
					table.insert(candidates, { bp = bp, kind = kind, dist = dist })
				else
					if bp:FindFirstChild(HL_NAME) then
						destroyHighlightOn(bp)
					end
				end
			end
		end

		table.sort(candidates, function(a, b)
			return a.dist < b.dist
		end)

		local shown = 0
		local byKindShown: { [string]: number } = {
			collide = 0,
			visual = 0,
			barrier = 0,
			floor = 0,
		}
		for i = 1, math.min(maxN, #candidates) do
			local c = candidates[i]
			M.ensureHighlight(c.bp, c.kind)
			shown += 1
			byKindShown[c.kind] = (byKindShown[c.kind] or 0) + 1
		end
		for i = maxN + 1, #candidates do
			destroyHighlightOn(candidates[i].bp)
		end

		byKindShown.terrain = terrainCells
		byKindAll.terrain = terrainCells
		byKindShown.partFloorRays = partFloorRays

		return shown, byKindShown, totalClassified, standing
	end

	---------------------------------------------------------------------------
	-- Toggle / maintain
	---------------------------------------------------------------------------

	local function maintainLoop()
		while S.meshOutlineEnabled do
			pcall(function()
				M.refreshOutlines()
			end)
			task.wait(C.MESH_OUTLINE_INTERVAL or MAINTAIN)
		end
		S.meshOutlineThread = nil
	end

	function M.setMeshOutlineEnabled(on: boolean)
		S.meshOutlineEnabled = on and true or false
		refreshLabel()
		if S.meshOutlineEnabled then
			local shown, byKind, total, standing = M.refreshOutlines()
			local fp = M.getMapFingerprint()
			local standLabel = "none"
			if standing then
				if standing.kind == "terrain" then
					standLabel = string.format("Terrain/%s y=%.1f", standing.material or "?", standing.y or 0)
				else
					standLabel = string.format("%s %s", standing.kind or "?", standing.name or standing.path or "?")
				end
			end
			setStatus(string.format(
				"Outline Mesh ON — %d parts (F%d C%d V%d B%d) terrainTiles=%d | feet=%s | map=%s #%s",
				shown,
				byKind.floor or 0,
				byKind.collide or 0,
				byKind.visual or 0,
				byKind.barrier or 0,
				byKind.terrain or 0,
				standLabel,
				fp.name or "?",
				fp.hash or "?"
			))
			if not S.meshOutlineThread then
				S.meshOutlineThread = task.spawn(maintainLoop)
			end
		else
			M.clearAllHighlights()
			setStatus("Outline Mesh OFF")
		end
	end

	function M.toggleMeshOutline()
		M.setMeshOutlineEnabled(not S.meshOutlineEnabled)
	end

	return M
end

-- portal_mage/nav.lua — floor-valid pathfinding + smooth navigation
--
-- Any goal is snapped to walkable floor (Terrain or CanCollide ground), then
-- reached via A* on a local floor grid and Util.walkTo (Humanoid:MoveTo).
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local M = {}

	local function cfg(key: string, default: any): any
		local v = C[key]
		if v == nil then
			return default
		end
		return v
	end

	---------------------------------------------------------------------------
	-- Raycast helpers
	---------------------------------------------------------------------------

	function M.rayParams(extraExclude: { Instance }?): RaycastParams
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
		-- Don't treat living mobs as walls for path probes
		pcall(function()
			local mobs = workspace:FindFirstChild("Mobs")
			if mobs then
				table.insert(exclude, mobs)
			end
		end)
		-- Ignore our own debug outline tiles
		pcall(function()
			local folder = workspace:FindFirstChild("PortalMage_TerrainFloorOutline")
			if folder then
				table.insert(exclude, folder)
			end
		end)
		if extraExclude then
			for _, inst in ipairs(extraExclude) do
				table.insert(exclude, inst)
			end
		end
		params.FilterDescendantsInstances = exclude
		params.IgnoreWater = false
		return params
	end

	local function isBarrierInstance(inst: Instance): boolean
		local path = inst:GetFullName()
		if string.find(path, "InvisibleWall", 1, true) then
			return true
		end
		local n = string.lower(inst.Name)
		if string.find(n, "invisible wall", 1, true) or string.find(n, "invisiblewall", 1, true) then
			return true
		end
		return false
	end

	-- Horizontal free distance to the nearest *wall-like* surface (not floor).
	-- Returns min free studs across compass probes (capped at probe length).
	function M.wallClearance(pos: Vector3): number
		local probe = cfg("NAV_WALL_PROBE", 8)
		local dirs = cfg("NAV_WALL_DIRS", 8)
		local minNy = cfg("NAV_MIN_NORMAL_Y", 0.45)
		local heights = cfg("NAV_BODY_HEIGHTS", { 1.2, 2.5, 4.5 })
		local params = M.rayParams()
		local minFree = probe

		for i = 0, dirs - 1 do
			local ang = (i / dirs) * math.pi * 2
			local dir = Vector3.new(math.sin(ang), 0, math.cos(ang))
			for _, hy in ipairs(heights) do
				local origin = pos + Vector3.new(0, hy, 0)
				local hit = workspace:Raycast(origin, dir * probe, params)
				if hit and hit.Instance and not isBarrierInstance(hit.Instance) then
					-- Floor/ground normals face up; walls face mostly sideways
					if hit.Normal.Y < minNy then
						if hit.Distance < minFree then
							minFree = hit.Distance
						end
					end
				elseif hit and hit.Instance and isBarrierInstance(hit.Instance) then
					-- Invisible walls still block kiting
					if hit.Distance < minFree then
						minFree = hit.Distance
					end
				end
			end
		end
		return minFree
	end

	function M.hasWallClearance(pos: Vector3): boolean
		local need = cfg("NAV_WALL_CLEARANCE", 2.75)
		return M.wallClearance(pos) + 1e-3 >= need
	end

	-- Sample walkable floor under world XZ.
	-- Returns nil if void / too steep / barrier / pinched against walls (when requireClear).
	function M.sampleFloor(x: number, z: number, yHint: number?, opts: any?): any?
		opts = opts or {}
		local requireClear = opts.requireClear
		if requireClear == nil then
			requireClear = true -- default: reject wall-pinched points
		end
		local rayUp = cfg("NAV_RAY_UP", 50)
		local rayDown = cfg("NAV_RAY_DOWN", 140)
		local minNy = cfg("NAV_MIN_NORMAL_Y", 0.45)
		local y0 = yHint or 50
		local origin = Vector3.new(x, y0 + rayUp, z)
		local params = M.rayParams()
		local hit = workspace:Raycast(origin, Vector3.new(0, -(rayUp + rayDown), 0), params)
		if not hit then
			return nil
		end
		if hit.Normal.Y < minNy then
			return nil -- hit a non-floor surface (wall / cliff face)
		end
		local inst = hit.Instance
		if not inst then
			return nil
		end
		if isBarrierInstance(inst) then
			return nil
		end
		local okSurface = false
		if inst:IsA("Terrain") then
			okSurface = true
		elseif inst:IsA("BasePart") then
			local bp = inst :: BasePart
			if bp.CanCollide then
				okSurface = true
			end
		end
		if not okSurface then
			return nil
		end
		local pos = hit.Position + hit.Normal.Unit * 0.15
		local clear = M.wallClearance(pos)
		local need = cfg("NAV_WALL_CLEARANCE", 2.75)
		if requireClear and clear + 1e-3 < need then
			return nil -- would stand against a wall / in a corner
		end
		return {
			pos = pos,
			normal = hit.Normal,
			material = hit.Material and tostring(hit.Material) or nil,
			instance = inst,
			path = inst:GetFullName(),
			isTerrain = inst:IsA("Terrain"),
			distance = hit.Distance,
			wallClearance = clear,
		}
	end

	function M.sampleFloorAt(world: Vector3, opts: any?): any?
		return M.sampleFloor(world.X, world.Z, world.Y, opts)
	end

	function M.isWalkablePos(world: Vector3): boolean
		local s = M.sampleFloorAt(world)
		if not s then
			return false
		end
		if math.abs(s.pos.Y - world.Y) > cfg("NAV_MAX_SNAP_Y", 10) then
			return false
		end
		return true
	end

	---------------------------------------------------------------------------
	-- Grid pathfinding (A*) on floor samples
	---------------------------------------------------------------------------

	local function keyXZ(ix: number, iz: number): string
		return tostring(ix) .. ":" .. tostring(iz)
	end

	local function heuristic(ax: number, az: number, bx: number, bz: number): number
		local dx = ax - bx
		local dz = az - bz
		return math.sqrt(dx * dx + dz * dz)
	end

	-- Build path of world Vector3 from `from` to `to` on a local floor grid.
	-- Returns { Vector3, ... } including goal (snapped), or nil.
	function M.findPath(from: Vector3, to: Vector3, opts: any?): { Vector3 }?
		opts = opts or {}
		local cell = opts.cell or cfg("NAV_CELL", 4)
		local maxCells = opts.maxCells or cfg("NAV_MAX_CELLS", 28) -- radius in cells
		local maxStepY = opts.maxStepY or cfg("NAV_MAX_STEP_Y", 7)
		local yHint = math.max(from.Y, to.Y)

		local goalSample = M.sampleFloor(to.X, to.Z, to.Y)
		if not goalSample then
			-- Try a few jittered samples around goal (still require wall clearance)
			local found = nil
			for _, j in ipairs({
				{ 0, 0 },
				{ cell, 0 },
				{ -cell, 0 },
				{ 0, cell },
				{ 0, -cell },
				{ cell, cell },
				{ -cell, -cell },
				{ cell * 2, 0 },
				{ -cell * 2, 0 },
				{ 0, cell * 2 },
				{ 0, -cell * 2 },
			}) do
				found = M.sampleFloor(to.X + j[1], to.Z + j[2], to.Y)
				if found then
					break
				end
			end
			goalSample = found
		end
		if not goalSample then
			return nil
		end
		-- Start may be wall-pinched (we're stuck) — allow sampling without clear to leave
		local startSample = M.sampleFloor(from.X, from.Z, from.Y, { requireClear = false })
			or { pos = from, normal = Vector3.yAxis, wallClearance = 0 }

		-- Short path: if close and clear-ish, go direct
		local directDist = (Vector3.new(startSample.pos.X, 0, startSample.pos.Z)
			- Vector3.new(goalSample.pos.X, 0, goalSample.pos.Z)).Magnitude
		if directDist <= cell * 1.25 then
			return { goalSample.pos }
		end

		-- Grid origin at start, indices relative
		local function worldToCell(wx: number, wz: number): (number, number)
			local ix = math.floor((wx - startSample.pos.X) / cell + 0.5)
			local iz = math.floor((wz - startSample.pos.Z) / cell + 0.5)
			return ix, iz
		end
		local function cellToWorld(ix: number, iz: number): (number, number)
			return startSample.pos.X + ix * cell, startSample.pos.Z + iz * cell
		end

		local gix, giz = worldToCell(goalSample.pos.X, goalSample.pos.Z)
		-- Clamp goal cell into searchable radius
		gix = math.clamp(gix, -maxCells, maxCells)
		giz = math.clamp(giz, -maxCells, maxCells)

		local sampleCache: { [string]: any } = {}
		local function getSample(ix: number, iz: number): any?
			local k = keyXZ(ix, iz)
			if sampleCache[k] ~= nil then
				local c = sampleCache[k]
				return if c == false then nil else c
			end
			if math.abs(ix) > maxCells or math.abs(iz) > maxCells then
				sampleCache[k] = false
				return nil
			end
			local wx, wz = cellToWorld(ix, iz)
			-- Path nodes must not sit against walls (avoids kite-into-corner)
			local s = M.sampleFloor(wx, wz, yHint, { requireClear = true })
			if s then
				sampleCache[k] = s
				return s
			end
			sampleCache[k] = false
			return nil
		end

		-- Force start/goal into cache
		sampleCache[keyXZ(0, 0)] = startSample
		sampleCache[keyXZ(gix, giz)] = goalSample

		-- A*
		local open: { { ix: number, iz: number, f: number } } = {
			{ ix = 0, iz = 0, f = heuristic(0, 0, gix, giz) },
		}
		local cameFrom: { [string]: string } = {}
		local gScore: { [string]: number } = { [keyXZ(0, 0)] = 0 }
		local closed: { [string]: boolean } = {}
		local neighbors = {
			{ 1, 0 },
			{ -1, 0 },
			{ 0, 1 },
			{ 0, -1 },
			{ 1, 1 },
			{ 1, -1 },
			{ -1, 1 },
			{ -1, -1 },
		}

		local expanded = 0
		local maxExpand = cfg("NAV_MAX_EXPAND", 900)

		while #open > 0 and expanded < maxExpand do
			-- pop lowest f
			local bestI = 1
			for i = 2, #open do
				if open[i].f < open[bestI].f then
					bestI = i
				end
			end
			local cur = table.remove(open, bestI)
			local ck = keyXZ(cur.ix, cur.iz)
			if closed[ck] then
				continue
			end
			closed[ck] = true
			expanded += 1

			if cur.ix == gix and cur.iz == giz then
				-- reconstruct
				local pathKeys = { ck }
				while cameFrom[pathKeys[#pathKeys]] do
					table.insert(pathKeys, cameFrom[pathKeys[#pathKeys]])
				end
				-- reverse
				local worldPath = {}
				for i = #pathKeys, 1, -1 do
					local a, b = string.match(pathKeys[i], "^(%-?%d+):(%-?%d+)$")
					local ix, iz = tonumber(a), tonumber(b)
					if ix and iz then
						local s = getSample(ix, iz)
						if s then
							table.insert(worldPath, s.pos)
						end
					end
				end
				-- ensure exact goal
				if #worldPath == 0
					or (worldPath[#worldPath] - goalSample.pos).Magnitude > 0.5
				then
					table.insert(worldPath, goalSample.pos)
				end
				return worldPath
			end

			local curSample = getSample(cur.ix, cur.iz)
			if not curSample then
				continue
			end
			local curG = gScore[ck] or math.huge

			for _, d in ipairs(neighbors) do
				local nix, niz = cur.ix + d[1], cur.iz + d[2]
				if math.abs(nix) > maxCells or math.abs(niz) > maxCells then
					continue
				end
				local nk = keyXZ(nix, niz)
				if closed[nk] then
					continue
				end
				local ns = getSample(nix, niz)
				if not ns then
					continue
				end
				-- Height continuity
				if math.abs(ns.pos.Y - curSample.pos.Y) > maxStepY then
					continue
				end
				-- Block edge if a wall sits between cells (horizontal LOS)
				do
					local mid = (curSample.pos + ns.pos) * 0.5
					local midH = mid + Vector3.new(0, 2.5, 0)
					local delta = ns.pos - curSample.pos
					local flat = Vector3.new(delta.X, 0, delta.Z)
					if flat.Magnitude > 0.5 then
						local losHit = workspace:Raycast(midH - flat.Unit * 0.2, flat.Unit * (flat.Magnitude + 0.4), M.rayParams())
						if losHit and losHit.Normal.Y < cfg("NAV_MIN_NORMAL_Y", 0.45) then
							continue
						end
					end
				end
				local stepCost = heuristic(cur.ix, cur.iz, nix, niz) * cell
				-- Prefer open space slightly (higher wall clearance = lower cost)
				local openBonus = 0
				if ns.wallClearance then
					openBonus = math.max(0, 3 - (ns.wallClearance or 0)) * 0.35
				end
				local tent = curG + stepCost + openBonus
				if tent < (gScore[nk] or math.huge) then
					gScore[nk] = tent
					cameFrom[nk] = ck
					local f = tent + heuristic(nix, niz, gix, giz) * cell
					table.insert(open, { ix = nix, iz = niz, f = f })
				end
			end

			if expanded % 80 == 0 then
				task.wait()
			end
		end

		-- Fallback: try direct to goal floor even if A* failed
		return { goalSample.pos }
	end

	---------------------------------------------------------------------------
	-- Goal helpers (kill-aura / kite)
	---------------------------------------------------------------------------

	-- Best stand point near `target` at ~idealRange (floor + wall clearance).
	function M.standPointNear(
		target: Vector3,
		idealRange: number,
		opts: any?
	): Vector3?
		opts = opts or {}
		local from: Vector3? = opts.from
		local samples = opts.samples or cfg("NAV_RING_SAMPLES", 16)
		local sticky = opts.sticky or 0
		local minDist = opts.minDist or 0

		if from then
			local dNow = (from - target).Magnitude
			if sticky > 0 and math.abs(dNow - idealRange) <= sticky then
				local feet = M.sampleFloorAt(from, { requireClear = true })
				if feet then
					return feet.pos
				end
				-- Stuck against a wall: force re-pick an open stand point
			end
		end

		local best: Vector3? = nil
		local bestScore = math.huge
		local baseAng = 0
		if from then
			baseAng = math.atan2(from.X - target.X, from.Z - target.Z)
		end

		for i = 0, samples - 1 do
			local ang = baseAng + (i / samples) * math.pi * 2
			for _, rScale in ipairs({ 1.0, 0.9, 1.1, 0.8, 1.2 }) do
				local r = idealRange * rScale
				local x = target.X + math.sin(ang) * r
				local z = target.Z + math.cos(ang) * r
				local s = M.sampleFloor(x, z, target.Y, { requireClear = true })
				if s then
					local d = (s.pos - target).Magnitude
					if minDist > 0 and d < minDist * 0.9 then
						continue
					end
					local rangeErr = math.abs(d - idealRange)
					local moveCost = 0
					if from then
						moveCost = (s.pos - from).Magnitude * 0.04
					end
					-- Prefer more open space (anti-corner for kiting)
					local wallPen = math.max(0, 6 - (s.wallClearance or 0)) * 0.8
					local score = rangeErr + moveCost + wallPen
					if score < bestScore then
						bestScore = score
						best = s.pos
					end
				end
			end
		end
		return best
	end

	function M.randomFloorNear(center: Vector3, minR: number, maxR: number): Vector3?
		for _ = 1, 32 do
			local ang = math.random() * math.pi * 2
			local r = minR + math.random() * math.max(0.1, maxR - minR)
			local x = center.X + math.sin(ang) * r
			local z = center.Z + math.cos(ang) * r
			local s = M.sampleFloor(x, z, center.Y, { requireClear = true })
			if s then
				return s.pos
			end
		end
		return nil
	end

	---------------------------------------------------------------------------
	-- Execute path with smooth movement
	---------------------------------------------------------------------------

	-- Walk along path with Util.walkTo. Returns false if cancelled / hard fail.
	function M.followPath(path: { Vector3 }, opts: any?): boolean
		opts = opts or {}
		if not path or #path == 0 then
			return true
		end
		local requireWalking = opts.requireWalking == true
		local lookAt = opts.lookAt
		local arrive = opts.arriveStuds or cfg("NAV_ARRIVE_STUDS", C.SMOOTH_WALK_ARRIVE_STUDS or 2.5)

		for i, wp in ipairs(path) do
			if requireWalking and not S.walking then
				return false
			end
			-- Skip intermediate points if already past them
			local playerPos = U.getLivePlayerVector and U.getLivePlayerVector()
			if playerPos and i < #path then
				local flat = Vector3.new(playerPos.X - wp.X, 0, playerPos.Z - wp.Z).Magnitude
				if flat <= arrive then
					continue
				end
			end
			local ok = U.walkTo(wp.X, wp.Y, wp.Z, {
				silent = true,
				lookAt = lookAt,
				softTurn = opts.softTurn == true and i == 1,
				requireWalking = requireWalking,
				snapOnTimeout = opts.snapOnTimeout == true, -- default off (no teleport thrash)
				arriveStuds = arrive,
				timeout = opts.timeout or C.SMOOTH_WALK_TIMEOUT or 3.0,
				useMoveKeys = if opts.useMoveKeys == nil then true else opts.useMoveKeys,
			})
			if not ok then
				return false
			end
		end
		return true
	end

	-- True if horizontal walk from→to is not blocked by a wall-like surface.
	function M.hasClearWalk(from: Vector3, to: Vector3): boolean
		local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
		local dist = flat.Magnitude
		if dist < 0.5 then
			return true
		end
		local dir = flat.Unit
		local params = M.rayParams()
		local minNy = cfg("NAV_MIN_NORMAL_Y", 0.45)
		for _, hy in ipairs({ 1.2, 2.5, 4.0 }) do
			local origin = from + Vector3.new(0, hy, 0)
			local hit = workspace:Raycast(origin, dir * dist, params)
			if hit and hit.Instance then
				if isBarrierInstance(hit.Instance) or hit.Normal.Y < minNy then
					return false
				end
			end
		end
		return true
	end

	---------------------------------------------------------------------------
	-- A* path visualization (toggle via Path Viz button)
	---------------------------------------------------------------------------

	local PATH_VIZ_FOLDER = "PortalMage_PathViz"
	local PATH_VIZ_COLOR = Color3.fromRGB(80, 200, 255)
	local PATH_VIZ_NODE = Color3.fromRGB(255, 220, 80)

	function M.clearPathViz()
		pcall(function()
			if S.pathVizFolder and S.pathVizFolder.Parent then
				S.pathVizFolder:Destroy()
			end
		end)
		pcall(function()
			local f = workspace:FindFirstChild(PATH_VIZ_FOLDER)
			if f then
				f:Destroy()
			end
		end)
		S.pathVizFolder = nil
	end

	local function ensurePathVizFolder(): Folder
		local f = S.pathVizFolder
		if f and f.Parent then
			return f :: Folder
		end
		f = workspace:FindFirstChild(PATH_VIZ_FOLDER)
		if not (f and f:IsA("Folder")) then
			f = Instance.new("Folder")
			f.Name = PATH_VIZ_FOLDER
			f.Parent = workspace
		end
		S.pathVizFolder = f
		return f :: Folder
	end

	local function styleVizPart(p: BasePart, color: Color3)
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = color
		p.Transparency = 0.15
	end

	-- Draw path polyline: amber nodes + cyan segment cylinders (X-axis = segment).
	function M.showPathViz(points: { Vector3 }?, tag: string?)
		if not S.pathVizEnabled then
			return
		end
		if not points or #points == 0 then
			M.clearPathViz()
			return
		end
		local folder = ensurePathVizFolder()
		-- Rebuild clean (simple, rare — only on new A* lock)
		for _, ch in ipairs(folder:GetChildren()) do
			ch:Destroy()
		end
		local label = Instance.new("StringValue")
		label.Name = "Tag"
		label.Value = tag or "path"
		label.Parent = folder

		for i, pt in ipairs(points) do
			local node = Instance.new("Part")
			node.Name = string.format("N%02d", i)
			node.Shape = Enum.PartType.Ball
			node.Size = Vector3.new(0.55, 0.55, 0.55)
			styleVizPart(node, if i == 1 then Color3.fromRGB(80, 255, 120) elseif i == #points then Color3.fromRGB(255, 100, 100) else PATH_VIZ_NODE)
			node.CFrame = CFrame.new(pt + Vector3.new(0, 0.4, 0))
			node.Parent = folder

			if i < #points then
				local a = pt + Vector3.new(0, 0.35, 0)
				local b = points[i + 1] + Vector3.new(0, 0.35, 0)
				local delta = b - a
				local dist = delta.Magnitude
				if dist > 0.05 then
					local seg = Instance.new("Part")
					seg.Name = string.format("S%02d", i)
					seg.Shape = Enum.PartType.Cylinder
					seg.Size = Vector3.new(dist, 0.18, 0.18)
					styleVizPart(seg, PATH_VIZ_COLOR)
					seg.CFrame = CFrame.lookAt(a + delta * 0.5, b) * CFrame.Angles(0, math.rad(90), 0)
					seg.Parent = folder
				end
			end
		end
	end

	function M.setPathVizEnabled(on: boolean)
		S.pathVizEnabled = on and true or false
		if S.ui and S.ui.setPathVizLabel then
			S.ui.setPathVizLabel(S.pathVizEnabled)
		end
		if not S.pathVizEnabled then
			M.clearPathViz()
			if U and U.setStatus then
				U.setStatus("Path Viz OFF")
			end
		else
			if U and U.setStatus then
				U.setStatus("Path Viz ON — A* routes draw cyan/amber lines")
			end
		end
	end

	function M.togglePathViz()
		M.setPathVizEnabled(not S.pathVizEnabled)
	end

	-- Snap goal to floor, pathfind, follow with smooth MoveTo.
	-- Never straight-lines through walls: A* unless hasClearWalk.
	-- opts.snapOnTimeout = false recommended for combat (avoids teleport thrash).
	-- opts.lockedPath = precomputed path to follow (skip findPath — stick to lock).
	function M.goTo(goal: Vector3, opts: any?): boolean
		opts = opts or {}
		local playerPos = U.getLivePlayerVector and U.getLivePlayerVector()
		if not playerPos then
			return false
		end
		local snapped = M.sampleFloor(goal.X, goal.Z, goal.Y or playerPos.Y, { requireClear = true })
			or M.sampleFloor(goal.X, goal.Z, goal.Y or playerPos.Y, { requireClear = false })
		if not snapped then
			snapped = { pos = Vector3.new(goal.X, playerPos.Y, goal.Z) }
		end
		local flat = Vector3.new(playerPos.X - snapped.pos.X, 0, playerPos.Z - snapped.pos.Z).Magnitude
		if flat <= (opts.arriveStuds or cfg("NAV_ARRIVE_STUDS", 2.5)) then
			return true
		end
		-- forceDirect: kite / panic step — NEVER run A* (was freezing reverse kite)
		if opts.forceDirect == true then
			return U.walkTo(snapped.pos.X, snapped.pos.Y, snapped.pos.Z, {
				silent = true,
				lookAt = opts.lookAt,
				requireWalking = opts.requireWalking == true,
				snapOnTimeout = false,
				arriveStuds = opts.arriveStuds,
				timeout = opts.timeout or 1.0,
				useMoveKeys = if opts.useMoveKeys == nil then true else opts.useMoveKeys,
			})
		end
		-- Pre-locked path: stick to it (do not recompute A*)
		if opts.lockedPath and type(opts.lockedPath) == "table" and #opts.lockedPath > 0 then
			if S.pathVizEnabled then
				M.showPathViz(opts.lockedPath, "locked")
			end
			if opts.snapOnTimeout == nil then
				opts.snapOnTimeout = false
			end
			return M.followPath(opts.lockedPath, opts)
		end
		-- Direct only when LOS is clear (else walls)
		local canDirect = opts.direct ~= false
			and flat <= (opts.directDist or 18)
			and M.hasClearWalk(playerPos, snapped.pos)
		if canDirect then
			if S.pathVizEnabled then
				M.showPathViz({ playerPos, snapped.pos }, "direct")
			end
			return U.walkTo(snapped.pos.X, snapped.pos.Y, snapped.pos.Z, {
				silent = true,
				lookAt = opts.lookAt,
				requireWalking = opts.requireWalking == true,
				snapOnTimeout = opts.snapOnTimeout == true,
				arriveStuds = opts.arriveStuds,
				timeout = opts.timeout or C.SMOOTH_WALK_TIMEOUT or 3.0,
				useMoveKeys = if opts.useMoveKeys == nil then true else opts.useMoveKeys,
			})
		end
		local path = M.findPath(playerPos, snapped.pos, opts)
		if not path or #path == 0 then
			path = { snapped.pos }
		end
		if S.pathVizEnabled then
			M.showPathViz(path, "astar")
		end
		if opts.snapOnTimeout == nil then
			opts.snapOnTimeout = false
		end
		return M.followPath(path, opts)
	end

	return M
end



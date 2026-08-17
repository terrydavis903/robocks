-- portal_mage/nav.lua — floor-valid pathfinding + smooth navigation
--
-- Any goal is snapped to walkable floor (Terrain or CanCollide ground), then
-- reached via A* on a local floor grid and Util.walkTo (Humanoid:MoveTo).
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local PathfindingService = game:GetService("PathfindingService")
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

	-- Market stands / tarps / tents / sails from mesh dump must never count as floors.
	-- Dump 2026-08-16_23-17-38: Buildings.Stalls (1072), Tents, Modular_Standalone_Roof_*,
	-- Mech_Sail_ClothMesh — old slab heuristic (minA<=4,horiz>=8) treated stall plates + sail
	-- cloth as walk floors so hasClearWalk returned clear on upward-ish hits.
	local function matchesKeywordList(hay: string, list: any): boolean
		if type(list) ~= "table" then
			return false
		end
		for _, kw in ipairs(list) do
			if type(kw) == "string" and kw ~= "" and string.find(hay, string.lower(kw), 1, true) then
				return true
			end
		end
		return false
	end

	local function isNamedObstacle(inst: Instance): boolean
		local path = string.lower(inst:GetFullName())
		local n = string.lower(inst.Name)
		if matchesKeywordList(path, C.NAV_OBSTACLE_PATH_KEYWORDS) then
			return true
		end
		if matchesKeywordList(n, C.NAV_OBSTACLE_NAME_KEYWORDS) then
			return true
		end
		-- Hardcoded fallbacks if config is stale/offline
		if string.find(path, ".stalls.", 1, true)
			or string.find(path, ".tents.", 1, true)
			or string.find(path, "modular_standalone_roof", 1, true)
			or string.find(path, "standalone_roof", 1, true)
			or string.find(path, "goblin_stall", 1, true)
			or string.find(path, "goblin_tent", 1, true)
			or string.find(path, "mech_sail", 1, true)
			or string.find(path, "junk_longtable", 1, true)
			or string.find(n, "clothmesh", 1, true)
			or string.find(n, "sail_cloth", 1, true)
			or (string.find(n, "tent", 1, true) and not string.find(n, "content", 1, true))
			or string.find(n, "tarp", 1, true)
			or string.find(n, "awning", 1, true)
		then
			return true
		end
		return false
	end

	-- Large thin slabs / named ground = walkable floor (not props).
	local function isWalkFloorPart(bp: BasePart): boolean
		-- Never treat market stands / tarps / tents as floor
		if isNamedObstacle(bp) then
			return false
		end
		local s = bp.Size
		local minA = math.min(s.X, s.Y, s.Z)
		local horiz = math.sqrt(s.X * s.X + s.Z * s.Z)
		-- Flat slab only — keep tight so stall "plates" (Y~3–4) are NOT floors
		local maxThick = cfg("NAV_FLOOR_SLAB_MAX_THICK", 1.25)
		local minHoriz = cfg("NAV_FLOOR_SLAB_MIN_HORIZ", 12)
		if minA <= maxThick and horiz >= minHoriz then
			return true
		end
		local n = string.lower(bp.Name)
		local path = string.lower(bp:GetFullName())
		if string.find(n, "floor", 1, true)
			or string.find(n, "ground", 1, true)
			or string.find(n, "road", 1, true)
			or string.find(n, "path", 1, true) == 1
			or string.find(n, "bridge", 1, true)
			or string.find(n, "pebble", 1, true)
			or string.find(path, "terrain", 1, true)
			or string.find(path, "landscape", 1, true)
		then
			return true
		end
		return false
	end

	-- Collide props that pathing must NOT walk through / stand on.
	-- Dump example: Stable.Animal.T1_Mount_BrownHorse.* MeshParts (CanCollide=true).
	-- Top normals look "floor-like" so Normal.Y alone is insufficient.
	local function isCollideProp(inst: Instance): boolean
		if not inst:IsA("BasePart") then
			return false
		end
		local bp = inst :: BasePart
		if not bp.CanCollide then
			return false
		end
		-- Named market / tent / tarp / sail structures always block (before floor check)
		if isNamedObstacle(bp) then
			return true
		end
		if isWalkFloorPart(bp) then
			return false
		end
		local path = string.lower(inst:GetFullName())
		local n = string.lower(inst.Name)
		-- Mounts / stable animals (world props, not live Workspace.Mounts riders only)
		if string.find(path, "mount", 1, true)
			or string.find(path, "animalspace", 1, true)
			or string.find(path, ".animal.", 1, true)
			or string.find(n, "horse", 1, true)
			or string.find(n, "saddle", 1, true)
			or string.find(n, "bridle", 1, true)
		then
			return true
		end
		-- Compact / tall collide meshes (furniture, machines, statues, crates, thin planks…)
		local s = bp.Size
		local maxd = math.max(s.X, s.Y, s.Z)
		local mind = math.min(s.X, s.Y, s.Z)
		local horiz = math.sqrt(s.X * s.X + s.Z * s.Z)
		-- mind > 0.12 catches thin planks/boards that still block the body (was 0.35)
		if maxd < 100 and mind > 0.12 then
			if s.Y >= 1.0 or (horiz < 28 and maxd >= 1.2) then
				return true
			end
		end
		return false
	end

	-- Expose for mesh outline / debug if needed
	function M.isCollideProp(inst: Instance): boolean
		return isCollideProp(inst)
	end

	function M.isWalkFloorPart(bp: BasePart): boolean
		return isWalkFloorPart(bp)
	end

	function M.isNamedObstacle(inst: Instance): boolean
		return isNamedObstacle(inst)
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
		-- Do not stand on horses / props (upward normals still collide)
		if isCollideProp(inst) then
			return nil
		end
		local okSurface = false
		if inst:IsA("Terrain") then
			okSurface = true
		elseif inst:IsA("BasePart") then
			local bp = inst :: BasePart
			if bp.CanCollide and isWalkFloorPart(bp) then
				okSurface = true
			elseif bp.CanCollide and not isCollideProp(bp) then
				-- Generic large floors not caught by slab heuristic
				local s = bp.Size
				local horiz = math.sqrt(s.X * s.X + s.Z * s.Z)
				if horiz >= 10 and math.min(s.X, s.Y, s.Z) <= 6 then
					okSurface = true
				end
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
			-- Path nodes must not sit against walls
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
	-- Execute path with smooth movement (generic; Kill Aura no longer uses this)
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

	-- True if horizontal walk from→to is not blocked by a wall-like / collide mesh.
	-- Body-width: center + left/right offsets so thin wall gaps don't look clear.
	function M.hasClearWalk(from: Vector3, to: Vector3): boolean
		local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
		local dist = flat.Magnitude
		if dist < 0.5 then
			return true
		end
		local dir = flat.Unit
		local right = Vector3.new(-dir.Z, 0, dir.X)
		local params = M.rayParams()
		local minNy = cfg("NAV_MIN_NORMAL_Y", 0.45)
		local halfW = math.max(0.6, (cfg("NAV_AGENT_RADIUS", 2) or 2) * 0.55)
		local heights = cfg("NAV_BODY_HEIGHTS", { 1.2, 2.5, 4.5 })
		local laterals = { 0, -halfW, halfW }

		local function blocksWalk(hit: RaycastResult): boolean
			local inst = hit.Instance
			if not inst then
				return false
			end
			if isBarrierInstance(inst) then
				return true
			end
			-- Stalls / tents / tarps / sails / named props always block (even "floor-like" tops)
			if isNamedObstacle(inst) and inst:IsA("BasePart") and (inst :: BasePart).CanCollide then
				return true
			end
			-- Props with CanCollide (horses, mounts, crates…) block even if top normal faces up
			if isCollideProp(inst) then
				return true
			end
			if inst:IsA("Terrain") then
				-- Flat terrain OK; steep faces block
				return hit.Normal.Y < minNy
			end
			if inst:IsA("BasePart") then
				local bp = inst :: BasePart
				if not bp.CanCollide then
					return false
				end
				-- Real floor slabs with upward normal: walk OK
				if isWalkFloorPart(bp) and hit.Normal.Y >= minNy then
					return false
				end
				-- Any other collide part (walls, mesh props, horse body sides/tops)
				return true
			end
			return hit.Normal.Y < minNy
		end

		for _, hy in ipairs(heights) do
			for _, lat in ipairs(laterals) do
				local origin = from + Vector3.new(0, hy, 0) + right * lat
				-- Slight inset so we don't start inside a wall we're already touching
				local start = origin + dir * 0.35
				local remain = math.max(0.1, dist - 0.5)
				local hit = workspace:Raycast(start, dir * remain, params)
				if hit and blocksWalk(hit) then
					return false
				end
			end
		end
		return true
	end

	-- If next waypoint is through a collide mesh, skip ahead while clear; nil if need repath.
	function M.nextClearWaypoint(from: Vector3, points: { Vector3 }, startIdx: number): number?
		if not points or #points == 0 then
			return nil
		end
		local i = math.clamp(startIdx or 1, 1, #points)
		-- Prefer first waypoint we can actually walk toward
		for j = i, #points do
			if M.hasClearWalk(from, points[j]) then
				return j
			end
		end
		return nil
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

	-- Draw path polyline: amber nodes + cyan segments. Always draws when Path Viz is ON.
	function M.showPathViz(points: { Vector3 }?, tag: string?)
		if not S.pathVizEnabled then
			return
		end
		if not points or #points == 0 then
			M.clearPathViz()
			return
		end
		local folder = ensurePathVizFolder()
		for _, ch in ipairs(folder:GetChildren()) do
			ch:Destroy()
		end
		local label = Instance.new("StringValue")
		label.Name = "Tag"
		label.Value = string.format("%s n=%d", tag or "path", #points)
		label.Parent = folder

		local lift = 1.2 -- sit above floor so it's visible outdoors
		for i, pt in ipairs(points) do
			local node = Instance.new("Part")
			node.Name = string.format("N%02d", i)
			node.Shape = Enum.PartType.Ball
			node.Size = Vector3.new(0.9, 0.9, 0.9)
			styleVizPart(node, if i == 1 then Color3.fromRGB(80, 255, 120) elseif i == #points then Color3.fromRGB(255, 80, 80) else PATH_VIZ_NODE)
			node.CFrame = CFrame.new(pt + Vector3.new(0, lift, 0))
			node.Parent = folder

			if i < #points then
				local a = pt + Vector3.new(0, lift, 0)
				local b = points[i + 1] + Vector3.new(0, lift, 0)
				local delta = b - a
				local dist = delta.Magnitude
				if dist > 0.05 then
					local seg = Instance.new("Part")
					seg.Name = string.format("S%02d", i)
					seg.Shape = Enum.PartType.Cylinder
					seg.Size = Vector3.new(dist, 0.35, 0.35)
					styleVizPart(seg, PATH_VIZ_COLOR)
					seg.CFrame = CFrame.lookAt(a + delta * 0.5, b) * CFrame.Angles(0, math.rad(90), 0)
					seg.Parent = folder
				end
			end
		end
		if U and U.setStatus and tag then
			-- brief breadcrumb in status is optional; pathing logs more detail
		end
	end

	-- Roblox PathfindingService (primary). Returns points + per-wp jump flags.
	function M.computeNativePath(from: Vector3, to: Vector3): ({ Vector3 }?, string, { boolean }?)
		local pathObj = PathfindingService:CreatePath({
			AgentRadius = C.NAV_AGENT_RADIUS or 2,
			AgentHeight = C.NAV_AGENT_HEIGHT or 5,
			AgentCanJump = C.NAV_AGENT_CAN_JUMP ~= false,
			WaypointSpacing = C.NAV_WAYPOINT_SPACING or 6,
		})
		local ok, err = pcall(function()
			pathObj:ComputeAsync(from, to)
		end)
		if not ok then
			return nil, "pfs_err:" .. tostring(err), nil
		end
		if pathObj.Status ~= Enum.PathStatus.Success then
			return nil, "pfs:" .. tostring(pathObj.Status), nil
		end
		local pts: { Vector3 } = {}
		local jumps: { boolean } = {}
		for _, wp in ipairs(pathObj:GetWaypoints()) do
			table.insert(pts, wp.Position)
			local isJump = false
			pcall(function()
				isJump = wp.Action == Enum.PathWaypointAction.Jump
			end)
			table.insert(jumps, isJump)
		end
		if #pts == 0 then
			return nil, "pfs:empty", nil
		end
		return pts, "pfs", jumps
	end

	-- True if each hop of the polyline is walkable (no wall/prop).
	-- Short PFS paths often still clip custom meshes — reject those.
	function M.pathSegmentsClear(pts: { Vector3 }?): boolean
		if not pts or #pts < 2 then
			return false
		end
		for i = 1, #pts - 1 do
			local a, b = pts[i], pts[i + 1]
			local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z).Magnitude
			if flat < 0.35 then
				continue
			end
			-- Chunk long hops so mid-segment walls are seen
			local step = 10
			if flat <= step + 1 then
				if not M.hasClearWalk(a, b) then
					return false
				end
			else
				local dir = Vector3.new(b.X - a.X, 0, b.Z - a.Z).Unit
				local traveled = 0
				local cur = a
				while traveled < flat - 0.5 do
					local chunk = math.min(step, flat - traveled)
					local nxt = cur + dir * chunk
					nxt = Vector3.new(nxt.X, cur.Y + (b.Y - a.Y) * ((traveled + chunk) / flat), nxt.Z)
					if not M.hasClearWalk(cur, nxt) then
						return false
					end
					cur = nxt
					traveled += chunk
				end
			end
		end
		return true
	end

	local function snapGoal(to: Vector3): Vector3
		local s = M.sampleFloor(to.X, to.Z, to.Y, { requireClear = false })
		if s and s.pos then
			return s.pos
		end
		return to
	end

	local function jumpsFromPts(pts: { Vector3 }): { boolean }
		local inf: { boolean } = {}
		for i, p in ipairs(pts) do
			local j = false
			if i > 1 then
				j = (p.Y - pts[i - 1].Y) >= 3.5
			end
			table.insert(inf, j)
		end
		return inf
	end

	-- Try one goal: PFS (validated) → floor A* (validated). Nil if both fail/clip.
	local function tryRoute(from: Vector3, goal: Vector3): ({ Vector3 }?, string, { boolean }?)
		local native, _nWhy, jumps = M.computeNativePath(from, goal)
		if native and #native >= 2 then
			if M.pathSegmentsClear(native) then
				return native, "pfs", jumps or {}
			end
			-- Multi-wp navmesh with one dirty far hop: still OK if first hop is clear
			if #native >= 3 and M.hasClearWalk(from, native[2]) then
				return native, "pfs:partial", jumps or {}
			end
			-- 2-wp through wall → reject (common when navmesh ignores custom stalls)
		elseif native and #native == 1 then
			if M.hasClearWalk(from, native[1]) then
				return { from, native[1] }, "pfs", { false, false }
			end
		end

		local dist = Vector3.new(goal.X - from.X, 0, goal.Z - from.Z).Magnitude
		local cell = cfg("NAV_CELL", 4)
		local maxCells = math.max(cfg("NAV_MAX_CELLS", 40), math.ceil(dist / cell) + 8)
		local custom = M.findPath(from, goal, { maxCells = maxCells, cell = cell })
		if custom and #custom >= 1 then
			local pts = if #custom == 1 then { from, custom[1] } else custom
			if M.pathSegmentsClear(pts) then
				return pts, "grid", jumpsFromPts(pts)
			end
			if #pts >= 3 and M.hasClearWalk(from, pts[2]) then
				return pts, "grid:partial", jumpsFromPts(pts)
			end
		end
		return nil, "none", nil
	end

	-- Prefer native PathfindingService; fall back to floor A*; try ring goals.
	-- NEVER return a straight line through a wall (log 00-32-43: path line thrash).
	-- Third return: jump flags aligned with points (true = Space at that node).
	function M.computePath(from: Vector3, to: Vector3): ({ Vector3 }, string, { boolean })
		local primary = snapGoal(to)

		-- Candidate stand goals: primary + ring around primary (detour around walls)
		local goals: { Vector3 } = { primary }
		local ringR = { 10, 18, 28, 38 }
		local ringN = 8
		for _, r in ipairs(ringR) do
			for i = 0, ringN - 1 do
				local ang = (i / ringN) * math.pi * 2
				local cand = Vector3.new(
					primary.X + math.cos(ang) * r,
					primary.Y,
					primary.Z + math.sin(ang) * r
				)
				table.insert(goals, snapGoal(cand))
			end
		end

		local lastWhy = "fail"
		for gi, goal in ipairs(goals) do
			local pts, kind, jumps = tryRoute(from, goal)
			if pts and #pts > 0 then
				local tag = kind
				if gi > 1 then
					tag = kind .. ":ring"
				end
				if S.pathVizEnabled then
					M.showPathViz(pts, tag)
				end
				return pts, tag, jumps or jumpsFromPts(pts)
			end
			lastWhy = kind or lastWhy
		end

		-- Last resort: straight line ONLY if actually clear
		if M.hasClearWalk(from, primary) then
			local line = { from, primary }
			if S.pathVizEnabled then
				M.showPathViz(line, "line")
			end
			return line, "line", { false, (primary.Y - from.Y) >= 3.5 }
		end

		-- Stuck: no walkable route. Return single point (pathing should drop / re-aim).
		if S.pathVizEnabled then
			M.showPathViz({ from }, "blocked:" .. tostring(lastWhy))
		end
		return { from }, "blocked", { false }
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



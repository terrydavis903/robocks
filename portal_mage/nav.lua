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

	-- Defaults for stone/walkable materials + MeshPart path keywords.
	-- Bridge dump (mesh_2026-08-17_20-06-58): GJ_Bridge plates are Plastic, TextureID empty.
	local DEFAULT_WALKABLE_MATERIALS = { "Cobblestone", "Asphalt" }
	local DEFAULT_WALKABLE_PATH_KEYWORDS = { "GJ_Bridge" }
	local GENERIC_PART_MATERIALS: { [string]: boolean } = {
		Plastic = true,
		SmoothPlastic = true,
	}

	local function walkableFilePath(): string
		return C.WALKABLE_MATERIALS_FILE or "waypoints/walkable_materials.json"
	end

	function M.normalizeMaterialName(mat: any): string?
		if mat == nil then
			return nil
		end
		local s = tostring(mat)
		s = string.gsub(s, "^Enum%.Material%.", "")
		s = string.gsub(s, "^Material%.", "")
		s = string.gsub(s, "^%s+", "")
		s = string.gsub(s, "%s+$", "")
		if s == "" or s == "nil" or s == "Air" then
			return nil
		end
		return s
	end

	local function normalizeKeyword(kw: any): string?
		if type(kw) ~= "string" then
			return nil
		end
		local s = string.gsub(kw, "^%s+", "")
		s = string.gsub(s, "%s+$", "")
		if s == "" then
			return nil
		end
		return s
	end

	local function ensureWalkableList(): { string }
		if type(C.NAV_STONE_PATH_MATERIALS) ~= "table" then
			C.NAV_STONE_PATH_MATERIALS = {}
		end
		if #C.NAV_STONE_PATH_MATERIALS == 0 then
			for _, name in ipairs(DEFAULT_WALKABLE_MATERIALS) do
				table.insert(C.NAV_STONE_PATH_MATERIALS, name)
			end
		end
		return C.NAV_STONE_PATH_MATERIALS
	end

	local function ensurePathKeywordList(): { string }
		if type(C.NAV_WALKABLE_PATH_KEYWORDS) ~= "table" then
			C.NAV_WALKABLE_PATH_KEYWORDS = {}
		end
		if #C.NAV_WALKABLE_PATH_KEYWORDS == 0 then
			for _, name in ipairs(DEFAULT_WALKABLE_PATH_KEYWORDS) do
				table.insert(C.NAV_WALKABLE_PATH_KEYWORDS, name)
			end
		end
		return C.NAV_WALKABLE_PATH_KEYWORDS
	end

	-- Stone path materials (mesh dump: Cobblestone under stone roads; Sandstone = sand).
	function M.isStonePathMaterial(mat: any): boolean
		local s = M.normalizeMaterialName(mat)
		if not s then
			return false
		end
		local list = ensureWalkableList()
		for _, name in ipairs(list) do
			if type(name) == "string" and name ~= "" and string.find(s, name, 1, true) then
				return true
			end
		end
		-- Also allow list entries that include Enum.Material. prefix
		local full = tostring(mat)
		for _, name in ipairs(list) do
			if type(name) == "string" and name ~= "" and string.find(full, name, 1, true) then
				return true
			end
		end
		return false
	end

	-- MeshPart floors often share Material=Plastic; match path/name keywords instead.
	function M.isWalkablePathKeyword(inst: Instance?): boolean
		if not inst then
			return false
		end
		local path = string.lower(inst:GetFullName())
		local name = string.lower(inst.Name)
		for _, kw in ipairs(ensurePathKeywordList()) do
			local k = string.lower(tostring(kw))
			if k ~= "" and (string.find(path, k, 1, true) or string.find(name, k, 1, true)) then
				return true
			end
		end
		return false
	end

	-- True if this floor sample should be treated as stone-path walkable.
	function M.isWalkableSurface(inst: Instance?, mat: any): boolean
		if M.isStonePathMaterial(mat) then
			return true
		end
		return M.isWalkablePathKeyword(inst)
	end

	function M.listWalkableMaterials(): { string }
		local out = {}
		for _, name in ipairs(ensureWalkableList()) do
			if type(name) == "string" and name ~= "" then
				table.insert(out, name)
			end
		end
		return out
	end

	function M.listWalkablePathKeywords(): { string }
		local out = {}
		for _, name in ipairs(ensurePathKeywordList()) do
			if type(name) == "string" and name ~= "" then
				table.insert(out, name)
			end
		end
		return out
	end

	function M.saveWalkableMaterials(): boolean
		local HttpService = S.Services.HttpService
		local path = walkableFilePath()
		local dir = C.WAYPOINT_DIR or "waypoints"
		local payload = {
			version = 2,
			updated = os.date("%Y-%m-%d_%H-%M-%S"),
			materials = M.listWalkableMaterials(),
			pathKeywords = M.listWalkablePathKeywords(),
		}
		local ok, err = pcall(function()
			if U and U.ensureDir then
				U.ensureDir(dir)
			end
			writefile(path, HttpService:JSONEncode(payload))
		end)
		if not ok then
			if U and U.setStatus then
				U.setStatus("Walkable save failed: " .. tostring(err))
			end
			return false
		end
		return true
	end

	function M.loadWalkableMaterials(): number
		local HttpService = S.Services.HttpService
		local path = walkableFilePath()
		local ok, data = pcall(function()
			if not isfile or not isfile(path) then
				return nil
			end
			return HttpService:JSONDecode(readfile(path))
		end)
		if ok and type(data) == "table" then
			if type(data.materials) == "table" and #data.materials > 0 then
				local merged = {}
				local seen: { [string]: boolean } = {}
				local function add(name: any)
					local n = M.normalizeMaterialName(name)
					if n and not seen[n] then
						seen[n] = true
						table.insert(merged, n)
					end
				end
				for _, name in ipairs(DEFAULT_WALKABLE_MATERIALS) do
					add(name)
				end
				for _, name in ipairs(data.materials) do
					add(name)
				end
				C.NAV_STONE_PATH_MATERIALS = merged
			else
				ensureWalkableList()
			end
			if type(data.pathKeywords) == "table" then
				local mergedKw = {}
				local seenKw: { [string]: boolean } = {}
				local function addKw(name: any)
					local n = normalizeKeyword(name)
					if n then
						local key = string.lower(n)
						if not seenKw[key] then
							seenKw[key] = true
							table.insert(mergedKw, n)
						end
					end
				end
				for _, name in ipairs(DEFAULT_WALKABLE_PATH_KEYWORDS) do
					addKw(name)
				end
				for _, name in ipairs(data.pathKeywords) do
					addKw(name)
				end
				C.NAV_WALKABLE_PATH_KEYWORDS = mergedKw
			else
				ensurePathKeywordList()
			end
		else
			ensureWalkableList()
			ensurePathKeywordList()
		end
		-- Always persist so GJ_Bridge lands in the file even on first load
		M.saveWalkableMaterials()
		if S.ui and S.ui.refreshWalkableMaterials then
			S.ui.refreshWalkableMaterials()
		end
		return #ensureWalkableList() + #ensurePathKeywordList()
	end

	function M.addWalkableMaterial(name: any): (boolean, string?)
		local n = M.normalizeMaterialName(name)
		if not n then
			return false, nil
		end
		if M.isStonePathMaterial(n) then
			return false, n -- already present
		end
		table.insert(ensureWalkableList(), n)
		M.saveWalkableMaterials()
		if S.ui and S.ui.refreshWalkableMaterials then
			S.ui.refreshWalkableMaterials()
		end
		return true, n
	end

	function M.addWalkablePathKeyword(kw: any): (boolean, string?)
		local n = normalizeKeyword(kw)
		if not n then
			return false, nil
		end
		local lower = string.lower(n)
		for _, existing in ipairs(ensurePathKeywordList()) do
			if string.lower(tostring(existing)) == lower then
				return false, n
			end
		end
		table.insert(ensurePathKeywordList(), n)
		M.saveWalkableMaterials()
		if S.ui and S.ui.refreshWalkableMaterials then
			S.ui.refreshWalkableMaterials()
		end
		return true, n
	end

	function M.removeWalkableMaterial(name: any): boolean
		local n = M.normalizeMaterialName(name)
		if not n then
			return false
		end
		local list = ensureWalkableList()
		for i = #list, 1, -1 do
			if M.normalizeMaterialName(list[i]) == n then
				table.remove(list, i)
			end
		end
		-- Never leave the list empty
		if #list == 0 then
			for _, d in ipairs(DEFAULT_WALKABLE_MATERIALS) do
				table.insert(list, d)
			end
		end
		M.saveWalkableMaterials()
		if S.ui and S.ui.refreshWalkableMaterials then
			S.ui.refreshWalkableMaterials()
		end
		return true
	end

	function M.resetWalkableMaterials(): number
		C.NAV_STONE_PATH_MATERIALS = {}
		for _, name in ipairs(DEFAULT_WALKABLE_MATERIALS) do
			table.insert(C.NAV_STONE_PATH_MATERIALS, name)
		end
		C.NAV_WALKABLE_PATH_KEYWORDS = {}
		for _, name in ipairs(DEFAULT_WALKABLE_PATH_KEYWORDS) do
			table.insert(C.NAV_WALKABLE_PATH_KEYWORDS, name)
		end
		M.saveWalkableMaterials()
		if S.ui and S.ui.refreshWalkableMaterials then
			S.ui.refreshWalkableMaterials()
		end
		return #C.NAV_STONE_PATH_MATERIALS + #C.NAV_WALKABLE_PATH_KEYWORDS
	end

	-- From a part path, prefer a segment containing "bridge" (e.g. GJ_Bridge).
	local function extractBridgeKeyword(path: string?): string?
		if type(path) ~= "string" or path == "" then
			return nil
		end
		for seg in string.gmatch(path, "[^%.]+") do
			if string.find(string.lower(seg), "bridge", 1, true) then
				return seg
			end
		end
		return nil
	end

	-- Probe feet and append Terrain/Mesh Material — or a path keyword for Plastic mesh floors.
	-- Returns: added(bool), token, kind ("terrain"|"part"|…), detail status
	function M.addWalkableTileFromFeet(): (boolean, string?, string?, string)
		local pos = U.getLivePlayerVector and U.getLivePlayerVector()
		if not pos then
			return false, nil, nil, "no character"
		end
		local info: any? = nil
		if S.MeshOutline and S.MeshOutline.probeStandingFloor then
			info = S.MeshOutline.probeStandingFloor(pos)
		end
		if not info then
			local sample = M.sampleFloor(pos.X, pos.Z, pos.Y, { allowAnyFloor = true, requireClear = false })
			if sample then
				info = {
					kind = sample.isTerrain and "terrain" or "part",
					material = sample.material,
					path = sample.path,
					name = sample.instance and sample.instance.Name or nil,
				}
			end
		end
		if not info then
			return false, nil, nil, "no floor under feet"
		end
		local kind = tostring(info.kind or "?")
		local mat = M.normalizeMaterialName(info.material)

		-- Generic Plastic MeshParts (bridge plates): prefer path keyword over Material
		if kind ~= "terrain" and mat and GENERIC_PART_MATERIALS[mat] then
			local kw = extractBridgeKeyword(info.path)
			if kw then
				local added, name = M.addWalkablePathKeyword(kw)
				if added then
					return true, name, kind, string.format("added path keyword %s (%s)", tostring(name), kind)
				end
				return false, name or kw, kind, string.format("already walkable path: %s", tostring(name or kw))
			end
		end

		-- Already walkable via path keyword (e.g. standing on GJ_Bridge)
		do
			local pathL = string.lower(tostring(info.path or ""))
			local nameL = string.lower(tostring(info.name or ""))
			for _, kw in ipairs(ensurePathKeywordList()) do
				local k = string.lower(tostring(kw))
				if k ~= "" and (string.find(pathL, k, 1, true) or string.find(nameL, k, 1, true)) then
					return false, kw, kind, string.format("already walkable path: %s", kw)
				end
			end
		end

		if not mat then
			return false, nil, kind, string.format("no material (%s %s)", kind, tostring(info.name or info.path or ""))
		end
		local added, name = M.addWalkableMaterial(mat)
		if added then
			return true, name, kind, string.format(
				"added %s (%s)%s",
				tostring(name),
				kind,
				info.name and (" " .. tostring(info.name)) or ""
			)
		end
		return false, name or mat, kind, string.format("already walkable: %s (%s)", tostring(name or mat), kind)
	end

	function M.stonePathOnly(): boolean
		-- Always respect config. Soft any-floor "escape" was removed — it pathing
		-- through walls/sand caused more stuck than stone islands (user 2026-08-18).
		return cfg("NAV_STONE_PATH_ONLY", true) == true
	end

	-- True if this ray hit qualifies as a standable floor for the current mode.
	local function classifyFloorHit(hit: RaycastResult, stoneOnly: boolean): (boolean, boolean, string?, boolean)
		local inst = hit.Instance
		if not inst then
			return false, false, nil, false
		end
		if isBarrierInstance(inst) then
			return false, false, nil, false
		end
		if hit.Normal.Y < cfg("NAV_MIN_NORMAL_Y", 0.45) then
			return false, false, nil, false -- wall / cliff face / underside edge
		end
		local matName = hit.Material and tostring(hit.Material) or nil
		local isTerrain = inst:IsA("Terrain")
		local walkable = M.isWalkableSurface(inst, matName)
		-- User-marked walkable mats / path keywords bypass collide-prop rejection
		-- (bridge MeshParts are Plastic and otherwise look like props).
		if not walkable and isCollideProp(inst) then
			return false, walkable, matName, isTerrain
		end

		local okSurface = false
		if stoneOnly then
			if walkable then
				if isTerrain then
					okSurface = true
				elseif inst:IsA("BasePart") then
					local bp = inst :: BasePart
					okSurface = bp.CanCollide == true
				end
			end
		elseif isTerrain then
			okSurface = true
		elseif inst:IsA("BasePart") then
			local bp = inst :: BasePart
			if bp.CanCollide and isWalkFloorPart(bp) then
				okSurface = true
			elseif bp.CanCollide and not isCollideProp(bp) then
				local s = bp.Size
				local horiz = math.sqrt(s.X * s.X + s.Z * s.Z)
				if horiz >= 10 and math.min(s.X, s.Y, s.Z) <= 6 then
					okSurface = true
				end
			end
		end
		return okSurface, walkable, matName, isTerrain
	end

	-- Sample walkable floor under world XZ.
	-- Stone-path mode: Terrain OR MeshPart floors whose Material is in the walkable list.
	-- Pierces non-walkable overhead MeshParts (mesh dump 2026-08-17_20-18-13: Goblin_Gate
	-- Plastic roofs at y~151 sit above Cobblestone Terrain at y~108 and used to steal the ray).
	function M.sampleFloor(x: number, z: number, yHint: number?, opts: any?): any?
		opts = opts or {}
		local allowAny = opts.allowAnyFloor == true
		local stoneOnly = M.stonePathOnly() and not allowAny
		local requireClear = opts.requireClear
		if requireClear == nil then
			-- Stone roads: no pinch / collision gating
			requireClear = not stoneOnly
		end
		if stoneOnly then
			requireClear = false
		end
		local rayUp = cfg("NAV_RAY_UP", 50)
		local rayDown = cfg("NAV_RAY_DOWN", 140)
		local y0 = yHint or 50
		local topY = y0 + rayUp
		local bottomY = y0 - rayDown
		local curOrigin = Vector3.new(x, topY, z)
		local pierceExclude: { Instance } = {}
		local maxPierce = 14
		local traveled = 0

		for _ = 1, maxPierce do
			local remaining = curOrigin.Y - bottomY
			if remaining < 0.5 then
				return nil
			end
			local params = M.rayParams(pierceExclude)
			local hit = workspace:Raycast(curOrigin, Vector3.new(0, -remaining, 0), params)
			if not hit or not hit.Instance then
				return nil
			end
			traveled += hit.Distance

			local okSurface, walkable, matName, isTerrain = classifyFloorHit(hit, stoneOnly)
			local inst = hit.Instance
			if okSurface then
				local pos = hit.Position + hit.Normal.Unit * 0.15
				local clear = 99
				if requireClear then
					clear = M.wallClearance(pos)
					local need = cfg("NAV_WALL_CLEARANCE", 2.75)
					if clear + 1e-3 < need then
						return nil
					end
				end
				local isStone = walkable and (isTerrain or (inst:IsA("BasePart") and (inst :: BasePart).CanCollide))
				return {
					pos = pos,
					normal = hit.Normal,
					material = matName,
					instance = inst,
					path = inst:GetFullName(),
					isTerrain = isTerrain,
					isStonePath = isStone == true,
					distance = traveled,
					wallClearance = clear,
				}
			end

			-- Rejected hit: pierce past BaseParts so roofs/awnings don't hide the real floor.
			-- Terrain / barriers end the search (can't punch through the ground or walls).
			if isTerrain or isBarrierInstance(inst) or not inst:IsA("BasePart") then
				return nil
			end
			table.insert(pierceExclude, inst)
			-- Continue just below this hit so we don't re-strike the same surface.
			curOrigin = Vector3.new(x, hit.Position.Y - 0.05, z)
		end
		return nil
	end

	function M.sampleFloorAt(world: Vector3, opts: any?): any?
		return M.sampleFloor(world.X, world.Z, world.Y, opts)
	end

	-- Nearest stone-path floor near a point (spiral). Used when player/goal is off the road.
	function M.snapToStonePath(world: Vector3, maxR: number?): any?
		local rMax = maxR or cfg("NAV_STONE_PATH_SNAP_R", 24)
		local cell = cfg("NAV_CELL", 4)
		local best: any? = nil
		local bestD = math.huge
		-- Center first
		local c0 = M.sampleFloor(world.X, world.Z, world.Y, { requireClear = false })
		if c0 and c0.isStonePath then
			return c0
		end
		local steps = math.max(1, math.ceil(rMax / cell))
		for ring = 1, steps do
			local r = ring * cell
			local n = math.max(8, ring * 8)
			for i = 0, n - 1 do
				local ang = (i / n) * math.pi * 2
				local x = world.X + math.cos(ang) * r
				local z = world.Z + math.sin(ang) * r
				local s = M.sampleFloor(x, z, world.Y, { requireClear = false })
				if s and s.isStonePath then
					local d = Vector3.new(s.pos.X - world.X, 0, s.pos.Z - world.Z).Magnitude
					if d < bestD then
						bestD = d
						best = s
					end
				end
			end
			if best and bestD <= r * 1.1 then
				break
			end
		end
		return best
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

		local goalSample = M.sampleFloor(to.X, to.Z, to.Y, { requireClear = false })
		if not goalSample and M.stonePathOnly() then
			goalSample = M.snapToStonePath(to)
		end
		if not goalSample then
			for _, j in ipairs({
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
				goalSample = M.sampleFloor(to.X + j[1], to.Z + j[2], to.Y, { requireClear = false })
				if goalSample then
					break
				end
			end
		end
		if not goalSample then
			return nil
		end
		-- Start: snap onto stone road if standing on sand/dirt
		local startSample = M.sampleFloor(from.X, from.Z, from.Y, { requireClear = false })
		if M.stonePathOnly() and (not startSample or not startSample.isStonePath) then
			startSample = M.snapToStonePath(from) or startSample
		end
		if not startSample then
			startSample = { pos = from, normal = Vector3.yAxis, wallClearance = 99, isStonePath = false }
		end

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
			-- Stone-path mode: only stone terrain cells (no wall-pinch)
			local s = M.sampleFloor(wx, wz, yHint, { requireClear = not M.stonePathOnly() })
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
				-- Height continuity: tight on climbs, generous on drops (walk off ledge)
				local dY = ns.pos.Y - curSample.pos.Y
				local maxDrop = cfg("NAV_MAX_DROP_Y", 40)
				if dY > maxStepY then
					continue -- climb too high
				end
				if dY < -maxDrop then
					continue -- absurd void
				end
				-- Stone roads: no mid-edge collision LOS (paths are guaranteed clear).
				if not M.stonePathOnly() then
					local mid = (curSample.pos + ns.pos) * 0.5
					local midH = mid + Vector3.new(0, 2.5, 0)
					local delta = ns.pos - curSample.pos
					local flat = Vector3.new(delta.X, 0, delta.Z)
					if flat.Magnitude > 0.5 then
						local losHit = workspace:Raycast(
							midH - flat.Unit * 0.2,
							flat.Unit * (flat.Magnitude + 0.4),
							M.rayParams()
						)
						if losHit and losHit.Normal.Y < cfg("NAV_MIN_NORMAL_Y", 0.45) then
							continue
						end
					end
				end
				local stepCost = heuristic(cur.ix, cur.iz, nix, niz) * cell
				local tent = curG + stepCost
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

	-- Next node is a walk-off drop (hold W; gravity lands you). Not a wall.
	-- A* dump 02-55-10: y76→y62 dy=-13.5 was hopClear=false → strafe thrash on ledge.
	function M.isElevationDrop(from: Vector3, to: Vector3): boolean
		local allow = cfg("NAV_DROP_ALLOW_DY", 2.0)
		return (to.Y - from.Y) <= -allow
	end

	-- Player body hitbox size for clearance probes (HRP size × scale + pad).
	-- Exported for Clear Hitbox viz button.
	function M.playerHitboxSize(): Vector3
		local pad = cfg("NAV_HITBOX_PAD", 0.05)
		local scale = cfg("NAV_HITBOX_SCALE", 0.9)
		if scale < 0.4 then
			scale = 0.4
		elseif scale > 1.2 then
			scale = 1.2
		end
		local lp = Players.LocalPlayer
		local char = lp and lp.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			local s = (hrp :: BasePart).Size
			return Vector3.new(
				s.X * scale + pad * 2,
				s.Y * scale + pad * 2,
				s.Z * scale + pad * 2
			)
		end
		local r = (cfg("NAV_AGENT_RADIUS", 2) or 2) * 2 * scale
		local h = (cfg("NAV_AGENT_HEIGHT", 5) or 5) * scale
		return Vector3.new(r, h, r)
	end

	-- How high above the floor the Clear Hitbox CENTER sits (live character).
	-- Probes use this delta so we never test at floor-node Y (always "hits floor").
	function M.playerHitboxCenterHeight(): number
		local box = M.playerHitboxSize()
		local lift = cfg("NAV_HITBOX_FLOOR_LIFT", 0.15)
		local lp = Players.LocalPlayer
		local char = lp and lp.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hrp and hrp:IsA("BasePart") then
			local floor = M.sampleFloor(hrp.Position.X, hrp.Position.Z, hrp.Position.Y, {
				requireClear = false,
				allowAnyFloor = true, -- height measure even on sand
			})
			if floor and floor.pos then
				local dy = hrp.Position.Y - floor.pos.Y
				if dy > 0.4 and dy < 12 then
					return dy + lift
				end
			end
			local hip = (hum and hum.HipHeight) or 2
			return hip + (hrp :: BasePart).Size.Y * 0.5 + lift
		end
		return box.Y * 0.5 + lift
	end

	local HITBOX_VIZ_FOLDER = "PortalMage_HitboxViz"
	local lastClearProbeSamples: { any } = {} -- for viz trail after hasClearWalk

	-- Shared exclude list for clearance probes (self/mobs/viz). NEVER exclude InvisibleWall.
	local function clearanceExcludeList(): { Instance }
		local exclude: { Instance } = {}
		local lp = Players.LocalPlayer
		if lp and lp.Character then
			table.insert(exclude, lp.Character)
		end
		pcall(function()
			local mobs = workspace:FindFirstChild("Mobs")
			if mobs then
				table.insert(exclude, mobs)
			end
		end)
		pcall(function()
			for _, name in ipairs({
				"PortalMage_TerrainFloorOutline",
				"PortalMage_PathViz",
				"PortalMage_FaceViz",
				"PortalMage_SpawnPathViz",
				"PortalMage_SpawnPathStarts",
				HITBOX_VIZ_FOLDER,
			}) do
				local f = workspace:FindFirstChild(name)
				if f then
					table.insert(exclude, f)
				end
			end
		end)
		return exclude
	end

	local function clearanceRayParams(): RaycastParams
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = clearanceExcludeList()
		params.RespectCanCollide = true
		return params
	end

	-- Overhangs sampleFloor already pierces (gate arches, standalone roofs, sails).
	-- Their MeshPart AABBs/Box collision fill the walk-under volume and must not
	-- invalidate stone roads (dump 02-12-49: Goblin_Gate false-blocked hops 2–8).
	local function isPierceableOverhang(bp: BasePart): boolean
		local path = string.lower(bp:GetFullName())
		local n = string.lower(bp.Name)
		if string.find(path, ".gates.", 1, true)
			or string.find(path, "goblin_gate", 1, true)
			or string.find(path, "modular_standalone_roof", 1, true)
			or string.find(path, "standalone_roof", 1, true)
			or string.find(path, "mech_sail", 1, true)
			or string.find(n, "awning", 1, true)
			or string.find(n, "tarp", 1, true)
			or string.find(n, "canopy", 1, true)
			or string.find(n, "clothmesh", 1, true)
			or string.find(n, "sail_cloth", 1, true)
		then
			return true
		end
		return false
	end

	-- True wall / door pieces (keep blocking). Mega tower/house hulls often share
	-- Buildings.* but are decorative Box/Hull volumes over the stone road.
	local function isExplicitWallPart(bp: BasePart): boolean
		local path = string.lower(bp:GetFullName())
		local n = string.lower(bp.Name)
		if string.find(path, "invisiblewall", 1, true)
			or string.find(n, "invisible wall", 1, true)
		then
			return true
		end
		if string.find(n, "secwall", 1, true)
			or string.find(path, "secwall", 1, true)
			or string.find(n, "door", 1, true)
		then
			return true
		end
		-- "wall" in the leaf name, not just ancestor folder (Buildings.Towers…)
		if string.find(n, "wall", 1, true) then
			return true
		end
		return false
	end

	-- Bloated Buildings.* MeshParts (pipes/shaft/barrel/whole-tower hulls).
	-- Dump 02-15-11: player stood ON stone inside Goblin_Tower_Type3 AABB
	-- (GJ_Tower3_Pipes ~65k stud³) → every Blockcast blocked → KA kind=blocked thrash.
	local function isBloatedBuildingHull(bp: BasePart): boolean
		if isBarrierInstance(bp) or isExplicitWallPart(bp) then
			return false
		end
		if isNamedObstacle(bp) then
			return false
		end
		local path = string.lower(bp:GetFullName())
		if not string.find(path, ".buildings.", 1, true) then
			return false
		end
		local s = bp.Size
		local volume = s.X * s.Y * s.Z
		-- Real thin walls are << this; tower/house LODs are tens of thousands.
		return volume >= 1500
	end

	local function partContainsPoint(bp: BasePart, point: Vector3, margin: number): boolean
		local localPoint = bp.CFrame:PointToObjectSpace(point)
		local half = bp.Size * 0.5 + Vector3.new(margin, margin, margin)
		return math.abs(localPoint.X) <= half.X
			and math.abs(localPoint.Y) <= half.Y
			and math.abs(localPoint.Z) <= half.Z
	end

	-- Does this part count as a body collision (not the floor under our feet)?
	local function partBlocksBody(bp: BasePart, centerPos: Vector3, boxSize: Vector3): boolean
		if not bp.CanCollide then
			return false
		end
		if isBarrierInstance(bp) then
			return true
		end
		local n = string.lower(bp.Name)
		local path = string.lower(bp:GetFullName())
		if string.find(path, "invisiblewall", 1, true)
			or string.find(n, "invisible wall", 1, true)
		then
			return true
		end
		if isPierceableOverhang(bp) or isBloatedBuildingHull(bp) then
			return false
		end
		-- Vertical band first: floors under feet + pure overhangs above head are not walls.
		-- (Named stalls/awnings used to short-circuit before this and kill valid roads.)
		local footY = centerPos.Y - boxSize.Y * 0.5
		local headY = centerPos.Y + boxSize.Y * 0.5
		local topY = bp.Position.Y + bp.Size.Y * 0.5
		local botY = bp.Position.Y - bp.Size.Y * 0.5
		if topY <= footY + 0.45 then
			return false
		end
		if botY >= headY - 0.15 then
			return false
		end
		if isNamedObstacle(bp) then
			return true
		end
		if bp:IsA("Terrain") then
			return false
		end
		if isWalkFloorPart(bp) then
			return false
		end
		if isCollideProp(bp) then
			return true
		end
		-- Explicit walls still block; other collide meshes in body band too
		if isExplicitWallPart(bp) then
			return true
		end
		return true
	end

	local function structureHitNote(bp: BasePart): string
		local path = string.lower(bp:GetFullName())
		if isBarrierInstance(bp) or string.find(path, "invisiblewall", 1, true) then
			return "map_wall"
		end
		if isExplicitWallPart(bp)
			or string.find(path, "house", 1, true)
			or string.find(path, "tower", 1, true)
		then
			return "building"
		end
		return "structure"
	end

	-- Sweep player hitbox along the hop with Blockcast (real collision geometry).
	-- Multi-hit pierce: soffits, gate/roof overhangs, bloated Buildings hulls, and any
	-- part that already contains the start (standing inside tower AABB on stone).
	local function hopHitsStructure(fromCenter: Vector3, toCenter: Vector3, boxSize: Vector3): (boolean, string?)
		local flat = Vector3.new(toCenter.X - fromCenter.X, 0, toCenter.Z - fromCenter.Z)
		local dist = flat.Magnitude
		if dist < 0.05 then
			return false, nil
		end
		local dir = flat.Unit
		local cf = CFrame.lookAt(fromCenter, fromCenter + dir)
		-- Slightly shorter than full body so high arch lintels don't skim-block.
		local probeSize = Vector3.new(boxSize.X, math.max(1.0, boxSize.Y * 0.82), boxSize.Z)
		local exclude = clearanceExcludeList()
		local castDir = dir * dist
		for _ = 1, 10 do
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = exclude
			params.RespectCanCollide = true
			local ok, hit = pcall(function()
				return workspace:Blockcast(cf, probeSize, castDir, params)
			end)
			if not ok or not hit or not hit.Instance then
				return false, nil
			end
			local inst = hit.Instance
			-- Soffit / roof underside: walk-under is valid
			if hit.Normal.Y < -0.35 then
				table.insert(exclude, inst)
				continue
			end
			if not inst:IsA("BasePart") then
				table.insert(exclude, inst)
				continue
			end
			local bp = inst :: BasePart
			if isPierceableOverhang(bp)
				or isBloatedBuildingHull(bp)
				or partContainsPoint(bp, fromCenter, 0.75)
			then
				table.insert(exclude, bp)
				continue
			end
			local hitCenter = Vector3.new(hit.Position.X, fromCenter.Y, hit.Position.Z)
			if partBlocksBody(bp, hitCenter, boxSize) then
				return true, structureHitNote(bp)
			end
			table.insert(exclude, bp)
		end
		return false, nil
	end

	-- Probe one hop.
	-- Stone-path mode: stone continuity + Blockcast vs walls (AABB overlap false-blocks gates).
	-- Any-floor mode: same Blockcast body sweep.
	-- Returns clear?, samples (for Clear Hitbox viz).
	local function sampleHopProbes(from: Vector3, to: Vector3): (boolean, { any })
		local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
		local dist = flat.Magnitude
		local samples: { any } = {}
		if dist < 0.35 then
			return true, samples
		end
		local boxSize = M.playerHitboxSize()
		local centerH = M.playerHitboxCenterHeight()
		local dir = flat.Unit
		local step = cfg("NAV_CLEAR_STEP", 2.5)
		if step < 1.0 then
			step = 1.0
		end
		local nSteps = math.max(1, math.ceil(dist / step))
		local hopClear = true
		local stoneOnly = M.stonePathOnly()

		-- Stone roads: stone continuity + Blockcast body sweep (not MeshPart AABB overlap).
		if stoneOnly then
			local firstCenter: Vector3? = nil
			local lastCenter: Vector3? = nil
			for s = 0, nSteps do
				local t = math.min(dist, s * step)
				local alpha = if dist > 1e-4 then t / dist else 0
				local hintY = from.Y + (to.Y - from.Y) * alpha
				local x = from.X + dir.X * t
				local z = from.Z + dir.Z * t
				local floor = M.sampleFloor(x, z, hintY, { requireClear = false })
				local onStone = floor and floor.isStonePath == true
				local centerPos = if floor and floor.pos
					then Vector3.new(x, floor.pos.Y + centerH, z)
					else Vector3.new(x, hintY + centerH, z)
				if not firstCenter then
					firstCenter = centerPos
				end
				lastCenter = centerPos
				if not onStone then
					hopClear = false
				end
				table.insert(samples, {
					pos = centerPos,
					size = boxSize,
					dir = dir,
					blocked = not onStone,
					note = if onStone then "stone" else "off_stone",
					material = floor and floor.material or nil,
					floorY = floor and floor.pos.Y or hintY,
					centerH = centerH,
				})
			end
			if firstCenter and lastCenter then
				local hitStruct, structNote = hopHitsStructure(firstCenter, lastCenter, boxSize)
				if hitStruct then
					hopClear = false
					for _, sample in ipairs(samples) do
						sample.blocked = true
						sample.note = structNote or "structure"
					end
				end
			end
			return hopClear, samples
		end

		-- Any-floor: floor samples + Blockcast body sweep (same geometry as stone).
		if M.isElevationDrop(from, to) then
			table.insert(samples, {
				pos = Vector3.new(from.X, from.Y - boxSize.Y * 0.5 + centerH, from.Z),
				size = boxSize,
				dir = dir,
				blocked = false,
				note = "drop",
			})
			return true, samples
		end
		local maxFall = cfg("NAV_MAX_DROP_Y", 40)
		local firstCenter: Vector3? = nil
		local lastCenter: Vector3? = nil
		for s = 0, nSteps do
			local t = math.min(dist, s * step)
			local alpha = if dist > 1e-4 then t / dist else 0
			local hintY = from.Y + (to.Y - from.Y) * alpha
			local x = from.X + dir.X * t
			local z = from.Z + dir.Z * t
			local floorY = hintY
			local floor = M.sampleFloor(x, z, hintY, { requireClear = false, allowAnyFloor = true })
			if floor and floor.pos then
				if floor.pos.Y < hintY - maxFall then
					table.insert(samples, {
						pos = Vector3.new(x, hintY + centerH, z),
						size = boxSize,
						dir = dir,
						blocked = true,
						note = "void",
					})
					hopClear = false
					continue
				end
				floorY = floor.pos.Y
			end
			local centerPos = Vector3.new(x, floorY + centerH, z)
			if not firstCenter then
				firstCenter = centerPos
			end
			lastCenter = centerPos
			table.insert(samples, {
				pos = centerPos,
				size = boxSize,
				dir = dir,
				blocked = false,
				floorY = floorY,
				centerH = centerH,
			})
		end
		if firstCenter and lastCenter then
			local hitStruct, structNote = hopHitsStructure(firstCenter, lastCenter, boxSize)
			if hitStruct then
				hopClear = false
				for _, sample in ipairs(samples) do
					if sample.note ~= "void" then
						sample.blocked = true
						sample.note = structNote or "structure"
					end
				end
			end
		end
		return hopClear, samples
	end

	-- True if player-sized hitboxes along from→to are clear (body height, not floor nodes).
	function M.hasClearWalk(from: Vector3, to: Vector3): boolean
		local ok, samples = sampleHopProbes(from, to)
		lastClearProbeSamples = samples
		if S.hitboxVizEnabled then
			M.refreshHitboxViz()
		end
		return ok
	end

	-- Probe every hop of a polyline; always stores ALL samples for Clear Hitbox viz.
	function M.probeFullPath(pts: { Vector3 }?): boolean
		if not pts or #pts < 2 then
			lastClearProbeSamples = {}
			if S.hitboxVizEnabled then
				M.refreshHitboxViz()
			end
			return false
		end
		local all: { any } = {}
		local allClear = true
		local maxProbes = 120
		for i = 1, #pts - 1 do
			local hopOk, samples = sampleHopProbes(pts[i], pts[i + 1])
			if not hopOk then
				allClear = false
			end
			for _, s in ipairs(samples) do
				if #all >= maxProbes then
					break
				end
				table.insert(all, s)
			end
			if #all >= maxProbes then
				break
			end
		end
		lastClearProbeSamples = all
		if S.hitboxVizEnabled then
			M.refreshHitboxViz()
		end
		return allClear
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
		-- Destroy every PathViz folder (duplicates / stale refs left neon boxes after OFF)
		pcall(function()
			for _, ch in ipairs(workspace:GetChildren()) do
				if ch.Name == PATH_VIZ_FOLDER or string.find(ch.Name, "PortalMage_PathViz", 1, true) == 1 then
					ch:Destroy()
				end
			end
		end)
		S.pathVizFolder = nil
	end

	local function ensurePathVizFolder(): Folder?
		-- Never create viz while disabled (would leave green nodes after OFF)
		if not S.pathVizEnabled then
			return nil
		end
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

	-- Draw path polyline: green start / amber mid / red end + cyan segments.
	function M.showPathViz(points: { Vector3 }?, tag: string?)
		if not S.pathVizEnabled then
			M.clearPathViz()
			return
		end
		if not points or #points == 0 then
			M.clearPathViz()
			return
		end
		local epoch = S.pathVizEpoch or 0
		-- Full-path clearance probes for Clear Hitbox viz (every hop)
		if S.hitboxVizEnabled and #points >= 2 then
			M.probeFullPath(points)
		end
		if not S.pathVizEnabled or (S.pathVizEpoch or 0) ~= epoch then
			M.clearPathViz()
			return
		end
		local folder = ensurePathVizFolder()
		if not folder then
			return
		end
		for _, ch in ipairs(folder:GetChildren()) do
			ch:Destroy()
		end
		local label = Instance.new("StringValue")
		label.Name = "Tag"
		label.Value = string.format("%s n=%d", tag or "path", #points)
		label.Parent = folder

		local lift = 1.2 -- sit above floor so it's visible outdoors
		for i, pt in ipairs(points) do
			if not S.pathVizEnabled or (S.pathVizEpoch or 0) ~= epoch then
				M.clearPathViz()
				return
			end
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

	-- True if each hop of the polyline is walkable (no wall/prop/stall).
	-- Short PFS paths often still clip custom meshes — reject those.
	function M.pathSegmentsClear(pts: { Vector3 }?): boolean
		-- Full-path probe so Clear Hitbox viz shows every hop, not only the last.
		return M.probeFullPath(pts)
	end

	local function snapGoal(to: Vector3): Vector3
		local s = M.sampleFloor(to.X, to.Z, to.Y, { requireClear = false })
		if (not s or (M.stonePathOnly() and not s.isStonePath)) and M.stonePathOnly() then
			s = M.snapToStonePath(to)
		end
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

	-- Stone-path mode: prefer grid A* on Cobblestone (PFS often cuts across sand).
	-- Validation = stone continuity only (no obstacle collision).
	local function tryRoute(from: Vector3, goal: Vector3): ({ Vector3 }?, string, { boolean }?)
		local stoneOnly = M.stonePathOnly()
		-- Snap endpoints onto stone road. Goal snap is tight — a 24st yank used to
		-- pull stand goals onto cobble behind the player (KA dump 20-55-42).
		local fromSnap = from
		local goalSnap = goal
		if stoneOnly then
			local fs = M.snapToStonePath(from)
			local gs = M.snapToStonePath(goal, 10)
			if fs and fs.pos then
				fromSnap = fs.pos
			end
			if gs and gs.pos then
				local yank = Vector3.new(gs.pos.X - goal.X, 0, gs.pos.Z - goal.Z).Magnitude
				if yank <= 10 then
					goalSnap = gs.pos
				end
				-- else keep geometric goal; grid may fail (caller varies angle)
			end
		end

		-- Grid A* (stone network, or any-floor during soft escape).
		-- ALWAYS require hop clearance — escape used to return raw grids that clipped
		-- through InvisibleWall / map bounds.
		local dist = Vector3.new(goalSnap.X - fromSnap.X, 0, goalSnap.Z - fromSnap.Z).Magnitude
		local cell = cfg("NAV_CELL", 4)
		local maxCells = math.max(cfg("NAV_MAX_CELLS", 40), math.ceil(dist / cell) + 8)
		local custom = M.findPath(fromSnap, goalSnap, { maxCells = maxCells, cell = cell })
		if custom and #custom >= 1 then
			local pts = if #custom == 1 then { fromSnap, custom[1] } else custom
			if M.pathSegmentsClear(pts) then
				return pts, "grid", jumpsFromPts(pts)
			end
			if #pts >= 3 then
				local prefix = { pts[1] }
				for i = 2, #pts do
					if not M.hasClearWalk(prefix[#prefix], pts[i]) then
						break
					end
					table.insert(prefix, pts[i])
				end
				if #prefix >= 2 then
					return prefix, "grid:prefix", jumpsFromPts(prefix)
				end
			end
		end

		if stoneOnly then
			-- Direct line on stone only
			if M.hasClearWalk(fromSnap, goalSnap) then
				return { fromSnap, goalSnap }, "line:stone", { false, false }
			end
			return nil, "none", nil
		end

		local native, _nWhy, jumps = M.computeNativePath(from, goal)
		if native and #native >= 2 then
			if M.pathSegmentsClear(native) then
				return native, "pfs", jumps or {}
			end
			if #native >= 3 then
				local prefix = { native[1] }
				for i = 2, #native do
					if not M.hasClearWalk(prefix[#prefix], native[i]) then
						break
					end
					table.insert(prefix, native[i])
				end
				if #prefix >= 2 then
					return prefix, "pfs:prefix", jumpsFromPts(prefix)
				end
			end
		elseif native and #native == 1 then
			if M.hasClearWalk(from, native[1]) then
				return { from, native[1] }, "pfs", { false, false }
			end
		end
		return nil, "none", nil
	end

	-- Prefer native PathfindingService; fall back to floor A*; small ring of alts.
	-- NEVER return a straight line through a wall (line:soft was walking into walls).
	function M.computePath(from: Vector3, to: Vector3, opts: any?): ({ Vector3 }, string, { boolean })
		opts = opts or {}
		local primary = snapGoal(to)

		local goals: { Vector3 } = { primary }
		local maxGoals = math.clamp(tonumber(opts.maxGoals) or cfg("NAV_PATH_MAX_GOALS", 6), 1, 16)
		local ringR = opts.ringR or { 10, 18, 28 }
		local ringN = opts.ringN or 6
		for _, r in ipairs(ringR) do
			if #goals >= maxGoals then
				break
			end
			for i = 0, ringN - 1 do
				if #goals >= maxGoals then
					break
				end
				local ang = (i / ringN) * math.pi * 2 + (opts.ringPhase or 0)
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
			if pts and #pts >= 2 and kind ~= "none" then
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
			if gi < #goals then
				task.wait()
			end
		end

		-- Clear straight line only — never line:soft (log: stuck W into wall @54st)
		if M.hasClearWalk(from, primary) then
			local line = { from, primary }
			if S.pathVizEnabled then
				M.showPathViz(line, "line")
			end
			return line, "line", { false, (primary.Y - from.Y) >= 3.5 }
		end

		-- No walkable route. Single point → pathing repaths / picks another angle.
		if S.pathVizEnabled then
			M.showPathViz({ from }, "blocked:" .. tostring(lastWhy))
		end
		return { from }, "blocked", { false }
	end

	function M.setPathVizEnabled(on: boolean)
		local want = on and true or false
		if not want then
			-- Invalidate in-flight showPathViz draws before clearing
			S.pathVizEpoch = (S.pathVizEpoch or 0) + 1
			S.pathVizEnabled = false
			M.clearPathViz()
			if S.ui and S.ui.setPathVizLabel then
				S.ui.setPathVizLabel(false)
			end
			if U and U.setStatus then
				U.setStatus("Path Viz OFF")
			end
			return
		end
		S.pathVizEnabled = true
		if S.ui and S.ui.setPathVizLabel then
			S.ui.setPathVizLabel(true)
		end
		if U and U.setStatus then
			U.setStatus("Path Viz ON — A* routes draw green/amber/cyan markers")
		end
	end

	function M.togglePathViz()
		M.setPathVizEnabled(not S.pathVizEnabled)
	end

	---------------------------------------------------------------------------
	-- Clearance hitbox visualization (player box + last probe samples)
	---------------------------------------------------------------------------

	function M.clearHitboxViz()
		pcall(function()
			if S.hitboxVizFolder and S.hitboxVizFolder.Parent then
				S.hitboxVizFolder:Destroy()
			end
		end)
		pcall(function()
			local f = workspace:FindFirstChild(HITBOX_VIZ_FOLDER)
			if f then
				f:Destroy()
			end
		end)
		S.hitboxVizFolder = nil
	end

	local function ensureHitboxVizFolder(): Folder
		local f = S.hitboxVizFolder
		if f and f.Parent then
			return f :: Folder
		end
		f = workspace:FindFirstChild(HITBOX_VIZ_FOLDER)
		if not (f and f:IsA("Folder")) then
			f = Instance.new("Folder")
			f.Name = HITBOX_VIZ_FOLDER
			f.Parent = workspace
		end
		S.hitboxVizFolder = f
		return f :: Folder
	end

	-- Same Neon style as Path Viz (ForceField was nearly invisible in-game).
	local function mkHitboxPart(
		name: string,
		size: Vector3,
		cf: CFrame,
		color: Color3,
		parent: Instance,
		transparency: number?
	): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = color
		p.Transparency = transparency or 0.45
		p.Size = size
		p.CFrame = cf
		p.Parent = parent
		local sb = Instance.new("SelectionBox")
		sb.Name = "Outline"
		sb.Adornee = p
		sb.Color3 = color
		sb.LineThickness = 0.06
		sb.SurfaceTransparency = 0.85
		sb.Transparency = 0
		sb.Parent = p
		return p
	end

	-- 12-edge wireframe so the box stays visible even when solid fill sits inside the body mesh.
	local function mkWireBox(
		name: string,
		size: Vector3,
		cf: CFrame,
		color: Color3,
		parent: Instance
	)
		local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
		local corners = {
			Vector3.new(-hx, -hy, -hz),
			Vector3.new(hx, -hy, -hz),
			Vector3.new(hx, -hy, hz),
			Vector3.new(-hx, -hy, hz),
			Vector3.new(-hx, hy, -hz),
			Vector3.new(hx, hy, -hz),
			Vector3.new(hx, hy, hz),
			Vector3.new(-hx, hy, hz),
		}
		local edges = {
			{ 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 },
			{ 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 },
			{ 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 },
		}
		local thick = 0.12
		for ei, e in ipairs(edges) do
			local a = cf:PointToWorldSpace(corners[e[1]])
			local b = cf:PointToWorldSpace(corners[e[2]])
			local mid = (a + b) * 0.5
			local delta = b - a
			local len = delta.Magnitude
			if len < 0.05 then
				continue
			end
			local edge = Instance.new("Part")
			edge.Name = string.format("%s_E%02d", name, ei)
			edge.Shape = Enum.PartType.Cylinder
			edge.Anchored = true
			edge.CanCollide = false
			edge.CanQuery = false
			edge.CanTouch = false
			edge.CastShadow = false
			edge.Material = Enum.Material.Neon
			edge.Color = color
			edge.Transparency = 0.05
			edge.Size = Vector3.new(len, thick, thick)
			-- Cylinder axis is +X; aim X along edge
			edge.CFrame = CFrame.lookAt(mid, mid + delta) * CFrame.Angles(0, math.rad(90), 0)
			edge.Parent = parent
		end
	end

	function M.refreshHitboxViz()
		if not S.hitboxVizEnabled then
			return
		end
		local okAll, errAll = pcall(function()
			local folder = ensureHitboxVizFolder()
			-- Full redraw each tick (wire + probes) — simpler than reuse churn
			for _, ch in ipairs(folder:GetChildren()) do
				ch:Destroy()
			end

			local lp = Players.LocalPlayer
			local char = lp and lp.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			local boxSize = M.playerHitboxSize()
			-- Minimum so a tiny HRP still shows a readable box
			boxSize = Vector3.new(
				math.max(boxSize.X, 1.4),
				math.max(boxSize.Y, 2.0),
				math.max(boxSize.Z, 1.4)
			)

			if hrp and hrp:IsA("BasePart") then
				local cf = (hrp :: BasePart).CFrame
				-- Solid fill (see-through neon)
				mkHitboxPart("PlayerHitbox", boxSize, cf, Color3.fromRGB(60, 220, 255), folder, 0.65)
				-- Bright wire outline outside the mesh
				mkWireBox("PlayerWire", boxSize * 1.05, cf, Color3.fromRGB(0, 255, 255), folder)
				-- True HRP size (amber) so you can compare pad/scale
				local raw = (hrp :: BasePart).Size
				mkWireBox("HrpWire", raw, cf, Color3.fromRGB(255, 200, 60), folder)
			else
				-- No character: drop a marker at camera look so toggle still proves itself
				local cam = workspace.CurrentCamera
				if cam then
					local pos = cam.CFrame.Position + cam.CFrame.LookVector * 8
					local cf = CFrame.new(pos)
					mkHitboxPart("NoCharHitbox", boxSize, cf, Color3.fromRGB(255, 120, 40), folder, 0.4)
					mkWireBox("NoCharWire", boxSize, cf, Color3.fromRGB(255, 160, 60), folder)
				end
			end

			-- Last hasClearWalk probe samples (green clear / red blocked)
			for i, sample in ipairs(lastClearProbeSamples) do
				if type(sample) == "table" and sample.pos and sample.size then
					local dir = sample.dir
					if typeof(dir) ~= "Vector3" or (dir :: Vector3).Magnitude < 1e-4 then
						dir = Vector3.new(0, 0, -1)
					else
						dir = (dir :: Vector3).Unit
					end
					local sz = sample.size :: Vector3
					sz = Vector3.new(math.max(sz.X, 1.2), math.max(sz.Y, 1.8), math.max(sz.Z, 1.2))
					local pos = sample.pos :: Vector3
					local cf = CFrame.lookAt(pos, pos + dir)
					local col = if sample.blocked
						then Color3.fromRGB(255, 60, 60)
						else Color3.fromRGB(80, 255, 100)
					mkHitboxPart(string.format("Probe_%02d", i), sz, cf, col, folder, 0.55)
					mkWireBox(string.format("ProbeWire_%02d", i), sz, cf, col, folder)
				end
			end
		end)
		if not okAll and U and U.setStatus then
			U.setStatus("Clear Hitbox draw error: " .. tostring(errAll))
		end
	end

	function M.setHitboxVizEnabled(on: boolean)
		S.hitboxVizEnabled = on and true or false
		if S.ui and S.ui.setHitboxVizLabel then
			S.ui.setHitboxVizLabel(S.hitboxVizEnabled)
		end
		if not S.hitboxVizEnabled then
			if S.hitboxVizThread then
				pcall(task.cancel, S.hitboxVizThread)
				S.hitboxVizThread = nil
			end
			M.clearHitboxViz()
			if U and U.setStatus then
				U.setStatus("Clear Hitbox OFF")
			end
			return
		end
		local sz = M.playerHitboxSize()
		local ch = M.playerHitboxCenterHeight()
		if U and U.setStatus then
			U.setStatus(string.format(
				"Clear Hitbox ON — %.1f×%.1f×%.1f @ floor+%.1f (full A* path probes)",
				sz.X,
				sz.Y,
				sz.Z,
				ch
			))
		end
		-- Re-probe last kill-aura / bot path so full route boxes appear immediately
		local last = S.lastKillAuraPath or S.lastBotPath
		if last and type(last.points) == "table" and #last.points >= 2 then
			local pts: { Vector3 } = {}
			for _, p in ipairs(last.points) do
				if type(p) == "table" and p.x and p.z then
					table.insert(pts, Vector3.new(p.x, p.y or 0, p.z))
				end
			end
			if #pts >= 2 then
				M.probeFullPath(pts)
			end
		end
		M.refreshHitboxViz()
		if S.hitboxVizThread then
			pcall(task.cancel, S.hitboxVizThread)
		end
		S.hitboxVizThread = task.spawn(function()
			while S.hitboxVizEnabled do
				M.refreshHitboxViz()
				task.wait(0.12)
			end
		end)
	end

	function M.toggleHitboxViz()
		M.setHitboxVizEnabled(not S.hitboxVizEnabled)
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

	-- Merge persisted walkable materials (Waypoints "Add walkable tile")
	task.defer(function()
		M.loadWalkableMaterials()
	end)

	return M
end



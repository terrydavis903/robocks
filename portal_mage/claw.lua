-- portal_mage/claw.lua — Event_ClawMachine (ISOLATED module)
--
-- Separate from combat / pathing / proximity. Claw lives on a safe map with no
-- enemies; combat maps never have this machine. Shares only the HUD shell.
-- Prox guard, walk+atk, and combat loops must not gate or cancel claw runs.
--
-- Key map (from player-position cardinal deltas — NOT beam dumps):
--   W → +Z   S → −Z   A → +X   D → −X
-- Aim uses the machine claw XZ (Cylinder / PrizeDetect). Drop = Space once.
-- Sequence is one-shot (no loop).
return function(S)
	local C = S.Config
	local U = S.Util
	local HttpService = S.Services.HttpService
	local VIM = S.Services.VirtualInputManager
	local M = {}

	local CLAW_ROOT_NAME = "Event_ClawMachine"
	local MAINTAIN_INTERVAL = 0.25

	-- Longest keyword first so "aurorite" beats "aurora", "enchantedbark" beats "bark"
	-- Lower tier number = higher priority. Unmatched names = P8 other.
	-- P9 = pure junk (Tria currency, scrap, etc.) so unknown mats still beat them.
	local PRIORITY_KEYWORDS = {
		{ key = "spirit", tier = 2 }, -- spirit stones; own tier under P1
		{ key = "enchantedbark", tier = 5 },
		{ key = "heartwood", tier = 4 }, -- also matches AncientHeartwood
		{ key = "enchantedwood", tier = 5 },
		{ key = "mysticessence", tier = 6 }, -- was 7
		{ key = "briarvine", tier = 6 }, -- was 5
		{ key = "memorysap", tier = 6 }, -- was 5
		{ key = "goblincoin", tier = 3 },
		{ key = "aurorite", tier = 7 }, -- was 6
		{ key = "junkcore", tier = 7 }, -- was 6
		{ key = "glowingmoss", tier = 6 }, -- was 7
		{ key = "grimoire", tier = 1 },
		{ key = "circuit", tier = 1 },
		{ key = "meteor", tier = 1 },
		{ key = "timber", tier = 1 },
		{ key = "aurora", tier = 1 },
		{ key = "amber", tier = 3 },
		{ key = "living", tier = 3 }, -- LivingBark etc.
		{ key = "tome", tier = 1 },
		-- Junk / currency (below generic mats)
		{ key = "triacoin", tier = 9 },
		{ key = "triapouch", tier = 9 },
		{ key = "triasack", tier = 9 },
		{ key = "tria", tier = 9 },
		{ key = "scrapmetal", tier = 9 },
		{ key = "rustygear", tier = 9 },
		{ key = "solite", tier = 9 },
		{ key = "lumite", tier = 9 },
	}

	local MOVE_KEYS = {
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
	}

	local function setStatus(t: string)
		U.setStatus(t)
	end

	local function color3Table(c: Color3)
		return { r = c.R, g = c.G, b = c.B }
	end

	local function normalizeName(name: string): string
		return (string.lower(name):gsub("[^%w]", ""))
	end

	---------------------------------------------------------------------------
	-- Machine finders
	---------------------------------------------------------------------------

	function M.findRoot(): Instance?
		local root = workspace:FindFirstChild(CLAW_ROOT_NAME)
		if root then
			return root
		end
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == CLAW_ROOT_NAME then
				return d
			end
		end
		return nil
	end

	function M.findBeam(): Beam?
		local root = M.findRoot()
		if not root then
			return nil
		end
		local housing = root:FindFirstChild("ClawHousing")
		local claw = housing and housing:FindFirstChild("Claw")
		local cylinder = claw and claw:FindFirstChild("Cylinder")
		local beam = cylinder and cylinder:FindFirstChild("Beam")
		if beam and beam:IsA("Beam") then
			return beam
		end
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("Beam") then
				return d
			end
		end
		return nil
	end

	-- Claw aim point (XZ of grabber). Prefer PrizeDetect, then Cylinder, then beam mid.
	function M.getClawPosition(): Vector3?
		local root = M.findRoot()
		if not root then
			return nil
		end
		local housing = root:FindFirstChild("ClawHousing")
		local clawModel = housing and housing:FindFirstChild("Claw")
		if clawModel then
			local detect = clawModel:FindFirstChild("PrizeDetect", true)
			if detect and detect:IsA("BasePart") then
				return detect.Position
			end
			local cylinder = clawModel:FindFirstChild("Cylinder", true)
			if cylinder and cylinder:IsA("BasePart") then
				return cylinder.Position
			end
			local pos = U.getCharacterLikePosition(clawModel :: Model) or U.getInstancePosition(clawModel)
			if pos then
				return pos
			end
		end
		local beam = M.findBeam()
		if beam then
			local a0, a1 = beam.Attachment0, beam.Attachment1
			if a0 and a1 then
				return (a0.WorldPosition + a1.WorldPosition) * 0.5
			end
			if a0 then
				return a0.WorldPosition
			end
			if a1 then
				return a1.WorldPosition
			end
			return U.getInstancePosition(beam.Parent)
		end
		return nil
	end

	---------------------------------------------------------------------------
	-- Reachable bounds = machine wall box (flush). No imaginary inset hitbox.
	-- Claw travel limits from W/A/S/D max dumps; prizes on the glass are valid.
	---------------------------------------------------------------------------

	-- Absolute wall-flush AABB (never shrink with margin — margin kept for compat only).
	function M.getReachBounds()
		if C.CLAW_REACH_ENABLED == false then
			return nil
		end
		-- Do NOT apply CLAW_REACH_MARGIN as an inset — that was the false inner hitbox.
		local xMin = C.CLAW_REACH_X_MIN or -math.huge
		local xMax = C.CLAW_REACH_X_MAX or math.huge
		local zMin = C.CLAW_REACH_Z_MIN or -math.huge
		local zMax = C.CLAW_REACH_Z_MAX or math.huge
		if xMin > xMax or zMin > zMax then
			return nil
		end
		return xMin, xMax, zMin, zMax
	end

	function M.clearBlockedPrizes()
		S.clawBlockedPrizes = {}
	end

	function M.isPrizeBlocked(p: any): boolean
		if not p then
			return true
		end
		local blocked = S.clawBlockedPrizes
		if type(blocked) ~= "table" then
			return false
		end
		local key = p.path or p.name
		return blocked[key] == true
	end

	function M.blockPrize(p: any, reason: string?)
		if not p then
			return
		end
		if type(S.clawBlockedPrizes) ~= "table" then
			S.clawBlockedPrizes = {}
		end
		local key = p.path or p.name
		S.clawBlockedPrizes[key] = true
		if M.log then
			M.log("WARN", string.format(
				"skip prize this run %s (%s)",
				tostring(p.name),
				reason or "unreachable"
			), false)
		end
	end

	-- Distance from prize center to nearest point on the wall-flush AABB (0 if inside).
	function M.prizeDistanceToReachBox(x: number, z: number): number
		local xMin, xMax, zMin, zMax = M.getReachBounds()
		if xMin == nil then
			return 0
		end
		local cx = math.clamp(x, xMin, xMax)
		local cz = math.clamp(z, zMin, zMax)
		local dx = x - cx
		local dz = z - cz
		return math.sqrt(dx * dx + dz * dz)
	end

	-- Kept for logs/dumps only (positive = center inside box). NOT used to reject edge prizes.
	function M.prizeInsetScore(x: number, z: number): number
		local xMin, xMax, zMin, zMax = M.getReachBounds()
		if xMin == nil then
			return 0
		end
		local dOut = M.prizeDistanceToReachBox(x, z)
		if dOut > 1e-6 then
			return -dOut
		end
		return math.min(x - xMin, xMax - x, z - zMin, zMax - z)
	end

	function M.reachSlack(): number
		return C.CLAW_OUTSIDE_REACH_SLACK or 0
	end

	function M.defaultPrizeRadius(): number
		return C.CLAW_PRIZE_DEFAULT_RADIUS_XZ or 0.375
	end

	-- REACH = prize *body* intersects wall-flush machine box.
	-- Center may sit slightly outside the claw AABB when the ball is pressed on glass;
	-- if center is within radius of the box edge, it is still grabbable.
	-- Optional 4th arg: radiusXZ (or pass prize table as 1st via isPrizeReachablePrize).
	function M.isPrizeReachable(x: number, z: number, _priority: number?, radiusXZ: number?): boolean
		if C.CLAW_REACH_ENABLED == false then
			return true
		end
		local xMin = M.getReachBounds()
		if xMin == nil then
			return false
		end
		local r = radiusXZ
		if type(r) ~= "number" or r < 0 then
			r = M.defaultPrizeRadius()
		end
		local slack = M.reachSlack()
		return M.prizeDistanceToReachBox(x, z) <= (r + slack + 1e-4)
	end

	function M.isPrizeEntryReachable(p: any): boolean
		if not p then
			return false
		end
		return M.isPrizeReachable(p.x, p.z, p.priority, p.radiusXZ)
	end

	function M.formatReachBounds(): string
		local xMin, xMax, zMin, zMax = M.getReachBounds()
		if xMin == nil then
			return "disabled"
		end
		return string.format(
			"walls X[%.2f,%.2f] Z[%.2f,%.2f] flush r=%.2f",
			xMin,
			xMax,
			zMin,
			zMax,
			M.defaultPrizeRadius()
		)
	end

	function M.priorityForName(name: string): (number, string?)
		local n = normalizeName(name)
		for _, entry in ipairs(PRIORITY_KEYWORDS) do
			if string.find(n, entry.key, 1, true) then
				return entry.tier, entry.key
			end
		end
		return 8, nil -- unknown mats (still above P9 junk)
	end

	local function isPrizeName(name: string): boolean
		local nameL = string.lower(name)
		return string.find(nameL, "prize", 1, true) == 1
	end

	-- Geometric CENTER of a prize (never a corner/vertex).
	-- BasePart.Position is the part center; Models use GetBoundingBox center
	-- or a volume-weighted average of child part centers if pivot is offset.
	function M.getPrizeCenter(inst: Instance): (Vector3?, Vector3?, number?)
		if not inst or not inst.Parent then
			return nil, nil, nil
		end
		if inst:IsA("BasePart") then
			-- Prefer the largest solid-ish descendant mesh under this part's parent
			-- only when this part is a thin shell; otherwise Position is the ball center.
			local center = inst.Position
			local size = inst.Size
			-- If children BaseParts exist (nested visual), use volume-weighted center
			local wsum = 0
			local sum = Vector3.zero
			local maxVol = size.X * size.Y * size.Z
			local bestSize = size
			for _, d in ipairs(inst:GetDescendants()) do
				if d:IsA("BasePart") then
					local vol = d.Size.X * d.Size.Y * d.Size.Z
					if vol > 1e-6 then
						sum += d.Position * vol
						wsum += vol
						if vol > maxVol then
							maxVol = vol
							bestSize = d.Size
						end
					end
				end
			end
			if wsum > 0 then
				-- Blend self + children by volume so we sit on mass center, not a rim piece
				local selfVol = size.X * size.Y * size.Z
				center = (inst.Position * selfVol + sum) / (selfVol + wsum)
				size = bestSize
			end
			local radiusXZ = math.min(size.X, size.Z) * 0.5
			return center, size, radiusXZ
		end
		if inst:IsA("Model") then
			local ok, cf, size = pcall(function()
				return inst:GetBoundingBox()
			end)
			if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
				-- GetBoundingBox returns AABB center — still the object center, not a corner
				local radiusXZ = math.min(size.X, size.Z) * 0.5
				return cf.Position, size, radiusXZ
			end
			local wsum = 0
			local sum = Vector3.zero
			local bestSize = Vector3.new(0.75, 0.75, 0.75)
			local maxVol = 0
			for _, d in ipairs(inst:GetDescendants()) do
				if d:IsA("BasePart") then
					local vol = d.Size.X * d.Size.Y * d.Size.Z
					if vol > 1e-6 then
						sum += d.Position * vol
						wsum += vol
						if vol > maxVol then
							maxVol = vol
							bestSize = d.Size
						end
					end
				end
			end
			if wsum > 0 then
				local radiusXZ = math.min(bestSize.X, bestSize.Z) * 0.5
				return sum / wsum, bestSize, radiusXZ
			end
		end
		local fallback = U.getInstancePosition(inst)
		return fallback, nil, nil
	end

	local function makePrizeEntry(inst: Instance): any?
		if not isPrizeName(inst.Name) then
			return nil
		end
		-- Skip claw hitbox / detectors
		local nameL = string.lower(inst.Name)
		if string.find(nameL, "detect", 1, true) or string.find(nameL, "sensor", 1, true) then
			return nil
		end
		local center, size, radiusXZ = M.getPrizeCenter(inst)
		if not center then
			return nil
		end
		local tier, kw = M.priorityForName(inst.Name)
		return {
			inst = inst,
			name = inst.Name,
			path = inst:GetFullName(),
			priority = tier,
			matchedKeyword = kw,
			-- Aim point = ball CENTER (x/z), never corner
			position = center,
			x = center.X,
			y = center.Y,
			z = center.Z,
			size = size,
			radiusXZ = radiusXZ or 0.375,
			transparency = if inst:IsA("BasePart") then inst.Transparency else nil,
		}
	end

	function M.scanPrizes(): { any }
		local root = M.findRoot()
		local list = {}
		if not root then
			return list
		end
		local prizesFolder = root:FindFirstChild("Prizes")
		local seen: { [Instance]: boolean } = {}

		local function push(inst: Instance)
			if seen[inst] then
				return
			end
			local entry = makePrizeEntry(inst)
			if entry then
				seen[inst] = true
				table.insert(list, entry)
			end
		end

		-- Prefer direct children of Prizes (one entry per ball root)
		if prizesFolder then
			for _, child in ipairs(prizesFolder:GetChildren()) do
				if child:IsA("BasePart") or child:IsA("Model") then
					push(child)
				end
			end
		end

		-- Fallback: named prize parts under machine if folder empty / nested only
		if #list == 0 then
			local searchRoot: Instance = prizesFolder or root
			for _, d in ipairs(searchRoot:GetDescendants()) do
				if (d:IsA("BasePart") or d:IsA("Model")) and isPrizeName(d.Name) then
					-- Prefer outermost prize ancestor to avoid double-counting children
					local parent = d.Parent
					local skip = false
					while parent and parent ~= searchRoot do
						if isPrizeName(parent.Name) then
							skip = true
							break
						end
						parent = parent.Parent
					end
					if not skip then
						push(d)
					end
				end
			end
		end
		return list
	end

	-- Pick highest priority reachable prize.
	-- Same priority: closer to claw wins. Wall-edge prizes are valid (no inset bias).
	function M.pickBestPrize(prizes: { any }, clawPos: Vector3?, opts: any?): any?
		opts = opts or {}
		local requireReachable = opts.requireReachable ~= false
		local excludeInst = opts.excludeInst
		if #prizes == 0 then
			return nil
		end
		local best = nil
		local bestOutside = nil -- best high-prio truly outside machine (for logs)
		local skippedOutside = 0
		local skippedBlocked = 0
		for _, p in ipairs(prizes) do
			if excludeInst and p.inst == excludeInst then
				-- skip
			elseif M.isPrizeBlocked(p) then
				skippedBlocked += 1
			else
				local dist = math.huge
				if clawPos then
					local dx = p.x - clawPos.X
					local dz = p.z - clawPos.Z
					dist = math.sqrt(dx * dx + dz * dz)
				end
				p.distXZ = dist
				local reachable = M.isPrizeEntryReachable(p)
				p.reachable = reachable
				p.inset = M.prizeInsetScore(p.x, p.z) -- debug only
				if requireReachable and not reachable then
					skippedOutside += 1
					local hiMax = C.CLAW_HIGH_PRIORITY_TIER_MAX or 5
					if (p.priority or 99) <= hiMax then
						if not bestOutside
							or p.priority < bestOutside.priority
							or (p.priority == bestOutside.priority and dist < (bestOutside.distXZ or math.huge))
						then
							bestOutside = p
						end
					end
				else
					local better = false
					if not best then
						better = true
					elseif p.priority < best.priority then
						better = true
					elseif p.priority == best.priority and dist < (best.distXZ or math.huge) then
						better = true
					end
					if better then
						best = p
					end
				end
			end
		end
		if best then
			best._skippedUnreachable = skippedOutside
			best._skippedBlocked = skippedBlocked
			best._bestWallHigh = bestOutside -- legacy field name for logs
		end
		return best
	end

	function M.countReachable(prizes: { any }): (number, number, number)
		local ok, bad, blocked = 0, 0, 0
		for _, p in ipairs(prizes) do
			if M.isPrizeBlocked(p) then
				blocked += 1
			elseif M.isPrizeEntryReachable(p) then
				ok += 1
			else
				bad += 1
			end
		end
		return ok, bad, blocked
	end

	function M.refreshPrize(target: any): any?
		if not target then
			return nil
		end
		local inst = target.inst
		if inst and inst.Parent then
			local center, size, radiusXZ = M.getPrizeCenter(inst)
			if center then
				target.position = center
				target.x = center.X
				target.y = center.Y
				target.z = center.Z
				target.size = size
				target.radiusXZ = radiusXZ or target.radiusXZ
				return target
			end
		end
		-- Instance gone — rescan by name and pick closest same-name (by center)
		local prizes = M.scanPrizes()
		local clawPos = M.getClawPosition()
		local best = nil
		for _, p in ipairs(prizes) do
			if p.name == target.name then
				local dist = math.huge
				if clawPos then
					local dx = p.x - clawPos.X
					local dz = p.z - clawPos.Z
					dist = math.sqrt(dx * dx + dz * dz)
				end
				p.distXZ = dist
				if not best or dist < (best.distXZ or math.huge) then
					best = p
				end
			end
		end
		return best
	end

	---------------------------------------------------------------------------
	-- Beam force (existing)
	---------------------------------------------------------------------------

	local function beamInfo(beam: Beam): any
		local a0, a1 = beam.Attachment0, beam.Attachment1
		local t0, t1 = 0, 0
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
		local parentPart = beam.Parent
		local parentTrans = nil
		local parentLocalTrans = nil
		if parentPart and parentPart:IsA("BasePart") then
			parentTrans = parentPart.Transparency
			pcall(function()
				parentLocalTrans = parentPart.LocalTransparencyModifier
			end)
		end
		local playerVisible = true
		local invisibleReason: string? = nil
		if not beam.Enabled then
			playerVisible = false
			invisibleReason = "Enabled=false"
		elseif not a0 or not a1 then
			playerVisible = false
			invisibleReason = "missing Attachment0/1"
		elseif (t0 or 0) >= 0.99 and (t1 or 0) >= 0.99 then
			playerVisible = false
			invisibleReason = "full transparency"
		elseif (beam.Width0 or 0) <= 0.001 and (beam.Width1 or 0) <= 0.001 then
			playerVisible = false
			invisibleReason = "zero width"
		end
		return {
			name = beam.Name,
			path = beam:GetFullName(),
			enabled = beam.Enabled,
			transparency0 = t0,
			transparency1 = t1,
			width0 = beam.Width0,
			width1 = beam.Width1,
			faceCamera = beam.FaceCamera,
			lightEmission = beam.LightEmission,
			lightInfluence = beam.LightInfluence,
			texture = beam.Texture,
			textureMode = tostring(beam.TextureMode),
			color = color3Table(beam.Color.Keypoints[1].Value),
			hasAttachment0 = a0 ~= nil,
			hasAttachment1 = a1 ~= nil,
			attachment0 = a0 and a0:GetFullName() or nil,
			attachment1 = a1 and a1:GetFullName() or nil,
			parent = parentPart and parentPart:GetFullName() or nil,
			parentTransparency = parentTrans,
			parentLocalTransparencyModifier = parentLocalTrans,
			playerVisible = playerVisible,
			invisibleReason = invisibleReason,
		}
	end

	function M.inspectBeam(): any?
		local beam = M.findBeam()
		if not beam then
			return nil
		end
		local ok, info = pcall(beamInfo, beam)
		if ok then
			return info
		end
		return {
			path = beam:GetFullName(),
			enabled = beam.Enabled,
			error = tostring(info),
			playerVisible = false,
			invisibleReason = "inspect failed: " .. tostring(info),
		}
	end

	function M.collectBalls(): { any }
		local root = M.findRoot()
		local balls = {}
		if not root then
			return balls
		end
		for _, d in ipairs(root:GetDescendants()) do
			local nameL = string.lower(d.Name)
			local looksBall = string.find(nameL, "ball", 1, true)
				or string.find(nameL, "prize", 1, true)
				or string.find(nameL, "orb", 1, true)
				or string.find(nameL, "capsule", 1, true)
				or string.find(nameL, "plush", 1, true)
			if d:IsA("BasePart") and looksBall then
				table.insert(balls, {
					name = d.Name,
					className = d.ClassName,
					path = d:GetFullName(),
					transparency = d.Transparency,
					canCollide = d.CanCollide,
					size = { x = d.Size.X, y = d.Size.Y, z = d.Size.Z },
					position = U.vec3Table(d.Position),
					color = color3Table(d.Color),
					material = tostring(d.Material),
				})
			elseif d:IsA("Model") and looksBall then
				local pos = U.getCharacterLikePosition(d) or U.getInstancePosition(d)
				table.insert(balls, {
					name = d.Name,
					className = d.ClassName,
					path = d:GetFullName(),
					position = pos and U.vec3Table(pos) or nil,
				})
			end
		end
		return balls
	end

	function M.collectTreeSummary(): any
		local root = M.findRoot()
		if not root then
			return { found = false }
		end
		local byClass: { [string]: number } = {}
		local sample = {}
		local n = 0
		for _, d in ipairs(root:GetDescendants()) do
			n += 1
			byClass[d.ClassName] = (byClass[d.ClassName] or 0) + 1
			if #sample < 80 then
				table.insert(sample, {
					name = d.Name,
					className = d.ClassName,
					path = d:GetFullName(),
				})
			end
		end
		return {
			found = true,
			path = root:GetFullName(),
			descendantCount = n,
			byClass = byClass,
			sample = sample,
		}
	end

	local function numberSeq(v0: number, v1: number?): NumberSequence
		local v1r = if v1 ~= nil then v1 else v0
		return NumberSequence.new({
			NumberSequenceKeypoint.new(0, v0),
			NumberSequenceKeypoint.new(1, v1r),
		})
	end

	local function colorSeq(c: Color3): ColorSequence
		return ColorSequence.new(c)
	end

	-- Solid cylinder rods (true 3D — not FaceCamera Beam billboards).
	-- SmoothPlastic (no Neon glow). Colors dimmed ~5% from pure RGB for lower brightness.
	-- Main: cyan under claw center. Prongs: green from each of 3 Arms.
	-- Prizes: amber rods / pyramids up to claw height.
	local VIS_ROD_NAME = "PortalMage_VisRod"
	local VIS_BEAM_NAME = "PortalMage_VisBeam" -- legacy Beam name (cleaned on destroy)
	local VIS_ATT0_NAME = "PortalMage_VisAtt0"
	local VIS_ATT1_NAME = "PortalMage_VisAtt1"
	local VIS_FLOOR_NAME = "PortalMage_VisFloor"
	local PRONG_ROD_FOLDER = "PortalMage_ProngRods"
	local BEAM_BRIGHTNESS = 0.95 -- ~5% dimmer color
	local function beamColor(r: number, g: number, b: number): Color3
		local k = BEAM_BRIGHTNESS
		return Color3.fromRGB(
			math.floor(r * k + 0.5),
			math.floor(g * k + 0.5),
			math.floor(b * k + 0.5)
		)
	end
	local CLAW_ROD_COLOR = beamColor(0, 255, 220)
	local CLAW_ROD_DIAMETER = 0.20 -- main center beam (slightly thinner than 0.275)
	-- Center is secondary now — prongs are the real grab columns; keep main faint.
	local CLAW_ROD_TRANSPARENCY = 0.72
	local PRONG_ROD_COLOR = beamColor(40, 220, 70) -- green side prongs
	local PRONG_ROD_DIAMETER = 0.055 -- much thinner — actual 3-prong grab columns
	local PRONG_ROD_TRANSPARENCY = 0.30
	local PRIZE_BEAM_FOLDER = "PortalMage_PrizeBeams"
	local PRIZE_ROD_COLOR = beamColor(255, 150, 40) -- amber = reachable best (grab target)
	local GLOBAL_BEST_ROD_COLOR = beamColor(60, 255, 100) -- green = global best (ignore walls)
	local PRIZE_ROD_DIAMETER = 0.15
	local PRIZE_ROD_TRANSPARENCY = 0.58
	-- All-prize markers: short pyramids (not full rods). Best prize keeps full rod.
	-- Base XZ matches best-prize rod diameter so bulk stays in height only.
	local ALL_PRIZE_PYRAMID_HEIGHT_FRAC = 0.20 -- fraction of full claw-height pillar
	local ALL_PRIZE_PYRAMID_BASE = PRIZE_ROD_DIAMETER -- width/length = best rod thickness

	local function findClawModel(): Model?
		local root = M.findRoot()
		if not root then
			return nil
		end
		local housing = root:FindFirstChild("ClawHousing")
		local claw = housing and housing:FindFirstChild("Claw")
		if claw and claw:IsA("Model") then
			return claw
		end
		return nil
	end

	local function findClawCylinder(): BasePart?
		local claw = findClawModel()
		if claw then
			local cylinder = claw:FindFirstChild("Cylinder", true)
			if cylinder and cylinder:IsA("BasePart") then
				return cylinder
			end
		end
		local root = M.findRoot()
		if not root then
			return nil
		end
		for _, d in ipairs(root:GetDescendants()) do
			if d.Name == "Cylinder" and d:IsA("BasePart") then
				return d
			end
		end
		return nil
	end

	-- World positions of the 3 prong tips (Claw.Arm ×3 → child Part "Arm").
	local function getProngTipPositions(): { Vector3 }
		local tips: { Vector3 } = {}
		local claw = findClawModel()
		if not claw then
			return tips
		end
		for _, ch in ipairs(claw:GetChildren()) do
			if ch.Name == "Arm" and ch:IsA("Model") then
				local tipPart: BasePart? = nil
				local armPart = ch:FindFirstChild("Arm")
				if armPart and armPart:IsA("BasePart") then
					tipPart = armPart
				else
					local part = ch:FindFirstChild("Part")
					if part and part:IsA("BasePart") then
						tipPart = part
					else
						for _, d in ipairs(ch:GetDescendants()) do
							if d:IsA("BasePart") and d.Name ~= "ClawMotor" then
								tipPart = d
								break
							end
						end
					end
				end
				if tipPart then
					table.insert(tips, tipPart.Position)
				end
			end
		end
		return tips
	end

	-- Prize pool floor height (Y). Prefer sample prize / game beam floor.
	local function getPrizeFloorY(): number
		if S.clawAimXZ and S.clawAimXZ.y then
			return S.clawAimXZ.y
		end
		local prizes = M.scanPrizes()
		if #prizes > 0 and prizes[1].y then
			return prizes[1].y
		end
		local gameBeam = M.findBeam()
		if gameBeam and gameBeam.Attachment1 then
			return gameBeam.Attachment1.WorldPosition.Y
		end
		return 8.0 -- dumps show prize Y ≈ 8
	end

	-- Floor point directly under the claw (same XZ). Claw beam is always vertical —
	-- never tracks the prize; prize rods are the amber pillars.
	function M.getBeamFloorUnderClaw(clawPos: Vector3?): Vector3
		local floorY = getPrizeFloorY()
		local c = clawPos or M.getClawPosition()
		if c then
			return Vector3.new(c.X, floorY, c.Z)
		end
		return Vector3.new(0, floorY, 0)
	end

	-- Kept for callers; floor aim is always under-claw (not prize-tracking).
	function M.getBeamFloorAim(): Vector3
		return M.getBeamFloorUnderClaw(nil)
	end

	function M.setBeamAimPrize(p: any?)
		-- Optional: remember prize Y for floor height samples only (not claw-beam tip).
		if p and p.y then
			S.clawAimXZ = { x = p.x, y = p.y, z = p.z }
		elseif p and p.x and p.z then
			S.clawAimXZ = { x = p.x, y = p.y, z = p.z }
		else
			S.clawAimXZ = nil
		end
	end

	-- Style a solid cylinder rod (PartType.Cylinder axis = X).
	-- SmoothPlastic — no Neon bloom/glow (was too bright).
	local function styleVisRod(part: BasePart, color: Color3, transparency: number?)
		part.Shape = Enum.PartType.Cylinder
		part.Material = Enum.Material.SmoothPlastic
		part.Color = color
		part.Transparency = transparency or 0.25
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Massless = true
	end

	-- Place cylinder so its X-axis spans a → b (true 3D volume, no camera billboard).
	local function placeRodBetween(part: BasePart, a: Vector3, b: Vector3, diameter: number)
		local delta = b - a
		local dist = delta.Magnitude
		if dist < 1e-4 then
			part.Size = Vector3.new(0.05, diameter, diameter)
			part.CFrame = CFrame.new(a)
			return
		end
		local mid = a + delta * 0.5
		part.Size = Vector3.new(dist, diameter, diameter)
		-- lookAt uses −Z forward; rotate so cylinder X aligns with a→b
		part.CFrame = CFrame.lookAt(mid, b) * CFrame.Angles(0, math.rad(90), 0)
	end

	local function makeRodPart(name: string, parent: Instance, color: Color3, transparency: number?): BasePart
		local part = Instance.new("Part")
		part.Name = name
		styleVisRod(part, color, transparency)
		part.Size = Vector3.new(1, 0.2, 0.2)
		part.Parent = parent
		return part
	end

	-- All-prize marker: square pyramid (4 wedges), tip up, sitting on the prize.
	local function stylePyramidWedge(w: BasePart, color: Color3, transparency: number)
		w.Material = Enum.Material.SmoothPlastic -- no Neon glow
		w.Color = color
		w.Transparency = transparency
		w.Anchored = true
		w.CanCollide = false
		w.CanQuery = false
		w.CanTouch = false
		w.CastShadow = false
		w.Massless = true
	end

	local function makePyramidModel(name: string, parent: Instance): Model
		local model = Instance.new("Model")
		model.Name = name
		for i = 1, 4 do
			local w = Instance.new("WedgePart")
			w.Name = "W" .. tostring(i)
			stylePyramidWedge(w, PRIZE_ROD_COLOR, PRIZE_ROD_TRANSPARENCY)
			w.Parent = model
		end
		model.Parent = parent
		return model
	end

	-- Height h, base center at (px,py,pz), tip at (px, py+h, pz).
	-- Width/length fixed to best-prize rod diameter (was 0.22–0.5 and scaled with h → bulky).
	local function placePyramidAt(model: Model, px: number, py: number, pz: number, h: number)
		h = math.max(0.12, h)
		local base = ALL_PRIZE_PYRAMID_BASE or PRIZE_ROD_DIAMETER or 0.15
		local wedges: { WedgePart } = {}
		for _, ch in ipairs(model:GetChildren()) do
			if ch:IsA("WedgePart") then
				table.insert(wedges, ch :: WedgePart)
			end
		end
		while #wedges < 4 do
			local w = Instance.new("WedgePart")
			w.Name = "W" .. tostring(#wedges + 1)
			stylePyramidWedge(w, PRIZE_ROD_COLOR, PRIZE_ROD_TRANSPARENCY)
			w.Parent = model
			table.insert(wedges, w)
		end
		-- Four wedges → square pyramid (standard layout)
		for i = 1, 4 do
			local w = wedges[i]
			stylePyramidWedge(w, PRIZE_ROD_COLOR, PRIZE_ROD_TRANSPARENCY)
			w.Size = Vector3.new(base, h, base * 0.5)
			local yaw = math.rad((i - 1) * 90)
			w.CFrame = CFrame.new(px, py + h * 0.5, pz)
				* CFrame.Angles(0, yaw, 0)
				* CFrame.new(0, 0, base * 0.25)
				* CFrame.Angles(math.rad(180), 0, 0)
		end
	end

	function M.destroyInjectedBeam()
		pcall(function()
			if S.clawVisBeam and S.clawVisBeam.Parent then
				S.clawVisBeam:Destroy()
			end
		end)
		pcall(function()
			if S.clawProngRods and S.clawProngRods.Parent then
				S.clawProngRods:Destroy()
			end
		end)
		pcall(function()
			local root = M.findRoot()
			local host: Instance = root or workspace
			for _, name in ipairs({
				VIS_ROD_NAME,
				VIS_BEAM_NAME,
				VIS_FLOOR_NAME,
				VIS_ATT0_NAME,
				VIS_ATT1_NAME,
				PRONG_ROD_FOLDER,
			}) do
				local inst = host:FindFirstChild(name)
				if inst then
					inst:Destroy()
				end
			end
			local cyl = findClawCylinder()
			if cyl then
				for _, name in ipairs({ VIS_ROD_NAME, VIS_BEAM_NAME, VIS_ATT0_NAME }) do
					local old = cyl:FindFirstChild(name)
					if old then
						old:Destroy()
					end
				end
			end
		end)
		S.clawVisBeam = nil
		S.clawProngRods = nil
	end

	local function ensureProngRodFolder(host: Instance): Folder
		local folder = S.clawProngRods
		if folder and folder.Parent then
			return folder :: Folder
		end
		folder = host:FindFirstChild(PRONG_ROD_FOLDER)
		if not (folder and folder:IsA("Folder")) then
			folder = Instance.new("Folder")
			folder.Name = PRONG_ROD_FOLDER
			folder.Parent = host
		end
		S.clawProngRods = folder
		return folder :: Folder
	end

	function M.ensureInjectedBeam(): (boolean, string)
		local clawPos = M.getClawPosition()
		if not clawPos then
			return false, "claw position not found"
		end
		local root = M.findRoot()
		local host: Instance = root or workspace
		local floorY = getPrizeFloorY()

		-------------------------------------------------------------------
		-- Main center rod (slightly thinner cyan under PrizeDetect / center)
		-------------------------------------------------------------------
		local nadir = Vector3.new(clawPos.X, floorY, clawPos.Z)
		local rod = S.clawVisBeam
		if not (rod and rod.Parent and rod:IsA("BasePart")) then
			rod = host:FindFirstChild(VIS_ROD_NAME)
			if not (rod and rod:IsA("BasePart")) then
				rod = makeRodPart(VIS_ROD_NAME, host, CLAW_ROD_COLOR, CLAW_ROD_TRANSPARENCY)
			else
				styleVisRod(rod :: BasePart, CLAW_ROD_COLOR, CLAW_ROD_TRANSPARENCY)
			end
			S.clawVisBeam = rod
		end
		styleVisRod(rod :: BasePart, CLAW_ROD_COLOR, CLAW_ROD_TRANSPARENCY)
		placeRodBetween(rod :: BasePart, clawPos, nadir, CLAW_ROD_DIAMETER)

		-------------------------------------------------------------------
		-- Three prong rods — actual grab columns from each Claw.Arm tip down
		-------------------------------------------------------------------
		local tips = getProngTipPositions()
		local folder = ensureProngRodFolder(host)
		local keep: { [string]: boolean } = {}
		for i, tip in ipairs(tips) do
			local key = string.format("Prong%d", i)
			keep[key] = true
			local prong = folder:FindFirstChild(key)
			if not (prong and prong:IsA("BasePart")) then
				if prong then
					prong:Destroy()
				end
				prong = makeRodPart(key, folder, PRONG_ROD_COLOR, PRONG_ROD_TRANSPARENCY)
			else
				styleVisRod(prong :: BasePart, PRONG_ROD_COLOR, PRONG_ROD_TRANSPARENCY)
			end
			local foot = Vector3.new(tip.X, floorY, tip.Z)
			placeRodBetween(prong :: BasePart, tip, foot, PRONG_ROD_DIAMETER)
		end
		for _, child in ipairs(folder:GetChildren()) do
			if not keep[child.Name] then
				child:Destroy()
			end
		end

		return true, string.format(
			"main d=%.2f + %d prongs d=%.3f → floor Y=%.1f",
			CLAW_ROD_DIAMETER,
			#tips,
			PRONG_ROD_DIAMETER,
			floorY
		)
	end

	local function maintainLoop()
		while S.clawBeamEnabled do
			pcall(function()
				M.ensureInjectedBeam()
			end)
			task.wait(MAINTAIN_INTERVAL)
		end
		S.clawBeamThread = nil
	end

	function M.setEnabled(on: boolean)
		S.clawBeamEnabled = on and true or false
		if S.ui and S.ui.setClawBeamLabel then
			S.ui.setClawBeamLabel(S.clawBeamEnabled)
		end
		if S.clawBeamEnabled then
			local ok, msg = M.ensureInjectedBeam()
			if ok then
				setStatus("Claw Beam ON — " .. msg)
			else
				setStatus("Claw Beam ON — inject failed: " .. tostring(msg))
			end
			if not S.clawBeamThread then
				S.clawBeamThread = task.spawn(maintainLoop)
			end
		else
			M.destroyInjectedBeam()
			S.clawAimXZ = nil
			setStatus("Claw Beam OFF — removed main + prong rods")
		end
	end

	function M.toggle()
		M.setEnabled(not S.clawBeamEnabled)
	end

	---------------------------------------------------------------------------
	-- Prize rods: each ball gets a solid amber cylinder up to claw height.
	---------------------------------------------------------------------------
	function M.destroyPrizeBeams()
		pcall(function()
			if S.clawPrizeBeamsFolder and S.clawPrizeBeamsFolder.Parent then
				S.clawPrizeBeamsFolder:Destroy()
			end
		end)
		pcall(function()
			local root = M.findRoot()
			if root then
				local f = root:FindFirstChild(PRIZE_BEAM_FOLDER)
				if f then
					f:Destroy()
				end
			end
			local ws = workspace:FindFirstChild(PRIZE_BEAM_FOLDER)
			if ws then
				ws:Destroy()
			end
		end)
		S.clawPrizeBeamsFolder = nil
	end

	-- Any prize-rod display active? (all-prizes and/or best-only mode)
	function M.prizeBeamsWanted(): boolean
		return S.clawPrizeBeamsEnabled == true or S.clawPrizeBeamsBestOnly == true
	end

	local function snapshotLock(entry: any, note: string): any
		entry._lockNote = note
		entry._lockAt = os.clock()
		entry.inset = entry.inset or M.prizeInsetScore(entry.x, entry.z)
		return entry
	end

	local function formatLockTag(entry: any, note: string, n: number): string
		return string.format(
			"P%d %s kw=%s inset=%.2f %s (%d scanned)",
			entry.priority or -1,
			tostring(entry.name),
			tostring(entry.matchedKeyword or "other"),
			entry.inset or 0,
			note,
			n
		)
	end

	-- One-shot best picks at button press. Not re-run every maintain tick.
	-- Returns reachable best (grab target), plus locks global best (ignore walls).
	function M.lockBestPrizeFromScan(opts: any?): (any?, string)
		opts = opts or {}
		local prizes = opts.prizes or M.scanPrizes()
		local clawPos = opts.clawPos or M.getClawPosition()
		local n = #prizes

		-- Amber: best inside reach box (same as grab intention)
		local reachBest = M.pickBestPrize(prizes, clawPos, { requireReachable = true })
		local reachNote = "reach"
		if not reachBest then
			reachBest = M.pickBestPrize(prizes, clawPos, { requireReachable = false })
			reachNote = "any(no-reach)"
		end
		if reachBest then
			-- Copy fields so global pick can be a separate table if same prize
			local snap = {
				inst = reachBest.inst,
				name = reachBest.name,
				path = reachBest.path,
				priority = reachBest.priority,
				matchedKeyword = reachBest.matchedKeyword,
				x = reachBest.x,
				y = reachBest.y,
				z = reachBest.z,
				radiusXZ = reachBest.radiusXZ,
				_skippedUnreachable = reachBest._skippedUnreachable,
				_skippedBlocked = reachBest._skippedBlocked,
				_bestWallHigh = reachBest._bestWallHigh,
			}
			S.clawBestPrizeLocked = snapshotLock(snap, reachNote)
		else
			S.clawBestPrizeLocked = nil
		end

		-- Green: absolute best priority in the whole set (ignore reach box)
		local globalBest = M.pickBestPrize(prizes, clawPos, { requireReachable = false })
		if globalBest then
			local gsnap = {
				inst = globalBest.inst,
				name = globalBest.name,
				path = globalBest.path,
				priority = globalBest.priority,
				matchedKeyword = globalBest.matchedKeyword,
				x = globalBest.x,
				y = globalBest.y,
				z = globalBest.z,
				radiusXZ = globalBest.radiusXZ,
			}
			S.clawGlobalBestPrizeLocked = snapshotLock(gsnap, "global")
		else
			S.clawGlobalBestPrizeLocked = nil
		end

		local parts = {}
		if S.clawBestPrizeLocked then
			table.insert(parts, "amber=" .. formatLockTag(S.clawBestPrizeLocked, reachNote, n))
		else
			table.insert(parts, "amber=none")
		end
		if S.clawGlobalBestPrizeLocked then
			table.insert(parts, "green=" .. formatLockTag(S.clawGlobalBestPrizeLocked, "global", n))
		else
			table.insert(parts, "green=none")
		end
		local tag = table.concat(parts, " | ")
		if not S.clawBestPrizeLocked and not S.clawGlobalBestPrizeLocked then
			return nil, string.format("none (%d scanned, box=%s)", n, M.formatReachBounds())
		end
		-- Grab / Start still use reachable (amber) as primary return
		return S.clawBestPrizeLocked, tag
	end

	function M.clearBestPrizeLock()
		S.clawBestPrizeLocked = nil
		S.clawGlobalBestPrizeLocked = nil
	end

	-- Refresh locked prize pose from its Instance only (never re-pick).
	local function refreshLockedSlot(slotKey: string): any?
		local lock = if slotKey == "global" then S.clawGlobalBestPrizeLocked else S.clawBestPrizeLocked
		if not lock then
			return nil
		end
		local note, lockAt = lock._lockNote, lock._lockAt
		if lock.inst and lock.inst.Parent then
			local refreshed = M.refreshPrize(lock)
			if refreshed then
				refreshed._lockNote = note
				refreshed._lockAt = lockAt
				if slotKey == "global" then
					S.clawGlobalBestPrizeLocked = refreshed
				else
					S.clawBestPrizeLocked = refreshed
				end
				return refreshed
			end
		end
		if type(lock.x) == "number" and type(lock.z) == "number" then
			return lock
		end
		return nil
	end

	function M.getLockedBestPrize(): any?
		return refreshLockedSlot("reach")
	end

	function M.getLockedGlobalBestPrize(): any?
		return refreshLockedSlot("global")
	end

	local function startPrizeBeamsLoop()
		if not S.clawPrizeBeamsThread then
			S.clawPrizeBeamsThread = task.spawn(function()
				while M.prizeBeamsWanted() do
					local ok, err = pcall(function()
						M.ensurePrizeBeams()
					end)
					if not ok and setStatus then
						pcall(function()
							setStatus("Prize beams error: " .. tostring(err))
						end)
					end
					task.wait(MAINTAIN_INTERVAL)
				end
				S.clawPrizeBeamsThread = nil
			end)
		end
	end

	local function stopPrizeBeamsIfIdle()
		if not M.prizeBeamsWanted() then
			M.destroyPrizeBeams()
		end
	end

	local function placeBestRod(
		folder: Folder,
		key: string,
		prize: any,
		color: Color3,
		clawY: number,
		keep: { [string]: boolean }
	): boolean
		if not prize or type(prize.x) ~= "number" or type(prize.z) ~= "number" then
			return false
		end
		keep[key] = true
		local px, py, pz = prize.x, prize.y or 8, prize.z
		local topY = math.max(clawY, py + 2)
		local rod = folder:FindFirstChild(key)
		if rod and not rod:IsA("BasePart") then
			rod:Destroy()
			rod = nil
		end
		if not (rod and rod:IsA("BasePart")) then
			rod = makeRodPart(key, folder, color, PRIZE_ROD_TRANSPARENCY)
		else
			styleVisRod(rod :: BasePart, color, PRIZE_ROD_TRANSPARENCY)
		end
		placeRodBetween(
			rod :: BasePart,
			Vector3.new(px, py, pz),
			Vector3.new(px, topY, pz),
			PRIZE_ROD_DIAMETER
		)
		;(rod :: BasePart).Transparency = PRIZE_ROD_TRANSPARENCY
		return true
	end

	-- All prizes → short pyramids (live scan).
	-- Best mode → amber rod = reachable lock; green rod = global lock (ignore walls).
	function M.ensurePrizeBeams(): (boolean, string)
		if not M.prizeBeamsWanted() then
			M.destroyPrizeBeams()
			return true, "off"
		end

		local root = M.findRoot()
		if not root then
			return false, "Event_ClawMachine not found"
		end
		local clawPos = M.getClawPosition()
		local clawY = clawPos and math.max(clawPos.Y, 12) or 15

		local showAll = S.clawPrizeBeamsEnabled == true
		local showBest = S.clawPrizeBeamsBestOnly == true

		-- Live positions only for pyramid mode
		local prizes = if showAll then M.scanPrizes() else {}

		local best = nil
		local globalBest = nil
		local bestTag = ""
		if showBest then
			best = M.getLockedBestPrize()
			globalBest = M.getLockedGlobalBestPrize()
			local bits = {}
			if best then
				table.insert(bits, string.format(
					"amber=P%d %s (%s)",
					best.priority or -1,
					tostring(best.name),
					tostring(best._lockNote or "reach")
				))
			else
				table.insert(bits, "amber=nil")
			end
			if globalBest then
				table.insert(bits, string.format(
					"green=P%d %s (global)",
					globalBest.priority or -1,
					tostring(globalBest.name)
				))
			else
				table.insert(bits, "green=nil")
			end
			bestTag = " " .. table.concat(bits, " ")
			if not best and not globalBest then
				bestTag = " locked=nil (press Best Prize to scan)"
			end
		end

		local folder = S.clawPrizeBeamsFolder
		if not (folder and folder.Parent) then
			folder = root:FindFirstChild(PRIZE_BEAM_FOLDER)
			if not folder then
				folder = Instance.new("Folder")
				folder.Name = PRIZE_BEAM_FOLDER
				folder.Parent = root
			end
			S.clawPrizeBeamsFolder = folder
		end

		local keep: { [string]: boolean } = {}
		local nPyramids, nRods = 0, 0

		if showAll then
			for i, p in ipairs(prizes) do
				local px, py, pz = p.x, p.y or 8, p.z
				if type(px) == "number" and type(pz) == "number" then
					local key = string.format("P%02d", i)
					keep[key] = true
					local marker = folder:FindFirstChild(key)
					if marker and not marker:IsA("Model") then
						marker:Destroy()
						marker = nil
					end
					if not (marker and marker:IsA("Model")) then
						marker = makePyramidModel(key, folder)
					end
					local topY = math.max(clawY, py + 2)
					local fullH = math.max(0.5, topY - py)
					local h = fullH * ALL_PRIZE_PYRAMID_HEIGHT_FRAC
					placePyramidAt(marker :: Model, px, py, pz, h)
					nPyramids += 1
				end
			end
		end

		if showBest then
			if placeBestRod(folder :: Folder, "BEST", best, PRIZE_ROD_COLOR, clawY, keep) then
				nRods += 1
			end
			-- Green global rod (skip if same instance as amber to avoid z-fight double)
			local sameAsAmber = best
				and globalBest
				and best.inst
				and globalBest.inst
				and best.inst == globalBest.inst
			if not sameAsAmber then
				if placeBestRod(
					folder :: Folder,
					"BEST_GLOBAL",
					globalBest,
					GLOBAL_BEST_ROD_COLOR,
					clawY,
					keep
				) then
					nRods += 1
				end
			end
		end

		for _, child in ipairs(folder:GetChildren()) do
			if not keep[child.Name] then
				child:Destroy()
			end
		end

		return true, string.format(
			"pyramids=%d rods=%d clawY=%.1f%s",
			nPyramids,
			nRods,
			clawY,
			bestTag
		)
	end

	function M.setPrizeBeamsEnabled(on: boolean)
		S.clawPrizeBeamsEnabled = on and true or false
		if S.ui and S.ui.setClawPrizeBeamsLabel then
			S.ui.setClawPrizeBeamsLabel(S.clawPrizeBeamsEnabled)
		end
		if M.prizeBeamsWanted() then
			local ok, msg = M.ensurePrizeBeams()
			if ok then
				setStatus(string.format("Prize Beams ON — %s", msg))
			else
				setStatus("Prize Beams ON — failed: " .. tostring(msg))
			end
			startPrizeBeamsLoop()
		else
			stopPrizeBeamsIfIdle()
			setStatus("Prize Beams OFF — removed " .. PRIZE_BEAM_FOLDER)
		end
	end

	function M.togglePrizeBeams()
		M.setPrizeBeamsEnabled(not S.clawPrizeBeamsEnabled)
	end

	function M.setBestPrizeOnly(on: boolean)
		S.clawPrizeBeamsBestOnly = on and true or false
		if S.ui and S.ui.setClawBestPrizeLabel then
			S.ui.setClawBestPrizeLabel(S.clawPrizeBeamsBestOnly)
		end
		if S.clawPrizeBeamsBestOnly then
			-- ONE-SHOT: amber = reachable best, green = global best (ignore walls)
			local _, tag = M.lockBestPrizeFromScan({ requireReachable = true })
			setStatus("Best locked — " .. tag)
			local ok, msg = M.ensurePrizeBeams()
			if not ok then
				setStatus("Best Prize ON — beam failed: " .. tostring(msg))
			end
			startPrizeBeamsLoop()
		else
			M.clearBestPrizeLock()
			if M.prizeBeamsWanted() then
				M.ensurePrizeBeams()
				startPrizeBeamsLoop()
				setStatus("Best Prize OFF (locks cleared)")
			else
				stopPrizeBeamsIfIdle()
				setStatus("Best Prize OFF")
			end
		end
	end

	function M.toggleBestPrizeOnly()
		M.setBestPrizeOnly(not S.clawPrizeBeamsBestOnly)
	end

	function M.reportStatus()
		local info = M.inspectBeam()
		local balls = M.collectBalls()
		local prizes = M.scanPrizes()
		local inj = S.clawVisBeam
		local injOk = inj and inj.Parent and inj:IsA("BasePart")
		local prizeOn = S.clawPrizeBeamsEnabled
		if injOk or prizeOn then
			setStatus(string.format(
				"Claw rod=%s (cyan) | prize rods=%s (amber) n=%d | balls=%d",
				injOk and "ON" or "OFF",
				prizeOn and "ON" or "OFF",
				#prizes,
				#balls
			))
			return
		end
		if not info then
			setStatus(string.format("Claw: machine/beam missing | inject OFF | prizes=%d", #prizes))
			return
		end
		setStatus(string.format(
			"Claw inject OFF | game beam Enabled=%s W=%.3f | prizes=%d",
			tostring(info.enabled),
			info.width0 or 0,
			#prizes
		))
	end

	function M.dumpClaw()
		setStatus("Dumping claw machine…")
		local stamp = os.date("%Y-%m-%d_%H-%M-%S")
		local beam = M.inspectBeam()
		local balls = M.collectBalls()
		local tree = M.collectTreeSummary()
		local prizes = M.scanPrizes()
		-- strip Instance refs for JSON
		local prizesJson = {}
		for _, p in ipairs(prizes) do
			table.insert(prizesJson, {
				name = p.name,
				path = p.path,
				priority = p.priority,
				matchedKeyword = p.matchedKeyword,
				-- geometric center (aim point), not a corner
				center = { x = p.x, y = p.y, z = p.z },
				position = { x = p.x, y = p.y, z = p.z },
				radiusXZ = p.radiusXZ,
				size = p.size and { x = p.size.X, y = p.size.Y, z = p.size.Z } or nil,
			})
		end
		local payload = {
			type = "claw_machine",
			timestamp = stamp,
			beam = beam,
			ballCount = #balls,
			balls = balls,
			prizes = prizesJson,
			prizeCount = #prizesJson,
			tree = tree,
			forceEnabled = S.clawBeamEnabled,
			clawPosition = (function()
				local p = M.getClawPosition()
				return p and U.vec3Table(p) or nil
			end)(),
		}
		local path = string.format("%s/claw_%s.json", C.DUMP_DIR, stamp)
		local ok, err = pcall(function()
			U.ensureDir(C.DUMP_DIR)
			writefile(path, HttpService:JSONEncode(payload))
		end)
		if ok then
			local vis = beam and (beam.playerVisible and "VISIBLE" or ("INVISIBLE:" .. tostring(beam.invisibleReason))) or "no-beam"
			setStatus(string.format("Claw dump OK: %s | beam %s | %d prizes", path, vis, #prizesJson))
		else
			setStatus("Claw dump failed: " .. tostring(err))
		end
		return payload
	end

	function M.snapshotFragment(): any
		local prizes = M.scanPrizes()
		local prizesJson = {}
		for _, p in ipairs(prizes) do
			table.insert(prizesJson, {
				name = p.name,
				path = p.path,
				priority = p.priority,
				matchedKeyword = p.matchedKeyword,
				center = { x = p.x, y = p.y, z = p.z },
				position = { x = p.x, y = p.y, z = p.z },
				radiusXZ = p.radiusXZ,
			})
		end
		local clawPos = M.getClawPosition()
		return {
			beam = M.inspectBeam(),
			balls = M.collectBalls(),
			prizes = prizesJson,
			prizeCount = #prizesJson,
			tree = M.collectTreeSummary(),
			forceEnabled = S.clawBeamEnabled,
			clawPosition = clawPos and U.vec3Table(clawPos) or nil,
			busy = S.clawBusy,
		}
	end

	---------------------------------------------------------------------------
	-- Logging (HUD ring + file + print) — for diagnosing stuck runs
	---------------------------------------------------------------------------

	local function fmtVec(v: Vector3?): string
		if not v then
			return "nil"
		end
		return string.format("(%.3f, %.3f, %.3f)", v.X, v.Y, v.Z)
	end

	local function fmtXZ(x: number?, z: number?): string
		if x == nil or z == nil then
			return "nil"
		end
		return string.format("(%.3f, %.3f)", x, z)
	end

	-- Short prize tag for every decision log line
	local function prizeTag(p: any?): string
		if not p then
			return "prize=nil"
		end
		return string.format(
			"prize=P%d %s kw=%s @%s",
			p.priority or -1,
			tostring(p.name),
			tostring(p.matchedKeyword or "other"),
			fmtXZ(p.x, p.z)
		)
	end

	function M.clearLogs()
		S.clawLogLines = {}
		S.clawLogPath = nil
		S._clawLogT0 = nil
		if S.ui and S.ui.setClawLog then
			S.ui.setClawLog("(log cleared)")
		end
	end

	function M.getLogText(): string
		local lines = S.clawLogLines or {}
		if #lines == 0 then
			return "(no claw logs yet)"
		end
		return table.concat(lines, "\n")
	end

	local function refreshLogUi()
		if S.ui and S.ui.setClawLog then
			S.ui.setClawLog(M.getLogText())
		end
	end

	-- level: "INFO" | "WARN" | "ERR" | "STEP" | "PHASE"
	function M.log(level: string, msg: string, alsoStatus: boolean?)
		local elapsed = ""
		if S.clawBusy and S._clawLogT0 then
			elapsed = string.format(" +%.2fs", os.clock() - S._clawLogT0)
		end
		local line = string.format("[%s%s] %s", level, elapsed, msg)
		-- Console (executor)
		pcall(function()
			print("[portal_mage/claw] " .. line)
		end)
		-- Ring buffer for HUD
		if type(S.clawLogLines) ~= "table" then
			S.clawLogLines = {}
		end
		table.insert(S.clawLogLines, line)
		local maxUi = C.CLAW_LOG_UI_LINES or 12
		while #S.clawLogLines > math.max(maxUi, 40) do
			table.remove(S.clawLogLines, 1)
		end
		-- Keep UI to last N
		local uiLines = {}
		local start = math.max(1, #S.clawLogLines - maxUi + 1)
		for i = start, #S.clawLogLines do
			table.insert(uiLines, S.clawLogLines[i])
		end
		if S.ui and S.ui.setClawLog then
			S.ui.setClawLog(table.concat(uiLines, "\n"))
		end
		-- Append to run file
		if S.clawLogPath then
			pcall(function()
				local prev = ""
				if isfile and isfile(S.clawLogPath) then
					prev = readfile(S.clawLogPath)
				end
				writefile(S.clawLogPath, prev .. line .. "\n")
			end)
		end
		if alsoStatus ~= false then
			-- STEP logs update status less noisily only every few; default true for phases
			if level ~= "STEP" or alsoStatus == true then
				setStatus("Claw " .. msg)
			end
		end
	end

	local function beginRunLog(token: number)
		-- Fresh HUD + file every execution (no clutter from prior runs)
		M.clearLogs()
		S._clawLogT0 = os.clock()
		S.clawLogLines = {}
		local stamp = os.date("%Y-%m-%d_%H-%M-%S")
		local dir = C.CLAW_LOG_DIR or C.DUMP_DIR or "dumps"
		pcall(function()
			U.ensureDir(dir)
		end)
		S.clawLogPath = string.format("%s/claw_run_%s_t%d.log", dir, stamp, token)
		pcall(function()
			writefile(S.clawLogPath, string.format(
				"# portal_mage claw run log\n# token=%d started=%s\n",
				token,
				stamp
			))
		end)
		if S.ui and S.ui.setClawLog then
			S.ui.setClawLog("(new run…)")
		end
		M.log("PHASE", "run start → log " .. tostring(S.clawLogPath))
	end

	---------------------------------------------------------------------------
	-- One-shot aim + drop sequence
	---------------------------------------------------------------------------

	local function releaseMoveKeys()
		for _, key in ipairs(MOVE_KEYS) do
			pcall(function()
				VIM:SendKeyEvent(false, key, false, game)
			end)
		end
	end

	local function keyDown(key: Enum.KeyCode)
		pcall(function()
			VIM:SendKeyEvent(true, key, false, game)
		end)
	end

	local function keyUp(key: Enum.KeyCode)
		pcall(function()
			VIM:SendKeyEvent(false, key, false, game)
		end)
	end

	-- Single short tap (corrections only — not used for primary travel)
	local function tapKey(key: Enum.KeyCode, duration: number)
		keyDown(key)
		task.wait(duration)
		keyUp(key)
	end

	local function oppositeKey(key: Enum.KeyCode): Enum.KeyCode?
		if key == Enum.KeyCode.A then
			return Enum.KeyCode.D
		elseif key == Enum.KeyCode.D then
			return Enum.KeyCode.A
		elseif key == Enum.KeyCode.W then
			return Enum.KeyCode.S
		elseif key == Enum.KeyCode.S then
			return Enum.KeyCode.W
		end
		return nil
	end

	local function stillRunning(token: number): boolean
		return S.clawBusy and S.clawRunToken == token
	end

	local function xzError(claw: Vector3, prizeX: number, prizeZ: number): (number, number, number)
		local dx = prizeX - claw.X
		local dz = prizeZ - claw.Z
		return dx, dz, math.sqrt(dx * dx + dz * dz)
	end

	local function withinThreshold(dist: number, thr: number): boolean
		return dist <= thr
	end

	-- Distance from point P to segment A→B (clamped). Returns radial dist, t∈[0,1].
	local function pointToSegmentDist(p: Vector3, a: Vector3, b: Vector3): (number, number)
		local ab = b - a
		local abLen2 = ab:Dot(ab)
		if abLen2 < 1e-12 then
			return (p - a).Magnitude, 0
		end
		local t = math.clamp((p - a):Dot(ab) / abLen2, 0, 1)
		local closest = a + ab * t
		return (p - closest).Magnitude, t
	end

	-- Claw beam axis: vertical under claw (matches cyan visual rod).
	-- Prize beam axis: prize center → same XZ at claw height (amber rod).
	function M.encapsulationMargins(): (number, number, number, number)
		local clawR = (CLAW_ROD_DIAMETER or 0.2754) * 0.5
		local prizeR = (PRIZE_ROD_DIAMETER or 0.15) * 0.5
		local hard = C.CLAW_ENCAP_HARD_MARGIN
		if hard == nil then
			hard = math.max(0.04, clawR - prizeR)
		end
		local soft = C.CLAW_ENCAP_SOFT_MARGIN
		if soft == nil then
			soft = math.max(hard * 1.5, clawR)
		end
		return hard, soft, clawR, prizeR
	end

	-- Max radial distance of the prize rod from the vertical claw rod.
	-- Fully encapsulated when prize column sits inside the claw's downward cylinder.
	function M.prizeInClawBeam(
		clawPos: Vector3,
		prizeX: number,
		prizeY: number,
		prizeZ: number
	): (number, number, number)
		local floorY = prizeY
		if S.clawAimXZ and S.clawAimXZ.y then
			floorY = S.clawAimXZ.y
		end
		-- Claw rod: tip straight down (same XZ as claw)
		local a = clawPos
		local b = Vector3.new(clawPos.X, floorY, clawPos.Z)
		-- Prize rod: center up to claw height
		local clawY = clawPos.Y
		local c = Vector3.new(prizeX, prizeY, prizeZ)
		local d = Vector3.new(prizeX, clawY, prizeZ)

		local maxRadial = 0
		local samples = 10
		for i = 0, samples do
			local t = i / samples
			local p = c:Lerp(d, t)
			local radial = pointToSegmentDist(p, a, b)
			if radial > maxRadial then
				maxRadial = radial
			end
		end
		local hardM, softM = M.encapsulationMargins()
		return maxRadial, hardM, softM
	end

	function M.isEncapsulatedHard(clawPos: Vector3, prize: any): boolean
		if not clawPos or not prize then
			return false
		end
		local maxR, hardM = M.prizeInClawBeam(clawPos, prize.x, prize.y or 8, prize.z)
		return maxR <= hardM
	end

	function M.isEncapsulatedSoft(clawPos: Vector3, prize: any): boolean
		if not clawPos or not prize then
			return false
		end
		local maxR, _, softM = M.prizeInClawBeam(clawPos, prize.x, prize.y or 8, prize.z)
		return maxR <= softM
	end

	-- Primary "above prize" test: encapsulation when enabled, else dXZ thr.
	local function isAboveHard(clawPos: Vector3, prize: any, distXZ: number, thr: number): boolean
		if C.CLAW_ALIGN_USE_ENCAPSULATION ~= false then
			return M.isEncapsulatedHard(clawPos, prize)
		end
		return withinThreshold(distXZ, thr)
	end

	local function isAboveSoft(clawPos: Vector3, prize: any, distXZ: number, softThr: number): boolean
		if C.CLAW_ALIGN_USE_ENCAPSULATION ~= false then
			return M.isEncapsulatedSoft(clawPos, prize)
		end
		return distXZ <= softThr
	end

	local function encapLogBits(clawPos: Vector3?, prize: any?): string
		if not clawPos or not prize then
			return "encap=?"
		end
		local maxR, hardM, softM = M.prizeInClawBeam(clawPos, prize.x, prize.y or 8, prize.z)
		return string.format(
			"encapR=%.3f hard≤%.3f soft≤%.3f %s",
			maxR,
			hardM,
			softM,
			maxR <= hardM and "FULL" or (maxR <= softM and "SOFT" or "OUT")
		)
	end

	-- Cardinal-only key for the larger axis error.
	-- Map (player-measured): W=+Z S=-Z A=+X D=-X
	local function pickMoveKey(dx: number, dz: number): Enum.KeyCode?
		if math.abs(dx) < 1e-9 and math.abs(dz) < 1e-9 then
			return nil
		end
		if math.abs(dx) >= math.abs(dz) then
			if dx > 0 then
				return Enum.KeyCode.A -- need +X
			else
				return Enum.KeyCode.D -- need -X
			end
		else
			if dz > 0 then
				return Enum.KeyCode.W -- need +Z
			else
				return Enum.KeyCode.S -- need -Z
			end
		end
	end

	-- Signed error along the axis this key is correcting (prize - claw).
	-- Positive means we still want this key's direction.
	local function axisSignedError(key: Enum.KeyCode, claw: Vector3, prizeX: number, prizeZ: number): number
		if key == Enum.KeyCode.A then
			return prizeX - claw.X -- want +X
		elseif key == Enum.KeyCode.D then
			return claw.X - prizeX -- want -X, positive while still too far +X of target
		elseif key == Enum.KeyCode.W then
			return prizeZ - claw.Z -- want +Z
		elseif key == Enum.KeyCode.S then
			return claw.Z - prizeZ -- want -Z
		end
		return 0
	end

	local function setRunLabel(text: string)
		if S.ui and S.ui.setClawRunLabel then
			S.ui.setClawRunLabel(text)
		end
	end

	function M.cancelSequence(reason: string?)
		local why = reason or "Claw: cancelled"
		if not S.clawBusy then
			releaseMoveKeys()
			M.log("INFO", "cancel ignored (not running): " .. why, false)
			return
		end
		M.log("PHASE", "CANCEL " .. why)
		S.clawBusy = false
		S.clawRunToken = (S.clawRunToken or 0) + 1
		M.setBeamAimPrize(nil)
		releaseMoveKeys()
		setRunLabel("idle")
		setStatus(why)
	end

	function M.startSequence()
		if S.clawBusy then
			M.log("WARN", "start blocked — already running (Cancel first)")
			return
		end
		if not M.findRoot() then
			M.log("ERR", "Event_ClawMachine not found")
			setStatus("Claw: Event_ClawMachine not found")
			return
		end

		-- Isolated mode: ignore prox / combat gates. Only drop local Walk+Atk so
		-- WASD is not stolen by pathing on the same keys (no prox freeze, no combat).
		if S.walking or S.combatBusy then
			M.log("INFO", string.format(
				"releasing walk/combat for key ownership (walking=%s combatBusy=%s)",
				tostring(S.walking),
				tostring(S.combatBusy)
			), false)
			S.walking = false
			S.combatBusy = false
			S.proximityResumeWalk = false
			if S.ui and S.ui.setWalkLabel then
				S.ui.setWalkLabel(false)
			end
		end

		local token = (S.clawRunToken or 0) + 1
		S.clawRunToken = token
		S.clawBusy = true
		setRunLabel("running")
		beginRunLog(token)

		task.spawn(function()
			local thr = C.CLAW_ALIGN_THRESHOLD or 0.08
			local softThr = C.CLAW_ALIGN_SOFT_THRESHOLD or (thr * 2)
			local orbitHolds = C.CLAW_ORBIT_HOLDS or 8
			local nearTapDist = C.CLAW_NEAR_TAP_DIST or 0.22
			local holdPoll = C.CLAW_HOLD_POLL or 0.03
			local holdMax = C.CLAW_HOLD_MAX or 2.5
			local correctTap = C.CLAW_CORRECT_TAP or 0.05
			local releaseSlack = C.CLAW_HOLD_RELEASE_SLACK or 0.02
			local axisGood = thr -- per-axis stop band
			local releaseAt = math.max(axisGood, thr + releaseSlack) -- release a hair early
			local stableChecks = C.CLAW_STABLE_CHECKS or 2
			local stableInterval = C.CLAW_STABLE_INTERVAL or 0.10
			local maxSeconds = C.CLAW_MAX_SECONDS or 90
			local t0 = os.clock()
			local alignSteps = 0
			local holdCount = 0
			local correctCount = 0
			local reaimCount = 0
			local bestDist = math.huge
			local nearHoldStreak = 0 -- holds while dist in (thr, softThr]
			local recentKeys: { string } = {}
			local zeroMoveStreak = 0 -- consecutive holds with almost no claw travel
			local forceKey: Enum.KeyCode? = nil -- after zero-travel hold_max, try other axis

			local function elapsed(): number
				return os.clock() - t0
			end

			local function timedOut(): boolean
				return elapsed() > maxSeconds
			end

			local function fail(msg: string)
				if stillRunning(token) then
					M.log("ERR", msg .. string.format(
						" | t=%.2fs holds=%d corrects=%d reaims=%d bestDist=%.4f",
						elapsed(),
						holdCount,
						correctCount,
						reaimCount,
						bestDist
					))
					S.clawBusy = false
					M.setBeamAimPrize(nil)
					releaseMoveKeys()
					setRunLabel("idle")
					setStatus("Claw FAIL: " .. msg)
				else
					M.log("WARN", "fail after stop: " .. msg, false)
				end
			end

			local function succeed(msg: string)
				if stillRunning(token) then
					M.log("PHASE", msg .. string.format(
						" | t=%.2fs holds=%d corrects=%d reaims=%d",
						elapsed(),
						holdCount,
						correctCount,
						reaimCount
					))
					S.clawBusy = false
					M.setBeamAimPrize(nil)
					releaseMoveKeys()
					setRunLabel("idle")
					setStatus("Claw OK: " .. msg)
				end
			end

			M.clearBlockedPrizes()
			local hardM0, softM0, clawR0, prizeR0 = M.encapsulationMargins()
			M.log("INFO", string.format(
				"config thr=%.3f soft=%.3f encap=%s hardM=%.3f softM=%.3f clawR=%.3f prizeR=%.3f holdPoll=%.3f holdMax=%.2f correctTap=%.3f releaseAt=%.3f stable=%d maxT=%.0fs",
				thr,
				softThr,
				tostring(C.CLAW_ALIGN_USE_ENCAPSULATION ~= false),
				hardM0,
				softM0,
				clawR0,
				prizeR0,
				holdPoll,
				holdMax,
				correctTap,
				releaseAt,
				stableChecks,
				maxSeconds
			), false)
			M.log("INFO", "reach box ABSOLUTE " .. M.formatReachBounds(), false)

			-- 1) Initial scan + dump full prize table (intent debug) + pick
			M.log("PHASE", "scan prizes…")
			local prizes = M.scanPrizes()
			if not stillRunning(token) then
				M.log("INFO", "aborted after scan (token dead)", false)
				return
			end
			local reachOk, reachBad, reachBlocked = M.countReachable(prizes)
			M.log("INFO", string.format(
				"scan found %d prizes | reachable=%d wall=%d blocked=%d box=%s",
				#prizes,
				reachOk,
				reachBad,
				reachBlocked,
				M.formatReachBounds()
			), false)

			local clawPosEarly = M.getClawPosition()
			-- Annotate + dump ALL prizes for this run (JSON + log lines)
			local dumpList = {}
			for _, p in ipairs(prizes) do
				local dist = math.huge
				if clawPosEarly then
					local dx = p.x - clawPosEarly.X
					local dz = p.z - clawPosEarly.Z
					dist = math.sqrt(dx * dx + dz * dz)
				end
				p.distXZ = dist
				p.reachable = M.isPrizeEntryReachable(p)
				p.inset = M.prizeInsetScore(p.x, p.z)
				p.blocked = M.isPrizeBlocked(p)
				local why = "candidate"
				if p.blocked then
					why = "blocked_this_run"
				elseif not p.reachable then
					why = "outside_machine_walls"
				elseif (p.inset or 0) < 0 then
					why = "wall_edge_ok" -- center slightly outside, body still in box
				end
				table.insert(dumpList, {
					name = p.name,
					path = p.path,
					priority = p.priority,
					matchedKeyword = p.matchedKeyword,
					center = { x = p.x, y = p.y, z = p.z },
					radiusXZ = p.radiusXZ,
					reachable = p.reachable,
					blocked = p.blocked,
					inset = p.inset,
					distXZ = p.distXZ,
					reason = why,
				})
			end
			table.sort(dumpList, function(a, b)
				if a.priority ~= b.priority then
					return a.priority < b.priority
				end
				return (a.distXZ or 0) < (b.distXZ or 0)
			end)
			local stampPrizes = os.date("%Y-%m-%d_%H-%M-%S")
			local prizeDumpPath = string.format(
				"%s/claw_prizes_%s_t%d.json",
				C.CLAW_LOG_DIR or C.DUMP_DIR or "dumps",
				stampPrizes,
				token
			)
			pcall(function()
				U.ensureDir(C.CLAW_LOG_DIR or C.DUMP_DIR or "dumps")
				local payload = {
					type = "claw_prize_scan",
					timestamp = stampPrizes,
					token = token,
					reachBox = M.formatReachBounds(),
					clawPosition = clawPosEarly and U.vec3Table(clawPosEarly) or nil,
					prizeCount = #dumpList,
					reachableCount = reachOk,
					wallCount = reachBad,
					blockedCount = reachBlocked,
					prizes = dumpList,
				}
				writefile(prizeDumpPath, HttpService:JSONEncode(payload))
			end)
			M.log("INFO", "prize dump → " .. prizeDumpPath .. " (" .. tostring(#dumpList) .. " entries)", false)
			for i, p in ipairs(dumpList) do
				M.log("INFO", string.format(
					"  ALL[%02d] P%d %s kw=%s %s inset=%.2f d=%.3f center=%s | %s",
					i,
					p.priority,
					p.name,
					tostring(p.matchedKeyword),
					p.reachable and "REACH" or "WALL",
					p.inset or 0,
					p.distXZ or -1,
					fmtXZ(p.center.x, p.center.z),
					p.reason or "?"
				), false)
			end
			if #prizes == 0 then
				fail("no prizes found under Event_ClawMachine.Prizes")
				return
			end

			local clawPos = clawPosEarly or M.getClawPosition()
			if not clawPos then
				fail("cannot read claw position (Cylinder/PrizeDetect)")
				return
			end
			M.log("INFO", "claw pos " .. fmtVec(clawPos), false)

			-- One-shot intention lock (same as Best Prize button) — never re-pick mid-run
			local target, lockTag = M.lockBestPrizeFromScan({
				prizes = prizes,
				clawPos = clawPos,
				requireReachable = true,
			})
			if not target then
				fail(string.format(
					"no grabbable prize in machine walls %s (all %d outside/blocked) | %s",
					M.formatReachBounds(),
					#prizes,
					tostring(lockTag)
				))
				return
			end
			local _, _, d0 = xzError(clawPos, target.x, target.z)
			bestDist = d0
			M.setBeamAimPrize(target)
			if S.clawBeamEnabled then
				pcall(function()
					M.ensureInjectedBeam()
				end)
			end
			if S.clawPrizeBeamsBestOnly then
				pcall(function()
					M.ensurePrizeBeams()
				end)
			end
			M.log("INFO", "best locked (one-shot) " .. tostring(lockTag), false)
			M.log("PHASE", string.format(
				"INTENTION decide target | %s | dXZ=%.4f inset=%.2f thr=%.4f soft=%.4f wallSkip=%s blockSkip=%s dump=%s",
				prizeTag(target),
				d0,
				target.inset or M.prizeInsetScore(target.x, target.z),
				thr,
				softThr,
				tostring(target._skippedUnreachable),
				tostring(target._skippedBlocked),
				prizeDumpPath
			))
			-- High-prio prize truly outside machine walls (not wall-edge).
			local outsideHigh = target._bestWallHigh
			if outsideHigh and (target.priority or 99) > (outsideHigh.priority or 99) then
				M.log("WARN", string.format(
					"high-prio outside machine — skipped P%d %s @%s; using %s",
					outsideHigh.priority or -1,
					tostring(outsideHigh.name),
					fmtXZ(outsideHigh.x, outsideHigh.z),
					prizeTag(target)
				), false)
			end

			-- 2) Align: HOLD one cardinal key fluidly; counter-tap only on overshoot.
			--    World WASD on a rotated claw orbits near the prize — soft thr + orbit stop.
			local function alignOnce(tag: string): (boolean, string?)
				M.log("PHASE", string.format(
					"align begin (%s) | intended %s",
					tag,
					prizeTag(target)
				))
				nearHoldStreak = 0
				recentKeys = {}

				local function isOrbiting(): boolean
					if #recentKeys < 6 then
						return false
					end
					local seen: { [string]: boolean } = {}
					local nUnique = 0
					for i = math.max(1, #recentKeys - 7), #recentKeys do
						local k = recentKeys[i]
						if not seen[k] then
							seen[k] = true
							nUnique += 1
						end
					end
					return nUnique >= 3
				end

				while stillRunning(token) and not timedOut() do
					releaseMoveKeys()

					clawPos = M.getClawPosition()
					if not clawPos then
						return false, "lost claw position"
					end
					local prevTarget = target
					target = M.refreshPrize(target)
					if not target then
						return false, "target prize despawned"
					end
					M.setBeamAimPrize(target)
					if prevTarget
						and (
							math.abs((prevTarget.x or 0) - target.x) > 0.05
							or math.abs((prevTarget.z or 0) - target.z) > 0.05
						)
					then
						M.log("INFO", string.format(
							"prize moved %s → %s | intended %s",
							fmtXZ(prevTarget.x, prevTarget.z),
							fmtXZ(target.x, target.z),
							prizeTag(target)
						), false)
					end

					local dx, dz, dist = xzError(clawPos, target.x, target.z)
					if dist < bestDist then
						bestDist = dist
					end

					if isAboveHard(clawPos, target, dist, thr) then
						M.log("PHASE", string.format(
							"align OK (%s) dXZ=%.4f %s holds=%d | intended %s",
							tag, dist, encapLogBits(clawPos, target), holdCount, prizeTag(target)
						))
						return true, nil
					end

					local softOk = isAboveSoft(clawPos, target, dist, softThr)
					if softOk then
						nearHoldStreak += 1
					else
						nearHoldStreak = 0
					end
					if softOk and (nearHoldStreak >= orbitHolds or (isOrbiting() and holdCount >= 6)) then
						M.log("PHASE", string.format(
							"align SOFT-OK (%s) dXZ=%.4f %s | intended %s",
							tag, dist, encapLogBits(clawPos, target), prizeTag(target)
						))
						return true, nil
					end

					local key = forceKey or pickMoveKey(dx, dz)
					forceKey = nil
					if not key then
						M.log("INFO", string.format(
							"decide no-key dXZ=%.4f %s | intended %s",
							dist,
							encapLogBits(clawPos, target),
							prizeTag(target)
						), false)
						return true, nil
					end

					local signed0 = axisSignedError(key, clawPos, target.x, target.z)
					-- Axis band still uses thr for release; hard encap already returned above
					if math.abs(dx) <= thr and math.abs(dz) <= thr then
						M.log("PHASE", string.format(
							"align OK axes dXZ=%.4f %s | intended %s",
							dist,
							encapLogBits(clawPos, target),
							prizeTag(target)
						))
						return true, nil
					end

					holdCount += 1
					alignSteps += 1
					table.insert(recentKeys, key.Name)
					while #recentKeys > 12 do
						table.remove(recentKeys, 1)
					end
					local holdStart = os.clock()
					local startSigned = signed0
					local before = clawPos
					-- Near: soft-encapsulated or within near-tap dXZ
					local useTap = softOk or dist <= nearTapDist

					M.log("STEP", string.format(
						"decide %s#%d key=%s dXZ=%.4f dx=%+.4f dz=%+.4f signed=%+.4f claw=%s %s | intended %s",
						useTap and "TAP" or "HOLD",
						holdCount,
						key.Name,
						dist,
						dx,
						dz,
						startSigned,
						fmtXZ(clawPos.X, clawPos.Z),
						encapLogBits(clawPos, target),
						prizeTag(target)
					), true)
					setStatus(string.format(
						"Claw %s %s → %s d=%.3f",
						useTap and "TAP" or "HOLD",
						key.Name,
						target.name,
						dist
					))

					local endReason = "unknown"
					local samples = 0

					if useTap then
						tapKey(key, correctTap)
						samples = 1
						endReason = "tap"
						task.wait(holdPoll)
					else
						-- Hold until axis good / overshoot / soft / max hold time — no no_move anticheat
						keyDown(key)
						while stillRunning(token) and not timedOut() do
							task.wait(holdPoll)
							samples += 1
							local heldFor = os.clock() - holdStart
							clawPos = M.getClawPosition()
							target = M.refreshPrize(target)
							if not clawPos or not target then
								keyUp(key)
								releaseMoveKeys()
								return false, "lost claw/prize during hold"
							end

							local signed = axisSignedError(key, clawPos, target.x, target.z)
							local _, _, distNow = xzError(clawPos, target.x, target.z)
							if distNow < bestDist then
								bestDist = distNow
							end

							if isAboveHard(clawPos, target, distNow, thr) then
								endReason = "encap_full"
								break
							end
							if isAboveSoft(clawPos, target, distNow, softThr) and samples >= 3 then
								endReason = "encap_soft"
								break
							end
							if math.abs(signed) <= releaseAt then
								endReason = "axis_good"
								break
							end
							if startSigned > 0 and signed < -0.001 then
								endReason = "overshoot"
								break
							end
							if startSigned < 0 and signed > 0.001 then
								endReason = "overshoot"
								break
							end
							-- Cap hold so we never spin forever if axis never reaches releaseAt
							if heldFor >= holdMax then
								endReason = "hold_max"
								break
							end
							if samples % 20 == 0 then
								M.log("STEP", string.format(
									"  holding %s t=%.2fs signed=%+.4f dXZ=%.4f %s | intended %s",
									key.Name,
									heldFor,
									signed,
									distNow,
									encapLogBits(clawPos, target),
									prizeTag(target)
								), false)
							end
						end
						keyUp(key)
					end

					releaseMoveKeys()
					local holdDur = os.clock() - holdStart
					local after = M.getClawPosition() or clawPos
					target = M.refreshPrize(target) or target
					if not target then
						return false, "target prize despawned"
					end
					local endSigned = axisSignedError(key, after, target.x, target.z)
					local _, _, endDist = xzError(after, target.x, target.z)
					local pathMoved = math.sqrt(
						(after.X - before.X) ^ 2 + (after.Z - before.Z) ^ 2
					)

					if isAboveHard(after, target, endDist, thr) then
						M.log("PHASE", string.format(
							"align OK after move (%s) dXZ=%.4f %s | intended %s",
							tag,
							endDist,
							encapLogBits(after, target),
							prizeTag(target)
						))
						return true, nil
					end

					M.log("INFO", string.format(
						"decide end %s reason=%s t=%.2fs moved=%.4f signed %.4f→%.4f dXZ=%.4f %s | intended %s",
						key.Name,
						endReason,
						holdDur,
						pathMoved,
						startSigned,
						endSigned,
						endDist,
						encapLogBits(after, target),
						prizeTag(target)
					), false)

					if endReason == "overshoot" then
						local opp = oppositeKey(key)
						if opp then
							correctCount += 1
							M.log("INFO", string.format(
								"decide OVERSHOOT %s → tap %s | intended %s",
								key.Name,
								opp.Name,
								prizeTag(target)
							), false)
							tapKey(opp, correctTap)
							task.wait(holdPoll)
						end
					elseif endReason == "hold_max" and pathMoved < 0.05 then
						-- Claw ignored this key (often machine not focused, or axis blocked).
						-- Do not spam the same key: try the other world axis next.
						zeroMoveStreak += 1
						local alt: Enum.KeyCode? = nil
						if key == Enum.KeyCode.A or key == Enum.KeyCode.D then
							-- other axis is Z
							alt = if dz >= 0 then Enum.KeyCode.W else Enum.KeyCode.S
						else
							alt = if dx >= 0 then Enum.KeyCode.A else Enum.KeyCode.D
						end
						forceKey = alt
						M.log("WARN", string.format(
							"decide ZERO-MOVE hold_max on %s (moved=%.4f) — next try %s | intended %s",
							key.Name,
							pathMoved,
							alt and alt.Name or "?",
							prizeTag(target)
						), true)
						if zeroMoveStreak >= 4 then
							return false, string.format(
								"claw not moving after %d holds (focus the claw machine UI?)",
								zeroMoveStreak
							)
						end
					else
						if pathMoved >= 0.05 then
							zeroMoveStreak = 0
						end
					end
				end

				if not stillRunning(token) then
					return false, "cancelled"
				end
				return false, "timeout aligning"
			end

			local okAlign, alignErr = alignOnce("initial")
			if not stillRunning(token) then
				M.log("INFO", "stopped after initial align", false)
				return
			end
			if not okAlign then
				fail(tostring(alignErr))
				return
			end

			-- 3) Settle after move, then rescan/confirm (lets claw stop before drop)
			local settleWait = C.CLAW_SETTLE_WAIT or 0.3
			M.log("PHASE", string.format(
				"settle %.2fs then rescan | intended %s",
				settleWait,
				prizeTag(target)
			))
			task.wait(settleWait)
			if not stillRunning(token) then
				return
			end

			local function rescanConfirm(): (boolean, number?)
				clawPos = M.getClawPosition()
				target = M.refreshPrize(target)
				if not clawPos or not target then
					return false, nil
				end
				M.setBeamAimPrize(target)
				local _, _, d = xzError(clawPos, target.x, target.z)
				local soft = isAboveSoft(clawPos, target, d, softThr)
				M.log("INFO", string.format(
					"decide rescan after settle dXZ=%.4f %s claw=%s | intended %s",
					d,
					encapLogBits(clawPos, target),
					fmtXZ(clawPos.X, clawPos.Z),
					prizeTag(target)
				), false)
				return soft, d
			end

			local okNear, dist = rescanConfirm()
			if not stillRunning(token) then
				return
			end
			if not okNear then
				reaimCount += 1
				M.log("WARN", string.format(
					"decide after settle not above (dXZ=%s %s) — re-aim | intended %s",
					tostring(dist),
					encapLogBits(clawPos, target),
					prizeTag(target)
				))
				okAlign, alignErr = alignOnce("post-settle")
				if not stillRunning(token) then
					return
				end
				if not okAlign then
					fail(tostring(alignErr))
					return
				end
				M.log("PHASE", string.format(
					"settle %.2fs again | intended %s",
					settleWait,
					prizeTag(target)
				))
				task.wait(settleWait)
				if not stillRunning(token) then
					return
				end
				okNear, dist = rescanConfirm()
				if not okNear then
					-- Last chance: hard dXZ fallback only if still soft-ish
					local loose = dist and dist <= softThr * 1.25
					if loose then
						M.log("WARN", string.format(
							"decide still loose dXZ=%.4f %s — drop anyway | intended %s",
							dist,
							encapLogBits(clawPos, target),
							prizeTag(target)
						), false)
					else
						fail(string.format(
							"not above prize after settle (dXZ=%s %s) | %s",
							tostring(dist),
							encapLogBits(clawPos, target),
							prizeTag(target)
						))
						return
					end
				end
			end

			-- Second confirm sample after a short beat
			task.wait(stableInterval)
			if not stillRunning(token) then
				return
			end
			okNear, dist = rescanConfirm()
			if not okNear then
				if not (dist and dist <= softThr * 1.25) then
					fail(string.format(
						"lost alignment before drop (dXZ=%s %s) | %s",
						tostring(dist),
						encapLogBits(clawPos, target),
						prizeTag(target)
					))
					return
				end
			end

			if timedOut() then
				fail("timeout before drop | " .. prizeTag(target))
				return
			end

			-- 4) Drop Space once
			releaseMoveKeys()
			M.log("PHASE", string.format(
				"decide DROP Space dXZ=%.4f %s | intended %s",
				dist or -1,
				encapLogBits(clawPos, target),
				prizeTag(target)
			))
			task.wait(0.05)
			if not stillRunning(token) then
				M.log("WARN", "cancelled in pre-drop wait | " .. prizeTag(target), false)
				return
			end
			local spaceOk, spaceErr = pcall(function()
				U.pressKey(Enum.KeyCode.Space)
			end)
			M.log("INFO", string.format(
				"Space sent ok=%s err=%s | intended %s",
				tostring(spaceOk),
				tostring(spaceErr),
				prizeTag(target)
			), false)

			succeed(string.format(
				"dropped %s (one-shot complete) log=%s",
				prizeTag(target),
				tostring(S.clawLogPath)
			))
		end)
	end

	return M
end

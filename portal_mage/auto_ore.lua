-- portal_mage/auto_ore.lua — path between ore nodes (A*/PFS + wall climb)
--
-- Uses Ore.collectOres (ESP not required), Nav.computePath segments (same as
-- Kill Aura / Path Viz), and face beams to aim into a wall for Space+W climbs.
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local M = {}

	local FACE_VIZ_FOLDER = "PortalMage_AutoOreFace"
	local faceVizFolder: Folder? = nil
	local faceVizFace: BasePart? = nil -- cyan: measured look
	local faceVizWant: BasePart? = nil -- green: desired (segment / wall)
	local faceVizTurn: BasePart? = nil -- magenta/yellow: turn bias

	---------------------------------------------------------------------------
	-- Helpers
	---------------------------------------------------------------------------

	local function setStatus(t: string)
		if U and U.setStatus then
			U.setStatus(t)
		end
	end

	local function refreshLabel()
		if S.ui and S.ui.setAutoOreLabel then
			S.ui.setAutoOreLabel(S.autoOreEnabled == true)
		end
	end

	local function Ore()
		return S.Ore
	end

	local function Nav()
		return S.Nav
	end

	local function flatDist(a: Vector3, b: Vector3): number
		return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
	end

	local function getHum(): Humanoid?
		local lp = Players.LocalPlayer
		local char = lp and lp.Character
		return char and char:FindFirstChildOfClass("Humanoid")
	end

	local function getHrp(): BasePart?
		local lp = Players.LocalPlayer
		local char = lp and lp.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			return hrp
		end
		return nil
	end

	local function playerPos(): Vector3?
		if U and U.getLivePlayerVector then
			return U.getLivePlayerVector()
		end
		local hrp = getHrp()
		return hrp and hrp.Position or nil
	end

	local function excludeSelf(): RaycastParams
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local excl = {}
		local lp = Players.LocalPlayer
		if lp and lp.Character then
			table.insert(excl, lp.Character)
		end
		-- ignore debug viz
		for _, name in ipairs({
			"PortalMage_PathViz",
			"PortalMage_FaceViz",
			FACE_VIZ_FOLDER,
			"PortalMage_TerrainFloorOutline",
		}) do
			local f = workspace:FindFirstChild(name)
			if f then
				table.insert(excl, f)
			end
		end
		params.FilterDescendantsInstances = excl
		return params
	end

	---------------------------------------------------------------------------
	-- Face beams (reuse Kill Aura style; gated by AUTO_ORE_FACE_VIZ)
	---------------------------------------------------------------------------

	local function styleFacePart(p: BasePart, color: Color3)
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = color
		p.Transparency = 0.15
	end

	local function ensureFaceViz()
		if C.AUTO_ORE_FACE_VIZ == false then
			return
		end
		if faceVizFolder and faceVizFolder.Parent then
			return
		end
		pcall(function()
			local old = workspace:FindFirstChild(FACE_VIZ_FOLDER)
			if old then
				old:Destroy()
			end
			local f = Instance.new("Folder")
			f.Name = FACE_VIZ_FOLDER
			f.Parent = workspace
			faceVizFolder = f
			local function mk(name: string, color: Color3): BasePart
				local p = Instance.new("Part")
				p.Name = name
				p.Shape = Enum.PartType.Cylinder
				p.Size = Vector3.new(1, 0.1, 0.1)
				styleFacePart(p, color)
				p.Parent = f
				return p
			end
			faceVizFace = mk("FaceLook", Color3.fromRGB(80, 220, 255))
			faceVizWant = mk("WantTarget", Color3.fromRGB(120, 255, 100))
			faceVizTurn = mk("TurnHint", Color3.fromRGB(255, 200, 60))
		end)
	end

	local function clearFaceViz()
		pcall(function()
			if faceVizFolder and faceVizFolder.Parent then
				faceVizFolder:Destroy()
			end
			local old = workspace:FindFirstChild(FACE_VIZ_FOLDER)
			if old then
				old:Destroy()
			end
		end)
		faceVizFolder = nil
		faceVizFace = nil
		faceVizWant = nil
		faceVizTurn = nil
	end

	local function placeRod(part: BasePart?, a: Vector3, b: Vector3, thick: number?)
		if not part or not part.Parent then
			return
		end
		local delta = b - a
		local dist = delta.Magnitude
		if dist < 0.05 then
			part.Transparency = 1
			return
		end
		local t = thick or 0.1
		part.Transparency = 0.12
		part.Size = Vector3.new(dist, t, t)
		part.CFrame = CFrame.lookAt(a + delta * 0.5, b) * CFrame.Angles(0, math.rad(90), 0)
	end

	local function updateFaceViz(
		hrp: BasePart,
		wantPos: Vector3,
		measuredLook: Vector3?,
		turnKey: Enum.KeyCode?
	)
		if C.AUTO_ORE_FACE_VIZ == false then
			clearFaceViz()
			return
		end
		ensureFaceViz()
		local origin = hrp.Position + Vector3.new(0, 1.4, 0)
		local flatLook = measuredLook
		if not flatLook or flatLook.Magnitude < 1e-4 then
			local look = hrp.CFrame.LookVector
			flatLook = Vector3.new(look.X, 0, look.Z)
		end
		if flatLook.Magnitude < 1e-4 then
			flatLook = Vector3.new(0, 0, -1)
		else
			flatLook = Vector3.new(flatLook.X, 0, flatLook.Z).Unit
		end
		local faceLen = C.AUTO_ORE_FACE_BEAM_LEN or C.KILL_AURA_FACE_BEAM_LEN or 6
		placeRod(faceVizFace, origin, origin + flatLook * faceLen, 0.1)
		local toW = Vector3.new(wantPos.X - origin.X, 0, wantPos.Z - origin.Z)
		if toW.Magnitude > 0.15 then
			toW = toW.Unit
			placeRod(
				faceVizWant,
				origin + Vector3.new(0, 0.12, 0),
				origin + Vector3.new(0, 0.12, 0) + toW * (faceLen * 1.15),
				0.08
			)
		elseif faceVizWant then
			faceVizWant.Transparency = 1
		end
		if turnKey and faceVizTurn then
			local right = Vector3.new(-flatLook.Z, 0, flatLook.X)
			local side = if turnKey == Enum.KeyCode.Left then -right else right
			faceVizTurn.Color = if turnKey == Enum.KeyCode.Left
				then Color3.fromRGB(255, 120, 220)
				else Color3.fromRGB(255, 200, 50)
			placeRod(
				faceVizTurn,
				origin + Vector3.new(0, -0.12, 0),
				origin + Vector3.new(0, -0.12, 0) + side * (faceLen * 0.55),
				0.09
			)
		elseif faceVizTurn then
			faceVizTurn.Transparency = 1
		end
	end

	---------------------------------------------------------------------------
	-- Soft face toward world XZ (same invert L/R as Kill Aura)
	---------------------------------------------------------------------------

	local lastFaceDot = 0
	local lastYawErr = 0
	local lastTurnName = "-"
	local faceOkSince = 0

	local function facePoint(target: Vector3, align: number?): number
		local need = align or C.AUTO_ORE_FACE_ALIGN or C.KILL_AURA_FACE_ALIGN or 0.9
		local hrp = getHrp()
		local hum = getHum()
		if not hrp then
			return 0
		end
		if hum then
			pcall(function()
				hum.AutoRotate = false
			end)
		end

		local pos = hrp.Position
		local flat = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
		local measuredLook = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
		if measuredLook.Magnitude > 1e-4 then
			measuredLook = measuredLook.Unit
		else
			measuredLook = Vector3.new(0, 0, -1)
		end

		if flat.Magnitude < 0.2 then
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			lastFaceDot = 1
			lastYawErr = 0
			lastTurnName = "-"
			faceOkSince = os.clock()
			updateFaceViz(hrp, target, measuredLook, nil)
			return 1
		end

		local dBefore = (U.facingDotTo and U.facingDotTo(target.X, target.Z)) or 0
		local yawErr = (U.yawErrorTo and U.yawErrorTo(target.X, target.Z)) or 0
		local poll = C.SMOOTH_WALK_POLL or 0.06
		local turnRate = C.AUTO_ORE_FACE_TURN_RATE or C.KILL_AURA_FACE_TURN_RATE or 3.2

		pcall(function()
			local lookAt = Vector3.new(target.X, pos.Y, target.Z)
			local desired = CFrame.lookAt(pos, lookAt)
			local alpha = 1 - math.exp(-turnRate * poll)
			hrp.CFrame = hrp.CFrame:Lerp(desired, math.clamp(alpha, 0.02, 0.45))
		end)

		local cam = workspace.CurrentCamera
		if cam then
			pcall(function()
				local cpos = cam.CFrame.Position
				local look = cam.CFrame.LookVector
				local to = Vector3.new(target.X - cpos.X, 0, target.Z - cpos.Z)
				if to.Magnitude > 0.2 then
					to = to.Unit
					local flatLook = Vector3.new(look.X, 0, look.Z)
					if flatLook.Magnitude > 0.1 then
						flatLook = flatLook.Unit
						local cross = flatLook.X * to.Z - flatLook.Z * to.X
						local dot = flatLook:Dot(to)
						if dot < 0.98 then
							local deg = (C.PATH_CAMERA_YAW_DEG or 3.5) * (if cross > 0 then -1 else 1)
							if dot < 0 then
								deg = deg * 1.8
							elseif dot < 0.5 then
								deg = deg * 1.25
							end
							local newLook = CFrame.Angles(0, math.rad(deg), 0) * Vector3.new(look.X, 0, look.Z)
							if newLook.Magnitude > 0.1 then
								newLook = newLook.Unit
								cam.CFrame = CFrame.lookAt(cpos, cpos + Vector3.new(newLook.X, look.Y, newLook.Z))
							end
						end
					end
				end
			end)
		end

		local d = (U.facingDotTo and U.facingDotTo(target.X, target.Z)) or dBefore
		local turnKey: Enum.KeyCode? = nil
		if d < need then
			if U.turnKeyToward then
				turnKey = U.turnKeyToward(target.X, target.Z, need)
			elseif math.abs(yawErr) >= (C.PATH_TURN_YAW_DEADZONE or 0.08) or d < 0.5 then
				-- inverted for this game (same as util.turnKeyToward)
				turnKey = if yawErr > 0 then Enum.KeyCode.Right else Enum.KeyCode.Left
			end
		end
		if U.holdTurnKey then
			U.holdTurnKey(turnKey, true)
		end

		lastFaceDot = d
		lastYawErr = yawErr
		lastTurnName = if turnKey == Enum.KeyCode.Left
			then "LEFT"
			elseif turnKey == Enum.KeyCode.Right then "RIGHT"
			else "-"
		updateFaceViz(hrp, target, measuredLook, turnKey)
		return d
	end

	---------------------------------------------------------------------------
	-- Wall probes / climb
	---------------------------------------------------------------------------

	-- Nearest wall-like hit around player. Returns hitPos, outwardNormal, distance.
	local function findNearestWall(from: Vector3): (Vector3?, Vector3?, number?)
		local probe = C.AUTO_ORE_WALL_PROBE or 10
		local dirs = C.AUTO_ORE_WALL_DIRS or 12
		local minNy = C.NAV_MIN_NORMAL_Y or 0.45
		local heights = C.NAV_BODY_HEIGHTS or { 1.2, 2.5, 4.5 }
		local params = excludeSelf()
		local bestDist = probe + 1
		local bestHit: Vector3? = nil
		local bestN: Vector3? = nil

		for i = 0, dirs - 1 do
			local ang = (i / dirs) * math.pi * 2
			local dir = Vector3.new(math.sin(ang), 0, math.cos(ang))
			for _, hy in ipairs(heights) do
				local origin = from + Vector3.new(0, hy, 0)
				local hit = workspace:Raycast(origin, dir * probe, params)
				if hit and hit.Normal.Y < minNy then
					if hit.Distance < bestDist then
						bestDist = hit.Distance
						bestHit = hit.Position
						bestN = hit.Normal
					end
				end
			end
		end
		if bestHit and bestN then
			return bestHit, bestN, bestDist
		end
		return nil, nil, nil
	end

	local function wallAhead(from: Vector3, dir: Vector3, probe: number): boolean
		if dir.Magnitude < 1e-4 then
			return false
		end
		dir = Vector3.new(dir.X, 0, dir.Z)
		if dir.Magnitude < 1e-4 then
			return false
		end
		dir = dir.Unit
		local nav = Nav()
		if nav and nav.hasClearWalk then
			return not nav.hasClearWalk(from, from + dir * probe)
		end
		local hit = workspace:Raycast(from + Vector3.new(0, 2.2, 0), dir * probe, excludeSelf())
		if not hit then
			return false
		end
		return hit.Normal.Y < 0.55
	end

	local function setMoveKey(which: string?)
		if not U.holdMoveKeys then
			return
		end
		if which == "W" then
			U.holdMoveKeys({ Enum.KeyCode.W })
		elseif which == "A" then
			U.holdMoveKeys({ Enum.KeyCode.A })
		elseif which == "D" then
			U.holdMoveKeys({ Enum.KeyCode.D })
		else
			U.holdMoveKeys(nil)
		end
	end

	local function stopMove()
		if U.releaseMoveKeys then
			U.releaseMoveKeys()
		else
			setMoveKey(nil)
			if U.holdJump then
				U.holdJump(false)
			end
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
		end
		local hum = getHum()
		if hum then
			pcall(function()
				hum.PlatformStand = false
				hum:Move(Vector3.zero)
				hum.AutoRotate = true
			end)
		end
	end

	---------------------------------------------------------------------------
	-- Path segments (same polyline Path Viz draws)
	---------------------------------------------------------------------------

	local pathPts: { Vector3 } = {}
	local pathIdx = 1
	local pathBuiltAt = 0
	local pathGoal: Vector3? = nil
	local pathKind = ""
	local lastSlide: string? = nil
	local lastSlideAt = 0
	local lastPos: Vector3? = nil
	local stuckSince = 0

	local function clearPath()
		pathPts = {}
		pathIdx = 1
		pathBuiltAt = 0
		pathGoal = nil
		pathKind = ""
		faceOkSince = 0
		lastSlide = nil
		lastPos = nil
		stuckSince = 0
	end

	local function advancePathIndex(pos: Vector3)
		local arrive = C.AUTO_ORE_SEG_ARRIVE or C.KILL_AURA_SEG_ARRIVE or 3.5
		local advanced = false
		while pathIdx < #pathPts and flatDist(pos, pathPts[pathIdx]) <= arrive do
			pathIdx += 1
			advanced = true
		end
		if advanced then
			faceOkSince = 0
		end
		if pathIdx < 1 then
			pathIdx = 1
		end
		if #pathPts > 0 and pathIdx > #pathPts then
			pathIdx = #pathPts
		end
	end

	local function rebuildPath(from: Vector3, to: Vector3)
		local goal = to
		local nav = Nav()
		if nav and nav.sampleFloor then
			local s = nav.sampleFloor(to.X, to.Z, to.Y, { requireClear = false })
			if s and s.pos then
				goal = s.pos
			end
		end
		local pts: { Vector3 }
		local kind = "line"
		if nav and nav.computePath then
			pts, kind = nav.computePath(from, goal)
		elseif nav and nav.findPath then
			pts = nav.findPath(from, goal) or { from, goal }
			kind = "grid"
			if S.pathVizEnabled and nav.showPathViz then
				nav.showPathViz(pts, kind)
			end
		else
			pts = { from, goal }
			if S.pathVizEnabled and nav and nav.showPathViz then
				nav.showPathViz(pts, "line")
			end
		end
		if not pts or #pts == 0 then
			pts = { from, goal }
			kind = "line"
		end
		pathPts = pts
		pathGoal = goal
		pathBuiltAt = os.clock()
		pathKind = kind or "path"
		pathIdx = 1
		advancePathIndex(from)
		faceOkSince = 0
	end

	local function ensurePath(from: Vector3, to: Vector3, force: boolean?)
		local interval = C.AUTO_ORE_PATH_REBUILD or C.PATH_REBUILD or 0.85
		local need = force == true
			or #pathPts < 2
			or pathGoal == nil
			or flatDist(pathGoal, to) > 8
			or (os.clock() - pathBuiltAt) >= interval
		if not need and pathIdx <= #pathPts then
			if flatDist(from, pathPts[pathIdx]) > 28 then
				need = true
			end
		end
		if need then
			rebuildPath(from, to)
		else
			advancePathIndex(from)
		end
	end

	local function segmentTarget(from: Vector3, goal: Vector3): (Vector3, string)
		if #pathPts >= 1 and pathIdx >= 1 and pathIdx <= #pathPts then
			return pathPts[pathIdx], string.format("seg%d/%d", pathIdx, #pathPts)
		end
		return goal, "goal"
	end

	---------------------------------------------------------------------------
	-- Ore selection
	---------------------------------------------------------------------------

	local visited: { [Instance]: boolean } = {}
	local currentOre: Instance? = nil
	local currentOrePos: Vector3? = nil
	local dwellUntil = 0
	local minedCount = 0
	local climbActive = false
	local climbStartedAt = 0
	local climbStartY = 0
	local climbTargetY = 0
	local climbWallHit: Vector3? = nil

	local function oreTypeAllowed(typeKey: string): boolean
		if C.AUTO_ORE_SKIP_ROCK and (typeKey == "rock" or typeKey == "stone") then
			return false
		end
		local prio = C.AUTO_ORE_TYPE_PRIORITY
		if type(prio) ~= "table" or #prio == 0 then
			return true
		end
		for _, k in ipairs(prio) do
			if string.lower(tostring(k)) == typeKey then
				return true
			end
		end
		return false
	end

	local function listCandidateOres(from: Vector3): { { inst: Instance, pos: Vector3, dist: number, typeKey: string } }
		local oreApi = Ore()
		if not oreApi or not oreApi.collectOres then
			return {}
		end
		local out = {}
		for _, inst in ipairs(oreApi.collectOres()) do
			if visited[inst] then
				continue
			end
			if not inst.Parent then
				continue
			end
			local typeKey = oreApi.oreTypeKey and oreApi.oreTypeKey(inst) or "ore"
			if not oreTypeAllowed(typeKey) then
				continue
			end
			local pos = oreApi.getOrePosition and oreApi.getOrePosition(inst)
			if not pos then
				continue
			end
			table.insert(out, {
				inst = inst,
				pos = pos,
				dist = (pos - from).Magnitude,
				typeKey = typeKey,
			})
		end
		table.sort(out, function(a, b)
			return a.dist < b.dist
		end)
		return out
	end

	local function pickNextOre(from: Vector3): (Instance?, Vector3?, string?)
		-- prune dead visited
		for inst in pairs(visited) do
			if not inst.Parent then
				visited[inst] = nil
			end
		end
		local list = listCandidateOres(from)
		if #list == 0 then
			-- all visited or none — reset visited and try again
			if next(visited) ~= nil then
				table.clear(visited)
				list = listCandidateOres(from)
			end
		end
		if #list == 0 then
			return nil, nil, nil
		end
		local best = list[1]
		return best.inst, best.pos, best.typeKey
	end

	local function interactAtOre()
		if C.AUTO_ORE_INTERACT == false then
			return
		end
		local key = C.AUTO_ORE_INTERACT_KEY or Enum.KeyCode.E
		local n = C.AUTO_ORE_INTERACT_PULSES or 3
		if U.pressKey then
			for _ = 1, n do
				U.pressKey(key)
				task.wait(0.12)
			end
		end
	end

	---------------------------------------------------------------------------
	-- One approach tick toward goal position
	---------------------------------------------------------------------------

	local function approachTick(from: Vector3, goal: Vector3): string
		local hum = getHum()
		if hum then
			pcall(function()
				hum.AutoRotate = false
				hum.PlatformStand = false
				if hum.WalkSpeed < 8 then
					hum.WalkSpeed = C.WALK_SPEED_DEFAULT or 16
				end
			end)
		end

		local arrive = C.AUTO_ORE_ARRIVE or 6
		local flat = flatDist(from, goal)
		local dy = goal.Y - from.Y
		local climbDy = C.AUTO_ORE_CLIMB_DY or 3.5
		local wallNear = C.AUTO_ORE_WALL_NEAR or 4.5

		-- At node (horizontal) — allow some height slack if already close
		if flat <= arrive and math.abs(dy) < (climbDy + 2) then
			setMoveKey(nil)
			if U.holdJump then
				U.holdJump(false)
			end
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			facePoint(goal)
			return "arrive"
		end

		-- ---- Climb mode ----
		if climbActive then
			local maxT = C.AUTO_ORE_CLIMB_MAX or 6
			local minRise = C.AUTO_ORE_CLIMB_MIN_RISE or 1.2
			local wallPos = climbWallHit
			local hit, normal, dist = findNearestWall(from)
			if hit then
				wallPos = hit
				climbWallHit = hit
			end
			if not wallPos then
				climbActive = false
				setMoveKey(nil)
				if U.holdJump then
					U.holdJump(false)
				end
				return "climb-no-wall"
			end

			local faceAlign = C.AUTO_ORE_CLIMB_FACE_ALIGN or 0.85
			local fd = facePoint(wallPos, faceAlign)
			if fd < faceAlign then
				setMoveKey(nil)
				if U.holdJump then
					U.holdJump(false)
				end
				return string.format("climb-face d=%.2f wall=%.1f", fd, dist or -1)
			end

			-- Pressed into wall: Space + W
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			setMoveKey("W")
			if U.holdJump then
				U.holdJump(true)
			end

			local risen = from.Y - climbStartY
			local done = (from.Y >= climbTargetY - 1.0)
				or (risen >= minRise and dy < climbDy * 0.5)
				or (os.clock() - climbStartedAt) >= maxT
			if done then
				climbActive = false
				if U.holdJump then
					U.holdJump(false)
				end
				setMoveKey(nil)
				faceOkSince = 0
				pathBuiltAt = 0 -- repath after elevation change
				return string.format("climb-done rise=%.1f", risen)
			end
			return string.format("climb W+Space rise=%.1f dy=%.1f", risen, dy)
		end

		-- Need vertical? Only climb when a wall is near (per design).
		local needHeight = dy >= climbDy
		local stuck = false
		if lastPos then
			local moved = flatDist(from, lastPos)
			if moved < 0.3 then
				if stuckSince == 0 then
					stuckSince = os.clock()
				elseif os.clock() - stuckSince > (C.AUTO_ORE_STUCK or 1.2) then
					stuck = true
				end
			else
				stuckSince = 0
			end
		end
		lastPos = from

		if needHeight or (stuck and dy > 1.5) then
			local hit, _n, dist = findNearestWall(from)
			if hit and dist and dist <= wallNear then
				climbActive = true
				climbStartedAt = os.clock()
				climbStartY = from.Y
				climbTargetY = goal.Y
				climbWallHit = hit
				setMoveKey(nil)
				if U.holdJump then
					U.holdJump(false)
				end
				faceOkSince = 0
				return string.format("climb-start wall=%.1f dy=%.1f", dist, dy)
			end
			-- Not near wall yet: if stuck with height need, walk toward nearest wall hit beyond near range
			if hit and dist and dist > wallNear then
				-- approach the wall first (horizontal), no jump yet
				goal = hit -- re-use local goal for this tick's path only
			end
		end

		-- ---- Horizontal path along A* segments ----
		ensurePath(from, goal)
		local target, segLabel = segmentTarget(from, goal)
		local faceAlign = C.AUTO_ORE_FACE_ALIGN or C.KILL_AURA_FACE_ALIGN or 0.9
		local faceSettle = C.AUTO_ORE_FACE_SETTLE or C.KILL_AURA_FACE_SETTLE or 0.18
		local fd = facePoint(target, faceAlign)

		if fd < faceAlign then
			setMoveKey(nil)
			if U.holdJump then
				U.holdJump(false)
			end
			faceOkSince = 0
			return string.format("face %s d=%.2f", segLabel, fd)
		end

		local now = os.clock()
		if faceOkSince <= 0 then
			faceOkSince = now
		end
		if (now - faceOkSince) < faceSettle then
			setMoveKey(nil)
			if U.holdJump then
				U.holdJump(false)
			end
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			return string.format("settle %s d=%.2f", segLabel, fd)
		end

		if U.holdTurnKey then
			U.holdTurnKey(nil)
		end

		local faceDir = Vector3.new(target.X - from.X, 0, target.Z - from.Z)
		if faceDir.Magnitude < 0.2 then
			advancePathIndex(from)
			setMoveKey(nil)
			return "seg-next"
		end
		faceDir = faceDir.Unit
		local probe = C.KILL_AURA_PROBE or 4.5

		-- Small step-up: Space+W without full wall climb
		local stepJump = false
		if dy > 1.2 and dy < climbDy then
			local origin = from + Vector3.new(0, 0.5, 0) + faceDir * 1.2
			local hit = workspace:Raycast(origin, faceDir * probe + Vector3.new(0, 3, 0), excludeSelf())
			if hit and hit.Normal.Y > 0.5 then
				local stepUp = hit.Position.Y - from.Y
				if stepUp > 1.0 and stepUp < 8 then
					stepJump = true
				end
			end
		end
		if U.holdJump then
			U.holdJump(stepJump)
		end

		local blocked = stuck or wallAhead(from, faceDir, probe)
		if not blocked then
			lastSlide = nil
			setMoveKey("W")
			return string.format("%s %s", if stepJump then "W+Space" else "W", segLabel)
		end

		-- Wall slide A/D
		local right = Vector3.new(-faceDir.Z, 0, faceDir.X).Unit
		local leftBlocked = wallAhead(from, -right, probe)
		local rightBlocked = wallAhead(from, right, probe)
		local pick: string
		if not leftBlocked and rightBlocked then
			pick = "A"
		elseif leftBlocked and not rightBlocked then
			pick = "D"
		elseif lastSlide and (os.clock() - lastSlideAt) < 1.5 then
			pick = lastSlide
		else
			pick = if lastSlide == "A" then "D" else "A"
		end
		lastSlide = pick
		lastSlideAt = os.clock()
		stuckSince = 0
		setMoveKey(pick)
		return string.format("turn-%s %s", pick, segLabel)
	end

	---------------------------------------------------------------------------
	-- Main loop
	---------------------------------------------------------------------------

	local function runLoop()
		setStatus("Auto Ore ON — scanning Spawn_Ore…")
		while S.autoOreEnabled do
			local ok, err = pcall(function()
				if S.proximityPaused then
					stopMove()
					setStatus("[auto-ore] prox pause")
					task.wait(0.2)
					return
				end
				if S.clawBusy then
					stopMove()
					task.wait(0.2)
					return
				end
				if S.walking then
					-- Kill Aura owns movement; yield
					stopMove()
					setStatus("[auto-ore] paused — Kill Aura on")
					task.wait(0.3)
					return
				end

				local from = playerPos()
				if not from then
					task.wait(0.15)
					return
				end

				-- Pick / refresh target
				if not currentOre or not currentOre.Parent then
					currentOre, currentOrePos = nil, nil
					local inst, pos, typeKey = pickNextOre(from)
					if not inst or not pos then
						stopMove()
						setStatus("[auto-ore] no ores found — waiting")
						task.wait(1.0)
						return
					end
					currentOre = inst
					currentOrePos = pos
					clearPath()
					dwellUntil = 0
					setStatus(string.format(
						"[auto-ore] target %s (%s) d=%.0f",
						inst.Name,
						typeKey or "?",
						(pos - from).Magnitude
					))
				else
					-- refresh position (ore may shift slightly)
					local oreApi = Ore()
					if oreApi and oreApi.getOrePosition then
						currentOrePos = oreApi.getOrePosition(currentOre) or currentOrePos
					end
				end

				if not currentOrePos then
					currentOre = nil
					return
				end

				-- Dwelling at node after arrive
				if dwellUntil > 0 then
					stopMove()
					facePoint(currentOrePos)
					if os.clock() >= dwellUntil then
						visited[currentOre] = true
						minedCount += 1
						currentOre = nil
						currentOrePos = nil
						dwellUntil = 0
						clearPath()
						setStatus(string.format("[auto-ore] next… mined=%d", minedCount))
					else
						setStatus(string.format(
							"[auto-ore] dwell %.1fs @ %s | mined=%d",
							dwellUntil - os.clock(),
							currentOre.Name,
							minedCount
						))
					end
					task.wait(0.12)
					return
				end

				local tag = approachTick(from, currentOrePos)
				if tag == "arrive" then
					stopMove()
					interactAtOre()
					dwellUntil = os.clock() + (C.AUTO_ORE_DWELL or 2.5)
					setStatus(string.format(
						"[auto-ore] arrived %s — interact+dwell",
						currentOre.Name
					))
					task.wait(0.1)
					return
				end

				local typeKey = "?"
				local oreApi = Ore()
				if oreApi and oreApi.oreTypeKey and currentOre then
					typeKey = oreApi.oreTypeKey(currentOre)
				end
				setStatus(string.format(
					"[auto-ore] %s d=%.0f %s yaw=%+.2f turn=%s %s | %s mined=%d",
					tag,
					(currentOrePos - from).Magnitude,
					pathKind,
					lastYawErr,
					lastTurnName,
					currentOre.Name,
					typeKey,
					minedCount
				))
				task.wait(C.SMOOTH_WALK_POLL or 0.06)
			end)

			if not ok then
				stopMove()
				setStatus("Auto Ore error: " .. tostring(err))
				task.wait(0.5)
			end
		end

		stopMove()
		clearFaceViz()
		clearPath()
		currentOre = nil
		currentOrePos = nil
		climbActive = false
		S.autoOreThread = nil
		refreshLabel()
		setStatus(string.format("Auto Ore OFF — mined=%d", minedCount))
	end

	---------------------------------------------------------------------------
	-- Public API
	---------------------------------------------------------------------------

	function M.stop()
		if not S.autoOreEnabled and not S.autoOreThread then
			stopMove()
			clearFaceViz()
			return
		end
		S.autoOreEnabled = false
		stopMove()
		clearFaceViz()
		refreshLabel()
	end

	function M.setEnabled(on: boolean)
		on = on and true or false
		if on == S.autoOreEnabled then
			refreshLabel()
			return
		end
		if on then
			if not Ore() or not Ore().collectOres then
				setStatus("Auto Ore failed — Ore module missing")
				return
			end
			-- Yield movement to us: stop Kill Aura if running
			if S.walking and S.Pathing and S.Pathing.toggleWalk then
				S.Pathing.toggleWalk()
			end
			S.autoOreEnabled = true
			refreshLabel()
			visited = {}
			minedCount = 0
			clearPath()
			currentOre = nil
			if not S.autoOreThread then
				S.autoOreThread = task.spawn(runLoop)
			end
		else
			M.stop()
		end
	end

	function M.toggle()
		M.setEnabled(not S.autoOreEnabled)
	end

	function M.isEnabled(): boolean
		return S.autoOreEnabled == true
	end

	return M
end

-- portal_mage/pathing.lua — Kill Aura movement
--
-- Loop:
--   1) A*/PFS path to stand ring
--   2) Face segment (soft) until aimed → THEN W + Move along path
--   3) If face drifts off path → stop W, re-face, then move again
--   4) Within fightRange → stop; face enemy; combat R/cast
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local VIM = S.Services.VirtualInputManager
	local M = {}

	local function T()
		return S.Targets
	end

	local function Nav()
		return S.Nav
	end

	local function cds(): string
		if S.Abilities and S.Abilities.formatCds then
			return S.Abilities.formatCds()
		end
		return ""
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

	---------------------------------------------------------------------------
	-- Log
	---------------------------------------------------------------------------

	local logFile: string? = nil
	local logT0 = 0

	local function logOpen()
		if C.KILL_AURA_LOG == false then
			return
		end
		logT0 = os.clock()
		local stamp = os.date("%Y-%m-%d_%H-%M-%S")
		local dir = C.DUMP_DIR or "dumps"
		logFile = string.format("%s/killaura_%s.log", dir, stamp)
		pcall(function()
			if U.ensureDir then
				U.ensureDir(dir)
			end
			writefile(logFile, "# portal_mage kill aura v8 L/R pulse face→check→W + full-path hitbox\n# " .. stamp .. "\n")
		end)
	end

	local function log(msg: string)
		if not logFile then
			return
		end
		local line = string.format("[+%.2fs] %s\n", os.clock() - logT0, msg)
		pcall(function()
			if appendfile then
				appendfile(logFile, line)
			elseif readfile and writefile and isfile and isfile(logFile) then
				writefile(logFile, readfile(logFile) .. line)
			end
		end)
	end

	local function stopMove()
		if U.releaseMoveKeys then
			U.releaseMoveKeys()
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
	-- Probes (walls / steps)
	---------------------------------------------------------------------------

	local function excludeSelf(): RaycastParams
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local lp = Players.LocalPlayer
		local excl = {}
		if lp and lp.Character then
			table.insert(excl, lp.Character)
		end
		params.FilterDescendantsInstances = excl
		return params
	end

	-- Next path node is lower → walk off ledge (W only; gravity drops). Not blocked.
	local function isElevationDrop(from: Vector3, to: Vector3): boolean
		local nav = Nav()
		if nav and nav.isElevationDrop then
			return nav.isElevationDrop(from, to)
		end
		return (to.Y - from.Y) <= -(C.NAV_DROP_ALLOW_DY or 2.0)
	end

	-- Horizontal wall ahead of current look (or toward point)
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
		return hit.Normal.Y < 0.55 -- vertical-ish surface
	end

	-- Jump only for a real ledge/step on the walk path — never because enemy is higher
	-- (log 19-36-42: W+Space spam on flat ground while enemy.Y was above path).
	local function needJumpUp(playerPos: Vector3, target: Vector3, faceDir: Vector3): boolean
		if faceDir.Magnitude < 1e-4 then
			return false
		end
		faceDir = Vector3.new(faceDir.X, 0, faceDir.Z)
		if faceDir.Magnitude < 1e-4 then
			return false
		end
		faceDir = faceDir.Unit

		local minDy = C.KILL_AURA_JUMP_MIN_DY or 2.2
		local maxDy = C.KILL_AURA_JUMP_MAX_DY or 9
		local segDy = target.Y - playerPos.Y
		local flatTo = flatDist(playerPos, target)

		-- Segment ledge: next path node is clearly higher AND close enough to jump
		if segDy >= minDy and segDy <= maxDy and flatTo <= (C.KILL_AURA_JUMP_RANGE or 8) then
			return true
		end

		-- Immediate step under feet ahead (short ray only — not distant slopes)
		local probe = C.KILL_AURA_JUMP_PROBE or 2.8
		local origin = playerPos + Vector3.new(0, 0.8, 0) + faceDir * 0.8
		local hit = workspace:Raycast(origin, faceDir * probe + Vector3.new(0, 2.2, 0), excludeSelf())
		if hit and hit.Normal.Y > 0.55 and hit.Distance <= probe + 0.5 then
			local stepUp = hit.Position.Y - playerPos.Y
			if stepUp >= minDy and stepUp <= maxDy then
				return true
			end
		end
		return false
	end

	---------------------------------------------------------------------------
	-- Face viz: thin beams from character (actual face vs desired vs turn)
	---------------------------------------------------------------------------

	local FACE_VIZ_FOLDER = "PortalMage_FaceViz"
	local faceVizFolder: Folder? = nil
	local faceVizFace: BasePart? = nil -- cyan: what we think you're facing (HRP look)
	local faceVizWant: BasePart? = nil -- lime: desired direction to enemy
	local faceVizTurn: BasePart? = nil -- yellow/magenta: left/right decision wedge

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
		if C.KILL_AURA_FACE_VIZ == false then
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
				p.Size = Vector3.new(4, 0.12, 0.12)
				styleFacePart(p, color)
				p.Parent = f
				return p
			end
			faceVizFace = mk("FaceLook", Color3.fromRGB(80, 220, 255)) -- cyan = measured face
			faceVizWant = mk("WantEnemy", Color3.fromRGB(120, 255, 100)) -- green = to enemy
			faceVizTurn = mk("TurnHint", Color3.fromRGB(255, 200, 60)) -- yellow = turn bias
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

	-- Place a thin cylinder from a→b (length along X after 90° yaw)
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

	-- Update viz: cyan = face BEFORE correction (measured), green = to enemy, turn = L/R.
	-- Pass measuredLook (flat unit) so cyan is not always equal to green after hard CFrame snap.
	local function updateFaceViz(
		hrp: BasePart,
		epos: Vector3,
		measuredLook: Vector3?,
		yawErr: number?,
		turnKey: Enum.KeyCode?
	)
		if C.KILL_AURA_FACE_VIZ == false then
			clearFaceViz()
			return
		end
		ensureFaceViz()
		local origin = hrp.Position + Vector3.new(0, 1.4, 0) -- chest height
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
		local faceLen = C.KILL_AURA_FACE_BEAM_LEN or 6
		local wantLen = faceLen * 1.15

		-- Cyan: measured facing used for yaw error / turn decision
		placeRod(faceVizFace, origin, origin + flatLook * faceLen, 0.1)

		-- Green: desired flat direction to enemy
		local toE = Vector3.new(epos.X - origin.X, 0, epos.Z - origin.Z)
		if toE.Magnitude > 0.15 then
			toE = toE.Unit
			placeRod(
				faceVizWant,
				origin + Vector3.new(0, 0.12, 0),
				origin + Vector3.new(0, 0.12, 0) + toE * wantLen,
				0.08
			)
		elseif faceVizWant then
			faceVizWant.Transparency = 1
		end

		-- Magenta LEFT / yellow RIGHT: turn key decision (from measured look)
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
	-- Face then move: Left/Right camera pulses → check aim → then W.
	-- Calibrated short holds + gaps (never permanent arrow hold = spin).
	---------------------------------------------------------------------------

	local faceAlign = C.KILL_AURA_FACE_ALIGN or 0.82
	local faceKeep = C.KILL_AURA_FACE_KEEP or C.KILL_AURA_FACE_STOP or 0.30
	if faceKeep > faceAlign - 0.15 then
		faceKeep = math.max(0.2, faceAlign - 0.45)
	end
	local faceSettle = C.KILL_AURA_FACE_SETTLE or 0.0
	local faceStuckT = C.KILL_AURA_FACE_STUCK or 0.6
	local lastFaceDot = 0
	local lastYawErr = 0
	local lastTurnName = "-"
	local faceOkSince = 0
	local walkingFacing = false
	local faceStuckSince = 0
	local faceStuckBest = -2
	local progressPos: Vector3? = nil
	local progressAt = 0
	local noProgressRepaths = 0
	local lastHrpDot = 0
	local lastCamDot = 0

	-- Arrow turn state machine: idle → hold (short) → gap (release) → remeasure
	local turnPhase = "idle" -- idle | hold | gap
	local turnPhaseUntil = 0
	local turnKeyActive: Enum.KeyCode? = nil
	local lastAbsAng = 0

	-- Camera-primary facing (L/R turns the cam; WASD follows cam in this game).
	local function facingQuality(target: Vector3): (number, number, Vector3, number, number)
		local hrp = getHrp()
		local pos = hrp and hrp.Position or target
		local to = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
		if to.Magnitude < 1e-4 then
			return 1, 0, Vector3.new(0, 0, -1), 1, 1
		end
		to = to.Unit
		local hrpDot = 0
		local measured = Vector3.new(0, 0, -1)
		if hrp then
			measured = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
			if measured.Magnitude > 1e-4 then
				measured = measured.Unit
				hrpDot = measured:Dot(to)
			end
		end
		local camDot = hrpDot
		local camLook = measured
		local cam = workspace.CurrentCamera
		if cam then
			local cl = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
			if cl.Magnitude > 1e-4 then
				cl = cl.Unit
				camLook = cl
				camDot = cl:Dot(to)
			end
		end
		-- Yaw error from camera look (what L/R arrows change)
		local yawErr = camLook.X * to.Z - camLook.Z * to.X
		return camDot, yawErr, camLook, hrpDot, camDot
	end

	local function releaseTurn()
		turnPhase = "idle"
		turnKeyActive = nil
		if U.holdTurnKey then
			U.holdTurnKey(nil)
		end
		lastTurnName = "-"
	end

	-- Calibrated L/R: short hold proportional to error, then mandatory release gap.
	-- Returns camera facing dot toward target.
	local function faceWithArrows(target: Vector3): number
		local hum = getHum()
		if hum then
			pcall(function()
				hum.AutoRotate = false
			end)
		end
		local d, yawErr, measured, hrpDot, camDot = facingQuality(target)
		-- Signed angle from cam to path (rad)
		local ang = math.atan2(yawErr, math.clamp(d, -1, 1))
		local absAng = math.abs(ang)
		local now = os.clock()
		local deadDeg = C.PATH_TURN_DEAD_DEG or 12
		local dead = math.rad(deadDeg)
		local baseHold = C.PATH_TURN_HOLD or 0.05
		local baseGap = C.PATH_TURN_GAP or 0.10
		local holdMax = C.PATH_TURN_HOLD_MAX or 0.11
		local gapMin = C.PATH_TURN_GAP_MIN or 0.07
		local invert = C.PATH_TURN_INVERT ~= false

		lastFaceDot = d
		lastYawErr = yawErr
		lastHrpDot = hrpDot
		lastCamDot = camDot
		lastAbsAng = absAng
		updateFaceViz(getHrp(), target, measured, yawErr, turnKeyActive)

		-- Aimed: release and done
		if absAng <= dead and d >= (faceAlign * 0.92) then
			releaseTurn()
			return d
		end
		if absAng <= dead * 0.6 then
			releaseTurn()
			return d
		end

		-- Pick arrow (inverted for this game)
		local key: Enum.KeyCode
		if invert then
			key = if yawErr > 0 then Enum.KeyCode.Right else Enum.KeyCode.Left
		else
			key = if yawErr > 0 then Enum.KeyCode.Left else Enum.KeyCode.Right
		end

		-- Scale: bigger error → slightly longer press; near aligned → longer gap
		local err01 = math.clamp(absAng / math.pi, 0, 1)
		local holdT = math.clamp(baseHold * (0.65 + err01 * 1.2), baseHold * 0.6, holdMax)
		local gapT = math.clamp(baseGap * (0.75 + (1 - err01) * 0.9), gapMin, baseGap * 1.8)
		-- Stuck facing: longer pulse to break inertia
		if faceStuckSince > 0 and (now - faceStuckSince) >= faceStuckT then
			holdT = math.min(holdMax * 1.15, holdT * 1.5)
		end

		if turnPhase == "hold" and turnKeyActive then
			if now < turnPhaseUntil then
				if U.holdTurnKey then
					U.holdTurnKey(turnKeyActive, false) -- keep without re-edge
				end
				lastTurnName = if turnKeyActive == Enum.KeyCode.Left then "LEFT" else "RIGHT"
				return d
			end
			-- End hold → gap
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			turnPhase = "gap"
			turnPhaseUntil = now + gapT
			turnKeyActive = nil
			lastTurnName = "-"
			return d
		end

		if turnPhase == "gap" then
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			lastTurnName = "-"
			if now < turnPhaseUntil then
				return d
			end
			turnPhase = "idle"
		end

		-- idle → start a new calibrated pulse
		turnPhase = "hold"
		turnPhaseUntil = now + holdT
		turnKeyActive = key
		if U.holdTurnKey then
			U.holdTurnKey(key, true) -- edge down
		end
		lastTurnName = if key == Enum.KeyCode.Left then "LEFT" else "RIGHT"
		updateFaceViz(getHrp(), target, measured, yawErr, key)
		return d
	end

	local function facePoint(target: Vector3): number
		return faceWithArrows(target)
	end

	local function faceEnemy(epos: Vector3): number
		return facePoint(epos)
	end

	---------------------------------------------------------------------------
	-- A* / PFS path: same segments Path Viz draws; movement follows them.
	---------------------------------------------------------------------------

	local pathPts: { Vector3 } = {}
	local pathIdx = 1
	local pathEnemy: Model? = nil
	local pathBuiltAt = 0
	local lastRepathAt = 0
	local lastVizKind = ""
	local lastSegLabel = "-"
	local segBlocked = false
	local standAngleIdx = 0 -- rotate stand goal on stuck / short path
	local ringPhase = 0 -- rotate computePath ring so repaths differ
	local blockedRouteFails = 0
	local lastPathSig = "" -- detect identical repaths (logical loop)
	-- True if candidate stand gets us meaningfully closer to the enemy.
	-- Dump 20-55-42: stone-snap pulled goals onto cobble BEHIND the player → face
	-- thrash (dot≈-0.4) and PATH_NEED timer loops with no W for minutes.
	local function goalApproachesEnemy(goal: Vector3, playerPos: Vector3, epos: Vector3, range: number): boolean
		local dPlayer = flatDist(playerPos, epos)
		local dGoal = flatDist(goal, epos)
		-- Must sit near the stand band (not a random road tile 20st off)
		if dGoal > range + 10 then
			return false
		end
		-- Must close distance (even a few studs — fightRange gap is often small)
		if dGoal >= dPlayer - 0.75 then
			return false
		end
		-- Must not be behind the player relative to the enemy (opposite-side snap)
		local toEnemy = Vector3.new(epos.X - playerPos.X, 0, epos.Z - playerPos.Z)
		local toGoal = Vector3.new(goal.X - playerPos.X, 0, goal.Z - playerPos.Z)
		if toEnemy.Magnitude > 1 and toGoal.Magnitude > 1.5 then
			if toEnemy.Unit:Dot(toGoal.Unit) < -0.15 then
				return false
			end
		end
		return true
	end

	-- Stand on the player-side of the enemy only (small ±yaw). Never opposite-side
	-- goals — those force long arc paths and look like walking in circles.
	local function standGoalNear(playerPos: Vector3, epos: Vector3, range: number, angleOffsetRad: number?): Vector3
		local nav = Nav()
		local base = Vector3.new(playerPos.X - epos.X, 0, playerPos.Z - epos.Z)
		if base.Magnitude < 0.2 then
			base = Vector3.new(0, 0, 1)
		else
			base = base.Unit
		end
		local off0 = math.clamp(angleOffsetRad or 0, -0.9, 0.9)
		local offsets = { off0, off0 + 0.4, off0 - 0.4, off0 + 0.75, off0 - 0.75, 0 }

		local function tryDest(dest: Vector3): Vector3?
			if nav and nav.sampleFloor then
				local s = nav.sampleFloor(dest.X, dest.Z, playerPos.Y, { requireClear = false })
				if s and s.pos and goalApproachesEnemy(s.pos, playerPos, epos, range) then
					return s.pos
				end
			elseif goalApproachesEnemy(dest, playerPos, epos, range) then
				return Vector3.new(dest.X, playerPos.Y, dest.Z)
			end
			-- Tight stone snap only — wide snap was yanking goals back to the player pad
			if nav and nav.snapToStonePath then
				local gs = nav.snapToStonePath(dest, 10)
				if gs and gs.pos and goalApproachesEnemy(gs.pos, playerPos, epos, range) then
					local snapDist = flatDist(gs.pos, dest)
					if snapDist <= 10 then
						return gs.pos
					end
				end
			end
			return nil
		end

		for _, off in ipairs(offsets) do
			local flat = base
			if math.abs(off) > 1e-4 then
				local c, s = math.cos(off), math.sin(off)
				flat = Vector3.new(base.X * c - base.Z * s, 0, base.X * s + base.Z * c)
				if flat.Magnitude > 1e-4 then
					flat = flat.Unit
				end
			end
			local hit = tryDest(epos + flat * range)
			if hit then
				return hit
			end
		end
		-- Last resort: geometric stand (even off-stone). computePath may still fail,
		-- but never return a behind-player snap that causes face thrash.
		local dest = epos + base * range
		return Vector3.new(dest.X, playerPos.Y, dest.Z)
	end

	local function bumpPathVariety(reason: string)
		standAngleIdx += 1
		ringPhase = (ringPhase + 0.85) % (math.pi * 2)
		log(string.format("PATH_VARIETY %s angle=%d phase=%.2f", reason, standAngleIdx, ringPhase))
	end

	local function pathSignature(pts: { Vector3 }, kind: string): string
		if not pts or #pts == 0 then
			return kind .. "|empty"
		end
		local last = pts[#pts]
		local mid = pts[math.clamp(math.ceil(#pts / 2), 1, #pts)]
		return string.format(
			"%s|n=%d|m=%.0f,%.0f|e=%.0f,%.0f",
			kind,
			#pts,
			mid.X,
			mid.Z,
			last.X,
			last.Z
		)
	end

	local function pathFlatLength(pts: { Vector3 }): number
		local len = 0
		for i = 2, #pts do
			len += flatDist(pts[i - 1], pts[i])
		end
		return len
	end

	local function advancePathIndex(playerPos: Vector3)
		local arrive = C.KILL_AURA_SEG_ARRIVE or 3.5
		local advanced = false
		-- Advance only while a *next* waypoint exists (don't thrash on last node)
		while pathIdx < #pathPts and flatDist(playerPos, pathPts[pathIdx]) <= arrive do
			pathIdx += 1
			advanced = true
		end
		if advanced then
			-- Soft reset only — hysteresis may still allow W if facing similar dir
			faceOkSince = 0
		end
		if pathIdx < 1 then
			pathIdx = 1
		end
		if #pathPts > 0 and pathIdx > #pathPts then
			pathIdx = #pathPts
		end
	end

	-- Build a clear polyline to player-side stand. Never walk a line through a wall.
	-- ringPhase / standAngleIdx change on stuck so we do not rebuild the same dead path.
	local function rebuildPath(playerPos: Vector3, epos: Vector3, enemy: Model, range: number)
		local nav = Nav()
		local angOff = ((standAngleIdx % 7) - 3) * 0.35
		local goal = standGoalNear(playerPos, epos, range, angOff)
		local pts: { Vector3 } = {}
		local kind = "none"
		local maxGoals = C.NAV_PATH_MAX_GOALS or 6

		-- Prefer recorded spawn corridor when standing on/near one (human stone route).
		-- Free A* from the pad often invents wall-clips; respawn_paths.json is the truth.
		do
			local PR = S.PathRecord
			if PR and PR.buildCorridorToward then
				local corridor = PR.buildCorridorToward(epos, C.RESPAWN_PATH_MATCH_STUDS or 64)
				if type(corridor) == "table" and #corridor >= 3 then
					local endP = corridor[#corridor]
					if flatDist(endP, epos) < flatDist(playerPos, epos) - 3 then
						pts = corridor
						kind = "spawn_corridor"
						goal = endP
						log(string.format(
							"path spawn_corridor (prefer) wps=%d → %s",
							#pts,
							enemy.Name
						))
					end
				end
			end
		end

		if #pts < 2 and nav and nav.computePath then
			local tryPts, tryKind = nav.computePath(playerPos, goal, {
				maxGoals = maxGoals,
				ringN = 6,
				ringR = { 10, 18, 28 },
				ringPhase = ringPhase,
			})
			local blocked = (not tryPts)
				or #tryPts < 2
				or tryKind == "blocked"
				or (type(tryKind) == "string" and string.sub(tryKind, 1, 7) == "blocked")
				or tryKind == "line:soft"
			if not blocked and tryPts then
				-- Full-path clearance (stone + map walls). Escape used to accept
				-- first-hop-only and clip through InvisibleWall.
				local hopOk = true
				if nav.pathSegmentsClear then
					hopOk = nav.pathSegmentsClear(tryPts)
				elseif nav.hasClearWalk then
					local hopTo = tryPts[math.min(2, #tryPts)]
					hopOk = nav.hasClearWalk(playerPos, hopTo)
				end
				if hopOk then
					local straight = flatDist(playerPos, tryPts[#tryPts])
					local plen = pathFlatLength(tryPts)
					local maxDet = C.KILL_AURA_MAX_PATH_DETOR or 2.8
					if straight < 4 or plen <= straight * maxDet then
						pts = tryPts
						kind = tryKind
					end
				end
			end
		end

		-- Drop routes whose end does not approach the enemy (stone-snap false paths)
		local function acceptRoute(tryPts: { Vector3 }, tryKind: string, tryGoal: Vector3): boolean
			if not tryPts or #tryPts < 2 then
				return false
			end
			local endP = tryPts[#tryPts]
			if not goalApproachesEnemy(endP, playerPos, epos, range)
				and not goalApproachesEnemy(tryGoal, playerPos, epos, range)
			then
				log(string.format(
					"path REJECT %s end=(%.0f,%.0f) dEnemy=%.1f (no approach)",
					tryKind,
					endP.X,
					endP.Z,
					flatDist(endP, epos)
				))
				return false
			end
			-- Never accept a wall-clipping polyline (recorded spawn corridors are trusted)
			if tryKind ~= "spawn_corridor"
				and nav
				and nav.pathSegmentsClear
				and not nav.pathSegmentsClear(tryPts)
			then
				log(string.format("path REJECT %s (wall/clearance)", tryKind))
				return false
			end
			return true
		end

		if #pts >= 2 and not acceptRoute(pts, kind, goal) then
			pts = {}
			kind = "none"
		end

		if #pts < 2 then
			-- Prefer snap to stone path then straight line on stone
			local fromP, goalP = playerPos, goal
			if nav and nav.snapToStonePath then
				local fs = nav.snapToStonePath(playerPos)
				local gs = nav.snapToStonePath(goal, 10)
				if fs and fs.pos then
					fromP = fs.pos
				end
				if gs and gs.pos and goalApproachesEnemy(gs.pos, playerPos, epos, range) then
					goalP = gs.pos
				end
			end
			if goalApproachesEnemy(goalP, playerPos, epos, range)
				and nav
				and nav.hasClearWalk
				and nav.hasClearWalk(fromP, goalP)
			then
				pts = { fromP, goalP }
				kind = "line:stone"
				goal = goalP
			elseif goalApproachesEnemy(goal, playerPos, epos, range) and (not nav or not nav.hasClearWalk) then
				pts = { playerPos, goal }
				kind = "line:nocheck"
			else
				local base = Vector3.new(playerPos.X - epos.X, 0, playerPos.Z - epos.Z)
				if base.Magnitude < 0.2 then
					base = Vector3.new(0, 0, 1)
				else
					base = base.Unit
				end
				for _, ang in ipairs({ 0.5, -0.5, 1.0, -1.0, 1.4, -1.4, 2.0, -2.0 }) do
					local c, s = math.cos(ang + ringPhase * 0.25), math.sin(ang + ringPhase * 0.25)
					local flat = Vector3.new(base.X * c - base.Z * s, 0, base.X * s + base.Z * c)
					local cand = epos + flat.Unit * range
					if nav and nav.snapToStonePath then
						local gs = nav.snapToStonePath(cand, 10)
						if gs and gs.pos and goalApproachesEnemy(gs.pos, playerPos, epos, range) then
							cand = gs.pos
						end
					end
					if goalApproachesEnemy(cand, playerPos, epos, range)
						and nav
						and nav.hasClearWalk
						and nav.hasClearWalk(fromP, cand)
					then
						pts = { fromP, cand }
						kind = "line:side"
						goal = cand
						break
					end
				end
			end
		end

		if #pts >= 2 and not acceptRoute(pts, kind, goal) then
			pts = {}
			kind = "none"
		end

		-- Free A* failed: follow recorded respawn corridor (human stone route) toward enemy
		-- instead of inventing a wall-clip / sand cut. Dump 01-47-07: stood on spawn_1009
		-- while A* stayed BLOCKED — corridor is the intended egress.
		if #pts < 2 then
			local PR = S.PathRecord
			if PR and PR.buildCorridorToward then
				local corridor = PR.buildCorridorToward(epos, C.RESPAWN_PATH_MATCH_STUDS or 64)
				if type(corridor) == "table" and #corridor >= 2 then
					local endP = corridor[#corridor]
					if flatDist(endP, epos) < flatDist(playerPos, epos) - 2 then
						pts = corridor
						kind = "spawn_corridor"
						goal = endP
						log(string.format(
							"path spawn_corridor wps=%d → %s dEnemy=%.1f",
							#pts,
							enemy.Name,
							flatDist(endP, epos)
						))
					end
				end
			end
		end

		-- Stand-band unreachable (enemy off stone / lower terrace): still walk stone
		-- that closes distance. Dump 02-15-11: only BLOCKED thrash at dist≈54 with
		-- goals at y=106 while player on y=112 stone under tower AABB.
		if #pts < 2 and nav and nav.computePath then
			local progressGoal = epos
			if nav.snapToStonePath then
				local gs = nav.snapToStonePath(epos, 28)
				if gs and gs.pos then
					progressGoal = gs.pos
				end
			end
			local dNow = flatDist(playerPos, epos)
			local dProg = flatDist(progressGoal, epos)
			if dProg < dNow - 2 then
				local tryPts, tryKind = nav.computePath(playerPos, progressGoal, {
					maxGoals = maxGoals,
					ringN = 6,
					ringR = { 10, 18, 28 },
					ringPhase = ringPhase,
				})
				if tryPts and #tryPts >= 2 and tryKind ~= "blocked"
					and not (type(tryKind) == "string" and string.sub(tryKind, 1, 7) == "blocked")
				then
					local endP = tryPts[#tryPts]
					if flatDist(endP, epos) < dNow - 2 then
						local hopOk = true
						if nav.pathSegmentsClear then
							hopOk = nav.pathSegmentsClear(tryPts)
						end
						if hopOk then
							pts = tryPts
							kind = "stone:progress"
							goal = endP
							log(string.format(
								"path stone:progress wps=%d → %s dEnemy=%.1f→%.1f",
								#pts,
								enemy.Name,
								dNow,
								flatDist(endP, epos)
							))
						end
					end
				end
			end
		end

		if #pts < 2 then
			pts = { playerPos }
			kind = "blocked"
			blockedRouteFails += 1
			bumpPathVariety("blocked")
			log(string.format("path BLOCKED n=%d → %s", blockedRouteFails, enemy.Name))
			if blockedRouteFails >= 3 then
				local Targets = T()
				if Targets and Targets.clearHold then
					Targets.clearHold("path_blocked")
				end
				blockedRouteFails = 0
				if standAngleIdx >= 8 then
					standAngleIdx = 0
					ringPhase = 0
					lastPathSig = ""
					log(string.format(
						"path BLOCKED_ESCAPE angle reset dist=%.1f → clearHold",
						flatDist(playerPos, epos)
					))
				end
			end
		else
			blockedRouteFails = 0
			-- Identical path as last stuck rebuild → force variety next time
			local sig = pathSignature(pts, kind)
			if sig == lastPathSig then
				bumpPathVariety("same_path")
			end
			lastPathSig = sig
		end

		pathPts = pts
		pathEnemy = enemy
		pathBuiltAt = os.clock()
		lastRepathAt = pathBuiltAt
		lastVizKind = kind
		pathIdx = 1
		segBlocked = kind == "blocked"
		-- Path Viz OFF → sweep markers every rebuild (stops leftover green nodes)
		if not S.pathVizEnabled then
			if nav and nav.clearPathViz then
				nav.clearPathViz()
			else
				pcall(function()
					for _, ch in ipairs(workspace:GetChildren()) do
						if ch.Name == "PortalMage_PathViz"
							or string.find(ch.Name, "PortalMage_PathViz", 1, true) == 1
						then
							ch:Destroy()
						end
					end
				end)
				S.pathVizFolder = nil
			end
		end
		-- Full-path clearance hitboxes for Clear Hitbox viz only (not Path Viz)
		if S.hitboxVizEnabled and nav and nav.probeFullPath and #pathPts >= 2 then
			nav.probeFullPath(pathPts)
		end
		-- Reset progress so we don't immediately NO_PROGRESS on a fresh path
		progressPos = playerPos
		progressAt = pathBuiltAt
		advancePathIndex(playerPos)
		if pathIdx < #pathPts and flatDist(playerPos, pathPts[pathIdx]) < 1.0 then
			pathIdx = math.min(pathIdx + 1, #pathPts)
		end

		local recPts = {}
		for _, p in ipairs(pathPts) do
			table.insert(recPts, { x = p.X, y = p.Y, z = p.Z })
		end
		S.lastKillAuraPath = {
			source = "kill_aura",
			kind = kind,
			points = recPts,
			waypointCount = #pathPts,
			idx = pathIdx,
			goal = { x = goal.X, y = goal.Y, z = goal.Z },
			from = { x = playerPos.X, y = playerPos.Y, z = playerPos.Z },
			enemy = enemy and enemy.Name or nil,
			segBlocked = segBlocked,
			at = os.clock(),
		}
		S.lastBotPath = S.lastKillAuraPath
		local parts = {}
		for i, p in ipairs(pathPts) do
			table.insert(parts, string.format("%d:%.0f,%.0f,%.0f", i, p.X, p.Y, p.Z))
		end
		log(string.format(
			"path %s wps=%d idx=%d goal=(%.1f,%.1f,%.1f) → %s",
			kind,
			#pathPts,
			pathIdx,
			goal.X,
			goal.Y,
			goal.Z,
			enemy.Name
		))
		if #parts > 0 then
			log("  WPS " .. table.concat(parts, " | "))
		end
	end

	local function ensurePath(playerPos: Vector3, epos: Vector3, enemy: Model, range: number, force: boolean?)
		local interval = C.PATH_REBUILD or 10.0
		local repathCd = C.PATH_REPATH_COOLDOWN or 2.0
		local now = os.clock()
		local sticky = C.KILL_AURA_STICKY or 4
		local arrive = C.KILL_AURA_SEG_ARRIVE or 3.5
		local need = force == true
			or pathEnemy ~= enemy
			or #pathPts < 2
			or (now - pathBuiltAt) >= interval
		local why = "timer"
		if force then
			why = "force"
		elseif pathEnemy ~= enemy then
			why = "enemy"
		elseif #pathPts < 2 then
			why = "empty"
		end
		if not need and pathIdx <= #pathPts then
			if flatDist(playerPos, pathPts[pathIdx]) > 36 then
				need = true
				why = "drift"
			end
		end
		-- Finished a short/prefix path but still outside stand band → new path, not W@enemy
		if not need and #pathPts >= 1 and pathIdx >= #pathPts then
			local last = pathPts[#pathPts]
			if flatDist(playerPos, last) <= arrive * 1.25 and flatDist(playerPos, epos) > range + sticky then
				need = true
				why = "short_path"
				bumpPathVariety("short_path")
				-- Dump 20-46-03: short_path/same_path spun for 7+ min at dist=34.5 with
				-- almost no W. After enough variety, drop hold and pick another mob.
				if standAngleIdx >= 12 then
					log(string.format(
						"path STUCK_ESCAPE angle=%d dist=%.1f → clearHold",
						standAngleIdx,
						flatDist(playerPos, epos)
					))
					local Targets = T()
					if Targets and Targets.clearHold then
						Targets.clearHold("path_stuck_escape")
					end
					standAngleIdx = 0
					ringPhase = 0
					lastPathSig = ""
					pathPts = {}
					pathEnemy = nil
					return
				end
			end
		end
		-- Do NOT mid-run hasClearWalk repath (false clear/blocked thrash). Stuck → NO_PROGRESS.

		if need then
			local canRebuild = force
				or pathEnemy ~= enemy
				or #pathPts < 2
				or why == "short_path"
				or (now - lastRepathAt) >= repathCd
			if canRebuild then
				log(string.format("PATH_NEED %s", why))
				rebuildPath(playerPos, epos, enemy, range)
			else
				advancePathIndex(playerPos)
			end
		else
			advancePathIndex(playerPos)
		end
	end

	-- Next world point to face/walk toward.
	-- Stable aim: current waypoint only (no blend — blend made face thrash every tick).
	-- Advance to next when close; never face enemy mid-path through walls.
	local function segmentTarget(playerPos: Vector3, epos: Vector3, range: number): (Vector3, string)
		local distEnemy = flatDist(playerPos, epos)
		if distEnemy <= range then
			return epos, "enemy"
		end
		if #pathPts >= 1 and pathIdx >= 1 and pathIdx <= #pathPts then
			local arrive = C.KILL_AURA_SEG_ARRIVE or 4
			-- Prefer next node when we're already on this one
			local idx = pathIdx
			while idx < #pathPts and flatDist(playerPos, pathPts[idx]) <= arrive * 0.85 do
				idx += 1
			end
			if idx ~= pathIdx then
				pathIdx = idx
			end
			local wp = pathPts[pathIdx]
			return wp, string.format("seg%d/%d", pathIdx, #pathPts)
		end
		return standGoalNear(playerPos, epos, range), "stand"
	end

	-- Distance-only stand band. hasClearWalk gate here caused permanent approach
	-- loops when soft LOS failed (log: wait stand / around wall forever).
	local function canStandForCombat(playerPos: Vector3, epos: Vector3, range: number, sticky: number): boolean
		local dist = flatDist(playerPos, epos)
		return dist <= range + sticky
	end

	local function clearPathState()
		pathPts = {}
		pathIdx = 1
		pathEnemy = nil
		pathBuiltAt = 0
		lastRepathAt = 0
		faceOkSince = 0
		walkingFacing = false
		faceStuckSince = 0
		faceStuckBest = -2
		progressPos = nil
		progressAt = 0
		noProgressRepaths = 0
		standAngleIdx = 0
		ringPhase = 0
		blockedRouteFails = 0
		segBlocked = false
		lastSegLabel = "-"
		lastPathSig = ""
		S.stoneRecoverBusy = false
	end

	local function clearPathVizIfOff()
		if S.pathVizEnabled then
			return
		end
		local nav = Nav()
		if nav and nav.clearPathViz then
			nav.clearPathViz()
		end
		-- Belt-and-suspenders: destroy any leftover folder even if Nav ref is stale
		pcall(function()
			for _, ch in ipairs(workspace:GetChildren()) do
				if ch.Name == "PortalMage_PathViz"
					or string.find(ch.Name, "PortalMage_PathViz", 1, true) == 1
				then
					ch:Destroy()
				end
			end
		end)
		S.pathVizFolder = nil
	end

	---------------------------------------------------------------------------
	-- Move: only W, A, or D (exactly one). Optional Space with W.
	---------------------------------------------------------------------------

	local lastSlide: string? = nil -- "A" | "D"
	local lastSlideAt = 0
	local lastPos: Vector3? = nil
	local stuckSince = 0

	-- which: "W"|"A"|"D"|"WA"|"WD"|nil  (human rec uses W+D to arc around blocks)
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
		elseif which == "WA" then
			U.holdMoveKeys({ Enum.KeyCode.W, Enum.KeyCode.A })
		elseif which == "WD" then
			U.holdMoveKeys({ Enum.KeyCode.W, Enum.KeyCode.D })
		else
			U.holdMoveKeys(nil)
		end
	end

	-- Drive body toward a flat world direction (keys + engine Move).
	-- Keys alone fail when AutoRotate is off or the game ignores key spoof mid-face.
	local function driveForward(faceDir: Vector3, jump: boolean)
		if U.holdTurnKey then
			U.holdTurnKey(nil)
		end
		setMoveKey("W")
		if U.holdJump then
			U.holdJump(jump)
		end
		local hum = getHum()
		if hum and faceDir.Magnitude > 1e-4 then
			pcall(function()
				hum.AutoRotate = false
				hum.PlatformStand = false
				-- world-space Move: works with AutoRotate off (WASD alone often does not)
				hum:Move(faceDir.Unit, false)
			end)
		end
	end

	local function driveStop()
		releaseTurn()
		setMoveKey(nil)
		if U.holdJump then
			U.holdJump(false)
		end
		local hum = getHum()
		if hum then
			pcall(function()
				hum:Move(Vector3.zero)
				hum.PlatformStand = false
			end)
		end
	end

	-- Between-fight stone-recover walk removed (stuck over obstacles).

	-- Approach: face A* segment → check HRP aim → only then W/Move.
	-- Never rotate aggressively while walking; never arrow-spin.
	local function approachStep(playerPos: Vector3, epos: Vector3, range: number): string
		local hum = getHum()
		if hum then
			pcall(function()
				hum.AutoRotate = false
				hum.PlatformStand = false
			end)
		end
		if U.holdTurnKey then
			U.holdTurnKey(nil)
		end

		local dist = flatDist(playerPos, epos)
		if dist <= range then
			faceWithArrows(epos)
			driveStop()
			walkingFacing = false
			faceOkSince = 0
			return "stand"
		end

		local target, segLabel = segmentTarget(playerPos, epos, range)
		lastSegLabel = segLabel

		local faceDir = Vector3.new(target.X - playerPos.X, 0, target.Z - playerPos.Z)
		if faceDir.Magnitude < 0.5 then
			advancePathIndex(playerPos)
			if pathIdx >= #pathPts and dist > range then
				local nav = Nav()
				local clearToEnemy = not nav or not nav.hasClearWalk or nav.hasClearWalk(playerPos, epos)
				if clearToEnemy and dist <= range + (C.KILL_AURA_STICKY or 4) + 6 then
					target = epos
					segLabel = "enemy"
					faceDir = Vector3.new(epos.X - playerPos.X, 0, epos.Z - playerPos.Z)
				else
					bumpPathVariety("end_of_path")
					pathBuiltAt = 0
					driveStop()
					walkingFacing = false
					return "repath-end"
				end
			else
				target, segLabel = segmentTarget(playerPos, epos, range)
				faceDir = Vector3.new(target.X - playerPos.X, 0, target.Z - playerPos.Z)
			end
			lastSegLabel = segLabel
		end

		if faceDir.Magnitude < 0.15 then
			bumpPathVariety("pin")
			pathBuiltAt = 0
			driveStop()
			walkingFacing = false
			return "repath-pin"
		end
		faceDir = faceDir.Unit

		---------------------------------------------------------------------------
		-- 1) L/R camera pulses toward path. 2) Check cam aim. 3) W only if aimed.
		---------------------------------------------------------------------------
		local now = os.clock()
		local d: number

		if not walkingFacing then
			-- Establishing face — arrows only, no W
			setMoveKey(nil)
			if U.holdJump then
				U.holdJump(false)
			end
			local hum0 = getHum()
			if hum0 then
				pcall(function()
					hum0:Move(Vector3.zero)
				end)
			end
			d = faceWithArrows(target)
			if d >= faceAlign and lastAbsAng <= math.rad((C.PATH_TURN_DEAD_DEG or 12) * 1.1) then
				if faceOkSince <= 0 then
					faceOkSince = now
				end
				if (now - faceOkSince) >= faceSettle then
					walkingFacing = true
					faceStuckSince = 0
					faceStuckBest = -2
					progressPos = playerPos
					progressAt = now
					releaseTurn()
					-- fall through to walk
				else
					return string.format("settle %.2f %s", d, segLabel)
				end
			else
				faceOkSince = 0
				if faceStuckSince <= 0 then
					faceStuckSince = now
					faceStuckBest = d
				elseif d > faceStuckBest + 0.03 then
					faceStuckBest = d
					faceStuckSince = now
				end
				return string.format("face %.2f %s t=%s", d, segLabel, lastTurnName)
			end
		else
			-- Walking: re-face only if BOTH cam and HRP are badly off.
			-- Dump 01-26-46: cam=0.27 hrp=0.52 → full stop mid-escape (reface thrash).
			d = select(1, facingQuality(target))
			local _, yawErr, measured, hrpDot, camDot = facingQuality(target)
			lastFaceDot = d
			lastYawErr = yawErr
			lastHrpDot = hrpDot
			lastCamDot = camDot
			local keepDot = math.max(d, hrpDot)
			if keepDot < faceKeep then
				walkingFacing = false
				faceOkSince = 0
				faceStuckSince = 0
				driveStop()
				return string.format("reface %.2f %s", d, segLabel)
			end
			if d < faceAlign then
				-- small corrections while walking (still pulsed L/R, not CFrame)
				faceWithArrows(target)
			else
				releaseTurn()
				updateFaceViz(getHrp(), target, measured, yawErr, nil)
			end
		end

		-- Aimed at path → walk (release arrows first so W isn't fighting turn)
		if turnPhase == "hold" then
			-- finish current pulse before walking straight
			return string.format("face %.2f %s t=%s", d, segLabel, lastTurnName)
		end
		releaseTurn()
		local jump = needJumpUp(playerPos, target, faceDir)
		driveForward(faceDir, jump)

		-- Progress watchdog (also escapes face thrash if XZ frozen)
		if not progressPos or flatDist(playerPos, progressPos) > 1.0 then
			progressPos = playerPos
			progressAt = now
			noProgressRepaths = 0
		elseif (now - progressAt) >= (C.KILL_AURA_NO_PROGRESS or 2.0) then
			noProgressRepaths += 1
			progressAt = now
			log(string.format("NO_PROGRESS n=%d d=%.1f %s idx=%d/%d", noProgressRepaths, dist, segLabel, pathIdx, #pathPts))
			if pathIdx < #pathPts then
				pathIdx += 1
				progressPos = playerPos
				walkingFacing = false
				faceOkSince = 0
				return string.format("skip-stuck %d/%d", pathIdx, #pathPts)
			end
			bumpPathVariety("no_progress")
			pathBuiltAt = 0
			walkingFacing = false
			faceOkSince = 0
			if noProgressRepaths >= 4 then
				local Targets = T()
				if Targets and Targets.clearHold then
					Targets.clearHold("no_progress")
				end
				noProgressRepaths = 0
				lastPathSig = ""
				return "drop-stuck"
			end
			driveStop()
			return "repath-stuck"
		end

		return string.format("%s %s", if jump then "W+Space" else "W", segLabel)
	end

	---------------------------------------------------------------------------
	-- Main loop
	---------------------------------------------------------------------------

	local function runWalker()
		logOpen()
		log("walker start v8 L/R pulse face→check→W")

		while S.walking do
			local ok, err = pcall(function()
				local Targets = T()
				if not Targets then
					task.wait(0.2)
					return
				end

				if S.resourceRecoverPhase == "regen" or S.zRegenBusy then
					stopMove()
					U.setStatus("[path] paused — recover")
					task.wait(0.15)
					return
				end

				if U.killAuraBlocked then
					local blocked, why = U.killAuraBlocked()
					if blocked then
						stopMove()
						if why == "sitting" then
							U.setStatus("[path] sitting — Z")
							if U.ensureStanding then
								U.ensureStanding(2.5)
							end
						elseif why == "sheathed" or why == "no_weapon" then
							U.setStatus("[path] sheathed — Q")
							if U.markWeaponSheathed then
								U.markWeaponSheathed()
							end
							if U.ensureWeaponDrawn then
								U.ensureWeaponDrawn(1.2, true)
							end
						else
							U.setStatus(string.format("[path] paused (%s)", tostring(why)))
						end
						task.wait(0.15)
						return
					end
				end

				-- Legacy flag (combat no longer sets it). Never freeze pathing here.
				if S.waitAllCds then
					S.waitAllCds = false
				end

				if S.combatBusy then
					-- Keep facing but no move mid-cast
					driveStop()
					task.wait(0.05)
					return
				end

				local playerPos = U.getLivePlayerVector()
				if not playerPos then
					task.wait(0.1)
					return
				end

				-- Path Viz OFF: continuously destroy leftovers (async redraw races)
				if not S.pathVizEnabled then
					clearPathVizIfOff()
				end

				-- Between-fight "walk to nearest stone over obstacles" removed —
				-- it caused more stuck than off-stone starts (user 2026-08-18).
				S.stoneRecoverBusy = false

				local range = Targets.fightRange()
				local sticky = C.KILL_AURA_STICKY or 4
				local model, epos, dist3 = Targets.ensureEnemy()

				if not model or not epos then
					stopMove()
					clearPathState()
					U.setStatus(string.format("[scan] no enemies ≤%d | %s", Targets.scanRange(), cds()))
					task.wait(0.2)
					return
				end

				-- Always use flat XZ for stand/approach (matches approachStep; avoids
				-- height-delta deadlock where path "stands" but combat waits).
				local dist = flatDist(playerPos, epos)

				-- A*/PFS path = movement segments (+ Path Viz when ON)
				ensurePath(playerPos, epos, model, range)

						-- Need a clear multi-point path. Never force line:enemy through walls.
				if #pathPts < 2 then
					rebuildPath(playerPos, epos, model, range)
				end
				if #pathPts < 2 then
					-- Blocked: stop moving, wait for repath / new enemy
					driveStop()
					U.setStatus(string.format(
						"[path] blocked d=%.1f %s | %s",
						dist,
						model.Name,
						cds()
					))
					task.wait(0.2)
					return
				end

				-- Stand band = distance only. Soft face enemy (no arrows, no spin).
				if canStandForCombat(playerPos, epos, range, sticky) then
					faceWithArrows(epos)
					driveStop()
					walkingFacing = false
					faceOkSince = 0
					local fd, yawErr, _m, hrpDot, camDot = facingQuality(epos)
					lastFaceDot = fd
					lastYawErr = yawErr
					lastHrpDot = hrpDot
					lastCamDot = camDot
					lastTurnName = "-"
					local pathInfo = string.format(" %s#%d", lastVizKind, #pathPts)
					U.setStatus(string.format(
						"[stand] d=%.1f face=%.2f h/c=%.2f/%.2f yaw=%+.2f %s%s | %s",
						dist,
						fd,
						hrpDot,
						camDot,
						yawErr,
						model.Name,
						pathInfo,
						cds()
					))
					task.wait(0.08)
					return
				end

				local tag = approachStep(playerPos, epos, range)
				U.setStatus(string.format(
					"[approach] d=%.1f %s yaw=%+.2f h/c=%.2f/%.2f turn=%s → %s %s | %s",
					dist,
					tag,
					lastYawErr,
					lastHrpDot,
					lastCamDot,
					lastTurnName,
					model.Name,
					lastVizKind,
					cds()
				))
				local head = string.sub(tag, 1, 4)
				if head == "face"
					or head == "sett"
					or head == "refa"
					or head == "wall"
					or head == "skip"
					or head == "repa"
					or head == "drop"
					or string.sub(tag, 1, 1) == "W"
				then
					log(string.format(
						"%s yaw=%+.3f hrp=%.2f cam=%.2f enemy=%s dist=%.1f idx=%d/%d kind=%s walk=%s",
						tag,
						lastYawErr,
						lastHrpDot,
						lastCamDot,
						model.Name,
						dist,
						pathIdx,
						#pathPts,
						lastVizKind,
						tostring(walkingFacing)
					))
				end
				task.wait(C.SMOOTH_WALK_POLL or 0.06)
			end)

			if not ok then
				stopMove()
				log("ERROR " .. tostring(err))
				U.setStatus("Path error: " .. tostring(err))
				task.wait(0.4)
			end
		end

		stopMove()
		clearFaceViz()
		clearPathState()
		clearPathVizIfOff()
		local nav = Nav()
		if nav and nav.clearPathViz then
			pcall(function()
				nav.clearPathViz()
			end)
		end
		log("walker stop")
		if logFile then
			U.setStatus("Kill Aura stopped — log " .. tostring(logFile))
		else
			U.setStatus("Kill Aura stopped")
		end
		S.walking = false
		S.combatBusy = false
		S.ui.setWalkLabel(false)
	end

	-- Live + last kill-aura route for Dump A* path.
	function M.getPathSnapshot(): any
		local pts = {}
		for i, p in ipairs(pathPts) do
			table.insert(pts, { i = i, x = p.X, y = p.Y, z = p.Z })
		end
		local playerPos = U.getLivePlayerVector and U.getLivePlayerVector()
		local hopClear = {}
		local nav = Nav()
		if nav and nav.hasClearWalk and #pathPts >= 2 then
			for i = 1, #pathPts - 1 do
				local ok = nav.hasClearWalk(pathPts[i], pathPts[i + 1])
				table.insert(hopClear, {
					from = i,
					to = i + 1,
					clear = ok == true,
				})
			end
			if playerPos and pathIdx >= 1 and pathIdx <= #pathPts then
				table.insert(hopClear, 1, {
					from = "player",
					to = pathIdx,
					clear = nav.hasClearWalk(playerPos, pathPts[pathIdx]) == true,
				})
			end
		end
		return {
			source = "kill_aura",
			live = true,
			walking = S.walking == true,
			kind = lastVizKind,
			pathIdx = pathIdx,
			waypointCount = #pathPts,
			points = pts,
			segBlocked = segBlocked,
			standAngleIdx = standAngleIdx,
			blockedRouteFails = blockedRouteFails,
			enemy = pathEnemy and pathEnemy.Name or nil,
			player = playerPos and { x = playerPos.X, y = playerPos.Y, z = playerPos.Z } or nil,
			hopClear = hopClear,
			pathBuiltAt = pathBuiltAt,
			lastRepathAt = lastRepathAt,
			at = os.clock(),
		}
	end

	function M.togglePathViz()
		local nav = Nav()
		local turningOn = not S.pathVizEnabled
		if nav and nav.setPathVizEnabled then
			nav.setPathVizEnabled(turningOn)
		else
			S.pathVizEnabled = turningOn
			if S.ui and S.ui.setPathVizLabel then
				S.ui.setPathVizLabel(S.pathVizEnabled)
			end
		end
		-- Always hard-clear workspace folder when OFF (stale folder left neon boxes)
		if not S.pathVizEnabled then
			if nav and nav.clearPathViz then
				nav.clearPathViz()
			end
			pcall(function()
				local f = workspace:FindFirstChild("PortalMage_PathViz")
				if f then
					f:Destroy()
				end
			end)
			return
		end
		-- ON: force path rebuild so viz redraws immediately
		pathBuiltAt = 0
		pathEnemy = nil
		if S.walking then
			local p = U.getLivePlayerVector and U.getLivePlayerVector()
			local model, epos = nil, nil
			if T() and T().getHold then
				model = T().getHold()
				if model and U.getCharacterLikePosition then
					epos = U.getCharacterLikePosition(model)
				end
			end
			if p and model and epos then
				ensurePath(p, epos, model, T().fightRange(), true)
			end
		end
	end

	function M.setPathVizEnabled(on: boolean)
		local nav = Nav()
		if nav and nav.setPathVizEnabled then
			nav.setPathVizEnabled(on)
		else
			S.pathVizEnabled = on and true or false
			if S.ui and S.ui.setPathVizLabel then
				S.ui.setPathVizLabel(S.pathVizEnabled)
			end
		end
		if not S.pathVizEnabled then
			if nav and nav.clearPathViz then
				nav.clearPathViz()
			end
			pcall(function()
				local f = workspace:FindFirstChild("PortalMage_PathViz")
				if f then
					f:Destroy()
				end
			end)
			return
		end
		pathBuiltAt = 0
		pathEnemy = nil
	end

	-- Shared start path for toggleWalk / post-respawn resume.
	-- opts.fromRespawn: skip "finish respawn first" guard (caller owns that).
	function M.startWalk(opts: any?): boolean
		opts = opts or {}
		if S.walking then
			return true
		end
		if not opts.fromRespawn then
			if S.zRegenBusy or S.respawnResumeWalk then
				U.setStatus("Kill Aura blocked — finish respawn first")
				return false
			end
		end

		if S.proximityGuardEnabled and S.Proximity and not opts.ignoreProx then
			local threat, plr, dist = S.Proximity.isThreatNearby()
			if threat and plr and dist then
				U.setStatus(string.format("Kill Aura blocked — %s @ %.0fst", plr.Name, dist))
				return false
			end
		end

		if not S.Targets or not S.Combat then
			U.setStatus("Kill Aura failed: Targets/Combat missing — reload")
			return false
		end

		-- Post-respawn: ignore WalkSpeed≈0 false sit (spawn lag). Hard sit only.
		local seatedCheck = if opts.fromRespawn and U.isSeatedHard then U.isSeatedHard else U.isSeated
		if seatedCheck and seatedCheck() then
			U.setStatus("Kill Aura: sitting — Z…")
			if U.ensureStanding then
				U.ensureStanding(3.0)
			end
			if seatedCheck() then
				U.setStatus("Kill Aura blocked — still sitting")
				return false
			end
		end

		if U.detectWeaponDrawnHard and select(1, U.detectWeaponDrawnHard()) then
			if U.markWeaponDrawn then
				U.markWeaponDrawn()
			end
		else
			U.setStatus("Kill Aura: force unsheath (Q)…")
			if U.markWeaponSheathed then
				U.markWeaponSheathed()
			end
			if U.ensureWeaponDrawn then
				U.ensureWeaponDrawn(1.5, true)
			end
		end

		if S.autoOreEnabled and S.AutoOre and S.AutoOre.stop then
			S.AutoOre.stop()
		end

		S.holdTarget = nil
		S.combatBusy = false
		S.buffBusy = false
		S.waitAllCds = false
		S.resourceRecoverPhase = nil
		S.zRegenBusy = false
		S.respawnResumeWalk = false
		S.combatPhase = "fight"
		S.walking = true
		S.ui.setWalkLabel(true)
		lastSlide = nil
		lastPos = nil
		stuckSince = 0
		clearPathState()

		U.setStatus(string.format(
			"Kill Aura ON — L/R face→check→W→stand@%d→R/cast%s",
			T().fightRange(),
			opts.fromRespawn and " (post-respawn)" or ""
		))

		S.walkThread = task.spawn(runWalker)
		S.combatThread = task.spawn(S.Combat.runCombat)
		return true
	end

	function M.toggleWalk(_opts: any?)
		if S.walking then
			S.walking = false
			S.combatBusy = false
			S.buffBusy = false
			S.waitAllCds = false
			S.proximityResumeWalk = false
			S.respawnResumeWalk = false
			S.armedCombatSlot = nil
			-- Manual off cancels scheduled blacklist resume
			S.blacklistResumeKillAura = false
			S.blacklistResumeAt = 0
			-- Drop sticky hold so next ON re-picks nearest (not last focus)
			if T() and T().clearHold then
				T().clearHold("kill_aura_off")
			end
			stopMove()
			clearPathState()
			S.lastKillAuraPath = nil
			S.ui.setWalkLabel(false)
			U.setStatus("Kill Aura OFF — hold cleared")
			return
		end

		-- Manual on cancels pending auto-resume (user already enabled)
		S.blacklistResumeKillAura = false
		S.blacklistResumeAt = 0
		-- Ensure no stale hold from before stop
		if T() and T().clearHold then
			T().clearHold("kill_aura_on")
		end
		clearPathState()

		M.startWalk(nil)
	end

	return M
end

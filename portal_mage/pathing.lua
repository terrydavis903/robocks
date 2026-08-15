-- portal_mage/pathing.lua — Kill Aura movement
--
-- Strict loop (no teleport, no S, no MoveTo spam):
--   1) Compute A*/PFS path to stand ring (same segments Path Viz draws)
--   2) Face current segment end (soft turn + arrows) until aligned + settle
--   3) Walk W along segment; A/D only on walls; Space+W for height
--   4) Advance waypoint when close; re-face next segment
--   5) Within fightRange → stop; face enemy; combat does R + cast
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
			writefile(logFile, "# portal_mage kill aura v5 face-seg→W|A|D (+Space) stand@30\n# " .. stamp .. "\n")
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

	-- Need jump: ledge/step or enemy much higher
	local function needJumpUp(playerPos: Vector3, epos: Vector3, faceDir: Vector3): boolean
		local dy = epos.Y - playerPos.Y
		if dy >= (C.KILL_AURA_JUMP_DY or 2.8) then
			return true
		end
		-- Step immediately ahead
		local probe = C.KILL_AURA_PROBE or 4
		local origin = playerPos + Vector3.new(0, 0.5, 0) + faceDir * 1.2
		local hit = workspace:Raycast(origin, faceDir * probe + Vector3.new(0, 3, 0), excludeSelf())
		if hit and hit.Normal.Y > 0.5 then
			local stepUp = hit.Position.Y - playerPos.Y
			if stepUp > 1.2 and stepUp < 8 then
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
	-- Face a world point (segment end / enemy). Soft turn only — no hard snap.
	-- Must align before any W/A/D.
	---------------------------------------------------------------------------

	local faceAlign = C.KILL_AURA_FACE_ALIGN or 0.92
	local faceSettle = C.KILL_AURA_FACE_SETTLE or 0.22
	-- Last face decision (for status)
	local lastFaceDot = 0
	local lastYawErr = 0
	local lastTurnName = "-"
	local faceOkSince = 0 -- os.clock when first hit faceAlign; 0 = not aligned

	local function facePoint(target: Vector3): number
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
			updateFaceViz(hrp, target, measuredLook, 0, nil)
			return 1
		end

		-- Measure BEFORE soft correction so viz + turn use true facing
		local dBefore = (U.facingDotTo and U.facingDotTo(target.X, target.Z)) or 0
		local yawErr = (U.yawErrorTo and U.yawErrorTo(target.X, target.Z)) or 0
		local poll = C.SMOOTH_WALK_POLL or 0.06
		local turnRate = C.KILL_AURA_FACE_TURN_RATE or 3.2

		-- 1) Soft HRP yaw toward segment/enemy (slow, no hard snap)
		pcall(function()
			local lookAt = Vector3.new(target.X, pos.Y, target.Z)
			local desired = CFrame.lookAt(pos, lookAt)
			local alpha = 1 - math.exp(-turnRate * poll)
			hrp.CFrame = hrp.CFrame:Lerp(desired, math.clamp(alpha, 0.02, 0.45))
		end)

		-- 2) Camera yaw nudge (game often drives move from camera). Sign matches
		--    inverted Left/Right (math left → negative Y rot for this game).
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
						local cross = flatLook.X * to.Z - flatLook.Z * to.X -- >0 target left of cam
						local dot = flatLook:Dot(to)
						if dot < 0.98 then
							-- Flipped vs math: cross>0 (left) → negative yaw for this game
							local deg = (C.PATH_CAMERA_YAW_DEG or 3.5) * (if cross > 0 then -1 else 1)
							if dot < 0 then
								deg = deg * 1.8
							elseif dot < 0.5 then
								deg = deg * 1.25
							end
							local newLook = (CFrame.Angles(0, math.rad(deg), 0) * Vector3.new(look.X, 0, look.Z))
							if newLook.Magnitude > 0.1 then
								newLook = newLook.Unit
								local aim = Vector3.new(newLook.X, look.Y, newLook.Z)
								cam.CFrame = CFrame.lookAt(cpos, cpos + aim)
							end
						end
					end
				end
			end)
		end

		-- 3) Left/Right arrows from yaw error (pulse). Uses util mapping (inverted for game).
		local d = (U.facingDotTo and U.facingDotTo(target.X, target.Z)) or dBefore
		local turnKey: Enum.KeyCode? = nil
		if d < faceAlign then
			if U.turnKeyToward then
				turnKey = U.turnKeyToward(target.X, target.Z, faceAlign)
			else
				local dead = C.PATH_TURN_YAW_DEADZONE or 0.08
				if math.abs(yawErr) >= dead or d < 0.5 then
					-- Same invert as util.turnKeyToward
					if yawErr > 0 then
						turnKey = Enum.KeyCode.Right
					elseif yawErr < 0 then
						turnKey = Enum.KeyCode.Left
					end
				end
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

		-- Cyan = pre-correction face; green = desired (segment or enemy)
		updateFaceViz(hrp, target, measuredLook, yawErr, turnKey)

		return d
	end

	-- Back-compat name used at stand band
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
	local lastVizKind = ""
	local lastSegLabel = "-"

	local function standGoalNear(playerPos: Vector3, epos: Vector3, range: number): Vector3
		local flat = Vector3.new(playerPos.X - epos.X, 0, playerPos.Z - epos.Z)
		if flat.Magnitude < 0.2 then
			flat = Vector3.new(0, 0, 1)
		else
			flat = flat.Unit
		end
		local dest = epos + flat * range
		local nav = Nav()
		if nav and nav.sampleFloor then
			local s = nav.sampleFloor(dest.X, dest.Z, playerPos.Y, { requireClear = false })
			if s and s.pos then
				return s.pos
			end
		end
		return Vector3.new(dest.X, playerPos.Y, dest.Z)
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
			faceOkSince = 0 -- re-settle face on next segment
		end
		if pathIdx < 1 then
			pathIdx = 1
		end
		if #pathPts > 0 and pathIdx > #pathPts then
			pathIdx = #pathPts
		end
	end

	-- Rebuild path to stand ring. Always used for movement; draws when Path Viz ON.
	local function rebuildPath(playerPos: Vector3, epos: Vector3, enemy: Model, range: number)
		local goal = standGoalNear(playerPos, epos, range)
		local nav = Nav()
		local pts: { Vector3 }
		local kind = "line"
		if nav and nav.computePath then
			pts, kind = nav.computePath(playerPos, goal)
		elseif nav and nav.findPath then
			pts = nav.findPath(playerPos, goal) or { playerPos, goal }
			kind = "grid"
			if S.pathVizEnabled and nav.showPathViz then
				nav.showPathViz(pts, kind)
			end
		else
			pts = { playerPos, goal }
			if S.pathVizEnabled and nav and nav.showPathViz then
				nav.showPathViz(pts, "line")
			end
		end
		if not pts or #pts == 0 then
			pts = { playerPos, goal }
			kind = "line"
		end
		pathPts = pts
		pathEnemy = enemy
		pathBuiltAt = os.clock()
		lastVizKind = kind or "path"
		pathIdx = 1
		advancePathIndex(playerPos)
		if pathIdx < #pathPts and flatDist(playerPos, pathPts[pathIdx]) < 1.0 and pathIdx < #pathPts then
			-- skip near-start duplicate
			pathIdx = math.min(pathIdx + 1, #pathPts)
		end
		faceOkSince = 0
		log(string.format(
			"path %s wps=%d idx=%d goal=(%.1f,%.1f,%.1f) → %s",
			lastVizKind,
			#pathPts,
			pathIdx,
			goal.X,
			goal.Y,
			goal.Z,
			enemy.Name
		))
	end

	local function ensurePath(playerPos: Vector3, epos: Vector3, enemy: Model, range: number, force: boolean?)
		local interval = C.PATH_REBUILD or 4.0
		local need = force == true
			or pathEnemy ~= enemy
			or #pathPts < 2
			or (os.clock() - pathBuiltAt) >= interval
		if not need and pathIdx <= #pathPts then
			-- drifted far from current waypoint → repath
			if flatDist(playerPos, pathPts[pathIdx]) > 36 then
				need = true
			end
		end
		-- Next segment through collide mesh → skip or repath
		if not need and #pathPts >= 2 then
			local nav = Nav()
			if nav and nav.hasClearWalk and pathIdx <= #pathPts then
				if not nav.hasClearWalk(playerPos, pathPts[pathIdx]) then
					if nav.nextClearWaypoint then
						local j = nav.nextClearWaypoint(playerPos, pathPts, pathIdx + 1)
						if j then
							pathIdx = j
							faceOkSince = 0
						else
							need = true
						end
					else
						need = true
					end
				end
			end
		end
		if need then
			rebuildPath(playerPos, epos, enemy, range)
		else
			advancePathIndex(playerPos)
		end
	end

	-- Next world point to face/walk toward (segment end). Final leg → stand ring / enemy.
	local function segmentTarget(playerPos: Vector3, epos: Vector3, range: number): (Vector3, string)
		local distEnemy = flatDist(playerPos, epos)
		if distEnemy <= range + 1.5 then
			return epos, "enemy"
		end
		if #pathPts >= 1 and pathIdx >= 1 and pathIdx <= #pathPts then
			local wp = pathPts[pathIdx]
			-- Last path node is stand ring; if we're on last node, still walk to it
			local label = string.format("seg%d/%d", pathIdx, #pathPts)
			return wp, label
		end
		return standGoalNear(playerPos, epos, range), "stand"
	end

	local function clearPathState()
		pathPts = {}
		pathIdx = 1
		pathEnemy = nil
		pathBuiltAt = 0
		faceOkSince = 0
		lastSegLabel = "-"
	end

	local function clearPathVizIfOff()
		if S.pathVizEnabled then
			return
		end
		local nav = Nav()
		if nav and nav.clearPathViz then
			nav.clearPathViz()
		end
	end

	---------------------------------------------------------------------------
	-- Move: only W, A, or D (exactly one). Optional Space with W.
	---------------------------------------------------------------------------

	local lastSlide: string? = nil -- "A" | "D"
	local lastSlideAt = 0
	local lastPos: Vector3? = nil
	local stuckSince = 0

	local function setMoveKey(which: string?) -- "W"|"A"|"D"|nil
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

	local function approachStep(playerPos: Vector3, epos: Vector3, range: number): string
		local hum = getHum()
		if hum then
			pcall(function()
				hum.AutoRotate = false
				hum.PlatformStand = false
				-- never touch Humanoid.WalkSpeed
			end)
		end

		local dist = flatDist(playerPos, epos)
		local target, segLabel = segmentTarget(playerPos, epos, range)
		lastSegLabel = segLabel
		local faceDot = facePoint(target)

		if dist <= range then
			setMoveKey(nil)
			if U.holdJump then
				U.holdJump(false)
			end
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			faceOkSince = 0
			return "stand"
		end

		-- PHASE 1: turn only until facing current path segment
		if faceDot < faceAlign then
			setMoveKey(nil)
			if U.holdJump then
				U.holdJump(false)
			end
			faceOkSince = 0
			return string.format("face %s d=%.2f", segLabel, faceDot)
		end

		-- PHASE 1b: hold still briefly once aligned so turn settles before W
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
			return string.format("settle %s d=%.2f", segLabel, faceDot)
		end

		-- Facing: stop arrow spam so W is clean
		if U.holdTurnKey then
			U.holdTurnKey(nil)
		end

		-- Walk along segment direction (to next waypoint), not straight at enemy
		local faceDir = Vector3.new(target.X - playerPos.X, 0, target.Z - playerPos.Z)
		if faceDir.Magnitude < 0.2 then
			-- arrived at waypoint mid-tick; advance and re-face next
			advancePathIndex(playerPos)
			setMoveKey(nil)
			if U.holdJump then
				U.holdJump(false)
			end
			return "seg-next"
		end
		faceDir = faceDir.Unit
		local probe = C.KILL_AURA_PROBE or 4.5

		-- Stuck? (pressed move but barely moved) → force slide
		local stuck = false
		if lastPos then
			local moved = flatDist(playerPos, lastPos)
			if moved < 0.35 then
				if stuckSince == 0 then
					stuckSince = os.clock()
				elseif os.clock() - stuckSince > 0.9 then
					stuck = true
				end
			else
				stuckSince = 0
			end
		end
		lastPos = playerPos

		-- Jump when we need height (use enemy height + segment ahead)
		local jump = needJumpUp(playerPos, epos, faceDir) or needJumpUp(playerPos, target, faceDir)
		if U.holdJump then
			U.holdJump(jump)
		end

		local blocked = stuck or wallAhead(playerPos, faceDir, probe)
		if not blocked then
			lastSlide = nil
			setMoveKey("W")
			return string.format("%s %s", if jump then "W+Space" else "W", segLabel)
		end

		-- Corner / wall: pick A or D (not both, never S)
		local right = Vector3.new(-faceDir.Z, 0, faceDir.X).Unit
		local leftBlocked = wallAhead(playerPos, -right, probe)
		local rightBlocked = wallAhead(playerPos, right, probe)
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
		return string.format("turn-%s %s%s", pick, segLabel, jump and "+Space" or "")
	end

	---------------------------------------------------------------------------
	-- Main loop
	---------------------------------------------------------------------------

	local function runWalker()
		logOpen()
		log("walker start v5 face-seg→W|A|D(+Space) stand@30")

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

				if S.waitAllCds then
					if Targets.getHold() then
						Targets.clearHold("wait_cds")
					end
					stopMove()
					U.setStatus(string.format("[cds] holding… | %s", cds()))
					task.wait(0.2)
					return
				end

				if S.combatBusy then
					-- Keep facing but no move keys mid-cast
					if U.holdMoveKeys then
						U.holdMoveKeys(nil)
					end
					if U.holdJump then
						U.holdJump(false)
					end
					task.wait(0.05)
					return
				end

				local playerPos = U.getLivePlayerVector()
				if not playerPos then
					task.wait(0.1)
					return
				end

				local range = Targets.fightRange()
				local sticky = C.KILL_AURA_STICKY or 4
				local model, epos, dist = Targets.ensureEnemy()

				if not model or not epos then
					stopMove()
					clearPathState()
					U.setStatus(string.format("[scan] no enemies ≤%d | %s", Targets.scanRange(), cds()))
					task.wait(0.2)
					return
				end

				if not dist then
					dist = flatDist(playerPos, epos)
				end

				-- A*/PFS path = movement segments (+ Path Viz when ON)
				ensurePath(playerPos, epos, model, range)

				-- Stand band: stop move, face enemy for combat
				if dist <= range + sticky then
					local fd = faceEnemy(epos)
					setMoveKey(nil)
					if U.holdJump then
						U.holdJump(false)
					end
					if U.holdTurnKey then
						U.holdTurnKey(nil)
					end
					local pathInfo = string.format(" %s#%d", lastVizKind, #pathPts)
					U.setStatus(string.format(
						"[stand] d=%.1f face=%.2f yaw=%+.2f turn=%s %s%s | %s",
						dist,
						fd,
						lastYawErr,
						lastTurnName,
						model.Name,
						pathInfo,
						cds()
					))
					task.wait(0.08)
					return
				end

				local tag = approachStep(playerPos, epos, range)
				U.setStatus(string.format(
					"[approach] d=%.1f %s yaw=%+.2f turn=%s → %s %s | %s",
					dist,
					tag,
					lastYawErr,
					lastTurnName,
					model.Name,
					lastVizKind,
					cds()
				))
				if string.find(tag, "face", 1, true) == 1 or string.find(tag, "settle", 1, true) == 1 then
					log(string.format(
						"%s yaw=%+.3f turn=%s enemy=%s dist=%.1f",
						tag,
						lastYawErr,
						lastTurnName,
						model.Name,
						dist
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

	function M.togglePathViz()
		local nav = Nav()
		if nav and nav.togglePathViz then
			nav.togglePathViz()
		else
			S.pathVizEnabled = not S.pathVizEnabled
			if S.ui and S.ui.setPathVizLabel then
				S.ui.setPathVizLabel(S.pathVizEnabled)
			end
			if not S.pathVizEnabled and nav and nav.clearPathViz then
				nav.clearPathViz()
			end
		end
		-- Force path rebuild so viz (and segment index) refresh immediately
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
			if not on and nav and nav.clearPathViz then
				nav.clearPathViz()
			end
		end
		pathBuiltAt = 0
		pathEnemy = nil
	end

	function M.toggleWalk(_opts: any?)
		if S.walking then
			S.walking = false
			S.combatBusy = false
			S.waitAllCds = false
			S.proximityResumeWalk = false
			S.respawnResumeWalk = false
			stopMove()
			S.ui.setWalkLabel(false)
			U.setStatus("Kill Aura stopping…")
			return
		end

		if S.zRegenBusy or S.respawnResumeWalk then
			U.setStatus("Kill Aura blocked — finish respawn first")
			return
		end

		if S.proximityGuardEnabled and S.Proximity then
			local threat, plr, dist = S.Proximity.isThreatNearby()
			if threat and plr and dist then
				U.setStatus(string.format("Kill Aura blocked — %s @ %.0fst", plr.Name, dist))
				return
			end
		end

		if not S.Targets or not S.Combat then
			U.setStatus("Kill Aura failed: Targets/Combat missing — reload")
			return
		end

		if U.isSeated and U.isSeated() then
			U.setStatus("Kill Aura: sitting — Z…")
			if U.ensureStanding then
				U.ensureStanding(3.0)
			end
			if U.isSeated() then
				U.setStatus("Kill Aura blocked — still sitting")
				return
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

		-- Auto Ore owns movement when on — release it for Kill Aura
		if S.autoOreEnabled and S.AutoOre and S.AutoOre.stop then
			S.AutoOre.stop()
		end

		S.holdTarget = nil
		S.combatBusy = false
		S.waitAllCds = false
		S.resourceRecoverPhase = nil
		S.combatPhase = "fight"
		S.walking = true
		S.ui.setWalkLabel(true)
		lastSlide = nil
		lastPos = nil
		stuckSince = 0
		clearPathState()

		U.setStatus(string.format(
			"Kill Aura ON — face segment→W/A/D(+Space)→stand@%d→R/cast",
			T().fightRange()
		))

		S.walkThread = task.spawn(runWalker)
		S.combatThread = task.spawn(S.Combat.runCombat)
	end

	return M
end

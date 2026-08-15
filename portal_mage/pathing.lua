-- portal_mage/pathing.lua — Kill Aura movement
--
-- Strict loop (no teleport, no S, no MoveTo spam):
--   1) Face enemy (←/→ + HRP/camera) until aligned
--   2) Move with only W / A / D (one at a time)
--   3) Corner/wall → switch A/D, re-face, continue
--   4) Need height → Space + W
--   5) Within fightRange → stop; combat does R + cast
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
			writefile(logFile, "# portal_mage kill aura v4 face→W|A|D (+Space) stand@30\n# " .. stamp .. "\n")
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
	-- Face enemy (must succeed before any W/A/D)
	---------------------------------------------------------------------------

	local faceAlign = C.KILL_AURA_FACE_ALIGN or 0.88

	local function faceEnemy(epos: Vector3): number
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
		local flat = Vector3.new(epos.X - pos.X, 0, epos.Z - pos.Z)
		if flat.Magnitude < 0.2 then
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			return 1
		end
		flat = flat.Unit

		-- 1) Hard set character yaw toward enemy every tick (primary)
		pcall(function()
			local lookAt = Vector3.new(epos.X, pos.Y, epos.Z)
			hrp.CFrame = CFrame.lookAt(pos, lookAt)
		end)

		-- 2) Camera yaw toward enemy (many games drive move from camera)
		local cam = workspace.CurrentCamera
		if cam then
			pcall(function()
				local cpos = cam.CFrame.Position
				local look = cam.CFrame.LookVector
				local to = Vector3.new(epos.X - cpos.X, 0, epos.Z - cpos.Z)
				if to.Magnitude > 0.2 then
					to = to.Unit
					local flatLook = Vector3.new(look.X, 0, look.Z)
					if flatLook.Magnitude > 0.1 then
						flatLook = flatLook.Unit
						local cross = flatLook.X * to.Z - flatLook.Z * to.X -- >0 enemy left of cam
						local dot = flatLook:Dot(to)
						if dot < 0.98 then
							local deg = (C.PATH_CAMERA_YAW_DEG or 10) * (if cross > 0 then 1 else -1)
							-- stronger turn when very misaligned
							if dot < 0 then
								deg = deg * 2.2
							elseif dot < 0.5 then
								deg = deg * 1.5
							end
							local cf = cam.CFrame
							local newLook = (CFrame.Angles(0, math.rad(deg), 0) * Vector3.new(look.X, 0, look.Z))
							if newLook.Magnitude > 0.1 then
								newLook = newLook.Unit
								local pitchY = look.Y
								local aim = Vector3.new(newLook.X, pitchY, newLook.Z)
								cam.CFrame = CFrame.lookAt(cpos, cpos + aim)
							end
						end
					end
				end
			end)
		end

		-- 3) Left/Right arrows (pulse every poll)
		local d = (U.facingDotTo and U.facingDotTo(epos.X, epos.Z)) or 0
		if d >= faceAlign then
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			return d
		end
		local turnKey = U.turnKeyToward and U.turnKeyToward(epos.X, epos.Z, faceAlign)
		if U.holdTurnKey then
			U.holdTurnKey(turnKey, true) -- pulse
		end
		return (U.facingDotTo and U.facingDotTo(epos.X, epos.Z)) or 0
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
				if hum.WalkSpeed < 8 and (not U.isSeated or not U.isSeated()) then
					hum.WalkSpeed = C.WALK_SPEED_DEFAULT or 16
				end
			end)
		end

		local dist = flatDist(playerPos, epos)
		local faceDot = faceEnemy(epos)

		if dist <= range then
			setMoveKey(nil)
			if U.holdJump then
				U.holdJump(false)
			end
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			return "stand"
		end

		-- PHASE 1: turn only until facing enemy
		if faceDot < faceAlign then
			setMoveKey(nil)
			if U.holdJump then
				U.holdJump(false)
			end
			return string.format("face d=%.2f", faceDot)
		end

		-- Facing: stop arrow spam so W is clean
		if U.holdTurnKey then
			U.holdTurnKey(nil)
		end

		local faceDir = Vector3.new(epos.X - playerPos.X, 0, epos.Z - playerPos.Z)
		if faceDir.Magnitude < 0.2 then
			setMoveKey(nil)
			if U.holdJump then
				U.holdJump(false)
			end
			return "stand"
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

		-- Jump when we need height
		local jump = needJumpUp(playerPos, epos, faceDir)
		if U.holdJump then
			U.holdJump(jump)
		end

		local blocked = stuck or wallAhead(playerPos, faceDir, probe)
		if not blocked then
			lastSlide = nil
			setMoveKey("W")
			return if jump then "W+Space" else "W"
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
			-- Prefer side that points slightly toward enemy offset
			local toE = faceDir
			local preferD = toE:Dot(right) > 0 -- shouldn't happen when facing; use sticky flip
			pick = if preferD then "D" else "A"
			if lastSlide == pick then
				pick = if pick == "A" then "D" else "A"
			end
		end
		lastSlide = pick
		lastSlideAt = os.clock()
		stuckSince = 0
		setMoveKey(pick)
		return "turn-" .. pick .. (jump and "+Space" or "")
	end

	---------------------------------------------------------------------------
	-- Main loop
	---------------------------------------------------------------------------

	local function runWalker()
		logOpen()
		log("walker start v4 face→W|A|D(+Space) stand@30 no-teleport")

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
					U.setStatus(string.format("[scan] no enemies ≤%d | %s", Targets.scanRange(), cds()))
					task.wait(0.2)
					return
				end

				if not dist then
					dist = flatDist(playerPos, epos)
				end

				-- Stand band: stop move, keep facing for combat
				if dist <= range + sticky then
					local fd = faceEnemy(epos)
					setMoveKey(nil)
					if U.holdJump then
						U.holdJump(false)
					end
					if U.holdTurnKey then
						U.holdTurnKey(nil)
					end
					U.setStatus(string.format(
						"[stand] d=%.1f face=%.2f %s | %s",
						dist,
						fd,
						model.Name,
						cds()
					))
					task.wait(0.08)
					return
				end

				local tag = approachStep(playerPos, epos, range)
				U.setStatus(string.format(
					"[approach] d=%.1f %s → %s | %s",
					dist,
					tag,
					model.Name,
					cds()
				))
				if string.sub(tag, 1, 4) == "face" then
					log(string.format("%s enemy=%s dist=%.1f", tag, model.Name, dist))
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

		U.setStatus(string.format(
			"Kill Aura ON — face→W/A/D(+Space)→stand@%d→R/cast (no TP)",
			T().fightRange()
		))

		S.walkThread = task.spawn(runWalker)
		S.combatThread = task.spawn(S.Combat.runCombat)
	end

	return M
end

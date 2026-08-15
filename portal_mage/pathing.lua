-- portal_mage/pathing.lua — Kill Aura movement (simple face → approach → stand)
--
-- 1) Pick nearest schema enemy
-- 2) Face them with Left/Right arrows (+ HRP/camera yaw assist)
-- 3) Approach facing them: W if clear, else A/D slide around walls (taxicab)
-- 4) Stop within fightRange (30) — combat does R + ability
-- 5) NO kite, NO sticky path lock, NO A* follow legs
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
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
	-- Kill-aura path log
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
			writefile(logFile, "# portal_mage kill aura (face→W/A/D→stand@30)\n# " .. stamp .. "\n")
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
		if U.releaseTurnKeys then
			U.releaseTurnKeys()
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

	local function prepHum()
		local hum = getHum()
		if hum then
			pcall(function()
				hum.PlatformStand = false
				hum.AutoRotate = false -- we own yaw via arrows / face
				if not U.isSeated or not U.isSeated() then
					if hum.WalkSpeed < 8 then
						hum.WalkSpeed = C.WALK_SPEED_DEFAULT or 16
					end
				end
			end)
		end
		return hum
	end

	---------------------------------------------------------------------------
	-- Facing + taxicab approach (always face the enemy)
	---------------------------------------------------------------------------

	local lastSlide: string? = nil -- "A" | "D" sticky while wall-blocked
	local lastSlideAt = 0
	local alignDot = C.PATH_WALK_ALIGN_DOT or 0.72
	local faceAlign = C.KILL_AURA_FACE_ALIGN or 0.85 -- stricter face before W

	-- Yaw character toward enemy: CFrame + camera nudge + Left/Right arrows.
	-- Returns facingDot (1 = looking at enemy).
	local function faceEnemy(epos: Vector3, dt: number?): number
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
		local look = Vector3.new(epos.X, pos.Y, epos.Z)
		local flat = Vector3.new(epos.X - pos.X, 0, epos.Z - pos.Z)
		if flat.Magnitude < 0.15 then
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			return 1
		end

		-- 1) HRP CFrame toward enemy
		local desired = CFrame.lookAt(pos, look)
		local d = U.facingDotTo and U.facingDotTo(epos.X, epos.Z) or 0
		local snap = (d ~= nil and d < 0.2)
		pcall(function()
			if snap then
				hrp.CFrame = desired
			else
				local rate = C.PATH_WALK_TURN_RATE or 18
				local alpha = 1 - math.exp(-rate * math.max(dt or 0.05, 0.016))
				hrp.CFrame = hrp.CFrame:Lerp(desired, math.clamp(alpha, 0.2, 1))
			end
		end)

		-- 2) Camera yaw nudge (character often follows camera in this game)
		local yawErr = U.yawErrorTo and U.yawErrorTo(epos.X, epos.Z)
		local cam = workspace.CurrentCamera
		if cam and yawErr and math.abs(yawErr) > (C.PATH_TURN_YAW_DEADZONE or 0.08) then
			local deg = (C.PATH_CAMERA_YAW_DEG or 6) * (if yawErr > 0 then 1 else -1)
			-- yawErr > 0 = enemy left of look → rotate camera left (positive Y in Roblox)
			pcall(function()
				local cf = cam.CFrame
				cam.CFrame = CFrame.new(cf.Position) * CFrame.Angles(0, math.rad(deg), 0) * (cf - cf.Position)
			end)
		end

		-- 3) Left/Right arrows (hold + edge re-press so games that ignore hold still turn)
		d = U.facingDotTo and U.facingDotTo(epos.X, epos.Z) or 0
		local need = faceAlign
		if d ~= nil and d >= need then
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			return d
		end

		local turnKey = U.turnKeyToward and U.turnKeyToward(epos.X, epos.Z, need)
		if U.holdTurnKey then
			U.holdTurnKey(turnKey)
		end
		-- Pulse: brief re-down each poll (some clients only turn on edge)
		if turnKey and C.PATH_TURN_PULSE ~= false and U.pressKey then
			-- short tap without full release of hold: send down again
			pcall(function()
				local VIM = S.Services.VirtualInputManager
				VIM:SendKeyEvent(true, turnKey, true, game) -- isRepeated=true
			end)
		end

		return U.facingDotTo and U.facingDotTo(epos.X, epos.Z) or 0
	end

	local function forwardClear(from: Vector3, toward: Vector3, probe: number): boolean
		local flat = Vector3.new(toward.X - from.X, 0, toward.Z - from.Z)
		if flat.Magnitude < 0.2 then
			return true
		end
		local dir = flat.Unit
		local dest = from + dir * probe
		local nav = Nav()
		if nav and nav.hasClearWalk then
			return nav.hasClearWalk(from, dest) == true
		end
		-- Raycast fallback
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local lp = Players.LocalPlayer
		local excl = {}
		if lp and lp.Character then
			table.insert(excl, lp.Character)
		end
		params.FilterDescendantsInstances = excl
		local hit = workspace:Raycast(from + Vector3.new(0, 2, 0), dir * probe, params)
		if not hit then
			return true
		end
		-- Floor-ish hit is OK; wall normals are mostly horizontal
		local n = hit.Normal
		return n.Y > 0.55
	end

	local function sideClear(from: Vector3, faceDir: Vector3, side: number, probe: number): boolean
		-- side +1 = right of facing, -1 = left
		local right = Vector3.new(-faceDir.Z, 0, faceDir.X)
		if right.Magnitude < 1e-4 then
			return false
		end
		right = right.Unit * side
		local dest = from + right * probe
		local nav = Nav()
		if nav and nav.hasClearWalk then
			return nav.hasClearWalk(from, dest) == true
		end
		return true
	end

	-- One approach step: face enemy, then W or A/D. Returns status tag.
	local function approachStep(playerPos: Vector3, epos: Vector3, range: number): string
		prepHum()
		local dist = flatDist(playerPos, epos)
		local dt = C.SMOOTH_WALK_POLL or 0.08

		-- Always face the enemy first
		local d = faceEnemy(epos, dt)

		if dist <= range then
			if U.holdMoveKeys then
				U.holdMoveKeys(nil)
			end
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			return "stand"
		end

		-- Not facing yet → pivot only (arrows), no W
		if d < faceAlign then
			if U.holdMoveKeys then
				U.holdMoveKeys(nil)
			end
			return string.format("face d=%.2f", d)
		end

		-- Facing: W if forward clear, else A/D slide (taxicab around walls)
		local faceDir = Vector3.new(epos.X - playerPos.X, 0, epos.Z - playerPos.Z)
		if faceDir.Magnitude < 0.2 then
			if U.holdMoveKeys then
				U.holdMoveKeys(nil)
			end
			return "stand"
		end
		faceDir = faceDir.Unit
		local probe = C.KILL_AURA_PROBE or 5

		if forwardClear(playerPos, epos, probe) then
			lastSlide = nil
			if U.holdMoveKeys then
				U.holdMoveKeys({ Enum.KeyCode.W })
			end
			-- Keep a light face hold via arrows if drift
			return "W"
		end

		-- Wall ahead → strafe A or D (relative to face = enemy)
		local leftOk = sideClear(playerPos, faceDir, -1, probe)
		local rightOk = sideClear(playerPos, faceDir, 1, probe)
		local pick: string? = nil
		if leftOk and not rightOk then
			pick = "A"
		elseif rightOk and not leftOk then
			pick = "D"
		elseif leftOk and rightOk then
			-- Prefer continuing last slide; else alternate by which side is freer longer
			if lastSlide and (os.clock() - lastSlideAt) < 1.2 then
				pick = lastSlide
			else
				pick = if (os.clock() * 3) % 2 < 1 then "A" else "D"
			end
		else
			-- both blocked: try reverse of last or random
			pick = if lastSlide == "A" then "D" else "A"
		end

		lastSlide = pick
		lastSlideAt = os.clock()
		if U.holdMoveKeys then
			if pick == "A" then
				U.holdMoveKeys({ Enum.KeyCode.A })
			else
				U.holdMoveKeys({ Enum.KeyCode.D })
			end
		end
		return "slide-" .. tostring(pick)
	end

	---------------------------------------------------------------------------
	-- Main loop
	---------------------------------------------------------------------------

	local function runWalker()
		logOpen()
		log("walker start (face→W/A/D→stand@30, no kite)")

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
							U.setStatus("[path] sitting — Z to stand")
							if U.ensureStanding then
								U.ensureStanding(2.5)
							end
						elseif why == "sheathed" or why == "no_weapon" then
							U.setStatus("[path] sheathed — force Q")
							if U.markWeaponSheathed then
								U.markWeaponSheathed()
							end
							if U.ensureWeaponDrawn then
								U.ensureWeaponDrawn(1.2, true)
							end
						elseif why == "dead" then
							U.setStatus("[path] dead — wait respawn")
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
					if U.releaseMoveKeys then
						U.releaseMoveKeys()
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

				-- In range (including too close): stop + face. No kite.
				if dist <= range + sticky then
					prepHum()
					faceEnemy(epos, 0.05)
					if U.holdMoveKeys then
						U.holdMoveKeys(nil)
					end
					if U.holdTurnKey then
						U.holdTurnKey(nil)
					end
					U.setStatus(string.format("[stand] d=%.1f face enemy %s | %s", dist, model.Name, cds()))
					task.wait(0.08)
					return
				end

				-- Approach: face, then W / A / D
				local tag = approachStep(playerPos, epos, range)
				U.setStatus(string.format(
					"[approach] d=%.1f %s → %s | %s",
					dist,
					tag,
					model.Name,
					cds()
				))
				if string.find(tag, "face", 1, true) == 1 then
					log(string.format("face %s d=%.1f", model.Name, dist))
				end
				task.wait(C.SMOOTH_WALK_POLL or 0.08)
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
			U.setStatus("Kill Aura: sitting — Z to stand…")
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

		U.setStatus(string.format(
			"Kill Aura ON — face→W/A/D→stand@%d → R/cast | no kite",
			T().fightRange()
		))

		S.walkThread = task.spawn(runWalker)
		S.combatThread = task.spawn(S.Combat.runCombat)
	end

	return M
end

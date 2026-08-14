-- portal_mage/pathing.lua — Kill Aura movement (reimagined)
--
-- 1) Pick nearest schema enemy
-- 2) Stand goal at fightRange (30)
-- 3) Compute path ONCE (PathfindingService → grid fallback → line)
-- 4) Stick to that path until stand / new enemy / stuck 2s
-- 5) Path Viz draws every computed path when toggle is ON
-- 6) Kite: fast direct steps, no path recompute spam
return function(S)
	local C = S.Config
	local U = S.Util
	local HttpService = S.Services.HttpService
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

	---------------------------------------------------------------------------
	-- Kill-aura path log (dumps/killaura_*.log) — so we can see why no path
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
			writefile(logFile, "# portal_mage kill aura path log\n# " .. stamp .. "\n")
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
				-- Don't clear Sit — recover sit is intentional (Z). Just stop motion.
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
				-- Do NOT force Sit=false — Z-recover sit is real state (dumps: WalkSpeed=0).
				-- Standing is done via Z toggle in util.ensureStanding.
				hum.PlatformStand = false
				hum.AutoRotate = true
				if not U.isSeated or not U.isSeated() then
					if hum.WalkSpeed < 8 then
						hum.WalkSpeed = C.WALK_SPEED_DEFAULT or 16
					end
				end
			end)
		end
		return hum
	end

	local function sampleFeet(x: number, z: number, yHint: number): Vector3
		local nav = Nav()
		if nav and nav.sampleFloor then
			local s = nav.sampleFloor(x, z, yHint, { requireClear = false })
			if s then
				return s.pos
			end
		end
		return Vector3.new(x, yHint, z)
	end

	---------------------------------------------------------------------------
	-- Locked path state
	---------------------------------------------------------------------------

	local lockEnemy: Model? = nil
	local lockGoal: Vector3? = nil
	local lockPath: { Vector3 }? = nil
	local lockKind = ""
	local lockWp = 1
	local lockStuckAt = 0
	local lockStuckPos: Vector3? = nil

	local function clearLock()
		lockEnemy = nil
		lockGoal = nil
		lockPath = nil
		lockKind = ""
		lockWp = 1
		lockStuckAt = 0
		lockStuckPos = nil
	end

	local function fleeGoal(playerPos: Vector3, enemyPos: Vector3, range: number): Vector3
		local nav = Nav()
		local away = Vector3.new(playerPos.X - enemyPos.X, 0, playerPos.Z - enemyPos.Z)
		if away.Magnitude < 0.25 then
			away = Vector3.new(1, 0, 0)
		else
			away = away.Unit
		end
		local dist = flatDist(playerPos, enemyPos)
		local need = math.clamp(range - dist + 6, 6, 18)
		local angles = { 0, 35, -35, 70, -70, 110, -110 }
		for _, deg in ipairs(angles) do
			local rad = math.rad(deg)
			local c, s = math.cos(rad), math.sin(rad)
			local dir = Vector3.new(away.X * c - away.Z * s, 0, away.X * s + away.Z * c).Unit
			local ring = enemyPos + dir * range
			local dest = playerPos + dir * need
			local candidate = if flatDist(playerPos, ring) < need * 1.6 then ring else dest
			local feet = sampleFeet(candidate.X, candidate.Z, playerPos.Y)
			if not nav or not nav.hasClearWalk or nav.hasClearWalk(playerPos, feet) then
				return feet
			end
		end
		return sampleFeet(playerPos.X + away.X * need, playerPos.Z + away.Z * need, playerPos.Y)
	end

	local function approachStandGoal(playerPos: Vector3, enemyPos: Vector3, range: number): Vector3
		local nav = Nav()
		if nav and nav.standPointNear then
			local g = nav.standPointNear(enemyPos, range, {
				from = playerPos,
				sticky = 0,
				minDist = range * 0.85,
				samples = 12,
			})
			if g then
				return g
			end
		end
		local flat = Vector3.new(playerPos.X - enemyPos.X, 0, playerPos.Z - enemyPos.Z)
		if flat.Magnitude < 0.2 then
			flat = Vector3.new(0, 0, 1)
		else
			flat = flat.Unit
		end
		local dest = enemyPos + flat * range
		return sampleFeet(dest.X, dest.Z, playerPos.Y)
	end

	local function lockPathTo(playerPos: Vector3, goal: Vector3, enemy: Model)
		local nav = Nav()
		lockEnemy = enemy
		lockGoal = goal
		lockWp = 1
		lockStuckAt = 0
		lockStuckPos = nil

		local path: { Vector3 }
		local kind = "line"
		if nav and nav.computePath then
			path, kind = nav.computePath(playerPos, goal)
		elseif nav and nav.findPath then
			path = nav.findPath(playerPos, goal) or { goal }
			kind = "grid"
			if nav.showPathViz and S.pathVizEnabled then
				nav.showPathViz(path, kind)
			end
		else
			path = { goal }
			if nav and nav.showPathViz and S.pathVizEnabled then
				nav.showPathViz({ playerPos, goal }, "line")
			end
		end
		lockPath = path
		lockKind = kind
		log(string.format(
			"LOCK path kind=%s wps=%d goal=(%.1f,%.1f,%.1f) enemy=%s",
			kind,
			#path,
			goal.X,
			goal.Y,
			goal.Z,
			enemy.Name
		))
		U.setStatus(string.format(
			"[path] LOCK %s %d wp → %s",
			kind,
			#path,
			enemy.Name
		))
	end

	-- Face-lock (reticle-relative WASD) only when reticle is ON the target.
	-- Otherwise A* / approach rotates along the path (no lookAt).
	local function combatLookAt(model: Model?, epos: Vector3?): any?
		if not model or not epos then
			return nil
		end
		local Targets = T()
		if Targets and Targets.hasReticleOn and Targets.hasReticleOn(model) then
			return { x = epos.X, y = epos.Y, z = epos.Z }
		end
		return nil
	end

	-- Walk next segment of locked path only (no recompute).
	-- lookAtTbl: reticle face lock, or nil → rotate toward waypoint.
	local function followLockedPath(lookAtTbl: any?)
		local path = lockPath
		local goal = lockGoal
		if not path or #path == 0 or not goal then
			return
		end
		local playerPos = U.getLivePlayerVector()
		if not playerPos then
			return
		end
		local arrive = C.NAV_ARRIVE_STUDS or 2.5

		-- Advance past nearby waypoints
		while lockWp <= #path and flatDist(playerPos, path[lockWp]) <= arrive do
			lockWp += 1
		end

		local target: Vector3
		if lockWp > #path then
			target = goal
		else
			target = path[lockWp]
		end

		prepHum()
		-- Single short leg toward current waypoint
		U.walkTo(target.X, target.Y, target.Z, {
			silent = true,
			lookAt = lookAtTbl, -- nil = path-follow rotate + W
			requireWalking = true,
			snapOnTimeout = false,
			useMoveKeys = true,
			timeout = 2.0,
			arriveStuds = arrive,
		})
	end

	local function walkDirect(goal: Vector3, lookAtTbl: any?, timeout: number)
		prepHum()
		if S.pathVizEnabled and Nav() and Nav().showPathViz then
			local p = U.getLivePlayerVector()
			if p then
				Nav().showPathViz({ p, goal }, "kite")
			end
		end
		U.walkTo(goal.X, goal.Y, goal.Z, {
			silent = true,
			lookAt = lookAtTbl,
			requireWalking = true,
			snapOnTimeout = false,
			useMoveKeys = true,
			timeout = timeout,
		})
	end

	local function runWalker()
		if not Nav() then
			S.walking = false
			S.ui.setWalkLabel(false)
			U.setStatus("Kill Aura failed: Nav missing")
			return
		end

		logOpen()
		log("walker start")

		while S.walking do
			local ok, err = pcall(function()
				local Targets = T()
				if not Targets then
					task.wait(0.2)
					return
				end

				-- Respawn Z-loop / mana sit-recover: hard stop (no MoveTo while seated)
				if S.resourceRecoverPhase == "regen" or S.zRegenBusy then
					stopMove()
					clearLock()
					U.setStatus("[path] paused — recover (Z loop)")
					task.wait(0.15)
					return
				end

				-- Sit / dead / sheathed: fix via Z/Q state toggles (never path until ready)
				if U.killAuraBlocked then
					local blocked, why = U.killAuraBlocked()
					if blocked then
						stopMove()
						clearLock()
						if why == "sitting" then
							U.setStatus("[path] sitting — Z to stand")
							if U.ensureStanding then
								U.ensureStanding(2.5)
							end
							task.wait(0.15)
							return
						elseif why == "sheathed" or why == "no_weapon" then
							U.setStatus("[path] weapon sheathed — Q to draw")
							if U.ensureWeaponDrawn then
								U.ensureWeaponDrawn(1.2)
							elseif U.ensureWeaponEquipped then
								U.ensureWeaponEquipped()
							end
							task.wait(0.15)
							return
						elseif why == "dead" then
							U.setStatus("[path] dead — wait respawn")
							task.wait(0.25)
							return
						else
							U.setStatus(string.format("[path] paused (%s)", tostring(why)))
							task.wait(0.15)
							return
						end
					end
				end

				if S.waitAllCds then
					if Targets.getHold() then
						Targets.clearHold("wait_cds")
					end
					stopMove()
					clearLock()
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
				local sticky = C.KILL_AURA_STICKY or 5
				local model, epos, dist = Targets.ensureEnemy()

				if not model or not epos then
					stopMove()
					clearLock()
					U.setStatus(string.format("[scan] no enemies ≤%d | %s", Targets.scanRange(), cds()))
					task.wait(0.2)
					return
				end

				if not dist then
					dist = flatDist(playerPos, epos)
				end

				-- Face lock only with reticle on target; else rotate along path
				local faceLock = combatLookAt(model, epos)

				-- KITE (close): fast, no path lock — keep face lock if reticle on
				if dist < range - sticky then
					if lockPath then
						log("clear lock → kite d=" .. string.format("%.1f", dist))
					end
					clearLock()
					local goal = fleeGoal(playerPos, epos, range)
					U.setStatus(string.format(
						"[kite] d=%.1f →@%d %s face=%s | %s",
						dist,
						range,
						model.Name,
						faceLock and "reticle" or "path",
						cds()
					))
					walkDirect(goal, faceLock, 0.85)
					return
				end

				-- STAND (in band)
				if dist <= range + sticky then
					if lockPath then
						log(string.format("arrived stand d=%.1f cleared lock", dist))
					end
					stopMove()
					clearLock()
					U.setStatus(string.format("[stand] d=%.1f %s | %s", dist, model.Name, cds()))
					task.wait(0.1)
					return
				end

				-- APPROACH: lock once, stick
				local needLock = lockEnemy ~= model or not lockPath or not lockGoal
				if lockPath and lockEnemy == model then
					if lockStuckPos and flatDist(playerPos, lockStuckPos) < 1.4 then
						if lockStuckAt == 0 then
							lockStuckAt = os.clock()
						elseif os.clock() - lockStuckAt > 2.2 then
							log("stuck 2.2s → re-lock path")
							needLock = true
							lockStuckAt = 0
							lockStuckPos = nil
						end
					else
						lockStuckPos = playerPos
						lockStuckAt = os.clock()
					end
				end

				if needLock then
					local goal = approachStandGoal(playerPos, epos, range)
					lockPathTo(playerPos, goal, model)
				end

				U.setStatus(string.format(
					"[approach] d=%.1f %s %d/%d wp %s face=%s | %s",
					dist,
					lockKind,
					math.min(lockWp, lockPath and #lockPath or 0),
					lockPath and #lockPath or 0,
					model.Name,
					faceLock and "reticle" or "path",
					cds()
				))
				followLockedPath(faceLock)
			end)

			if not ok then
				stopMove()
				clearLock()
				log("ERROR " .. tostring(err))
				U.setStatus("Path error: " .. tostring(err))
				task.wait(0.4)
			end
		end

		stopMove()
		clearLock()
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
		-- Re-draw current lock if any
		if S.pathVizEnabled and lockPath and Nav() and Nav().showPathViz then
			Nav().showPathViz(lockPath, lockKind or "locked")
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
			clearLock()
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

		if not S.Nav or not S.Targets or not S.Combat then
			U.setStatus("Kill Aura failed: Nav/Targets/Combat missing — reload")
			return
		end

		-- Require observed fight stance: standing + weapon drawn
		if U.isSeated and U.isSeated() then
			U.setStatus("Kill Aura: sitting — Z to stand…")
			if U.ensureStanding then
				U.ensureStanding(3.0)
			end
			if U.isSeated() then
				U.setStatus("Kill Aura blocked — still sitting (press Z / finish recover)")
				return
			end
		end
		-- Only force-Q when we know sheathed (post-sit). Soft default is drawn.
		if S.weaponDrawnKnown == false or (U.isWeaponDrawn and not U.isWeaponDrawn()) then
			U.setStatus("Kill Aura: unsheath (Q)…")
			if U.markWeaponSheathed and S.weaponDrawnKnown ~= false then
				-- leave known as-is
			end
			if U.ensureWeaponDrawn then
				U.ensureWeaponDrawn(1.5)
			end
			if U.isWeaponDrawn and not U.isWeaponDrawn() then
				U.setStatus("Kill Aura blocked — still sheathed after Q")
				return
			end
		end

		clearLock()
		S.holdTarget = nil
		S.combatBusy = false
		S.waitAllCds = false
		S.resourceRecoverPhase = nil
		S.combatPhase = "fight"
		S.walking = true
		S.ui.setWalkLabel(true)

		U.setStatus(string.format(
			"Kill Aura ON — stand@%d | weapon ready | dumps/killaura_*.log",
			T().fightRange()
		))

		S.walkThread = task.spawn(runWalker)
		S.combatThread = task.spawn(S.Combat.runCombat)
	end

	return M
end

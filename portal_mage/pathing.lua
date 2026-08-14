-- portal_mage/pathing.lua — Kill Aura movement
--
-- Kite: FAST (no A*). Approach: A* once then STICK to that path until done.
-- Path Viz (toggle): cyan/amber lines when A* runs.
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

	local function stopMove()
		if U.releaseMoveKeys then
			U.releaseMoveKeys()
		end
		local hum = getHum()
		if hum then
			pcall(function()
				hum.Sit = false
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
				hum.Sit = false
				hum.PlatformStand = false
				hum.AutoRotate = true
				if hum.WalkSpeed < 8 then
					hum.WalkSpeed = C.WALK_SPEED_DEFAULT or 16
				end
			end)
		end
		return hum
	end

	local function sampleFeet(x: number, z: number, yHint: number): Vector3?
		local nav = Nav()
		if not nav or not nav.sampleFloor then
			return Vector3.new(x, yHint, z)
		end
		local s = nav.sampleFloor(x, z, yHint, { requireClear = false })
		return if s then s.pos else Vector3.new(x, yHint, z)
	end

	---------------------------------------------------------------------------
	-- Locked approach path (compute once, follow until clear)
	---------------------------------------------------------------------------

	local lockEnemy: Model? = nil
	local lockGoal: Vector3? = nil
	local lockPath: { Vector3 }? = nil
	local lockBuiltAt = 0
	local lockStuckAt = 0
	local lockStuckPos: Vector3? = nil

	local function clearLock()
		lockEnemy = nil
		lockGoal = nil
		lockPath = nil
		lockBuiltAt = 0
		lockStuckAt = 0
		lockStuckPos = nil
		-- Keep last path drawn while Path Viz is ON (debug); clear when OFF
		if not S.pathVizEnabled then
			local nav = Nav()
			if nav and nav.clearPathViz then
				nav.clearPathViz()
			end
		end
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

		local function tryDir(dir: Vector3): Vector3?
			local dest = playerPos + dir * need
			local ring = enemyPos + dir * range
			local candidate = if flatDist(playerPos, ring) < need * 1.5 then ring else dest
			local feet = sampleFeet(candidate.X, candidate.Z, playerPos.Y)
			if not feet then
				return nil
			end
			if nav and nav.hasClearWalk and not nav.hasClearWalk(playerPos, feet) then
				return nil
			end
			return feet
		end

		local angles = { 0, 30, -30, 60, -60, 90, -90, 135, -135 }
		for _, deg in ipairs(angles) do
			local rad = math.rad(deg)
			local c, s = math.cos(rad), math.sin(rad)
			local dir = Vector3.new(away.X * c - away.Z * s, 0, away.X * s + away.Z * c)
			if dir.Magnitude > 0.1 then
				dir = dir.Unit
				local g = tryDir(dir)
				if g then
					return g
				end
			end
		end
		return sampleFeet(playerPos.X + away.X * need, playerPos.Z + away.Z * need, playerPos.Y)
			or (playerPos + away * need)
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
		return sampleFeet(dest.X, dest.Z, playerPos.Y) or Vector3.new(dest.X, playerPos.Y, dest.Z)
	end

	-- Build A* path once for this enemy/goal and lock it.
	local function lockApproachPath(playerPos: Vector3, goal: Vector3, enemy: Model)
		local nav = Nav()
		lockEnemy = enemy
		lockGoal = goal
		lockBuiltAt = os.clock()
		lockStuckAt = 0
		lockStuckPos = nil

		local path: { Vector3 }?
		if nav and nav.hasClearWalk and nav.hasClearWalk(playerPos, goal) and flatDist(playerPos, goal) <= 18 then
			path = { goal }
			if nav.showPathViz and S.pathVizEnabled then
				nav.showPathViz({ playerPos, goal }, "direct")
			end
		elseif nav and nav.findPath then
			path = nav.findPath(playerPos, goal)
			if path and #path > 0 then
				if nav.showPathViz and S.pathVizEnabled then
					nav.showPathViz(path, "astar")
				end
			else
				path = { goal }
				if nav.showPathViz and S.pathVizEnabled then
					nav.showPathViz({ playerPos, goal }, "fallback")
				end
			end
		else
			path = { goal }
		end
		lockPath = path
	end

	local function walkLockedPath(lookAt: Vector3, timeout: number)
		local nav = Nav()
		local goal = lockGoal
		local path = lockPath
		if not goal or not path or #path == 0 then
			return
		end
		prepHum()
		if nav and nav.goTo then
			nav.goTo(goal, {
				requireWalking = true,
				lookAt = { x = lookAt.X, y = lookAt.Y, z = lookAt.Z },
				snapOnTimeout = false,
				useMoveKeys = true,
				timeout = timeout,
				arriveStuds = C.NAV_ARRIVE_STUDS or 2.5,
				lockedPath = path, -- do not recompute A*
			})
		else
			U.walkTo(goal.X, goal.Y, goal.Z, {
				silent = true,
				lookAt = { x = lookAt.X, y = lookAt.Y, z = lookAt.Z },
				requireWalking = true,
				snapOnTimeout = false,
				useMoveKeys = true,
				timeout = timeout,
			})
		end
	end

	local function walkDirect(goal: Vector3, lookAt: Vector3, timeout: number)
		local nav = Nav()
		prepHum()
		if nav and nav.goTo then
			nav.goTo(goal, {
				requireWalking = true,
				lookAt = { x = lookAt.X, y = lookAt.Y, z = lookAt.Z },
				snapOnTimeout = false,
				useMoveKeys = true,
				timeout = timeout,
				forceDirect = true,
			})
		else
			U.walkTo(goal.X, goal.Y, goal.Z, {
				silent = true,
				lookAt = { x = lookAt.X, y = lookAt.Y, z = lookAt.Z },
				requireWalking = true,
				snapOnTimeout = false,
				useMoveKeys = true,
				timeout = timeout,
			})
		end
	end

	local function runWalker()
		if not Nav() then
			S.walking = false
			S.ui.setWalkLabel(false)
			U.setStatus("Kill Aura failed: Nav missing")
			return
		end

		while S.walking do
			local ok, err = pcall(function()
				local Targets = T()
				if not Targets then
					task.wait(0.2)
					return
				end

				if S.resourceRecoverPhase == "regen" or S.zRegenBusy then
					stopMove()
					clearLock()
					task.wait(0.15)
					return
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

				-------------------------------------------------------------------
				-- TOO CLOSE → FAST kite (never A*, clear approach lock)
				-------------------------------------------------------------------
				if dist < range - sticky then
					clearLock()
					local goal = fleeGoal(playerPos, epos, range)
					U.setStatus(string.format(
						"[kite] d=%.1f →@%d %s FAST | %s",
						dist,
						range,
						model.Name,
						cds()
					))
					walkDirect(goal, epos, 0.85)
					return
				end

				-------------------------------------------------------------------
				-- IN BAND → stop + clear path lock (arrived)
				-------------------------------------------------------------------
				if dist <= range + sticky then
					stopMove()
					clearLock()
					U.setStatus(string.format("[stand] d=%.1f %s | %s", dist, model.Name, cds()))
					task.wait(0.1)
					return
				end

				-------------------------------------------------------------------
				-- APPROACH: lock A* path once, stick until stand / new enemy / stuck
				-------------------------------------------------------------------
				local needNewLock = lockEnemy ~= model
					or not lockPath
					or not lockGoal

				-- Stuck: same place > 2s while locked → allow ONE recompute
				if lockPath and lockEnemy == model then
					if lockStuckPos and flatDist(playerPos, lockStuckPos) < 1.5 then
						if lockStuckAt == 0 then
							lockStuckAt = os.clock()
						elseif os.clock() - lockStuckAt > 2.0 then
							needNewLock = true
							lockStuckAt = 0
							lockStuckPos = nil
						end
					else
						lockStuckPos = playerPos
						lockStuckAt = os.clock()
					end
				end

				if needNewLock then
					local goal = approachStandGoal(playerPos, epos, range)
					U.setStatus(string.format(
						"[approach] d=%.1f lock A* →@%d %s | %s",
						dist,
						range,
						model.Name,
						cds()
					))
					lockApproachPath(playerPos, goal, model)
				else
					U.setStatus(string.format(
						"[approach] d=%.1f follow locked path (%d wp) %s | %s",
						dist,
						lockPath and #lockPath or 0,
						model.Name,
						cds()
					))
				end

				-- Follow locked path (nav.goTo will NOT re-A*)
				walkLockedPath(epos, 3.5)
			end)

			if not ok then
				stopMove()
				clearLock()
				U.setStatus("Path error: " .. tostring(err))
				task.wait(0.4)
			end
		end

		stopMove()
		clearLock()
		S.walking = false
		S.combatBusy = false
		S.ui.setWalkLabel(false)
		U.setStatus("Kill Aura stopped")
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

		clearLock()
		S.holdTarget = nil
		S.combatBusy = false
		S.waitAllCds = false
		S.resourceRecoverPhase = nil
		S.combatPhase = "fight"
		S.walking = true
		S.ui.setWalkLabel(true)

		U.setStatus(string.format(
			"Kill Aura ON — lock A* once, stand@%d, FAST kite | Path Viz optional",
			T().fightRange()
		))

		S.walkThread = task.spawn(runWalker)
		S.combatThread = task.spawn(S.Combat.runCombat)
	end

	return M
end

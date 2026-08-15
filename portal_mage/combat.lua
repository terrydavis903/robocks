-- portal_mage/combat.lua — ability half of Kill Aura
--
-- Loop (with pathing.lua):
--   hold = living enemy (pathing picks closest by path)
--   when dist ≈ 30 and reticle on hold and handler exists → cast schema
--   enemy dies → clear hold → pathing picks next → reloop
--   we die → respawn module resumes Kill Aura → reloop
--
-- Never cast without reticle. Never freefire. No special boss branches.
return function(S)
	local C = S.Config
	local U = S.Util
	local M = {}

	local function T()
		return S.Targets
	end

	local function A()
		return S.Abilities
	end

	---------------------------------------------------------------------------
	-- Public surface (ui / pathing / compat)
	---------------------------------------------------------------------------

	function M.stopAll()
		S.walking = false
		S.combatBusy = false
		S.waitAllCds = false
		S.proximityResumeWalk = false
		S.respawnResumeWalk = false
		S.resourceRecoverPhase = nil
		if T() then
			T().clearHold("stop")
		end
		if U.releaseMoveKeys then
			U.releaseMoveKeys()
		end
		if S.ui and S.ui.setWalkLabel then
			S.ui.setWalkLabel(false)
		end
	end

	function M.listActiveMobs()
		return T().listActive()
	end
	function M.isModelAlive(m)
		return T().isAlive(m)
	end
	function M.isMobAggro(m)
		return T().isAggro(m)
	end
	function M.distToModel(m, from)
		return T().dist(m, from)
	end
	function M.listAggroMobs(r)
		return T().listAggro(r)
	end
	function M.getClosestAggroMob(from, r)
		return T().closestAggro(from, r)
	end
	function M.getClosestMob(from, r, _)
		return T().closest(from, r)
	end
	function M.getClosestCombatMob(from, r)
		local origin = from or U.getLivePlayerVector()
		local model = select(1, T().pickEnemy(origin, true))
		return model
	end
	function M.getHoldTarget()
		return T().getHold()
	end
	function M.setHoldTarget(m, why)
		T().setHold(m, why)
	end
	function M.clearHoldTarget(why)
		T().clearHold(why)
	end
	function M.getReticleTargetModel()
		return T().getReticle()
	end
	function M.reticleLocksModel(h, r)
		return T().reticleOn(h, r)
	end
	function M.hasReticleOn(m)
		return T().hasReticleOn(m)
	end
	function M.killAuraPriority(m)
		return T().killAuraPriority(m)
	end
	function M.formatHandlerCds(now)
		return A().formatHandlerCds(now)
	end
	function M.findHandlerForModel(m)
		return A().findHandler(m)
	end
	function M.resolveHandlerForModel(m, def)
		return A().resolve(m, def)
	end
	function M.isHandlerReady(h)
		return A().isHandlerReady(h)
	end
	function M.isSlotDiamondFilled(s)
		return A().isSlotOn(s)
	end
	function M.getSlotCooldownRemaining(s)
		return A().getCooldownRemaining(s)
	end

	---------------------------------------------------------------------------
	-- Low mana: pause casts; wait until nearby reds clear, then Z-recover
	---------------------------------------------------------------------------

	local function manaBlocks(): boolean
		if S.combatBusy then
			return false
		end
		if S.resourceRecoverPhase == "regen" or S.zRegenBusy then
			return true
		end
		if S.resourceRecoverPhase == "hold" then
			-- Wait until no reds close, then sit-recover (Z)
			local reds = #T().listAggro(T().fightRange() * 1.5)
			if reds > 0 then
				U.setStatus(string.format("LOW MANA — hold (reds≈%d)", reds))
				return true
			end
			S.resourceRecoverPhase = "regen"
			task.spawn(function()
				if S.Respawn and S.Respawn.runZRegenSequence then
					S.Respawn.runZRegenSequence("Mana recover")
				end
				S.resourceRecoverPhase = nil
			end)
			return true
		end
		if S.Respawn and S.Respawn.isManaLow and S.Respawn.isManaLow() then
			S.resourceRecoverPhase = "hold"
			U.setStatus("LOW MANA — pause casts")
			return true
		end
		return false
	end

	---------------------------------------------------------------------------
	-- One combat tick
	---------------------------------------------------------------------------

	local function tick()
		if S.combatBusy or not S.walking then
			return
		end
		if manaBlocks() then
			return
		end

		-- Never cast while sitting / sheathed / recovering (observe state, then fix)
		if U.killAuraBlocked then
			local blocked, why = U.killAuraBlocked()
			if blocked then
				if why == "sitting" and not S.zRegenBusy and U.ensureStanding then
					U.setStatus("[fight] sitting — Z to stand")
					U.ensureStanding(2.5)
				elseif (why == "sheathed" or why == "no_weapon") and not S.zRegenBusy then
					U.setStatus("[fight] sheathed — force Q (no cast)")
					if U.markWeaponSheathed then
						U.markWeaponSheathed()
					end
					if U.ensureWeaponDrawn then
						U.ensureWeaponDrawn(1.2, true)
					end
				else
					U.setStatus(string.format("[fight] paused (%s)", tostring(why)))
					task.wait(0.15)
				end
				return
			end
		end

		-- After a kill: wait active CDs before reloop (death clears waitAllCds).
		if S.waitAllCds then
			T().clearHold("wait_cds")
			if A().allCombatCdsReady() then
				S.waitAllCds = false
				U.setStatus("[cds] ready — reloop")
				task.wait(0.05)
				return
			end
			U.setStatus(string.format(
				"[cds] wait… max %.1fs | %s",
				A().maxCombatCdRemaining(),
				A().formatCds()
			))
			task.wait(0.15)
			return
		end

		local range = T().fightRange()
		local sticky = C.KILL_AURA_STICKY or 5
		local hold, _pos, dist = T().ensureEnemy()

		if not hold then
			U.setStatus(string.format("[fight] scan… | %s", A().formatCds()))
			task.wait(0.15)
			return
		end

		local handler = A().findHandler(hold)
		if not handler then
			U.setStatus(string.format("[fight] no schema for %s — next", hold.Name))
			T().clearHold("no_schema")
			task.wait(0.1)
			return
		end

		if not dist then
			dist = T().dist(hold) or 999
		end

		-- Only fight after pathing has approached (within stand band). No cast while walking in.
		local maxFight = range + sticky -- e.g. ~34
		if dist > maxFight then
			U.setStatus(string.format("[fight] wait stand d=%.1f (need ≤%.0f) | %s", dist, maxFight, hold.Name))
			task.wait(0.12)
			return
		end

		-- Prefer facing the enemy before R (pathing owns arrows; light assist here)
		local epos = U.getCharacterLikePosition(hold)
		if epos and U.facingDotTo then
			local fd = U.facingDotTo(epos.X, epos.Z)
			local need = C.KILL_AURA_FACE_ALIGN or 0.85
			if fd ~= nil and fd < need * 0.9 then
				U.setStatus(string.format("[fight] face first d=%.1f face=%.2f", dist, fd))
				if U.holdTurnKey and U.turnKeyToward then
					U.holdTurnKey(U.turnKeyToward(epos.X, epos.Z, need))
				end
				task.wait(0.1)
				return
			end
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
		end

		-- Reticle then cast (only in stand range)
		if not T().hasReticleOn(hold) then
			U.setStatus(string.format("[fight] R → %s d=%.1f", hold.Name, dist))
			U.pressKey(Enum.KeyCode.R)
			task.wait(C.TARGET_CYCLE_DELAY or 0.12)
			if not T().hasReticleOn(hold) then
				return
			end
		end

		local rem = A().getCooldownRemaining(handler.slot)
		if rem > 0.35 then
			U.setStatus(string.format(
				"[fight] CD %s %.1fs | %s d=%.1f",
				handler.id,
				rem,
				hold.Name,
				dist
			))
			task.wait(0.15)
			return
		end

		A().cast(hold, handler, "fight")

		if not T().isAlive(hold) then
			T().clearHold("killed")
			S.waitAllCds = true
			U.setStatus("[fight] target down — wait CDs then reloop")
		end
	end

	function M.runCombat()
		while S.walking do
			if not S.combatBusy then
				local ok, err = pcall(tick)
				if not ok then
					S.combatBusy = false
					U.setStatus("Combat error: " .. tostring(err))
					task.wait(0.4)
				end
			end
			task.wait(0.05)
		end
		S.combatBusy = false
		if U.releaseMoveKeys then
			U.releaseMoveKeys()
		end
	end

	return M
end

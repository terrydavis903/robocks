-- portal_mage/combat.lua — ability half of Kill Aura
--
-- Loop (with pathing.lua):
--   hold = nearest living enemy
--   path to stand range → R reticle → cast ready slot (s4 hold 5s / s1 tap)
--   enemy dies → clear hold → next nearest (no full CD lockout; switch slots free)
--   we die → respawn module resumes Kill Aura → reloop
--
-- Never cast without reticle. Never freefire. No creature-specific sequences.
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
		S.buffBusy = false
		S.waitAllCds = false
		S.proximityResumeWalk = false
		S.respawnResumeWalk = false
		S.resourceRecoverPhase = nil
		S.armedCombatSlot = nil
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

	-- Same as UI "Stop All" (kill aura / combat / auto ore). Claw untouched.
	-- Returns whether Kill Aura was running (for blacklist delayed resume).
	function M.stopBot(reason: string?): boolean
		local wasWalking = S.walking == true
		S.proximityResumeWalk = false
		S.respawnResumeWalk = false
		if S.AutoOre and S.AutoOre.stop then
			S.AutoOre.stop()
		end
		M.stopAll()
		if S.ui and S.ui.setAutoOreLabel then
			S.ui.setAutoOreLabel(false)
		end
		U.setStatus(reason or "Stopped kill aura/combat/auto-ore (claw unaffected)")
		return wasWalking
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

		-- Legacy waitAllCds (no longer set after kill — no QS4 lockout). Clear if stuck.
		if S.waitAllCds then
			S.waitAllCds = false
		end

		if S.buffBusy then
			task.wait(0.1)
			return
		end

		-- Pathing is walking back onto Cobblestone before the next pick
		if S.stoneRecoverBusy then
			task.wait(0.1)
			return
		end

		local range = T().fightRange()
		local sticky = C.KILL_AURA_STICKY or 5
		local playerFlat = U.getLivePlayerVector()

		-- Reticle locked on enemy far above us (roof/cliff): hold R to unlock, move on.
		-- World dump 13-26-06: 24 mobs +40–50 Y while player ~109.
		do
			local ret = T().getReticleLiving and T().getReticleLiving() or T().getReticle()
			if ret and T().isTooHigh and T().isTooHigh(ret, playerFlat) then
				if T().releaseReticleTooHigh then
					T().releaseReticleTooHigh(ret, "reticle_too_high")
				end
				task.wait(0.1)
				return
			end
		end

		-- Nearest mob (pathing approaches); no creature schema filter
		local hold, _pos, dist = T().ensureEnemy()

		-- Between fights (no target / after kill): reapply bless if BuffIcon missing
		if not hold then
			if A().ensureCombatBuff and A().ensureCombatBuff("scan") then
				return
			end
			U.setStatus(string.format("[fight] scan… | %s", A().formatCds()))
			task.wait(0.15)
			return
		end

		-- Hold is too high: release reticle if on them, clear, pick another
		if T().isTooHigh and T().isTooHigh(hold, playerFlat) then
			if T().hasReticleOn and T().hasReticleOn(hold) and T().releaseReticleTooHigh then
				T().releaseReticleTooHigh(hold, "hold_too_high")
			else
				if T().markTooHighIgnore then
					T().markTooHighIgnore(hold)
				end
				T().clearHold("hold_too_high")
			end
			task.wait(0.1)
			return
		end

		-- Ready slot: prefer s4 hold, else s1 tap (no creature sequences)
		local handler = A().pickCombatHandler and A().pickCombatHandler() or A().findHandler(hold)
		if not handler then
			handler = A().getDefaultHandler()
		end
		if not handler then
			U.setStatus("[fight] no combat slots configured")
			task.wait(0.2)
			return
		end

		-- Flat XZ distance (matches pathing stand band — avoids height deadlock)
		local eposFlat = U.getCharacterLikePosition(hold)
		if eposFlat and playerFlat then
			dist = Vector3.new(eposFlat.X - playerFlat.X, 0, eposFlat.Z - playerFlat.Z).Magnitude
		elseif not dist then
			dist = T().dist(hold) or 999
		end

		-- Only fight after pathing has approached. Distance-only — no hasClearWalk
		-- gate (wall LOS false-negatives froze combat in "wait path" forever).
		local maxFight = range + sticky -- e.g. ~34
		if dist > maxFight then
			if not S.walking then
				U.setStatus(string.format(
					"[fight] wait stand d=%.1f (need ≤%.0f) | %s",
					dist,
					maxFight,
					hold.Name
				))
			end
			task.wait(0.12)
			return
		end

		-- Face enemy with hard snap only — never Left/Right arrows (permanent spin).
		local epos = U.getCharacterLikePosition(hold)
		if epos then
			if U.holdTurnKey then
				U.holdTurnKey(nil)
			end
			if U.faceToward then
				U.faceToward(epos.X, epos.Y, epos.Z, false, 0.05)
			end
		end

		-- Reticle then cast (only in stand range)
		if not T().hasReticleOn(hold) then
			U.setStatus(string.format("[fight] R → %s d=%.1f", hold.Name, dist))
			U.pressKey(Enum.KeyCode.R)
			task.wait(C.TARGET_CYCLE_DELAY or 0.12)
			-- R may have locked a different (e.g. high) mob — unlock and bail
			local ret = T().getReticleLiving and T().getReticleLiving() or T().getReticle()
			if ret and not T().reticleOn(hold, ret) then
				if T().isTooHigh and T().isTooHigh(ret, playerFlat) and T().releaseReticleTooHigh then
					T().releaseReticleTooHigh(ret, "r_locked_too_high")
				end
				return
			end
			if not T().hasReticleOn(hold) then
				return
			end
		end

		local rem = A().getCooldownRemaining(handler.slot)
		if rem > 0.35 then
			-- Slot on CD — try the other combat slot immediately (no lockout)
			local alt = nil
			if A().pickCombatHandler then
				alt = A().pickCombatHandler()
			end
			if alt and alt.slot ~= handler.slot and A().isHandlerReady(alt) then
				handler = alt
			else
				U.setStatus(string.format(
					"[fight] CD s%d %.1fs | %s d=%.1f | %s",
					handler.slot or 0,
					rem,
					hold.Name,
					dist,
					A().formatCds()
				))
				task.wait(0.12)
				return
			end
		end

		A().cast(hold, handler, "fight")

		if not T().isAlive(hold) then
			T().clearHold("killed")
			-- Between fights: refresh buff before pathing to next opponent
			if A().ensureCombatBuff then
				A().ensureCombatBuff("post_kill")
			end
			U.setStatus("[fight] target down — next")
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

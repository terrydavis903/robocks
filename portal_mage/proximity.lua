-- portal_mage/proximity.lua — pause walk+combat if another player is too close
-- Respawn + anti-AFK keep running. Default ON (critical safety).
--
-- Scope: combat/pathing maps only. Claw is a separate module on a different map
-- (no enemies there). While S.clawBusy, this guard is a full no-op — it must not
-- freeze, cancel, or overwrite claw status.
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local M = {}

	function M.findNearestOtherPlayer(): (Player?, number?)
		local myPos = U.getLivePlayerVector()
		if not myPos then
			return nil, nil
		end
		local lp = Players.LocalPlayer
		local bestPlr: Player? = nil
		local bestDist = math.huge
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= lp then
				local char = plr.Character
				if char then
					local pos = U.getCharacterLikePosition(char)
					if pos then
						local d = (pos - myPos).Magnitude
						if d < bestDist then
							bestDist = d
							bestPlr = plr
						end
					end
				end
			end
		end
		if bestPlr then
			return bestPlr, bestDist
		end
		return nil, nil
	end

	function M.isThreatNearby(): (boolean, Player?, number?)
		local radius = C.PLAYER_PROXIMITY_PAUSE_STUDS or 150
		local plr, dist = M.findNearestOtherPlayer()
		if plr and dist and dist <= radius then
			return true, plr, dist
		end
		return false, plr, dist
	end

	local function freezeBot(statusText: string)
		if S.walking then
			S.proximityResumeWalk = true
		end
		S.walking = false
		S.combatBusy = false
		S.proximityPaused = true
		if S.ui and S.ui.setWalkLabel then
			S.ui.setWalkLabel(false)
		end
		U.setStatus(statusText)
	end

	function M.tick()
		if not S.proximityGuardEnabled then
			S.proximityPaused = false
			return
		end

		-- Claw one-shot is independent of prox guard: do not freeze, cancel, or
		-- steal status while aiming/dropping. Walk+combat still pause when idle.
		if S.clawBusy then
			return
		end

		local radius = C.PLAYER_PROXIMITY_PAUSE_STUDS or 150
		local threat, plr, dist = M.isThreatNearby()
		if threat and plr and dist then
			-- Immediate hard stop of walk + combat (respawn stays alive separately)
			if S.walking or S.combatBusy or not S.proximityPaused then
				freezeBot(string.format(
					"⚠ PROX PAUSE | %s @ %.0fst (<%d) — bot frozen",
					plr.Name,
					dist,
					radius
				))
			else
				-- Stay frozen; refresh status so user sees ongoing threat
				U.setStatus(string.format(
					"⚠ PROX PAUSE | %s @ %.0fst (<%d) — bot frozen",
					plr.Name,
					dist,
					radius
				))
			end
			return
		end

		-- Clear of other players
		if S.proximityPaused then
			S.proximityPaused = false
			if S.proximityResumeWalk then
				-- Never resume mid post-respawn Z sequence
				if S.zRegenBusy or S.respawnResumeWalk then
					U.setStatus("Prox clear — waiting for respawn Z→Z→Q before Walk+Atk")
					return
				end
				S.proximityResumeWalk = false
				U.setStatus("Prox clear — resuming Walk+Atk…")
				task.defer(function()
					if S.walking or not S.proximityGuardEnabled then
						return
					end
					if S.zRegenBusy or S.respawnResumeWalk then
						S.proximityResumeWalk = true
						return
					end
					local stillThreat = M.isThreatNearby()
					if stillThreat then
						return
					end
					if S.Pathing and S.Pathing.toggleWalk then
						S.Pathing.toggleWalk()
					end
				end)
			else
				U.setStatus("Prox clear — safe (Walk+Atk was off)")
			end
		end
	end

	function M.start()
		if S.proximityThread then
			return
		end
		S.proximityGuardEnabled = true
		S.proximityPaused = false
		S.proximityResumeWalk = false
		S.proximityThread = task.spawn(function()
			while true do
				pcall(M.tick)
				task.wait(C.PLAYER_PROXIMITY_CHECK_INTERVAL or 0.15)
			end
		end)
	end

	function M.toggleGuard()
		S.proximityGuardEnabled = not S.proximityGuardEnabled
		S.ui.setProxLabel(S.proximityGuardEnabled)
		if not S.proximityGuardEnabled then
			S.proximityPaused = false
			S.proximityResumeWalk = false
			U.setStatus("Prox guard OFF — will not pause for players")
		else
			U.setStatus(string.format(
				"Prox guard ON — pause if player <%d studs",
				C.PLAYER_PROXIMITY_PAUSE_STUDS or 150
			))
			M.tick()
		end
	end

	return M
end

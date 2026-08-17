-- portal_mage/player_blacklist.lua
-- If a blacklisted player joins (or is already present): Stop All immediately.
-- Anti-AFK jump stays on. If Kill Aura was on, schedule re-enable after lock (30m)
-- unless the user turns it on manually first.
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local M = {}

	local function namesList(): { string }
		local list = C.PLAYER_BLACKLIST_NAMES
		if type(list) ~= "table" then
			return {}
		end
		return list
	end

	function M.isBlacklistedName(name: string?): boolean
		if type(name) ~= "string" or name == "" then
			return false
		end
		local lower = string.lower(name)
		for _, n in ipairs(namesList()) do
			if type(n) == "string" and string.lower(n) == lower then
				return true
			end
		end
		return false
	end

	function M.findBlacklistedPlayer(): Player?
		local lp = Players.LocalPlayer
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= lp then
				if M.isBlacklistedName(plr.Name) or M.isBlacklistedName(plr.DisplayName) then
					return plr
				end
			end
		end
		return nil
	end

	local function lockSeconds(): number
		return tonumber(C.PLAYER_BLACKLIST_LOCK_SECONDS) or (30 * 60)
	end

	-- Stop All + schedule Kill Aura resume. Does not touch Anti-AFK.
	function M.trigger(plr: Player?, why: string?)
		local name = plr and plr.Name or "?"
		local lock = lockSeconds()
		local wasWalking = false
		if S.Combat and S.Combat.stopBot then
			wasWalking = S.Combat.stopBot(string.format(
				"⛔ BLACKLIST %s — Stop All (%s). KA lock %.0fm",
				name,
				why or "hit",
				lock / 60
			))
		else
			wasWalking = S.walking == true
			if S.Combat and S.Combat.stopAll then
				S.Combat.stopAll()
			end
			S.walking = false
		end

		S.blacklistLastHitName = name
		S.blacklistLockUntil = os.clock() + lock
		if wasWalking then
			S.blacklistResumeKillAura = true
			S.blacklistResumeAt = S.blacklistLockUntil
			U.setStatus(string.format(
				"⛔ BLACKLIST %s — stopped. Auto re-enable Kill Aura in %.0fm (AFK jump stays on)",
				name,
				lock / 60
			))
		else
			S.blacklistResumeKillAura = false
			S.blacklistResumeAt = 0
			U.setStatus(string.format(
				"⛔ BLACKLIST %s — stopped (KA was off). Lock %.0fm",
				name,
				lock / 60
			))
		end
	end

	function M.onPlayer(plr: Player, why: string)
		if not plr or plr == Players.LocalPlayer then
			return
		end
		if M.isBlacklistedName(plr.Name) or M.isBlacklistedName(plr.DisplayName) then
			M.trigger(plr, why)
		end
	end

	local function tryResume()
		if not S.blacklistResumeKillAura then
			return
		end
		if os.clock() < (S.blacklistResumeAt or 0) then
			return
		end
		-- User already re-enabled Kill Aura manually — cancel schedule
		if S.walking then
			S.blacklistResumeKillAura = false
			S.blacklistResumeAt = 0
			return
		end
		S.blacklistResumeKillAura = false
		S.blacklistResumeAt = 0
		U.setStatus(string.format(
			"Blacklist lock ended (was %s) — re-enabling Kill Aura…",
			tostring(S.blacklistLastHitName or "?")
		))
		task.defer(function()
			if S.walking then
				return
			end
			if S.Pathing and S.Pathing.toggleWalk then
				S.Pathing.toggleWalk()
			end
		end)
	end

	function M.tick()
		-- Join / already_here fire trigger; tick only handles delayed Kill Aura resume.
		tryResume()
	end

	function M.start()
		if S.blacklistThread then
			return
		end
		-- Existing players at load
		for _, plr in ipairs(Players:GetPlayers()) do
			M.onPlayer(plr, "already_here")
		end
		Players.PlayerAdded:Connect(function(plr)
			-- Wait a beat for name replication
			task.defer(function()
				task.wait(0.25)
				M.onPlayer(plr, "joined")
			end)
		end)
		S.blacklistThread = task.spawn(function()
			while true do
				pcall(M.tick)
				task.wait(1.0)
			end
		end)
	end

	return M
end

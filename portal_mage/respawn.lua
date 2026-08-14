-- portal_mage/respawn.lua — auto-click Respawn, Z-recover HP/MP, then Z → Q
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local GuiService = S.Services.GuiService
	local VIM = S.Services.VirtualInputManager
	local M = {}

	local lastRespawnClickAt = 0

	local function clickGuiButton(btn: GuiButton)
		pcall(function()
			if typeof(firesignal) == "function" then
				firesignal(btn.MouseButton1Down)
				firesignal(btn.MouseButton1Up)
				firesignal(btn.MouseButton1Click)
				firesignal(btn.Activated)
			end
		end)
		pcall(function()
			(btn :: any):Activate()
		end)

		local inset = Vector2.zero
		pcall(function()
			inset = GuiService:GetGuiInset()
		end)
		local pos = btn.AbsolutePosition
		local size = btn.AbsoluteSize
		local x = pos.X + size.X * 0.5
		local y = pos.Y + size.Y * 0.5 + inset.Y
		VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
		task.wait(0.04)
		VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
	end

	local function getRespawnButtonText(btn: Instance): string?
		local label = btn:FindFirstChild("ButtonText")
		if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
			return label.Text
		end
		if btn:IsA("TextButton") then
			return btn.Text
		end
		return nil
	end

	local function findReadyRespawnButton(): GuiButton?
		local lp = Players.LocalPlayer
		if not lp then
			return nil
		end
		local pg = lp:FindFirstChildOfClass("PlayerGui") or lp:FindFirstChild("PlayerGui")
		if not pg then
			return nil
		end

		local candidates = {}
		local portal = pg:FindFirstChild("ThePortalUI")
		if portal then
			local death = portal:FindFirstChild("DeathFrame")
			if death then
				local content = death:FindFirstChild("ContentFrame")
				local btn = content and content:FindFirstChild("RespawnButton")
				if btn and btn:IsA("GuiButton") then
					table.insert(candidates, btn)
				end
			end
		end

		if #candidates == 0 then
			for _, inst in ipairs(pg:GetDescendants()) do
				if inst.Name == "RespawnButton" and inst:IsA("GuiButton") then
					table.insert(candidates, inst)
				end
			end
		end

		for _, btn in ipairs(candidates) do
			if not btn.Visible then
				continue
			end
			local ancestorOk = true
			local p: Instance? = btn.Parent
			while p do
				if p:IsA("GuiObject") and not p.Visible then
					ancestorOk = false
					break
				end
				if p:IsA("ScreenGui") and not p.Enabled then
					ancestorOk = false
					break
				end
				p = p.Parent
			end
			if not ancestorOk then
				continue
			end
			local text = getRespawnButtonText(btn)
			if text and string.lower(string.gsub(text, "^%s*(.-)%s*$", "%1")) == "respawn" then
				return btn
			end
		end
		return nil
	end

	local function parseCurMax(text: string?): (number?, number?)
		if type(text) ~= "string" then
			return nil, nil
		end
		local a, b = string.match(text, "(%d+)%s*/%s*(%d+)")
		if a and b then
			return tonumber(a), tonumber(b)
		end
		return nil, nil
	end

	local function getHudHpMpTexts(): (string?, string?)
		local lp = Players.LocalPlayer
		if not lp then
			return nil, nil
		end
		local pg = lp:FindFirstChildOfClass("PlayerGui") or lp:FindFirstChild("PlayerGui")
		local ui = pg and pg:FindFirstChild("ThePortalUI")
		local hud = ui and ui:FindFirstChild("HUD")
		local container = hud and hud:FindFirstChild("HealthManaContainer")
		if not container then
			return nil, nil
		end
		local hpLabel = container:FindFirstChild("HPText", true)
		local mpLabel = container:FindFirstChild("MPText", true)
		local hpText = if hpLabel and (hpLabel:IsA("TextLabel") or hpLabel:IsA("TextButton")) then hpLabel.Text else nil
		local mpText = if mpLabel and (mpLabel:IsA("TextLabel") or mpLabel:IsA("TextButton")) then mpLabel.Text else nil
		return hpText, mpText
	end

	-- Returns isMaxed, hp, maxHp, mp, maxMp (nils if unknown)
	function M.readVitals(): (boolean, number?, number?, number?, number?)
		local hp, maxHp, mp, maxMp = nil, nil, nil, nil

		local hpText, mpText = getHudHpMpTexts()
		local h1, h2 = parseCurMax(hpText)
		local m1, m2 = parseCurMax(mpText)
		if h1 and h2 then
			hp, maxHp = h1, h2
		end
		if m1 and m2 then
			mp, maxMp = m1, m2
		end

		-- Humanoid backup for health
		local lp = Players.LocalPlayer
		local char = lp and lp.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum and (not hp or not maxHp) then
			hp = hum.Health
			maxHp = hum.MaxHealth
		end

		-- Not maxed until we can see both pools at full (need mana from HUD)
		if not maxHp or not maxMp or maxHp <= 0 or maxMp <= 0 then
			return false, hp, maxHp, mp, maxMp
		end
		if not hp or not mp then
			return false, hp, maxHp, mp, maxMp
		end
		local eps = 0.5
		local full = hp + eps >= maxHp and mp + eps >= maxMp
		return full, hp, maxHp, mp, maxMp
	end

	function M.isManaLow(threshold: number?): boolean
		local frac = threshold or C.MANA_RECOVER_FRACTION or 0.2
		local _full, _hp, _maxHp, mp, maxMp = M.readVitals()
		if not mp or not maxMp or maxMp <= 0 then
			return false
		end
		return (mp / maxMp) < frac
	end

	-- Wait until HP/MP full (poll only — do NOT spam Z).
	function M.waitUntilVitalsMaxed(statusPrefix: string?): boolean
		local prefix = statusPrefix or "Recover"
		local interval = C.RESPAWN_Z_POLL_INTERVAL or 0.35
		local cap = C.RESPAWN_Z_MAX_SECONDS or 90
		local deadline = os.clock() + cap

		while os.clock() < deadline do
			-- Abort if walk stopped mid-regen (except respawn may run without walking)
			local full, hp, maxHp, mp, maxMp = M.readVitals()
			if full then
				U.setStatus(string.format(
					"%s: HP/MP full (%s/%s | %s/%s)",
					prefix,
					tostring(hp),
					tostring(maxHp),
					tostring(mp),
					tostring(maxMp)
				))
				return true
			end
			U.setStatus(string.format(
				"%s: recovering… HP %s/%s MP %s/%s",
				prefix,
				tostring(hp or "?"),
				tostring(maxHp or "?"),
				tostring(mp or "?"),
				tostring(maxMp or "?")
			))
			task.wait(interval)
		end

		local full = M.readVitals()
		return full
	end

	-- Z once → wait full → Z once → wait → Q  (shared by respawn + low-mana recover)
	function M.runZRegenSequence(statusPrefix: string?): boolean
		if S.zRegenBusy then
			return false
		end
		S.zRegenBusy = true
		local prefix = statusPrefix or "Z-regen"
		local ok, err = pcall(function()
			U.setStatus(prefix .. ": Z (enter recover)")
			pcall(function()
				U.pressKey(Enum.KeyCode.Z)
			end)

			M.waitUntilVitalsMaxed(prefix)

			U.setStatus(prefix .. ": Z (exit recover)")
			pcall(function()
				U.pressKey(Enum.KeyCode.Z)
			end)
			task.wait(C.RESPAWN_AFTER_MAX_WAIT or 0.5)
			U.setStatus(prefix .. ": Q")
			pcall(function()
				U.pressKey(Enum.KeyCode.Q)
			end)
			U.setStatus(prefix .. ": done")
		end)
		if not ok then
			U.setStatus(prefix .. " error: " .. tostring(err))
		end
		S.zRegenBusy = false
		return ok
	end

	-- After death: wait → full Z regen → only then restart Walk+Atk if it was active
	local function runPostRespawnSequence()
		if S.zRegenBusy then
			return
		end
		local shouldResumeWalk = S.respawnResumeWalk

		local waitAfterClick = C.RESPAWN_POST_CLICK_WAIT or 2
		U.setStatus(string.format(
			"Auto-respawn: waiting %.1fs…%s",
			waitAfterClick,
			if shouldResumeWalk then " (Walk+Atk paused until Z→Z→Q)" else ""
		))
		-- Hold Walk+Atk frozen for the entire post-respawn sequence
		S.zRegenBusy = true
		S.resourceRecoverPhase = "regen"
		task.wait(waitAfterClick)

		-- runZRegenSequence sets zRegenBusy itself; clear our hold first so it can enter
		S.zRegenBusy = false
		M.runZRegenSequence("Auto-respawn")

		S.resourceRecoverPhase = nil
		S.holdTarget = nil
		S.waitAllCds = false -- death cleared CDs; reloop immediately after resume

		if not shouldResumeWalk then
			S.respawnResumeWalk = false
			return
		end

		-- Walk+Atk was active: resume only after Z→Z→Q fully finished
		S.respawnResumeWalk = false
		if S.walking then
			return
		end

		if S.proximityGuardEnabled and S.Proximity then
			local threat, plr, dist = S.Proximity.isThreatNearby()
			if threat then
				S.proximityResumeWalk = true
				U.setStatus(string.format(
					"Auto-respawn done — prox blocked (%s @ %.0f), resume later",
					plr and plr.Name or "?",
					dist or -1
				))
				return
			end
		end

		U.setStatus("Auto-respawn done — resuming Walk+Atk…")
		if S.Pathing and S.Pathing.toggleWalk then
			S.Pathing.toggleWalk()
		end
	end

	local function tryAutoRespawn()
		-- Don't re-click while post-respawn / Z sequence is running
		if S.zRegenBusy then
			return
		end
		local btn = findReadyRespawnButton()
		if not btn then
			return
		end
		local now = os.clock()
		if now - lastRespawnClickAt < C.RESPAWN_CLICK_COOLDOWN then
			return
		end
		lastRespawnClickAt = now

		-- If Walk+Atk was running, stop it until Z→Z→Q completes.
		-- Death resets ability CDs — do not waitAllCds after respawn.
		if S.walking then
			S.respawnResumeWalk = true
			S.walking = false
			S.combatBusy = false
			S.waitAllCds = false
			S.holdTarget = nil
			S.ui.setWalkLabel(false)
			U.setStatus("Auto-respawn: Walk+Atk paused — clicking Respawn")
		else
			S.waitAllCds = false
			U.setStatus("Auto-respawn: clicking Respawn")
		end

		pcall(function()
			clickGuiButton(btn)
		end)
		task.spawn(runPostRespawnSequence)
	end

	function M.start()
		task.spawn(function()
			while true do
				pcall(tryAutoRespawn)
				task.wait(0.2)
			end
		end)
	end

	return M
end

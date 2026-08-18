-- portal_mage/respawn.lua — auto-click Respawn, Z-recover HP/MP, then Z → Q
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local GuiService = S.Services.GuiService
	local VIM = S.Services.VirtualInputManager
	local M = {}

	local lastRespawnClickAt = 0

	-- True only when a Humanoid exists and is dead. Nil character during the
	-- post-click swap is NOT death (that false-positive aborted regen forever:
	-- "died mid-regen — aborting old loop" stuck).
	local function isDefinitelyDead(): boolean
		local hum = U.getHumanoid and U.getHumanoid()
		return hum ~= nil and hum.Health <= 0
	end

	-- True if this post-respawn generation was superseded (died again / new click).
	local function regenAborted(gen: number?): boolean
		if S.respawnRegenAbort == true then
			return true
		end
		if type(gen) == "number" and type(S.postRespawnGen) == "number" and gen ~= S.postRespawnGen then
			return true
		end
		return false
	end

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
	-- opts.gen: post-respawn generation; abort if we die again mid-wait.
	function M.waitUntilVitalsMaxed(statusPrefix: string?, opts: any?): boolean
		opts = opts or {}
		local gen = opts.gen
		local prefix = statusPrefix or "Recover"
		local interval = C.RESPAWN_Z_POLL_INTERVAL or 0.35
		local cap = C.RESPAWN_Z_MAX_SECONDS or 90
		local deadline = os.clock() + cap

		while os.clock() < deadline do
			if regenAborted(gen) or isDefinitelyDead() then
				U.setStatus(prefix .. ": died mid-regen — abort for re-respawn")
				S.respawnRegenAbort = true
				return false
			end
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

		if regenAborted(gen) or isDefinitelyDead() then
			S.respawnRegenAbort = true
			return false
		end
		local full = M.readVitals()
		return full
	end

	-- State-driven recover (not a blind Z→Z→Q sequence):
	--   sit/stand = Z toggle (observe isSeated: Sit / Seated / WalkSpeed≈0)
	--   sheathe/draw = Q toggle (observe isWeaponDrawn: Tool on character)
	--   HP/MP from HUD; only sit-recover when not full.
	-- While zRegenBusy, Kill Aura hard-idles.
	-- opts.gen / opts.allowBusy: post-respawn may already hold zRegenBusy.
	function M.runZRegenSequence(statusPrefix: string?, opts: any?): boolean
		opts = opts or {}
		local gen = opts.gen
		if S.zRegenBusy and not opts.allowBusy then
			return false
		end
		S.zRegenBusy = true
		if U.releaseMoveKeys then
			U.releaseMoveKeys()
		end
		local prefix = statusPrefix or "recover"
		local aborted = false
		local ok, err = pcall(function()
			if regenAborted(gen) or isDefinitelyDead() then
				aborted = true
				return
			end
			local full = M.readVitals()

			-- 1) Need vitals → enter sit-recover if not already seated
			if not full then
				if not U.isSeated() then
					U.setStatus(prefix .. ": vitals low → sit (Z)")
					U.ensureSeated(3.0)
				else
					U.setStatus(prefix .. ": already sitting — recover")
				end
				if not M.waitUntilVitalsMaxed(prefix, { gen = gen }) then
					aborted = true
					return
				end
			else
				U.setStatus(prefix .. ": vitals already full")
			end

			if regenAborted(gen) or isDefinitelyDead() then
				aborted = true
				return
			end

			-- 2) Must stand before drawing / fighting
			if U.isSeated() then
				U.setStatus(prefix .. ": sit → stand (Z)")
				local stood = U.ensureStanding(4.0)
				if not stood then
					U.setStatus(prefix .. ": still sitting after Z — retry")
					U.ensureStanding(3.0)
				end
				-- Standing after sit-recover ⇒ sheathed (game); force draw next
				if U.markWeaponSheathed then
					U.markWeaponSheathed()
				end
			end

			if regenAborted(gen) or isDefinitelyDead() then
				aborted = true
				return
			end

			-- 3) Draw when we know sheathed (post-sit) or hard-negative
			if U.isSeated() then
				U.setStatus(prefix .. ": cannot draw — still sitting")
			else
				local hard = U.detectWeaponDrawnHard and select(1, U.detectWeaponDrawnHard())
				if hard then
					if U.markWeaponDrawn then
						U.markWeaponDrawn()
					end
					U.setStatus(prefix .. ": weapon hard-detected drawn")
				elseif S.weaponDrawnKnown == false or not hard then
					-- Post-sit: known=false → Q once. If unknown, soft isWeaponDrawn is true
					-- so ensureWeaponDrawn no-ops unless known=false.
					if S.weaponDrawnKnown == false then
						U.setStatus(prefix .. ": sheathed after sit → force Q")
						U.ensureWeaponDrawn(C.WEAPON_EQUIP_WAIT or 1.5, true)
					else
						-- Standing without hard detect: still force one unsheath
						U.setStatus(prefix .. ": standing → force Q unsheath")
						if U.markWeaponSheathed then
							U.markWeaponSheathed()
						end
						U.ensureWeaponDrawn(C.WEAPON_EQUIP_WAIT or 1.5, true)
					end
				end
			end

			-- 4) Status from stance snapshot
			local stance = U.getStance and U.getStance() or {}
			local seated = stance.seated == true or U.isSeated()
			local drawn = stance.weaponDrawn == true or U.isWeaponDrawn()
			if not seated and drawn then
				U.setStatus(string.format(
					"%s: ready — stand + drawn (hard=%s known=%s)",
					prefix,
					tostring(stance.weaponHard),
					tostring(stance.weaponKnown)
				))
			else
				U.setStatus(string.format(
					"%s: incomplete (sit=%s drawn=%s hard=%s known=%s)",
					prefix,
					tostring(seated),
					tostring(drawn),
					tostring(stance.weaponHard),
					tostring(stance.weaponKnown)
				))
			end
		end)
		if not ok then
			U.setStatus(prefix .. " error: " .. tostring(err))
		end
		S.zRegenBusy = false
		if aborted or regenAborted(gen) then
			return false
		end
		return ok and (not U.isSeated()) and U.isWeaponDrawn()
	end

	-- Drop busy flags for this post-respawn generation. Superseded gens no-op
	-- so a newer click's sequence keeps ownership.
	local function endPostRespawnBusy(gen: number, opts: any?)
		opts = opts or {}
		if type(gen) == "number" and type(S.postRespawnGen) == "number" and gen ~= S.postRespawnGen then
			return
		end
		S.zRegenBusy = false
		S.resourceRecoverPhase = nil
		S.spawnEgressBusy = false
		if opts.clearResume == true then
			S.respawnResumeWalk = false
		end
		-- keepResumeIfDead: leave respawnResumeWalk armed for the next Respawn click
	end

	-- After death: wait for character → S nudge → recover → spawn egress → resume KA
	local function runPostRespawnSequence(gen: number)
		-- Capture before any flag churn; keep respawnResumeWalk until startWalk succeeds
		local shouldResumeWalk = S.respawnResumeWalk == true
			or S.proximityResumeWalk == true

		local waitAfterClick = C.RESPAWN_POST_CLICK_WAIT or 2
		U.setStatus(string.format(
			"Auto-respawn: waiting %.1fs for character…%s",
			waitAfterClick,
			if shouldResumeWalk then " (Kill Aura paused)" else ""
		))
		S.zRegenBusy = true
		S.resourceRecoverPhase = "regen"
		if shouldResumeWalk then
			S.respawnResumeWalk = true
		end

		local function abortDead(msg: string)
			endPostRespawnBusy(gen, { keepResumeIfDead = true })
			U.setStatus(msg)
		end

		task.wait(waitAfterClick)
		if regenAborted(gen) then
			endPostRespawnBusy(gen, {}) -- superseded: don't touch resume
			return
		end

		-- Wait until we have a living humanoid before stance actions
		local tChar = os.clock()
		while os.clock() - tChar < 8 do
			if regenAborted(gen) then
				endPostRespawnBusy(gen, {})
				return
			end
			local hum = U.getHumanoid and U.getHumanoid()
			if hum and hum.Health > 0 then
				break
			end
			task.wait(0.2)
		end

		if regenAborted(gen) then
			endPostRespawnBusy(gen, {})
			return
		end
		if isDefinitelyDead() then
			abortDead("Auto-respawn: dead again before regen — waiting for Respawn UI")
			return
		end

		-- Immediately after spawn, before Z-sit: hold S for 1s (nudge off pad)
		do
			local holdS = C.RESPAWN_POST_S_HOLD or 1.0
			U.setStatus(string.format("Auto-respawn: hold S %.1fs…", holdS))
			if U.releaseMoveKeys then
				U.releaseMoveKeys()
			end
			if U.holdMoveKeys then
				U.holdMoveKeys({ Enum.KeyCode.S })
			end
			local tS = os.clock()
			while os.clock() - tS < holdS do
				if regenAborted(gen) or isDefinitelyDead() then
					break
				end
				task.wait(0.05)
			end
			if U.releaseMoveKeys then
				U.releaseMoveKeys()
			end
		end

		if regenAborted(gen) then
			endPostRespawnBusy(gen, {})
			return
		end
		if isDefinitelyDead() then
			abortDead("Auto-respawn: died during S-hold — re-respawn")
			return
		end

		-- allowBusy: we already own zRegenBusy for this generation
		local ready = M.runZRegenSequence("Auto-respawn", { gen = gen, allowBusy = true })

		if regenAborted(gen) then
			endPostRespawnBusy(gen, {})
			return
		end
		if isDefinitelyDead() then
			abortDead("Auto-respawn: died mid-regen — will click Respawn again")
			return
		end

		S.resourceRecoverPhase = nil
		S.holdTarget = nil
		S.waitAllCds = false
		S.combatBusy = false
		S.buffBusy = false
		if S.Abilities and S.Abilities.clearSyntheticCds then
			S.Abilities.clearSyntheticCds()
		else
			S.slotCdUntil = {}
			S.lastCastAt = 0
			S.lastCastSlot = nil
		end

		if not shouldResumeWalk then
			endPostRespawnBusy(gen, { clearResume = true })
			return
		end

		if S.walking then
			S.proximityResumeWalk = false
			endPostRespawnBusy(gen, { clearResume = true })
			U.setStatus("Auto-respawn: Kill Aura already running")
			return
		end

		-- Best-effort stand + draw (hard sit only — spawn WS=0 is not a seat)
		local seatedNow = if U.isSeatedHard then U.isSeatedHard() else (U.isSeated and U.isSeated())
		if seatedNow then
			U.setStatus("Auto-respawn: still sitting — Z stand")
			if U.ensureStanding then
				U.ensureStanding(3.5)
			end
		end
		if U.markWeaponSheathed then
			U.markWeaponSheathed()
		end
		if U.ensureWeaponDrawn then
			U.ensureWeaponDrawn(C.WEAPON_EQUIP_WAIT or 1.5, true)
		end

		if regenAborted(gen) then
			endPostRespawnBusy(gen, {})
			return
		end
		if isDefinitelyDead() then
			abortDead("Auto-respawn: died before egress — waiting for Respawn UI")
			return
		end

		U.setStatus(string.format(
			"Auto-respawn ready (regen=%s) — checking spawn egress…",
			tostring(ready)
		))

		-- Keep respawnResumeWalk set through egress; clear only after KA starts.
		S.zRegenBusy = false
		S.resourceRecoverPhase = nil

		-- Spawn egress BEFORE prox gate — leave the pad even if players are nearby.
		if S.PathRecord and S.PathRecord.tryPlayClosestSpawnPath then
			local matchStuds = C.RESPAWN_PATH_MATCH_STUDS or 64
			local used = S.PathRecord.tryPlayClosestSpawnPath(matchStuds)
			if regenAborted(gen) then
				endPostRespawnBusy(gen, {})
				return
			end
			if isDefinitelyDead() then
				abortDead("Auto-respawn: died during spawn egress — re-respawn")
				return
			end
			if not used then
				U.setStatus(string.format(
					"Auto-respawn: no spawn path ≤%.0fst — resume KA (no egress)",
					matchStuds
				))
			else
				U.setStatus("Auto-respawn: spawn egress finished — resuming Kill Aura…")
			end
			local seatedAfter = if U.isSeatedHard then U.isSeatedHard() else (U.isSeated and U.isSeated())
			if seatedAfter and U.ensureStanding then
				U.ensureStanding(2.5)
			end
			if U.ensureWeaponDrawn then
				U.ensureWeaponDrawn(C.WEAPON_EQUIP_WAIT or 1.5, true)
			end
		end

		if regenAborted(gen) then
			endPostRespawnBusy(gen, {})
			return
		end
		if isDefinitelyDead() then
			abortDead("Auto-respawn: died after egress — re-respawn")
			return
		end

		-- If prox still blocks KA start, hand off to prox resume (path already done).
		if S.proximityGuardEnabled and S.Proximity then
			local threat, plr, dist = S.Proximity.isThreatNearby()
			if threat then
				S.proximityResumeWalk = true
				S.proximityPaused = true
				endPostRespawnBusy(gen, { clearResume = true })
				U.setStatus(string.format(
					"Auto-respawn: egress done — prox blocked (%s @ %.0f); KA when clear",
					plr and plr.Name or "?",
					dist or -1
				))
				return
			end
		end

		-- Force start (not toggle). Keep resume flag until walking is true.
		local started = false
		if S.Pathing and S.Pathing.startWalk then
			started = S.Pathing.startWalk({ fromRespawn = true }) == true
		elseif S.Pathing and S.Pathing.toggleWalk then
			S.Pathing.toggleWalk()
			started = S.walking == true
		end

		if not started and not S.walking then
			for attempt = 1, 6 do
				if regenAborted(gen) then
					endPostRespawnBusy(gen, {})
					return
				end
				if isDefinitelyDead() then
					abortDead("Auto-respawn: died during KA resume retries")
					return
				end
				if S.walking then
					started = true
					break
				end
				local sitStr = tostring(
					if U.isSeatedHard then U.isSeatedHard() else (U.isSeated and U.isSeated())
				)
				U.setStatus(string.format(
					"Auto-respawn: resume retry %d/6 (sit=%s)…",
					attempt,
					sitStr
				))
				local stillSit = if U.isSeatedHard then U.isSeatedHard() else (U.isSeated and U.isSeated())
				if stillSit and U.ensureStanding then
					U.ensureStanding(2.5)
				end
				if U.ensureWeaponDrawn then
					U.ensureWeaponDrawn(1.2, true)
				end
				task.wait(0.45)
				S.zRegenBusy = false
				if S.Pathing and S.Pathing.startWalk then
					started = S.Pathing.startWalk({ fromRespawn = true }) == true
				end
			end
		end

		if regenAborted(gen) then
			endPostRespawnBusy(gen, {})
			return
		end

		if S.walking then
			S.proximityResumeWalk = false
			S.proximityPaused = false
			endPostRespawnBusy(gen, { clearResume = true })
			U.setStatus("Auto-respawn: Kill Aura resumed")
		else
			-- Sticky prox handoff if a player appeared during retries
			if S.proximityGuardEnabled and S.Proximity and select(1, S.Proximity.isThreatNearby()) then
				S.proximityResumeWalk = true
				S.proximityPaused = true
				endPostRespawnBusy(gen, { clearResume = true })
				U.setStatus("Auto-respawn: KA deferred to prox clear")
			else
				endPostRespawnBusy(gen, { clearResume = true })
				U.setStatus(string.format(
					"Auto-respawn: failed to resume Kill Aura (sit=%s drawn=%s) — toggle manually",
					tostring(if U.isSeatedHard then U.isSeatedHard() else (U.isSeated and U.isSeated())),
					tostring(U.isWeaponDrawn and U.isWeaponDrawn())
				))
			end
		end
	end

	local function tryAutoRespawn()
		local btn = findReadyRespawnButton()
		if not btn then
			return
		end

		-- Only interrupt an in-flight post-respawn if we are *actually* dead again.
		-- Respawn UI can linger after our own click while zRegenBusy=true — aborting
		-- that killed the new loop and stuck status on "died mid-regen".
		if S.zRegenBusy or S.spawnEgressBusy then
			if not isDefinitelyDead() then
				return -- legitimate regen / egress still running
			end
			S.respawnRegenAbort = true
			S.spawnEgressBusy = false
			if S.respawnResumeWalk or S.proximityResumeWalk then
				S.respawnResumeWalk = true
			end
			U.setStatus("Auto-respawn: died mid-regen — re-clicking Respawn")
			task.wait(0.05)
			S.zRegenBusy = false
		end

		local now = os.clock()
		if now - lastRespawnClickAt < C.RESPAWN_CLICK_COOLDOWN then
			return
		end
		lastRespawnClickAt = now

		-- Resume intent: KA was on, OR prox already froze it, OR a prior death
		-- already armed respawnResumeWalk. Prox often clears S.walking before the
		-- Respawn button appears — without this, neither egress nor KA restart.
		local wantResume = S.walking == true
			or S.proximityResumeWalk == true
			or S.respawnResumeWalk == true
		if wantResume then
			S.respawnResumeWalk = true
			S.walking = false
			S.combatBusy = false
			S.buffBusy = false
			S.waitAllCds = false
			S.holdTarget = nil
			S.resourceRecoverPhase = nil
			if U.releaseMoveKeys then
				U.releaseMoveKeys()
			end
			if S.ui and S.ui.setWalkLabel then
				S.ui.setWalkLabel(false)
			end
			U.setStatus("Auto-respawn: Kill Aura paused — clicking Respawn")
		else
			S.waitAllCds = false
			U.setStatus("Auto-respawn: clicking Respawn")
		end
		if S.Abilities and S.Abilities.clearSyntheticCds then
			S.Abilities.clearSyntheticCds()
		end

		-- New generation invalidates any in-flight post-respawn / regen wait
		S.postRespawnGen = (S.postRespawnGen or 0) + 1
		local gen = S.postRespawnGen
		S.respawnRegenAbort = false

		pcall(function()
			clickGuiButton(btn)
		end)
		task.spawn(function()
			runPostRespawnSequence(gen)
		end)
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

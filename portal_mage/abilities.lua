-- portal_mage/abilities.lua — handlers, quickslot TOGGLE arm, cast
-- ALL combat abilities are toggles: number key arms/disarms (Slot_Select diamond).
-- Cast = arm once if off → settle → fire steps (E / hold E). Never re-press slot key.
-- Standalone: needs Targets for reticle/alive checks. Never freefires.
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local M = {}

	local SLOT_KEY = {
		[1] = Enum.KeyCode.One,
		[2] = Enum.KeyCode.Two,
		[3] = Enum.KeyCode.Three,
		[4] = Enum.KeyCode.Four,
		[5] = Enum.KeyCode.Five,
		[6] = Enum.KeyCode.Six,
		[7] = Enum.KeyCode.Seven,
		[8] = Enum.KeyCode.Eight,
		[9] = Enum.KeyCode.Nine,
	}

	local function T()
		return S.Targets
	end

	local function isWalking(): boolean
		return S.walking == true
	end

	---------------------------------------------------------------------------
	-- QuickSlot UI
	---------------------------------------------------------------------------

	local function getPlayerGui(): PlayerGui?
		local lp = Players.LocalPlayer
		if not lp then
			return nil
		end
		return lp:FindFirstChildOfClass("PlayerGui") or lp:FindFirstChild("PlayerGui")
	end

	function M.getSlotFrame(slot: number): GuiObject?
		local pg = getPlayerGui()
		if not pg then
			return nil
		end
		local ui = pg:FindFirstChild("ThePortalUI")
		local hud = ui and ui:FindFirstChild("HUD")
		local container = hud and hud:FindFirstChild("QuickSlotContainer")
		local frame = container and container:FindFirstChild("QuickSlot" .. tostring(slot))
		if frame and frame:IsA("GuiObject") then
			return frame
		end
		return nil
	end

	M.getQuickSlotFrame = M.getSlotFrame

	-- Every ability slot is a toggle. Slot_Select diamond visible = armed/ON.
	local function guiLooksOn(g: Instance?): boolean
		if not (g and g:IsA("GuiObject")) then
			return false
		end
		if g.Visible ~= true then
			return false
		end
		-- Some builds leave Visible=true and only fade the image
		if g:IsA("ImageLabel") and (g :: ImageLabel).ImageTransparency >= 0.98 then
			return false
		end
		if g:IsA("ImageButton") and (g :: ImageButton).ImageTransparency >= 0.98 then
			return false
		end
		return true
	end

	function M.isSlotOn(slot: number): boolean
		local frame = M.getSlotFrame(slot)
		if not frame then
			return false
		end
		-- Authoritative: Slot_Select (filled diamond). Do NOT OR Slot_Selection —
		-- that marker is often lit for focus/hover and caused false "on" / bad toggles.
		return guiLooksOn(frame:FindFirstChild("Slot_Select"))
	end

	M.isSlotDiamondFilled = M.isSlotOn
	M.isAbilityToggledOn = M.isSlotOn

	local function parseTimerText(text: string): number?
		if type(text) ~= "string" then
			return nil
		end
		local cleaned = string.gsub(text, "%s+", "")
		if cleaned == "" then
			return 0
		end
		local m, s = string.match(cleaned, "^(%d+):(%d+)$")
		if m and s then
			return (tonumber(m) or 0) * 60 + (tonumber(s) or 0)
		end
		return tonumber(cleaned)
	end

	-- UI-only CD (CooldownTimer label). 0 if hidden / unreadable.
	function M.getUiCooldownRemaining(slot: number): number
		local frame = M.getSlotFrame(slot)
		local timer = frame and frame:FindFirstChild("CooldownTimer")
		if not (timer and timer:IsA("TextLabel")) then
			return 0
		end
		if not timer.Visible then
			return 0
		end
		local secs = parseTimerText(timer.Text)
		if secs == nil or secs >= 90 * 60 then
			return 0
		end
		return math.max(0, secs)
	end

	-- Effective CD = max(UI timer, synthetic post-cast floor, overlay hint).
	-- Synthetic covers CooldownTimer lag that used to re-arm and spam toggles.
	function M.getCooldownRemaining(slot: number): number
		local ui = M.getUiCooldownRemaining(slot)
		local syn = 0
		local untilT = S.slotCdUntil and S.slotCdUntil[slot]
		if type(untilT) == "number" then
			syn = math.max(0, untilT - os.clock())
			if syn <= 0.05 then
				S.slotCdUntil[slot] = nil
				syn = 0
			end
		end
		local overlayBump = 0
		local frame = M.getSlotFrame(slot)
		local overlay = frame and frame:FindFirstChild("CooldownOverlay")
		if overlay and overlay:IsA("GuiObject") and overlay.Visible == true then
			if ui < 0.25 and syn < 0.25 then
				overlayBump = 0.45
			end
		end
		return math.max(ui, syn, overlayBump)
	end

	M.getSlotCooldownRemaining = M.getCooldownRemaining

	-- After a cast: remember CD for THIS slot only (no global lockout — other slots stay free).
	function M.noteCastCooldown(slot: number?, handler: any?)
		if type(slot) ~= "number" then
			return
		end
		task.wait(0.2)
		local ui = M.getUiCooldownRemaining(slot)
		local usage = (C.QUICKSLOT_USAGE or {})[slot]
		local usageMin = usage and tonumber(usage.minCd)
		local minCd = (handler and tonumber(handler.minCd)) or usageMin or C.ABILITY_MIN_CD or 0.5
		local lock = C.CAST_LOCKOUT or 0.15
		local rem = math.max(ui, minCd, lock)
		S.slotCdUntil = S.slotCdUntil or {}
		S.slotCdUntil[slot] = os.clock() + rem
		S.lastCastAt = os.clock()
		S.lastCastSlot = slot
	end

	function M.clearSyntheticCds()
		S.slotCdUntil = {}
		S.lastCastAt = 0
		S.lastCastSlot = nil
	end

	function M.isSlotReady(slot: number): boolean
		return M.getCooldownRemaining(slot) <= 0.35
	end

	function M.isHandlerReady(handler): boolean
		if not handler or not handler.slot then
			return false
		end
		-- ON-diamond does not mean ready — CD can still be running
		return M.isSlotReady(handler.slot)
	end

	-- Combat slots from QUICKSLOT_USAGE + DEFAULT (no creature map, no QS3).
	function M.combatSlots(): { number }
		local seen = {}
		local out = {}
		local function add(s: any)
			local n = tonumber(s)
			if type(n) == "number" and n >= 1 and n <= 9 and not seen[n] then
				seen[n] = true
				table.insert(out, n)
			end
		end
		add(C.DEFAULT_COMBAT_SLOT or 4)
		for slot, _ in pairs(C.QUICKSLOT_USAGE or {}) do
			add(slot)
		end
		table.sort(out)
		return out
	end

	-- Slots that currently matter for post-kill wait (active CDs / last cast).
	function M.activeCooldownSlots(): { number }
		if C.WAIT_CDS_ONLY_ACTIVE == false then
			return M.combatSlots()
		end
		local seen = {}
		local out = {}
		local function add(slot: number?)
			if type(slot) == "number" and not seen[slot] then
				seen[slot] = true
				table.insert(out, slot)
			end
		end
		add(S.lastCastSlot)
		for _, slot in ipairs(M.combatSlots()) do
			if M.getCooldownRemaining(slot) > 0.35 then
				add(slot)
			end
		end
		if #out == 0 then
			return M.combatSlots()
		end
		return out
	end

	-- True when relevant combat CDs are ready (reloop after kill).
	function M.allCombatCdsReady(): boolean
		for _, slot in ipairs(M.activeCooldownSlots()) do
			if M.getCooldownRemaining(slot) > 0.35 then
				return false
			end
		end
		return true
	end

	function M.maxCombatCdRemaining(): number
		local best = 0
		for _, slot in ipairs(M.activeCooldownSlots()) do
			local r = M.getCooldownRemaining(slot)
			if r > best then
				best = r
			end
		end
		return best
	end

	---------------------------------------------------------------------------
	-- Handlers = quickslot + QUICKSLOT_USAGE steps (no creature schemas)
	---------------------------------------------------------------------------

	-- Build a castable handler from slot (+ optional steps override).
	function M.handlerForSlot(slot: number, match: string?, stepsOverride: any?): any
		local usage = (C.QUICKSLOT_USAGE or {})[slot]
		local steps = stepsOverride
		if type(steps) ~= "table" and usage and type(usage.steps) == "table" then
			steps = usage.steps
		end
		if type(steps) ~= "table" then
			steps = { { key = Enum.KeyCode.E } }
		end
		local minCd = usage and tonumber(usage.minCd) or nil
		return {
			id = string.format("s%d", slot), -- display / CD label only
			slot = slot,
			match = match,
			steps = steps,
			minCd = minCd,
		}
	end

	-- Prefer DEFAULT_COMBAT_SLOT when ready; else any ready combat slot (QS1);
	-- else DEFAULT so combat can wait on its CD. Never uses QS3.
	function M.pickCombatHandler(): any
		local def = C.DEFAULT_COMBAT_SLOT or 4
		local slots = M.combatSlots()
		if M.isSlotReady(def) then
			return M.handlerForSlot(def, nil, nil)
		end
		local bestSlot: number? = nil
		local bestRem = math.huge
		for _, slot in ipairs(slots) do
			local rem = M.getCooldownRemaining(slot)
			if rem <= 0.35 then
				return M.handlerForSlot(slot, nil, nil)
			end
			if rem < bestRem then
				bestRem = rem
				bestSlot = slot
			end
		end
		return M.handlerForSlot(bestSlot or def, nil, nil)
	end

	-- Any living mob: same combat (path nearest + s4 hold / s1 tap). Model only for API compat.
	function M.findHandler(model: Model?)
		if not model then
			return nil
		end
		return M.pickCombatHandler()
	end

	M.findHandlerForModel = M.findHandler

	-- id is "s1"…"s4" (slot id). Legacy "meteor"/"aqua" map to slot 1 / default.
	function M.getById(id: string)
		if type(id) ~= "string" then
			return nil
		end
		local n = string.match(id, "^s(%d+)$") or string.match(id, "^slot(%d+)$")
		if n then
			return M.handlerForSlot(tonumber(n) :: number, nil, nil)
		end
		-- Legacy aliases (pre-slot-only config)
		if id == "meteor" or id == "aurora" then
			return M.handlerForSlot(1, nil, nil)
		end
		if id == "aqua" or id == "holywounds" or id == "holy_wounds" then
			return M.handlerForSlot(C.DEFAULT_COMBAT_SLOT or 4, nil, nil)
		end
		return nil
	end

	function M.getDefaultHandler()
		return M.handlerForSlot(C.DEFAULT_COMBAT_SLOT or 4, nil, nil)
	end

	-- Compat aliases (old names → default / slot 1)
	function M.getAquaHandler()
		return M.getDefaultHandler()
	end

	function M.getMeteorHandler()
		return M.handlerForSlot(1, nil, nil)
	end

	-- Always combat handler for a model (creature schemas removed).
	function M.resolve(model: Model, useDefault: boolean?)
		local h = M.findHandler(model)
		if h then
			return h
		end
		if useDefault then
			return M.getDefaultHandler()
		end
		return nil
	end

	M.resolveHandlerForModel = M.resolve

	function M.formatCds(): string
		local parts = {}
		for _, slot in ipairs(M.combatSlots()) do
			local on = if M.isSlotOn(slot) then "on" else "off"
			table.insert(parts, string.format("s%d %.0f %s", slot, M.getCooldownRemaining(slot), on))
		end
		return table.concat(parts, " | ")
	end

	M.formatHandlerCds = function(_now)
		return M.formatCds()
	end

	---------------------------------------------------------------------------
	-- Arm toggle ON (key only — never mouse). Already ON → do nothing.
	-- EVERY ability is a toggle: one press arms, a second press disarms.
	-- Never press the slot key twice in one ensure (UI lag → off→on→off).
	---------------------------------------------------------------------------

	function M.ensureSlotOn(slot: number): boolean
		if M.isSlotOn(slot) then
			return true
		end
		local key = SLOT_KEY[slot]
		if not key then
			return false
		end
		if U.releaseMoveKeys then
			U.releaseMoveKeys()
		end
		U.setStatus(string.format("[cast] toggle-arm slot %d (%s)…", slot, key.Name))
		U.pressKey(key)
		local waitFor = C.SLOT_SELECT_WAIT or 0.55
		local t0 = os.clock()
		while os.clock() - t0 < waitFor and isWalking() do
			if M.isSlotOn(slot) then
				return true
			end
			task.wait(0.04)
		end
		-- Still dark: do NOT second-toggle. Fire E anyway; diamond can lag.
		return M.isSlotOn(slot)
	end

	M.selectAbilitySlot = M.ensureSlotOn

	---------------------------------------------------------------------------
	-- Fire steps only. Slot arming is exclusively ensureSlotOn(handler.slot).
	---------------------------------------------------------------------------

	local function isHotbarKey(key: Enum.KeyCode): boolean
		for _, k in pairs(SLOT_KEY) do
			if k == key then
				return true
			end
		end
		return false
	end

	local function runSteps(handler): boolean
		-- 1) Toggle-arm via handler.slot (all abilities)
		if handler.slot then
			local armed = M.ensureSlotOn(handler.slot)
			task.wait(C.SLOT_FIRE_SETTLE or 0.12)
			if not armed and not M.isSlotOn(handler.slot) then
				U.setStatus(string.format(
					"[cast] slot %d still off after arm — firing anyway",
					handler.slot
				))
			end
		end
		if U.releaseMoveKeys then
			U.releaseMoveKeys()
		end
		-- 2) Fire / channel only — never hotbar (would toggle OFF)
		for _, step in ipairs(handler.steps or {}) do
			if not isWalking() then
				return false
			end
			if step.hold then
				U.setStatus(string.format(
					"[cast] HOLD %s %.1fs",
					tostring(step.hold.Name),
					step.duration or C.HOLD_DURATION or 5
				))
				U.holdKeyCharge(step.hold, isWalking, step.duration or C.HOLD_DURATION or 5)
			elseif step.key then
				if isHotbarKey(step.key) then
					-- Legacy configs may still list One/Four in steps — skip always
					continue
				end
				U.setStatus(string.format("[cast] press %s", tostring(step.key.Name)))
				U.pressKey(step.key)
				task.wait(C.SHORT_DELAY or 0.18)
			end
		end
		return isWalking()
	end

	---------------------------------------------------------------------------
	-- Cast: living target + reticle on it + handler. No freefire.
	---------------------------------------------------------------------------

	function M.cast(model: Model, handler, tag: string?): boolean
		local Targets = T()
		if not Targets or not Targets.isAlive(model) then
			return false
		end
		if not Targets.hasReticleOn(model) then
			U.setStatus(string.format(
				"No cast — reticle not on %s [%s]",
				model.Name,
				tag or "?"
			))
			return false
		end
		if not handler then
			return false
		end

		S.combatBusy = true
		if U.releaseMoveKeys then
			U.releaseMoveKeys()
		end
		local pos = U.getCharacterLikePosition(model)
		local playerPos = U.getLivePlayerVector()
		local dist = if pos and playerPos then (pos - playerPos).Magnitude else -1
		local ok, err = pcall(function()
			U.setStatus(string.format(
				"CAST %s → %s %.1fst [%s]",
				handler.id,
				model.Name,
				dist,
				tag or ""
			))
			runSteps(handler)
		end)
		if not ok then
			U.setStatus("Cast error: " .. tostring(err))
		end
		if not Targets.isAlive(model) and Targets.clearHold then
			Targets.clearHold("post_cast_dead")
		end
		-- Synthetic + UI CD so we never re-arm while timer is still catching up
		if ok then
			M.noteCastCooldown(handler.slot, handler)
		else
			S.lastCastAt = os.clock()
		end
		S.combatBusy = false
		return ok == true
	end

	return M
end

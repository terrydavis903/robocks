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

	function M.getCooldownRemaining(slot: number): number
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

	M.getSlotCooldownRemaining = M.getCooldownRemaining

	function M.isSlotReady(slot: number): boolean
		return M.getCooldownRemaining(slot) <= 0
	end

	function M.isHandlerReady(handler): boolean
		if not handler or not handler.slot then
			return false
		end
		return M.isSlotReady(handler.slot) or M.isSlotOn(handler.slot)
	end

	-- Unique slots used by COMBAT_HANDLERS (meteor 1, aqua 4, …)
	function M.combatSlots(): { number }
		local seen = {}
		local out = {}
		for _, h in ipairs(C.COMBAT_HANDLERS or {}) do
			local s = h.slot
			if type(s) == "number" and not seen[s] then
				seen[s] = true
				table.insert(out, s)
			end
		end
		return out
	end

	-- True when every combat-schema slot is off cooldown (ready to reloop).
	function M.allCombatCdsReady(): boolean
		for _, slot in ipairs(M.combatSlots()) do
			if M.getCooldownRemaining(slot) > 0.35 then
				return false
			end
		end
		return true
	end

	function M.maxCombatCdRemaining(): number
		local best = 0
		for _, slot in ipairs(M.combatSlots()) do
			local r = M.getCooldownRemaining(slot)
			if r > best then
				best = r
			end
		end
		return best
	end

	---------------------------------------------------------------------------
	-- Handlers (combat schematics)
	---------------------------------------------------------------------------

	function M.findHandler(model: Model)
		for _, handler in ipairs(C.COMBAT_HANDLERS or {}) do
			if string.find(model.Name, handler.match, 1, true) then
				return handler
			end
		end
		return nil
	end

	M.findHandlerForModel = M.findHandler

	function M.getById(id: string)
		for _, handler in ipairs(C.COMBAT_HANDLERS or {}) do
			if handler.id == id then
				return handler
			end
		end
		return nil
	end

	function M.getAquaHandler()
		return M.getById("aqua")
	end

	function M.getMeteorHandler()
		return M.getById("meteor")
	end

	-- Handler for model; if useDefaultAqua and unmatched, first aqua schematic.
	function M.resolve(model: Model, useDefaultAqua: boolean?)
		local h = M.findHandler(model)
		if h then
			return h
		end
		if useDefaultAqua then
			return M.getAquaHandler()
		end
		return nil
	end

	M.resolveHandlerForModel = M.resolve

	function M.formatCds(): string
		local parts = {}
		local seen = {}
		for _, h in ipairs(C.COMBAT_HANDLERS or {}) do
			if not seen[h.id] then
				seen[h.id] = true
				local on = if M.isSlotOn(h.slot) then "on" else "off"
				table.insert(parts, string.format("%s %.0f %s", h.id, M.getCooldownRemaining(h.slot), on))
			end
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
					step.duration or C.HOLD_DURATION or 6
				))
				U.holdKeyCharge(step.hold, isWalking, step.duration or C.HOLD_DURATION)
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
		-- Post-cast lockout: CooldownTimer often lags 0.3–1s after E; without this
		-- combat re-enters cast and re-toggles 1/4 before CD UI updates.
		S.lastCastAt = os.clock()
		S.combatBusy = false
		return ok == true
	end

	return M
end

-- portal_mage/abilities.lua — handlers, quickslot toggle (keys 1–4), cast
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

	-- Keys 1–4 toggle; Slot_Select visible = ON
	function M.isSlotOn(slot: number): boolean
		local frame = M.getSlotFrame(slot)
		if not frame then
			return false
		end
		local filled = frame:FindFirstChild("Slot_Select")
		if filled and filled:IsA("GuiObject") then
			return filled.Visible == true
		end
		return false
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
	-- Toggle slot ON (key only — never mouse). Already ON → do nothing.
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
		U.pressKey(key)
		local waitFor = C.SLOT_SELECT_WAIT or 0.35
		local t0 = os.clock()
		while os.clock() - t0 < waitFor and isWalking() do
			if M.isSlotOn(slot) then
				return true
			end
			task.wait(0.04)
		end
		-- One more toggle attempt only if still off
		if not M.isSlotOn(slot) and isWalking() then
			U.pressKey(key)
			task.wait(0.15)
		end
		return M.isSlotOn(slot)
	end

	M.selectAbilitySlot = M.ensureSlotOn

	---------------------------------------------------------------------------
	-- Run handler steps (fire only — slot toggle handled separately)
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
		if handler.slot then
			M.ensureSlotOn(handler.slot)
		end
		if U.releaseMoveKeys then
			U.releaseMoveKeys()
		end
		for _, step in ipairs(handler.steps or {}) do
			if not isWalking() then
				return false
			end
			if step.hold then
				U.holdKeyCharge(step.hold, isWalking, step.duration or C.HOLD_DURATION)
			elseif step.key then
				if isHotbarKey(step.key) then
					continue -- already toggled
				end
				U.pressKey(step.key)
				task.wait(C.SHORT_DELAY or 0.15)
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
		S.combatBusy = false
		return ok == true
	end

	return M
end

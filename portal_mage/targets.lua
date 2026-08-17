-- portal_mage/targets.lua — living mobs, reticle, hold, nearest pick
-- Standalone. No casting / no walking.
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local M = {}

	function M.scanRange(): number
		return C.KILL_AURA_SCAN or 250
	end

	-- Fight stand-off (pathing approaches to this, combat casts inside band).
	function M.fightRange(): number
		return C.KILL_AURA_RANGE or C.KILL_AURA_APPROACH or 30
	end

	M.approachRange = M.fightRange

	---------------------------------------------------------------------------
	-- Alive
	---------------------------------------------------------------------------

	function M.isAlive(model: Model?): boolean
		if not model then
			return false
		end
		local okP, parent = pcall(function()
			return model.Parent
		end)
		if not okP or parent == nil then
			return false
		end
		local okF, full = pcall(function()
			return model:GetFullName()
		end)
		if okF and type(full) == "string" and string.find(full, "Mobs", 1, true) then
			if not string.find(full, "Mobs.Active", 1, true) then
				return false
			end
		end
		local hum = model:FindFirstChildOfClass("Humanoid")
			or model:FindFirstChildWhichIsA("Humanoid", true)
		if hum then
			if hum.Health <= 0 then
				return false
			end
			local okS, st = pcall(function()
				return hum:GetState()
			end)
			if okS and st == Enum.HumanoidStateType.Dead then
				return false
			end
		end
		local dead = nil
		pcall(function()
			dead = model:GetAttribute("Dead") or model:GetAttribute("IsDead")
		end)
		if dead == true then
			return false
		end
		return true
	end

	M.isModelAlive = M.isAlive

	function M.getNameLabelColor(model: Model): Color3?
		local overhead = model:FindFirstChild("OverheadHud") or model:FindFirstChild("OverheadHUD")
		local label = overhead and overhead:FindFirstChild("NameLabel", true)
		if label and label:IsA("TextLabel") then
			return label.TextColor3
		end
		return nil
	end

	function M.isAggro(model: Model?): boolean
		if not model then
			return false
		end
		local c = M.getNameLabelColor(model)
		if not c then
			return false
		end
		if c.R >= 0.85 and c.G >= 0.85 and c.B >= 0.85 then
			return false
		end
		if c.R > c.G + 0.05 then
			return true
		end
		if c.R >= 0.55 and c.R > c.B + 0.10 and c.R >= c.G then
			return true
		end
		return false
	end

	M.isMobAggro = M.isAggro

	function M.dist(model: Model, fromPos: Vector3?): number?
		local origin = fromPos or U.getLivePlayerVector()
		local pos = U.getCharacterLikePosition(model)
		if not pos or not origin then
			return nil
		end
		return (pos - origin).Magnitude
	end

	M.distToModel = M.dist

	---------------------------------------------------------------------------
	-- List / snapshot
	---------------------------------------------------------------------------

	function M.listActive(): { Model }
		local out = {}
		local mobs = workspace:FindFirstChild("Mobs")
		local active = mobs and mobs:FindFirstChild("Active")
		if not active then
			return out
		end
		for _, child in ipairs(active:GetChildren()) do
			if child:IsA("Model") and M.isAlive(child) then
				table.insert(out, child)
			end
		end
		return out
	end

	M.listActiveMobs = M.listActive

	function M.snapshot(playerPos: Vector3?, maxRange: number?): { any }
		local origin = playerPos or U.getLivePlayerVector()
		local cap = maxRange or M.scanRange()
		local out = {}
		if not origin then
			return out
		end
		for _, model in ipairs(M.listActive()) do
			local pos = U.getCharacterLikePosition(model)
			if pos then
				local d = (pos - origin).Magnitude
				if d <= cap then
					table.insert(out, {
						model = model,
						pos = pos,
						dist = d,
						aggro = M.isAggro(model),
					})
				end
			end
		end
		table.sort(out, function(a, b)
			return a.dist < b.dist
		end)
		return out
	end

	function M.listAggro(maxRange: number?): { Model }
		local out = {}
		for _, e in ipairs(M.snapshot(nil, maxRange)) do
			if e.aggro then
				table.insert(out, e.model)
			end
		end
		return out
	end

	M.listAggroMobs = M.listAggro

	function M.closestAggro(fromPos: Vector3?, maxRange: number?): Model?
		for _, e in ipairs(M.snapshot(fromPos, maxRange)) do
			if e.aggro then
				return e.model
			end
		end
		return nil
	end

	M.getClosestAggroMob = M.closestAggro

	function M.closest(fromPos: Vector3?, maxRange: number?): Model?
		local snap = M.snapshot(fromPos, maxRange)
		return if #snap > 0 then snap[1].model else nil
	end

	M.getClosestMob = function(from, r, _)
		return M.closest(from, r)
	end

	---------------------------------------------------------------------------
	-- Hold
	---------------------------------------------------------------------------

	function M.clearHold(_reason: string?)
		S.holdTarget = nil
	end

	M.clearHoldTarget = M.clearHold

	---------------------------------------------------------------------------
	-- Height gate: enemies far above us (cliff/roof) — don't path/fight them.
	-- Threshold = MULT × floor→Clear Hitbox center height (Nav measure; fallback 3).
	---------------------------------------------------------------------------

	local tooHighIgnore: { [Model]: number } = {} -- model → os.clock until

	function M.clearHitboxFloorHeight(): number
		local fallback = C.KILL_AURA_HITBOX_HEIGHT_FALLBACK or 3.0
		if S.Nav and S.Nav.playerHitboxCenterHeight then
			local ok, h = pcall(function()
				return S.Nav.playerHitboxCenterHeight()
			end)
			if ok and type(h) == "number" and h > 0.5 and h < 20 then
				return h
			end
		end
		return fallback
	end

	-- Max enemy.Y - player.Y we will engage (only ABOVE; drops are fine).
	function M.maxEngageDyAbove(): number
		local mult = C.KILL_AURA_MAX_DY_MULT or 3
		return mult * M.clearHitboxFloorHeight()
	end

	function M.dyAbovePlayer(model: Model?, playerPos: Vector3?): number?
		if not model then
			return nil
		end
		local origin = playerPos or U.getLivePlayerVector()
		local epos = U.getCharacterLikePosition(model)
		if not origin or not epos then
			return nil
		end
		return epos.Y - origin.Y
	end

	function M.isTooHigh(model: Model?, playerPos: Vector3?): boolean
		local dy = M.dyAbovePlayer(model, playerPos)
		if dy == nil then
			return false
		end
		return dy > M.maxEngageDyAbove()
	end

	function M.markTooHighIgnore(model: Model?)
		if not model then
			return
		end
		local sec = C.KILL_AURA_TOO_HIGH_IGNORE or 12
		tooHighIgnore[model] = os.clock() + sec
	end

	function M.isTooHighIgnored(model: Model?): boolean
		if not model then
			return false
		end
		local untilT = tooHighIgnore[model]
		if not untilT then
			return false
		end
		if os.clock() >= untilT then
			tooHighIgnore[model] = nil
			return false
		end
		return true
	end

	-- Hold R to release reticle, clear hold, ignore height for a while.
	function M.releaseReticleTooHigh(model: Model?, why: string?): boolean
		if not model then
			return false
		end
		local dy = M.dyAbovePlayer(model)
		local maxDy = M.maxEngageDyAbove()
		local h = M.clearHitboxFloorHeight()
		M.markTooHighIgnore(model)
		if S.holdTarget == model then
			M.clearHold(why or "too_high")
		end
		local holdFor = C.KILL_AURA_RETICLE_RELEASE_HOLD or 0.4
		if U.holdKeyCharge then
			U.holdKeyCharge(Enum.KeyCode.R, function()
				return S.walking == true
			end, holdFor)
		elseif U.pressKey then
			U.pressKey(Enum.KeyCode.R)
		end
		if U.setStatus then
			U.setStatus(string.format(
				"[target] R-release too high dY=+%.0f (max +%.0f = %d×%.1f hitbox) %s",
				dy or 0,
				maxDy,
				C.KILL_AURA_MAX_DY_MULT or 3,
				h,
				model.Name
			))
		end
		return true
	end

	function M.getHold(): Model?
		local t = S.holdTarget
		if t and M.isAlive(t) then
			-- Drop unreachable high holds so pathing doesn't chase roofs
			if M.isTooHigh(t) then
				M.clearHold("hold_too_high")
				return nil
			end
			return t
		end
		if t then
			S.holdTarget = nil
		end
		return nil
	end

	M.getHoldTarget = M.getHold

	function M.setHold(model: Model?, _reason: string?)
		if model and not M.isAlive(model) then
			S.holdTarget = nil
			return
		end
		S.holdTarget = model
	end

	M.setHoldTarget = M.setHold

	---------------------------------------------------------------------------
	-- Reticle
	---------------------------------------------------------------------------

	local function getPlayerGui(): PlayerGui?
		local lp = Players.LocalPlayer
		if not lp then
			return nil
		end
		return lp:FindFirstChildOfClass("PlayerGui") or lp:FindFirstChild("PlayerGui")
	end

	local function modelFromAdornee(inst: Instance?): Model?
		local cur = inst
		local first: Model? = nil
		while cur do
			if cur:IsA("Model") then
				if not first then
					first = cur
				end
				if string.find(cur.Name, "Monster_", 1, true) then
					return cur
				end
				if cur.Parent and cur.Parent.Name == "Active" then
					return cur
				end
			end
			cur = cur.Parent
		end
		return first
	end

	function M.getReticle(): Model?
		local pg = getPlayerGui()
		if not pg then
			return nil
		end
		local name = C.RETICLE_PATH or "TargetLockReticle"
		local reticle = pg:FindFirstChild(name)
		if not reticle then
			reticle = pg:FindFirstChild(name, true) -- recursive
		end
		if not (reticle and reticle:IsA("BillboardGui")) then
			return nil
		end
		return modelFromAdornee((reticle :: BillboardGui).Adornee)
	end

	M.getReticleTargetModel = M.getReticle

	function M.getReticleLiving(): Model?
		local r = M.getReticle()
		if not r then
			return nil
		end
		-- Prefer living root; reticle may adornee a child model without Humanoid
		if M.isAlive(r) then
			return r
		end
		local cur: Instance? = r
		while cur do
			if cur:IsA("Model") and M.isAlive(cur) then
				return cur :: Model
			end
			cur = cur.Parent
		end
		return r -- still return for name matching
	end

	function M.reticleOn(hold: Model?, reticle: Model?): boolean
		if not hold or not reticle then
			return false
		end
		if reticle == hold or reticle.Name == hold.Name then
			return true
		end
		local ok, desc = pcall(function()
			return reticle:IsDescendantOf(hold) or hold:IsDescendantOf(reticle)
		end)
		if ok and desc then
			return true
		end
		local function rootMonster(m: Model): Model?
			local cur: Instance? = m
			while cur do
				if cur:IsA("Model") and string.find(cur.Name, "Monster_", 1, true) then
					return cur :: Model
				end
				cur = cur.Parent
			end
			return nil
		end
		local rh, rr = rootMonster(hold), rootMonster(reticle)
		if rh and rr and (rh == rr or rh.Name == rr.Name) then
			return true
		end
		-- Fuzzy: shared name token (PatchHound etc.)
		local hn = hold.Name
		local rn = reticle.Name
		if string.find(rn, hn, 1, true) or string.find(hn, rn, 1, true) then
			return true
		end
		return false
	end

	M.reticleLocksModel = M.reticleOn

	function M.hasReticleOn(model: Model?): boolean
		if not model or not M.isAlive(model) then
			return false
		end
		local r = M.getReticle()
		if not r then
			return false
		end
		return M.reticleOn(model, r)
	end

	---------------------------------------------------------------------------
	-- Pick: schema matches preferred, then optional name priority, then nearest
	---------------------------------------------------------------------------

	-- Optional ordered name keys in C.KILL_AURA_PRIORITY (lower index = better).
	-- Empty table → pure distance among schema (or all) mobs.
	function M.killAuraPriority(model: Model?): number
		if not model then
			return 999
		end
		local pri = C.KILL_AURA_PRIORITY or {}
		for i, key in ipairs(pri) do
			if type(key) == "string" and key ~= "" and string.find(model.Name, key, 1, true) then
				return i
			end
		end
		return 100 + #pri
	end

	-- Closest useful enemy by KILL_AURA_PRIORITY then dist.
	-- Creature-specific combat schemas removed — every living mob is fair game.
	function M.pickEnemy(playerPos: Vector3?, _preferHandler: boolean?): (Model?, Vector3?, number?)
		local origin = playerPos or U.getLivePlayerVector()
		if not origin then
			return nil, nil, nil
		end
		local snaps = M.snapshot(origin, M.scanRange())
		if #snaps == 0 then
			return nil, nil, nil
		end

		-- Drop ignored / too-high (above) targets before ranking
		local filtered = {}
		for _, e in ipairs(snaps) do
			if not M.isTooHighIgnored(e.model) and not M.isTooHigh(e.model, origin) then
				table.insert(filtered, e)
			end
		end
		if #filtered == 0 then
			return nil, nil, nil
		end

		table.sort(filtered, function(a, b)
			local pa = M.killAuraPriority(a.model)
			local pb = M.killAuraPriority(b.model)
			if pa ~= pb then
				return pa < pb
			end
			return a.dist < b.dist
		end)

		local best = filtered[1]
		return best.model, best.pos, best.dist
	end

	-- Keep hold if alive; switch if another pick is clearly closer (or higher priority).
	-- Soften sticky when hold is far (no reticle until stand band) so we don't lock
	-- an unreachable Critter while nearer mobs exist (astar 02-56-00: Goblin_1898).
	function M.ensureEnemy(): (Model?, Vector3?, number?)
		local origin = U.getLivePlayerVector()
		local hold = M.getHold()
		local pick, ppos, pdist = M.pickEnemy(origin, true)

		if hold and M.isAlive(hold) then
			-- Height gate (getHold may already drop; re-check for race)
			if M.isTooHigh(hold, origin) then
				M.clearHold("hold_too_high")
				hold = nil
			end
		end

		if hold and M.isAlive(hold) then
			local hpos = U.getCharacterLikePosition(hold)
			local hd = if hpos and origin then (hpos - origin).Magnitude else M.dist(hold, origin)
			if pick and pick ~= hold and pdist and hd then
				local hp = M.killAuraPriority(hold)
				local pp = M.killAuraPriority(pick)
				local sticky = C.KILL_AURA_HOLD_STICKY or 8
				-- Far holds switch easier (4 studs); close holds keep 8-stud hysteresis
				if hd > (C.KILL_AURA_RANGE or 30) + 20 then
					sticky = 4
				end
				if pp < hp or (pp == hp and pdist < hd - sticky) then
					M.setHold(pick, "better")
					return pick, ppos, pdist
				end
			end
			-- Dead / missing position: drop
			if not hpos and not hd then
				M.clearHold("hold_no_pos")
			else
				return hold, hpos, hd
			end
		end

		M.clearHold("ensure_pick")
		if pick then
			M.setHold(pick, "pick")
		end
		return pick, ppos, pdist
	end

	return M
end

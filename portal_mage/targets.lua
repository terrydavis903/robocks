-- portal_mage/targets.lua — living mobs, reticle, hold, shortest-path pick
-- Standalone. No casting / no walking.
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local M = {}

	function M.scanRange(): number
		return C.KILL_AURA_SCAN or 250
	end

	-- Fight range: approach to this, never stand closer.
	function M.fightRange(): number
		return C.KILL_AURA_RANGE or C.KILL_AURA_APPROACH or 30
	end

	M.kiteRange = M.fightRange
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

	function M.getHold(): Model?
		local t = S.holdTarget
		if t and M.isAlive(t) then
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
	-- Shortest path pick
	---------------------------------------------------------------------------

	local function pathLength(from: Vector3, to: Vector3): number?
		local nav = S.Nav
		if not nav or not nav.findPath then
			return (Vector3.new(to.X - from.X, 0, to.Z - from.Z)).Magnitude
		end
		local path = nav.findPath(from, to)
		if not path or #path == 0 then
			return nil
		end
		local len = 0
		local prev = from
		for _, p in ipairs(path) do
			len += (p - prev).Magnitude
			prev = p
		end
		return len
	end

	-- Prefer true nearest (euclidean). Light path tie-break only among near-equals.
	function M.pickShortestPath(playerPos: Vector3, snaps: { any }): any?
		if #snaps == 0 then
			return nil
		end
		-- snaps already sorted by dist — default to snaps[1]
		local maxCheck = math.min(C.KILL_AURA_PATH_CANDIDATES or 5, #snaps)
		local best, bestLen = snaps[1], snaps[1].dist
		best.pathLen = bestLen
		for i = 2, maxCheck do
			local e = snaps[i]
			-- Only contest nearest if within 15 studs of it
			if (e.dist - snaps[1].dist) > 15 then
				break
			end
			local len = e.dist
			if e.dist <= 90 then
				local pl = pathLength(playerPos, e.pos)
				if pl then
					len = pl
				end
			end
			e.pathLen = len
			if len < bestLen then
				bestLen = len
				best = e
			end
		end
		if best == snaps[1] and snaps[1].dist <= 90 then
			local pl = pathLength(playerPos, snaps[1].pos)
			if pl then
				best.pathLen = pl
			end
		end
		return best
	end

	-- Closest enemy in scan. Prefer combat-schema matches (still nearest among those).
	function M.pickEnemy(playerPos: Vector3?, preferHandler: boolean?): (Model?, Vector3?, number?)
		local origin = playerPos or U.getLivePlayerVector()
		if not origin then
			return nil, nil, nil
		end
		local snaps = M.snapshot(origin, M.scanRange())
		if #snaps == 0 then
			return nil, nil, nil
		end

		local pool = snaps
		if preferHandler ~= false and S.Abilities and S.Abilities.findHandler then
			local withSchema = {}
			for _, e in ipairs(snaps) do
				if S.Abilities.findHandler(e.model) then
					table.insert(withSchema, e)
				end
			end
			if #withSchema > 0 then
				pool = withSchema
			end
		end

		local best = M.pickShortestPath(origin, pool)
		if not best then
			return nil, nil, nil
		end
		return best.model, best.pos, best.dist
	end

	-- Keep hold if alive, but switch if another schema mob is clearly closer
	-- (fixes walking past the nearest enemy after a kill / sticky far hold).
	function M.ensureEnemy(): (Model?, Vector3?, number?)
		local origin = U.getLivePlayerVector()
		local hold = M.getHold()
		local pick, ppos, pdist = M.pickEnemy(origin, true)

		if hold and M.isAlive(hold) then
			local hpos = U.getCharacterLikePosition(hold)
			local hd = if hpos and origin then (hpos - origin).Magnitude else M.dist(hold, origin)
			if pick and pick ~= hold and pdist and hd and pdist < hd - 8 then
				M.setHold(pick, "closer")
				return pick, ppos, pdist
			end
			return hold, hpos, hd
		end

		M.clearHold("ensure_pick")
		if pick then
			M.setHold(pick, "pick")
		end
		return pick, ppos, pdist
	end

	function M.killAuraPriority(model: Model?): number
		if not model then
			return 999
		end
		local pri = C.KILL_AURA_PRIORITY or {}
		for i, key in ipairs(pri) do
			if string.find(model.Name, key, 1, true) then
				return i
			end
		end
		return 100 + #pri
	end

	return M
end

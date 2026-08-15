-- portal_mage/util.lua
return function(S)
	local C = S.Config
	local VIM = S.Services.VirtualInputManager
	local Players = S.Services.Players
	local M = {}

	function M.setStatus(text: string)
		S.ui.setStatus(text)
	end

	function M.pressKey(keyCode: Enum.KeyCode)
		-- Full down/up with settle so hotbar binds register (ability select 1/4, fire E)
		pcall(function()
			VIM:SendKeyEvent(true, keyCode, false, game)
		end)
		task.wait(0.06)
		pcall(function()
			VIM:SendKeyEvent(false, keyCode, false, game)
		end)
		task.wait(0.03)
	end

	function M.holdKeyCharge(
		keyCode: Enum.KeyCode,
		isStillRunning: () -> boolean,
		duration: number?
	)
		local holdFor = duration or C.HOLD_DURATION
		pcall(function()
			VIM:SendKeyEvent(true, keyCode, false, game)
		end)
		local elapsed = 0
		while elapsed < holdFor do
			if not isStillRunning() then
				break
			end
			local slice = math.min(0.1, holdFor - elapsed)
			task.wait(slice)
			elapsed += slice
		end
		pcall(function()
			VIM:SendKeyEvent(false, keyCode, false, game)
		end)
	end

	-- Click a GuiButton: firesignal + Activate + real mouse (same path as respawn).
	function M.clickGuiButton(btn: GuiButton)
		if not btn then
			return
		end
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
		local GuiService = S.Services.GuiService
		local inset = Vector2.zero
		pcall(function()
			inset = GuiService:GetGuiInset()
		end)
		local pos = btn.AbsolutePosition
		local size = btn.AbsoluteSize
		local x = pos.X + size.X * 0.5
		local y = pos.Y + size.Y * 0.5 + inset.Y
		pcall(function()
			VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
		end)
		task.wait(0.04)
		pcall(function()
			VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
		end)
	end

	---------------------------------------------------------------------------
	-- Walk move keys. With a reticle/enemy lock the body always faces the target,
	-- so we never try to "turn then W" — WASD is computed in reticle-facing space:
	--   W/S = along face axis, A/D = strafe, diagonals = two keys held.
	---------------------------------------------------------------------------

	local MOVE_KEYS = {
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
	}
	-- Free-path yaw when CFrame face is ignored by the game (no RMB camera drag)
	local TURN_KEYS = {
		Enum.KeyCode.Left,
		Enum.KeyCode.Right,
	}
	local heldMoveKeys: { [Enum.KeyCode]: boolean } = {}
	local heldTurnKey: Enum.KeyCode? = nil

	local function keyUp(k: Enum.KeyCode)
		pcall(function()
			VIM:SendKeyEvent(false, k, false, game)
		end)
	end

	local function keyDown(k: Enum.KeyCode)
		pcall(function()
			VIM:SendKeyEvent(true, k, false, game)
		end)
	end

	function M.releaseTurnKeys()
		for _, k in ipairs(TURN_KEYS) do
			keyUp(k)
		end
		heldTurnKey = nil
	end

	-- Hold Left or Right arrow (or nil = release). Used to yaw character for path follow.
	function M.holdTurnKey(key: Enum.KeyCode?)
		if key ~= Enum.KeyCode.Left and key ~= Enum.KeyCode.Right then
			key = nil
		end
		if key == heldTurnKey then
			return
		end
		if heldTurnKey then
			keyUp(heldTurnKey)
			heldTurnKey = nil
		end
		if key then
			keyDown(key)
			heldTurnKey = key
		end
	end

	function M.releaseMoveKeys()
		for _, k in ipairs(MOVE_KEYS) do
			if heldMoveKeys[k] then
				keyUp(k)
			end
			-- Always send up for safety (covers desync)
			keyUp(k)
			heldMoveKeys[k] = nil
		end
		M.releaseTurnKeys()
	end

	-- Hold exactly the given set of WASD keys (nil/empty = release all).
	function M.holdMoveKeys(keys: { Enum.KeyCode }?)
		local want: { [Enum.KeyCode]: boolean } = {}
		if type(keys) == "table" then
			for _, k in ipairs(keys) do
				if k == Enum.KeyCode.W or k == Enum.KeyCode.A or k == Enum.KeyCode.S or k == Enum.KeyCode.D then
					want[k] = true
				end
			end
		end
		for _, k in ipairs(MOVE_KEYS) do
			local should = want[k] == true
			local isHeld = heldMoveKeys[k] == true
			if should and not isHeld then
				keyDown(k)
				heldMoveKeys[k] = true
			elseif not should and isHeld then
				keyUp(k)
				heldMoveKeys[k] = nil
			end
		end
	end

	-- Back-compat single-key helper
	function M.holdMoveKey(key: Enum.KeyCode?)
		if key then
			M.holdMoveKeys({ key })
		else
			M.holdMoveKeys(nil)
		end
	end

	-- World-flat right vector for a forward look (Y-up).
	local function flatRight(forward: Vector3): Vector3
		-- forward × up-ish: rotate 90° so +forward → +right (Roblox look -Z → +X)
		return Vector3.new(-forward.Z, 0, forward.X)
	end

	-- Signed yaw error to world point: >0 = goal is to our LEFT, <0 = to our RIGHT.
	-- Used to choose Left/Right arrow for free-path turns.
	function M.yawErrorTo(worldX: number, worldZ: number): number?
		local player = Players.LocalPlayer
		local character = player and player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if not (hrp and hrp:IsA("BasePart")) then
			return nil
		end
		local fwd = flatUnit(hrp.CFrame.LookVector)
		local to = flatUnit(Vector3.new(worldX - hrp.Position.X, 0, worldZ - hrp.Position.Z))
		if not fwd or not to then
			return nil
		end
		-- 2D cross (Y component): look × to
		return fwd.X * to.Z - fwd.Z * to.X
	end

	-- Which arrow to hold to face a world XZ point. nil if already aligned enough.
	function M.turnKeyToward(worldX: number, worldZ: number, alignDot: number?): Enum.KeyCode?
		local d = M.facingDotTo(worldX, worldZ)
		local need = alignDot or (C.PATH_WALK_ALIGN_DOT or 0.72)
		if d ~= nil and d >= need then
			return nil
		end
		local err = M.yawErrorTo(worldX, worldZ)
		if err == nil then
			return nil
		end
		local dead = C.PATH_TURN_YAW_DEADZONE or 0.08
		if math.abs(err) < dead and d ~= nil and d > 0 then
			return nil -- almost on-axis forward
		end
		-- err > 0 → goal left of facing → Left arrow
		if err > 0 then
			return Enum.KeyCode.Left
		end
		return Enum.KeyCode.Right
	end

	-- WASD relative to reticle/face direction for the walk goal.
	-- facePos = where we must look (enemy); goalPos = path waypoint / stand point.
	-- Returns 0–2 keys. Empty if already at goal.
	function M.moveKeysForWalk(playerPos: Vector3, goalPos: Vector3, facePos: Vector3?): { Enum.KeyCode }
		local toGoal = Vector3.new(goalPos.X - playerPos.X, 0, goalPos.Z - playerPos.Z)
		if toGoal.Magnitude < 0.35 then
			return {}
		end
		toGoal = toGoal.Unit

		-- No combat face lock: just hold W (AutoRotate / face-travel handles yaw)
		if not facePos then
			return { Enum.KeyCode.W }
		end

		local toFace = Vector3.new(facePos.X - playerPos.X, 0, facePos.Z - playerPos.Z)
		if toFace.Magnitude < 0.15 then
			-- On top of target — still need a walk cycle; nudge with W
			return { Enum.KeyCode.W }
		end
		local forward = toFace.Unit
		local right = flatRight(forward)
		if right.Magnitude < 1e-4 then
			return { Enum.KeyCode.W }
		end
		right = right.Unit

		local f = toGoal:Dot(forward) -- +W / -S
		local r = toGoal:Dot(right) -- +D / -A
		local dead = C.WALK_KEY_DEADZONE or 0.28

		local keys: { Enum.KeyCode } = {}
		if f > dead then
			table.insert(keys, Enum.KeyCode.W)
		elseif f < -dead then
			table.insert(keys, Enum.KeyCode.S)
		end
		if r > dead then
			table.insert(keys, Enum.KeyCode.D)
		elseif r < -dead then
			table.insert(keys, Enum.KeyCode.A)
		end

		-- Pure-axis edge case (components both under deadzone): pick dominant
		if #keys == 0 then
			if math.abs(f) >= math.abs(r) then
				table.insert(keys, if f >= 0 then Enum.KeyCode.W else Enum.KeyCode.S)
			else
				table.insert(keys, if r >= 0 then Enum.KeyCode.D else Enum.KeyCode.A)
			end
		end
		return keys
	end

	-- Back-compat: single "primary" key (first of the set)
	function M.moveKeyForWalk(playerPos: Vector3, goalPos: Vector3, facePos: Vector3?): Enum.KeyCode?
		local keys = M.moveKeysForWalk(playerPos, goalPos, facePos)
		return keys[1]
	end

	function M.vec3Table(v: Vector3)
		return { x = v.X, y = v.Y, z = v.Z }
	end

	function M.getInstancePosition(inst: Instance): Vector3?
		if inst:IsA("BasePart") then
			return inst.Position
		end
		if inst:IsA("Model") then
			local ok, pivot = pcall(function()
				return inst:GetPivot()
			end)
			if ok and pivot then
				return pivot.Position
			end
			if inst.PrimaryPart then
				return inst.PrimaryPart.Position
			end
		end
		if inst:IsA("Attachment") then
			return inst.WorldPosition
		end
		return nil
	end

	function M.getCharacterLikePosition(model: Model): Vector3?
		local hrp = model:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			return hrp.Position
		end
		return M.getInstancePosition(model)
	end

	function M.getPlayerPosition(): (string?, { x: number, y: number, z: number }?)
		local player = Players.LocalPlayer
		if not player then
			return nil, nil
		end
		local character = player.Character
		if not character then
			return player.Name, nil
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			return player.Name, M.vec3Table(hrp.Position)
		end
		local ok, pivot = pcall(function()
			return character:GetPivot()
		end)
		if ok and pivot then
			return player.Name, M.vec3Table(pivot.Position)
		end
		return player.Name, nil
	end

	function M.getLivePlayerVector(): Vector3?
		local player = Players.LocalPlayer
		local character = player and player.Character
		if not character then
			return nil
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			return hrp.Position
		end
		local ok, pivot = pcall(function()
			return character:GetPivot()
		end)
		if ok and pivot then
			return pivot.Position
		end
		return nil
	end

	-- Facing / camera snapshot for dumps + debug
	function M.getPlayerFacingSnapshot(): any?
		local player = Players.LocalPlayer
		local character = player and player.Character
		if not character then
			return nil
		end
		local out: any = { name = player.Name }
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			local cf = hrp.CFrame
			local look = cf.LookVector
			out.rootPosition = M.vec3Table(hrp.Position)
			out.rootLookVector = M.vec3Table(look)
			out.rootYawDeg = math.deg(math.atan2(-look.X, -look.Z))
		end
		local hum = character:FindFirstChildOfClass("Humanoid")
		if hum then
			out.moveDirection = M.vec3Table(hum.MoveDirection)
			out.walkSpeed = hum.WalkSpeed
			out.autoRotate = hum.AutoRotate
			out.sit = hum.Sit == true
			out.seatPart = hum.SeatPart ~= nil
			pcall(function()
				out.humanoidState = tostring(hum:GetState())
			end)
		end
		-- Stance (from dumps 2026-08-14: sit walkSpeed=0; stand sheathed/drawn via tools/Q)
		out.seated = M.isSeated and M.isSeated() or false
		local hard, hardWhy = false, nil
		if M.detectWeaponDrawnHard then
			hard, hardWhy = M.detectWeaponDrawnHard()
		end
		out.weaponHard = hard
		out.weaponHardWhy = hardWhy
		out.weaponDrawn = M.isWeaponDrawn and M.isWeaponDrawn() or false
		out.weaponKnown = S.weaponDrawnKnown
		local tools = M.getEquippedTools and M.getEquippedTools() or {}
		local names = {}
		for _, t in ipairs(tools) do
			table.insert(names, t.Name)
		end
		out.equippedToolNames = names
		-- Character inventory snapshot (for dump debugging draw/sheathe)
		local charKids = {}
		if character then
			for _, c in ipairs(character:GetChildren()) do
				table.insert(charKids, {
					name = c.Name,
					className = c.ClassName,
				})
			end
		end
		out.characterChildren = charKids
		local bp = player:FindFirstChildOfClass("Backpack")
		local bpTools = {}
		if bp then
			for _, t in ipairs(bp:GetChildren()) do
				if t:IsA("Tool") then
					table.insert(bpTools, t.Name)
				end
			end
		end
		out.backpackTools = bpTools
		local cam = workspace.CurrentCamera
		if cam then
			local cl = cam.CFrame.LookVector
			out.cameraPosition = M.vec3Table(cam.CFrame.Position)
			out.cameraLookVector = M.vec3Table(cl)
			out.cameraYawDeg = math.deg(math.atan2(-cl.X, -cl.Z))
		end
		return out
	end

	function M.ensureDir(dir: string)
		if not isfolder(dir) then
			makefolder(dir)
		end
	end

	function M.teleportTo(
		x: number,
		y: number,
		z: number,
		silent: boolean?,
		lookAt: { x: number, y: number, z: number }?
	): boolean
		local player = Players.LocalPlayer
		local character = player and player.Character
		if not character then
			if not silent then
				M.setStatus("Teleport failed: no character")
			end
			return false
		end

		local pos = Vector3.new(x, y, z)
		local target: CFrame
		if lookAt then
			local look = Vector3.new(lookAt.x, lookAt.y, lookAt.z)
			if (look - pos).Magnitude > 0.05 then
				target = CFrame.lookAt(pos, look)
			else
				target = CFrame.new(pos)
			end
		else
			target = CFrame.new(pos)
		end

		local ok, err = pcall(function()
			character:PivotTo(target)
		end)
		if not ok then
			local hrp = character:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				ok, err = pcall(function()
					hrp.CFrame = target
				end)
			end
		end

		if ok then
			if not silent then
				M.setStatus(string.format("Teleported to %.1f, %.1f, %.1f", x, y, z))
			end
			return true
		end
		if not silent then
			M.setStatus("Teleport failed: " .. tostring(err))
		end
		return false
	end

	local function flatUnit(v: Vector3): Vector3?
		local f = Vector3.new(v.X, 0, v.Z)
		if f.Magnitude < 1e-4 then
			return nil
		end
		return f.Unit
	end

	-- Face a world point (horizontal). soft=true lerps yaw (no 180° snap).
	-- dt: optional seconds since last sample for frame-rate independent turns.
	function M.faceToward(
		worldX: number,
		worldY: number,
		worldZ: number,
		soft: boolean?,
		dt: number?
	): boolean
		local player = Players.LocalPlayer
		local character = player and player.Character
		if not character then
			return false
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not (hrp and hrp:IsA("BasePart")) then
			return false
		end
		local pos = hrp.Position
		local lookAt = Vector3.new(worldX, pos.Y, worldZ)
		if (lookAt - pos).Magnitude < 0.05 then
			return true
		end
		local desired = CFrame.lookAt(pos, lookAt)
		local ok = pcall(function()
			if soft then
				-- Time-based exp lerp when dt known; else fixed alpha per poll
				local alpha: number
				if dt and dt > 0 then
					local rate = C.SMOOTH_WALK_TURN_RATE or 5.5
					alpha = 1 - math.exp(-rate * dt)
				else
					alpha = C.SMOOTH_WALK_FACE_ALPHA or 0.12
				end
				hrp.CFrame = hrp.CFrame:Lerp(desired, math.clamp(alpha, 0.02, 1))
			else
				hrp.CFrame = desired
			end
		end)
		return ok
	end

	-- Dot of current look vs direction to (fx,fz). 1 = aligned, -1 = opposite.
	function M.facingDotTo(worldX: number, worldZ: number): number?
		local player = Players.LocalPlayer
		local character = player and player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if not (hrp and hrp:IsA("BasePart")) then
			return nil
		end
		local fwd = flatUnit(hrp.CFrame.LookVector)
		local to = flatUnit(Vector3.new(worldX - hrp.Position.X, 0, worldZ - hrp.Position.Z))
		if not fwd or not to then
			return nil
		end
		return fwd:Dot(to)
	end

	-- Smooth walk: Humanoid:MoveTo + WASD spoof for walk anim / games that read keys.
	--
	-- TWO MODES:
	--   lookAt set (reticle on enemy): face target; reticle-relative WASD. Never yaw-to-path.
	--   lookAt nil (free path / A*):
	--     1) try HRP CFrame faceToward waypoint
	--     2) if still misaligned, hold Left/Right arrows to yaw (no RMB camera drag)
	--     3) only hold W when facing waypoint (else choppy strafe)
	--
	-- Falls back to teleportTo on timeout if snapOnTimeout ~= false.
	function M.walkTo(
		x: number,
		y: number,
		z: number,
		opts: any?
	): boolean
		opts = opts or {}
		local silent = opts.silent == true
		local lookAt = opts.lookAt -- optional; only when reticle is locked on enemy
		local hardFace = opts.hardFace == true
		local forceSoftTurn = opts.softTurn == true
		local useMoveKeys = opts.useMoveKeys
		if useMoveKeys == nil then
			useMoveKeys = C.WALK_SPOOF_MOVE_KEYS ~= false
		end
		local useTurnArrows = opts.useTurnArrows
		if useTurnArrows == nil then
			useTurnArrows = C.PATH_TURN_ARROWS ~= false
		end
		local arrive = opts.arriveStuds or C.SMOOTH_WALK_ARRIVE_STUDS or 2.5
		local timeout = opts.timeout or C.SMOOTH_WALK_TIMEOUT or 3.0
		local poll = opts.poll or C.SMOOTH_WALK_POLL or 0.05
		local reissue = opts.reissue or C.SMOOTH_WALK_REISSUE or 0.45
		local requireWalking = opts.requireWalking == true
		local snapOnTimeout = opts.snapOnTimeout
		if snapOnTimeout == nil then
			snapOnTimeout = true
		end
		local pathAlignDot = C.PATH_WALK_ALIGN_DOT or 0.72
		local pathTurnRate = C.PATH_WALK_TURN_RATE or 16

		local hum = M.getHumanoid()
		local player = Players.LocalPlayer
		local character = player and player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if not hum or not (hrp and hrp:IsA("BasePart")) then
			M.releaseMoveKeys()
			if snapOnTimeout then
				return M.teleportTo(x, y, z, silent, lookAt)
			end
			return false
		end

		local goal = Vector3.new(x, y, z)
		local combatFace = type(lookAt) == "table" and lookAt.x ~= nil and lookAt.z ~= nil
		local faceX = if combatFace then lookAt.x else goal.X
		local faceY = if combatFace then (lookAt.y or y) else goal.Y
		local faceZ = if combatFace then lookAt.z else goal.Z
		local facePos = Vector3.new(faceX, faceY, faceZ)

		local function cleanupMove(restoreAutoRotate: boolean?)
			M.releaseMoveKeys() -- includes turn arrows
			pcall(function()
				hum:Move(Vector3.zero)
				if restoreAutoRotate ~= false then
					hum.AutoRotate = true
				end
			end)
		end

		-- Face waypoint: CFrame attempt + optional Left/Right arrow yaw.
		local function facePathWaypoint(dt: number): number?
			pcall(function()
				hum.AutoRotate = false
			end)
			local pos = hrp.Position
			local look = Vector3.new(goal.X, pos.Y, goal.Z)
			if (look - pos).Magnitude < 0.05 then
				M.holdTurnKey(nil)
				return 1
			end
			local desired = CFrame.lookAt(pos, look)
			local d = M.facingDotTo(goal.X, goal.Z)
			local snap = hardFace or forceSoftTurn or (d ~= nil and d < 0.25)
			pcall(function()
				if snap then
					hrp.CFrame = desired
				else
					local alpha = 1 - math.exp(-pathTurnRate * math.max(dt or poll, 0.016))
					hrp.CFrame = hrp.CFrame:Lerp(desired, math.clamp(alpha, 0.15, 1))
				end
			end)
			d = M.facingDotTo(goal.X, goal.Z)

			-- Arrow-key yaw when still off-axis (game often ignores HRP CFrame alone)
			if useTurnArrows and useMoveKeys and not S.clawBusy and not S.combatBusy then
				if d ~= nil and d >= pathAlignDot then
					M.holdTurnKey(nil)
				else
					M.holdTurnKey(M.turnKeyToward(goal.X, goal.Z, pathAlignDot))
				end
			else
				M.holdTurnKey(nil)
			end

			return M.facingDotTo(goal.X, goal.Z)
		end

		local function applyMoveKeys(pos: Vector3, faceDot: number?)
			if not useMoveKeys or S.clawBusy then
				return
			end
			if S.combatBusy then
				M.holdMoveKeys(nil)
				M.holdTurnKey(nil)
				return
			end
			if combatFace then
				M.holdTurnKey(nil) -- never arrow-turn while face-locked on reticle
				M.holdMoveKeys(M.moveKeysForWalk(pos, goal, facePos))
			else
				-- Free path: W only when facing waypoint; arrows handle the turn
				if faceDot ~= nil and faceDot >= pathAlignDot then
					M.holdMoveKeys({ Enum.KeyCode.W })
				else
					M.holdMoveKeys(nil)
				end
			end
		end

		-- Initial face
		local d0: number? = nil
		if combatFace then
			M.faceToward(faceX, faceY, faceZ, not hardFace, poll)
			pcall(function()
				hum.AutoRotate = false
			end)
			M.holdTurnKey(nil)
			d0 = 1
		else
			d0 = facePathWaypoint(poll)
		end
		pcall(function()
			hum:MoveTo(goal)
		end)
		applyMoveKeys(hrp.Position, d0)

		local t0 = os.clock()
		local lastIssue = t0
		local lastTick = t0
		while os.clock() - t0 < timeout do
			if requireWalking and not S.walking then
				cleanupMove(true)
				return false
			end
			if S.clawBusy then
				M.releaseMoveKeys()
			end
			local now = os.clock()
			local dt = math.clamp(now - lastTick, 0.001, 0.2)
			lastTick = now

			local pos = hrp.Position
			local flat = Vector3.new(pos.X - goal.X, 0, pos.Z - goal.Z).Magnitude
			if flat <= arrive then
				cleanupMove(true)
				return true
			end

			local faceDot: number? = nil
			if combatFace then
				pcall(function()
					hum.AutoRotate = false
				end)
				M.faceToward(faceX, faceY, faceZ, not hardFace, dt)
				M.holdTurnKey(nil)
				faceDot = 1
			else
				faceDot = facePathWaypoint(dt)
			end

			applyMoveKeys(pos, faceDot)

			if now - lastIssue >= reissue then
				pcall(function()
					hum:MoveTo(goal)
				end)
				lastIssue = now
			end
			task.wait(poll)
		end

		cleanupMove(true)
		if snapOnTimeout then
			return M.teleportTo(x, y, z, true, lookAt)
		end
		return false
	end

	---------------------------------------------------------------------------
	-- Anti-AFK: Space every ANTI_AFK_INTERVAL (default 2 min)
	---------------------------------------------------------------------------

	local function refreshAntiAfkLabel()
		if S.ui and S.ui.setAntiAfkLabel then
			S.ui.setAntiAfkLabel(S.antiAfkEnabled == true)
		end
	end

	function M.startAntiAfk()
		if S.antiAfkEnabled and S.antiAfkThread then
			refreshAntiAfkLabel()
			return
		end
		S.antiAfkEnabled = true
		S.antiAfkThread = task.spawn(function()
			local interval = C.ANTI_AFK_INTERVAL or 120
			while S.antiAfkEnabled do
				task.wait(interval)
				if not S.antiAfkEnabled then
					break
				end
				-- Don't jump mid-cast. Claw Space is the drop — separate map module.
				if not S.combatBusy and not S.clawBusy then
					pcall(function()
						M.pressKey(Enum.KeyCode.Space)
					end)
				end
			end
			S.antiAfkThread = nil
		end)
		refreshAntiAfkLabel()
	end

	function M.stopAntiAfk()
		S.antiAfkEnabled = false
		-- Thread exits on next loop; don't nil mid-wait so we can detect "running"
		refreshAntiAfkLabel()
		M.setStatus("Anti-AFK OFF")
	end

	function M.setAntiAfk(on: boolean)
		if on then
			M.startAntiAfk()
			M.setStatus(string.format(
				"Anti-AFK ON — Space every %ds",
				C.ANTI_AFK_INTERVAL or 120
			))
		else
			M.stopAntiAfk()
		end
	end

	function M.toggleAntiAfk()
		M.setAntiAfk(not S.antiAfkEnabled)
	end

	---------------------------------------------------------------------------
	-- WalkSpeed force: re-apply Humanoid.WalkSpeed every frame while enabled
	---------------------------------------------------------------------------

	local function refreshWalkSpeedLabel()
		if S.ui and S.ui.setWalkSpeedLabel then
			S.ui.setWalkSpeedLabel(S.walkSpeedEnabled == true, S.walkSpeedValue)
		end
	end

	function M.getHumanoid(): Humanoid?
		local char = Players.LocalPlayer and Players.LocalPlayer.Character
		if not char then
			return nil
		end
		return char:FindFirstChildOfClass("Humanoid")
	end

	---------------------------------------------------------------------------
	-- Sit (Z toggle) / weapon draw (Q toggle) — state from character, not timers.
	-- Dumps 2026-08-14 sit→stand→draw: sit freezes WalkSpeed≈0; draw = tool on char.
	-- Z toggles sit/stand (recover). Q toggles sheathe/draw (has cooldown).
	---------------------------------------------------------------------------

	function M.getEquippedTools(): { Tool }
		local out: { Tool } = {}
		local lp = Players.LocalPlayer
		local char = lp and lp.Character
		if not char then
			return out
		end
		for _, c in ipairs(char:GetChildren()) do
			if c:IsA("Tool") then
				table.insert(out, c)
			end
		end
		return out
	end

	-- Recover sit: Humanoid sit/seat, Seated state, or game freezes WalkSpeed at 0.
	function M.isSeated(): boolean
		local hum = M.getHumanoid()
		if not hum or hum.Health <= 0 then
			return false
		end
		if hum.Sit == true then
			return true
		end
		local okSeat, seat = pcall(function()
			return hum.SeatPart
		end)
		if okSeat and seat ~= nil then
			return true
		end
		local okSt, st = pcall(function()
			return hum:GetState()
		end)
		if okSt and st == Enum.HumanoidStateType.Seated then
			return true
		end
		-- Dump signal: sit-recover sets WalkSpeed to 0 (don't treat our force-speed as sit)
		if not S.walkSpeedEnabled and (hum.WalkSpeed or 0) <= 0.05 then
			return true
		end
		return false
	end

	-- Body parts we ignore when looking for a gripped weapon mesh/weld.
	local BODY_PART_NAMES: { [string]: boolean } = {
		HumanoidRootPart = true,
		Head = true,
		UpperTorso = true,
		LowerTorso = true,
		Torso = true,
		LeftUpperArm = true,
		LeftLowerArm = true,
		LeftHand = true,
		RightUpperArm = true,
		RightLowerArm = true,
		RightHand = true,
		LeftUpperLeg = true,
		LeftLowerLeg = true,
		LeftFoot = true,
		RightUpperLeg = true,
		RightLowerLeg = true,
		RightFoot = true,
		["Left Arm"] = true,
		["Right Arm"] = true,
		["Left Leg"] = true,
		["Right Leg"] = true,
	}

	-- Hard evidence only (Tools / grip / attrs). This game often has NO Tools while drawn
	-- (dumps 19-41-18 + 19-50-44: equippedToolNames=[], weapon still out).
	function M.detectWeaponDrawnHard(): (boolean, string?)
		local lp = Players.LocalPlayer
		local char = lp and lp.Character
		if not char then
			return false, "no_char"
		end
		local tools = M.getEquippedTools()
		if #tools > 0 then
			return true, "tool:" .. tools[1].Name
		end

		local hum = char:FindFirstChildOfClass("Humanoid")
		local attrNames = {
			"WeaponDrawn",
			"WeaponEquipped",
			"IsWeaponOut",
			"WeaponOut",
			"CombatReady",
			"Sheathed",
			"IsSheathed",
			"WeaponSheathed",
		}
		for _, inst in ipairs({ char, hum }) do
			if inst then
				for _, an in ipairs(attrNames) do
					local ok, v = pcall(function()
						return (inst :: any):GetAttribute(an)
					end)
					if ok and v ~= nil then
						local al = string.lower(an)
						if string.find(al, "sheath", 1, true) then
							-- Sheathed=false ⇒ drawn; Sheathed=true ⇒ sheathed
							if v == false or v == 0 or v == "false" then
								return true, "attr:" .. an .. "=false"
							elseif v == true or v == 1 or v == "true" then
								S.weaponDrawnKnown = false
								return false, "attr:" .. an .. "=true"
							end
						else
							if v == true or v == 1 or v == "true" then
								return true, "attr:" .. an
							end
						end
					end
				end
			end
		end

		-- RightGrip / hand motors gripping a non-body part (classic + many custom weapons)
		for _, d in ipairs(char:GetDescendants()) do
			if d:IsA("Motor6D") then
				local n = string.lower(d.Name)
				if n == "rightgrip" or n == "leftgrip" or string.find(n, "grip", 1, true) then
					return true, "motor:" .. d.Name
				end
				local p0, p1 = d.Part0, d.Part1
				local handish = p0 and (string.find(p0.Name, "Hand", 1, true) or string.find(p0.Name, "Arm", 1, true))
				if handish and p1 and not BODY_PART_NAMES[p1.Name] then
					return true, "grip:" .. p1.Name
				end
			end
		end

		-- Handle part under a character child (tool-like without Tool class)
		for _, c in ipairs(char:GetChildren()) do
			if c:IsA("Accessory") then
				continue
			end
			if c:IsA("Model") or c:IsA("Folder") or c:IsA("BasePart") then
				local handle = c:FindFirstChild("Handle", true)
				if handle and handle:IsA("BasePart") then
					return true, "handle:" .. c.Name
				end
				local n = string.lower(c.Name)
				local kws = C.WEAPON_NAME_KEYWORDS or {}
				for _, kw in ipairs(kws) do
					if type(kw) == "string" and kw ~= "" and string.find(n, string.lower(kw), 1, true) then
						return true, "name:" .. c.Name
					end
				end
			end
		end
		return false, nil
	end

	function M.markWeaponDrawn()
		S.weaponDrawnKnown = true
	end

	function M.markWeaponSheathed()
		S.weaponDrawnKnown = false
	end

	-- Effective drawn state for Kill Aura / recover.
	-- Dumps prove Tool detection alone is wrong (empty tools while unsheathed).
	-- Soft rules:
	--   hard evidence → drawn
	--   known=false (e.g. just stood from Z-sit) → sheathed
	--   known=true → drawn
	--   unknown + standing → assume drawn (never false-"sheathed" / spam Q off)
	--   sitting → sheathed
	function M.isWeaponDrawn(): boolean
		local hard, _why = M.detectWeaponDrawnHard()
		if hard then
			S.weaponDrawnKnown = true
			return true
		end
		if M.isSeated() then
			return false
		end
		if S.weaponDrawnKnown == false then
			return false
		end
		if S.weaponDrawnKnown == true then
			return true
		end
		-- Unknown while standing: assume drawn so we don't toggle Q on an already-out weapon
		return true
	end

	M.hasWeaponEquipped = M.isWeaponDrawn -- alias

	function M.getStance(): any
		local hum = M.getHumanoid()
		local seated = M.isSeated()
		local hard, hardWhy = M.detectWeaponDrawnHard()
		local drawn = M.isWeaponDrawn()
		local tools = M.getEquippedTools()
		local names = {}
		for _, t in ipairs(tools) do
			table.insert(names, t.Name)
		end
		return {
			seated = seated,
			weaponDrawn = drawn,
			weaponHard = hard,
			weaponHardWhy = hardWhy,
			weaponKnown = S.weaponDrawnKnown,
			walkSpeed = hum and hum.WalkSpeed or nil,
			autoRotate = hum and hum.AutoRotate or nil,
			sitFlag = hum and hum.Sit or nil,
			health = hum and hum.Health or nil,
			equippedTools = names,
			readyToFight = (not seated) and drawn and hum ~= nil and hum.Health > 0,
		}
	end

	local function toggleCooldownOk(lastAt: number?): boolean
		local cd = C.WEAPON_Q_COOLDOWN or 0.8
		if type(lastAt) ~= "number" then
			return true
		end
		return (os.clock() - lastAt) >= cd
	end

	-- Press Z once to flip sit/stand, then wait for observed state.
	-- Standing up from Z-recover leaves weapon sheathed → mark for auto-draw.
	function M.ensureStanding(timeout: number?): boolean
		if not M.isSeated() then
			return true
		end
		local waitFor = timeout or 3.0
		local wasSeated = true
		if toggleCooldownOk(S.lastSitToggleAt) then
			M.setStatus("[stance] Z → stand")
			M.pressKey(Enum.KeyCode.Z)
			S.lastSitToggleAt = os.clock()
		end
		local t0 = os.clock()
		while os.clock() - t0 < waitFor do
			if not M.isSeated() then
				if wasSeated then
					-- Game sheathes on sit-recover exit; need Q before fight
					M.markWeaponSheathed()
				end
				return true
			end
			task.wait(0.08)
		end
		if not M.isSeated() then
			M.markWeaponSheathed()
			return true
		end
		return false
	end

	-- Enter sit-recover via Z if not already seated (for HP/MP regen).
	function M.ensureSeated(timeout: number?): boolean
		if M.isSeated() then
			return true
		end
		local waitFor = timeout or 3.0
		if toggleCooldownOk(S.lastSitToggleAt) then
			M.setStatus("[stance] Z → sit/recover")
			M.pressKey(Enum.KeyCode.Z)
			S.lastSitToggleAt = os.clock()
		end
		local t0 = os.clock()
		while os.clock() - t0 < waitFor do
			if M.isSeated() then
				return true
			end
			task.wait(0.08)
		end
		return M.isSeated()
	end

	local function toolPreferScore(tool: Tool): number
		local n = string.lower(tool.Name)
		local kws = C.WEAPON_NAME_KEYWORDS or {}
		for i, kw in ipairs(kws) do
			if type(kw) == "string" and kw ~= "" and string.find(n, string.lower(kw), 1, true) then
				return i
			end
		end
		return 1000
	end

	-- Draw weapon via Q (toggle + CD).
	-- force=true: always press Q once (Kill Aura start / post-sit). Soft "assume drawn"
	-- must not skip unsheath when the weapon is actually sheathed.
	function M.ensureWeaponDrawn(timeout: number?, force: boolean?): boolean
		if M.isSeated() then
			return false
		end
		local hard = select(1, M.detectWeaponDrawnHard())
		if hard then
			M.markWeaponDrawn()
			return true
		end
		-- Soft-known drawn and not forced → skip (avoid Q-sheathing an already-out weapon)
		if not force and S.weaponDrawnKnown == true then
			return true
		end

		local waitFor = timeout or (C.WEAPON_EQUIP_WAIT or 1.2)
		local eqKey = C.WEAPON_EQUIP_KEY or Enum.KeyCode.Q

		if toggleCooldownOk(S.lastWeaponToggleAt) then
			M.setStatus("[stance] Q → unsheath/draw")
			M.pressKey(eqKey)
			S.lastWeaponToggleAt = os.clock()
			M.markWeaponDrawn()
		else
			M.setStatus("[stance] Q on cooldown — wait draw…")
		end

		local t0 = os.clock()
		while os.clock() - t0 < waitFor do
			if select(1, M.detectWeaponDrawnHard()) then
				M.markWeaponDrawn()
				return true
			end
			task.wait(0.08)
		end

		-- Fallback EquipTool if backpack tools exist
		local lp = Players.LocalPlayer
		local hum = M.getHumanoid()
		local bp = lp and lp:FindFirstChildOfClass("Backpack")
		local candidates: { Tool } = {}
		if bp then
			for _, t in ipairs(bp:GetChildren()) do
				if t:IsA("Tool") then
					table.insert(candidates, t)
				end
			end
		end
		table.sort(candidates, function(a, b)
			return toolPreferScore(a) < toolPreferScore(b)
		end)
		if hum and #candidates > 0 then
			pcall(function()
				hum:EquipTool(candidates[1])
			end)
			task.wait(0.25)
			if select(1, M.detectWeaponDrawnHard()) then
				M.markWeaponDrawn()
				return true
			end
		end
		-- No hard signal in this game — after forced Q we treat as drawn
		return force == true or S.weaponDrawnKnown == true or M.isWeaponDrawn()
	end

	M.ensureWeaponEquipped = M.ensureWeaponDrawn -- alias for older callers

	-- Deprecated force-unsit (wrong for Z-recover). Prefer ensureStanding (Z toggle).
	function M.standUp(): boolean
		return M.ensureStanding(2.5)
	end

	-- True when Kill Aura must idle (respawn, sit-recover, dead, sheathed).
	function M.killAuraBlocked(): (boolean, string?)
		if S.zRegenBusy then
			return true, "z_regen"
		end
		if S.resourceRecoverPhase == "regen" then
			return true, "mana_regen"
		end
		local hum = M.getHumanoid()
		if not hum or hum.Health <= 0 then
			return true, "dead"
		end
		if M.isSeated() then
			return true, "sitting"
		end
		if not M.isWeaponDrawn() then
			return true, "sheathed"
		end
		return false, nil
	end

	-- Ready for fight: standing + weapon drawn + alive.
	function M.readyForKillAura(): (boolean, string?)
		local blocked, why = M.killAuraBlocked()
		if blocked then
			return false, why
		end
		return true, nil
	end

	function M.applyWalkSpeed(speed: number?): boolean
		local hum = M.getHumanoid()
		if not hum then
			return false
		end
		local sp = speed or S.walkSpeedValue or C.WALK_SPEED_DEFAULT or 32
		local lo = C.WALK_SPEED_MIN or 8
		local hi = C.WALK_SPEED_MAX or 200
		sp = math.clamp(sp, lo, hi)
		S.walkSpeedValue = sp
		pcall(function()
			hum.WalkSpeed = sp
		end)
		return true
	end

	function M.setWalkSpeedValue(speed: number)
		local lo = C.WALK_SPEED_MIN or 8
		local hi = C.WALK_SPEED_MAX or 200
		S.walkSpeedValue = math.clamp(speed, lo, hi)
		if S.walkSpeedEnabled then
			M.applyWalkSpeed(S.walkSpeedValue)
		end
		refreshWalkSpeedLabel()
	end

	function M.startWalkSpeedForce()
		if S.walkSpeedEnabled and S.walkSpeedThread then
			refreshWalkSpeedLabel()
			return
		end
		local hum = M.getHumanoid()
		if hum and S.walkSpeedSaved == nil then
			S.walkSpeedSaved = hum.WalkSpeed
		end
		if not S.walkSpeedValue or S.walkSpeedValue <= 0 then
			S.walkSpeedValue = C.WALK_SPEED_DEFAULT or 32
		end
		S.walkSpeedEnabled = true
		S.walkSpeedThread = task.spawn(function()
			local RunService = game:GetService("RunService")
			while S.walkSpeedEnabled do
				M.applyWalkSpeed(S.walkSpeedValue)
				RunService.Heartbeat:Wait()
			end
			S.walkSpeedThread = nil
		end)
		refreshWalkSpeedLabel()
		M.setStatus(string.format("WalkSpeed force ON — %.0f", S.walkSpeedValue))
	end

	function M.stopWalkSpeedForce()
		S.walkSpeedEnabled = false
		-- Restore previous/vanilla speed once
		local hum = M.getHumanoid()
		if hum then
			local restore = S.walkSpeedSaved or C.WALK_SPEED_VANILLA or 16
			pcall(function()
				hum.WalkSpeed = restore
			end)
		end
		S.walkSpeedSaved = nil
		refreshWalkSpeedLabel()
		M.setStatus("WalkSpeed force OFF")
	end

	function M.setWalkSpeedForce(on: boolean)
		if on then
			M.startWalkSpeedForce()
		else
			M.stopWalkSpeedForce()
		end
	end

	function M.toggleWalkSpeedForce()
		M.setWalkSpeedForce(not S.walkSpeedEnabled)
	end

	return M
end

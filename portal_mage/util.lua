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
	-- Walk-anim move keys (W toward reticle / S away). MoveTo alone often skips anim.
	---------------------------------------------------------------------------

	local MOVE_KEYS = {
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
	}
	local heldMoveKey: Enum.KeyCode? = nil

	function M.releaseMoveKeys()
		for _, k in ipairs(MOVE_KEYS) do
			pcall(function()
				VIM:SendKeyEvent(false, k, false, game)
			end)
		end
		heldMoveKey = nil
	end

	function M.holdMoveKey(key: Enum.KeyCode?)
		if key == heldMoveKey then
			return
		end
		-- Release previous first
		if heldMoveKey then
			local prev = heldMoveKey
			pcall(function()
				VIM:SendKeyEvent(false, prev, false, game)
			end)
			heldMoveKey = nil
		end
		if key then
			pcall(function()
				VIM:SendKeyEvent(true, key, false, game)
			end)
			heldMoveKey = key
		end
	end

	-- Pick W (toward face) or S (away) from movement vs face/reticle direction.
	-- facePos = reticle/enemy; goalPos = where we're walking.
	function M.moveKeyForWalk(playerPos: Vector3, goalPos: Vector3, facePos: Vector3?): Enum.KeyCode?
		local toGoal = Vector3.new(goalPos.X - playerPos.X, 0, goalPos.Z - playerPos.Z)
		if toGoal.Magnitude < 0.35 then
			return nil
		end
		toGoal = toGoal.Unit
		if facePos then
			local toFace = Vector3.new(facePos.X - playerPos.X, 0, facePos.Z - playerPos.Z)
			if toFace.Magnitude < 0.2 then
				-- On top of target — still need some anim; prefer W
				return Enum.KeyCode.W
			end
			toFace = toFace.Unit
			local dot = toGoal:Dot(toFace)
			-- Toward reticle/enemy → W; away (kite) → S
			if dot >= 0.12 then
				return Enum.KeyCode.W
			elseif dot <= -0.12 then
				return Enum.KeyCode.S
			end
			-- Mostly strafe: still use W so walk cycle plays while soft-facing
			return Enum.KeyCode.W
		end
		-- No reticle: always "forward" relative to travel (game sees W + AutoRotate)
		return Enum.KeyCode.W
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
		end
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

	-- Smooth walk: Humanoid:MoveTo + W/S spoof so walk animation plays.
	-- With lookAt (reticle/enemy): face target; W if goal is toward it, S if away (kite).
	-- Without lookAt: face travel + hold W.
	-- Falls back to teleportTo on timeout if snapOnTimeout ~= false.
	function M.walkTo(
		x: number,
		y: number,
		z: number,
		opts: any?
	): boolean
		opts = opts or {}
		local silent = opts.silent == true
		local lookAt = opts.lookAt -- optional; kite/reticle soft-face target
		local hardFace = opts.hardFace == true -- rare; soft lerp is default
		local forceSoftTurn = opts.softTurn == true -- pathing reverse hint
		local useMoveKeys = opts.useMoveKeys
		if useMoveKeys == nil then
			useMoveKeys = C.WALK_SPOOF_MOVE_KEYS ~= false
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
		local softTurnDot = C.SMOOTH_WALK_SOFT_TURN_DOT or 0.35
		local alignDot = C.SMOOTH_WALK_ALIGN_DOT or 0.90

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
		-- Face reticle/enemy when provided; else face travel goal
		local faceX = if lookAt then lookAt.x else goal.X
		local faceY = if lookAt then (lookAt.y or y) else goal.Y
		local faceZ = if lookAt then lookAt.z else goal.Z
		local facePos = Vector3.new(faceX, faceY, faceZ)

		local function needsSoftTurn(): boolean
			if forceSoftTurn then
				return true
			end
			local d = M.facingDotTo(faceX, faceZ)
			if d == nil then
				return lookAt ~= nil
			end
			return d < softTurnDot
		end

		local function cleanupMove(restoreAutoRotate: boolean?)
			M.releaseMoveKeys()
			pcall(function()
				hum:Move(Vector3.zero)
				if restoreAutoRotate ~= false then
					hum.AutoRotate = true
				end
			end)
		end

		local softTurning = needsSoftTurn() or lookAt ~= nil
		if softTurning then
			M.faceToward(faceX, faceY, faceZ, not hardFace, poll)
		end

		pcall(function()
			-- Prefer AutoRotate only when not facing a combat reticle
			hum.AutoRotate = not softTurning and lookAt == nil
			hum:MoveTo(goal)
		end)
		if useMoveKeys then
			M.holdMoveKey(M.moveKeyForWalk(hrp.Position, goal, if lookAt then facePos else nil))
		end

		local t0 = os.clock()
		local lastIssue = t0
		local lastTick = t0
		while os.clock() - t0 < timeout do
			if requireWalking and not S.walking then
				cleanupMove(true)
				return false
			end
			-- Claw owns WASD fully
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

			-- Soft-turn while misaligned; keep facing reticle during kite/engage
			local d = M.facingDotTo(faceX, faceZ)
			if lookAt ~= nil or (d ~= nil and d < softTurnDot) then
				softTurning = true
			elseif d ~= nil and d >= alignDot and lookAt == nil then
				softTurning = false
			end

			if softTurning or lookAt ~= nil then
				pcall(function()
					hum.AutoRotate = false
				end)
				M.faceToward(faceX, faceY, faceZ, not hardFace, dt)
			else
				pcall(function()
					hum.AutoRotate = true
				end)
			end

			-- Keep walking during combat. Only drop W/S spoof mid-cast so 1/E aren't fighting
			-- held move keys; Humanoid:MoveTo continues either way.
			if useMoveKeys and not S.clawBusy and not S.combatBusy then
				M.holdMoveKey(M.moveKeyForWalk(pos, goal, if lookAt then facePos else nil))
			elseif useMoveKeys and S.combatBusy then
				M.releaseMoveKeys()
			end

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

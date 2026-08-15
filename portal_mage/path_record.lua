-- portal_mage/path_record.lua — Human A* / path traversal recorder
--
-- When stuck on Auto Ore: pause bot → toggle "A* Rec" → walk the route yourself.
-- Records position trail + key edges/holds + last bot path + Path Viz polyline.
-- Writes dumps/pathrec_YYYY-MM-DD_HH-MM-SS.json for offline fix of traversal.
return function(S)
	local C = S.Config
	local U = S.Util
	local Players = S.Services.Players
	local UIS = S.Services.UserInputService
	local HttpService = S.Services.HttpService
	local M = {}

	local TRACK_KEYS = {
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
		Enum.KeyCode.Space,
		Enum.KeyCode.Left,
		Enum.KeyCode.Right,
		Enum.KeyCode.Q,
		Enum.KeyCode.F,
		Enum.KeyCode.Z,
		Enum.KeyCode.LeftShift,
		Enum.KeyCode.LeftControl,
	}

	local KEY_NAME: { [Enum.KeyCode]: string } = {
		[Enum.KeyCode.W] = "W",
		[Enum.KeyCode.A] = "A",
		[Enum.KeyCode.S] = "S",
		[Enum.KeyCode.D] = "D",
		[Enum.KeyCode.Space] = "Space",
		[Enum.KeyCode.Left] = "Left",
		[Enum.KeyCode.Right] = "Right",
		[Enum.KeyCode.Q] = "Q",
		[Enum.KeyCode.F] = "F",
		[Enum.KeyCode.Z] = "Z",
		[Enum.KeyCode.LeftShift] = "LShift",
		[Enum.KeyCode.LeftControl] = "LCtrl",
	}

	local REC_FOLDER = "PortalMage_PathRecTrail"

	local function setStatus(t: string)
		if U and U.setStatus then
			U.setStatus(t)
		end
	end

	local function refreshLabel()
		if S.ui and S.ui.setPathRecLabel then
			S.ui.setPathRecLabel(S.pathRecEnabled == true)
		end
	end

	local function keyName(k: Enum.KeyCode): string
		return KEY_NAME[k] or tostring(k)
	end

	local function isTrackKey(k: Enum.KeyCode): boolean
		return KEY_NAME[k] ~= nil
	end

	local function playerSnapshot(): any?
		local lp = Players.LocalPlayer
		local char = lp and lp.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not (hrp and hrp:IsA("BasePart")) then
			return nil
		end
		local look = hrp.CFrame.LookVector
		local yaw = math.deg(math.atan2(-look.X, -look.Z))
		local held = {}
		for _, k in ipairs(TRACK_KEYS) do
			if UIS:IsKeyDown(k) then
				table.insert(held, keyName(k))
			end
		end
		local cam = workspace.CurrentCamera
		local camYaw = nil
		if cam then
			local cl = cam.CFrame.LookVector
			camYaw = math.deg(math.atan2(-cl.X, -cl.Z))
		end
		return {
			x = hrp.Position.X,
			y = hrp.Position.Y,
			z = hrp.Position.Z,
			yaw = yaw,
			camYaw = camYaw,
			keys = held,
		}
	end

	local function vec3t(v: Vector3?): any?
		if not v then
			return nil
		end
		return { x = v.X, y = v.Y, z = v.Z }
	end

	local function pointsToTable(pts: { Vector3 }?): { any }
		local out = {}
		if not pts then
			return out
		end
		for _, p in ipairs(pts) do
			table.insert(out, vec3t(p))
		end
		return out
	end

	-- Snapshot Path Viz folder parts if present
	local function capturePathVizPoints(): { any }
		local folder = workspace:FindFirstChild("PortalMage_PathViz") or S.pathVizFolder
		if not folder then
			return {}
		end
		local nodes = {}
		for _, ch in ipairs(folder:GetChildren()) do
			if ch:IsA("BasePart") and string.sub(ch.Name, 1, 1) == "N" then
				table.insert(nodes, {
					name = ch.Name,
					x = ch.Position.X,
					y = ch.Position.Y,
					z = ch.Position.Z,
				})
			end
		end
		table.sort(nodes, function(a, b)
			return a.name < b.name
		end)
		return nodes
	end

	local function captureLastBotPath(): any?
		if S.AutoOre and S.AutoOre.getLastPath then
			return S.AutoOre.getLastPath()
		end
		return S.lastBotPath
	end

	---------------------------------------------------------------------------
	-- Trail viz (human walk crumbs while recording)
	---------------------------------------------------------------------------

	local trailFolder: Folder? = nil
	local trailCount = 0

	local function clearTrail()
		pcall(function()
			if trailFolder and trailFolder.Parent then
				trailFolder:Destroy()
			end
			local old = workspace:FindFirstChild(REC_FOLDER)
			if old then
				old:Destroy()
			end
		end)
		trailFolder = nil
		trailCount = 0
	end

	local function ensureTrail(): Folder
		if trailFolder and trailFolder.Parent then
			return trailFolder
		end
		clearTrail()
		local f = Instance.new("Folder")
		f.Name = REC_FOLDER
		f.Parent = workspace
		trailFolder = f
		return f
	end

	local function dropTrailMarker(pos: Vector3)
		if C.PATH_REC_TRAIL_VIZ == false then
			return
		end
		local maxN = C.PATH_REC_TRAIL_MAX or 400
		local f = ensureTrail()
		trailCount += 1
		if trailCount > maxN then
			-- drop oldest
			local oldest = f:FindFirstChild("T1") or f:GetChildren()[1]
			if oldest then
				oldest:Destroy()
			end
		end
		local p = Instance.new("Part")
		p.Name = string.format("T%04d", trailCount)
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.new(0.55, 0.55, 0.55)
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = Color3.fromRGB(80, 255, 140)
		p.Transparency = 0.25
		p.CFrame = CFrame.new(pos + Vector3.new(0, 0.4, 0))
		p.Parent = f
	end

	---------------------------------------------------------------------------
	-- Session state
	---------------------------------------------------------------------------

	local samples: { any } = {}
	local keyEvents: { any } = {}
	local recT0 = 0
	local recPath: string? = nil
	local connBegan: RBXScriptConnection? = nil
	local connEnded: RBXScriptConnection? = nil
	local startSnap: any? = nil
	local pathVizAtStart: { any } = {}
	local botPathAtStart: any? = nil

	local function disconnectInput()
		if connBegan then
			connBegan:Disconnect()
			connBegan = nil
		end
		if connEnded then
			connEnded:Disconnect()
			connEnded = nil
		end
	end

	local function appendKeyEvent(down: boolean, key: Enum.KeyCode)
		if not S.pathRecEnabled then
			return
		end
		if not isTrackKey(key) then
			return
		end
		table.insert(keyEvents, {
			t = os.clock() - recT0,
			key = keyName(key),
			down = down,
		})
	end

	local function sampleLoop()
		local interval = C.PATH_REC_SAMPLE or 0.08
		local lastTrailAt = 0
		local trailEvery = C.PATH_REC_TRAIL_EVERY or 0.25
		while S.pathRecEnabled do
			local snap = playerSnapshot()
			if snap then
				local t = os.clock() - recT0
				table.insert(samples, {
					t = t,
					x = snap.x,
					y = snap.y,
					z = snap.z,
					yaw = snap.yaw,
					camYaw = snap.camYaw,
					keys = snap.keys,
				})
				if (os.clock() - lastTrailAt) >= trailEvery then
					dropTrailMarker(Vector3.new(snap.x, snap.y, snap.z))
					lastTrailAt = os.clock()
				end
				if #samples % 25 == 0 then
					setStatus(string.format(
						"[path-rec] t=%.1fs samples=%d keys=%d → walk the stuck route",
						t,
						#samples,
						#keyEvents
					))
				end
			end
			task.wait(interval)
		end
		S.pathRecThread = nil
	end

	local function writeRecording(): string?
		local dir = C.DUMP_DIR or "dumps"
		local stamp = os.date("%Y-%m-%d_%H-%M-%S")
		local path = string.format("%s/pathrec_%s.json", dir, stamp)
		local endSnap = playerSnapshot()
		local payload = {
			type = "path_recording",
			version = 1,
			stamp = stamp,
			duration = os.clock() - recT0,
			sampleHz = 1 / (C.PATH_REC_SAMPLE or 0.08),
			start = startSnap,
			finish = endSnap,
			-- Bot path that failed (auto ore / last compute)
			botPath = botPathAtStart or captureLastBotPath(),
			-- Path Viz nodes at record start (A* the bot wanted)
			pathVizAtStart = pathVizAtStart,
			pathVizAtEnd = capturePathVizPoints(),
			samples = samples,
			keyEvents = keyEvents,
			notes = "Human walk of stuck A* route. Use samples+keys vs botPath to fix traversal.",
		}
		local ok, err = pcall(function()
			if U and U.ensureDir then
				U.ensureDir(dir)
			end
			writefile(path, HttpService:JSONEncode(payload))
		end)
		if not ok then
			setStatus("Path rec write failed: " .. tostring(err))
			return nil
		end
		return path
	end

	---------------------------------------------------------------------------
	-- Public API
	---------------------------------------------------------------------------

	function M.setEnabled(on: boolean)
		on = on and true or false
		if on == (S.pathRecEnabled == true) then
			refreshLabel()
			return
		end

		if on then
			-- Capture context before human moves
			recT0 = os.clock()
			samples = {}
			keyEvents = {}
			startSnap = playerSnapshot()
			pathVizAtStart = capturePathVizPoints()
			botPathAtStart = captureLastBotPath()
			recPath = nil
			clearTrail()
			S.pathRecEnabled = true
			refreshLabel()

			-- Auto-on Path Viz so you see the bot path while walking
			if C.PATH_REC_AUTO_PATH_VIZ ~= false and not S.pathVizEnabled then
				if S.Pathing and S.Pathing.setPathVizEnabled then
					S.Pathing.setPathVizEnabled(true)
				elseif S.Nav and S.Nav.setPathVizEnabled then
					S.Nav.setPathVizEnabled(true)
				else
					S.pathVizEnabled = true
				end
			end

			disconnectInput()
			connBegan = UIS.InputBegan:Connect(function(input, _gp)
				if input.UserInputType == Enum.UserInputType.Keyboard then
					appendKeyEvent(true, input.KeyCode)
				end
			end)
			connEnded = UIS.InputEnded:Connect(function(input, _gp)
				if input.UserInputType == Enum.UserInputType.Keyboard then
					appendKeyEvent(false, input.KeyCode)
				end
			end)

			if not S.pathRecThread then
				S.pathRecThread = task.spawn(sampleLoop)
			end
			setStatus(string.format(
				"A* Rec ON — walk the stuck path, toggle OFF to save (botWps=%s)",
				botPathAtStart and tostring(botPathAtStart.waypointCount or #((botPathAtStart.points or {}))) or "none"
			))
		else
			S.pathRecEnabled = false
			disconnectInput()
			-- let sample loop exit
			task.wait(0.05)
			local path = writeRecording()
			recPath = path
			refreshLabel()
			if path then
				setStatus(string.format(
					"A* Rec saved %s  samples=%d keyEv=%d",
					path,
					#samples,
					#keyEvents
				))
			else
				setStatus("A* Rec OFF (save failed)")
			end
			-- keep trail a few seconds then clear? keep until next rec for visual review
		end
	end

	function M.toggle()
		M.setEnabled(not S.pathRecEnabled)
	end

	function M.isEnabled(): boolean
		return S.pathRecEnabled == true
	end

	function M.getLastFile(): string?
		return recPath
	end

	function M.clearTrailViz()
		clearTrail()
	end

	return M
end

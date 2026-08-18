-- portal_mage/path_record.lua — Human path recorder + spawn-path registry
--
-- Waypoints tab "A* Rec": walk a route → OFF saves dumps/pathrec_*.json AND
-- registers a spawn egress path (start = first sample) in waypoints/respawn_paths.json.
-- List/delete wrong recordings; "Respawn points" viz marks starts with recorded paths.
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
	local SPAWN_VIZ_FOLDER = "PortalMage_SpawnPathStarts"

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

	local function refreshSpawnList()
		if S.ui and S.ui.refreshSpawnPaths then
			S.ui.refreshSpawnPaths()
		end
	end

	local function spawnFilePath(): string
		return C.RESPAWN_PATH_FILE or "waypoints/respawn_paths.json"
	end

	local function newSpawnId(): string
		return string.format("sp_%s_%04d", os.date("%Y%m%d%H%M%S"), math.random(0, 9999))
	end

	---------------------------------------------------------------------------
	-- Spawn-path registry (saved recordings for respawn egress)
	---------------------------------------------------------------------------

	function M.loadSpawnPaths(): number
		S.spawnPaths = {}
		S.selectedSpawnPathId = nil
		local path = spawnFilePath()
		local ok, data = pcall(function()
			if not isfile or not isfile(path) then
				return nil
			end
			return HttpService:JSONDecode(readfile(path))
		end)
		if ok and type(data) == "table" and type(data.paths) == "table" then
			for _, p in ipairs(data.paths) do
				if type(p) == "table" and type(p.start) == "table" and type(p.samples) == "table" then
					table.insert(S.spawnPaths, {
						id = tostring(p.id or newSpawnId()),
						name = tostring(p.name or "spawn"),
						placeId = p.placeId,
						start = p.start,
						finish = p.finish,
						samples = p.samples,
						sampleCount = type(p.samples) == "table" and #p.samples or (p.sampleCount or 0),
						created = p.created or "",
						pathrecFile = p.pathrecFile,
					})
				end
			end
		end
		if #S.spawnPaths > 0 then
			S.selectedSpawnPathId = S.spawnPaths[1].id
		end
		refreshSpawnList()
		if S.spawnPathVizEnabled then
			M.refreshSpawnPathViz()
		end
		return #S.spawnPaths
	end

	function M.saveSpawnPaths(): boolean
		local path = spawnFilePath()
		local dir = C.WAYPOINT_DIR or "waypoints"
		local payload = {
			version = 1,
			updated = os.date("%Y-%m-%d_%H-%M-%S"),
			paths = S.spawnPaths or {},
		}
		local ok, err = pcall(function()
			if U and U.ensureDir then
				U.ensureDir(dir)
			end
			writefile(path, HttpService:JSONEncode(payload))
		end)
		if not ok then
			setStatus("Spawn path save failed: " .. tostring(err))
			return false
		end
		return true
	end

	function M.listSpawnPaths(): { any }
		return S.spawnPaths or {}
	end

	function M.getSelectedSpawnPath(): any?
		local id = S.selectedSpawnPathId
		if not id then
			return nil
		end
		for _, p in ipairs(S.spawnPaths or {}) do
			if p.id == id then
				return p
			end
		end
		return nil
	end

	function M.setSelectedSpawnPath(id: string?)
		S.selectedSpawnPathId = id
	end

	function M.deleteSpawnPath(id: string?): boolean
		if not id then
			return false
		end
		local paths = S.spawnPaths or {}
		for i, p in ipairs(paths) do
			if p.id == id then
				table.remove(paths, i)
				if S.selectedSpawnPathId == id then
					S.selectedSpawnPathId = if #paths > 0 then paths[1].id else nil
				end
				M.saveSpawnPaths()
				refreshSpawnList()
				if S.spawnPathVizEnabled then
					M.refreshSpawnPathViz()
				end
				setStatus("Deleted spawn path: " .. tostring(p.name or id))
				return true
			end
		end
		return false
	end

	function M.addSpawnPathFromRecording(payload: any, pathrecFile: string?): any?
		if type(payload) ~= "table" then
			return nil
		end
		local samples = payload.samples
		if type(samples) ~= "table" or #samples < 2 then
			setStatus("Spawn path not saved — need ≥2 samples")
			return nil
		end
		local start = payload.start or samples[1]
		local finish = payload.finish or samples[#samples]
		if type(start) ~= "table" or type(start.x) ~= "number" then
			return nil
		end
		local id = newSpawnId()
		local name = string.format(
			"spawn_%.0f_%.0f_%.0f",
			start.x or 0,
			start.y or 0,
			start.z or 0
		)
		local entry = {
			id = id,
			name = name,
			placeId = game.PlaceId,
			start = {
				x = start.x,
				y = start.y,
				z = start.z,
			},
			finish = if type(finish) == "table"
				then { x = finish.x, y = finish.y, z = finish.z }
				else nil,
			samples = samples,
			sampleCount = #samples,
			created = os.date("%Y-%m-%d_%H-%M-%S"),
			pathrecFile = pathrecFile,
			duration = payload.duration,
		}
		if not S.spawnPaths then
			S.spawnPaths = {}
		end
		table.insert(S.spawnPaths, entry)
		S.selectedSpawnPathId = id
		M.saveSpawnPaths()
		refreshSpawnList()
		if S.spawnPathVizEnabled then
			M.refreshSpawnPathViz()
		end
		return entry
	end

	function M.clearSpawnPathViz()
		pcall(function()
			if S.spawnPathVizFolder and S.spawnPathVizFolder.Parent then
				S.spawnPathVizFolder:Destroy()
			end
			local f = workspace:FindFirstChild(SPAWN_VIZ_FOLDER)
			if f then
				f:Destroy()
			end
		end)
		S.spawnPathVizFolder = nil
	end

	function M.refreshSpawnPathViz()
		M.clearSpawnPathViz()
		if not S.spawnPathVizEnabled then
			return
		end
		local folder = Instance.new("Folder")
		folder.Name = SPAWN_VIZ_FOLDER
		folder.Parent = workspace
		S.spawnPathVizFolder = folder
		local n = 0
		for _, p in ipairs(S.spawnPaths or {}) do
			local st = p.start
			if type(st) == "table" and type(st.x) == "number" then
				n += 1
				local part = Instance.new("Part")
				part.Name = "Spawn_" .. tostring(p.id)
				part.Shape = Enum.PartType.Ball
				part.Size = Vector3.new(3.2, 3.2, 3.2)
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.CastShadow = false
				part.Material = Enum.Material.Neon
				part.Color = Color3.fromRGB(255, 200, 60)
				part.Transparency = 0.25
				part.CFrame = CFrame.new(st.x, (st.y or 0) + 2.2, st.z)
				part.Parent = folder
				local bb = Instance.new("BillboardGui")
				bb.Size = UDim2.fromOffset(120, 28)
				bb.StudsOffset = Vector3.new(0, 2.5, 0)
				bb.AlwaysOnTop = true
				bb.Parent = part
				local lab = Instance.new("TextLabel")
				lab.Size = UDim2.fromScale(1, 1)
				lab.BackgroundTransparency = 0.35
				lab.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
				lab.Font = Enum.Font.GothamBold
				lab.TextSize = 11
				lab.TextColor3 = Color3.fromRGB(255, 230, 120)
				lab.Text = tostring(p.name or p.id)
				lab.Parent = bb
			end
		end
		if U and U.setStatus then
			U.setStatus(string.format("Respawn points ON — %d start marker(s)", n))
		end
	end

	function M.setSpawnPathVizEnabled(on: boolean)
		S.spawnPathVizEnabled = on and true or false
		if S.ui and S.ui.setRespawnPathVizLabel then
			S.ui.setRespawnPathVizLabel(S.spawnPathVizEnabled)
		end
		if S.spawnPathVizEnabled then
			M.refreshSpawnPathViz()
		else
			M.clearSpawnPathViz()
			setStatus("Respawn points OFF")
		end
	end

	function M.toggleSpawnPathViz()
		M.setSpawnPathVizEnabled(not S.spawnPathVizEnabled)
	end

	---------------------------------------------------------------------------
	-- Post-respawn egress: closest recorded path within N studs of player
	---------------------------------------------------------------------------

	local function spawnStartVec(p: any): Vector3?
		local st = p and p.start
		if type(st) ~= "table" or type(st.x) ~= "number" or type(st.z) ~= "number" then
			return nil
		end
		return Vector3.new(st.x, st.y or 0, st.z)
	end

	-- Flat XZ distance to path start. Returns entry + dist, or nil if none within maxStuds.
	function M.findClosestSpawnPath(maxStuds: number?): (any?, number?)
		local lim = maxStuds or C.RESPAWN_PATH_MATCH_STUDS or 12
		local pos = U.getLivePlayerVector and U.getLivePlayerVector()
		if not pos then
			return nil, nil
		end
		local best: any? = nil
		local bestD = math.huge
		local nearestD = math.huge
		for _, p in ipairs(S.spawnPaths or {}) do
			local st = spawnStartVec(p)
			if st then
				local d = Vector3.new(pos.X - st.X, 0, pos.Z - st.Z).Magnitude
				if d < nearestD then
					nearestD = d
				end
				if d <= lim and d < bestD then
					best = p
					bestD = d
				end
			end
		end
		if best then
			return best, bestD
		end
		-- Expose nearest distance via status when nothing matched (debug pad jitter)
		if nearestD < math.huge and nearestD > lim then
			setStatus(string.format(
				"Spawn egress: nearest start %.1fst > limit %.0fst",
				nearestD,
				lim
			))
		end
		return nil, nil
	end

	local function samplesToWaypoints(samples: { any }, spacing: number): { Vector3 }
		local out: { Vector3 } = {}
		if type(samples) ~= "table" then
			return out
		end
		local last: Vector3? = nil
		for _, s in ipairs(samples) do
			if type(s) == "table" and type(s.x) == "number" and type(s.z) == "number" then
				local v = Vector3.new(s.x, s.y or 0, s.z)
				if not last then
					table.insert(out, v)
					last = v
				else
					local flat = Vector3.new(v.X - last.X, 0, v.Z - last.Z).Magnitude
					if flat >= spacing then
						table.insert(out, v)
						last = v
					end
				end
			end
		end
		-- Always keep the final sample so we finish at the recorded end
		local lastSamp = samples[#samples]
		if type(lastSamp) == "table" and type(lastSamp.x) == "number" then
			local endV = Vector3.new(lastSamp.x, lastSamp.y or 0, lastSamp.z)
			local tip = out[#out]
			if not tip or (endV - tip).Magnitude > 0.5 then
				table.insert(out, endV)
			end
		end
		return out
	end

	-- Walk a recorded spawn egress path (samples). Does not start Kill Aura.
	-- Returns true if followed to end (or already at end); false on cancel/fail.
	function M.playSpawnPath(entry: any, opts: any?): boolean
		opts = opts or {}
		if type(entry) ~= "table" then
			return false
		end
		local samples = entry.samples
		if type(samples) ~= "table" or #samples < 2 then
			setStatus("Spawn egress skipped — path has no samples")
			return false
		end
		local spacing = opts.spacing or C.RESPAWN_PATH_WP_SPACING or 3.5
		local wps = samplesToWaypoints(samples, spacing)
		if #wps < 1 then
			return false
		end

		S.spawnEgressBusy = true
		setStatus(string.format(
			"Spawn egress: %s (%d wps from %d samples)",
			tostring(entry.name or entry.id),
			#wps,
			#samples
		))

		local ok = false
		local nav = S.Nav
		if nav and nav.followPath then
			ok = nav.followPath(wps, {
				requireWalking = false,
				snapOnTimeout = false,
				arriveStuds = opts.arriveStuds or C.RESPAWN_PATH_ARRIVE or 2.8,
				timeout = opts.timeout or C.RESPAWN_PATH_SEG_TIMEOUT or 4.0,
				useMoveKeys = true,
				softTurn = true,
			}) == true
		else
			-- Fallback: sequential Util.walkTo
			ok = true
			for i, wp in ipairs(wps) do
				local hum = U.getHumanoid and U.getHumanoid()
				if not hum or hum.Health <= 0 then
					ok = false
					break
				end
				local arrived = U.walkTo(wp.X, wp.Y, wp.Z, {
					silent = true,
					snapOnTimeout = false,
					arriveStuds = opts.arriveStuds or C.RESPAWN_PATH_ARRIVE or 2.8,
					timeout = opts.timeout or C.RESPAWN_PATH_SEG_TIMEOUT or 4.0,
					useMoveKeys = true,
					softTurn = i == 1,
				})
				if not arrived then
					ok = false
					break
				end
			end
		end

		if U.releaseMoveKeys then
			U.releaseMoveKeys()
		end
		S.spawnEgressBusy = false
		if ok then
			setStatus(string.format("Spawn egress done — %s", tostring(entry.name or entry.id)))
		else
			setStatus(string.format("Spawn egress incomplete — %s", tostring(entry.name or entry.id)))
		end
		return ok
	end

	-- After regen: if a spawn-path start is within match studs, play it.
	-- Returns true if a path was found and playback ran (even if incomplete).
	function M.tryPlayClosestSpawnPath(maxStuds: number?): boolean
		if not S.spawnPaths or #S.spawnPaths == 0 then
			if M.loadSpawnPaths then
				M.loadSpawnPaths()
			end
		end
		local lim = maxStuds or C.RESPAWN_PATH_MATCH_STUDS or 12
		local entry, dist = M.findClosestSpawnPath(lim)
		if not entry then
			setStatus(string.format(
				"Spawn egress: no path start within %.0fst — skipping pathing",
				lim
			))
			return false
		end
		setStatus(string.format(
			"Spawn egress: closest %s @ %.1fst",
			tostring(entry.name or entry.id),
			dist or -1
		))
		M.playSpawnPath(entry)
		return true
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
		-- Also register as a spawn egress path (start = first sample / start snap)
		pcall(function()
			M.addSpawnPathFromRecording(payload, path)
		end)
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

	-- Load registry on module init
	task.defer(function()
		M.loadSpawnPaths()
	end)

	return M
end

-- portal_mage/waypoints.lua — named saved positions + recall teleport
return function(S)
	local C = S.Config
	local U = S.Util
	local HttpService = S.Services.HttpService
	local M = {}

	local function filePath(): string
		return C.WAYPOINT_FILE or "waypoints/waypoints.json"
	end

	local function newId(): string
		return string.format("%s_%04d", os.date("%Y%m%d%H%M%S"), math.random(0, 9999))
	end

	function M.load()
		local path = filePath()
		S.waypoints = {}
		S.selectedWaypointId = nil
		local ok, data = pcall(function()
			if not isfile or not isfile(path) then
				return nil
			end
			return HttpService:JSONDecode(readfile(path))
		end)
		if ok and type(data) == "table" and type(data.waypoints) == "table" then
			for _, wp in ipairs(data.waypoints) do
				if type(wp) == "table"
					and type(wp.name) == "string"
					and type(wp.x) == "number"
					and type(wp.y) == "number"
					and type(wp.z) == "number"
				then
					table.insert(S.waypoints, {
						id = tostring(wp.id or newId()),
						name = wp.name,
						x = wp.x,
						y = wp.y,
						z = wp.z,
						created = wp.created or os.date("%Y-%m-%d_%H-%M-%S"),
					})
				end
			end
		end
		if #S.waypoints > 0 then
			S.selectedWaypointId = S.waypoints[1].id
		end
		return #S.waypoints
	end

	function M.save(): boolean
		local path = filePath()
		local dir = C.WAYPOINT_DIR or "waypoints"
		local payload = {
			version = 1,
			updated = os.date("%Y-%m-%d_%H-%M-%S"),
			waypoints = S.waypoints,
		}
		local ok, err = pcall(function()
			U.ensureDir(dir)
			writefile(path, HttpService:JSONEncode(payload))
		end)
		if not ok then
			U.setStatus("Waypoint save failed: " .. tostring(err))
			return false
		end
		return true
	end

	function M.list()
		return S.waypoints
	end

	function M.findById(id: string?)
		if not id then
			return nil, nil
		end
		for i, wp in ipairs(S.waypoints) do
			if wp.id == id then
				return wp, i
			end
		end
		return nil, nil
	end

	function M.getSelected()
		return M.findById(S.selectedWaypointId)
	end

	function M.setSelected(id: string?)
		if id and M.findById(id) then
			S.selectedWaypointId = id
			return true
		end
		return false
	end

	local function uniqueName(base: string): string
		local name = base
		local n = 2
		while true do
			local taken = false
			for _, wp in ipairs(S.waypoints) do
				if wp.name == name then
					taken = true
					break
				end
			end
			if not taken then
				return name
			end
			name = string.format("%s (%d)", base, n)
			n += 1
		end
	end

	-- Mark current position. name optional (default WP #n / coordinates).
	function M.mark(name: string?): any?
		local _player, pos = U.getPlayerPosition()
		if not pos then
			U.setStatus("Waypoint mark failed: no player position")
			return nil
		end
		local base = name and string.gsub(name, "^%s*(.-)%s*$", "%1") or ""
		if base == "" then
			base = string.format("WP %d", #S.waypoints + 1)
		end
		local wp = {
			id = newId(),
			name = uniqueName(base),
			x = pos.x,
			y = pos.y,
			z = pos.z,
			created = os.date("%Y-%m-%d_%H-%M-%S"),
		}
		table.insert(S.waypoints, wp)
		S.selectedWaypointId = wp.id
		M.save()
		U.setStatus(string.format(
			"Waypoint saved: %s @ %.1f, %.1f, %.1f",
			wp.name,
			wp.x,
			wp.y,
			wp.z
		))
		return wp
	end

	function M.rename(id: string, newName: string): boolean
		local wp = M.findById(id)
		if not wp then
			U.setStatus("Rename failed: no waypoint selected")
			return false
		end
		local cleaned = string.gsub(newName or "", "^%s*(.-)%s*$", "%1")
		if cleaned == "" then
			U.setStatus("Rename failed: empty name")
			return false
		end
		-- Allow same name on self; otherwise uniquify
		local conflict = false
		for _, other in ipairs(S.waypoints) do
			if other.id ~= id and other.name == cleaned then
				conflict = true
				break
			end
		end
		if conflict then
			cleaned = uniqueName(cleaned)
		end
		wp.name = cleaned
		M.save()
		U.setStatus("Waypoint renamed: " .. wp.name)
		return true
	end

	function M.delete(id: string?): boolean
		local wp, idx = M.findById(id or S.selectedWaypointId)
		if not wp or not idx then
			U.setStatus("Delete failed: no waypoint selected")
			return false
		end
		local name = wp.name
		table.remove(S.waypoints, idx)
		if S.selectedWaypointId == wp.id then
			S.selectedWaypointId = if #S.waypoints > 0 then S.waypoints[1].id else nil
		end
		M.save()
		U.setStatus("Waypoint deleted: " .. name)
		return true
	end

	function M.recall(id: string?): boolean
		local wp = M.findById(id or S.selectedWaypointId)
		if not wp then
			U.setStatus("Recall failed: no waypoint selected")
			return false
		end
		local ok = U.teleportTo(wp.x, wp.y, wp.z, false)
		if ok then
			U.setStatus(string.format(
				"Recalled to %s (%.1f, %.1f, %.1f)",
				wp.name,
				wp.x,
				wp.y,
				wp.z
			))
		end
		return ok
	end

	---------------------------------------------------------------------------
	-- Live player scan + teleport
	---------------------------------------------------------------------------

	-- Returns { { name, userId, x, y, z }, ... } for other players with a position
	function M.scanPlayers(): { any }
		local Players = S.Services.Players
		local lp = Players.LocalPlayer
		local out = {}
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= lp then
				local char = plr.Character
				local pos = char and U.getCharacterLikePosition(char)
				if pos then
					table.insert(out, {
						name = plr.Name,
						displayName = plr.DisplayName,
						userId = plr.UserId,
						x = pos.X,
						y = pos.Y,
						z = pos.Z,
					})
				else
					table.insert(out, {
						name = plr.Name,
						displayName = plr.DisplayName,
						userId = plr.UserId,
						x = nil,
						y = nil,
						z = nil,
					})
				end
			end
		end
		table.sort(out, function(a, b)
			return a.name < b.name
		end)
		return out
	end

	function M.teleportToPlayer(playerName: string?): boolean
		if not playerName or playerName == "" then
			U.setStatus("TP to player: none selected")
			return false
		end
		local Players = S.Services.Players
		local plr = Players:FindFirstChild(playerName)
		if not plr or not plr:IsA("Player") then
			-- refresh by name match
			for _, p in ipairs(Players:GetPlayers()) do
				if p.Name == playerName then
					plr = p
					break
				end
			end
		end
		if not plr or not plr:IsA("Player") then
			U.setStatus("TP to player: " .. playerName .. " not in server")
			return false
		end
		local char = plr.Character
		local pos = char and U.getCharacterLikePosition(char)
		if not pos then
			U.setStatus("TP to player: " .. playerName .. " has no character/position")
			return false
		end
		local ok = U.teleportTo(pos.X, pos.Y, pos.Z, false)
		if ok then
			U.setStatus(string.format(
				"Teleported to %s (%.1f, %.1f, %.1f)",
				playerName,
				pos.X,
				pos.Y,
				pos.Z
			))
		end
		return ok
	end

	-- Load on module init
	pcall(M.load)

	return M
end

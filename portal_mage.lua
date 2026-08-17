--[[
  Portal Mage — modular bootstrap (robocks)

  Loader:
    loadstring(game:HttpGet("https://raw.githubusercontent.com/terrydavis903/robocks/main/loader.lua"))()

  Local (no network): put portal_mage.lua + portal_mage/*.lua in executor workspace
  and execute portal_mage.lua, or set getgenv().ROBOCKS_OFFLINE = true
]]

local FROM_LOADER = getgenv and getgenv().ROBOCKS_FROM_LOADER == true
local OWNER = (getgenv and getgenv().ROBOCKS_OWNER) or "terrydavis903"
local REPO = (getgenv and getgenv().ROBOCKS_REPO) or "robocks"
local BRANCH = (getgenv and getgenv().ROBOCKS_BRANCH) or "main"
local REMOTE_BASE = (getgenv and getgenv().ROBOCKS_BASE)
	or ("https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPO .. "/" .. BRANCH .. "/")

local USE_CACHE = not (getgenv and getgenv().ROBOCKS_CACHE == false)
local OFFLINE = getgenv and getgenv().ROBOCKS_OFFLINE == true
-- Local execution: prefer files on disk. Loader: prefer GitHub, cache after fetch.
local PREFER_LOCAL = OFFLINE or not FROM_LOADER

local CACHE_ROOTS = {
	"robocks/portal_mage/",
	"workspace/robocks/portal_mage/",
	"portal_mage/",
	"scripts/portal_mage/",
}

local function httpGet(url)
	if syn and syn.request then
		local res = syn.request({ Url = url, Method = "GET" })
		if res and type(res.Body) == "string" and res.StatusCode == 200 then
			return res.Body
		end
		error("syn.request " .. tostring(res and res.StatusCode))
	end
	if request then
		local res = request({ Url = url, Method = "GET" })
		if res and type(res.Body) == "string" then
			return res.Body
		end
	end
	local body = game:HttpGet(url)
	if type(body) ~= "string" or body == "" then
		error("HttpGet empty")
	end
	if string.find(body, "404: Not Found", 1, true) then
		error("404")
	end
	return body
end

local function ensureCacheDirs()
	if not makefolder then
		return
	end
	pcall(function()
		if not isfolder or not isfolder("robocks") then
			makefolder("robocks")
		end
	end)
	pcall(function()
		if not isfolder or not isfolder("robocks/portal_mage") then
			makefolder("robocks/portal_mage")
		end
	end)
end

local function cacheWrite(relPath, src)
	if not USE_CACHE or not writefile then
		return
	end
	pcall(function()
		ensureCacheDirs()
		writefile("robocks/portal_mage/" .. relPath, src)
	end)
end

local function tryReadLocal(relName)
	if not (isfile and readfile) then
		return nil
	end
	for _, root in ipairs(CACHE_ROOTS) do
		local path = root .. relName
		local ok, exists = pcall(function()
			return isfile(path)
		end)
		if ok and exists then
			local okR, src = pcall(readfile, path)
			if okR and type(src) == "string" and #src > 0 then
				return src
			end
		end
	end
	return nil
end

local function fetchModule(name)
	local rel = name .. ".lua"

	if PREFER_LOCAL then
		local localSrc = tryReadLocal(rel)
		if localSrc then
			return localSrc, "local"
		end
		if OFFLINE then
			error("[portal_mage] offline missing: " .. rel)
		end
	end

	-- Remote (loader / missing local)
	local url = REMOTE_BASE .. "portal_mage/" .. rel
	local ok, src = pcall(httpGet, url)
	if ok and type(src) == "string" then
		cacheWrite(rel, src)
		return src, "remote"
	end

	local localSrc = tryReadLocal(rel)
	if localSrc then
		warn("[portal_mage] remote fail, local fallback: " .. rel)
		return localSrc, "local-fallback"
	end

	error("[portal_mage] missing module: " .. name .. " (" .. tostring(src) .. ")")
end

local function import(name)
	local src = fetchModule(name)
	-- Yield so 17× HttpGet does not freeze/crash the client
	task.wait()
	local chunk, err = loadstring(src, "@portal_mage/" .. name .. ".lua")
	if not chunk then
		error("compile failed " .. name .. ": " .. tostring(err))
	end
	local ok, result = pcall(chunk)
	if not ok then
		error("exec failed " .. name .. ": " .. tostring(result))
	end
	return result
end

print("[portal_mage] boot prefer_local=" .. tostring(PREFER_LOCAL) .. " base=" .. REMOTE_BASE)

-- 1) shared + config
local S = import("shared")
if type(S) ~= "table" then
	error("shared did not return state table")
end
S.Config = import("config")
if type(S.Config) ~= "table" then
	error("config did not return table")
end

-- Claw prize priority: always from disk claw_priority.lua (never HttpGet).
-- Create defaults if missing. Config tab edits call S.ClawPriority.save.
do
	local CLAW_PRIORITY_REL = "claw_priority.lua"
	local CLAW_PRIORITY_DEFAULT = [=[-- portal_mage/claw_priority.lua — claw prize pick order (local config)
--
-- Edit via the Config tab or by hand. Lower tier = grab first.
-- Unmatched prizes ("others") use the first empty tier (1–10), else 11.
-- Prefer longer keys before shorter substrings when hand-editing.

return {
	{ key = "spirit", tier = 2 },
	{ key = "enchantedbark", tier = 4 },
	{ key = "heartwood", tier = 4 },
	{ key = "enchantedwood", tier = 5 },
	{ key = "mysticessence", tier = 6 },
	{ key = "briarvine", tier = 6 },
	{ key = "memorysap", tier = 6 },
	{ key = "goblincoin", tier = 3 },
	{ key = "aurorite", tier = 7 },
	{ key = "junkcore", tier = 7 },
	{ key = "glowingmoss", tier = 6 },
	{ key = "grimoire", tier = 1 },
	{ key = "circuit", tier = 1 },
	{ key = "meteor", tier = 1 },
	{ key = "timber", tier = 1 },
	{ key = "aurora", tier = 1 },
	{ key = "amber", tier = 3 },
	{ key = "living", tier = 3 },
	{ key = "tome", tier = 1 },
	{ key = "triacoin", tier = 9 },
	{ key = "triapouch", tier = 9 },
	{ key = "triasack", tier = 9 },
	{ key = "tria", tier = 9 },
	{ key = "scrapmetal", tier = 9 },
	{ key = "rustygear", tier = 9 },
	{ key = "solite", tier = 9 },
	{ key = "lumite", tier = 9 },
}
]=]

	local function clawPriorityWritePath()
		if isfolder then
			for _, root in ipairs(CACHE_ROOTS) do
				local dir = string.gsub(root, "/$", "")
				local ok, exists = pcall(function()
					return isfolder(dir)
				end)
				if ok and exists then
					return root .. CLAW_PRIORITY_REL
				end
			end
		end
		return "robocks/portal_mage/" .. CLAW_PRIORITY_REL
	end

	local function ensureParentFolder(path)
		if not makefolder then
			return
		end
		local parts = {}
		for part in string.gmatch(path, "[^/\\]+") do
			table.insert(parts, part)
		end
		if #parts < 2 then
			return
		end
		local acc = parts[1]
		pcall(function()
			if not isfolder or not isfolder(acc) then
				makefolder(acc)
			end
		end)
		for i = 2, #parts - 1 do
			acc = acc .. "/" .. parts[i]
			pcall(function()
				if not isfolder or not isfolder(acc) then
					makefolder(acc)
				end
			end)
		end
	end

	local function normalizeKeywordList(list)
		if type(list) ~= "table" then
			return {}
		end
		local out = {}
		local seen = {}
		for _, e in ipairs(list) do
			if type(e) == "table" and type(e.key) == "string" then
				local key = string.lower((e.key:gsub("[^%w]", "")))
				local tier = math.floor(tonumber(e.tier) or 0)
				if key ~= "" and tier >= 1 and tier <= 10 and not seen[key] then
					seen[key] = true
					table.insert(out, { key = key, tier = tier })
				end
			end
		end
		-- Longer keys first so substring matches stay correct after UI edits
		table.sort(out, function(a, b)
			if #a.key ~= #b.key then
				return #a.key > #b.key
			end
			if a.tier ~= b.tier then
				return a.tier < b.tier
			end
			return a.key < b.key
		end)
		return out
	end

	local function parseClawPrioritySource(src)
		local chunk, cerr = loadstring(src, "@portal_mage/claw_priority.lua")
		if not chunk then
			warn("[portal_mage] claw_priority compile failed: " .. tostring(cerr))
			return nil
		end
		local ok, result = pcall(chunk)
		if not ok then
			warn("[portal_mage] claw_priority exec failed: " .. tostring(result))
			return nil
		end
		if type(result) ~= "table" then
			warn("[portal_mage] claw_priority must return a table")
			return nil
		end
		return normalizeKeywordList(result)
	end

	local function serializeClawPriority(list)
		local lines = {
			"-- portal_mage/claw_priority.lua — claw prize pick order (local config)",
			"--",
			"-- Edit via the Config tab or by hand. Lower tier = grab first.",
			"-- Unmatched prizes (\"others\") use the first empty tier (1–10), else 11.",
			"",
			"return {",
		}
		for _, e in ipairs(list) do
			table.insert(lines, string.format('\t{ key = %q, tier = %d },', e.key, e.tier))
		end
		table.insert(lines, "}")
		return table.concat(lines, "\n") .. "\n"
	end

	local function othersTierFor(list)
		local used = {}
		for _, e in ipairs(list) do
			used[e.tier] = true
		end
		for t = 1, 10 do
			if not used[t] then
				return t
			end
		end
		return 11
	end

	local CP = {
		path = nil,
		TIER_COUNT = 10,
	}

	function CP.getKeywords()
		return normalizeKeywordList(S.Config.CLAW_PRIORITY_KEYWORDS)
	end

	function CP.othersTier(list)
		return othersTierFor(list or CP.getKeywords())
	end

	function CP.apply(list)
		local normalized = normalizeKeywordList(list)
		S.Config.CLAW_PRIORITY_KEYWORDS = normalized
		return normalized
	end

	function CP.save(list)
		local normalized = CP.apply(list)
		local path = CP.path or clawPriorityWritePath()
		CP.path = path
		if not writefile then
			warn("[portal_mage] claw_priority save: no writefile")
			return false, "no writefile"
		end
		ensureParentFolder(path)
		local src = serializeClawPriority(normalized)
		local ok, err = pcall(writefile, path, src)
		if not ok then
			warn("[portal_mage] claw_priority save failed: " .. tostring(err))
			return false, tostring(err)
		end
		return true, path
	end

	function CP.reload()
		local src = tryReadLocal(CLAW_PRIORITY_REL)
		if not src and CP.path and isfile and isfile(CP.path) then
			local okR, body = pcall(readfile, CP.path)
			if okR and type(body) == "string" then
				src = body
			end
		end
		if not src then
			return nil, "missing"
		end
		local keywords = parseClawPrioritySource(src)
		if not keywords then
			return nil, "invalid"
		end
		CP.apply(keywords)
		return keywords
	end

	-- Boot: load or create
	local src = tryReadLocal(CLAW_PRIORITY_REL)
	local created = false
	CP.path = clawPriorityWritePath()
	-- Prefer path of an existing file under CACHE_ROOTS
	if isfile and readfile then
		for _, root in ipairs(CACHE_ROOTS) do
			local p = root .. CLAW_PRIORITY_REL
			local ok, exists = pcall(function()
				return isfile(p)
			end)
			if ok and exists then
				CP.path = p
				break
			end
		end
	end

	if not src then
		if writefile then
			ensureParentFolder(CP.path)
			local wok, werr = pcall(writefile, CP.path, CLAW_PRIORITY_DEFAULT)
			if wok then
				created = true
				src = CLAW_PRIORITY_DEFAULT
				print("[portal_mage] claw_priority created: " .. CP.path)
			else
				warn("[portal_mage] claw_priority write failed (" .. tostring(werr) .. "); using embedded defaults")
				src = CLAW_PRIORITY_DEFAULT
			end
		else
			warn("[portal_mage] no writefile; claw_priority missing — using embedded defaults")
			src = CLAW_PRIORITY_DEFAULT
		end
	end

	local keywords = parseClawPrioritySource(src)
	if keywords then
		CP.apply(keywords)
		print(
			"[portal_mage] claw_priority loaded ("
				.. #keywords
				.. " keywords, others=T"
				.. tostring(CP.othersTier(keywords))
				.. (created and ", new file" or "")
				.. ")"
		)
	else
		local fallback = parseClawPrioritySource(CLAW_PRIORITY_DEFAULT)
		if fallback then
			CP.apply(fallback)
			warn("[portal_mage] claw_priority invalid on disk; embedded defaults applied")
		end
	end

	S.ClawPriority = CP
end

local function loadFactory(name)
	local factory = import(name)
	if type(factory) ~= "function" then
		error(name .. " is not a factory")
	end
	local ok, mod = pcall(factory, S)
	if not ok then
		error(name .. " factory error: " .. tostring(mod))
	end
	return mod
end

local function tryFactory(name)
	local ok, mod = pcall(loadFactory, name)
	if ok then
		return mod
	end
	warn("[portal_mage] optional module failed: " .. name .. " — " .. tostring(mod))
	return nil
end

-- 2) core modules (required)
S.Util = loadFactory("util")
S.Dump = tryFactory("dump")
S.Targets = loadFactory("targets")
S.Abilities = loadFactory("abilities")
S.Combat = loadFactory("combat")
S.Nav = tryFactory("nav")
S.Pathing = loadFactory("pathing")
S.Waypoints = tryFactory("waypoints")
S.Respawn = loadFactory("respawn")
S.Proximity = loadFactory("proximity")
S.PlayerBlacklist = tryFactory("player_blacklist")

-- 3) optional / heavy (claw is large — isolate failures)
S.Claw = tryFactory("claw")
S.Ore = tryFactory("ore")
S.Esp = tryFactory("esp")
S.AutoOre = tryFactory("auto_ore")
S.PathRecord = tryFactory("path_record")
S.MeshOutline = tryFactory("mesh_outline")
S.UI = loadFactory("ui")

-- 4) start (guarded)
local function start()
	S.UI.build()
	if S.Respawn and S.Respawn.start then
		S.Respawn.start()
	end
	if S.Util and S.Util.startAntiAfk then
		S.Util.startAntiAfk()
	end
	if S.Proximity and S.Proximity.start then
		S.Proximity.start()
	end
	if S.PlayerBlacklist and S.PlayerBlacklist.start then
		S.PlayerBlacklist.start()
	end

	if S.ui.setProxLabel then
		S.ui.setProxLabel(S.proximityGuardEnabled)
	end
	if S.ui.setAntiAfkLabel then
		S.ui.setAntiAfkLabel(S.antiAfkEnabled)
	end
	if S.ui.setOreEspLabel then
		S.ui.setOreEspLabel(S.oreEspEnabled)
	end
	if S.ui.setPlayerEspLabel then
		S.ui.setPlayerEspLabel(S.playerEspEnabled == true)
	end
	if S.ui.setEnemyEspLabel then
		S.ui.setEnemyEspLabel(S.enemyEspEnabled == true)
	end
	if S.ui.setAutoOreLabel then
		S.ui.setAutoOreLabel(S.autoOreEnabled == true)
	end
	if S.ui.setMeshOutlineLabel then
		S.ui.setMeshOutlineLabel(S.meshOutlineEnabled)
	end
	if S.ui.setPathVizLabel then
		S.ui.setPathVizLabel(S.pathVizEnabled == true)
	end
	if S.ui.setPathRecLabel then
		S.ui.setPathRecLabel(S.pathRecEnabled == true)
	end
	S.walkSpeedValue = (S.Config and S.Config.WALK_SPEED_DEFAULT) or 32
	if S.ui.setWalkSpeedLabel then
		S.ui.setWalkSpeedLabel(S.walkSpeedEnabled, S.walkSpeedValue)
	end
	if S.ui.setClawBeamLabel then
		S.ui.setClawBeamLabel(S.clawBeamEnabled)
	end
	if S.ui.setClawPrizeBeamsLabel then
		S.ui.setClawPrizeBeamsLabel(S.clawPrizeBeamsEnabled)
	end
	if S.ui.setClawBestPrizeLabel then
		S.ui.setClawBestPrizeLabel(S.clawPrizeBeamsBestOnly)
	end

	if not S.Nav then
		S.ui.setStatus("Nav failed — Kill Aura pathing limited")
	elseif not S.Claw then
		S.ui.setStatus("Ready (claw optional failed) — Kill Aura OK")
	else
		S.ui.setStatus("Ready — robocks | Kill Aura path→@30→R→schema")
	end
end

local okStart, startErr = pcall(start)
if not okStart then
	warn("[portal_mage] start failed: " .. tostring(startErr))
	pcall(function()
		if S.ui and S.ui.setStatus then
			S.ui.setStatus("START ERROR: " .. tostring(startErr))
		end
	end)
end

if getgenv then
	getgenv().PortalMage = S
end

print("[portal_mage] boot complete")
return S

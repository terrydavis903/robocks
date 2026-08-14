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

-- 3) optional / heavy (claw is large — isolate failures)
S.Claw = tryFactory("claw")
S.Farm = tryFactory("farm")
S.Ore = tryFactory("ore")
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

	if S.ui.setProxLabel then
		S.ui.setProxLabel(S.proximityGuardEnabled)
	end
	if S.ui.setAntiAfkLabel then
		S.ui.setAntiAfkLabel(S.antiAfkEnabled)
	end
	if S.ui.setEmptyPlotLabel then
		S.ui.setEmptyPlotLabel(S.farmEmptyHighlightEnabled)
	end
	if S.ui.setOreEspLabel then
		S.ui.setOreEspLabel(S.oreEspEnabled)
	end
	if S.ui.setMeshOutlineLabel then
		S.ui.setMeshOutlineLabel(S.meshOutlineEnabled)
	end
	if S.ui.setPathVizLabel then
		S.ui.setPathVizLabel(S.pathVizEnabled == true)
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

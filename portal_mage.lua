--[[
  Portal Mage — modular bootstrap (robocks)

  Prefer loading via loader.lua:
    loadstring(game:HttpGet("https://raw.githubusercontent.com/terrydavis903/robocks/main/loader.lua"))()

  Modules: portal_mage/*.lua (GitHub raw or local isfile/readfile)
]]

local OWNER = (getgenv and getgenv().ROBOCKS_OWNER) or "terrydavis903"
local REPO = (getgenv and getgenv().ROBOCKS_REPO) or "robocks"
local BRANCH = (getgenv and getgenv().ROBOCKS_BRANCH) or "main"
local REMOTE_BASE = (getgenv and getgenv().ROBOCKS_BASE)
	or string.format("https://raw.githubusercontent.com/%s/%s/%s/", OWNER, REPO, BRANCH)

local USE_CACHE = true
if getgenv and getgenv().ROBOCKS_CACHE == false then
	USE_CACHE = false
end
local OFFLINE = getgenv and getgenv().ROBOCKS_OFFLINE == true

local CACHE_ROOTS = {
	"robocks/portal_mage/",
	"workspace/robocks/portal_mage/",
	"portal_mage/",
	"scripts/portal_mage/",
}

local MODULE_ORDER_HINT = {
	"shared",
	"config",
	"util",
	"dump",
	"targets",
	"abilities",
	"combat",
	"nav",
	"pathing",
	"waypoints",
	"respawn",
	"proximity",
	"claw",
	"farm",
	"ore",
	"mesh_outline",
	"ui",
}

local function httpGet(url: string): string
	local body: string? = nil
	local ok, err = pcall(function()
		if typeof(game.HttpGet) == "function" then
			body = game:HttpGet(url)
		elseif typeof(game.HttpGetAsync) == "function" then
			body = game:HttpGetAsync(url)
		else
			error("HttpGet not available")
		end
	end)
	if not ok or type(body) ~= "string" or body == "" then
		error("HttpGet failed: " .. tostring(url) .. " — " .. tostring(err or body))
	end
	if string.find(body, "404: Not Found", 1, true) then
		error("404 Not Found: " .. url)
	end
	return body
end

local function ensureDir(path: string)
	if not makefolder then
		return
	end
	local parts = string.split(path, "/")
	local acc = ""
	for _, p in ipairs(parts) do
		if p ~= "" and not string.find(p, "%.lua$") then
			acc = if acc == "" then p else (acc .. "/" .. p)
			pcall(function()
				if isfolder and not isfolder(acc) then
					makefolder(acc)
				elseif not isfolder then
					makefolder(acc)
				end
			end)
		end
	end
end

local function cacheWrite(relPath: string, src: string)
	if not USE_CACHE or not writefile then
		return
	end
	local path = "robocks/portal_mage/" .. relPath
	pcall(function()
		ensureDir(path)
		writefile(path, src)
	end)
end

local function tryReadLocal(relName: string): string?
	if not (isfile and readfile) then
		return nil
	end
	for _, root in ipairs(CACHE_ROOTS) do
		local path = root .. relName
		local ok, exists = pcall(function()
			return isfile(path)
		end)
		if ok and exists then
			local okR, src = pcall(function()
				return readfile(path)
			end)
			if okR and type(src) == "string" and src ~= "" then
				return src
			end
		end
	end
	return nil
end

local function fetchModule(name: string): string
	local rel = name .. ".lua"

	if OFFLINE then
		local localSrc = tryReadLocal(rel)
		if localSrc then
			return localSrc
		end
		error("[portal_mage] offline: missing " .. rel)
	end

	-- Prefer remote (always fresh from GitHub), then fall back to cache/local
	local url = REMOTE_BASE .. "portal_mage/" .. rel
	local ok, srcOrErr = pcall(httpGet, url)
	if ok and type(srcOrErr) == "string" then
		cacheWrite(rel, srcOrErr)
		return srcOrErr
	end

	local localSrc = tryReadLocal(rel)
	if localSrc then
		warn("[portal_mage] remote fail, using local: " .. rel .. " (" .. tostring(srcOrErr) .. ")")
		return localSrc
	end

	error("[portal_mage] module not found: " .. name .. " — " .. tostring(srcOrErr))
end

local function import(name: string)
	local src = fetchModule(name)
	local chunk, err = loadstring(src, "@portal_mage/" .. name .. ".lua")
	if not chunk then
		error("load failed portal_mage/" .. name .. ".lua: " .. tostring(err))
	end
	return chunk()
end

-- 1) shared state + config
local S = import("shared")
S.Config = import("config")

-- 2) leaf modules (factories taking S)
S.Util = import("util")(S)
S.Dump = import("dump")(S)
S.Targets = import("targets")(S)
S.Abilities = import("abilities")(S)
S.Combat = import("combat")(S)
do
	local okNav, navMod = pcall(function()
		return import("nav")(S)
	end)
	if okNav then
		S.Nav = navMod
	else
		S.Nav = nil
		warn("[portal_mage] nav module failed to load: " .. tostring(navMod))
	end
end
S.Pathing = import("pathing")(S)
S.Waypoints = import("waypoints")(S)
S.Respawn = import("respawn")(S)
S.Proximity = import("proximity")(S)
do
	local okClaw, clawMod = pcall(function()
		return import("claw")(S)
	end)
	if okClaw then
		S.Claw = clawMod
	else
		S.Claw = nil
		warn("[portal_mage] claw module failed to load: " .. tostring(clawMod))
	end
end
do
	local okFarm, farmMod = pcall(function()
		return import("farm")(S)
	end)
	if okFarm then
		S.Farm = farmMod
	else
		S.Farm = nil
		warn("[portal_mage] farm module failed to load: " .. tostring(farmMod))
	end
end
do
	local okOre, oreMod = pcall(function()
		return import("ore")(S)
	end)
	if okOre then
		S.Ore = oreMod
	else
		S.Ore = nil
		warn("[portal_mage] ore module failed to load: " .. tostring(oreMod))
	end
end
do
	local okMesh, meshMod = pcall(function()
		return import("mesh_outline")(S)
	end)
	if okMesh then
		S.MeshOutline = meshMod
	else
		S.MeshOutline = nil
		warn("[portal_mage] mesh_outline module failed to load: " .. tostring(meshMod))
	end
end
S.UI = import("ui")(S)

-- 3) start
S.UI.build()
S.Respawn.start()
S.Util.startAntiAfk() -- default ON; toggle on Bot tab
S.Proximity.start()
S.ui.setProxLabel(S.proximityGuardEnabled)
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
S.walkSpeedValue = S.Config.WALK_SPEED_DEFAULT or 32
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
if not S.Claw then
	S.ui.setStatus("Claw module failed to load — check executor console for warn")
end
if not S.Nav then
	S.ui.setStatus("Nav module failed — Kill Aura needs floor pathfinding")
else
	S.ui.setStatus("Ready — robocks loader | Kill Aura: path→@30→R→schema→CDs")
end

-- expose for debug
if getgenv then
	getgenv().PortalMage = S
end

return S

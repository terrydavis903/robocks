--[[
  robocks loader
  https://github.com/terrydavis903/robocks

  Run in executor:
    loadstring(game:HttpGet("https://raw.githubusercontent.com/terrydavis903/robocks/main/loader.lua"))()
]]

local OWNER = "terrydavis903"
local REPO = "robocks"
local BRANCH = "main"
if getgenv and type(getgenv().ROBOCKS_BRANCH) == "string" and getgenv().ROBOCKS_BRANCH ~= "" then
	BRANCH = getgenv().ROBOCKS_BRANCH
end

local BASE = "https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPO .. "/" .. BRANCH .. "/"

if getgenv then
	getgenv().ROBOCKS_BASE = BASE
	getgenv().ROBOCKS_OWNER = OWNER
	getgenv().ROBOCKS_REPO = REPO
	getgenv().ROBOCKS_BRANCH = BRANCH
	getgenv().ROBOCKS_FROM_LOADER = true
end

local function httpGet(url)
	-- Prefer request libraries that some executors need; fall back to game:HttpGet
	if syn and syn.request then
		local res = syn.request({ Url = url, Method = "GET" })
		if res and res.Body and res.StatusCode == 200 then
			return res.Body
		end
		error("syn.request failed: " .. tostring(res and res.StatusCode))
	end
	if request then
		local res = request({ Url = url, Method = "GET" })
		if res and res.Body and (res.StatusCode == 200 or res.StatusCode == nil) then
			return res.Body
		end
	end
	if http_request then
		local res = http_request({ Url = url, Method = "GET" })
		if res and res.Body then
			return res.Body
		end
	end
	local body = game:HttpGet(url)
	if type(body) ~= "string" or body == "" then
		error("HttpGet empty: " .. url)
	end
	if string.find(body, "404: Not Found", 1, true) then
		error("404: " .. url)
	end
	return body
end

local url = BASE .. "portal_mage.lua"
print("[robocks] fetching " .. url)

local ok, src = pcall(httpGet, url)
if not ok then
	error("[robocks] fetch failed: " .. tostring(src))
end

local chunk, err = loadstring(src, "@robocks/portal_mage.lua")
if not chunk then
	error("[robocks] loadstring failed: " .. tostring(err))
end

-- Run in a fresh thread so module loads can task.wait (avoids hard freeze/crash)
task.spawn(function()
	local okRun, runErr = pcall(chunk)
	if not okRun then
		warn("[robocks] portal_mage error: " .. tostring(runErr))
	else
		print("[robocks] portal_mage loaded OK")
	end
end)

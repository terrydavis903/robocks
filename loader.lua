--[[
  robocks loader
  Repo: https://github.com/terrydavis903/robocks

  Executor usage (one line):
    loadstring(game:HttpGet("https://raw.githubusercontent.com/terrydavis903/robocks/main/loader.lua"))()

  Optional before load:
    getgenv().ROBOCKS_BRANCH = "main"          -- default main
    getgenv().ROBOCKS_CACHE  = true            -- write modules under workspace/robocks/ (default true)
    getgenv().ROBOCKS_OFFLINE = true           -- prefer local cache / scripts only (no HttpGet)
]]

local OWNER = "terrydavis903"
local REPO = "robocks"
local BRANCH = (getgenv and getgenv().ROBOCKS_BRANCH) or "main"
local BASE = string.format(
	"https://raw.githubusercontent.com/%s/%s/%s/",
	OWNER,
	REPO,
	BRANCH
)

if getgenv then
	getgenv().ROBOCKS_BASE = BASE
	getgenv().ROBOCKS_OWNER = OWNER
	getgenv().ROBOCKS_REPO = REPO
	getgenv().ROBOCKS_BRANCH = BRANCH
end

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
	-- GitHub soft-404 HTML
	if string.find(body, "404: Not Found", 1, true) then
		error("404 Not Found: " .. url)
	end
	return body
end

local function bootstrapUrl(): string
	return BASE .. "portal_mage.lua"
end

print(string.format("[robocks] loading portal_mage from %s", bootstrapUrl()))

local src = httpGet(bootstrapUrl())
local chunk, err = loadstring(src, "@robocks/portal_mage.lua")
if not chunk then
	error("[robocks] loadstring failed: " .. tostring(err))
end
chunk()
print("[robocks] portal_mage loaded")

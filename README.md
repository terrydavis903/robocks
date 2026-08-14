# robocks

Roblox executor scripts (Portal Mage).

## Load

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/terrydavis903/robocks/main/loader.lua"))()
```

If that freezes, try once after a rejoin (first run downloads ~15 modules).

### Local-only (no GitHub)

Put `portal_mage.lua` + `portal_mage/*.lua` in the executor workspace and run `portal_mage.lua`,  
**or** set before loading:

```lua
getgenv().ROBOCKS_OFFLINE = true
```

### Options

```lua
getgenv().ROBOCKS_BRANCH = "main"
getgenv().ROBOCKS_CACHE  = true   -- save under robocks/portal_mage/
getgenv().ROBOCKS_OFFLINE = false -- true = never HttpGet modules
```

## Notes

- Loader runs bootstrap in `task.spawn` so loads can `task.wait` (avoids client freeze).
- Local `portal_mage.lua` prefers **disk files first**; GitHub loader prefers **remote then cache**.
- Heavy modules (claw, dump, …) are optional — failure won’t kill the whole boot.

### Claw prize priority

Tiers always come from a **local disk file**: `portal_mage/claw_priority.lua`  
(lower tier number = grab first). Never fetched from GitHub.

- First boot creates the file with defaults if it is missing (under `robocks/portal_mage/` or whichever module folder already exists).
- Edit `{ key = "...", tier = N }` and reload. Console: `claw_priority loaded (N keywords)`.
- Keep longer keys before shorter substrings (`aurorite` before `aurora`).

## Layout

```
loader.lua
portal_mage.lua
portal_mage/*.lua
```

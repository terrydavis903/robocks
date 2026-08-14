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

- First boot creates the file with defaults if missing.
- **In-game:** open the **Config** tab — 10 tiers, `+` to add keywords, `x` to remove (auto-saves).
- Unmatched prizes (“others”) use the first empty tier (1–10), else 11.
- Hand-edit the file and reload if you prefer.

## Layout

```
loader.lua
portal_mage.lua
portal_mage/*.lua
```

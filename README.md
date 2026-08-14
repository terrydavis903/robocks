# robocks

Roblox executor scripts (Portal Mage / kill aura, claw, dumps).

## Load (executor)

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/terrydavis903/robocks/main/loader.lua"))()
```

That pulls `portal_mage.lua` + every module under `portal_mage/` from this repo.

### Options (set before loadstring)

```lua
getgenv().ROBOCKS_BRANCH = "main"   -- branch
getgenv().ROBOCKS_CACHE  = true     -- write modules to workspace/robocks/ (default true)
getgenv().ROBOCKS_OFFLINE = false   -- true = only local isfile/readfile, no HttpGet
```

## Layout

```
loader.lua              -- one-line entry (HttpGet bootstrap)
portal_mage.lua         -- modular bootstrap
portal_mage/
  config.lua            -- constants & COMBAT_HANDLERS
  shared.lua            -- services + state
  util.lua              -- keys, positions, walk
  targets.lua           -- mobs, reticle, hold, path pick
  abilities.lua         -- handlers, slot toggle, cast
  combat.lua            -- fight loop
  nav.lua               -- floor A* + path viz
  pathing.lua           -- Kill Aura walk / kite
  ui.lua / claw / dump / …
```

## Local Potassium

Same tree can live under the executor workspace:

```
portal_mage.lua
portal_mage/*.lua
```

Or after first remote load, cache at `robocks/portal_mage/`.

## License

Private / personal use unless noted otherwise.

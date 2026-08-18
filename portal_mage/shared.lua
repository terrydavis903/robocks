-- portal_mage/shared.lua — services + mutable runtime state
local S = {}

S.Services = {
	VirtualInputManager = game:GetService("VirtualInputManager"),
	UserInputService = game:GetService("UserInputService"),
	HttpService = game:GetService("HttpService"),
	Players = game:GetService("Players"),
	CoreGui = game:GetService("CoreGui"),
	GuiService = game:GetService("GuiService"),
	CollectionService = game:GetService("CollectionService"),
}

-- UI hooks (filled by ui.lua after build)
S.ui = {
	setStatus = function(_text: string) end,
	setWalkLabel = function(_on: boolean) end, -- Kill Aura toggle label
	setKillAuraLabel = function(_on: boolean) end, -- alias of setWalkLabel
	setProxLabel = function(_on: boolean) end,
	setAntiAfkLabel = function(_on: boolean) end,
	setWalkSpeedLabel = function(_on: boolean, _speed: number?) end,
	setOreEspLabel = function(_on: boolean) end,
	setPlayerEspLabel = function(_on: boolean) end,
	setEnemyEspLabel = function(_on: boolean) end,
	setAutoOreLabel = function(_on: boolean) end,
	setMeshOutlineLabel = function(_on: boolean) end,
	setPathVizLabel = function(_on: boolean) end, -- A* path lines
	setHitboxVizLabel = function(_on: boolean) end, -- clearance hitbox probes
	setPathRecLabel = function(_on: boolean) end, -- human A* walk recorder
	setRespawnPathVizLabel = function(_on: boolean) end, -- spawn-path start markers
	refreshSpawnPaths = function() end, -- refresh spawn-path picker list
	refreshWalkableMaterials = function() end, -- Waypoints walkable-tile list label
	setClawBeamLabel = function(_on: boolean) end,
	setClawPrizeBeamsLabel = function(_on: boolean) end,
	setClawBestPrizeLabel = function(_on: boolean) end,
	setClawRunLabel = function(_text: string) end,
	setClawLog = function(_text: string) end,
	registerWalkToggle = function(_btn: TextButton, _opts: any) end,
	refreshWaypoints = function() end,
}

-- Walk + combat (Humanoid:MoveTo via Nav floor pathfinding)
S.walking = false
S.walkThread = nil
S.combatThread = nil
S.Nav = nil :: any
S.combatBusy = false -- true only while a handler is mid-cast
S.lastCastAt = 0 -- os.clock() of last cast
S.lastCastSlot = nil :: number? -- slot used by last cast
S.slotCdUntil = {} :: { [number]: number } -- synthetic CD end times (UI lag)
S.slotLastArmAt = {} :: { [number]: number } -- last hotbar arm key press (anti-toggle spam)
S.slotArmPendingUntil = {} :: { [number]: number } -- don't re-press while waiting for diamond
S.holdTarget = nil :: Model? -- single shared focus (targets + pathing + combat)
S.combatPhase = "fight" :: string
-- After a kill: wait until combat-schema CDs are ready before picking next enemy.
-- Player death/respawn clears this (death resets CDs).
S.waitAllCds = false
-- Barrel fight bookkeeping (slot usage only; no skill names)
S.barrelFightModel = nil :: Model?
S.barrelMeteorOpened = false -- legacy flag name; slot-1 open once if used
-- Low mana: "hold" (pause casts until reds clear) → "regen" (Z sit recover)
S.resourceRecoverPhase = nil :: string?
S.Targets = nil :: any
S.Abilities = nil :: any
S.zRegenBusy = false
-- After death: if Kill Aura was running, resume only when standing + weapon drawn
S.respawnResumeWalk = false
S.lastSitToggleAt = 0 -- Z sit/stand toggle cooldown
S.lastWeaponToggleAt = 0 -- Q sheathe/draw toggle cooldown
-- nil = unknown (standing defaults to drawn — this game has no Tool while unsheathed)
-- false = sheathed (e.g. just stood from Z) → Kill Aura will Q to draw
-- true = drawn
S.weaponDrawnKnown = nil :: boolean?

-- Anti-AFK (Space every ANTI_AFK_INTERVAL)
S.antiAfkEnabled = false
S.antiAfkThread = nil

-- Custom WalkSpeed force-loop
S.walkSpeedEnabled = false
S.walkSpeedValue = 32
S.walkSpeedThread = nil
S.walkSpeedSaved = nil :: number? -- vanilla to restore on disable

-- Ore ESP (Spawn_Ore neon outlines, through walls)
S.oreEspEnabled = false
S.oreEspThread = nil
S.Ore = nil :: any

-- Player / Enemy ESP (through-wall highlights)
S.playerEspEnabled = false
S.playerEspThread = nil
S.enemyEspEnabled = false
S.enemyEspThread = nil
S.Esp = nil :: any

-- Auto Ore (path node→node; independent of ESP)
S.autoOreEnabled = false
S.autoOreThread = nil
S.AutoOre = nil :: any

-- Dev mesh outline (same filters as Dump Mesh)
S.meshOutlineEnabled = false
S.meshOutlineThread = nil
S.MeshOutline = nil :: any

-- A* path visualization (neon polyline when pathfinding runs)
S.pathVizEnabled = false
S.pathVizFolder = nil :: any

-- Clearance hitbox viz (player box + last hasClearWalk probe samples)
S.hitboxVizEnabled = false
S.hitboxVizFolder = nil :: any
S.hitboxVizThread = nil :: any

-- Human path recording (samples + keys → dumps/pathrec_*.json)
S.pathRecEnabled = false
S.pathRecThread = nil
S.PathRecord = nil :: any
S.spawnPaths = {} :: { any } -- recorded respawn egress paths
S.selectedSpawnPathId = nil :: string?
S.spawnPathVizEnabled = false
S.spawnPathVizFolder = nil :: any
S.spawnEgressBusy = false -- true while walking a recorded spawn path after regen
S.lastBotPath = nil :: any -- last auto-ore (or bot) A* attempt for recorder
S.lastKillAuraPath = nil :: any -- last kill-aura route (for Dump A* path)

-- Player proximity guard (pause bot if other player too close)
S.proximityGuardEnabled = true -- default ON (critical safety)
S.proximityPaused = false
S.proximityResumeWalk = false -- auto-resume Walk+Atk when clear
S.proximityThread = nil

-- Hard player blacklist (Stop All + delayed Kill Aura resume; Anti-AFK stays on)
S.blacklistLockUntil = 0 -- os.clock() until which we refuse auto-resume
S.blacklistResumeAt = 0 -- when to re-toggle Kill Aura if it was on
S.blacklistResumeKillAura = false -- scheduled resume after lock
S.blacklistLastHitName = nil :: string?
S.blacklistThread = nil
S.PlayerBlacklist = nil :: any

-- Between-fight combat buff (QS3 hold → BuffIcon_BUFF_BLESS)
S.buffBusy = false
S.lastBuffCastAt = 0

-- Claw module (separate map from combat; shares HUD only)
S.clawBeamEnabled = false
S.clawBeamThread = nil
S.clawVisBeam = nil :: any -- solid center rod (SmoothPlastic, no Neon glow)
S.clawProngRods = nil :: any -- folder of thin green rods from each of 3 claw Arms
S.clawAimXZ = nil :: { x: number, y: number?, z: number }? -- optional prize Y for floor height
-- Per-prize vertical beams (prize floor → claw height); separate color from claw aim beam
S.clawPrizeBeamsEnabled = false
S.clawPrizeBeamsThread = nil
S.clawPrizeBeamsFolder = nil :: any
S.clawPrizeBeamsBestOnly = false -- when true, show full rods on locked best prizes
S.clawBestPrizeLocked = nil :: any -- one-shot reachable best (amber rod)
S.clawGlobalBestPrizeLocked = nil :: any -- one-shot global best, ignore walls (green rod)
S.clawBusy = false -- one-shot grab; prox/combat must ignore this
S.clawRunToken = 0
S.clawLogLines = {} :: { string } -- ring buffer for HUD
S.clawLogPath = nil :: string?
-- Per-run prize skips only (absolute reach box lives in config)
S.clawBlockedPrizes = {} :: any

-- Named recall waypoints (persisted)
S.waypoints = {} :: { any }
S.selectedWaypointId = nil :: string?

-- Filled after modules load
S.Config = nil :: any
S.Util = nil :: any
S.Dump = nil :: any
S.Combat = nil :: any
S.Pathing = nil :: any
S.Nav = nil :: any
S.Respawn = nil :: any
S.Proximity = nil :: any
S.Waypoints = nil :: any
S.Claw = nil :: any
S.UI = nil :: any

return S

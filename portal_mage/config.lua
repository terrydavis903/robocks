-- portal_mage/config.lua — constants & combat handler table
return {
	SHORT_DELAY = 0.18, -- settle after fire key (E); slot select has its own wait
	HOLD_DURATION = 6,
	SLOT_SELECT_WAIT = 0.55, -- max wait for diamond after ONE arm press (never double-tap)
	SLOT_FIRE_SETTLE = 0.12, -- pause after arm before E so toggle registers
	CAST_LOCKOUT = 0.85, -- min settle after cast even if UI timer still 0
	ABILITY_MIN_CD = 1.5, -- synthetic CD floor after cast when CooldownTimer lags
	-- After kill: wait only slots that were used / still show CD (not every idle slot)
	WAIT_CDS_ONLY_ACTIVE = true,

	-- Stance toggles (state-driven — observe sit/draw, don't assume sequence done):
	--   Z = sit/stand recover  |  Q = sheathe/draw weapon (has cooldown)
	WEAPON_EQUIP_KEY = Enum.KeyCode.Q,
	WEAPON_EQUIP_WAIT = 1.2, -- max wait after one Q for isWeaponDrawn()
	WEAPON_Q_COOLDOWN = 0.85, -- don't spam Q (game toggle CD)
	WEAPON_NAME_KEYWORDS = { "staff", "wand", "tome", "sword", "blade", "bow", "weapon", "mage", "rod" },

	DUMP_DIR = "dumps",
	WAYPOINT_DIR = "waypoints",
	WAYPOINT_FILE = "waypoints/waypoints.json",
	-- World dump: non-combat workspace assets (ores, farms, NPCs, pickups, …)
	WORLD_DUMP_NEAR_STUDS = 100, -- Models/BaseParts near player
	WORLD_DUMP_NEAR_MAX = 800,
	WORLD_DUMP_TREE_MAX_NODES = 6000,
	WORLD_DUMP_TREE_MAX_DEPTH = 8,
	WORLD_DUMP_NAME_MATCH_MAX = 2000,

	-- Full world mesh export (walls/floors/collision geometry) → dumps/mesh_<stamp>/
	-- Best-effort: all BaseParts + Terrain voxels + downward raycast floor grid.
	MESH_DUMP_INCLUDE_NONCOLLIDE = true, -- false = CanCollide only (smaller)
	MESH_DUMP_SKIP_FULLY_INVISIBLE = true, -- drop Transparency>=1 AND not CanCollide
	MESH_DUMP_MIN_VOLUME = 0.001, -- skip dust motes (stud³)
	MESH_DUMP_CHUNK_SIZE = 1500, -- parts per parts_XXXX.json
	MESH_DUMP_YIELD_EVERY = 350, -- yield during scan so game stays responsive
	-- Floor/terrain use "playable" AABB (excludes InvisibleWall skyboxes that blow ±1024)
	MESH_DUMP_FLOOR_STEP = 4, -- studs between floor ray samples
	MESH_DUMP_FLOOR_MAX_SAMPLES = 80000,
	MESH_DUMP_FLOOR_RAY_UP = 40, -- above playable maxY (not barrier roof)
	MESH_DUMP_FLOOR_RAY_DOWN = 250,
	MESH_DUMP_TERRAIN_RES = 4, -- ReadVoxels resolution (studs)
	-- Roblox rejects huge ReadVoxels regions — keep small & player-centered
	MESH_DUMP_TERRAIN_MAX_AXIS = 256, -- studs per axis (was 2048 → "Region is too large")
	MESH_DUMP_TERRAIN_PAD = 16,
	MESH_DUMP_PLAYABLE_MAX_DIM = 180, -- part max size axis still allowed in playable AABB

	-- Dev Outline Mesh (live Highlight of dump-eligible parts)
	MESH_OUTLINE_RANGE = 220, -- studs from player (perf); uses closest-point on OBB not center
	MESH_OUTLINE_MAX = 700, -- max simultaneous highlights (nearest first)
	MESH_OUTLINE_INTERVAL = 1.0,
	MESH_OUTLINE_SHOW_BARRIERS = true, -- red = InvisibleWall / shells
	MESH_OUTLINE_FILL_T = 0.75,
	MESH_OUTLINE_OUTLINE_T = 0.05,
	-- Outdoor ground is often Terrain (not BasePart) — show neon sample grid under player
	MESH_OUTLINE_TERRAIN_FLOOR = true,
	MESH_OUTLINE_TERRAIN_RADIUS = 48, -- half-extent studs around player
	MESH_OUTLINE_TERRAIN_STEP = 4, -- grid spacing
	MESH_OUTLINE_TERRAIN_CELL = 3.6, -- neon tile size (slightly < step)

	WALK_STEP_SECONDS = 0.05, -- short wait when idle / regen (not a teleport step)
	-- Pathing uses Humanoid:MoveTo + optional W/S spoof for walk animation
	SMOOTH_WALK_ARRIVE_STUDS = 2.5, -- consider arrived within this XZ distance
	SMOOTH_WALK_TIMEOUT = 2.5, -- seconds; kill aura uses continuous MoveTo (no session chop)
	SMOOTH_WALK_POLL = 0.08, -- pathing continuous loop poll
	SMOOTH_WALK_REISSUE = 0.55, -- re-call MoveTo while still en route (keep keys held)
	SMOOTH_WALK_FACE_ALPHA = 0.12, -- fallback soft yaw lerp per poll
	-- Time-based yaw rate (higher = snappier). Used for U-turns at path tails.
	SMOOTH_WALK_TURN_RATE = 5.5,
	-- If look·forward < this (~70°), disable AutoRotate and soft-lerp instead of snap
	SMOOTH_WALK_SOFT_TURN_DOT = 0.35,
	-- Once look·forward >= this, re-enable AutoRotate (~25°)
	SMOOTH_WALK_ALIGN_DOT = 0.90,
	-- Spoof WASD so walk anim plays / games that read keys. With reticle lock, keys are
	-- relative to face (W toward enemy, A/D strafe, S kite) — not "turn then W".
	WALK_SPOOF_MOVE_KEYS = true,
	WALK_KEY_DEADZONE = 0.28, -- |local axis| must exceed this to hold that key

	-- Floor navigation (Walk+Atk / kill-aura)
	NAV_CELL = 4, -- grid A* cell size (fallback only)
	NAV_MAX_CELLS = 40,
	NAV_MAX_EXPAND = 1200,
	-- Primary pathing: Roblox PathfindingService (not homebrew A*)
	NAV_AGENT_RADIUS = 2,
	NAV_AGENT_HEIGHT = 5,
	NAV_AGENT_CAN_JUMP = true,
	NAV_WAYPOINT_SPACING = 6,
	-- Kill aura path debug log → dumps/killaura_*.log
	KILL_AURA_LOG = true,
	NAV_RAY_UP = 50,
	NAV_RAY_DOWN = 140,
	NAV_MIN_NORMAL_Y = 0.45, -- reject steep hits as "floor" (walls/cliffs)
	NAV_MAX_STEP_Y = 7, -- max height change between neighbor cells
	NAV_MAX_SNAP_Y = 10,
	NAV_ARRIVE_STUDS = 2.5,
	NAV_RING_SAMPLES = 16, -- standPointNear angle samples
	-- Wall clearance: reject stand/path points pinched against non-floor surfaces
	NAV_WALL_CLEARANCE = 2.75, -- min free studs to walls (horizontal probes)
	NAV_WALL_PROBE = 8, -- how far each wall probe casts
	NAV_WALL_DIRS = 8, -- compass directions
	NAV_BODY_HEIGHTS = { 1.2, 2.5, 4.5 }, -- probe heights above floor (studs)
	TARGET_CYCLE_DELAY = 0.12,
	RETICLE_PATH = "TargetLockReticle",

	-- Kill Aura loop:
	--   pick closest path → stand@RANGE → R → schema until dead → wait ALL CDs → reloop
	--   player death → CDs reset → respawn resumes Kill Aura (no CD wait) → reloop
	KILL_AURA_SCAN = 250, -- consider living mobs in this radius
	KILL_AURA_PATH_CANDIDATES = 5, -- path-cost checks among nearest (keep low — A* is heavy)
	KILL_AURA_RANGE = 30, -- fight stand-off (approach to this, never closer)
	KILL_AURA_APPROACH = 30, -- alias of RANGE (kept for old reads)
	KILL_AURA_STICKY = 5, -- stay put while |dist - RANGE| <= sticky (wider = less thrash)
	KILL_AURA_PRIORITY = {}, -- unused in simple loop (path length only)
	-- aliases
	COMBAT_RANGE = 30,
	COMBAT_RANGE_STICKY = 3,
	MIN_ENEMY_DISTANCE = 30,
	AGGRO_CONSIDER_RANGE = 250,
	BARREL_ENGAGE_RANGE = 30,

	RESPAWN_CLICK_COOLDOWN = 2.0,
	RESPAWN_POST_CLICK_WAIT = 2.0, -- after Respawn click, before first Z
	RESPAWN_Z_POLL_INTERVAL = 0.35, -- poll HP/MP while recovering (no extra Z spam)
	RESPAWN_Z_MAX_SECONDS = 90, -- safety cap waiting for full HP/MP
	RESPAWN_AFTER_MAX_WAIT = 0.5, -- after second Z, before Q
	RESPAWN_POST_EQUIP_WAIT = 0.45, -- after Q / EquipTool before resuming Kill Aura

	-- Low mana: stop fighting, kite until reds clear, then Z regen
	MANA_RECOVER_FRACTION = 0.20, -- enter recover when mp/maxMp below this

	-- Built-in anti-AFK: press Space this often (seconds)
	ANTI_AFK_INTERVAL = 120,

	-- Custom WalkSpeed (re-applied every frame while enabled)
	WALK_SPEED_DEFAULT = 32, -- target when first enabled
	WALK_SPEED_VANILLA = 16, -- restore when turning off
	WALK_SPEED_MIN = 8,
	WALK_SPEED_MAX = 200,

	-- Farm: highlight empty FarmSoils_Plot* tiles (no plant under CropPlaceholder)
	FARM_EMPTY_HL_INTERVAL = 0.6,
	FARM_EMPTY_HL_FILL = Color3.fromRGB(255, 90, 40),
	FARM_EMPTY_HL_OUTLINE = Color3.fromRGB(255, 220, 80),
	FARM_EMPTY_HL_FILL_T = 0.55,
	FARM_EMPTY_HL_OUTLINE_T = 0.15,

	-- Ore ESP: neon through-wall outlines on Workspace.Maps.World.Spawn_Ore.SP*.Ore_*
	-- Types seen in dump: Ore_Aurorite, Ore_Lumite; basic form is a rock (often no VFX).
	ORE_ESP_INTERVAL = 0.75,
	ORE_ESP_FILL_T = 0.65, -- mostly outline (claw-like neon edge)
	ORE_ESP_OUTLINE_T = 0.0,
	ORE_ESP_COLORS = {
		rock = {
			fill = Color3.fromRGB(160, 160, 175),
			outline = Color3.fromRGB(220, 230, 255),
		},
		stone = {
			fill = Color3.fromRGB(160, 160, 175),
			outline = Color3.fromRGB(220, 230, 255),
		},
		aurorite = {
			fill = Color3.fromRGB(40, 160, 220),
			outline = Color3.fromRGB(80, 230, 255),
		},
		lumite = {
			fill = Color3.fromRGB(200, 170, 40),
			outline = Color3.fromRGB(255, 240, 90),
		},
		default = {
			fill = Color3.fromRGB(180, 60, 220),
			outline = Color3.fromRGB(255, 120, 255),
		},
	},

	-- Claw machine one-shot (WASD aim → confirm → Space drop)
	-- Key map (player-position deltas): W=+Z S=-Z A=+X D=-X
	-- Movement: HOLD the cardinal key fluidly (no pulse spam). If we overshoot,
	-- release and short-tap the opposite key (D↔A, S↔W). Per-tap step ~0.12 studs.
	-- Align "above prize": preferred heuristic is prize-rod fully inside claw-rod
	-- (see claw.lua encapsulation). dXZ thr kept as fallback / axis stop band.
	CLAW_ALIGN_THRESHOLD = 0.08, -- fallback XZ + per-axis release band
	CLAW_ALIGN_SOFT_THRESHOLD = 0.16, -- fallback soft XZ
	CLAW_ALIGN_USE_ENCAPSULATION = true, -- prize beam ⊂ claw beam = on-target
	-- Optional radial margin overrides (studs). nil = derive from rod diameters.
	-- Hard: prize volume inside claw volume (clawR − prizeR). Soft: prize axis in clawR.
	CLAW_ENCAP_HARD_MARGIN = nil,
	CLAW_ENCAP_SOFT_MARGIN = nil,
	CLAW_ORBIT_HOLDS = 8, -- after this many near-target holds without improvement, soft-OK
	CLAW_MOVE_STEP_STUDS = 0.12, -- reference granularity
	CLAW_HOLD_POLL = 0.03, -- sample rate while key is held down
	CLAW_HOLD_MAX = 2.5, -- max seconds per WASD key hold while aiming, then re-pick axis
	CLAW_CORRECT_TAP = 0.05, -- opposite-key tap duration after overshoot
	CLAW_HOLD_RELEASE_SLACK = 0.02, -- release slightly early before thr (inertia)
	CLAW_NEAR_TAP_DIST = 0.22, -- below this, use short taps not long holds
	CLAW_STABLE_CHECKS = 2, -- fewer once soft-aligned
	CLAW_STABLE_INTERVAL = 0.10,
	CLAW_SETTLE_WAIT = 0.3, -- after aim move, wait before rescan/confirm/drop (claw settles)
	CLAW_MAX_SECONDS = 90,
	CLAW_LOG_DIR = "dumps",
	CLAW_LOG_UI_LINES = 12, -- last N lines on Claw tab (cleared every Start)

	-- Claw travel AABB (world XZ) = flush with machine walls (W/A/S/D max dumps).
	-- There is NO imaginary inset/inner hitbox — prizes pressed against glass are grabbable.
	-- A prize is REACH if its body (center ± radius) intersects this box (not center-only).
	--   W: 19-21-14 (-79.044, 37.938)  A: 19-21-17 (-79.232, 40.136)
	--   S: 19-21-22 (-82.835, 37.612)  D: 19-21-25 (-82.870, 40.734)
	CLAW_REACH_ENABLED = true,
	CLAW_REACH_MARGIN = 0.0, -- never shrink the box (was "inset" keep-out — removed)
	CLAW_OUTSIDE_REACH_SLACK = 0.0, -- no extra imaginary slack; use prize radius instead
	CLAW_PRIZE_DEFAULT_RADIUS_XZ = 0.375, -- if prize has no measured radiusXZ
	CLAW_REACH_X_MIN = -82.87033081054688,
	CLAW_REACH_X_MAX = -79.04434967041016,
	CLAW_REACH_Z_MIN = 37.61227035522461,
	CLAW_REACH_Z_MAX = 40.73351287841797,

	-- Claw prize tiers: always loaded from portal_mage/claw_priority.lua at boot
	-- (created with defaults if missing). Filled into CLAW_PRIORITY_KEYWORDS there.
	CLAW_PRIORITY_KEYWORDS = {},

	-- Critical: pause walk+combat if another player is this close (studs)
	PLAYER_PROXIMITY_PAUSE_STUDS = 150,
	PLAYER_PROXIMITY_CHECK_INTERVAL = 0.15,

	-- Barrel Champion: absolute combat priority — open meteor (slot 1), then aqua loop
	BARREL_CHAMPION_MATCH = "BarrelChampion", -- also matches "Barrel Champion" / "Barrel_Champion"
	BARREL_CHAMPION_TAGS = { "Barrel Champion", "BarrelChampion", "Barrel_Champion" },
	-- Junk King / Tin Tortoise: permanent aqua bubble spam (no meteor)
	JUNK_KING_MATCH = "JunkKing",
	JUNK_KING_TAGS = { "Junk King", "JunkKing", "Junk_King" },
	JUNK_KING_ENGAGE_RANGE = 30,
	TIN_TORTOISE_MATCH = "TinTortoise",
	TIN_TORTOISE_TAGS = { "Tin Tortoise", "TinTortoise", "Tin_Tortoise" },
	TIN_TORTOISE_ENGAGE_RANGE = 30,
	AQUA_SLOT = 4,

	-- Ability readiness comes from QuickSlotN.CooldownTimer (not hardset seconds).
	-- ALL abilities are TOGGLES: press slot key (1–4) to arm (Slot_Select diamond ON).
	-- Cast pipeline (abilities.lua): ensure slot ON once → settle → steps fire only.
	-- Do NOT put One/Two/… in steps (re-pressing toggles OFF). Use handler.slot to arm.
	-- R is reticle cycle only (not in steps).
	-- Red-name (aggro) mobs with no match use the first `aqua` handler as default.
	COMBAT_HANDLERS = {
		{
			id = "meteor",
			match = "ScarecrowGoblin",
			slot = 1, -- toggle arm QuickSlot1
			steps = {
				{ key = Enum.KeyCode.E },
			},
		},
		-- Dump: Monster_PatchHound_* / Monster_KettleBeetle_* (same meteor kit as scarecrow)
		{
			id = "meteor",
			match = "PatchHound",
			slot = 1,
			steps = {
				{ key = Enum.KeyCode.E },
			},
		},
		{
			id = "meteor",
			match = "KettleBeetle",
			slot = 1,
			steps = {
				{ key = Enum.KeyCode.E },
			},
		},
		{
			id = "aqua",
			match = "JunkKing",
			slot = 4, -- toggle arm QuickSlot4
			steps = {
				{ hold = Enum.KeyCode.E, duration = 6 },
			},
		},
		{
			id = "aqua",
			match = "TinTortoise",
			slot = 4,
			steps = {
				{ hold = Enum.KeyCode.E, duration = 6 },
			},
		},
		{
			id = "aqua",
			match = "BucketheadGoblin",
			slot = 4,
			steps = {
				{ hold = Enum.KeyCode.E, duration = 6 },
			},
		},
		-- Critter goblin: meteor only (same as scarecrow / patch / kettle)
		{
			id = "meteor",
			match = "CritterGoblin",
			slot = 1,
			steps = {
				{ key = Enum.KeyCode.E },
			},
		},
	},
}

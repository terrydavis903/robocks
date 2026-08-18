-- portal_mage/config.lua â€” constants & combat handler table
return {
	SHORT_DELAY = 0.18, -- settle after fire key (E); slot select has its own wait
	HOLD_DURATION = 5, -- QS4 channel default (hold E then release)
	SLOT_SELECT_WAIT = 0.45, -- brief settle after ONE arm press (never double-tap)
	SLOT_FIRE_SETTLE = 0.12, -- pause after arm before E so toggle registers
	-- After pressing a hotbar key, never press it again until this elapses
	-- (or until we switch to a different slot). Stops QS4 diamond flicker.
	SLOT_ARM_COOLDOWN = 2.0,
	-- Per-slot settle after cast (same slot only). No global lockout — switch slots immediately.
	CAST_LOCKOUT = 0.15,
	ABILITY_MIN_CD = 0.5, -- fallback synthetic floor when usage.minCd missing
	-- After kill: do not gate reloop on all CDs (QS4 has no lockout; switch to QS1 immediately)
	WAIT_CDS_ONLY_ACTIVE = true,

	-- Stance toggles (state-driven â€” observe sit/draw, don't assume sequence done):
	--   Z = sit/stand recover  |  Q = sheathe/draw weapon (has cooldown)
	WEAPON_EQUIP_KEY = Enum.KeyCode.Q,
	WEAPON_EQUIP_WAIT = 1.2, -- max wait after one Q for isWeaponDrawn()
	WEAPON_Q_COOLDOWN = 0.85, -- don't spam Q (game toggle CD)
	WEAPON_NAME_KEYWORDS = { "staff", "wand", "tome", "sword", "blade", "bow", "weapon", "mage", "rod" },

	DUMP_DIR = "dumps",
	WAYPOINT_DIR = "waypoints",
	WAYPOINT_FILE = "waypoints/waypoints.json",
	RESPAWN_PATH_FILE = "waypoints/respawn_paths.json", -- human egress paths after respawn
	-- After regen: use closest recorded spawn path if start OR any sample is within
	-- this XZ. Dump 00-01-13: pad at (1038,-679) vs path start (1009,-670) ≈30st —
	-- 12st start-only match skipped egress entirely.
	RESPAWN_PATH_MATCH_STUDS = 64,
	RESPAWN_PATH_WP_SPACING = 3.5, -- thin recorded samples while following egress
	RESPAWN_PATH_VIZ_SPACING = 5.0, -- studs between viz nodes when Respawn points ON
	RESPAWN_PATH_ARRIVE = 2.8,
	RESPAWN_PATH_SEG_TIMEOUT = 4.0,
	-- World dump: non-combat workspace assets (ores, farms, NPCs, pickups, â€¦)
	WORLD_DUMP_NEAR_STUDS = 100, -- Models/BaseParts near player
	WORLD_DUMP_NEAR_MAX = 800,
	WORLD_DUMP_TREE_MAX_NODES = 6000,
	WORLD_DUMP_TREE_MAX_DEPTH = 8,
	WORLD_DUMP_NAME_MATCH_MAX = 2000,

	-- Full world mesh export (walls/floors/collision geometry) â†’ dumps/mesh_<stamp>/
	-- Best-effort: all BaseParts + Terrain voxels + downward raycast floor grid.
	MESH_DUMP_INCLUDE_NONCOLLIDE = true, -- false = CanCollide only (smaller)
	MESH_DUMP_SKIP_FULLY_INVISIBLE = true, -- drop Transparency>=1 AND not CanCollide
	MESH_DUMP_MIN_VOLUME = 0.001, -- skip dust motes (studÂ³)
	MESH_DUMP_CHUNK_SIZE = 1500, -- parts per parts_XXXX.json
	MESH_DUMP_YIELD_EVERY = 350, -- yield during scan so game stays responsive
	-- Floor/terrain use "playable" AABB (excludes InvisibleWall skyboxes that blow Â±1024)
	MESH_DUMP_FLOOR_STEP = 4, -- studs between floor ray samples
	MESH_DUMP_FLOOR_MAX_SAMPLES = 80000,
	MESH_DUMP_FLOOR_RAY_UP = 40, -- above playable maxY (not barrier roof)
	MESH_DUMP_FLOOR_RAY_DOWN = 250,
	MESH_DUMP_TERRAIN_RES = 4, -- ReadVoxels resolution (studs)
	-- Roblox rejects huge ReadVoxels regions â€” keep small & player-centered
	MESH_DUMP_TERRAIN_MAX_AXIS = 256, -- studs per axis (was 2048 â†’ "Region is too large")
	MESH_DUMP_TERRAIN_PAD = 16,
	MESH_DUMP_PLAYABLE_MAX_DIM = 180, -- part max size axis still allowed in playable AABB

	-- Dev Outline Mesh (live Highlight of dump-eligible parts)
	MESH_OUTLINE_RANGE = 220, -- studs from player (perf); uses closest-point on OBB not center
	MESH_OUTLINE_MAX = 700, -- max simultaneous highlights (nearest first)
	MESH_OUTLINE_INTERVAL = 1.0,
	MESH_OUTLINE_SHOW_BARRIERS = true, -- red = InvisibleWall / shells
	MESH_OUTLINE_FILL_T = 0.75,
	MESH_OUTLINE_OUTLINE_T = 0.05,
	-- Outdoor ground is often Terrain (not BasePart) â€” show neon sample grid under player
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
	-- Camera face via Left/Right (short calibrated pulses — never permanent hold).
	PATH_WALK_TURN_RATE = 8,
	PATH_WALK_ALIGN_DOT = 0.82,
	PATH_TURN_ARROWS = true,
	PATH_TURN_INVERT = true,
	PATH_TURN_DEAD_DEG = 12,
	PATH_TURN_HOLD = 0.05,
	PATH_TURN_GAP = 0.10,
	PATH_TURN_HOLD_MAX = 0.11,
	PATH_TURN_GAP_MIN = 0.07,
	PATH_TURN_PULSE = true,
	PATH_TURN_YAW_DEADZONE = 0.08,
	PATH_CAMERA_YAW_DEG = 5,
	-- face (L/R cam) → check → W along A*
	KILL_AURA_FACE_ALIGN = 0.82,
	KILL_AURA_FACE_KEEP = 0.30,
	KILL_AURA_FACE_WALK_ALIGN = 0.30,
	KILL_AURA_FACE_STOP = 0.30,
	KILL_AURA_FACE_SETTLE = 0.0,
	KILL_AURA_FACE_STUCK = 0.6,
	KILL_AURA_FORCE_WALK = 0,
	KILL_AURA_NO_PROGRESS = 2.0,
	KILL_AURA_SEG_ARRIVE = 4.0, -- studs: advance to next path segment
	KILL_AURA_PROBE = 4.5, -- wall probe studs
	-- Jump: path ledge / short step only â€” NOT "enemy is higher" (flat-ground spam)
	KILL_AURA_JUMP_MIN_DY = 2.2, -- min height rise to jump
	KILL_AURA_JUMP_MAX_DY = 9, -- ignore crazy verticals
	KILL_AURA_JUMP_RANGE = 8, -- next path node must be within this XZ to jump
	KILL_AURA_JUMP_PROBE = 2.8, -- short step ray (was full PROBE â€” too eager)
	KILL_AURA_JUMP_DY = 2.2, -- legacy alias of JUMP_MIN_DY
	-- Face debug beams (Kill Aura on): cyan=HRP look, green=to segment, pink/yellow=turn L/R
	KILL_AURA_FACE_VIZ = true,
	KILL_AURA_FACE_BEAM_LEN = 6, -- studs; keep short/thin
	-- If lookÂ·forward < this (~70Â°), disable AutoRotate and soft-lerp instead of snap
	SMOOTH_WALK_SOFT_TURN_DOT = 0.35,
	-- Once lookÂ·forward >= this, re-enable AutoRotate (~25Â°)
	SMOOTH_WALK_ALIGN_DOT = 0.90,
	-- Spoof WASD for walk anim / games that read keys.
	-- Kill Aura: face A* segment â†’ W along it (A/D only on walls). Reticle combat uses relative WASD too.
	WALK_SPOOF_MOVE_KEYS = true,
	WALK_KEY_DEADZONE = 0.28, -- |local axis| must exceed this to hold that key

	-- Floor navigation (hasClearWalk probes + optional generic goTo/A*)
	NAV_CELL = 4,
	NAV_MAX_CELLS = 40,
	NAV_MAX_EXPAND = 1200,
	NAV_AGENT_RADIUS = 2.4, -- slightly wider so PFS avoids thin wall clips
	NAV_AGENT_HEIGHT = 5,
	NAV_AGENT_CAN_JUMP = true,
	NAV_WAYPOINT_SPACING = 6,
	NAV_PATH_MAX_GOALS = 6, -- computePath ring budget (was 33 â€” froze walk 30s+)
	KILL_AURA_LOG = true, -- dumps/killaura_*.log
	PATH_VIZ_REFRESH = 0.55, -- redraw Path Viz polyline only (not movement thrash)
	PATH_REBUILD = 10.0, -- Kill Aura path recompute ceiling
	PATH_REPATH_COOLDOWN = 2.0, -- min seconds between full rebuilds
	-- Dump A* path: mesh parts within this studs of the polyline (corridor)
	PATH_DUMP_MESH_RADIUS = 48,
	PATH_DUMP_MESH_MAX_PARTS = 2500,
	NAV_RAY_UP = 50,
	NAV_RAY_DOWN = 140,
	NAV_MIN_NORMAL_Y = 0.45,
	NAV_MAX_STEP_Y = 7, -- max climb between A* cells
	-- Walk-off drops: next node lower by this much = just hold W (gravity). Not a wall.
	NAV_DROP_ALLOW_DY = 2.0,
	NAV_MAX_DROP_Y = 40, -- A* may step down this far (ascent still NAV_MAX_STEP_Y)
	NAV_MAX_SNAP_Y = 10,
	NAV_ARRIVE_STUDS = 2.5,
	NAV_WALL_CLEARANCE = 1.6, -- unused when stone-path-only (no pinch checks)
	NAV_WALL_PROBE = 8,
	NAV_WALL_DIRS = 8,
	NAV_BODY_HEIGHTS = { 1.2, 2.4, 3.8 }, -- legacy
	-- Stone roads only (mesh dumps: Cobblestone = path, Sandstone = sand/dirt).
	-- Paths are player-safe → no obstacle collision probes along hops.
	-- Waypoints "Add walkable tile" appends feet Terrain/Mesh Material and persists
	-- to WALKABLE_MATERIALS_FILE (merged into NAV_STONE_PATH_MATERIALS at load).
	NAV_STONE_PATH_ONLY = true,
	NAV_STONE_PATH_MATERIALS = {
		"Cobblestone", -- stone path (dump feet material)
		"Asphalt", -- occasional paved connector
	},
	-- Path/name keywords (MeshParts often Plastic with empty TextureID).
	-- mesh dump 2026-08-17_20-06-58 feet: Workspace.Maps.World.Props.GJ_Bridge.*
	NAV_WALKABLE_PATH_KEYWORDS = {
		"GJ_Bridge",
	},
	WALKABLE_MATERIALS_FILE = "waypoints/walkable_materials.json",
	NAV_STONE_PATH_SNAP_R = 24, -- studs: snap start/goal to nearest stone if off-path
	-- Between fights: if feet aren't on walkable path, walk here before next mob.
	-- Dump 00-02-33: infinite re-snap at watchtower when snap cell was unreachable.
	NAV_STONE_RECOVER_SNAP_R = 40, -- wider search than path snap (pad / sand pockets)
	NAV_STONE_RECOVER_ARRIVE = 2.8,
	NAV_STONE_RECOVER_MAX_SEC = 8, -- hard abort → resume mob scan
	NAV_STONE_RECOVER_MAX_RESNAPS = 3,
	NAV_STONE_RECOVER_GIVEUP_CD = 20, -- seconds before trying recover again after abort
	-- Stranded on disconnected stone: briefly allow sand/any floor to rejoin roads
	NAV_STONE_ESCAPE_SEC = 10,
	NAV_CLEAR_STEP = 2.5, -- stone continuity samples along hop
	NAV_HITBOX_PAD = 0.05,
	NAV_HITBOX_SCALE = 0.9,
	NAV_HITBOX_FLOOR_LIFT = 0.15,
	-- World props that must NEVER be treated as walk floors (mesh dump 2026-08-16):
	-- Buildings.Stalls, Buildings.Tents, Modular_Standalone_Roof_*, Mech_Sail_ClothMesh
	NAV_OBSTACLE_PATH_KEYWORDS = {
		".stalls.",
		".tents.",
		"modular_standalone_roof",
		"standalone_roof",
		"goblin_stall",
		"goblin_tent",
		"mech_sail",
		".v_sail",
		".sail.",
		"junk_longtable",
		"planks_group",
	},
	NAV_OBSTACLE_NAME_KEYWORDS = {
		"stall",
		"tent",
		"tarp",
		"awning",
		"canopy",
		"clothmesh",
		"sail_cloth",
		"mech_sail",
		"cloth",
		"standalone_roof",
	},
	-- Slab floor heuristic (was minA<=4 / horiz>=8 â†’ stall plates & sail cloth counted as floors)
	NAV_FLOOR_SLAB_MAX_THICK = 1.25,
	NAV_FLOOR_SLAB_MIN_HORIZ = 12,
	TARGET_CYCLE_DELAY = 0.12,
	RETICLE_PATH = "TargetLockReticle",

	-- Kill Aura: face â†’ W/A/D â†’ stand@RANGE â†’ R â†’ cast â†’ CD wait â†’ reloop
	KILL_AURA_SCAN = 250,
	KILL_AURA_RANGE = 30,
	KILL_AURA_APPROACH = 30, -- alias
	KILL_AURA_STICKY = 4,
	KILL_AURA_HOLD_STICKY = 8, -- studs closer to switch hold when in/near fight range
	-- Skip / R-release targets too high above us (world dump: many +40–50 Y).
	-- Max engage ΔY = MULT × floor→ClearHitbox center height (live; fallback 3 studs).
	KILL_AURA_MAX_DY_MULT = 3,
	KILL_AURA_HITBOX_HEIGHT_FALLBACK = 3.0, -- studs if Nav measure unavailable
	KILL_AURA_TOO_HIGH_IGNORE = 12, -- seconds before re-considering a released high target
	KILL_AURA_RETICLE_RELEASE_HOLD = 0.4, -- hold R to unlock reticle
	KILL_AURA_MAX_PATH_DETOR = 2.2, -- reject paths longer than this × straight (anti-circle)
	-- Optional name priority (first match wins). Empty = nearest schema mob only.
	-- Example: { "ScarecrowGoblin", "PatchHound", "CritterGoblin" }
	KILL_AURA_PRIORITY = {},
	COMBAT_RANGE = 30,
	COMBAT_RANGE_STICKY = 3,
	MIN_ENEMY_DISTANCE = 30,
	AGGRO_CONSIDER_RANGE = 250,
	BARREL_ENGAGE_RANGE = 30,

	RESPAWN_CLICK_COOLDOWN = 2.0,
	RESPAWN_POST_CLICK_WAIT = 2.0, -- after Respawn click, before first Z
	-- After character is alive, hold S briefly before Z-sit regen (push off pad/spawn lock)
	RESPAWN_POST_S_HOLD = 1.0,
	RESPAWN_Z_POLL_INTERVAL = 0.35, -- poll HP/MP while recovering (no extra Z spam)
	RESPAWN_Z_MAX_SECONDS = 90, -- safety cap waiting for full HP/MP
	RESPAWN_AFTER_MAX_WAIT = 0.5, -- after second Z, before Q
	RESPAWN_POST_EQUIP_WAIT = 0.45, -- after Q / EquipTool before resuming Kill Aura

	-- Low mana: pause casts until nearby reds clear, then Z sit-recover
	MANA_RECOVER_FRACTION = 0.20,

	-- Built-in anti-AFK: press Space this often (seconds)
	ANTI_AFK_INTERVAL = 120,

	-- WalkSpeed: portal_mage never writes Humanoid.WalkSpeed (game owns it).
	WALK_SPEED_DEFAULT = 16, -- unused (legacy)
	WALK_SPEED_VANILLA = 16,
	WALK_SPEED_MIN = 8,
	WALK_SPEED_MAX = 200,

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
		-- was cyan; dark orange so Player ESP can own cyan
		aurorite = {
			fill = Color3.fromRGB(200, 90, 25),
			outline = Color3.fromRGB(255, 140, 40),
		},
		-- gold / yellow (unchanged)
		lumite = {
			fill = Color3.fromRGB(200, 170, 40),
			outline = Color3.fromRGB(255, 240, 90),
		},
		default = {
			fill = Color3.fromRGB(180, 60, 220),
			outline = Color3.fromRGB(255, 120, 255),
		},
	},

	-- Player ESP (other players) â€” cyan
	PLAYER_ESP_INTERVAL = 0.5,
	PLAYER_ESP_FILL_T = 0.65,
	PLAYER_ESP_OUTLINE_T = 0.0,
	PLAYER_ESP_COLORS = {
		fill = Color3.fromRGB(40, 200, 230),
		outline = Color3.fromRGB(120, 240, 255),
	},
	-- Enemy ESP (Mobs.Active) â€” red
	ENEMY_ESP_INTERVAL = 0.5,
	ENEMY_ESP_FILL_T = 0.65,
	ENEMY_ESP_OUTLINE_T = 0.0,
	ENEMY_ESP_COLORS = {
		fill = Color3.fromRGB(220, 40, 40),
		outline = Color3.fromRGB(255, 90, 90),
	},

	-- Auto Ore: A*/PFS between Spawn_Ore nodes (segment faceâ†’W; wall climb Space+W)
	AUTO_ORE_ARRIVE = 6, -- studs XZ to count as at node
	AUTO_ORE_DWELL = 12.0, -- alias: max wait after F for Mine GUI / ore gone
	AUTO_ORE_MINE_TIMEOUT = 12.0, -- seconds after single F waiting for Mine GUI to clear
	AUTO_ORE_INTERACT = true, -- mine with F when GUI text "Mine" is shown
	AUTO_ORE_INTERACT_KEY = Enum.KeyCode.F, -- game mine key (pressed once per Mine GUI)
	-- Path rebuild: NOT every step â€” only stuck / blocked segment / goal jump / rare safety
	AUTO_ORE_PATH_REBUILD = 10.0, -- safety repath ceiling (was ~1s â€” too thrashy)
	AUTO_ORE_PATH_GOAL_MOVE = 12, -- repath if ore goal moved this far from pathGoal
	AUTO_ORE_PATH_DRIFT = 36, -- repath if far from current waypoint
	AUTO_ORE_SEG_ARRIVE = 3.5, -- advance path waypoint
	AUTO_ORE_FACE_ALIGN = 0.90,
	AUTO_ORE_FACE_SETTLE = 0.18,
	AUTO_ORE_FACE_TURN_RATE = 3.2,
	AUTO_ORE_FACE_VIZ = true, -- cyan look / green want / turn wedge
	AUTO_ORE_FACE_BEAM_LEN = 6,
	AUTO_ORE_SEG_JUMP_DY = 3.5, -- next path waypoint this much higher â†’ Space+W along path
	AUTO_ORE_CLIMB_DY = 3.5, -- legacy alias of SEG_JUMP_DY
	AUTO_ORE_WALL_NEAR = 4.5, -- wall-climb only if stuck on a high segment + wall this close
	AUTO_ORE_WALL_PROBE = 10,
	AUTO_ORE_WALL_DIRS = 12,
	AUTO_ORE_CLIMB_FACE_ALIGN = 0.85, -- face into wall only for stuck ledge assist
	AUTO_ORE_CLIMB_MAX = 4.0, -- seconds per stuck wall-climb
	AUTO_ORE_CLIMB_MIN_RISE = 1.2,
	AUTO_ORE_STUCK = 1.4, -- seconds barely moving before repath/climb
	AUTO_ORE_REPATH_COOLDOWN = 1.6, -- min seconds between force rebuilds
	AUTO_ORE_SKIP_ROCK = false, -- true = skip basic rock/stone nodes
	AUTO_ORE_TYPE_PRIORITY = {}, -- empty = all types; else e.g. {"aurorite","lumite"}
	AUTO_ORE_LOG = true, -- dumps/autoore_*.log â€” every PATH attempt + stuck/mine

	-- Human A* path recording (pause bot â†’ walk stuck route â†’ save JSON)
	PATH_REC_SAMPLE = 0.08, -- seconds between position samples
	PATH_REC_TRAIL_VIZ = true, -- green crumbs while recording
	PATH_REC_TRAIL_EVERY = 0.25,
	PATH_REC_TRAIL_MAX = 400,
	PATH_REC_AUTO_PATH_VIZ = true, -- turn Path Viz ON when recording starts

	-- Claw machine one-shot (WASD aim â†’ confirm â†’ Space drop)
	-- Key map (player-position deltas): W=+Z S=-Z A=+X D=-X
	-- Movement: HOLD the cardinal key fluidly (no pulse spam). If we overshoot,
	-- release and short-tap the opposite key (Dâ†”A, Sâ†”W). Per-tap step ~0.12 studs.
	-- Align "above prize": preferred heuristic is prize-rod fully inside claw-rod
	-- (see claw.lua encapsulation). dXZ thr kept as fallback / axis stop band.
	CLAW_ALIGN_THRESHOLD = 0.08, -- fallback XZ + per-axis release band
	CLAW_ALIGN_SOFT_THRESHOLD = 0.16, -- fallback soft XZ
	CLAW_ALIGN_USE_ENCAPSULATION = true, -- prize beam âŠ‚ claw beam = on-target
	-- Optional radial margin overrides (studs). nil = derive from rod diameters.
	-- Hard: prize volume inside claw volume (clawR âˆ’ prizeR). Soft: prize axis in clawR.
	CLAW_ENCAP_HARD_MARGIN = nil,
	CLAW_ENCAP_SOFT_MARGIN = nil,
	CLAW_ORBIT_HOLDS = 8, -- after this many near-target holds without improvement, soft-OK
	CLAW_MOVE_STEP_STUDS = 0.12, -- reference granularity
	CLAW_HOLD_POLL = 0.03, -- sample rate while key is held down
	CLAW_HOLD_MAX = 1.0, -- max seconds per WASD key hold while aiming (was 2.5 â€” overshot/drift)
	CLAW_CORRECT_TAP = 0.05, -- opposite-key tap duration after overshoot
	CLAW_HOLD_RELEASE_SLACK = 0.02, -- release slightly early before thr (inertia)
	CLAW_NEAR_TAP_DIST = 0.22, -- below this, use short taps not long holds
	CLAW_STABLE_CHECKS = 2, -- fewer once soft-aligned
	CLAW_STABLE_INTERVAL = 0.10,
	CLAW_SETTLE_WAIT = 0.3, -- after aim move, wait before rescan/confirm/drop (claw settles)
	CLAW_MAX_SECONDS = 90,
	CLAW_LOG_DIR = "dumps",
	CLAW_LOG_UI_LINES = 12, -- last N lines on Claw tab (cleared every Start)

	-- Claw travel AABB (world XZ) = machine walls from W/A/S/D max dumps, then a small
	-- keep-out so prizes flush against glass are invalid (center must be inside inset).
	--   W: 19-21-14 (-79.044, 37.938)  A: 19-21-17 (-79.232, 40.136)
	--   S: 19-21-22 (-82.835, 37.612)  D: 19-21-25 (-82.870, 40.734)
	CLAW_REACH_ENABLED = true,
	CLAW_REACH_MARGIN = 0.12, -- small wall keep-out (studs) on each side of the flush box
	CLAW_OUTSIDE_REACH_SLACK = 0.0,
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

	-- Hard blacklist: on join â†’ Stop All; wait this long before auto re-enabling Kill Aura
	-- (Anti-AFK jump stays on). Manual KA enable cancels the scheduled resume.
	PLAYER_BLACKLIST_NAMES = {
		"Swaroff",
		"Ekiezu",
		"URIZEN",
		"Musmeed",
		"toyy",
		"batagorsomay",
		"ChronoArray",
	},
	PLAYER_BLACKLIST_LOCK_SECONDS = 30 * 60, -- 30 minutes

	-- Between fights: maintain bless buff via QS3 hold (dump: BuffIcon_BUFF_BLESS)
	-- Path: HUD.HealthManaContainer.StatusContainer.BuffIcon_BUFF_BLESS
	COMBAT_BUFF_ENABLED = true,
	COMBAT_BUFF_SLOT = 3,
	COMBAT_BUFF_HOLD = 5, -- hold E seconds after arming QS3
	COMBAT_BUFF_ICON_NAME = "BuffIcon_BUFF_BLESS",
	COMBAT_BUFF_ICON_PREFIX = "BuffIcon_", -- any visible BuffIcon_* also counts as "has buff"
	COMBAT_BUFF_RETRY_CD = 12, -- don't spam re-cast if icon still missing

	-- Named boss/mob tags (match substrings on model.Name). Combat uses slots only.
	BARREL_CHAMPION_MATCH = "BarrelChampion",
	BARREL_CHAMPION_TAGS = { "Barrel Champion", "BarrelChampion", "Barrel_Champion" },
	JUNK_KING_MATCH = "JunkKing",
	JUNK_KING_TAGS = { "Junk King", "JunkKing", "Junk_King" },
	JUNK_KING_ENGAGE_RANGE = 30,
	TIN_TORTOISE_MATCH = "TinTortoise",
	TIN_TORTOISE_TAGS = { "Tin Tortoise", "TinTortoise", "Tin_Tortoise" },
	TIN_TORTOISE_ENGAGE_RANGE = 30,

	-- Combat / utility quickslots. ALL are TOGGLES: press N to arm (diamond ON), then fire steps.
	-- Do NOT put One/Two/â€¦ in steps (re-pressing toggles OFF). Cast arms via handler.slot.
	-- QS1/QS4 = kill-aura damage. QS3 = bless buff only (between fights, not in cast sequences).
	QUICKSLOT_USAGE = {
		[1] = {
			-- tap cast (no hold)
			steps = { { key = Enum.KeyCode.E } },
			minCd = 0.5,
		},
		[3] = {
			-- bless buff: hold E 5s (applied between fights when BuffIcon missing)
			steps = { { hold = Enum.KeyCode.E, duration = 5 } },
			minCd = 1,
			utility = true, -- not a combat damage slot
		},
		[4] = {
			-- hold E for 5s, release; 2s CD; no lockout â€” may switch to QS1 immediately
			steps = { { hold = Enum.KeyCode.E, duration = 5 } },
			minCd = 2,
		},
	},
	-- Prefer this slot when ready; fall back to other combat slots (QS1)
	DEFAULT_COMBAT_SLOT = 4,

	-- Deprecated: creature-specific sequences removed. Kill aura = nearest mob + ready slot.
	COMBAT_HANDLERS = {},
}

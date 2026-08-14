-- Optional LOCAL claw prize priority override.
--
-- How to use (friend / personal prefs without editing config from GitHub):
--   1. Copy this file to:  portal_mage/claw_priority.lua
--      (same folder as claw.lua — scripts/portal_mage/ or robocks/portal_mage/)
--   2. Edit tiers below. Lower tier number = grab first.
--   3. Reload portal_mage. Boot prints: claw_priority local override (N keywords)
--
-- This file is never fetched from GitHub. Only claw_priority.lua on disk is loaded.
-- If claw_priority.lua is missing, config.CLAW_PRIORITY_KEYWORDS is used instead.
--
-- Matching: prize name is lowercased + non-alphanum stripped, then first keyword
-- substring wins. Put longer keys before shorter ones when one contains the other
-- (e.g. aurorite before aurora, triacoin before tria).
-- Unmatched prizes = tier 8 (above tier-9 junk).

return {
	-- P1 best
	{ key = "grimoire", tier = 1 },
	{ key = "circuit", tier = 1 },
	{ key = "meteor", tier = 1 },
	{ key = "timber", tier = 1 },
	{ key = "aurora", tier = 1 },
	{ key = "tome", tier = 1 },
	-- P2
	{ key = "spirit", tier = 2 },
	-- P3
	{ key = "goblincoin", tier = 3 },
	{ key = "amber", tier = 3 },
	{ key = "living", tier = 3 },
	-- P4
	{ key = "heartwood", tier = 4 },
	-- P5
	{ key = "enchantedbark", tier = 5 },
	{ key = "enchantedwood", tier = 5 },
	-- P6
	{ key = "briarvine", tier = 6 },
	{ key = "memorysap", tier = 6 },
	{ key = "mysticessence", tier = 6 },
	{ key = "glowingmoss", tier = 6 },
	-- P7
	{ key = "aurorite", tier = 7 },
	{ key = "junkcore", tier = 7 },
	-- P9 junk (keep long forms before "tria")
	{ key = "triacoin", tier = 9 },
	{ key = "triapouch", tier = 9 },
	{ key = "triasack", tier = 9 },
	{ key = "tria", tier = 9 },
	{ key = "scrapmetal", tier = 9 },
	{ key = "rustygear", tier = 9 },
	{ key = "solite", tier = 9 },
	{ key = "lumite", tier = 9 },
}

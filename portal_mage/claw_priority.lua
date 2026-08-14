-- portal_mage/claw_priority.lua — claw prize pick order (local config)
--
-- Edit via the Config tab or by hand. Lower tier = grab first.
-- Unmatched prizes ("others") use the first empty tier (1–10), else 11.
-- Boot creates this file with defaults if missing.

return {
	{ key = "spirit", tier = 2 }, -- spirit stones; own tier under P1
	{ key = "enchantedbark", tier = 5 },
	{ key = "heartwood", tier = 4 }, -- also matches AncientHeartwood
	{ key = "enchantedwood", tier = 5 },
	{ key = "mysticessence", tier = 6 },
	{ key = "briarvine", tier = 6 },
	{ key = "memorysap", tier = 6 },
	{ key = "goblincoin", tier = 3 },
	{ key = "aurorite", tier = 7 },
	{ key = "junkcore", tier = 7 },
	{ key = "glowingmoss", tier = 6 },
	{ key = "grimoire", tier = 1 },
	{ key = "circuit", tier = 1 },
	{ key = "meteor", tier = 1 },
	{ key = "timber", tier = 1 },
	{ key = "aurora", tier = 1 },
	{ key = "amber", tier = 3 },
	{ key = "living", tier = 3 }, -- LivingBark etc.
	{ key = "tome", tier = 1 },
	-- Junk / currency (below generic mats)
	{ key = "triacoin", tier = 9 },
	{ key = "triapouch", tier = 9 },
	{ key = "triasack", tier = 9 },
	{ key = "tria", tier = 9 },
	{ key = "scrapmetal", tier = 9 },
	{ key = "rustygear", tier = 9 },
	{ key = "solite", tier = 9 },
	{ key = "lumite", tier = 9 },
}

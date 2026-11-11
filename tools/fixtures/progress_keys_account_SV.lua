-- Fixture for tools/test_progress_keys.lua: an account SavedVariables file (WTF/Account/<account>/SavedVariables/
-- CompletionRoute.lua) in the layout written by releases BEFORE stable step keys: progress keyed by author step index.
-- Built from the structure of the real files (2026-11-10; field names, nesting, empty per-guide tables, records copied
-- in from other clients by tools/sync_progress.lua, records without `gametype`).  No real character or realm names:
-- "Tester-Test" is the offline stubs' own character (tools/stubs.lua), the others are placeholders.
-- Guide "t:keys:a" is the test's synthetic guide (v1, 19 steps); "wiki:era:1429:Alliance" is a real generated guide,
-- used only when that file is present.
CompletionRouteDB = {
	["chars"] = {
		["Tester-Test"] = {
			["class"] = "WARRIOR",
			["done"] = {
				["t:keys:a"] = {
					[1] = true,
					[2] = true,
					[3] = true,
					[9] = true,
					[16] = true,
					[99] = true,
					[-2] = true,
				},
				["t:keys:empty"] = {
				},
				["wiki:era:1429:Alliance"] = {
					[1] = true,
					[2] = true,
					[4] = true,
				},
			},
			["faction"] = "Alliance",
			["flavor"] = "era",
			["gametype"] = "era",
			["hardcore"] = false,
			["harvested"] = "2026-11-01 18:00:00",
			["level"] = 12,
			["migrated"] = true,
			["name"] = "Tester",
			["questCount"] = 2,
			["quests"] = {
				[7] = true,
				[15] = true,
			},
			["race"] = "Human",
			["realm"] = "Test",
			["skipped"] = {
				["t:keys:a"] = {
					[7] = true,
				},
				["t:keys:empty"] = {
				},
				["wiki:era:1429:Alliance"] = {
				},
			},
			["updated"] = "2026-11-01 18:30:00",
		},
		["Alt-Test"] = {
			["class"] = "MAGE",
			["done"] = {
				["t:keys:a"] = {
					[5] = true,
					[10] = true,
				},
			},
			["faction"] = "Alliance",
			["flavor"] = "era",
			["gametype"] = "era",
			["hardcore"] = false,
			["level"] = 20,
			["migrated"] = true,
			["name"] = "Alt",
			["quests"] = {
			},
			["race"] = "Gnome",
			["realm"] = "Test",
			["skipped"] = {
				["t:keys:a"] = {
				},
			},
			["updated"] = "2026-10-20 10:00:00",
		},
		["Old-Test"] = {
			["class"] = "HUNTER",
			["done"] = {
				["t:keys:a"] = {
					[6] = true,
				},
			},
			["faction"] = "Alliance",
			["flavor"] = "era",
			["level"] = 30,
			["migrated"] = true,
			["name"] = "Old",
			["quests"] = {
			},
			["race"] = "Dwarf",
			["realm"] = "Test",
			["skipped"] = {
			},
			["updated"] = "2026-08-20 10:00:00",
		},
		["Ret-Other"] = {
			["class"] = "DRUID",
			["done"] = {
				["t:keys:a"] = {
					[1] = true,
					[11] = true,
				},
			},
			["faction"] = "Alliance",
			["flavor"] = "retail",
			["gametype"] = "retail",
			["hardcore"] = false,
			["level"] = 67,
			["migrated"] = true,
			["name"] = "Ret",
			["quests"] = {
			},
			["race"] = "Worgen",
			["realm"] = "Other",
			["skipped"] = {
			},
			["updated"] = "2026-10-15 08:35:43",
		},
		["Mop-Other"] = {
			["class"] = "ROGUE",
			["done"] = {
				["t:keys:a"] = {
					[8] = true,
				},
			},
			["faction"] = "Alliance",
			["flavor"] = "mop",
			["level"] = 16,
			["migrated"] = true,
			["name"] = "Mop",
			["quests"] = {
			},
			["race"] = "NightElf",
			["realm"] = "Other",
			["skipped"] = {
			},
			["updated"] = "2026-08-20 19:03:35",
		},
	},
	["farmNodes"] = {
	},
	["instanceEntrances"] = {
	},
	["knownTaxi"] = {
	},
	["lastSync"] = "2026-11-01 18:31:00",
	["profile"] = {
		["accountQuests"] = true,
		["accountWide"] = false,
		["scope"] = "char",
	},
	["roadTrace"] = {
	},
	["verifyAll"] = {
	},
}

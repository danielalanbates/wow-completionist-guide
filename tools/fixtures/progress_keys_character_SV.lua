-- Fixture for tools/test_progress_keys.lua: the per-character SavedVariables file (WTF/Account/<account>/<realm>/
-- <character>/SavedVariables/CompletionRoute.lua) of "Tester-Test" in the layout written before stable step keys.
-- done / skipped are the copies the client writes of the account record's tables (Core/Account.lua aliases them);
-- reopened (steps stepped back to) lives only here.  Built from the structure of the real files; no real names.
CompletionRouteCharDB = {
	["bind"] = {
	},
	["done"] = {
		["t:keys:a"] = {
			[1] = true,
			[2] = true,
			[3] = true,
			[9] = true,
			[16] = true,
			[-2] = true,
		},
		["t:keys:empty"] = {
		},
		["wiki:era:1429:Alliance"] = {
			[1] = true,
			[2] = true,
			[4] = true,
			[5] = true,
		},
	},
	["guide"] = "t:keys:a",
	["knownTaxi"] = {
	},
	["laps"] = {
	},
	["lastVerify"] = {
	},
	["luaErrors"] = {
	},
	["luaErrorsVersion"] = "test",
	["parked"] = {
	},
	["reopened"] = {
		["t:keys:a"] = {
			[4] = true,
		},
		["t:keys:empty"] = {
		},
	},
	["skipped"] = {
		["t:keys:a"] = {
			[7] = true,
		},
		["t:keys:empty"] = {
		},
		["wiki:era:1429:Alliance"] = {
		},
	},
	["step"] = 1,
}

# Target Beacon + Account-Wide Progression

Two features added on top of the routing core. Both work identically on Era, TBC Anniversary,
Mists (Classic) and retail from the **same** addon folder — no per-flavor forks.

## 1. Target Beacon (`UI/Beacon.lua`)

"Where is the thing?" Zygor puts a marker over the quest giver's head; so does this.

| Surface | What you get | API used | Availability |
|---|---|---|---|
| Nameplate | **The game's own step icon** over the unit's head — the yellow quest `!` for accept steps, `?` for turn-ins, the raid-target skull for kills, coin/bag/boot for buy/use/run steps (`Guide.ACTION_ICON`). `/cr icon` switches to a plain arrow. | `C_NamePlate.GetNamePlates` with a WorldFrame fallback | all flavors |
| Target / mouseover frame | Same marker pinned to the left of the unit frame, so you can confirm the click landed | `PLAYER_TARGET_CHANGED`, `UPDATE_MOUSEOVER_UNIT` | all flavors |
| One-click select | Secure button on the arrow frame running `/cleartarget` + `/targetexact <name>` + `/target <name>` | `SecureActionButtonTemplate` macro | all flavors |
| Minimap + world map | Pin on every coordinate the step carries | HereBeDragons-Pins-2.0 (bundled) | all flavors |

### Where the name comes from
1. `|T|Name|` on the guide line (authoritative — guide authors should supply this).
2. Otherwise mined from the step title with the community phrasing conventions:
   `A ... from <NPC>`, `T ... to <NPC>`, `K Kill <Mob>`, `C ... talk to <NPC>`.
   Patterns are greedy-prefixed (`.*%f[%a]from`) so the **last** "from"/"to" wins —
   "Report to Goldshire to Marshal Dughan" resolves to *Marshal Dughan*, not *Goldshire to …*.
3. `cleanName` drops trailing parentheticals, `<Title>` fragments, trailing punctuation, and
   anything that starts with a digit or runs over 48 characters.

The current step plus the next 4 upcoming steps contribute names, so sticky/parallel objectives
stay marked (Zygor behaviour).

### Two bugs only a live client could find
* `C_NamePlate.GetNamePlates(true)` — that second argument is `isSecure`, and passing it from
  insecure addon code returns **nothing**. The over-head marker silently never attached. Never
  pass it; there is now an offline test asserting the call sites.
* Re-anchoring the marker on every 0.5s rescan while its bob animation was mid-flight made it
  stutter across the screen. `Beacon.Park` now anchors once and is idempotent, and the bob can be
  turned off entirely (`profile.beacon.bounce`).

Clients that expose nothing through `C_NamePlate` fall back to scanning `WorldFrame` children and
reading the unit name out of the plate's FontString, the way classic nameplate addons do.

### Deliberate non-goals
- **No world-space 3D overlay.** WoW's API cannot draw into the 3D scene; the nameplate anchor is
  the only supported "over its head" attachment point and is what every addon of this class uses.
- **No raid target icons.** `SetRaidTarget` needs group lead and would stomp the group's marks.

### Settings
`/or beacon` toggles it. Options panel: enable, scale, map pins, target button.

## 2. Account-wide progression (`Core/Account.lua`)

Every character's progress now lives in **one** account-level table,
`CompletionRouteDB.chars["Name-Realm"] = { done = {[guideID] = {[stepIndex] = true}}, skipped = …,
level, class, faction, flavor, updated }`. The per-character SavedVariables file keeps settings only.
Old per-character progress is migrated on first login (`me.migrated = true`).

**Opt-in** (`profile.accountWide`, default **off**, `/or accountwide`):

- **OFF** — classic per-character behaviour. Other characters' data is read for *display only*
  (guide tooltips show "This character X% / Whole account Y%"). Completionists leave it off and
  every character does every guide.
- **ON** — a step counts as done if **any** character on the account finished it. Skips never
  transfer: a skip is a personal choice, not account progress.

**Quest-level union** (`profile.accountQuests`, default on, only active when `accountWide` is on):
step indices only line up inside one guide, but quest IDs line up across every guide and every
source. Each character records the quests it turns in (`QUEST_TURNED_IN`, plus manual `T` step
completion) in `chars[key].quests`, so a quest an alt finished also clears the equivalent step in a
*different* guide covering the same content. `|QID|1&2|` requires all, `|QID|1^2|` requires any.

**The bulk sweep is sandboxed.** `/cr verifyall` loads all ~9000 guides, which auto-completes a
step in nearly every one of them. That used to land in the character's real record (4470 steps
across 4384 guides on one test character). `Account.BeginScratch()` / `EndScratch()` now divert
those writes; `tools/clean_sweep_progress.py` cleans up records written by older builds.

`/cr chars` prints the roster (steps + guides completed per character), `/or forget <Name-Realm>`
drops a deleted character. Guide list rows show a completion badge for guides already parsed
(never forced — the quest DB is ~9k guides and the list refreshes per keystroke).

## Verification

- Offline: `luajit tools/test_offline.lua` — sections 7 (account) and 8 (beacon) assert the name
  mining, the nameplate rescan, the secure macro, the 25%/75% progress math, and that the opt-in
  gate is honoured in **both** directions.
- Per-flavor load: `luajit tools/test_load_all.lua`, `luajit tools/validate_toc.lua`.
- In-game: `/or verifyfeatures` writes a named PASS/FAIL row per feature into
  `CompletionRouteDB.featureVerify`; it also runs automatically 30s after login.
  `python3 tools/collect_verify.py` pulls those out of every flavor's SavedVariables into
  `docs/verification.sqlite`; `docs/verification.sql` holds the schema and the report queries.

## 3. "Next Step" category (`UI/GuideMenu.lua`)

The first category in the guide browser is synthetic: **everything you could do right now that is
level-matched to you**, so a completionist can see the full menu of currently-appropriate content
without hunting through the tree.

A guide qualifies when:
* it declares a level bracket **and that bracket contains your current level**
  (`min <= level <= max + 0.99`). Level-agnostic guides — professions, most reputation entries —
  are things you could do at *any* level and would drown the bucket, so they stay in their own
  category; and
* it is not already at 100% for the active scope (character, or account when `accountWide` is on).

Ordering is "cheapest thing to do next": tightest bracket → most-progressed → our own guides first,
then the top 12 are priced by **actual travel time** (`Guide.GuideETA`, which routes from where you
are standing) and re-sorted so the nearest one floats to the top. Only 12 are priced because
`GuideETA` parses the guide and the quest DB holds thousands. Priced rows show `~Nm` next to the
level bracket. The result is cached for 30 seconds and invalidated when your level changes.

Verified live on TBC Anniversary at level 66: 77 matches, top entry Terokkar Forest [64-66] ~4m,
then Blade's Edge Mountains [65-67] ~7m (active).

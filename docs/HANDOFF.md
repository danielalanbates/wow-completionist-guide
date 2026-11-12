# Handoff for the next AI (written 2026-11-10, 16:30 Pacific)

Read this first, then `docs/STATUS.md` (newest section on top), `docs/IDEAS.md` and `docs/FINISH_PLAN.md`.

**2026-11-11 night: there is one build.** The owner runs exactly what a public release ships. Sections 3 to 5 below
were written before that: where they say dev build, fallback points, `--no-fallback`, `--wiki-only`, `--shippable`,
`_gaps` guides, `Imported_Entrances` or a release rebake, read `docs/RELEASE.md` instead. The generators' default
output is the build, and none of those variants exists any more.
These notes cover work that was **in flight** when they were written. Before trusting any line, check the real state
with the commands in each table, because jobs may have finished, failed or been cut off since.

## 0. The goal (Daniel's words, condensed)

An extremely versatile guide addon, freely available to anyone on **every** version of WoW (Classic Era, TBC Anniversary,
MoP Classic, Retail, WoW Forever) as **one** addon. It has the full feature set of a commercial guide suite, but quests are
community-driven and use only freely available information. **Optimal routing for the chosen guide is the core**: no
other free addon has it. Coverage target: every quest, mission, story, item-started quest and achievement. Results are
charted in SQL (`docs/verification.sqlite`). Daniel beta-tests in game and does not run in-game commands, so location and
quest data must be fixed offline with every resource available. An **online quest database is allowed, including as a
separate GitHub repo** (see section 5, phase 4).

## 1. Owner rules that bind this project

| Rule | Detail |
|---|---|
| No commercial guide content, ever | The project is fully independent. Never read, import, imitate or **name** the commercial guide addon it replaced. It was purged from all git history on 2026-11-07; `tools/install.sh` refuses to install if such files reappear. |
| Data sources | Quest and NPC data come from the Warcraft Wiki (warcraft.wiki.gg, CC BY-SA 4.0) and Blizzard client data (wago.tools DB2), plus the project's own data. Nothing derived from another addon is read, generated, loaded, installed, baked or shipped (the WoW-Pro adapter and the Questie-derived dev build were both removed on 2026-11-11: an addon for the public cannot depend on one, and the owner runs only the public build). The Questie tooling is in `archive/questie-tooling/`; `tools/measure/` holds one explicit offline comparison that never writes into `CompletionRoute/`. Wiki-derived data ships under CC BY-SA. Code is PolyForm Noncommercial with the 10% commercial rider, all rights reserved (batesai.org, help@batesai.org). |
| One build | What the six TOCs list = what `tools/install.sh` installs = what the generators write by default = what `tools/bake_resume.py` bakes = what `tools/package_release.py` packages (plus the version stamp). `tools/validate_toc.lua`, the installer and the packager's gate each refuse a file outside that set. |
| Testing | Daniel beta-tests in game himself. The AI never logs into Battle.net, launches WoW or drives the game. Verification is offline: `tools/vplayer.lua`, `tools/test_*.lua`, `tools/validate_toc.lua`, plus his reports. |
| Releases | GitHub releases are public and must be bug free, so none is made until Daniel's beta passes. The beta is the local install plus the companion app in /Applications ("Completionist's Guide.app", 2.0.0-beta). The app runs `tools/install.sh` from the Google Drive project folder and does not bundle guide data, so it needs a rebuild only when `app/` changes. |
| Publishing | Work goes to `github.com/danielalanbates/wow-completionist-guide` as a PR. **Merge locally and push**, not with the GitHub merge button or `gh pr merge`: those stamp the owner's primary email on the merge commit, which was purged from history on 2026-11-10. The repo-local `user.email` is the GitHub noreply address. |
| Flight paths (idea #2) | Flight paths are shared across characters **only on Retail and WoW Forever**. On Classic Era, TBC Anniversary and MoP Classic each character has its own. |
| Quest skipping | Skipping a quest warns if later quests need it. Confirming drops the whole chain, **rebuilds the guide** without it, and re-plans for the **least game time (shortest travel)**. Replacement quests are a separate idea, not part of the feature. |
| Mac limits | 8 GB of RAM. Keep at least 8 GB of disk free (guard at 11 GB). Run one heavy job at a time, using `~/Downloads/CompletionistGuide-work/heavy.sh <cmd>` (a lock plus nice 10). Never close, kill or install into a WoW client that is running (`pgrep -lf 'World of Warcraft.app/Contents/MacOS'`). No auto-test loops and no app-launch loops. |
| Where to save | The only place to write is under ~/Downloads. The canonical project copy is Google Drive → My Drive/Code/Completionist's Guide. Archive code that does not work into an archive folder; never delete it silently. |

## 2. Where things live

| What | Where |
|---|---|
| Main work clone (branch `master`) | `~/Downloads/CompletionistGuide-work/repo`. It holds the gitignored generated data (`CompletionRoute/Guides/Imported_{Wiki,Spine,Gold,Professions,Achievements,QuestLines,Missions}_*`, `CompletionRoute/Data/{RouteOrder,QuestDeps}_*`, `tools/db2`, `tools/wiki/cache`, `tools/wiki/wiki.sqlite`, `docs/verification.sqlite`). No other generated file belongs under `CompletionRoute/`. |
| Offline measurement inputs | `tools/measure/questie/` (gitignored): the older Questie-derived `Imported_Quests_<flavor>.lua` files, read only by `gen_wiki_guides.py --measure-fallback` (`tools/measure/README.md`). |
| Feature worktrees | `~/Downloads/CompletionistGuide-work/wt-skip` (`quest-skip`), `wt-graph` (`routing-graph`), `wt-bug` (`beta-bug-report`), `wt-pkg` (`release-packager`). Their generated-data paths are **symlinks into repo/**, so never write through them. `git worktree list` shows them. |
| Python venv (OR-Tools) | `~/Downloads/CompletionistGuide-work/venv` |
| Optimizer job directory | `~/.claude/jobs/ff3c728a/tmp` (hardcoded as `TMP` in `tools/optimize_routes.py` and `tools/cost_matrix.lua`; `CR_TMP` overrides it in `tools/bake_resume.py`). Result rows: `routeopt/<flavor>.jsonl`. |
| Canonical copy | Google Drive → My Drive/Code/Completionist's Guide (has the generated data too). Sync with plain `cp` or `rsync` **without `--delete`**: on 2026-11-07 `rsync --delete` wiped the gitignored generated files and they had to be restored from the game folders. |
| Game clients | `/Volumes/x10/Video Games/Mac/World of Warcraft/{_classic_era_,_anniversary_,_classic_,_retail_,_forever_}`. `tools/install.sh <dir>` installs the build, each client only its own flavor's data; a generated file that is not part of the build stops it. |

## 3. Done on 2026-11-10

* PR #3 (gold guides, secondary professions, guides listed by level) merged.
* The owner's personal email was purged from all git history (file contents and commit metadata) and force-pushed. The merged
  branch was deleted. GitHub still keeps `refs/pull/1-3/head` with the old history, which only GitHub Support can remove.
* `tools/cost_matrix.lua --list` prints each quest guide's id, step count and checksum without computing matrices.
* `docs/IDEAS.md` was added: 60 ranked ideas. Daniel approved #1–#9.
* `tools/bake_resume.py`: the resumable bake driver described in section 4.

## 4. In flight when this was written

**Update 2026-11-10, 21:20.** The Mac slept from about 20:50 to 21:00, which killed two builders mid-response. To prevent
idle sleep, `caffeinate -is -w <bake pid>` is now attached to the bake driver and ends with it. State:
* `beta-bug-report` is **done**: built, independently verified (1 major and 4 minor findings, all fixed with regression
  tests), and all harnesses pass.
* `routing-graph` and `release-packager` were relaunched with a "continue the interrupted work" brief.
* `quest-skip`: built (6 commits); the correctness check is done, and the routing and performance check was running.
* Bake: 698 of 1,221 guides done.
* Phase 4 (`~/Downloads/CompletionistGuide-work/wow-completionist-data`, local git with no remote) was started early,
  because it touches no addon file. Its build, verify and fix is running.

**Update 2026-11-10, 22:20.** The main bake **finished**: all 1,221 guides, 0 failures, and every flavor's rows are
current (tbc 354, forever 240, mop 772, retail 1021, era 234). The new `RouteOrder_mop.lua` and `RouteOrder_retail.lua`
are installed in `_classic_` and `_retail_` and copied to Drive. The forced map-fix pass (235 era/tbc/forever guides)
started at 22:18 under `caffeinate -is`. If it dies, re-run
`python3 tools/bake_resume.py --flavors era,tbc,forever --force-mapfix`. When it ends, install into
`_classic_era_`, `_anniversary_` and `_forever_`, copy those three RouteOrder files to Drive, and refresh STATUS.

**Update 2026-11-10, 22:45.** From here this file is kept on branch `integration` (worktree `wt-int`).
* `quest-skip` is **done**. It was built, checked by two independent reviewers (1 major and 11 minor or performance
  findings), and all of those were fixed. 542 skip checks pass.
* `integration` (worktree `wt-int`) = `route-bake-finish` + `quest-skip` + `beta-bug-report`. Conflicts were in Slash help,
  README and STATUS (both sides kept). Every harness passes on it, plus the ingest unit tests.
* Phase 2a started as workflow `beta-features-phase2a`: #6 in worktree `wt-ids` (branch `stable-step-id`) and #7 in
  `wt-auto` (branch `auto-quest`), both from `integration`. #9 then #1 wait for `routing-graph`, because they change
  the same cost code.
* Still running: `routing-graph` and `release-packager` (phase-1 resume), the data repo, and the map-fix bake.

**Update 2026-11-10, 22:55.** `routing-graph` and `release-packager` are **done**, both built, verified and fixed, and both
are merged into `integration`, merge order quest-skip → beta-bug-report → routing-graph → release-packager. Fix commit
`472f8a4` resolved three break points between branches:
* The quest-skip re-planner's `FindPaths` was ported to the discovered-flight-path rule.
* `test_bug_report` now expects the new default policy, `known`.
* The packager learned `Data/QuestDeps_*.lua`: only the new `gen_quest_deps.py --wiki-only` build ships, and the
  local build names its sources (Questie-derived gaps guides, storylines) in its header, so the packager refuses
  it. `Data/Teleports.lua` (wiki CC BY-SA) was added too.

Every harness passes on `integration`. Phase 2b (#9 cost model, then #1 bake gate and coordinate-aware checksum) runs
as workflow `beta-features-phase2b` in worktree `wt-cost` (branch `cost-model`, from `integration`). `wt-ids` and
`wt-auto` were branched before these merges, so expect conflicts in Slash help, README and STATUS when they merge.

**Update 2026-11-10, 23:00.** The map-fix bake pass is **done**: 235 guides, 0 failures, and every flavor's rows are
current. All five RouteOrder files are installed in the five clients (route-bake-finish code, which is the current beta)
and copied to Drive. STATUS has the counts. These orders become stale on purpose once #1 changes the checksum, and
then the full rebake follows.

**Update 2026-11-10, 23:15.** Phase 4 is **done**. `wow-completionist-data` was built, reviewed (4 major and 4 minor
findings, all fixed: Classic coordinates read against Blizzard positions with a per-point `confidence`, retail turn-in
pins beat drifting wiki points, shared quest ids, faction-alternative prerequisites), privacy-checked across all history,
and **published** at https://github.com/danielalanbates/wow-completionist-data (public). That repo holds 49 tests, its
own `docs/HANDOFF.md`, and the plan for the addon generators to read from it (not implemented). Its working tree, without
`.git` and `build/`, is copied to Drive at My Drive/Code/wow-completionist-data. The addon README links to it.

**Update 2026-11-11, 03:05.**
* `stable-step-id` (#6) and `auto-quest` (#7) are **done**: built, verified and fixed, then merged into `integration`
  (`d6b6d9f`, `b0dbdf1`). The auto-quest merge moved QuestAuto to key-based skip marks; every harness passes, including
  test_progress_keys (196) and test_quest_auto (1,272). test_skip's 2 ms frame check can flake under machine load; it
  is a known, existing timing check.
* Still running:
  * Phase 2b (`wt-cost`, #9 then #1). It was branched before these two merges, so expect `Core/Guide.lua` conflicts
    (step keys against the new checksum).
  * Phase 5, workflow `coverage-push-phase5`, in two worktrees. Each has **private copy-on-write data** (`cp -c`),
    not links, so its generators may write.
    * `wt-cov1` (`coverage-ach`): achievements, item-started quests, and storylines from wiki and Blizzard data only.
    * `wt-cov2` (`coverage-prof`): profession tiers, no-route rows, the Blasted Lands offset, and `--no-fallback`
      points for release.
  * Their generated data is not merged. Merge the code, then re-run the generators in `repo/` as each branch's
    report says, **before** the full rebake.
* `caffeinate -is -t 36000` holds off sleep until about 13:00.

**Update 2026-11-11, 04:55.** `cost-model` (#9 then #1) is **done**: built, verified (1 major, 5 minor findings), fixed, and
merged into `integration` (`7b92174`). That merge kept both the step keys and `CostModel.Locate`, and loads CostModel in
test_progress_keys and test_quest_auto. Every harness passes **except `test_route_order`, which fails by design**:
checksum v2 makes all 1,953 old RouteOrder entries stale, so until the rebake every guide plays in author order plus
the live window.
* **Full rebake: waits for phase 5.** Phase 5 regenerates most guides, so baking first would only be redone. Order:
  1. merge `coverage-ach` and `coverage-prof` into `integration`;
  2. `git worktree remove wt-int`, then check out `integration` in `repo/`;
  3. re-run the generators in `repo/` as each phase-5 report says, and `tools/gen_quest_deps.py`;
  4. `heavy.sh python3 tools/bake_resume.py --dry-run`, then run it without `--dry-run` (gate on; about 7 to 10 h; safe to
     kill and re-run);
  5. `test_route_order` must pass, then `test_cost_parity` and `unittest tools/test_bake_gate.py`;
  6. install into clients that are not running, sync Drive, open the PR, and merge locally.
* Free-AI second opinion, per the owner's rule to use free AIs where possible. Gemini 2.5 Flash on the free tier
  (gemini-pro-latest hit its quota, 3.8-flash was overloaded) reviewed QuestAuto, Skip, CostModel, Replan and Teleports.
  It reported 2 minor items, and both were rejected:
  * "QuestIsDaily is Classic only": wrong. Retail's own quest frame uses the global.
  * "store nil instead of true for a guide-less root": that would lose the skip, because nil means unskipped
    (Skip.lua:846).
  The script and its output are in the session scratchpad (`freeai/`). Nothing changed.

**Update 2026-11-11, 07:45 (new session; the earlier one was cleared).**
* Phase 5 (`coverage-push-phase5`, run `wf_50bf916c-593`) survived the session change. Both builds and both reviews are
  done (ach: 6 major + 3 minor findings; prof: 4 major + 6 minor). The two fix agents were still running in `wt-cov1` and
  `wt-cov2` (uncommitted edits there are theirs; do not touch). Results: that run's `journal.jsonl`.
* A read-only review of the merged tree runs as `integration-premerge-review` (`wf_d7d40fec-138`): real-client API and
  protected-action safety, cross-feature state and SavedVariables safety, plain Lua 5.1 behaviour and cost; then one
  skeptic verifies every finding. Fixes are applied on `integration` **after** the two coverage branches are merged.
* **Nothing since PR #3 is on GitHub.** A bundle of all local branches is in Drive at
  `My Drive/Code/Completionist's Guide/_wip-backup/` (restore with `git clone <bundle>`). The Drive working tree is still
  the 11-10 beta (code of `route-bake-finish` + its data), on purpose: the companion app installs from it, so it only
  changes when a consistent code + data + bake set exists.
* **Owner's work email in public history.** 40 commits on `origin/master` (2026-09-18 to 2026-11-09) carry the global
  `git config user.email` as author and committer; the 11-10 purge only looked for the other address. Plan: at publish
  time, with all worktrees removed, rewrite author/committer to the GitHub noreply address in a fresh mirror clone
  (`git filter-repo --mailmap`), check that every branch tree is unchanged, keep a rollback bundle, then force-push
  `master`. The repo-local `user.email` is already the noreply address; the global one is the owner's and is left alone.
* `tools/optimize_routes.py`, `tools/cost_matrix.lua` and `tools/collect_routes.py` hardcode a home-directory path for the
  job folder. Replace with `CR_TMP` or `~` expansion before publishing.
* Order from here: phase-5 fixes land -> merge `coverage-ach`, `coverage-prof` -> apply review fixes -> all harnesses ->
  check out `integration` in `repo/` -> regenerate (section 5 of each phase-5 report) -> full rebake -> install, Drive,
  PR, local merge, push.

**Update 2026-11-11, 17:15.**
* A usage limit stopped every agent twice (08:03 and 12:24). `coverage-ach` finished; the `coverage-prof` fixer did
  not, so its uncommitted work was committed as `5bec90d` and finished by hand. Both are merged; `integration` is now
  checked out in `repo/` and all other worktrees except `wt-cov1` / `wt-cov2` are gone (those two hold only caches
  that were merged into `repo/`; remove them with `git worktree remove --force`).
* Data regenerated in `repo/`; tests and numbers are at the top of STATUS. The regeneration script (cache merge,
  generators, every harness) is a session scratch file; the order is: `parse_wiki.py`, `fetch_titles.py`,
  `fetch_titles.py --db2-names`, `fetch_coord_history.py`, `parse_wiki.py`, `gen_wiki_guides.py`,
  `gen_professions.py`, `gen_gold.py`, `gen_completion_guides.py retail mop`, `gen_quest_deps.py`, `coverage.py
  --label L`, `status_report.py --label L`.
* **Rebake running** (started 17:08): `caffeinate -is nice -n 10 venv/bin/python tools/bake_resume.py` from `repo/`,
  log in the session scratchpad. If it died: run the same command again; it skips finished guides
  (`--dry-run` shows what is left). Do not change `Routing/CostModel.lua`, `Routing/TravelGraph.lua`,
  `Routing/StepOrder.lua` or the guide data while it runs.
* After the rebake: `luajit -joff tools/test_route_order.lua` must pass, then `tools/install.sh` per client that is
  not running, copy code + data to Drive (no `--delete`), rewrite the work email out of history (plan in the 07:45
  update), push, PR, local merge.
* Usage: a 5-hour window lasted about 40 minutes with four agents at the highest effort. Run at most one agent
  beside the main session, or none.

**Update 2026-11-11, 19:00. Published; rebake paused; four clients on the new build.**
* **Published.** PR #4 (`integration`) is merged into `master` on GitHub, merged locally with the noreply identity.
  Before the push the owner's work email was rewritten out of every commit's author and committer field
  (`git filter-repo --mailmap` in a scratch clone; every tree unchanged; a fresh clone shows only the noreply
  address). `refs/pull/1-3/head` on GitHub still hold the old commits; only GitHub Support can remove them. The
  owner's global `git config user.email` is still the work address: any new repo needs a repo-local `user.email`.
  `repo/` is on the rewritten history; only `master` exists besides the branch in use.
* **Rebake paused at 895 of 2,618 guides.** tbc (352) and forever (243) are done; era has 200 of 236 rows; mop (769)
  and retail (1,018) have none, so those two play in author order with the live window. It stopped twice on its
  free-disk guard: the internal disk fell to 8 GB (the owner's floor) while other jobs ran on the Mac and swap grew
  to 4 GB with a game client open. This project uses under 2 GB. **Resume** when the disk has room and no client is
  being played: `caffeinate -is nice -n 10 venv/bin/python tools/bake_resume.py --min-free-gb 9` from `repo/` (about
  4 hours; resumable). Then `luajit -joff tools/test_route_order.lua` must pass, then re-run `tools/install.sh`.
* **Installed** (19:00) on `_classic_era_`, `_anniversary_`, `_classic_`, `_retail_`: today's code and data, with the
  partial bake. **Not on `_forever_`** (it was running; it still has the 11-10 beta). The 11-10 addon folders and the
  CompletionRoute SavedVariables of those four clients are in
  `/Volumes/x10/Video Games/Mac/CompletionRoute-archive/2026-11-10-beta/` (restore by copying back).
* **Drive working tree not synced** (it is the 11-10 beta, code and data): the regenerated data is about 150 MB and
  the internal disk is at the floor. The companion app installs from Drive, so until Drive is synced its button
  installs the OLD build; sync code and data together (`rsync -a` without `--delete`, from `repo/`), then archive the
  superseded `Guides/Imported_Storylines_retail.lua` there too.
* The `_wip-backup` bundle in Drive was removed (GitHub has the work).

| Job | What it does | How to check | If it died |
|---|---|---|---|
| Route bake (started 15:46, about 3.5 h) | Bakes the 478 MoP and 725 retail quest guides that had no baked order, plus 10 TBC and 8 Forever guides with a stale checksum, at full solver quality. It runs from a session-scratch copy of `tools/bake_resume.py`. | `python3 tools/bake_resume.py --dry-run` from repo/: "to do 0" on mop and retail means done. | Re-run `python3 tools/bake_resume.py` from repo/. It skips finished guides. |
| Forced map-fix re-bake (queued after the bake) | 235 era, tbc and forever guides whose wiki points moved in the 2026-11-09 Classic map fix. The checksum cannot see moved coordinates. | No easy check, because the rows look current either way. | `python3 tools/bake_resume.py --flavors era,tbc,forever --force-mapfix` (about 40 min). |
| After both bakes | Install the new `RouteOrder_*` into every client that is **not running** (`tools/install.sh _retail_` and so on), copy `CompletionRoute/Data/RouteOrder_*.lua` to the Drive copy, and update the baked counts in docs/STATUS.md (`tools/status_report.py`). | `ls -la` on the RouteOrder files in a client folder | Do those steps. |
| Quest skip, branch `quest-skip` (wt-skip) | Spec: STATUS/ROUTING entries on that branch and section 1 above. Quest-level skip (`/cr skip`, `/cr unskip`, `/cr skipped`, step panel), a reverse prerequisite index generated offline (`Data/QuestDeps_<flavor>.lua`), a confirmation popup listing blocked quests, a chain drop that rebuilds the guide (projection; ticks still keyed by author index), and a time-sliced in-game re-plan (≤ 2 ms per frame) for least travel. New harness `tools/test_skip.lua`. Built by one agent, checked by two independent verifiers, then fixed. | `git -C wt-skip log --oneline route-bake-finish..` and run every harness in wt-skip | Review what is committed against the spec, then finish, verify and fix it. Uncommitted work in a dead worktree is unverified: review it before keeping it. |
| Phase 1, branch `routing-graph` (wt-graph) | #2: route only through discovered flight paths (shared only on retail and forever; `vplayer --taxi learn\|all`). #4: rebuild the travel graph only when an access chain unlocks, a flight path is learned, the hearth is re-bound or a teleport changes. #5: `Data/Teleports.lua` (class teleports, alternative hearthstones and toys, engineering devices) as router edges, with every id checked in DB2. | Same as above | Same as above |
| Phase 1, branch `beta-bug-report` (wt-bug) | #3: `/cr bug [note]` and a Report button save a snapshot (no character name or realm) to SavedVariables. `tools/ingest_beta_reports.py` loads them into the `beta_reports` table, and `tools/vplayer.lua --repro <id>` replays one. Docs: `docs/BETA_REPORTS.md`. | Same as above | Same as above |
| Phase 1, branch `release-packager` (wt-pkg) | #8: `tools/package_release.py` builds `dist/` with a provenance manifest and refuses to build on unknown provenance, WoW-Pro or Questie data, the banned product name, personal data, secrets, symlinks, or a TOC listing a file that isn't shipped. Adds LICENSE, ATTRIBUTION and a player README. Dry-run only; it never makes a release. Docs: `docs/RELEASE.md`. | Same as above | Same as above |

## 5. What comes next

### Phase 2: start after quest-skip is merged into the integration branch
These touch the same files as quest skip (`Core/Progress.lua`, `Core/Guide.lua`, `Routing/StepOrder.lua`), so they wait for it.

| Idea | Build | Notes |
|---|---|---|
| #6 Stable step identity | Store done, skipped and locked marks by a stable step key (for example a hash of action + quest id + objective index + zone + rounded point) instead of the author step index, with a one-time migration of existing SavedVariables. | This is what lets guide data be regenerated without moving players' ticks. Quest skip already keeps its own marks by author index plus quest id; move them to the stable key. |
| #7 Auto accept and turn-in | Only for quests in the active guide, never for skipped or locked quests, never when a turn-in offers a reward choice (unless `UI/ItemScore.lua` gives a clear winner and the option allows it). Hold a modifier to bypass. Use the existing `autoAccept` and `autoTurnin` options. Cover the Classic gossip/quest-frame APIs and Retail C_GossipInfo. | |
| #9, then #1: one cost model, then the bake gate | **Built on branch `cost-model` (worktree `wt-cost`), 2026-11-10, review fixes 2026-11-11, offline only, not merged.** #9: `Routing/CostModel.lua` (all six TOCs, version 2) owns the located rule (NPC point, else ride along in the same zone, else the new zone's centre; chosen by `tools/cost_holdout.lua`), one no-route cost (1,800 s), speed per level band at each step's planning level, the walking factor, the offline flight rule (faction-wide, measured against a level-band rule), the gate limits and the planning character (`CostModel.Persona`: per guide the faction, class, race and profession at least half of its located steps are written for; before the fix 89 guides, 75 with a bake today, had nothing to bake, now 12, all split between classes). cost_matrix, optimize_routes (reads the row's `"cm"`), StepOrder, Replan, Router.StepWorld and vplayer use it; the client files hold no fallback copies. `tools/test_cost_parity.lua`: optimizer and vplayer (`--who plan --live off`) agree within 2% per guide (harness 30/30; 20 per client with the full solver 100/100; 50 changed guides 50/50). #1: checksum version 2 (zone + first point) in Core/Guide.lua, cost_matrix and optimize_routes, equal on all 2,621 quest guides; `optimize_routes.py --gate` plays the planning character (`vplayer --who gate`), both factions for a guide for both (entries carry `va`/`vb`, plus `vah`/`vbh`), and saves the solves before the gate so a killed or failed gate never re-solves (`tools/test_bake_gate.py`, new); `bake_resume.py` gates each batch, resumes ungated rows, writes only current entries; `test_route_order.lua` fails on stale entries. Saved quest-skip re-plans reset once after the update (documented). Numbers: docs/ROUTING.md "One cost model" and "Bake gate". | **The orchestrator must run next, in repo/ after merging:** `cd ~/Downloads/CompletionistGuide-work/repo`, then `~/Downloads/CompletionistGuide-work/heavy.sh python3 tools/bake_resume.py --dry-run` (every quest guide shows as to do, about 2,620: every row is stale under checksum v2 and cost model v2), then `~/Downloads/CompletionistGuide-work/heavy.sh python3 tools/bake_resume.py` (all five flavors, gate on; the solve is about 6-8 h as before; the gate adds two vplayer runs per batch of 20, four when the batch holds guides for both factions, 16-32 s per batch on the samples, so roughly +1 to +2.5 h over about 131 batches, more on the largest zone guides; an estimate, not measured on the full set). Safe to kill and re-run at any point. Then `luajit tools/test_route_order.lua` must pass, then `luajit tools/test_cost_parity.lua` and `venv/bin/python -m unittest tools/test_bake_gate.py`, the sample vplayer runs and `python3 tools/collect_routes.py collect`, then install. Until the rebake, every guide plays in author order with the live window (checked). |

### Phase 3: integration and publish
1. Create the integration branch from `route-bake-finish`. Merge in this order: `quest-skip`, `routing-graph`,
   `beta-bug-report`, `release-packager`, then the phase-2 branches. Expect conflicts in: the top of docs/STATUS.md, the
   README feature and command tables, the docs/IDEAS.md rows, `Core/Guide.lua`, `Core/Progress.lua`, the slash-command
   handler, the TOCs, `tools/install.sh`, `tools/vplayer.lua` and the `Routing/*` files. After each merge, run every
   harness (`for t in tools/test_*.lua; do luajit $t; done; luajit tools/validate_toc.lua`).
2. Run the full rebake, then sample vplayer runs (author + live against baked + live, about 20 guides per flavor). Put the
   numbers in docs/STATUS.md and `docs/verification.sqlite`.
3. Install into the clients that are not running, sync the Drive copy (no `--delete`), and rebuild the app only if `app/`
   changed. Archive the previous app build into an archive folder if you rebuild.
4. Open the PR, merge it locally with the noreply identity, push, close the PR, delete the merged branches and remove the
   worktrees (`git worktree remove`). Make no release until Daniel's beta passes; `tools/package_release.py` then builds it.
5. Update the project memory and this file.

### Phase 4: open quest database repo (owner-approved 2026-11-10)
A separate public repo (working name `wow-completionist-data`), built locally at `~/Downloads/CompletionistGuide-work/wow-completionist-data`
and pushed only after it has been verified.
* **Contents.** Per-flavor quests (id, name, faction, level and required level, start and end NPC or object with coordinates,
  prerequisites and breadcrumbs, zone, type, class and race limits, which flavors have the quest), NPCs with coordinates,
  achievements with locations, and missions. Formats: SQLite plus JSON/CSV. Every record keeps its source (wiki page
  title + revision, or the DB2 table and build) for CC BY-SA attribution.
* **Licences.** Data is CC BY-SA 4.0 with attribution to warcraft.wiki.gg. Any code in that repo stays PolyForm NC + rider.
  The README points to batesai.org and help@batesai.org.
* **Why.** It keeps the share-alike data apart from the PolyForm code, gives players one place to send corrections as pull
  requests ("community driven"), and becomes the single input of the addon's generators (`tools/wiki/gen_*.py`).
  The release packager (#8) can then pull a pinned data version.
* **Gate.** Before any push, run the same banned-name, personal-data and secret scans as `tools/package_release.py`.

### Phase 5: coverage push (the "every quest, mission, story, item quest, achievement" goal)
Current numbers are in docs/STATUS.md. Known gaps:
* **Achievements:** located shares are below the 80% target (mop about 68%, retail about 43%). *Workstream A below.*
* **Retail Cooking tiers:** Pandaria stops at 22 of 75; Outland and Shadowlands have no guide.
* **No-route rows:** mop has 27 and retail 62 routable steps with no route.
* **Blasted Lands:** a 5.5-unit point offset with no known cause.
* **Item-started quests:** coverage has never been measured. *Workstream A below.*
Measure each gap with `tools/coverage.py` and `tools/status_report.py`, close it from the wiki and DB2, and record the
results in `docs/verification.sqlite`.

**Workstream A done offline on branch `coverage-ach` (2026-11-11, worktree wt-cov1; reviewed and fixed the same day;
not merged, nothing run in a client).** Achievements, item-started quests and storylines; numbers in STATUS 2026-11-11.
Release build (no fallback): achievements located retail 42.0% → 82.6%, mop 68.8% → 84.8% (retail is 76.3% without
the achievement wiki-page source, so its 80% rests on that source); item-started quests with a located accept (point +
zone) era 21 → 60, tbc 37 → 143, mop 54 → 190, retail 195 → 628, forever 22 → 61; storylines ship for the first time
(`Imported_QuestLines_retail.lua`, 1,492 of 1,653 lines with a point on every quest). The review fixes (topic and zone
pages, achievement zone and expansion scope, glyph lists, Dalaran / Midnight maps, a source on every step, the build
header) are listed in STATUS. What changed: `coverage.py` (`--shippable`, item quests from Blizzard ItemSparse,
`coverage_ach_types`, `item_quests`, internal achievements apart), `status_report.py` (the located share, item quests,
`--label`), `parse_wiki.py` (item sources and coords, `achievement_links`, `race_courses`, `glyph_points`),
`fetch_titles.py --db2-names`, `gen_wiki_guides.py` (item-started accepts, `|U|<item>|`, no points from zone or topic
pages, the fallback-build guard), `gen_completion_guides.py` (achievement places, quest lines, `--selfcheck`),
`wikimaps.py` (coverage-prof's version, see below), the retail TOC, `install.sh`, `package_release.py` +
`test_package.py`, the new `tools/test_completion.lua`, and the tools that load the storyline file.

Merging: `git merge-tree` of `coverage-ach` into today's integration (2a40df8, cost-model merged) is clean.
`tools/wiki/wikimaps.py` is coverage-prof's file taken verbatim (its Dalaran fix), so that file merges cleanly with
coverage-prof too. A trial merge with coverage-prof (957bb1f) conflicts in `tools/wiki/gen_wiki_guides.py`,
`tools/wiki/fetch_titles.py` and the docs (STATUS, HANDOFF, `tools/wiki/README.md`): coverage-prof adds QuestPOI pins,
place pages and zone-level steps in the same functions (`entity_coords`, `loc_tag`, the C-step block); keep both
sides' rules, then rerun `test_wiki.lua` and `test_completion.lua`. After the merge, `tools/test_route_order.lua` stays red until the full
rebake (`tools/bake_resume.py`): 7 checks fail on integration alone (stale rows under checksum v2) and 2 more with this
branch's data: RouteOrder rows naming a guide the regenerated wiki guides no longer have, in this build mop 5
(`wiki:mop:109:Both:4`, `wiki:mop:407:Both:1`..`:4`) and retail 34 (`wiki:retail:110:Both:4`, `114:Alliance:3`,
`1355:Both:1`..`:5`, `2214:Both:10`, `2437:Both:5`..`:11`, `42:Both:1`..`:3`, `534:Both:1`..`:2`, `543:Both:1`..`:2`,
`626:Both`, `680:Both:9`..`:12`, `695:Horde`, `76:Both:1`..`:2`, `84:Both:1`..`:2`, `862:Alliance:1`..`:2`). The exact
ids depend on the regeneration (the spine split is not byte-stable).

To regenerate in the main checkout after merging, in this order, each under `heavy.sh` (times measured in wt-cov1):
1. `python3 tools/wiki/db2_fetch.py WorldMapOverlay UiMapXMapArt UiMapArt UiMapArtStyleLayer DungeonEncounter AreaTable -- retail mop`
   (12 small requests, under a minute; `gen_completion_guides.py` would fetch them itself).
2. `python3 tools/wiki/fetch_titles.py --db2-names --min-interval 1.5`, then `python3 tools/wiki/parse_wiki.py`, then
   the same pair once more (round 1: 301 requests, about 14 min, 6,377 pages; round 2: 8 requests, 292 pages;
   resumable; each `parse_wiki.py` about 1.5 min). Faster: copy `tools/wiki/cache/wiki_raw.sqlite` (370 MB) from wt-cov1,
   which already holds these pages, then run `parse_wiki.py` once. `parse_wiki.py` rebuilds `wiki.sqlite` (now with
   `glyph_points`) and drops the tables `gen_wiki_guides.py` writes there, so step 3 must follow.
   Check: `python3 tools/wiki/fetch_titles.py --db2-names --dry-run` should report a few hundred titles at most.
3. `python3 tools/wiki/gen_wiki_guides.py` (all five flavors, about 2 min). For a release build use `--no-fallback`
   and run steps 4-5 after it: the achievement and quest-line files made from the default build say so in their
   header and the packager refuses them.
4. `python3 tools/gen_completion_guides.py retail mop` (about 10 s once it has the lock): achievements, the new
   `Imported_QuestLines_retail.lua`, missions. The old `Imported_Storylines_retail.lua` is no longer written or loaded;
   archive it rather than delete it. Then `luajit -joff tools/test_completion.lua`.
5. `python3 tools/gen_quest_deps.py` as usual (`--wiki-only` for a release; about 10 s); it now reads the quest-line file.
6. `python3 tools/coverage.py --label <name>` and `--shippable --label <name>-ship` (the latter on a `--no-fallback`
   build), then `python3 tools/status_report.py --label <name>` (under a minute each).
7. Rebake: the regenerated wiki guides change some splits, so their baked orders go stale (and `test_route_order.lua`
   reports the orphan rows above); the full rebake planned after phase 5 covers it.
Then `tools/install.sh` per client that is not running (retail now installs `Imported_QuestLines_retail.lua` and drops
the old storylines file from the client folder).

**Workstream B, branch `coverage-prof` (worktree `wt-cov2`), 2026-11-11.** Offline only, not merged, not installed;
numbers in docs/STATUS.md "2026-11-11: Coverage workstream B".
* Done: retail Cooking tiers (Outland, Shadowlands get guides; Pandaria, Cataclysm, Northrend reach 75; trainers for
  Kul Tiran, Dragon Isles, Khaz Algar, Midnight Cooking and Khaz Algar, Midnight Fishing); routable no_route on the
  re-run guides mop 14 -> 6, retail 57 -> 47 (MoP Pandaria and Isle of Thunder chains, the Maelstrom, the Tazavesh
  portal); the Blasted Lands offset (Classic-map numbers found through page history; median 5.54 -> 0.27 units) and
  Dalaran resolving to a Deadwind Pass micro map; release-build points (retail quest pins, wiki place pages,
  zone-level steps: era 40.2% -> 50.1% of steps with a point, retail 40.1% -> 70.9%).
* Changed code: `tools/wiki/wikimaps.py`, new `tools/wiki/fetch_coord_history.py`, `tools/wiki/fetch_titles.py`,
  `tools/wiki/gen_wiki_guides.py`, `tools/wiki/gen_professions.py`, new `tools/prof_tiers.py`, `Data/Access.lua`,
  `Data/Transit.lua`; tests `test_access.lua`, `test_professions.lua`, `test_wiki.lua`.
* **Re-run in the main checkout, in this order** (one heavy job at a time; times measured in `wt-cov2` on the shared
  8 GB Mac with a warm cache unless noted):
  1. `python3 tools/wiki/fetch_titles.py`: 54 requests, about 1 min. Fetches the place pages named by NPC pages that
     have no point (2,627 pages).
  2. `python3 tools/wiki/parse_wiki.py`: about 2 min. Rebuilds `wiki.sqlite` with the place pages.
  3. `python3 tools/wiki/fetch_coord_history.py`: 87 history requests the first time (about 2 min), seconds after.
     Writes `tools/wiki/cache/coord_history.sqlite`, which `parse_wiki.py` does not delete. Blasted Lands only by
     default; `--changed-zones` would check every zone the Cataclysm redrew (not run; expect thousands of requests).
  4. `python3 tools/wiki/gen_wiki_guides.py` (dev build, about 1.5 min) or `--no-fallback` (release build, about 70 s).
     Both also rebuild the spine. Every wiki guide's points can move (Dalaran, Blasted Lands, quest pins, place pages,
     zone-level steps).
  5. `python3 tools/wiki/gen_professions.py`: about 10 s; the first run fetches the trainer categories and pages
     (about 10 requests).
  6. `python3 tools/gen_completion_guides.py retail mop`: about 10 s (achievement points come from step 4's files).
  7. `python3 tools/gen_quest_deps.py` (or `--wiki-only` for a release): about 6 s.
  8. Optional: `python3 tools/wiki/gen_gold.py` (the Dalaran fix moves gold points there; not run or timed here).
  9. The baked route orders are stale wherever points moved; the checksum does not see it. This lines up with the
     full rebake that `cost-model` (#1, new checksum) needs anyway.
* Not done: anything in a client; Tol Barad on MoP Classic, Midnight, Argus and Forbidden Reach no_route rows (no
  cited exit); the pre-4.0.3 history outside Blasted Lands; Classic points for NPCs that moved at the Cataclysm;
  Legion and Draenor Cooking trainers; Shadowlands Cooking 75-175; the route-order rebake that the packager still
  fails on (5 problems, all `RouteOrder` rows for `_gaps` guides).

## 6. Other pathways considered

* **Bake strategy.** Incremental (`bake_resume.py`, recompute only missing or stale guides) is the default. A full rebake is
  needed after any cost-model, graph or checksum change. A faster alternative is lower solver limits (`--limit-s 4
  --dp-time 1`, used at the 2026-11-09 deadline), which cost route quality; `tools/optimize_routes.py` documents the limits.
* **Stale detection.** Option A (built on branch `cost-model`, checksum version 2) puts coordinates into the checksum. Option B stores a per-guide content hash
  in the result rows and compares it. B avoids invalidating the client-side check but needs the same hash in cost_matrix.
* **Re-planning after a skip.** In-game local search from the baked order minus the removed steps (being built). The
  alternative is shipping per-chain alternative bakes. That isn't feasible because the number of combinations explodes.
* **Flight paths in the bake.** Either assume every faction node (optimistic; the live router corrects it in game) or use a
  per-level-band discovery model. Decided on branch `cost-model`: faction-wide stays (measured with `vplayer --taxi learn`
  on 100 sample guides: both bakes beat author order, faction-wide by 0.4% more); `--taxi band` remains for experiments.

## 7. Gotchas

* Homebrew git's HTTPS hangs, so use `/usr/bin/git` for push and fetch. `grep` in this shell is ugrep, so use
  `/usr/bin/grep` for complex patterns. zsh aborts on unmatched globs, so use `bash -O nullglob -c` for `rm` with globs.
* `kern.memorystatus_vm_pressure_level` stays at 2 ("warn") with a game open, so gate on level 4 or under 10% free instead.
* **Worktrees and symlinks.** A pattern ending in `/` ignores a directory but not a symlink of the same name. On
  2026-11-11 a worktree's link `tools/teleports_db2` (to the data in `repo/`) was committed by `git add -A` and reached
  `master` in PR #6; its target was an absolute path in the home folder, and checking it out in `repo/` replaced the
  ignored cache directory there (regenerate with `tools/check_teleports.py --fetch --wiki`). The link was removed the
  same evening and the three directory patterns now have no trailing slash. After linking data into a worktree, run
  `git status --short` and make sure no link shows as untracked before any `git add`.
* Generated data is gitignored. It lives in repo/, the Drive copy and the game folders. If it is lost, regenerate it with
  `tools/wiki/gen_*.py`, `tools/gen_completion_guides.py` and `tools/gen_quest_deps.py` (order: `docs/RELEASE.md`
  "Making a build"), or copy it back from a client's `Interface/AddOns/CompletionRoute`.
* `tools/install.sh` installs only the installing client's flavor data and stops on any generated file that is not
  part of the build (a `_gaps` or `Imported_Quests_*` file, `Data/Imported_*`, a file that credits another addon's data).
  The Drive copy made before 2026-11-11 night still holds such files until it is cleaned.

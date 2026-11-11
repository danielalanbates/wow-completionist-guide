# Handoff for the next AI (written 2026-11-10, 16:30 Pacific)

Read this first, then `docs/STATUS.md` (newest section on top), `docs/IDEAS.md` and `docs/FINISH_PLAN.md`.
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
| Data sources | Quest and NPC data come from the Warcraft Wiki (warcraft.wiki.gg, CC BY-SA 4.0) and Blizzard client data (wago.tools DB2), plus the project's own data. WoW-Pro and Questie are used only at runtime or install time and never ship. Wiki-derived data ships under CC BY-SA. Code is PolyForm Noncommercial with the 10% commercial rider, all rights reserved (batesai.org, help@batesai.org). |
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
| Main work clone (branch `route-bake-finish`) | `~/Downloads/CompletionistGuide-work/repo`. It holds the gitignored generated data (`CompletionRoute/Guides/Imported_*`, `CompletionRoute/Data/RouteOrder_*`, `tools/db2`, `tools/wiki/cache`, `docs/verification.sqlite`). |
| Feature worktrees | `~/Downloads/CompletionistGuide-work/wt-skip` (`quest-skip`), `wt-graph` (`routing-graph`), `wt-bug` (`beta-bug-report`), `wt-pkg` (`release-packager`). Their generated-data paths are **symlinks into repo/**, so never write through them. `git worktree list` shows them. |
| Python venv (OR-Tools) | `~/Downloads/CompletionistGuide-work/venv` |
| Optimizer job directory | `~/.claude/jobs/ff3c728a/tmp` (hardcoded as `TMP` in `tools/optimize_routes.py` and `tools/cost_matrix.lua`; `CR_TMP` overrides it in `tools/bake_resume.py`). Result rows: `routeopt/<flavor>.jsonl`. |
| Canonical copy | Google Drive → My Drive/Code/Completionist's Guide (has the generated data too). Sync with plain `cp` or `rsync` **without `--delete`**: on 2026-11-07 `rsync --delete` wiped the gitignored generated files and they had to be restored from the game folders. |
| Game clients | `/Volumes/x10/Video Games/Mac/World of Warcraft/{_classic_era_,_anniversary_,_classic_,_retail_,_forever_}`. `tools/install.sh <dir>` ships each client only its own flavor's data. |

## 3. Done on 2026-11-10

* PR #3 (gold guides, secondary professions, guides listed by level) merged.
* The owner's personal email was purged from all git history (file contents and commit metadata) and force-pushed. The merged
  branch was deleted. GitHub still keeps `refs/pull/1-3/head` with the old history, which only GitHub Support can remove.
* `tools/cost_matrix.lua --list` prints each quest guide's id, step count and checksum without computing matrices.
* `docs/IDEAS.md` was added: 60 ranked ideas. Daniel approved #1–#9.
* `tools/bake_resume.py`: the resumable bake driver described in section 4.

## 4. In flight when this was written

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
| #9, then #1: one cost model, then the bake gate | #9: `Routing/CostModel.lua` used by cost_matrix, StepOrder and vplayer. It sets one rule for when a zone-only step counts as located, one no-route cost (currently 1,800 s, 600 s and 0 in the three places) and a speed per level band. `tools/test_cost_parity.lua` must show agreement within 2%. #1: `optimize_routes.py --gate` keeps a baked order only if vplayer finds it not slower than author order + live by more than max(1%, 30 s). The checksum gains zone and first point **in all three copies** (Core/Guide.lua, cost_matrix.lua, optimize_routes.py), and `tools/test_route_order.lua` fails on any stale entry. | The new checksum invalidates every existing baked order. That is intended: after #2, #5 and #9 change the costs, a **full rebake** of all five flavors is needed anyway. Use `tools/bake_resume.py`; expect about 6–8 hours for about 2,620 guides. Decide which flight-path knowledge the bake assumes (all faction nodes, or the nodes a character at that level band would have) and document it. |

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
* **Achievements:** located shares are below the 80% target (mop about 68%, retail about 43%).
* **Retail Cooking tiers:** Pandaria stops at 22 of 75; Outland and Shadowlands have no guide.
* **No-route rows:** mop has 27 and retail 62 routable steps with no route.
* **Blasted Lands:** a 5.5-unit point offset with no known cause.
* **Item-started quests:** coverage has never been measured.
Measure each gap with `tools/coverage.py` and `tools/status_report.py`, close it from the wiki and DB2, and record the
results in `docs/verification.sqlite`.

## 6. Other pathways considered

* **Bake strategy.** Incremental (`bake_resume.py`, recompute only missing or stale guides) is the default. A full rebake is
  needed after any cost-model, graph or checksum change. A faster alternative is lower solver limits (`--limit-s 4
  --dp-time 1`, used at the 2026-11-09 deadline), which cost route quality; `tools/optimize_routes.py` documents the limits.
* **Stale detection.** Option A (planned, #1) puts coordinates into the checksum. Option B stores a per-guide content hash
  in the result rows and compares it. B avoids invalidating the client-side check but needs the same hash in cost_matrix.
* **Re-planning after a skip.** In-game local search from the baked order minus the removed steps (being built). The
  alternative is shipping per-chain alternative bakes. That isn't feasible because the number of combinations explodes.
* **Flight paths in the bake.** Either assume every faction node (optimistic; the live router corrects it in game) or use a
  per-level-band discovery model. Decide in #9 and measure both with `vplayer --taxi learn`.

## 7. Gotchas

* Homebrew git's HTTPS hangs, so use `/usr/bin/git` for push and fetch. `grep` in this shell is ugrep, so use
  `/usr/bin/grep` for complex patterns. zsh aborts on unmatched globs, so use `bash -O nullglob -c` for `rm` with globs.
* `kern.memorystatus_vm_pressure_level` stays at 2 ("warn") with a game open, so gate on level 4 or under 10% free instead.
* Generated data is gitignored. It lives in repo/, the Drive copy and the game folders. If it is lost, regenerate it with
  `tools/wiki/gen_*.py`, or copy it back from a client's `Interface/AddOns/CompletionRoute`.
* `tools/install.sh` ships only the installing client's flavor data and refuses files from the banned product.

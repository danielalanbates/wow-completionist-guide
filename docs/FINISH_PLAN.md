# Completionist's Guide — Finish Plan

## REVISION 2026-11-07 (Daniel's decisions — supersede anything below)

| Topic | Decision | Effect on the plan |
|---|---|---|
| Commercial | **Nothing from Commercial, ever** — the project is fully independent | Commercial adapter, bakes, exporter, Commercial-keyed coord fixes and every Commercial-titled sweep/audit file **deleted and purged from all git history** (done 11-07). No Commercial baselines (old M2 dropped). The `commercial` comparison mode in route_compare is dropped; optimizer is measured against author/wiki order and its own lower bounds. |
| Source of truth | **Warcraft Wiki** (warcraft.wiki.gg) | New W4/W5: `tools/wiki/` fetches `{{Questbox}}` (40,357 pages: id, faction, level, start/end NPC, previous/next) and `{{Npcbox}}` (84,575 pages, `{{Coords}}`) via the MediaWiki API (polite, cached, gitignored). Wiki wins on conflicts; Blizzard client data (wago DB2) only fills what the wiki lacks (objective areas, flavor membership). Disagreements logged in SQL. |
| Licence | Wiki = CC BY-SA 4.0 | Wiki-derived data files ship under **CC BY-SA 4.0 with attribution** (share-alike); code stays PolyForm NC + rider. ATT/WoW-Pro/Questie are no longer needed as primary sources. |
| In-game verification | **Daniel beta-tests himself** — no AI Battle.net login or GUI takeover | W11 in-game passes dropped. Verification = offline vplayer/route_sweep + Daniel's beta reports. Game-time deadline no longer on the critical path. |
| Repo | Public; Commercial files erased | Done. Repo is `danielalanbates/wow-completionist-guide` (renamed from openroute). Old PR refs `refs/pull/1,2/head` still hold pre-purge commits — only GitHub Support can purge them. v1.0.0 release + tag deleted (shipped the Commercial adapter); next public release = v2.0 (wiki-based). |
| Commercial sub end | Early Dec 2026 | Irrelevant now (nothing depends on it). |
| Classic guides | .app generating them at install time is OK | Kept as fallback where the wiki has gaps. |
| WoW-Pro waiver / outreach | No | Runtime adapter only; nothing WoW-Pro-derived ships. |

---



## 0. What the research left unverified or missing

| Gap in inputs | Why it matters | How to close |
|---|---|---|
| **Exact Commercial sub end date.** It is still live (SavedVariables written 11-06), but the end date is unknown. | Sets the deadline for the final private export and the baseline numbers. | Daniel states the date, or I read it from Commercial.app account info. |
| **Exact game-time end.** "~late Dec" is an estimate from 08-24. | Era/TBC/MoP/Forever in-game passes must finish before it. | Read it from the Battle.net account page with Daniel's OK. |
| **Coverage without Commercial has never been measured.** Every headline number includes Commercial. | The real state of "Commercial-free" is unknown, and could be far below 35k/16k/5.7k/3.8k. | Re-run coverage, route_sweep and vplayer with `Imported_Legacy_*`/`Imported_Commercial_*` excluded (M1). |
| **"Verify every guide in-game" is undefined.** 15,865 guides cannot be played by hand. | Without a definition the goal is never "done". | Use 3 tiers: (a) every guide loads and routes in-client (ingame_sweeps), (b) 27 feature checks, (c) 3–5 guides per flavor actually walked, with time compared to the model. |
| **Whether the commercial guide's installed guides still load after the sub lapses.** | Decides whether Adapters/Commercial.lua is still useful even for Daniel. | Check once after the lapse (retail Starter Edition). |
| **Quest-log cap per flavor** (25/35 assumed). | It is a hard constraint for the optimizer. | Read it with `C_QuestLog.GetMaxNumQuestsCanAccept()` during the in-game pass. |
| **Forever support.** Daniel actively plays it (Forever was running again at 07:xx today; pids changed since the audit). No CompletionRoute TOC exists for it. | "One addon, all versions" currently fails here. | Add a Forever TOC plus Era data. QuestieDB has a Forever folder, wago has the `wowf` product, and ATT has Forever source. |
| **ATT parse feasibility and coverage are unmeasured.** `.contrib` uses preprocessor `#if` blocks and custom constructors. | ATT is the main shippable fact source. If the parse fails, the retail plan falls back to DB2 only. | Spike: parse one expansion and report quest, prereq and coord counts against QuestV2. |
| **Questie "PRs after 2026-10-21 = GPLv3 consent"** is an odd claim. | It does not change the outcome (still not shippable under PolyForm), but it is not verified. | Treat Questie as all rights reserved. Runtime or install-time use only. |
| **Real walk time vs modelled travel seconds.** terrainFactor 1.25 has never been calibrated. | "Optimal" is only as good as the cost model. | Log real time during the in-game pass, target ±15%. |
| **Retail after game time is limited to Starter Edition (level 20).** | Midnight, TWW and Legion content can only be checked offline afterwards. | Accept this, or Daniel renews game time (decision). |
| **Achievement criteria and mission locating have no chosen data path.** | 9,937 retail and 2,412 MoP achievements are unlocated, and 1,757 missions have 0 located. | ATT criteria coords plus DB2 Criteria/CriteriaTree joins. Missions are table-only (no location needed); mark them `|NOLOC` as legitimate. |

Spot-checks I ran myself: the repo is **PUBLIC**, PR #2 is **OPEN**, the feature_runs dates match the audit (tbc 08-22, mop 08-21, era 08-24, retail 10-02), and a WoW Forever process is running right now.

---

## 1. Where it stands

- **The project is 88.7% Commercial by guide** (14,080 of 15,865) and 65.1% by step (502,783 of 771,737). Dungeons, events, reputation, pets/mounts, titles, gold, hand-made achievements and MoP dailies are **100% Commercial**.
- **Leveling order is Commercial-majority on every flavor:**

  | Flavor | commercial guides | WoW-Pro guides |
  |---|---:|---:|
  | Era | 580 | 47 |
  | TBC | 129 | 49 |
  | MoP | 171 | 112 |
  | Retail | 712 | 232 |

  WoW-Pro (CC BY-NC-ND) cannot ship as derivatives. The only order fully ours is the DB2 Storylines (1,648).
- **The public v1.0.0 release ships 2 starter-zone guides and nothing else.** Every Imported_* file is gitignored. It also still ships Adapters/Commercial.lua.
- **The repo is PUBLIC** (not private as believed) and contains Commercial-derived artifacts: route_sweep/audit TSVs and CSVs with Commercial paths and titles, and QuestCoordFixes_retail.lua keyed partly on Commercial step coordinates.
- **Routing:** 0 stalls and 0 precedence violations. But only a 12-step window is reordered, using greedy plus 1-node Or-opt.
  - Window savings: Era 6.1%, TBC 9.0%, MoP 2.9%, Retail 1.5%, with 10 retail regressions.
  - Whole-guide savings have never been measured.
- **In-game checks:**

  | Flavor | Last check | Result |
  |---|---|---|
  | Retail | 10-02 | 27/27 |
  | Era | 08-24 | 27/27 |
  | TBC | 08-22 | 16/16, old check set |
  | MoP | 08-21 | 17 checks, old set |

  PR #2 code is installed nowhere, and Classic CompletionRoute has not been used in-game since 08-25.
- **Code is split across 3 Drive copies plus an iCloud stub.** The working copy is broken: its TOC loads LegacyGuides.lua, but the folder only has Commercial.lua. Classic TOCs still say Commercial.
- **Coverage, all including Commercial:**

  | Flavor | Quests covered |
  |---|---|
  | Retail | 35,493 / 66,420 (most of the rest are hidden trackers) |
  | MoP | 16,415 / 17,139 |
  | TBC | 5,748 / 6,160 |
  | Era | 3,852 / 4,807 |

  no_route steps: retail 1,254, MoP 515, TBC 39.

---

## 2. Deadline-driven critical path

| Deadline | Must be done before it | Why |
|---|---|---|
| **Commercial sub end (date unknown; assume before 2026-11-30)** | 1. Final **private** export of all flavors (Nov 6 content). 2. Freeze per-guide Commercial baselines in SQL: whole-guide seconds, seconds per quest, quest set per zone. 3. Agreement metric (Kendall tau) for the DB2 spine against Commercial order. 4. Then delete the Commercial bakes from every tree that could be shipped. | After the lapse there is nothing left to measure against. The baseline numbers are ours; the content never is. |
| **Game time end (est. ~2026-12-20; verify the date)** | 1. Merge PR #2, then one canonical tree, then install on all 5 clients (**adds Forever**). 2. In-game pass on Era, TBC, MoP and Forever: 27 feature checks, a full in-client load/route sweep, and 3–5 walked guides each. Run it **with Commercial bakes excluded**. 3. Calibrate the cost model from real elapsed time. 4. Read the quest-log cap per flavor. | After this, Era/TBC/MoP/Forever cannot be tested in-game at all. Retail drops to level 20. |
| **Any time (offline, no deadline)** | Optimizer, ATT/DB2 generators, coverage gaps, release. | wago.tools keeps publishing every flavor build, and vplayer is fully offline. |

**Order inside the window:**

| When | Work |
|---|---|
| Week of 11-09 | M0 + M1 (offline) |
| Week of 11-16 | M2 (Commercial baseline) |
| 11-23 → 12-14 | M4 in-game passes, scheduled when Daniel isn't playing |

The optimizer work (M5+) runs in parallel and does **not** block the in-game passes. The passes verify the engine, not the final orders.

---

## 3. Workstreams

| # | Workstream | Concrete deliverable | Data source / licence | Effort | Depends on | Verification (SQL) |
|---|---|---|---|---|---|---|
| W1 | **Repo consolidation** | Merge PR #2. One canonical tree in Google Drive `My Drive/Code/Completionist's Guide` (Drive supersedes CLAUDE.md §6 per 2026-09-25 directive); git work in a local clone under ~/Downloads. Archive `openroute-work`, `OpenRoute` and the Drive copy. Fix the TOCs. Make STATUS.md newest-first. | n/a | S | none | Clean `install.sh` dry-run; TOC file-existence check passes on 5 flavors |
| W2 | **Commercial independence: measure** | Coverage, sweep and vplayer rerun with the legacy bakes excluded. Frozen Commercial baselines. | Local Commercial install, private use only | S | W1 | New `coverage` rows with `scope='no_commercial'`; `route_compare mode='commercial'` |
| W3 | **Commercial independence: scrub** | Delete Commercial bakes from shippable trees. Rebuild QuestCoordFixes_retail without Commercial-keyed rows. Remove Commercial-titled TSVs/CSVs from git **history**. Audit Data/Access.lua and Farm_routes.lua comments. Adapters/Commercial.lua stays as optional runtime interop only. | n/a | S–M | W2 | grep for Commercial paths/titles in the tree and in git history = 0 hits |
| W4 | **Licence-clean data pipeline** | `gen_from_att.py` (ATT `.contrib`, all flavors incl. Forever). Pinned wago DB2 fetch per flavor and version. Fix `questie_env.lua` to point at **QuestieDB/data/<Exp>**. THIRD_PARTY_NOTICES (ATT MIT). Fix README "CC BY-SA" line. | ATT MIT (ship); DB2 derived facts (ship); QuestieDB (install-time in app/ or runtime `LibQuestieDB` only, never committed) | L | W1 | `data_provenance(file, source, licence, version)`; CI check that no Questie/WoW-Pro/Commercial-derived file is tracked |
| W5 | **Generated spine (replaces Commercial order)** | Retail: Campaign → CampaignXQuestLine → QuestLineXQuest order, plus ATT prerequisites, plus PRE tags in qpoi guides. Classic: ATT/Questie prerequisites plus level bands. Ordered category guides: dungeons (JournalInstance), reputation, events, professions. | DB2, ATT | L | W4 | `coverage scope='no_commercial'` ≥ the commercial guide's quest set per zone; Kendall tau vs Commercial baseline logged |
| W6 | **Routing tier A: offline optimizer** | `tools/cost_matrix.lua` (luajit, real TravelGraph). `tools/optimize_routes.py` (OR-Tools PDP with precedence, log capacity, level gates and GTSP alternatives; cross-checked with LKH-3). Output `Data/RouteOrder_<flavor>.lua` and `RoutePlan_<flavor>.lua` (zone chain and hearth binds). Only for redistributable guides. | Own engine | L | W5 | `route_compare` (author / window / baked / baked+live / commercial); `opt_gap` < 5% on instances under 40 nodes |
| W7 | **Routing tier B: live replanner** | Rewritten StepOrder: spine plus a 16–24-step horizon repair with seam cost, Savelsbergh O(1) feasibility checks, segment Or-opt and precedence-safe 2-opt, a 3 ms/frame coroutine, a hysteresis threshold of max(15 s, 5%), and live gates for level, log count and faction. Fix the cost inconsistencies (nearest alternative coordinate; median instead of 600 s). | Own | M–L | W6 | `route_compare`: 0 precedence/capacity/level violations; CPU p95 ≤ 3 ms; 0 guides >1% slower than author |
| W8 | **vplayer upgrade** | `--order` modes, quest-log cap, XP/level model, perturbation runs (random hub start, 20% pre-completed, skips). | Own | M | W1 | `route_compare`, `route_robust` tables |
| W9 | **Coverage gaps** | Achievement criteria located via ATT plus DB2 Criteria joins. no_route dungeons and scenarios via instance entrances and the JournalInstance graph. 133 retail item-quests. Retail hidden-tracker filter (ATT HiddenQuestTriggers) so the 66,420 denominator becomes real. Missions marked as non-geographic. | ATT, DB2 | M–L | W4 | `coverage` located/covered ratios; `noroute_steps` → 0 for routable steps |
| W10 | **Forever flavor** | `CompletionRoute_Forever.toc` (Interface 16001), flavor detection, Era/ATT-Forever/QuestieDB-Forever data. | ATT, QuestieDB runtime | S–M | W1, W4 | `feature_runs flavor='forever'` 27/27 |
| W11 | **In-game verification** | `run_flavor_verify.py` on Era/TBC/MoP/Forever/retail: 27 checks, a full in-client sweep, 3–5 walked guides with elapsed time, quest-log cap read. **Needs Daniel:** Battle.net logged in, permission to take focus, and a time slot when he isn't playing. | n/a | M (time-boxed) | W1, W2, W10 | `feature_runs`, `ingame_sweeps`, new `walk_calibration(flavor, guide, modelled_s, real_s)` |
| W12 | **SQL charting** | Single `docs/verification.sqlite` schema doc, one `status_report.py` that prints the headline table per flavor, and a frozen `baseline_commercial` table. | Own | S | W2, W8 | The report itself |
| W13 | **Release** | Release script bakes **only** shippable data (own guides, ATT/DB2-generated guides, RouteOrder). The companion .app generates the Questie-derived classic guides locally at install time. PolyForm NC + rider headers. Load-on-demand per flavor and expansion (Blizzard policy: no disk/FPS impact). Prior builds archived. .app = beta, GitHub release = stable. | as W4 | M | W3–W7 | Release zip audit: file list against `data_provenance`; fresh-install test on retail Starter Edition |
| W14 | **Docs for future AIs** | Newest-first STATUS.md, LICENSING.md (what ships where), ROUTING.md updated for tier A/B, and a reproduce-everything runbook. Memory entry updated. | n/a | S | ongoing | n/a |

---

## 4. Milestones

| M | Content | Exit criteria |
|---|---|---|
| **M0** | W1 consolidation + W3 public-repo scrub (or make the repo private) | One tree; PR #2 merged; TOCs load on all flavors in a luajit stub test; 0 Commercial artifacts in tracked files or history (or the repo is private) |
| **M1** | W2 measure without Commercial | `coverage scope='no_commercial'` rows for 4 flavors; gap table per category published in STATUS.md |
| **M2** | Commercial baseline freeze (**before the sub ends**) | `baseline_commercial` filled for every legacy guide (seconds, seconds per quest, quest set, zone); final private export taken, then bakes removed from all shippable trees |
| **M3** | W10 Forever TOC + W4 QuestieDB path fix | Forever loads in a stub test; classic generators run against a current QuestieDB checkout |
| **M4** | W11 in-game passes, Era/TBC/MoP/Forever (**before game time ends**) | 27/27 on each; in-client sweep with 0 stalls and 0 precedence violations; ≥3 walked guides per flavor within ±15% of the model; log cap recorded |
| **M5** | W4 ATT spike, then the full generator; W5 spine | ATT parse yields ≥90% of non-hidden QuestV2 with prerequisites and coords; generated leveling guides exist for every zone Commercial covered |
| **M6** | W8 vplayer upgrade + W6 offline optimizer | `route_compare` filled; Quests/qpoi guides at least 30% faster than author; 0 violations; gap < 5% |
| **M7** | W7 live replanner | CPU p95 ≤ 3 ms; robustness runs recover to within 10% of the re-solved optimum; 0 regressions over 1% |
| **M8** | W9 coverage gaps | no_route = 0 for routable steps; achievements located ≥80%; denominator excludes hidden trackers |
| **M9** | Commercial-free parity | Community guides ≤ Commercial seconds per quest in ≥90% of zone bands; quest coverage ≥ the commercial guide's per zone |
| **M10** | W13 release v2.0 + W14 docs | Release zip contains only provenance-approved files; fresh install shows real guides with no Commercial/WoW-Pro/Questie installed; .app beta updated and old builds archived |

---

## 5. Decisions Daniel must make

1. **In-game passes:** OK to log into Battle.net and take over screen focus for about 1–2 h per flavor? Which time slots? (I will never close a game he is playing.)
2. **Game time:** renew it, or accept that Era/TBC/MoP/Forever become offline-only after ~late Dec? If renewing, 1 month is enough for M4 slippage.
3. **Repo visibility:** make `openroute` private now, or keep it public and let me rewrite git history to purge the Commercial-derived files? A history rewrite cannot be undone.
4. **Commercial:** confirm the sub end date, and OK the final private export plus baseline before it lapses, then deletion of the bakes from shippable trees? Keep a private local copy for his own play?
5. **Classic guide distribution:** have the .app generate them at install time from QuestieDB (recommended), or rely on runtime `LibQuestieDB` only (requires users to install QuestieDB)?
6. **Optional outreach:** email WoW-Pro for an ND waiver, and/or ship a separately licensed CC BY-NC-SA RXP sub-addon? The default is no for both (runtime adapters only).

---

## 6. Risks and fallbacks

| Risk | Fallback / alternative pathway |
|---|---|
| ATT `.contrib` is too hard to parse or is missing retail prerequisites | Use DB2 QuestLineXQuest/Campaign order plus QuestPOIBlob only, and enrich from APR/RXP/WoW-Pro **at runtime** when the user has them installed |
| The generated order is clearly worse than the commercial guide's (M9 fails) | Runtime adapters (APR = GPL, every expansion; RXP free; WoW-Pro) feed the router in memory. Ship the generated spine as the default and label quality per zone in SQL |
| Game time lapses before M4 | Retail Starter Edition (level ≤20) plus offline vplayer. Mark Era/TBC/MoP/Forever as "offline-verified only" in SQL |
| Daniel is always playing Forever, so there is no slot for focus | Run the passes in a separate client only with his OK. Otherwise schedule an explicit window. Never kill his client |
| Blizzard objects to DB2-derived data | Same data practice as ATT, Questie, DBM and HandyNotes. Keep raw CSVs out of the repo and fetch names at runtime |
| OR-Tools is too slow on an 8 GB Mac (est. ~19 CPU-h) | Cluster split, a 30 s limit, `nice`, one process, run manually (no loops). LKH-3 as an alternative |
| Questie's licence changes again, or QuestieDB moves again | The .app generator pins a QuestieDB commit; runtime use reads only the documented `LibQuestieDB` contract v4 |
| the commercial guide's installed guides stop loading after the lapse | Daniel keeps the frozen private bake for his own use only; nothing ships from it |
| iCloud/Drive corrupts git | Do git work only in a local clone under ~/Downloads, copy results back to Drive, and heed the iCloud/Drive git hazard notes |
| Bundle size (Guides about 109 MB) | Load-on-demand addons per flavor and expansion; strip step text and fetch titles at runtime |

---

## 7. Sources

- https://github.com/ATTWoWAddon/AllTheThings/blob/master/LICENSE · https://github.com/ATTWoWAddon/AllTheThings/tree/master/.contrib/.db
- https://github.com/Questie/Questie/blob/master/LICENSE.md · https://github.com/Questie/QuestieDB · https://github.com/Questie/Questie/blob/master/docs/questiedb-integration.md
- https://github.com/Ludovicus-Maior/WoW-Pro-Guides/blob/main/License.md · https://creativecommons.org/licenses/by-nc-nd/3.0/
- https://github.com/RestedXP/RXPGuides/blob/master/LICENSE
- https://github.com/Azeroth-Pilot-Reloaded/azeroth-pilot-reloaded
- https://github.com/max-ri/Guidelime · https://github.com/zarillion/handynotes-plugins/blob/master/LICENSE · https://github.com/WowRarity/Rarity
- https://wago.tools/llms.txt · https://wago.tools/robots.txt · https://wago.tools/api/builds · https://wago.tools/db2/QuestLineXQuest/csv?product=wow · https://wago.tools/db2/CampaignXQuestLine/csv?product=wow
- https://example.com/p/commercial-guides-llc-terms-conditions/ · https://example.com/support/manual/sis
- https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534 · https://www.blizzard.com/en-us/legal/fba4d00f-c7e4-4883-b8b9-1b4500a402ea/blizzard-end-user-license-agreement · https://us.forums.blizzard.com/en/wow/t/datamining-story-spoilers-and-wow/1235149
- https://www.wowhead.com/tos
- https://developers.google.com/optimization/routing/pickup_delivery · https://github.com/c4v4/LKH3 · https://arxiv.org/pdf/2207.03876 · https://arxiv.org/abs/2107.05189
- https://polyformproject.org/licenses/noncommercial/1.0.0
- Local: `/Users/daniel/Library/CloudStorage/GoogleDrive-danielalanbates@gmail.com/My Drive/Code/Completionist's Guide/docs/verification.sqlite`, `/private/tmp/claude-501/-Users-daniel/d469ff92-af51-477c-842c-af3801218040/scratchpad/wowpro/WoW-Pro-Guides-main/License.md`
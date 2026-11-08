# Completionist's Guide — Finish Plan

Rewritten 2026-11-07 from Daniel's decisions. Status of each milestone is in [STATUS.md](STATUS.md).

## Decisions (Daniel, 2026-11-07)

| Topic | Decision | Effect |
|---|---|---|
| Sources | Community data only; no commercial guide content, ever | Third-party guide adapters, bakes and every file derived from them were removed and purged from all git history. `tools/install.sh` installs only allowlisted guides and adapters. |
| Source of truth | **Warcraft Wiki** (warcraft.wiki.gg) | `tools/wiki/` fetches `{{Questbox}}`, `{{Npcbox}}`, `{{Itembox}}`, object and achievement pages via the MediaWiki API (polite, cached, gitignored). Wiki wins on conflicts; Blizzard client data (wago DB2) decides flavor membership and fills coordinates the wiki lacks. Disagreements are logged in SQL. |
| Licence | Wiki = CC BY-SA 4.0 | Wiki-derived data files ship under CC BY-SA 4.0 with attribution; code stays PolyForm NC + rider. |
| Verification | Daniel beta-tests himself | No AI in-game passes, no Battle.net login, no GUI takeover. Verification = offline tests, vplayer, route_sweep, plus Daniel's beta reports. |
| Repo | Public, history rewritten | `danielalanbates/wow-completionist-guide`. v1.0.0 withdrawn; next public release = v2.0 (wiki-based). |
| Classic fallback | .app may generate Questie-based guides at install time | Used only where the wiki has gaps; never committed or shipped. |
| WoW-Pro | Runtime adapter only, no outreach | Nothing WoW-Pro-derived ships. |

## Workstreams

| # | Workstream | Deliverable | Data / licence | Verification (SQL) |
|---|---|---|---|---|
| W1 | Wiki pipeline | `tools/wiki/` fetch → parse → `Imported_Wiki_<flavor>.lua`; `_gaps` files keep only quests the wiki lacks | Wiki CC BY-SA; DB2 facts | `coverage`, `wiki_gaps`, `wiki_vs_db2`, `wiki_db2_conflict` |
| W2 | Generated spine | Retail Campaign → QuestLine order + wiki previous/next chains; Classic chains + level bands; category guides (dungeons, reputation, events, professions) | Wiki, DB2 | `coverage` per category; chain-order violations = 0 |
| W3 | Routing tier A: offline optimizer | `tools/cost_matrix.lua` (real TravelGraph) + `tools/optimize_routes.py` (OR-Tools PDP: precedence, quest-log capacity, level gates, alternative coordinates); output `Data/RouteOrder_<flavor>.lua` | Own | `route_compare` (author / window / baked / baked+live); `opt_gap` < 5% on instances under 40 nodes |
| W4 | Routing tier B: live replanner | StepOrder rewrite: spine + 16–24-step horizon repair, O(1) feasibility checks, segment Or-opt, precedence-safe 2-opt, 3 ms/frame coroutine, hysteresis max(15 s, 5%), live level/log/faction gates | Own | 0 violations; CPU p95 ≤ 3 ms; 0 guides >1% slower than author order |
| W5 | vplayer upgrade | `--order` modes, quest-log cap, XP/level model, perturbation runs | Own | `route_compare`, `route_robust` |
| W6 | Coverage gaps | Achievement criteria located (wiki + DB2 Criteria joins); dungeon/scenario entrances; item-started quests; retail hidden-tracker filter; missions marked non-geographic | Wiki, DB2 | `coverage` located/covered; routable `no_route` → 0 |
| W7 | Forever flavor | `CompletionRoute_Forever.toc`, flavor detection, Era wiki data | Wiki, DB2 | stub load test passes |
| W8 | SQL charting | `docs/verification.sqlite` schema doc + `status_report.py` headline table per flavor | Own | the report itself |
| W9 | Release v2.0 | Release bakes only shippable data (own guides, wiki/DB2-generated guides, RouteOrder); .app generates Classic fallback at install; load-on-demand per flavor; prior builds archived | as above | release file list audited against `data_provenance` |
| W10 | Docs for future AIs | Newest-first STATUS.md, LICENSING.md, ROUTING.md for tier A/B, reproduce-everything runbook | n/a | n/a |

## Milestones

| M | Content | Exit criteria |
|---|---|---|
| M0 | Clean repo | 0 third-party guide artifacts in tree or history; one canonical tree in Drive; TOCs pass `validate_toc.lua` |
| M1 | W1 wiki guides on 4 flavors (**done 2026-11-07**) | all test harnesses pass; `coverage` rows per flavor; spot-check vs wiki pages |
| M2 | W7 Forever | Forever TOC loads in stub test; installed on the Forever client — **done 2026-11-08 (offline; not yet loaded in client)** |
| M3 | W2 spine | generated leveling order for every zone with wiki quests — **done 2026-11-08** (0 PRE violations; level-gate revisit open) |
| M4 | W5 + W3 | `route_compare` filled; quest guides ≥30% faster than author order; 0 violations — **partial 2026-11-08**: 0 violations, model 21–29% median, in-game +5–13% over live window; mop/retail sampled only |
| M5 | W4 | CPU p95 ≤ 3 ms; recovery within 10% of re-solved optimum |
| M6 | W6 | routable `no_route` = 0; achievements located ≥80% |
| M7 | Daniel beta | beta .app installed; Daniel's reports triaged into `beta_reports` |
| M8 | W9 + W10 | v2.0 GitHub release; .app updated; old builds archived |

## Risks and fallbacks

| Risk | Fallback |
|---|---|
| Wiki lacks coordinates for many Classic steps | DB2 / install-time Questie fallback, tagged in the step note and counted in SQL |
| Wiki is retail-first; Classic locations differ | per-version twin pages; >300 yd disagreement → client fallback wins and the row is logged |
| OR-Tools too slow on 8 GB Mac | cluster split, 30 s limit, `nice`, one process, run manually |
| Blizzard objects to DB2-derived data | same practice as ATT/Questie/DBM; raw CSVs stay out of the repo |
| Drive corrupts git | git work only in the ~/Downloads clone; copy results back to Drive without `--delete` |
| Bundle size | load-on-demand per flavor; strip step text |

## Sources

- https://warcraft.wiki.gg/wiki/Warcraft_Wiki:Copyrights · https://creativecommons.org/licenses/by-sa/4.0/
- https://wago.tools/llms.txt · https://wago.tools/api/builds
- https://github.com/Questie/Questie/blob/master/LICENSE.md · https://github.com/Ludovicus-Maior/WoW-Pro-Guides/blob/main/License.md
- https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534
- https://developers.google.com/optimization/routing/pickup_delivery · https://github.com/c4v4/LKH3
- https://polyformproject.org/licenses/noncommercial/1.0.0

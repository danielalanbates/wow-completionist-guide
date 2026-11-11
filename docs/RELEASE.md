# Release packaging and the data-provenance gate

`tools/package_release.py` builds the add-on that players download. It proves the build holds only data the project
may ship: its own code and data, Warcraft Wiki data (CC BY-SA 4.0), Blizzard client data via wago.tools, and the
bundled libraries under their own licences. WoW-Pro and Questie are runtime or install-time interop only and never
ship. (FINISH_PLAN W9, IDEAS "Release packager with a data-provenance gate".)

**Status (2026-11-10).** Built and tested offline on branch `release-packager`. Nothing here has run in a real client,
and no build has passed the gate on real data yet (see *Today's local data*). The tool never tags, pushes or creates a
GitHub release: v2.0 waits for Daniel's beta.

## Commands

```
python3 tools/package_release.py                          # dry run: assemble in a temp folder, gate, measure, report
python3 tools/package_release.py --write --version 2.0.0-beta1   # also write dist/2.0.0-beta1/
python3 tools/package_release.py --stage-dir /tmp/rel     # keep the assembled add-on (pass or fail) for checks
python3 tools/test_package.py                             # offline tests: every gate rule fires on a planted file
```

On the 8 GB Mac prefix each with `heavy.sh`. A dry run on today's data takes about 18 s and 220 MB of memory.

| Option | Effect |
|---|---|
| `--layout universal\|per-client\|both` | which zips `--write` keeps (default `universal`). Both layouts are always measured. |
| `--version V` | version stamped into the packaged TOCs and file names. Default `2.0.0-dev.<commit>`, plus `-dirty` with uncommitted tracked changes. |
| `--data-root DIR` | generated data read from `DIR/<same path>` first (for example a release rebake). Anything else in `DIR` fails the gate. |
| `--allow-checkout-links` | a git worktree whose generated files are links to the same path in the main checkout may read through them. Every other symlink still fails. |
| `--wow-dir DIR` | WoW folder whose `WTF/Account` account and character names count as personal data (default: the x10 WoW folder). |
| `--personal-term T` | another term the package must not contain (repeatable). `tools/release/personal_terms.local.txt` (gitignored) adds more, one per line. |
| `--db PATH` | also write tables `data_provenance` and `release_gate` into that SQLite file. Refuses a symlink. |
| `--out DIR`, `--tmp DIR`, `--repo DIR`, `--no-measure` | output folder for `--write` (default `dist/`), temp parent, checkout, skip the other layout's zips. |

Exit code 0 = gate passed, 1 = gate failed, 2 = usage error. `dist/` is gitignored.

## What a build contains

1. Every file the six TOCs load (and the files their XML includes load), read from the checkout: git-tracked code and
   data, plus the gitignored generated data (`Guides/Imported_*.lua`, `Data/RouteOrder_*.lua`).
2. Always: `Textures/`, `Guides/WIKI_DATA_LICENSE.md`, `Libs/*/LICENSE*`.
3. Written by the packager: `LICENSE.txt` (the repository LICENSE: PolyForm Noncommercial 1.0.0, 10% rider, all
   rights reserved, batesai.org, help@batesai.org), `ATTRIBUTION.md` (from `tools/release/ATTRIBUTION.md`: Warcraft
   Wiki source, licence, changes and the ShareAlike note, then the wiki, Blizzard-data and library files in this
   package) and `README.md` for players (from `tools/release/README.md`).
4. The packaged TOCs get `## Version: <version>` and lose the lines of files that never ship. The checkout's TOCs are
   not changed.

`dist/<version>/` after a passing `--write`: `CompletionRoute/`, the zip(s), `provenance.json`, `gate.txt`. Every
older `dist/<version>/` moves to `dist/archive/`, so one build is current. A failing `--write` writes only `gate.txt`
and `provenance.json` and archives nothing. Zips are reproducible: fixed order, commit timestamp, mode 644.

## Universal zip, not per-client zips

Measured 2026-11-10 on the local data (deflate level 9; this data fails the gate, a release build will be smaller):

| Package | Files | Unpacked MB | Zip MB |
|---|---:|---:|---:|
| **universal** (all six TOCs) | 93 | 43.36 | **6.06** |
| era | 61 | 3.01 | 0.56 |
| tbc | 61 | 3.81 | 0.69 |
| mop | 63 | 8.34 | 1.36 |
| retail | 65 | 30.28 | 4.07 |
| forever | 64 | 3.11 | 0.58 |
| per-client zips together | | 48.55 | 7.27 |

Default: **one universal zip**. The project is one add-on for five clients, and a client loads only the files its
own TOC lists, so the other clients' data costs disk space (about 40 MB for a Classic-only player), not memory or
load time. One download covers a player with several clients. Daniel tests one artifact in beta. Nobody can install
the wrong client's zip. It matches what `tools/install.sh` and the companion app install today. `--layout per-client`
or `both` still builds per-client zips (era 0.56 MB, retail 4.07 MB) for a host that wants one file per game version.

## Where each file comes from (provenance)

`provenance.json` has one record per packaged file: path, bytes, sha256, category, licence, source, generator,
origin (tracked / generated / packager), `via` (a checkout link or `--data-root`) and the clients that load it. It
also lists the files never shipped and why, and the TOC lines stripped. The records come from `RULES` in
`tools/package_release.py`; the source of each generated file was taken from its generator:

| Files | Category | Real source (from the generator) | Generator |
|---|---|---|---|
| `Guides/Imported_Wiki_*` | wiki CC BY-SA | Warcraft Wiki quest pages; QuestV2 decides which quests a client has. Only the `--no-fallback` build ships. | `tools/wiki/gen_wiki_guides.py --no-fallback` (split, order: `gen_spine.py`) |
| `Guides/Imported_Spine_*` | wiki CC BY-SA | the wiki zone guides chained by level band and wiki chains (retail: also QuestLine/Campaign order); no step text copied | `tools/wiki/gen_spine.py` |
| `Guides/Imported_Gold_*` | wiki CC BY-SA | wiki herb, ore, fishing, NPC, quest and instance pages; wiki steps credited to Questie are dropped | `tools/wiki/gen_gold.py` |
| `Guides/Imported_Professions_*` | wiki CC BY-SA | wiki trainer, recipe, reagent and fishing pages; recipes, skill levels and dig sites from Blizzard tables | `tools/wiki/gen_professions.py` |
| `Guides/Imported_Achievements_*` | wiki CC BY-SA | Blizzard Achievement/Criteria/Map tables; points from wiki quest steps (Questie rows skipped) and wiki NPC pages | `tools/gen_completion_guides.py` |
| `Guides/Imported_Missions_retail` | Blizzard data | GarrMission table; the travel step to each table is written in the generator | `tools/gen_completion_guides.py` |
| `Data/Taxi_*`, `Data/MapFix_forever`, `Data/ZoneAliases` | Blizzard data | TaxiNodes/TaxiPath/TaxiPathNode, UiMapAssignment, UiMap (names edited by hand) | `gen_taxi.py`, `gen_mapfix_forever.py`, `gen_maps.py` |
| `Data/RouteOrder_*` | own data | step orders from the add-on's own travel graph over the shipped guides | `optimize_routes.py` (costs `cost_matrix.lua --prefix wiki:`) |
| `Data/Access`, `Transit`, `Inns`, `Farm_routes`, `Roads_*`, `Textures/*.tga` | own data | hand-authored (roads also from in-game traces); textures drawn by `gen_textures.py` | hand / tools |
| `Guides/Leveling/*` | own data, CC BY-SA 4.0 by file header | hand-written community guides | hand |
| `Core`, `Routing`, `UI`, `Adapters`, TOCs, `Guides.xml` | own code | own | hand |
| `Libs/LibStub`, `Libs/CallbackHandler-1.0`, `Libs/HereBeDragons` | library | public domain; Ace3 BSD-style (text shipped); BSD as declared upstream (no upstream licence text) | upstream |

Never shipped (their TOC lines are stripped from the packaged copy, so the client reports no missing file):

| Files | Why |
|---|---|
| `Guides/Imported_WoWPro_*` | WoW-Pro guide text exported on this machine (header: do not redistribute). `Adapters/WoWPro.lua` reads an installed WoW-Pro at runtime. |
| `Guides/Imported_Quests_*_gaps` | Questie-derived (retail: Blizzard POI plus Questie giver points, names, gates). Built at install time on Daniel's machine. |
| `Guides/Imported_Quests_*` | generator input from a local Questie checkout (retail: POI plus `questie_index.tsv`). No TOC loads them. |
| `Guides/Imported_Storylines_retail` | step lines copied from `Imported_Quests_retail.lua`. Ships once it is built from wiki and Blizzard data only. |
| `Data/Imported_Entrances` | Questie's `dungeons.lua`. `Core/Instances.lua` falls back to doors it learns and the retail encounter journal. |

## Gate rules

The gate fails the build on any of these. `tools/test_package.py` plants one bad file per rule and proves it fires.

| Rule | Fails when |
|---|---|
| `no-provenance` | a packaged file matches no rule; a file whose rule says "tracked" is not tracked by git; a `--data-root` holds anything but generated data; not a git checkout |
| `interop-derived` | a file whose rule is WoW-Pro or Questie interop would be packaged (for example through an XML include); a data file mentions Questie or WoW-Pro (for example `(location: Questie data)` fallback steps); a `RouteOrder` row orders a guide registered only in a never-shipped interop file |
| `not-redistributable` | a non-doc file says "do not redistribute", "do not commit", "local use only" or "not for redistribution" |
| `commercial-reference` | a file name or content names the commercial guide product this project replaced (case-insensitive; the name is stored encoded in the tool and never printed) |
| `personal-data` | an e-mail address other than help@batesai.org; a `/Users/<name>`, `/home/<name>`, `C:\Users\<name>` or `/Volumes/<name>` path; a WoW account or character name from `WTF/Account`; a `--personal-term` (reports name the kind, never the term) |
| `secret` | private key block, AWS key id, GitHub, Slack, Google, Stripe or Telegram token, `sk-` key, JWT, or a `password = "..."`-style assignment |
| `symlink` | a packaged file or one of its folders is a symlink (exception: `--allow-checkout-links`) |
| `toc-missing-file` | a packaged TOC (or an XML it includes) lists a file that is not in that client's package; a TOC is missing or not stamped |
| `missing-notice` | LICENSE lacks the PolyForm name, the 10% rider, "All rights reserved", help@batesai.org or batesai.org; a library ships without its licence file |

Notes, not failures: `RouteOrder` rows that name a guide found in no file (stale bake), how many account and
character names were checked, links read with `--allow-checkout-links`, uncommitted tracked changes.

## Today's local data (2026-11-10 dry run)

The gate fails with 13 problems, all real:

* `Imported_Wiki_<flavor>.lua` (5 files) were built with fallback points: 5,490 era, 8,330 tbc, 17,617 mop, 2,754
  retail and 5,493 forever lines credit Questie.
* `Imported_Achievements_mop/retail.lua` and `Imported_Missions_retail.lua` still carry the old "do not redistribute"
  header. `gen_completion_guides.py` on this branch writes the new header; the files were not regenerated.
* `RouteOrder_<flavor>.lua` hold rows for the Questie-derived `_gaps` guides: 56 era, 101 tbc, 44 mop, 29 retail, 55
  forever. Notes: 2 tbc rows and 1 forever row name a wiki guide that no longer exists (stale bake).

With `--stage-dir`, the packaged TOCs (interop lines stripped) load clean in `tools/test_load_all.lua` on all six
TOCs, run from the stage folder. That is a stub load, not a client.

## Making a build that passes

Run in the main checkout (the generators write fixed paths there), one heavy job at a time:

1. `python3 tools/wiki/gen_wiki_guides.py --no-fallback` (also rebuilds the spine). This replaces the local fallback
   variant Daniel plays with; rerun without `--no-fallback` after packaging to get it back.
2. `python3 tools/wiki/gen_gold.py`, `python3 tools/wiki/gen_professions.py`, `python3 tools/gen_completion_guides.py
   retail mop` (new headers; achievement points come from the wiki files of step 1).
3. Rebake the route orders over the shipped guides only, without touching the dev bake:
   ```
   python3 tools/package_release.py --stage-dir /tmp/rel          # new folder; fails only on RouteOrder now
   mkdir -p /tmp/rel/tools /tmp/rel-cost && cp tools/stubs.lua tools/maps_*.lua tools/optimize_routes.py /tmp/rel/tools/
   cd /tmp/rel                                                     # per flavor <fl>:
   luajit <repo>/tools/cost_matrix.lua <fl> --prefix wiki: --out /tmp/rel-cost/<fl>.jsonl
   <venv>/bin/python tools/optimize_routes.py <fl> --in /tmp/rel-cost/<fl>.jsonl --out /tmp/rel-opt/<fl>.jsonl
   mkdir -p /tmp/rel-data/Data && cp /tmp/rel/CompletionRoute/Data/RouteOrder_*.lua /tmp/rel-data/Data/
   ```
   The copied optimizer writes `RouteOrder_<fl>.lua` into the stage, not the checkout. In the stage the cost matrix
   loads exactly the shipped files: no `_gaps` guides, no `Imported_Entrances.lua`, the `--no-fallback` wiki points.
   Smoke-tested 2026-11-10 on one era guide (cost matrix 0.3 s, optimizer 4 s, the gate then passed `RouteOrder_era`).
   A full rebake is the multi-hour job of `docs/ROUTING.md` tier A.
4. `python3 tools/package_release.py --data-root /tmp/rel-data --write --version 2.0.0-beta1 --db docs/verification.sqlite`
5. Load-test the result: `cd dist/2.0.0-beta1 && luajit <repo>/tools/test_load_all.lua`. Then Daniel's beta in the
   real clients. Only after it passes: tag and publish by hand (`.github/workflows/release.yml` no longer publishes on
   a tag; it only runs `tools/test_package.py` on demand).

## Limits

* The gate reads text. Questie or WoW-Pro data that carries no name (a bare coordinate copied without its note) is
  caught only by the file rules, not by content. The generators are what keep fallback points tagged.
* A `RouteOrder` row for a wiki guide does not record which points its bake used. A bake run over the local fallback
  wiki files gives rows the gate cannot tell apart; follow step 3 so the bake sees only shipped data.
* The `RouteOrder` checksum covers only each step's action and first quest id, so a stale row can still apply. That
  check belongs to the bake gate (IDEAS #1).
* Retail `--no-fallback` also drops the `(location: Blizzard data)` points, which are Blizzard quest-POI data and
  could ship if `gen_wiki_guides.py` kept them apart from the Questie giver points.
* `.pkgmeta` (BigWigs packager) is unused since the release workflow stopped publishing on tags.

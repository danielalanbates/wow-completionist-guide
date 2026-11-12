# Release packaging and the data-provenance gate

`tools/package_release.py` builds the add-on that players download. It proves the build holds only data the project
may ship: its own code and data, Warcraft Wiki data (CC BY-SA 4.0), Blizzard client data via wago.tools, and the
bundled libraries under their own licences. Questie is install-time interop on the developer's machine only and never
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

On the 8 GB Mac prefix each with `heavy.sh`. A dry run on today's data takes about 19 s and 225 MB of memory.

| Option | Effect |
|---|---|
| `--layout universal\|per-client\|both` | which zips `--write` keeps (default `universal`). Both layouts are always measured. |
| `--version V` | version stamped into the packaged TOCs and file names. Default `2.0.0-dev.<commit>`, plus `-dirty` with uncommitted changes to `CompletionRoute/`, `LICENSE`, the packager or its templates (`tools/release/`). |
| `--data-root DIR` | generated data read from `DIR/<same path>` first (for example a release rebake). Anything else in `DIR` fails the gate. |
| `--allow-checkout-links` | a git worktree whose generated files are links to the same path in the main checkout may read through them. Every other symlink still fails. |
| `--wow-dir DIR` | WoW folder whose `WTF/Account` account and character names count as personal data (default: the x10 WoW folder). |
| `--personal-term T` | another term the package must not contain (repeatable). `tools/release/personal_terms.local.txt` (gitignored) adds more, one per line. |
| `--db PATH` | also write tables `data_provenance` and `release_gate` into that SQLite file. Refuses a symlink. |
| `--out DIR`, `--tmp DIR`, `--repo DIR`, `--no-measure` | output folder for `--write` (default `dist/`; any folder is safe, see below), temp parent, checkout, skip the other layout's zips. |

Exit code 0 = gate passed, 1 = gate failed, 2 = usage error (checked before any work: `--stage-dir`, `--out`,
`--tmp` and `--db` must be folders or new paths), 3 = the packager itself crashed (traceback printed; the gate did
not finish). `dist/` is gitignored.

## What a build contains

1. Every file the six TOCs load (and the files their XML includes load), read from the checkout: git-tracked code and
   data, plus the gitignored generated data (`Guides/Imported_*.lua`, `Data/RouteOrder_*.lua`).
2. Always: `Textures/`, `Guides/WIKI_DATA_LICENSE.md`, `Libs/*/LICENSE*`.
3. Written by the packager: `LICENSE.txt` (the repository LICENSE: PolyForm Noncommercial 1.0.0, 10% rider, all
   rights reserved, batesai.org, help@batesai.org), `ATTRIBUTION.md` (from `tools/release/ATTRIBUTION.md`: Warcraft
   Wiki source, licence, changes and the ShareAlike note, then the wiki, Blizzard-data and library files in this
   package; a per-client zip gets its own copy that lists only that zip's files, and its package record in
   `provenance.json` gives that copy's sha256 under `differs`) and `README.md` for players (from
   `tools/release/README.md`).
4. The packaged TOCs get `## Version: <version>` and lose the lines of files that never ship. The checkout's TOCs are
   not changed.

`--write` and the output folder:

* A passing build becomes `dist/<version>/`: `CompletionRoute/`, the zip(s), `provenance.json`, `gate.txt`. Every
  earlier build in `dist/`, the same version included, moves to `dist/archive/` (a taken name gets a time suffix), so
  one build is current and nothing is deleted.
* A failing build writes only `gate.txt` and `provenance.json`, to `dist/failed/<version>-<time>/`, and moves
  nothing. It never displaces the build Daniel is testing, even when it has the same version.
* Only folders the packager wrote count as builds: named like a version and holding that version's
  `provenance.json`. Anything else in the output folder is never moved or changed, so `--out` can point anywhere.
  A `dist/<version>` that is not a build stops `--write` with a usage error before anything is written.

Zips are reproducible: fixed order, commit timestamp, mode 644.

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
the wrong client's zip. This differs on purpose from `tools/install.sh` (and the companion app, which runs it): that
script copies each client only its own data files, because it installs into known client folders. `--layout per-client`
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
| `Guides/Imported_Achievements_*` | wiki CC BY-SA | Blizzard Achievement/Criteria/Map, QuestPOI, WorldMapOverlay, AreaTable and DungeonEncounter tables; points from wiki quest steps (fallback rows skipped) and wiki NPC, object, item, glyph, race and achievement pages; each located step names its source. Only the file made from the `--no-fallback` wiki build ships (its header says which build). | `tools/gen_completion_guides.py` |
| `Guides/Imported_QuestLines_retail` | wiki CC BY-SA | Blizzard QuestLine/QuestLineXQuest order and QuestPOI pins; step text, gates and points from `Imported_Wiki_retail.lua` (fallback points dropped); quests without a wiki page are "Quest <id>" steps (2026-11-11). Only the file made from the `--no-fallback` wiki build ships (its header says which build). | `tools/gen_completion_guides.py` |
| `Data/QuestDeps_*` | wiki CC BY-SA | quest chains and names from the wiki guides, breadcrumb wording from the wiki pages. Only the `--wiki-only` build ships. | `tools/gen_quest_deps.py --wiki-only` |
| `Data/Teleports.lua` | wiki CC BY-SA | hand-authored teleport list; ids checked against Blizzard tables, landing points from wiki coordinates or TaxiNodes, cited per entry | hand-authored, checked by `tools/check_teleports.py` |
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
| `Guides/Imported_WoWPro_*` | a leftover export of another addon's guides from before 2026-11-11. Nothing reads it any more; it never ships. |
| `Guides/Imported_Quests_*_gaps` | Questie-derived (retail: Blizzard POI plus Questie giver points, names, gates). Built at install time on Daniel's machine. |
| `Guides/Imported_Quests_*` | generator input from a local Questie checkout (retail: POI plus `questie_index.tsv`). No TOC loads them. |
| `Guides/Imported_Storylines_retail` | step lines copied from `Imported_Quests_retail.lua`. Replaced on 2026-11-11 by `Imported_QuestLines_retail.lua` (wiki and Blizzard data only), which the retail TOC loads instead; the old file keeps its interop rule, so a checkout that still has it never ships it. |
| `Data/Imported_Entrances` | Questie's `dungeons.lua`. `Core/Instances.lua` falls back to doors it learns and the retail encounter journal. |

## Gate rules

The gate fails the build on any of these. `tools/test_package.py` plants one bad file per rule and proves it fires.

| Rule | Fails when |
|---|---|
| `no-provenance` | a packaged file matches no rule; a file whose rule says "tracked" is not tracked by git; a `--data-root` holds anything but generated data; not a git checkout |
| `interop-derived` | a file whose rule is WoW-Pro or Questie interop would be packaged (for example through an XML include); a data file mentions Questie or WoW-Pro (for example `(location: Questie data)` fallback steps); a `RouteOrder` row orders a guide registered only in a never-shipped interop file |
| `not-redistributable` | a non-doc file says "do not redistribute", "do not commit", "local use only" or "not for redistribution" |
| `commercial-reference` | a file name or content names the commercial guide product this project replaced (case-insensitive; the name is stored encoded in the tool and never printed) |
| `personal-data` | an e-mail address other than help@batesai.org; a `/Users/<name>`, `/home/<name>`, `C:\Users\<name>` or `/Volumes/<name>` path; a WoW account or character name from `WTF/Account`; a `--personal-term`, in a file's content or its name (reports name the kind, never the term: a term in a file name is printed as `[personal term]` in `gate.txt`, `provenance.json` and the `--db` rows) |
| `secret` | private key block; AWS key id; GitHub, GitLab, Slack, Google, Stripe, Telegram, npm or Hugging Face token; `sk-` (OpenAI, Anthropic, OpenRouter), Cerebras `csk-`, Groq `gsk_` or xAI `xai-` key; JWT; a credential assignment such as `password = "..."`, `api_key=...` or `OPENAI_API_KEY=...` (unquoted values count when they look like a key: 16+ characters with letters and digits) |
| `symlink` | a packaged file or one of its folders is a symlink (exception: `--allow-checkout-links`) |
| `toc-missing-file` | a packaged TOC (or an XML it includes) lists a file that is not in that client's package; a TOC is missing or not stamped |
| `missing-notice` | LICENSE lacks the PolyForm name, the 10% rider, "All rights reserved", help@batesai.org or batesai.org; a library ships without its licence file |

Notes, not failures: `RouteOrder` rows that name a guide found in no file (stale bake), how many account and
character names were checked, links read with `--allow-checkout-links`, uncommitted changes (the version then ends in
`-dirty` unless `--version` is given).

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

## Dry run on 2026-11-11 (branch `coverage-prof`)

Built in that worktree as steps 1 and 2 below (`--no-fallback` wiki guides with the new quest-pin, place-page and
zone-level points; `gen_completion_guides.py retail mop`; `gen_quest_deps.py --wiki-only`): **gate FAIL, 5 problems,
all `RouteOrder_<fl>.lua` rows that order the Questie-derived `_gaps` guides** (era 56, tbc 101, mop 217, retail 159,
forever 55), plus stale-row notes. The wiki fallback lines, the old achievements/missions header and the local QuestDeps
no longer fail. Step 3 (the rebake over the shipped guides) is what is left. 104 files, universal zip 6.72 MB.

## Making a build that passes

Run in the main checkout (the generators write fixed paths there), one heavy job at a time:

1. `python3 tools/wiki/gen_wiki_guides.py --no-fallback` (also rebuilds the spine). This replaces the local fallback
   variant Daniel plays with; rerun without `--no-fallback` after packaging to get it back.
2. `python3 tools/wiki/gen_gold.py`, `python3 tools/wiki/gen_professions.py`, `python3 tools/gen_completion_guides.py
   retail mop` (new headers; achievement points come from the wiki files of step 1; it also writes the shippable
   `Imported_QuestLines_retail.lua`; files made from the default wiki build name the Questie-derived source in their
   header and fail the gate), and
   `python3 tools/gen_quest_deps.py --wiki-only` (the skip index from the wiki chains only; the local build also reads
   the Questie-derived gaps guides and the storylines and fails the gate). Rerun it without `--wiki-only` afterwards.
3. Rebake the route orders over the shipped guides only, without touching the dev bake:
   ```
   python3 tools/package_release.py --stage-dir /tmp/rel          # new folder; fails only on RouteOrder now
   mkdir -p /tmp/rel/tools /tmp/rel-cost && cp tools/stubs.lua tools/maps_*.lua tools/cm_offline.lua tools/vplayer.lua \
       tools/optimize_routes.py /tmp/rel/tools/
   cd /tmp/rel                                                     # per flavor <fl>:
   luajit <repo>/tools/cost_matrix.lua <fl> --prefix wiki: --out /tmp/rel-cost/<fl>.jsonl
   <venv>/bin/python tools/optimize_routes.py <fl> --in /tmp/rel-cost/<fl>.jsonl --out /tmp/rel-opt/<fl>.jsonl --gate
   mkdir -p /tmp/rel-data/Data && cp /tmp/rel/CompletionRoute/Data/RouteOrder_*.lua /tmp/rel-data/Data/
   ```
   The copied optimizer writes `RouteOrder_<fl>.lua` into the stage, not the checkout, and its gate plays the stage's
   own guides in the copied vplayer. In the stage the cost matrix loads exactly the shipped files: no `_gaps` guides, no
   `Imported_Entrances.lua`, the `--no-fallback` wiki points. Since the cost model (2026-11-10) `cost_matrix.lua` needs
   `tools/cm_offline.lua` next to it in the folder it runs from.
   Smoke-tested 2026-11-10 on one era guide (cost matrix 0.3 s, optimizer 4 s, the gate then passed `RouteOrder_era`).
   A full rebake is the multi-hour job of `docs/ROUTING.md` tier A.
4. `python3 tools/package_release.py --data-root /tmp/rel-data --write --version 2.0.0-beta1 --db docs/verification.sqlite`
5. Load-test the result: `cd dist/2.0.0-beta1 && luajit <repo>/tools/test_load_all.lua`. Then Daniel's beta in the
   real clients. Only after it passes: tag and publish by hand (`.github/workflows/release.yml` no longer publishes on
   a tag; it only runs `tools/test_package.py` on demand).

## Limits

* The gate reads text. Questie or WoW-Pro data that carries no name (a bare coordinate copied without its note) is
  caught only by the file rules, not by content. The generators are what keep fallback points tagged.
* A `RouteOrder` row for a wiki guide does not record which points its bake used. Since checksum version 2
  (2026-11-10) the checksum covers each step's zone and first point, so a row baked over other points no longer matches
  the shipped guide and the client plays that guide in author order; this gate still does not compare checksums, so
  follow step 3 so the bake sees only shipped data.
* `tools/test_route_order.lua` fails on a stale `RouteOrder` row (step count or checksum no longer matching); run it on
  the release data with `CR_ROUTE_ORDER_DIR=/tmp/rel-data/Data`.
* (Fixed 2026-11-11.) Retail quest-POI points are now read straight from the client tables and tagged
  `(location: Blizzard quest POI, ...)`, so the `--no-fallback` build keeps them; place-page and zone-level steps fill
  in after them (docs/WIKI_DATA_SPEC.md 3).
* `.pkgmeta` (BigWigs packager) is unused since the release workflow stopped publishing on tags.

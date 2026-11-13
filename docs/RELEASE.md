# Release packaging and the data-provenance gate

**There is one build (owner's decision, 2026-11-11).** What the six TOC files list, what `tools/install.sh` installs
on the owner's clients, what the generators write by default and what the route bake covers is the set a player gets
from a public release: the project's own code and data, Warcraft Wiki data (CC BY-SA 4.0), Blizzard client data via
wago.tools, players' own location contributions merged in the open data repository (CC BY-SA 4.0; none merged yet,
`docs/CONTRIBUTE.md`), and the bundled libraries under their own licences. Nothing derived from Questie or from any other addon
is generated, loaded, installed, baked or packaged. Packaging adds nothing and removes nothing: a packaged TOC is the
source TOC with the version stamped in.

`tools/package_release.py` builds the add-on that players download and proves the above with a gate.

**Status (2026-11-12).** Offline only: nothing here has run in a real client. The tool never tags, pushes or creates a
GitHub release: v2.0 waits for Daniel's beta. Gate result on the regenerated data: see *Dry run* below.

## Commands

```
python3 tools/package_release.py                          # dry run: assemble in a temp folder, gate, measure, report
python3 tools/package_release.py --write --version 2.0.0-beta1   # also write dist/2.0.0-beta1/
python3 tools/package_release.py --stage-dir /tmp/rel     # keep the assembled add-on (pass or fail) for checks
python3 tools/test_package.py                             # offline tests: every gate rule fires on a planted file
```

On the 8 GB Mac prefix each with `heavy.sh`. A dry run takes about 20 s and 225 MB of memory.

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
4. The packaged TOCs get `## Version: <version>`. That is the only difference from the checkout's TOCs, which are
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

Measured 2026-11-12 on the build (dry run, deflate level 9):

| Package | Files | Unpacked MB | Zip MB |
|---|---:|---:|---:|
| **universal** (all six TOCs) | 106 | 46.83 | **7.13** |
| era | 69 | 3.47 | 0.68 |
| tbc | 69 | 4.38 | 0.82 |
| mop | 71 | 9.07 | 1.54 |
| retail | 74 | 32.89 | 5.03 |
| forever | 72 | 3.59 | 0.71 |
| per-client zips together | | 53.40 | 8.78 |

Default: **one universal zip**. The project is one add-on for five clients, and a client loads only the files its
own TOC lists, so the other clients' data costs disk space (about 40 MB for a Classic-only player), not memory or
load time. One download covers a player with several clients. Daniel tests one artifact in beta. Nobody can install
the wrong client's zip. `tools/install.sh` (and the companion app, which runs it) installs that same universal set
into every client folder: the whole `CompletionRoute` folder, about 45 MB per client. Checked on 2026-11-12 with a
scratch `WOW_DIR`: each of the five installed folders differs from the staged universal package by nine things
only, the three files the packager writes (`LICENSE.txt`, `ATTRIBUTION.md`, `README.md`) and the `## Version` line
of the six TOCs. (Until that day the installer copied each client only its own flavor's data, so a client folder
held 72 to 78 files: neither the universal zip nor a per-client zip.) `--layout per-client` or `both` builds
per-client zips for a host that wants one file per game version.

## Where each file comes from (provenance)

`provenance.json` has one record per packaged file: path, bytes, sha256, category, licence, source, generator,
origin (tracked / generated / packager), `via` (a checkout link or `--data-root`) and the clients that load it. It
also lists any never-shipped file found in `CompletionRoute/` (each one fails the gate). The records come from `RULES` in
`tools/package_release.py`; the source of each generated file was taken from its generator:

| Files | Category | Real source (from the generator) | Generator |
|---|---|---|---|
| `Guides/Imported_Wiki_*` | wiki CC BY-SA | Warcraft Wiki quest pages; QuestV2 decides which quests a client has; on Retail, Blizzard quest pins for steps the wiki gives no point for (the note and the file header say so); for a step neither places, players' merged contributions from the open data repository `wow-completionist-data` (CC BY-SA 4.0; the note says `(location: player contributions, N players)`, the file header names the repository and its commit) | `tools/wiki/gen_wiki_guides.py` (split, order: `gen_spine.py`) |
| `Guides/Imported_Spine_*` | wiki CC BY-SA | the wiki zone guides chained by level band and wiki chains (retail: also QuestLine/Campaign order); no step text copied | `tools/wiki/gen_spine.py` |
| `Guides/Imported_Gold_*` | wiki CC BY-SA | wiki herb, ore, fishing, NPC, quest and instance pages | `tools/wiki/gen_gold.py` |
| `Guides/Imported_Professions_*` | wiki CC BY-SA | wiki trainer, recipe, reagent and fishing pages; recipes, skill levels and dig sites from Blizzard tables | `tools/wiki/gen_professions.py` |
| `Guides/Imported_Achievements_*` | wiki CC BY-SA | Blizzard Achievement/Criteria/Map, QuestPOI, WorldMapOverlay, AreaTable and DungeonEncounter tables; points from wiki quest steps (a player-contributed quest point is credited as such) and wiki NPC, object, item, glyph, race and achievement pages; each located step names its source | `tools/gen_completion_guides.py` |
| `Guides/Imported_QuestLines_retail` | wiki CC BY-SA | Blizzard QuestLine/QuestLineXQuest order and QuestPOI pins; step text, gates and points from `Imported_Wiki_retail.lua` (player-contributed points with their note; the header repeats the provenance line); quests without a wiki page are "Quest <id>" steps | `tools/gen_completion_guides.py` |
| `Data/QuestDeps_*` | wiki CC BY-SA | quest chains and names from the wiki guides, breadcrumb wording from the wiki pages | `tools/gen_quest_deps.py` |
| `Data/QuestIndex_*` | wiki CC BY-SA | which quest ids each quest route names, read from the shipped route files of the same client | `tools/gen_quest_index.lua` |
| `Data/Teleports.lua` | wiki CC BY-SA | hand-authored teleport list; ids checked against Blizzard tables, landing points from wiki coordinates or TaxiNodes, cited per entry | hand-authored, checked by `tools/check_teleports.py` |
| `Guides/Imported_Missions_retail` | Blizzard data | GarrMission table; the travel step to each table is written in the generator | `tools/gen_completion_guides.py` |
| `Data/Taxi_*`, `Data/MapFix_forever`, `Data/ZoneAliases` | Blizzard data | TaxiNodes/TaxiPath/TaxiPathNode, UiMapAssignment, UiMap (names edited by hand) | `gen_taxi.py`, `gen_mapfix_forever.py`, `gen_maps.py` |
| `Data/RouteOrder_*` | own data | step orders from the add-on's own travel graph over the shipped wiki quest guides | `tools/bake_resume.py` (`cost_matrix.lua`, `optimize_routes.py`) |
| `Data/Access`, `Transit`, `Inns`, `Farm_routes`, `Roads_*`, `Textures/*.tga` | own data | hand-authored (roads also from in-game traces); textures drawn by `gen_textures.py` | hand / tools |
| `Guides/Leveling/*` | own data, CC BY-SA 4.0 by file header | hand-written community guides | hand |
| `Core`, `Routing`, `UI`, `Adapters`, TOCs, `Guides.xml` | own code | own | hand |
| `Libs/LibStub`, `Libs/CallbackHandler-1.0`, `Libs/HereBeDragons` | library | public domain; Ace3 BSD-style (text shipped); BSD as declared upstream (no upstream licence text) | upstream |

Never shipped. None of these may be in `CompletionRoute/` or in a TOC: the gate fails on one, `tools/install.sh`
stops on one, and `tools/validate_toc.lua` fails a TOC that lists one.

| Files | Why |
|---|---|
| `Guides/Imported_WoWPro_*` | a leftover export of another addon's guides from before 2026-11-11. |
| `Guides/Imported_Quests_*_gaps` | Questie-derived guides for quests the wiki has no page for (retail: Blizzard POI plus Questie giver points, names, gates). The dev build loaded them until 2026-11-11. |
| `Guides/Imported_Quests_*` | older guides made from a local Questie checkout. Only the offline measurement reads them, from `tools/measure/questie/` (see `tools/measure/README.md`). |
| `Guides/Imported_Storylines_retail` | step lines copied from `Imported_Quests_retail.lua`. Replaced on 2026-11-11 by `Imported_QuestLines_retail.lua` (wiki and Blizzard data only). |
| `Data/Imported_*` (`Imported_Entrances`) | Questie's `dungeons.lua`. `Core/Instances.lua` uses doors it learns and the Retail encounter journal. |

## Gate rules

The gate fails the build on any of these. `tools/test_package.py` plants one bad file per rule and proves it fires.

| Rule | Fails when |
|---|---|
| `no-provenance` | a packaged file matches no rule; a file whose rule says "tracked" is not tracked by git; a `--data-root` holds anything but generated data; not a git checkout; a wiki file has Blizzard quest-pin steps and its header does not name the tables and the client build; a data file has a step that credits player contributions (`location: player contributions`) and its header does not name the data repository (`wow-completionist-data`, CC BY-SA 4.0) with the full commit the areas came from (`unknown` and `<commit>-dirty` fail) |
| `interop-derived` | a never-shipped file (table above) is anywhere in `CompletionRoute/`, a TOC lists one, or an XML include would package one; a data file mentions Questie or WoW-Pro (for example a `(location: Questie data)` step of the retired dev build or of the offline measurement file); a `RouteOrder` row orders a guide registered only in a never-shipped file |
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

## Dry run on 2026-11-12 (branch `public-build-only`)

`heavy.sh python3 tools/package_release.py` on the worktree's regenerated data, with no step that differs from the
everyday workflow: **gate PASS**, exit 0, no problem and no stale-row note. 106 files (own code 40, own data 19, own
docs 4, wiki CC BY-SA 29, Blizzard client data 8, libraries 6), universal zip 7.13 MB. The packaged TOCs differ from
the source TOCs by the `## Version` line only (re-run on commit `c381177` after the independent check: same result,
same sizes). One WoW account name and 43 character names were checked as personal
data. The route orders in that data hold 7 rows (the rest waits for the rebake), so the package would ship almost
unbaked guides: bake before a release.

One thing failed on the first try and was fixed in the generator, not worked around: the quest-line file copies
steps whose point is a Blizzard quest pin from the wiki file, and its header did not name the quest-pin tables and
their client build. `tools/gen_completion_guides.py` now repeats the wiki file's header line.

## Making a build

The everyday workflow is the release workflow. In the checkout that holds the generated data, one heavy job at a time:

1. Regenerate what changed (all of it after a wiki or generator change, or after new player contributions were
   merged: update the `../wow-completionist-data` checkout first and commit nothing by hand in it, so the header
   carries a clean commit):
   `python3 tools/wiki/gen_wiki_guides.py` (also rebuilds the spine), `python3 tools/wiki/gen_gold.py`,
   `python3 tools/wiki/gen_professions.py`, `python3 tools/gen_completion_guides.py retail mop`,
   `python3 tools/gen_quest_deps.py`, and last `luajit -joff tools/gen_quest_index.lua` (the quest index of the
   routes list; it must be made from the final route files: `docs/QUEST_COUNTS.md`).
2. Bake the route orders: `python3 tools/bake_resume.py --jobs 4` (resumable; four batches at a time; it bakes the shipped wiki quest guides and
   rewrites `Data/RouteOrder_<flavor>.lua` with rows for current guides only; `docs/ROUTING.md` "Bake gate").
3. Test: `luajit tools/validate_toc.lua`, the `tools/test_*.lua` harnesses, `python3 tools/test_package.py`,
   `python3 tools/test_contrib_gen.py`.
4. `python3 tools/package_release.py` (dry run: the gate). `tools/install.sh <client folders>` installs the same set
   on the owner's clients for the beta.
5. To publish, the only extra step is the version:
   `python3 tools/package_release.py --write --version 2.0.0-beta1 --db docs/verification.sqlite`, then load-test the
   result (`cd dist/2.0.0-beta1 && luajit <repo>/tools/test_load_all.lua`). Tag and publish by hand, and only after
   Daniel's beta passes (`.github/workflows/release.yml` only runs `tools/test_package.py` on demand).

There is no release-only data variant, no release rebake and no `--data-root` step any more. `--data-root` still
exists for packaging generated data from another folder.

## Limits

* The gate reads text. Questie or WoW-Pro data that carries no name (a bare coordinate copied by hand without its
  note) is not caught. No generator's default run reads such data, and `tools/measure/` (the one explicit offline
  comparison) never writes under `CompletionRoute/`.
* A `RouteOrder` row does not record which points its bake used. The checksum (version 2) covers each step's zone and
  first point, so a row baked over other points does not match the shipped guide and the client plays that guide in
  author order. `tools/test_route_order.lua` fails on such a stale row; the gate only notes rows that name no guide.
* `.pkgmeta` (BigWigs packager) is unused since the release workflow stopped publishing on tags.

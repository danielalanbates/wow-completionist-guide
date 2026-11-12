# Warcraft Wiki data spec (for the W4/W5 wiki generator)

Measured 2026-11-07 by sampling the live MediaWiki API (about 81 requests, cached) and wago.tools.
Sample: 531 `{{Questbox}}` pages spread across pageids 0–722k, plus 296 start/end target pages, plus template sources.
Expansions in the sample (by the `{{Patch X|...added}}` line): Cata 95, BfA 78, TWW 56, Legion 54, SL 40, Wrath 29, Midnight 29,
MoP 28, WoD 27, TBC 26, DF 23, Forever 22, Classic 12, unknown 11.

Source rules (Daniel, 2026-11-07): community sources only. The wiki is the source of truth. DB2 fills only the gaps and decides
flavor membership. Log every wiki-vs-DB2 disagreement in SQL. Wiki-derived files carry a CC BY-SA 4.0 header.

## 1. Fetching

| Item | Value |
|---|---|
| Endpoint | `https://warcraft.wiki.gg/api.php` only. Do not scrape HTML. |
| Headers / params | UA `CompletionistGuide/2.0 (+https://batesai.org)`, gzip, `maxlag=5`, `formatversion=2`. Send requests one at a time, at least 1.2 s apart. Honour `Retry-After` and 429. |
| Page text | `action=query&prop=revisions|categories&rvprop=content&rvslots=main&cllimit=max&redirects=1&titles=<50 titles>` |
| Enumerate | `list=embeddedin&eititle=Template:Questbox&einamespace=0&eilimit=500` (about 81 requests for 40k pages). The same call works for `Template:Npcbox` and `Template:Achievementtip` (9,477 pages, 19 requests). |
| Cache | One JSON file per request, keyed by the sha1 of the sorted params. Reference client: `scratchpad/wiki/w.py`. Move it to `tools/wiki/`, with the cache gitignored. |
| Namespaces | Quest pages are ns 0. Titles may carry suffixes: `(Classic)`, `(Alliance)`/`(Horde)`, `(2)`, `(quest)`. The `Quest:` prefix appears only inside the NQA migration (`Category:NQA questbox fix TODO`). |

## 2. `{{Questbox}}` fields (531 pages)

| Param | Filled | Meaning / parse rule |
|---|---:|---|
| name | 100% | In-game name. Strip the parenthetical page suffixes from the title; use `name` itself. |
| level | 99.8% | Number, or `{{level|bfa-max}}`/`{{Level|Full}}`/`{{level|<Zone>}}` (scaling). `-1` means max level. Use it only for the `LVL` tag when it is a plain number. |
| category | 99.1% | The quest-log header. Usually a zone, but can be a class (`Paladin`), profession, holiday (`Midsummer Fire Festival`), campaign or `Artifact`. **Not reliable as a zone.** `zone` (0.2%) overrides it for removed quests. `displaycat`/`disambigcat` (9%/6%) are display or link variants. |
| start | 97.9% | `[[NPC]]`, `[[Item]]` or `[[Object]]`, optionally with `{{co|x|y|Zone}}` (23% of starts carry coords). Other forms: `Automatic` / `Auto-accept` (9%), `A / B` or `<br>`-separated lists, `{{Alliance}} [[A]] / {{Horde}} [[B]]`, `{{NPC||Name}}`, `{{Au|Name}}`, `{{plainlist|...}}`. |
| end | 39.4% | Same forms as `start`. **Absent means end = start** (the template defaults it). |
| id | 95.1% | Quest ID. Sometimes `N, N` (one ID per faction or variant). On 5% it is missing. Fall back to `{{Elinks-quest|ID}}` in External links, which is on 97% of pages. |
| experience / money / rewards / reputation | 72 / 58 / 44 / 39% | Free text. Not needed for routing. |
| previous / next | 55 / 50% | `[[Title]]` links, `<br>`- or comma-separated. Resolve them to IDs through the title→id map. They become `PRE` tags. |
| levelreq | 52.5% | Minimum level. Becomes `LVL`. |
| faction | 51.8% | `Alliance`/`Horde`/`Neutral`/`Both`, a covenant name (`Kyrian`...) or `Scryers`. **Blank means Neutral.** A/H becomes `FACTION`. |
| type | 24% | blank (solo), `Daily`, `Weekly`, `World Quest`, `Rare/Elite/... world quest`, `Dungeon`, `Raid`, `Group`, `Elite`, `Bonus Objective`, `Calling Quest`, `Emissary Quest`, `Account`, `Important Quest`, `Legendary`, `Combat Ally Quest`, `Island Quest`, `Warfront Contribution`, `PvP`, and more. |
| shareable (`sharable` typo) | 30% | Yes/No. |
| other-faction | 13% | Title of the other faction's version. Use it to pair A/H variants. |
| class | 5.8% | One class becomes `C`. When `class` is blank, `category` may be the class name. |
| race | 4.1% | Comma list (up to 3). Becomes `R`. |
| groupsize / repeatable / profession | 2.1 / 2.4 / 0.4% | `profession` becomes `P`. |
| removed / doc / missingprog / image / noilink | rare | `removed` switches the page into the "Removed" categories. |

**Flavor and patch markers sit above the questbox, not in it:**

| Marker | Count (sample) | Meaning |
|---|---:|---|
| `{{Classic only|patch=4.0.3a}}` (`{{Classic only|tbc|wotlk|cata|mop...}}`) | 47 | Removed from retail at that patch, but still exists in Classic. `Category:Classic quests` holds 4,160 pages. |
| `{{Forever only|Quest}}` | 21 | Exclusive to WoW Forever (patch 1.60.x, product `wowf`). `Category:Forever quests` holds 195 pages. |
| `{{Removed}}` / `{{Removed|patch=X}}` | 8+ | Removed from retail. |
| `{{RemovedFromBeta}}`/`Alpha`/`PTR` | 16 | Never shipped. **Drop the quest.** |
| `==Patch changes==` `*{{Patch X|note=Added.}}` / `{{Patch X|added=}}` / `note=Removed.` | 98% of pages | Patch the quest was added or removed. Hidden categories `Added in patch X` / `Removed in patch X` show the same data. Classic re-releases have their own patches: 1.13–1.15 = Era, 1.60.1 = Forever, 2.5.x = TBC Anniversary, 3.4 = Wrath Classic, 4.4 = Cata Classic, 5.5.x = MoP Classic. |
| `(Classic)` page twin | 5 / 531 | Some quests have a separate Classic page with a different ID (Filthy Paws: Classic 307, retail 26863). Others reuse the same ID (Counterattack! 4021). Use the `(Classic)` page for era and tbc. Use the plain page for mop and retail. |

Body sections: Objectives 94%, Description 91%, Rewards 95%, Completion 96%, Progress(ion) 66%/60%, Notes 57%, Patch changes 98%, External links 100%.

## 3. Coordinates

`{{Coords|x|y|Zone|section|phase|old=|link=}}`. `{{co}}` is a redirect to it (`co` 203 uses vs `coords` 29 in the sample).
x and y are 0–100 percent of the zone map, which is the same unit as the guide `|M|`. All 535 instances sampled were numeric and had a zone.
`section` is an instance floor (`-sN`). `phase` is a terrain phase (21 uses: Gilneas, Hyjal, Midnight Eversong...). The zone is a wiki article
title, usually without a leading "The ". Version suffixes such as `(Classic)`, `(Burning Crusade)`, `(Forever)`, `(alternate universe)` and `(zone)` pick the map version.

Where a quest's giver or ender gets coordinates, in priority order:
1. Coords inside the questbox `start`/`end` (23% of starts).
2. The NPC/object page. `{{Npcbox}}` has `| location = [[Subzone]], [[Zone]]{{co|x|y|Zone}}`, but only 25% of npcboxes carry coords. Pages
   with a `==Locations==` section use one `{{Npclocations|loc=...{{co}}|level=|extracol={{Cata-inline}}|notes=}}` row per spawn,
   phase or expansion. The `extracol` expansion badge tells which era a row belongs to. Object pages (no infobox) put `{{co}}` in the lead sentence.
   Overall, 42% of start/end pages had at least one coords template.
3. DB2 (retail only; MoP Classic's table holds only dig sites): `QuestPOIBlob` with `ObjectiveIndex=-1` gives the turn-in area, read
   straight from the client table. Used for T, for C (objective area, `ObjectiveIndex = QO - 1`), and
   for A only when the wiki names the same NPC as giver and ender. Note `(location: Blizzard quest POI, ...)`; it ships, and the file
   header then names `QuestPOIBlob + QuestPOIPoint`, wago.tools and the client build (`tools/db2/<fl>/BUILD`);
   `tools/package_release.py` fails a wiki file whose steps use a pin without that line. In both builds a disagreement row
   (`turnin_xy`) is written when the wiki's own T point is more than 50 yd from the turn-in pin on the same map (694 on retail,
   2026-11-11).
4. The page of the place the NPC/object page names first in its location field (`[[Razor Hill]], [[Durotar]]`) when the NPC page itself
   has no point and that place is not a map. `tools/wiki/fetch_titles.py` fetches those pages. Note `(location: the wiki's <place>
   page; ...)`; it ships. Rules (2026-11-11 review):
   * only the place page's own point: its infobox, `{{Npclocations}}` or lead coordinate. A coordinate in a section of the page
     (portals, quests, rewards, notes, inhabitants) is something else at that place; a `(Forever)` or Season of Discovery coordinate
     is never used on another client.
   * a place made or moved in a later patch than the client's (`{{Patch 4.0.3a|note=Added.}}`, "Subzone moved", "Remodeled and
     moved", "Replaced the ...") is skipped on that client; "Destroyed", "Rebuilt", "Replaced by ..." and "Subzone added to existing
     area" are kept (the place stood there before).
   * the point must lie in a zone the NPC page names: a map in its location field, else the zone the linked place's own page links
     first in its lead (`place_zone`: "Kargath ... in the [[Badlands]]"). The quest-log category is not a check: on era it was wrong
     for all 16 points it would have rejected.
   * on era, tbc and forever, an NPC page that says where it stood before the Cataclysm ("Before the [[Cataclysm (event)|Cataclysm]],
     she was located at [[Kargath]], [[Badlands]]") gives that sentence's links instead of the location field (56 era pages; a link
     after "northeast of" or "across from" names a landmark and is left out). `fetch_titles.py` also fetches those places.
   Measured against the local reference (measurement only; release build; all A/T place steps on a map the reference also uses):
   median 83 / 78 / 65 / 85 yd on era / tbc / mop / forever, p90 287 / 232 / 365 / 288 yd, 8% / 5% / 9% / 8% over 500 yd or on another
   map (first pass, same script: median 96 / 81 / 67 / 113, p90 1,385 / 855 / 543 / 1,326, 22% / 14% / 10% / 20%).
5. Otherwise the step names a zone (`|Z|` without `M`) with `N|... No coordinates on the wiki; the quest is in <zone>.|`, so the router
   still takes the player to the zone. The zone is the one the NPC/object page names (location field, or its linked place's zone; on
   the Classic clients the pre-Cataclysm place above), not the quest-log category: the category is where the quest is filed (Foreboding
   Plans under Alterac Mountains, Magistrate Henry Maleb in Southshore; In Defense of Frostwolf under the battleground, Rokhstrom in
   Orgrimmar). Among several page maps the one that agrees with the category, then with the quest's located steps, wins. With no page
   map, the category, else the first located step's map. A quest added in 6.x or filed under "(alternate universe)" resolves to
   Draenor's map. With no zone at all the step goes out without a location. Era/TBC/MoP quests have no DB2 pin.
Nothing else is read (2026-11-11: one build). The retired dev build put a local Questie-derived fallback file between 3 and 4; today only
the explicit offline comparison does (`gen_wiki_guides.py --measure-fallback`, `tools/measure/README.md`), and it writes outside `CompletionRoute/`.

Classic-map numbers without a tag (2026-11-11). Patch 4.0.3 redrew the zone maps. A coordinate that already stood on its page, number for
number, in the page's last revision before 2010-11-23 was measured on the Classic map, whatever the zone name says; read as a retail
number it moves several units on the Classic clients (Blasted Lands: 5.5). `tools/wiki/fetch_coord_history.py` finds those
(`tools/wiki/cache/coord_history.sqlite`) and the generators read them as `(Classic)` points. A coordinate changed or added after that
date is a retail number. This complements `wikimaps.KEEP_NUMBERS` (whole zones whose pages are Classic numbers).

Multiple spawns: emit `M|x,y;x,y` only when all points share one zone. Otherwise take the first point in the quest's own zone.
Classic vs retail: Classic pages and `(Classic)` zones refer to pre-Cata maps. Convert them through world coordinates with the
`topX/leftY/width/height` in `tools/maps_<flavor>.lua` (the same math as `to_zone()` in `gen_quest_guides_retail.py`). Unchanged zones
match exactly (Elwynn, Loch Modan, Silverpine). Changed ones differ: Barrens, STV, Hillsbrad, Thousand Needles, Azshara, Darkshore, Westfall-era phases.

## 4. Objectives → steps

`==Objectives==`: a prose line, then `*` bullets (86 of 502 pages had no bullets).

| Bullet shape | Share | Step |
|---|---|---|
| `*[[Mob]] slain (N)` / `*[[Mob]]s revived (N)` | ~35% | `C ...|QID|q|QO|i|T|Mob|` plus coords from the mob page (`{{co}}` in npcbox location or Npclocations). |
| `*[[Item]] (N)` | common | `C`/`l` with `L|itemID N`. itemID comes from the item page `{{#data:Itemtip|itemid=}}`. Drop source is the item page `==Source==` list ("This drops from: *[[Mob]]...") or a lead sentence ("looted from [[Object]] in [[Subzone]]"). Take coords from the first mob or object that has them. |
| `*[[Item]] (provided)` | ~15% | Not a collection step. It becomes `U|itemID` when the description says "use". |
| `*Speak with [[NPC]] ...` / `*Follow [[NPC]]` / free text | ~35% | `C` at the NPC's coords. Free text stays a note-only `C`. |
| `... {{co|x|y|Zone}}` inline | ~5% | Use these coords directly (highest priority). |
| `(Optional)` | ~3% | `O` tag. |
| `(0/100%)` progress bars | ~2% | `C` at the subzone or quest-area coords. |

Retail fallback: DB2 `QuestObjective` (Type 0 = creature, 1 = item, ObjectID, OrderIndex) gives the `QO` index and IDs.
`QuestPOIBlob` objective blobs give the areas. Era, TBC and MoP have no `QuestObjective` (wago returns 400).

## 5. Achievements

The infobox is the parser function `{{#data:Achievementtip ...}}`, not a template call. It is on 9,477 ns-0 pages (19 `embeddedin` requests).
Fields: `name, icon, description, points, category` (e.g. `Quests Eastern Kingdoms`, `Exploration Eastern Kingdoms`,
`Dungeons & Raids`), `faction`, `account`, `meta`, `reward`, `mount`, `criteria` + deprecated `criteria2` (merge them), and `columncount`.
Criteria are `*` bullets: `[[Linked page]]` (sub-achievement, subzone or quest) or plain text (storylines such as `*Refuge Pointe`).
They carry no criterion IDs and no coords. Faction-split achievements use `{{FactionSwitch}}{{#data:Achievementtip...}}{{#data:#Horde ...}}`.
**ID:** `{{elinks-achievement|776}}` in External links. Join it to DB2 `Achievement`/`CriteriaTree`/`Criteria` for criterion IDs (`|ACH|id;treeId|`).
Location: exploration criteria link to subzone pages. Quest criteria resolve through the quest title→id map.

## 6. Flavor membership (wago.tools DB2)

| Flavor | Product key | Build seen 2026-11-07 | QuestV2 rows | URL |
|---|---|---|---:|---|
| era | `wow_classic_era` | 1.15.9.70576 | 4,807 | `https://wago.tools/db2/QuestV2/csv?product=wow_classic_era` |
| tbc | `wow_anniversary` | 2.5.6.70577 | 6,160 | `...?product=wow_anniversary` |
| mop | `wow_classic` | 5.5.4.70631 | 17,140 | `...?product=wow_classic` |
| retail | `wow` | 12.1.5.70783 | 66,552 | `...?product=wow` |
| forever | `wowf` | 1.60.1.70790 (pinned: the installed client) | 6,616 | `...?product=wowf` (`CompletionRoute_Forever.toc`) |

Pin the build when generating: `?build=<version>` (from `https://wago.tools/api/builds`, key → list, newest first).
QuestV2 is cumulative. It keeps removed IDs: all 36 sampled `Classic only|4.0.3a` quests were also in the mop and retail QuestV2.

**Rule:** quest q (wiki ID) belongs to flavor F when **all** of these hold:
1. q ∈ QuestV2[F].
2. Not `RemovedFromBeta/Alpha/PTR`.
3. Not removed at or before F's game version. "Removed" comes from `{{Classic only|patch=P}}`, `{{Removed|patch=P}}`, `Removed in patch P` or a `Patch P note=Removed`. Classic-only quests count as removed for mop (5.5 > 4.0.3a) and retail, but stay in era/tbc. A `{{Removed}}` with no patch excludes the quest from retail only.
4. Not `Forever only`, unless F = forever.
5. For era/tbc, the added patch is ≤ 2.4.3 (base game) or within F's own re-release line (1.13–1.15 for era, 2.5.x for tbc). For mop, it is ≤ 5.4.8 or 5.5.x.

Sample check (531 pages): normal pages with id in retail only 271, mop+retail 101, tbc+mop+retail 24, all products 6. Classic-only pages
36 in all products. Forever-only pages 21 in wowf only. 16 normal pages had an ID in no product (beta, removed or typo). Log those.
Retail live-ness cannot come from POI: 131/402 live sampled quests have no QuestPOIBlob or QuestObjective row.

Disagreement log (SQL, `docs/verification.sqlite`):
`wiki_db2_conflict(flavor, quest_id, field, wiki_value, db2_value, page_title, revid, note)`. Fields: `membership`, `turnin_xy`,
`objective_count`, `zone`, `id_missing`.

## 7. Zone names → uiMapID

Use the addon's resolver logic offline:
1. Strip `(Classic)`/`(Forever)`/`(Burning Crusade)`.
2. Normalize the name to lowercase alphanumerics and match the map names in `tools/maps_<flavor>.lua`.
3. On a miss, retry with "The " added.
4. Then try `NS.ZoneNameAliases`.
5. When several maps match, prefer type 3 (zone), then the lowest ID.

Coords zones in the sample: 377 distinct (category + coords) names. Retail left 91 unresolved, nearly all of them non-zone categories.

| Wiki name | Proposed alias / map (retail) | Note |
|---|---|---|
| `Barrens` / `Barrens (Classic)` | The Barrens (era 1413) / Northern Barrens (retail 10) | wiki drops "The" |
| `Emerald Dream (zone)` | Emerald Dream 2200 | |
| `Shadowmoon Valley (alternate universe)` | 539 | the WoD copy, not Outland 104 |
| `Nagrand (alternate universe)` | 550 | the WoD copy, not Outland 107 |
| `Scarlet Enclave` | Plaguelands: The Scarlet Enclave 124 | |
| `Eversong Woods (Burning Crusade)` / `Silvermoon City (Burning Crusade)` | 94 / 110 | the plain names on Midnight pages mean 2395 / 2393 |
| `Eversong Woods`, `Silvermoon City` (plain, added ≥ 12.0) | 2395 / 2393, **not** 94/110 | the lowest-ID rule is wrong here. Pick by the added patch, or by the DB2 POI UiMapID |
| `Scarlet Monastery Library/Armory/Cathedral` | Scarlet Monastery 302–305 (section) | instance floors |
| `Crusaders' Coliseum`, `Hall of Shadows`, `Temple of Five Dawns`, `Trueshot Lodge`, `Dreamgrove`, `Sinfall`, `Seat of the Primus`, `Elysian Hold`, `Heart of the Forest`, `Frostwall` | class halls, covenant sanctums, garrison: look up in maps_retail by exact name | add them to aliases when found |
| `Battle for Darkshore`, `Battle for Mount Hyjal`, `Vision of Orgrimmar`, `Azmerloth` | warfront / scenario maps | resolve by exact name, otherwise use the parent zone |
| `Zephras Isle` | **unresolved** (not in maps_retail 12.1.0.69382) | regenerate maps from 12.1.5. It may be new |
| `Northern Barrens` on mop | The Barrens 10 | already handled by ZoneNameAliases |
| Category values that are not zones (classes, professions, holidays, `* Campaign`, `Artifact`, `Battle Pets`, `Uncategorized`...) | no map | the guide home zone comes from the start coords' zone |

## 8. Risks

See the `risks` list in the W4 handoff. The main ones:
* Only about 45–55% of quest givers have wiki coords, and era/tbc have no DB2 coord fallback.
* Mob pages mostly lack coords.
* The wiki is retail-first, so Classic positions live on `(Classic)` twins, `Classic only-section` and `extracol` rows.
* Same-name maps (Midnight Eversong, Draenor copies) are ambiguous.
* Free-text fields are irregular.
* Wiki-derived files are CC BY-SA 4.0 and need attribution plus share-alike.

# tools/wiki: Warcraft Wiki → quest guides

Warcraft Wiki (<https://warcraft.wiki.gg>, CC BY-SA 4.0) is the **source of truth** for quest data (Daniel,
2026-11-07). Blizzard client data (wago.tools DB2) does two jobs only: it decides which client has a quest, and on Retail its
quest pins fill coordinates the wiki lacks. Since 2026-11-12 players' own contributions, merged in the open data
repository, fill what both leave open (`docs/CONTRIBUTE.md`). Nothing in this pipeline reads commercial guide data or
another addon's data: there is one build, and what this pipeline writes by default is what ships (2026-11-11).

```
nice -n 10 python3 tools/wiki/fetch_wiki.py        # 1. infobox pages -> cache/wiki_raw.sqlite (~51 min, resumable)
nice -n 10 python3 tools/wiki/parse_wiki.py        # 2. -> wiki.sqlite
nice -n 10 python3 tools/wiki/fetch_titles.py      # 3. pages quests link to that step 1 missed (items, objects,
nice -n 10 python3 tools/wiki/parse_wiki.py        #    subzones, redirects); run 3+2 again for item drop sources.
                                                   #    --db2-names also tries quest-starting items, criteria items and
                                                   #    criteria NPC names from Blizzard tables (about 300 requests)
nice -n 10 python3 tools/wiki/fetch_coord_history.py  # 3b. pre-4.0.3 revisions: Classic-map numbers (Blasted Lands by default)
nice -n 10 python3 tools/wiki/fetch_db2.py         # 4. pinned QuestV2 per flavor (+ retail QuestObjective) -> tools/db2/
nice -n 10 python3 tools/wiki/gen_wiki_guides.py   # 5. -> Guides/Imported_Wiki_<fl>.lua + Imported_Spine_<fl>.lua
luajit tools/test_wiki.lua                         # 6. check
```

Every output is gitignored: `cache/`, `wiki.sqlite`, `tools/db2/*/QuestV2.csv`, and `Guides/Imported_*.lua`.
Fetch etiquette: MediaWiki API only, serial requests at least 1 s apart, `maxlag=5`, Retry-After/429 honoured, gzip,
50 titles per request, UA `CompletionistGuide/2.0 (+https://batesai.org)`. Responses are cached, so no page is
fetched twice.

## What the generator does

The rules live in [docs/WIKI_DATA_SPEC.md](../../docs/WIKI_DATA_SPEC.md); the code is in `gen_wiki_guides.py`.

* **Membership.** A quest goes to a client only if all of these hold:
  * its id is in that client's QuestV2;
  * it is not RemovedFromBeta/Alpha/PTR, Forever-only (allowed on `forever` only) or Season of Discovery;
  * it was not removed at or before the client's version (`{{Classic only|patch=}}`, `{{Removed|patch=}}`,
    `==Patch changes== note=Removed`);
  * its added patch fits the client.

  When a quest has `(Classic)` / `(BC Classic)` / `(Wrath Classic)` twin pages, each client takes the page written
  for it. The reason every quest was skipped is in `wiki.sqlite` table `flavor_skip`.
* **Steps.**
  * `A` goes at the giver. The location comes first from the questbox `{{co}}`, then from the NPC/object/item page.
  * `C` is one step per `==Objectives==` bullet (`QO`, `T|mob|`, `L|item n|`, `O` for optional). The location is
    the bullet's own `{{co}}`, then the target page, then an item's drop sources. `(provided)` items become `U|id|`.
  * `T` goes at the ender. If the wiki gives no ender, the giver is used.
  * Gates: `FACTION`, `R`, `C`, `LVL` (from levelreq).
  * `PRE` comes from the wiki `previous` links ("any one of"), plus the reverse of `next`. It only keeps quests that
    exist on the same client.
* **Versions.** The wiki is retail-first. A wiki point that was not written for the client's version (an NPC page
  with only a current-retail location, used on Classic) is kept. The offline comparison (`--measure-fallback`,
  `tools/measure/README.md`) lists such points that a reference puts more than 300 yd away, in
  `docs/verification.sqlite` `wiki_fallback_conflict`; it never changes the build.
* **Points (2026-11-11).** After the wiki's own point: on retail the client's quest pin
  (`QuestPOIBlob`/`QuestPOIPoint`, `(location: Blizzard quest POI, ...)`),
  then the wiki page of the place the NPC page names when it has no point (`(location: the wiki's <place> page; ...)`),
  then a zone (`|Z|` only). `fetch_titles.py` also fetches those place pages. A coordinate that stood on its
  page before patch 4.0.3 is read as a Classic-map number (`fetch_coord_history.py`). Counts per client:
  `docs/verification.sqlite` `wiki_point_sources` (build `no-fallback` is the build; `fallback` is the offline comparison). Review fixes (2026-11-11): a place page gives only its own point
  (infobox, `{{Npclocations}}` or lead; never a portal, quest or NPC listed on it, never a `(Forever)` or Season of
  Discovery coordinate on another client), and must lie in a zone the NPC page names (its location field, else the
  zone the linked place's own page names); a place made or moved in a later patch than the client's is skipped. The
  zone of a zone-level step is the NPC page's, not the quest-log category's (`zone_choice`); Warlords quests resolve to
  Draenor. On era, tbc and forever an NPC page that says where the NPC stood before the Cataclysm ("was located at
  [[Kargath]], [[Badlands]]") gives that place instead of its current location field. The file header names the
  QuestPOI tables and the client build whenever a step uses a quest pin; `package_release.py` fails a file without it.
* **Player contributions (2026-11-12).** Between the quest pin and the place page: the merged area of the step's key
  in `<contributions>/areas/<flavor>.json` (`A:<quest>`, `T:<quest>`, `C:<quest>:<QO number>`), when it is marked
  `trusted` or `confirmed` and lies on a zone, city, dungeon or micro map the client has (never a continent or the
  world map). A broken areas file is not used: the run warns and goes on as with no contributions. Accept and turn-in take the heaviest area, an objective
  up to three on one map. Note `(location: player contributions, N players)`; the file header names the data
  repository and its commit, and `package_release.py` fails a file without that line. The folder is
  `--contributions DIR`, else `$CR_CONTRIB`, else `../wow-completionist-data/contributions`; `--no-contributions`
  reads none, and with no areas file the output does not change. A wiki point more than 100 yd from the contributed
  area of the same step is logged in `wiki_db2_conflict` (`A_xy_contrib`, `T_xy_contrib`, `C_xy_contrib`).
  `--out DIR` writes a whole run into another folder (`tools/test_contrib_gen.py` uses it).
* **No fallback, no gaps guides (2026-11-11).** A step with no wiki point, quest pin, contributed area or place page names its zone,
  or has no location and says so. A quest with no wiki page is in no zone guide. Until that day a local dev build
  filled both from Questie-derived files (`Imported_Quests_<fl>.lua`, `_gaps` guides); those never shipped and are no
  longer generated, loaded or installed. `install.sh`, the TOC validator and the packager refuse such a file.
* **Excluded types.** World quests, callings and emissary quests are left out (time-limited). Bonus objectives get
  no `T` step.
* **SQL tables.**
  * `wiki.sqlite`: `flavor_quests` (assigned), `flavor_gap` (in QuestV2 but no wiki page; `in_old_guides` is
    always 0 now), `flavor_skip`, `gen_stats`.
  * `docs/verification.sqlite`: `wiki_db2_conflict`, with fields `membership` (wiki says vanilla, era client lacks
    it), `objective_count` (retail wiki bullets vs QuestObjective rows, which also drops `QO`) and `turnin_xy` (wiki
    ender over 50 yd from the retail POI turn-in pin).

## WoW Forever

Forever (product `wowf`, client 1.60.1, Interface 16001) is Era content on the modern client. Its QuestV2 holds
4,805 of era's 4,807 ids plus 1,811 of its own (190 have a wiki page). Four zone maps are reshaped against Era
(Mulgore, Eastern Plaguelands, Redridge Mountains, Stormwind City) and it adds Zephras Isle, Darkspear Islands,
Mount Hyjal, Riverglades and Shen'dralas, with 8 new taxi nodes. So it is its own generator flavor:
`gen_wiki_guides.py forever` takes era membership rules plus the 1.60 line and `{{Forever only}}` / `(Forever)`
pages, and places points on `tools/maps_forever.lua`. The addon
runs the era code path there (`NS.flavor == "era"`, `NS.isForever`, `NS.dataFlavor == "forever"`); every Era-map
point in other guides and data is converted at runtime by `U.EraToForever` (`Data/MapFix_forever.lua`, from
`tools/gen_mapfix_forever.py`). Taxi: `Data/Taxi_forever.lua` (`tools/gen_taxi.py`, wowf 1.60.1.70790).

## Achievements

`parse_wiki.py` parses `{{#data:Achievementtip}}` into `achievements` / `achievement_criteria`: 9,157 pages carry an
`{{elinks-achievement|id}}`, and 8,631 of those match the ids in the DB2 achievement guides. The wiki criteria have
**no criterion ids and no coordinates**, so they cannot tick per criterion. Of 26,455 criteria, 1,779 link to a
quest page (2026-11-11 parse). The DB2 guides (`tools/gen_completion_guides.py`) tick every criterion through
`|ACH|id;criteriaTreeId|`, so they stay; the wiki supplies places: linked quests and NPC pages per criterion, and since
2026-11-11 table `achievement_links` (the links and `{{Coords}}` in each achievement page's lead and location sections),
used for an achievement no criterion locates.

## Items (2026-11-11)

`items` keeps, per item page (`{{Itembox}}` or a `{{#data:Itemtip}}` in the first 600 characters), the pages its
"source" sections and every lead sentence that says where it comes from link to ("can be fished on [[Mechagon Island]]",
"drops ... from [[Itoka]]", "found on Henrig's body{{coords|...}}"), in page order, plus the `{{Coords}}` of those
sentences (`coords_json`). `gen_wiki_guides.py` uses them for item-started quests: Blizzard `ItemSparse.StartQuestID`
says which item starts a quest, the accept step goes where the item is obtained (its own coords, else a source page's
point, else the source zone as a zone-only step) and carries `|U|<item>|`.
A source page about a zone, city or continent never gives a point (its `{{co}}` rows are neighbours and landmarks:
the Silithus page's road to Un'Goro Crater), and neither does a topic page whose every `{{co}}` stands in a body
section (a profession, holiday or system article); a zone source makes the accept zone-only. The accept's note names
the page its point came from. An item page's point is always kept (only the offline comparison, `--measure-fallback`,
sets it against a reference point).

## Glyphs (2026-11-11)

`glyph_points(name, zone, x, y, page_title)` holds every dragon / skyriding glyph that the glyph pages ("Dragon Glyph",
"Skyriding Glyph", "<zone> Glyph Hunter") give a `{{co}}` or a `{{Zone Map Note}}` for: 74 glyphs, all on the Dragon
Isles (The War Within and Midnight hunter pages list places without coordinates). `tools/gen_completion_guides.py`
places "Dragon Glyphs: <name>" achievements there and credits the page.

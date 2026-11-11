# tools/wiki: Warcraft Wiki → quest guides

Warcraft Wiki (<https://warcraft.wiki.gg>, CC BY-SA 4.0) is the **source of truth** for quest data (Daniel,
2026-11-07). Blizzard client data (wago.tools DB2) does two jobs only: it decides which client has a quest, and it
fills coordinates the wiki lacks. Nothing in this pipeline reads commercial guide data.

```
nice -n 10 python3 tools/wiki/fetch_wiki.py        # 1. infobox pages -> cache/wiki_raw.sqlite (~51 min, resumable)
nice -n 10 python3 tools/wiki/parse_wiki.py        # 2. -> wiki.sqlite
nice -n 10 python3 tools/wiki/fetch_titles.py      # 3. pages quests link to that step 1 missed (items, objects,
nice -n 10 python3 tools/wiki/parse_wiki.py        #    subzones, redirects); run 3+2 again for item drop sources.
                                                   #    --db2-names also tries quest-starting items, criteria items and
                                                   #    criteria NPC names from Blizzard tables (about 300 requests)
nice -n 10 python3 tools/wiki/fetch_db2.py         # 4. pinned QuestV2 per flavor (+ retail QuestObjective) -> tools/db2/
nice -n 10 python3 tools/wiki/gen_wiki_guides.py   # 5. -> Guides/Imported_Wiki_<fl>.lua + Imported_Quests_<fl>_gaps.lua
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
  with only a current-retail location, used on Classic) is kept unless the client's own fallback data puts the
  step more than 300 yd away. In that case the fallback wins and the row goes to `docs/verification.sqlite`
  `wiki_db2_conflict` (`A_xy_version` / `C_xy_version` / `T_xy_version`).
* **Fallback.** Only used when the wiki has no usable point. The same step is taken from `Imported_Quests_<fl>.lua`
  and tagged in its note: `(location: Blizzard data)` for retail quest POI, `(location: Questie data)` for Classic.
  `--no-fallback` writes a wiki-only file, which is the shippable variant.
* **No duplicates.** `Imported_Quests_<fl>_gaps.lua` is the old generated file minus every quest the wiki guide
  covers. The TOCs, `install.sh`, `coverage.py`, `vplayer.lua`, `route_sweep.lua` and `audit_guides.lua` load
  `Imported_Wiki_<fl>` + `_gaps` and never the full `Imported_Quests_<fl>`, which is now only generator input.
  `install.sh` excludes the full files from every client.
* **Excluded types.** World quests, callings and emissary quests are left out (time-limited). Bonus objectives get
  no `T` step.
* **SQL tables.**
  * `wiki.sqlite`: `flavor_quests` (assigned), `flavor_gap` (in QuestV2 but no wiki page; `in_old_guides` = still
    covered by `_gaps`), `flavor_skip`, `gen_stats`.
  * `docs/verification.sqlite`: `wiki_db2_conflict`, with fields `membership` (wiki says vanilla, era client lacks
    it), `objective_count` (retail wiki bullets vs QuestObjective rows, which also drops `QO`), `turnin_xy` (wiki
    ender over 50 yd from the retail POI turn-in pin), and `*_xy_version`.

## WoW Forever

Forever (product `wowf`, client 1.60.1, Interface 16001) is Era content on the modern client. Its QuestV2 holds
4,805 of era's 4,807 ids plus 1,811 of its own (190 have a wiki page). Four zone maps are reshaped against Era
(Mulgore, Eastern Plaguelands, Redridge Mountains, Stormwind City) and it adds Zephras Isle, Darkspear Islands,
Mount Hyjal, Riverglades and Shen'dralas, with 8 new taxi nodes. So it is its own generator flavor:
`gen_wiki_guides.py forever` takes era membership rules plus the 1.60 line and `{{Forever only}}` / `(Forever)`
pages, places points on `tools/maps_forever.lua`, and takes fallback points and the `_gaps` guides from
`Imported_Quests_era.lua` (no Forever Questie export), converting Era-map points on the reshaped maps. The addon
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

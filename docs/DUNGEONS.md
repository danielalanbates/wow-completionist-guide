# Dungeons section (dungeon and raid routes)

Owner's request (2026-11-16): "We need a dungeons section that includes all the quests leading up to the dungeon".
Branch `dungeons`. Offline only: **nothing here has run in a real WoW client.**

## 1. What the player sees

* A top-level **Dungeons** category in the routes list (it was already in the menu's category order, empty).
* Inside it, folders by expansion, dungeons before raids: era and Forever `Dungeons`, `Raids`; the other clients
  `Classic Dungeons`, `Classic Raids`, `Burning Crusade Dungeons`, ... (route field `folderOrder`, UI/GuideMenu.lua).
* In a folder, routes by the instance's level range, lowest first; the row shows the range (`[15-28]`) like every other
  route, and the quest count (`3 / 9 quests`) from the quest index.
* One route per instance, or one per faction when the two factions' quests differ (`The Deadmines (Alliance)`; the
  list hides the other faction's route and the faction word, as it does for zone routes).
* The dungeon for the level in the box carries `next for your level` (Core/Recommend.lua `R.NextDungeon`: fitting,
  unfinished, a 5-player dungeon before a raid, range centred nearest the level). Registration fields only, cached
  per level. The Recommended section (Leveling, Nearest quests, Gold, the owner's three picks) is unchanged.

## 2. What a route holds, in order

Built by `tools/wiki/gen_dungeons.py` into `Guides/Imported_Dungeons_<flavor>.lua` (generated, gitignored, CC BY-SA 4.0).

| Part | What | From |
|---|---|---|
| 1. Lead-up | every quest the instance quests need first: their `PRE` followed back until nothing is missing (of "any one of" alternatives: one the route's faction can take, lowest level, lowest id), plus attunement / key quests | `PRE` tags of `Imported_Wiki_<flavor>.lua`; quest names "Attunement to X", "Entry Into X", "The Key to X", and the non-heroic `key=` item of the instance infobox |
| 2. Pick-ups | accept steps of the instance quests whose giver stands outside | wiki NPC page zone |
| 3. The door | `D Enter <instance>` | see section 3 |
| 4. Inside | objective steps; accepts / turn-ins whose NPC stands inside, in chain order | |
| 5. Turn-ins | turn-ins outside, then follow-up quests whose `PRE` names an instance quest | |

A quest that needs another instance quest turned in outside first goes in a second pass (`Enter <instance> again`);
a lead-up quest that itself needs an instance quest is done between the passes (Uldaman: "Passing Word of a Threat"
needs "Prospect of Faith"). An "any one of" prerequisite (`;`) waits for the run only when none of its alternatives is in
the lead-up (`dungeon_routes.unordered_quests`: 0 across all five clients).

Every quest step is a line of the client's `Imported_Wiki_<flavor>.lua`, unchanged except for an inside step with no
point: it gets the instance's own map (`|Z|<instance uiMap>`, so Core/Instances.lua routes to the learned or journal
door), or on a client with no instance maps (era, Forever) the entrance point, with "Inside <instance>; the point is the
entrance." in its note. A quest the zone routes write once per faction takes the copy of the route's faction. Tags,
`QID`, `QO` and `PRE` are kept, so step keys, prefill, skip, quest counts and auto-advance work unchanged. When every
quest of a pass is already completed, `P.Prefill` ticks that pass's `D Enter <instance>` step too, so a finished dungeon
route opens as finished; in game, entering the instance (`IsInInstance`) also completes the `D Enter` step.

Which quests belong to an instance (one at most):
1. its quest-log category names the instance (or the client's own Map / Encounter Journal name of its map); when that
   name is also an outdoor zone on the client (Retail: `Zul'Aman`, `City of Threads`, `Eye of Azshara`), only quests of
   the instance's own expansion whose objectives are not placed on the outdoor continent map;
2. else one of its objective steps is on the instance's map;
3. else every placed objective target (NPC page zone; an item only when every drop source is placed) is in it.
Rules 2 and 3 only for quests of the instance's own expansion (a Shadowlands covenant memory in Stratholme is not a
Culling of Stratholme quest).

## 3. Instances, levels, entrances

| Fact | Source |
|---|---|
| which instances | wiki pages with `{{Infobox instance}}` (`tools/wiki/cache/wiki_raw.sqlite`, `fetch_wiki.py --templates "Infobox instance"`), the client's twin first (`(Classic)` on era/Forever, `(BC Classic)` / `(Burning Crusade)` on TBC, `(Burning Crusade)` on MoP); scenarios, delves, Season of Discovery and pet battle pages are left out |
| client has it, raid or dungeon, expansion | Blizzard `Map` (InstanceType 1/2, ExpansionID) and `JournalInstance` of the client (and MoP / Retail journal names) via `tools/wiki/db2_fetch.py` |
| level range | the client's `LFGDungeons` (normal difficulty, lowest minimum); Retail without one: the wiki's `Template:Level`; else the quests' levels; else the infobox |
| entrance point | `{{Coords}}` / `{{co}}` in the wiki infobox's `loc` field; else Retail `Map.Corpse_0/1` + `CorpseMapID` (the spot a ghost is sent back to: the instance portal) converted to the client's zone map (on era, TBC and Forever only when it lands in the zone the Classic page's `loc` names; Blackrock Mountain resolves to Burning Steppes / Searing Gorge, never `The Great Sea`); else `{{Coords}}` in the wiki page's lead section matching the infobox zone |
| no point | the instance's own map (Retail / MoP / TBC: the add-on learns or asks the journal for the door), else the infobox zone, with the wiki's location words in the note |

The Corpse point is the portal itself, which can lie underground (The Deadmines: 38.2,77.5 in Westfall, the tunnel
under Moonbrook); the step's note names the place from the infobox ("Moonbrook, Westfall").

## 4. Coverage (2026-11-18, `docs/verification.sqlite` table `dungeon_routes`)

| Client | Instances | Routes (dungeon / raid) | Instance quests | Lead-up | Follow-up | Steps | Steps without a point | Door with a point | Not routed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| era | 27 | 46 (36 / 10) | 560 | 369 | 68 | 3,276 | 1,432 | 45 of 46 | 0 |
| tbc | 50 | 76 (58 / 18) | 735 | 682 | 118 | 4,901 | 3,087 | 70 of 76 | 0 |
| forever | 31 | 54 (44 / 10) | 633 | 413 | 78 | 3,648 | 1,591 | 47 of 54 | 0 |
| mop | 94 | 144 (113 / 31) | 793 | 1,206 | 79 | 6,540 | 3,420 | 125 of 144 | 3 |
| retail | 181 | 279 (209 / 70) | 1,388 | 9,871 | 310 | 42,319 | 8,393 | 148 of 279 | 7 |

Counts are per route (a quest in an Alliance and a Horde route counts twice). Steps without a point are mostly the
zone routes' own gaps carried over (lead-up and turn-in steps; `step_detail.py` notes). File sizes: era 0.6 MB, TBC
0.8, Forever 0.7, MoP 1.0, Retail 5.6 MB.

Instance categories with quests and no route, and why (`status = 'no route'`):

| Client | Category (quests) | Why |
|---|---|---|
| mop | Coilfang Reservoir (1), Proving Grounds (2), Temple of Kotmogu (1) | wiki page has no Blizzard dungeon/raid map on the client (an umbrella page, a scenario, a battleground) |
| retail | Coilfang Reservoir (1), Proving Grounds (4), Deaths of Chromie (25), Labyrinth of Kindo'jan (7), Torghast (21), Temple of Kotmogu (1), Gilneas City (3) | same (umbrella page, scenario, battleground or phased zone) |

## 5. Performance

Routes register as text; nothing is parsed until a route is opened (`tools/test_dungeons.lua` checks). The quest index
(`tools/gen_quest_index.lua`) lists every dungeon route, so the counts never parse one. The total "Quests done" line
does not move: the quests are already in the zone routes. Largest Retail routes: Halls of Atonement 1,510 steps,
Castle Nathria 1,470 (the Shadowlands campaign is their lead-up); Retail achievement routes already reach 3,661.

## 6. Commands

```
~/Downloads/CompletionistGuide-work/heavy.sh python3 tools/wiki/gen_dungeons.py        # after gen_wiki_guides.py
~/Downloads/CompletionistGuide-work/heavy.sh luajit -joff tools/gen_quest_index.lua      # always after it
luajit -joff tools/test_dungeons.lua
luajit tools/vplayer.lua <flavor> --type Dungeons --out /tmp/x.tsv
```
Not in the route bake (`tools/bake_resume.py` bakes the wiki zone routes): dungeon routes play in author order plus
the live window, like the quest-line routes.

## 7. Pathways

* An entrance table from Blizzard `AreaTrigger` near the Corpse point would give a surface door instead of the portal.
* Retail lead-ups are long where dungeon quests close a campaign; a "lead-up from the last campaign chapter" option
  could cut them, at the cost of the owner's "all the quests leading up".
* Bake dungeon routes (`cost_matrix.lua` loads only the wiki zone routes).

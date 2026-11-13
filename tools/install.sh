#!/bin/bash
# Sync the addon into one or more WoW AddOns folders (copy, not symlink — WoW + iCloud eviction don't mix).
# Usage: tools/install.sh [flavor_dir ...]   default: _anniversary_      (WOW_DIR=<folder> installs somewhere else)
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)/CompletionRoute"
WOW="${WOW_DIR:-/Volumes/x10/Video Games/Mac/World of Warcraft}"
# The background sync agent keeps its own copy of sync_progress.lua: never leave one older than the addon installed here.
"$(dirname "$0")/refresh_sync_agent.sh" || echo "install.sh: warning: could not refresh the sync agent's copy of sync_progress.lua" >&2
# There is one build: what this script installs is what a player gets from a public release. Every client folder
# gets the whole add-on folder, file for file what the release zip holds (tools/package_release.py, universal
# layout); the zip only adds LICENSE.txt, ATTRIBUTION.md, README.md and the stamped version line of the TOCs. A client
# loads just the files its own TOC lists, so the other clients' data costs disk space (about 40 MB), nothing else.
# Everything generated is built from the Warcraft Wiki (CC BY-SA 4.0), Blizzard client data and the project's own
# data. Nothing derived from another addon is installed: such a file in the source folder stops the install.
FLAVORS="era tbc mop retail forever"
stop() { echo "install.sh: $*" >&2; exit 1; }
# Guard: the quest guides every client loads are Imported_Wiki_<flavor>.lua, written by tools/wiki/gen_wiki_guides.py -
# generated, gitignored. A fresh clone lacks them, and rsync --delete below would then strip the quest guides from
# every client (happened 2026-09-18/19 with the old files). Refuse.
for tier in $FLAVORS; do
  [ -s "$SRC/Guides/Imported_Wiki_$tier.lua" ] || stop "missing Guides/Imported_Wiki_$tier.lua - run tools/wiki/parse_wiki.py + tools/wiki/gen_wiki_guides.py; refusing to wipe the quest guides from the clients"
done
# Completionist sets (tools/gen_completion_guides.py): achievements (mop, retail), quest lines (storylines) + mission
# tables (retail). Generated, gitignored - only a warning: a client without them still has every quest guide.
for f in Imported_Achievements_mop Imported_Achievements_retail Imported_QuestLines_retail Imported_Missions_retail; do
  [ -s "$SRC/Guides/$f.lua" ] || echo "install.sh: note: Guides/$f.lua missing - run tools/gen_completion_guides.py to add it" >&2
done
# Baked route orders (tools/bake_resume.py, Data/RouteOrder_<flavor>.lua): generated, gitignored, optional -
# without one a guide keeps its author order.
for tier in $FLAVORS; do
  [ -s "$SRC/Data/RouteOrder_$tier.lua" ] || echo "install.sh: note: Data/RouteOrder_$tier.lua missing - run tools/bake_resume.py --flavors $tier (guides keep author order)" >&2
done
# Quest prerequisite index for quest-level skipping (tools/gen_quest_deps.py, Data/QuestDeps_<flavor>.lua): generated,
# gitignored, optional - without one, skipping a quest warns from the loaded guide's own PRE tags only.
for tier in $FLAVORS; do
  [ -s "$SRC/Data/QuestDeps_$tier.lua" ] || echo "install.sh: note: Data/QuestDeps_$tier.lua missing - run tools/gen_quest_deps.py $tier (skip warnings fall back to the loaded guide)" >&2
done
# Quest index for the quest counts in the routes list (tools/gen_quest_index.lua, Data/QuestIndex_<flavor>.lua):
# generated, gitignored, optional - without one the list parses every route to count its quests (slower, same numbers).
# Re-run it whenever the route files are regenerated: an entry made from another version of a route is ignored.
for tier in $FLAVORS; do
  [ -s "$SRC/Data/QuestIndex_$tier.lua" ] || echo "install.sh: note: Data/QuestIndex_$tier.lua missing - run luajit -joff tools/gen_quest_index.lua $tier (the routes list then parses every route for its quest count)" >&2
done
# Allowlist: only the generated files that ship may be in the source folder (the same families tools/validate_toc.lua
# lets a TOC list). Anything else generated - a file derived from another addon's data, a generator input, a retired
# file - stops the install: it is not part of the build and must not reach a client.
is_flavor() { case " $FLAVORS " in *" $1 "*) return 0;; esac; return 1; }
for f in "$SRC"/Guides/Imported_* "$SRC"/Data/Imported_* "$SRC"/Data/RouteOrder_* "$SRC"/Data/QuestDeps_* "$SRC"/Data/QuestIndex_*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  rel="${f#"$SRC"/}"; base="$(basename "$f" .lua)"
  [ -L "$f" ] && stop "$rel is a symlink - generated data must be real files here (copy it, do not link it)"
  case "$rel" in
    Guides/Imported_Quests_*_gaps.lua)
      stop "$rel is not part of the build (the _gaps guides were made from another addon's database and were retired on 2026-11-11) - delete it";;
    Guides/Imported_Quests_*)
      stop "$rel is not part of the build (older guides made from another addon's database) - move it to tools/measure/questie/ (offline measurement only) or delete it";;
    Guides/Imported_Storylines_*)
      stop "$rel is not part of the build (replaced by Guides/Imported_QuestLines_retail.lua) - delete it";;
    Data/Imported_*)
      stop "$rel is not part of the build (no generated file belongs in Data/Imported_*; the dungeon-door table was retired on 2026-11-11) - delete it";;
    Guides/Imported_Wiki_*.lua|Guides/Imported_Spine_*.lua|Guides/Imported_Professions_*.lua|Guides/Imported_Gold_*.lua|Guides/Imported_Achievements_*.lua|Guides/Imported_QuestLines_*.lua|Guides/Imported_Missions_*.lua|Data/RouteOrder_*.lua|Data/QuestDeps_*.lua|Data/QuestIndex_*.lua)
      is_flavor "${base##*_}" || stop "unknown generated file $rel (no client has the flavor '${base##*_}') - delete it first";;
    *) stop "unknown generated file $rel is not on the allowlist - delete it first";;
  esac
done
# Content guard: a generated file with an allowed name must not hold another addon's data either (a leftover of the
# dev build retired on 2026-11-11 says so in its header or step notes; the offline measurement file says MEASUREMENT
# ONLY). The release packager's gate applies the same rule.
BAD="$(LC_ALL=C /usr/bin/grep -l -i -E 'questie|wow-?pro|MEASUREMENT ONLY' "$SRC"/Guides/Imported_*.lua "$SRC"/Data/QuestDeps_*.lua "$SRC"/Data/QuestIndex_*.lua 2>/dev/null || true)"
if [ -n "$BAD" ]; then
  echo "$BAD" | while read -r f; do echo "install.sh: ${f#"$SRC"/} holds or credits another addon's data (or is the offline measurement file)" >&2; done
  stop "regenerate the files above (tools/wiki/gen_wiki_guides.py, then gen_gold, gen_professions, tools/gen_completion_guides.py, tools/gen_quest_deps.py, tools/gen_quest_index.lua); nothing was installed"
fi
# A baked order for a guide of the retired dev build (ids qdb:... / qpoi:...) was computed from another addon's points:
# such a row must not reach a client either (tools/optimize_routes.py --merge --current drops it).
BAD="$(LC_ALL=C /usr/bin/grep -l -E '^O\["q(db|poi):' "$SRC"/Data/RouteOrder_*.lua 2>/dev/null || true)"
if [ -n "$BAD" ]; then
  echo "$BAD" | while read -r f; do echo "install.sh: ${f#"$SRC"/} holds baked orders for guides that are not part of the build (qdb: / qpoi: rows)" >&2; done
  stop "rewrite the route orders (tools/bake_resume.py, or tools/optimize_routes.py <flavor> --merge --current <list>); nothing was installed"
fi
flavor_of() { case "$1" in _retail_) echo retail;; _classic_) echo mop;; _classic_era_) echo era;; _anniversary_) echo tbc;; _forever_) echo forever;; *) echo retail;; esac; }
# WoW Forever runs the era code path (Core/Init.lua) with its own wiki guides, taxi and map fix.
for f in "$SRC"/Adapters/*; do
  case "$(basename "$f")" in DynamicQuests.lua) ;;
    *) stop "unknown adapter $f is not on the allowlist - delete it first";;
  esac
done
for fl in "${@:-_anniversary_}"; do
  LEGACY="$WOW/$fl/Interface/AddOns/OpenRoute"
  if [ -d "$LEGACY" ]; then
    echo "install.sh: obsolete OpenRoute is still installed at $LEGACY; archive it before installing CompletionRoute to prevent both guide engines from running" >&2
    exit 1
  fi
  DST="$WOW/$fl/Interface/AddOns/CompletionRoute"
  MINE="$(flavor_of "$fl")"
  mkdir -p "$DST"
  # the whole folder, as the release zip has it (no per-client subset: the owner's client holds what a player's does)
  rsync -a --delete --delete-excluded --exclude ".DS_Store" "$SRC/" "$DST/"
  echo "installed -> $DST ($MINE: $(du -sh "$DST" | cut -f1))"
done

#!/bin/bash
# Sync the addon into one or more WoW AddOns folders (copy, not symlink — WoW + iCloud eviction don't mix).
# Usage: tools/install.sh [flavor_dir ...]   default: _anniversary_
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)/CompletionRoute"
WOW="${WOW_DIR:-/Volumes/x10/Video Games/Mac/World of Warcraft}"
# Guides/ now holds a baked set per flavor (the retail install alone is ~30 MB); ship each client
# only its own, or every game folder carries ~90 MB of other eras' guides it will never load.
# Guard: the quest guides every client loads are Imported_Wiki_<flavor>.lua (Warcraft Wiki, CC BY-SA 4.0) plus
# Imported_Quests_<flavor>_gaps.lua (the older Questie/Blizzard-POI guides minus every quest the wiki covers), both
# written by tools/wiki/gen_wiki_guides.py - generated, gitignored. A fresh clone lacks them, and rsync --delete
# below would then strip the quest guides from every client (happened 2026-09-18/19 with the old files). Refuse.
for tier in era tbc mop retail forever; do
  for f in "Imported_Wiki_$tier" "Imported_Quests_${tier}_gaps"; do
    [ -s "$SRC/Guides/$f.lua" ] || { echo "install.sh: missing Guides/$f.lua - run tools/wiki/parse_wiki.py + tools/wiki/gen_wiki_guides.py (needs Guides/Imported_Quests_$tier.lua for the gaps file; forever uses Imported_Quests_era.lua); refusing to wipe the quest guides from the clients" >&2; exit 1; }
  done
done
# Completionist sets (tools/gen_completion_guides.py): achievements (mop, retail), storylines + mission
# tables (retail).  Same rule as above - generated, gitignored - but only a warning: a client without
# them still has every quest guide.
for f in Imported_Achievements_mop Imported_Achievements_retail Imported_Storylines_retail Imported_Missions_retail; do
  [ -s "$SRC/Guides/$f.lua" ] || echo "install.sh: note: Guides/$f.lua missing - run tools/gen_completion_guides.py to add it" >&2
done
# Baked route orders (tools/optimize_routes.py, Data/RouteOrder_<flavor>.lua): generated, gitignored, optional -
# without one a guide keeps its author order. Each client gets only its own (per-flavor excludes below).
for tier in era tbc mop retail forever; do
  [ -s "$SRC/Data/RouteOrder_$tier.lua" ] || echo "install.sh: note: Data/RouteOrder_$tier.lua missing - run tools/cost_matrix.lua + tools/optimize_routes.py $tier (guides keep author order)" >&2
done
for f in "$SRC"/Data/RouteOrder_*; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in RouteOrder_era.lua|RouteOrder_tbc.lua|RouteOrder_mop.lua|RouteOrder_retail.lua|RouteOrder_forever.lua) ;;
    *) echo "install.sh: unknown route order file $f - delete it first" >&2; exit 1;;
  esac
done
flavor_of() { case "$1" in _retail_) echo retail;; _classic_) echo mop;; _classic_era_) echo era;; _anniversary_) echo tbc;; _forever_) echo forever;; *) echo retail;; esac; }
# WoW Forever runs the era code path (Core/Init.lua) with its own wiki/gaps guides, taxi and map fix; it still
# loads the era WoW-Pro adapter file (Guides/Imported_WoWPro_era.lua, see CompletionRoute_Forever.toc).
wowpro_of() { case "$1" in forever) echo era;; *) echo "$1";; esac; }
# Allowlist: only community-sourced generated guides and known adapters may be installed or shipped
# (Daniel, 2026-11-07). Anything else in Guides/ or Adapters/ stops the install.
for f in "$SRC"/Guides/Imported_*; do
  case "$(basename "$f")" in
    Imported_Wiki_*|Imported_Spine_*|Imported_Professions_*|Imported_Gold_*|Imported_Quests_*|Imported_WoWPro_*|Imported_Achievements_*|Imported_Storylines_*|Imported_Missions_*|Imported_Entrances_*) ;;
    *) echo "install.sh: unknown generated guide $f is not on the allowlist - delete it first" >&2; exit 1;;
  esac
done
for f in "$SRC"/Adapters/*; do
  case "$(basename "$f")" in DynamicQuests.lua|WoWPro.lua) ;;
    *) echo "install.sh: unknown adapter $f is not on the allowlist - delete it first" >&2; exit 1;;
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
  EXCL=()
  # the full Imported_Quests_<tier>.lua files are generator INPUT now (no TOC loads them); never ship them
  for tier in era tbc wotlk cata mop retail; do EXCL+=(--exclude "Guides/Imported_Quests_$tier.lua"); done
  for other in era tbc mop retail forever; do
    [ "$other" = "$MINE" ] && continue
    [ "$other" != "$(wowpro_of "$MINE")" ] && EXCL+=(--exclude "Guides/Imported_WoWPro_$other.lua")
    EXCL+=(--exclude "Guides/Imported_Wiki_$other.lua" --exclude "Guides/Imported_Spine_$other.lua" --exclude "Guides/Imported_Professions_$other.lua" --exclude "Guides/Imported_Gold_$other.lua" --exclude "Guides/Imported_Quests_${other}_gaps.lua"
           --exclude "Guides/Imported_Achievements_$other.lua" --exclude "Guides/Imported_Storylines_$other.lua"
           --exclude "Guides/Imported_Missions_$other.lua" --exclude "Data/RouteOrder_$other.lua")
  done
  mkdir -p "$DST"
  rsync -a --delete --delete-excluded --exclude ".DS_Store" "${EXCL[@]}" "$SRC/" "$DST/"
  echo "installed -> $DST ($MINE: $(du -sh "$DST" | cut -f1))"
done

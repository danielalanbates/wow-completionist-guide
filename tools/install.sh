#!/bin/bash
# Sync the addon into one or more WoW AddOns folders (copy, not symlink — WoW + iCloud eviction don't mix).
# Usage: tools/install.sh [flavor_dir ...]   default: _anniversary_
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)/CompletionRoute"
WOW="${WOW_DIR:-/Volumes/x10/Video Games/Mac/World of Warcraft}"
# bake third-party guides from the local install so CompletionRoute is standalone (non-fatal if luajit/addons missing)
command -v luajit >/dev/null && luajit "$(dirname "$0")/export_guides.lua" || true
# Guides/ now holds a baked set per flavor (Zygor's retail install alone is ~30 MB); ship each client
# only its own, or every game folder carries ~90 MB of other eras' guides it will never load.
# Guard: Imported_Quests_*.lua are the community (Questie/Blizzard-POI) guides — generated, gitignored,
# and the whole point of the addon once the Zygor sub ends. A fresh clone lacks them, and rsync --delete
# below would then strip them from every client (happened 2026-09-18/19). Refuse instead.
for tier in era tbc wotlk cata mop retail; do
  [ -s "$SRC/Guides/Imported_Quests_$tier.lua" ] || { echo "install.sh: missing Guides/Imported_Quests_$tier.lua — regenerate (tools/gen_quest_guides.lua / gen_quest_guides_retail.py) or copy it in; refusing to wipe the community guides from the clients" >&2; exit 1; }
done
# Completionist sets (tools/gen_completion_guides.py): achievements (mop, retail), storylines + mission
# tables (retail).  Same rule as above - generated, gitignored - but only a warning: a client without
# them still has every quest guide.
for f in Imported_Achievements_mop Imported_Achievements_retail Imported_Storylines_retail Imported_Missions_retail; do
  [ -s "$SRC/Guides/$f.lua" ] || echo "install.sh: note: Guides/$f.lua missing - run tools/gen_completion_guides.py to add it" >&2
done
flavor_of() { case "$1" in _retail_) echo retail;; _classic_) echo mop;; _classic_era_) echo era;; _anniversary_) echo tbc;; *) echo retail;; esac; }
for fl in "${@:-_anniversary_}"; do
  LEGACY="$WOW/$fl/Interface/AddOns/OpenRoute"
  if [ -d "$LEGACY" ]; then
    echo "install.sh: obsolete OpenRoute is still installed at $LEGACY; archive it before installing CompletionRoute to prevent both guide engines from running" >&2
    exit 1
  fi
  DST="$WOW/$fl/Interface/AddOns/CompletionRoute"
  MINE="$(flavor_of "$fl")"
  EXCL=()
  for other in era tbc mop retail; do
    [ "$other" = "$MINE" ] && continue
    EXCL+=(--exclude "Guides/Imported_Zygor_$other.lua" --exclude "Guides/Imported_WoWPro_$other.lua"
           --exclude "Guides/Imported_Achievements_$other.lua" --exclude "Guides/Imported_Storylines_$other.lua"
           --exclude "Guides/Imported_Missions_$other.lua")
  done
  mkdir -p "$DST"
  rsync -a --delete --exclude ".DS_Store" "${EXCL[@]}" "$SRC/" "$DST/"
  echo "installed -> $DST ($MINE: $(du -sh "$DST" | cut -f1))"
done

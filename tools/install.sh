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
flavor_of() { case "$1" in _retail_) echo retail;; _classic_) echo mop;; _classic_era_) echo era;; _anniversary_) echo tbc;; *) echo retail;; esac; }
for fl in "${@:-_anniversary_}"; do
  DST="$WOW/$fl/Interface/AddOns/CompletionRoute"
  MINE="$(flavor_of "$fl")"
  EXCL=()
  for other in era tbc mop retail; do
    [ "$other" = "$MINE" ] && continue
    EXCL+=(--exclude "Guides/Imported_Zygor_$other.lua" --exclude "Guides/Imported_WoWPro_$other.lua")
  done
  mkdir -p "$DST"
  rsync -a --delete --exclude ".DS_Store" "${EXCL[@]}" "$SRC/" "$DST/"
  echo "installed -> $DST ($MINE: $(du -sh "$DST" | cut -f1))"
done

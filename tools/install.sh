#!/bin/bash
# Sync the addon into one or more WoW AddOns folders (copy, not symlink — WoW + iCloud eviction don't mix).
# Usage: tools/install.sh [flavor_dir ...]   default: _anniversary_
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)/OpenRoute"
WOW="${WOW_DIR:-/Volumes/x10/Video Games/Mac/World of Warcraft}"
# bake third-party guides from the local install so OpenRoute is standalone (non-fatal if luajit/addons missing)
command -v luajit >/dev/null && luajit "$(dirname "$0")/export_guides.lua" "$WOW/_anniversary_" || true
for fl in "${@:-_anniversary_}"; do
  DST="$WOW/$fl/Interface/AddOns/OpenRoute"
  mkdir -p "$DST"
  rsync -a --delete --exclude ".DS_Store" "$SRC/" "$DST/"
  echo "installed -> $DST"
done

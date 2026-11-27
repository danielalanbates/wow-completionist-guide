#!/bin/sh
# CompletionRoute :: tools/emu/fetch_emu.sh
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
# Download the open emulator world databases (docs/EMU_DATA.md) into $CR_TMP/emu/dl, extract the compact
# tools/db2/emu/<source>.sqlite files, then delete the downloads.  Needs gh and 7zz.
set -eu
cd "$(dirname "$0")/../.."
: "${CR_TMP:=$(python3 -c 'import sys; sys.path.insert(0,"tools"); import optimize_routes as o; print(o.TMP_DEFAULT)')}"
D="$CR_TMP/emu/dl"; mkdir -p "$D"
X() { nice -n 10 python3 tools/emu/extract_emu.py "$@"; }
for spec in classic-db:ClassicDB_1_12_1_z2815.sql.gz:classic tbc-db:TBCDB_1.11.0_Vengeance_One_A_Cmangos_Story.sql.gz:tbc; do
  repo=${spec%%:*}; rest=${spec#*:}; f=${rest%%:*}; src=${rest#*:}
  sha=$(gh api "repos/cmangos/$repo/commits/master" --jq .sha)
  curl -sfL -o "$D/$f" "https://github.com/cmangos/$repo/raw/$sha/Full_DB/$f"
  X "$src" "cmangos/$repo" "$sha" "$D/$f"; rm -f "$D/$f"
done
for spec in TDB442.26081:tc442 TDB1210.26091:tc1210; do
  tag=${spec%%:*}; src=${spec#*:}
  sha=$(gh api "repos/TrinityCore/TrinityCore/git/ref/tags/$tag" --jq .object.sha)
  gh release download "$tag" -R TrinityCore/TrinityCore -p '*.7z' -D "$D" --clobber
  X "$src" "TrinityCore/TrinityCore@$tag" "$sha" "$D"/TDB_full_*.7z; rm -f "$D"/TDB_full_*.7z
done

#!/bin/sh
# CompletionRoute :: tools/att/fetch_att.sh
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
# Shallow, blobless, sparse clone of only db/<Version> of the MIT community collection database (docs/EMU_DATA.md;
# the whole repo is ~7 GB, these folders ~40 MB) into $CR_TMP/att, write tools/db2/att/<source>.sqlite, delete the clone.
# Needs git and Lua 5.4+ (`lua`).
set -eu
cd "$(dirname "$0")/../.."
: "${CR_TMP:=$(python3 -c 'import sys; sys.path.insert(0,"tools"); import optimize_routes as o; print(o.TMP_DEFAULT)')}"
D="$CR_TMP/att"; rm -rf "$D"; mkdir -p "$D"
git clone -q --depth 1 --filter=blob:none --no-checkout https://github.com/ATTWoWAddon/AllTheThings.git "$D/db"
git -C "$D/db" sparse-checkout set --no-cone /db/Standard/ /db/Vanilla/ /db/Camelot/ /db/TBC/ /db/Mists/ /LICENSE \
  '!/db/*/LocalizationDB.lua'
git -C "$D/db" checkout -q
sha=$(git -C "$D/db" rev-parse HEAD)
for spec in Vanilla:vanilla Camelot:camelot TBC:tbc Mists:mists Standard:standard; do
  ver=${spec%%:*}; src=${spec#*:}
  nice -n 10 lua tools/att/extract_att.lua "$D/db/db/$ver" "$D/$src.tsv"
  nice -n 10 python3 tools/att/build_att.py "$src" ATTWoWAddon/AllTheThings "$sha" "$D/$src.tsv"
done
rm -rf "$D"

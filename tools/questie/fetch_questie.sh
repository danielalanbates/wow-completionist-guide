#!/bin/sh
# CompletionRoute :: tools/questie/fetch_questie.sh
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
# Shallow, sparse clone of the GPLv3 community quest database (docs/EMU_DATA.md) into $CR_TMP/questie, write the
# compact tools/db2/questie/<source>.sqlite files, then delete the clone.  Needs git and Lua 5.4+ (`lua`).
set -eu
cd "$(dirname "$0")/../.."
: "${CR_TMP:=$(python3 -c 'import sys; sys.path.insert(0,"tools"); import optimize_routes as o; print(o.TMP_DEFAULT)')}"
D="$CR_TMP/questie"; rm -rf "$D"; mkdir -p "$D"
git clone -q --depth 1 --filter=blob:none --sparse https://github.com/Questie/QuestieDB.git "$D/db"
git -C "$D/db" sparse-checkout set --no-cone data src/corrections support LICENSE.md
sha=$(git -C "$D/db" rev-parse HEAD)
for spec in Classic:classic TBC:tbc Cata:cata MoP:mop Forever:forever; do
  exp=${spec%%:*}; src=${spec#*:}
  nice -n 10 lua tools/questie/extract_questie.lua "$D/db" "$exp" "$D/$src.tsv"
  nice -n 10 python3 tools/questie/build_questie.py "$src" Questie/QuestieDB "$sha" "$D/$src.tsv"
done
rm -rf "$D"

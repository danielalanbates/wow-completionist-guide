#!/bin/sh
# CompletionRoute :: tools/check_all.sh
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
#
# The checks the old GitHub CI ran, run on this machine (the project uses no GitHub compute; the workflows are in
# archive/github-actions/). Run by hand before a push or PR:  sh tools/check_all.sh
# luacheck fails only on errors (exit >= 2); warnings are reported.
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
step() { printf '\n== %s\n' "$*"; "$@" || { echo "FAILED: $*"; fail=1; }; }
lint() { luacheck CompletionRoute --no-color -q; c=$?; [ "$c" -lt 2 ]; }
if command -v luacheck >/dev/null 2>&1; then step lint; else echo "luacheck not installed: lint skipped"; fi
step luajit tools/validate_toc.lua
step luajit tools/test_load_all.lua
step luajit tools/test_offline.lua
step luajit tools/test_doors.lua
step python3 tools/test_package.py
step python3 tools/test_contrib_gen.py
step python3 tools/test_history_points.py
step python3 tools/test_tmp_default.py
step python3 tools/test_refresh_changed.py
step python3 tools/test_subzones.py
step python3 tools/test_emu_points.py
step python3 tools/test_questie_points.py
step python3 tools/test_att_points.py
step python3 tools/test_legacy.py
[ "$fail" = 0 ] && echo "\nall checks passed" || echo "\nsome checks FAILED"
exit "$fail"

#!/bin/bash
# The background sync agent (tools/install_sync_agent.sh) runs its OWN copy of sync_progress.lua, made when the agent
# was installed.  A copy older than the addon rewrites every client's saved variables without the tables it does not
# know (the August 2026 copy dropped stepDone, stepSkipped, stepMeta and questSkip).  This replaces a copy that
# differs from the one next to this script.  It does nothing when no agent copy exists.  Run by tools/install.sh.
SRC="$(cd "$(dirname "$0")" && pwd)/sync_progress.lua"
DST_DIR="${CR_SYNC_AGENT_DIR:-$HOME/Library/Application Support/CompletionRoute}"
DST="$DST_DIR/sync_progress.lua"
[ -f "$DST" ] || exit 0
[ -f "$SRC" ] || { echo "refresh_sync_agent.sh: $SRC is missing" >&2; exit 1; }
cmp -s "$SRC" "$DST" && exit 0
cp "$SRC" "$DST" && echo "sync agent: its copy of sync_progress.lua was out of date and has been replaced ($DST)"

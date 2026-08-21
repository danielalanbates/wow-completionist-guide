#!/bin/bash
# Install the cross-client progress sync as a launchd WatchPaths agent (fires whenever any WoW client
# writes CompletionRoute's SavedVariables, i.e. at logout / reload). The script is COPIED out of iCloud
# first - launchd must never point at an iCloud path (eviction crash-loops).
set -e
SRC="$(cd "$(dirname "$0")" && pwd)/sync_progress.lua"
DST_DIR="$HOME/Library/Application Support/CompletionRoute"
WOW="${WOW_DIR:-/Volumes/x10/Video Games/Mac/World of Warcraft}"
LUAJIT="$(command -v luajit || echo /opt/homebrew/bin/luajit)"
mkdir -p "$DST_DIR"
cp "$SRC" "$DST_DIR/sync_progress.lua"
cat > "$DST_DIR/sync.sh" <<SH
#!/bin/bash
sleep 20   # let the client finish writing every SavedVariables file
exec "$LUAJIT" "$DST_DIR/sync_progress.lua" --wow "$WOW" >> "$DST_DIR/sync.log" 2>&1
SH
chmod +x "$DST_DIR/sync.sh"
PLIST="$HOME/Library/LaunchAgents/com.batesai.completionroute-sync.plist"
{
  echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'
  echo '<key>Label</key><string>com.batesai.completionroute-sync</string>'
  echo "<key>ProgramArguments</key><array><string>$DST_DIR/sync.sh</string></array>"
  echo '<key>WatchPaths</key><array>'
  for fl in _retail_ _classic_ _classic_era_ _anniversary_; do
    for f in "$WOW/$fl"/WTF/Account/*/SavedVariables/CompletionRoute.lua; do [ -e "$f" ] && echo "<string>$f</string>"; done
  done
  echo '</array><key>RunAtLoad</key><false/><key>ThrottleInterval</key><integer>30</integer></dict></plist>'
} > "$PLIST"
launchctl bootout "gui/$(id -u)/com.batesai.completionroute-sync" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl print "gui/$(id -u)/com.batesai.completionroute-sync" | grep -E "state|path" | head -3
echo "installed $PLIST"

# Cross-game progress sync

WoW stores an addon's SavedVariables **per client folder** (`_retail_/WTF`, `_classic_/WTF`, `_classic_era_/WTF`,
`_anniversary_/WTF`). Nothing inside the game can read another folder, so "a guide finished on retail shows as
finished in Classic" needs a merge outside the game.

## What syncs
`CompletionRouteDB.chars[<Name-Realm>]` = one record per character on the account: `done[guide][step]`,
`skipped`, `quests[questID]` (harvested from the client at login + every turn-in), plus name/class/faction/level.
`tools/sync_progress.lua` loads every flavor's file, **unions** those records (and the recorded road traces) and
writes the merged `chars` back into each file. Idempotent. Backups: `<file>.presync.bak`.
Then in any client: the guide browser shows `(CharacterName)` for wholly completed guides from every game, and
with account-wide progression opted in, their quest completions clear matching steps.

Verified 2026-08-20: 6 characters across 4 clients, 757 completed-quest records unioned
(`luajit tools/sync_progress.lua` → "synced _retail_ (1 -> 6 chars)" etc.).

## When it runs
* `tools/install.sh` and `tools/run_flavor_verify.py` run it (Terminal context).
* `tools/install_sync_agent.sh` installs a launchd WatchPaths agent (`com.batesai.completionroute-sync`) that fires
  whenever a client writes its SavedVariables (logout / reload). **Blocked today by macOS TCC**: processes started by
  launchd are not allowed to read the external drive (`ls: .../World of Warcraft/*/WTF/...: No such file or
  directory` in `~/Library/Application Support/CompletionRoute/sync.log`), the same wall the photo indexer hit.
  One-time fix, needs Daniel: System Settings → Privacy & Security → Full Disk Access → add `/opt/homebrew/bin/luajit`
  (or `/bin/bash`). After that the agent works unattended. Until then: run `luajit tools/sync_progress.lua` after
  playing, or just before launching another game.

## Timing caveat
A client reads SavedVariables once at login and writes them at logout/reload. A merge done while a client is
running is overwritten by that client at logout — harmless, the next merge unions it back in. For the merge to be
visible in a game, it has to happen before that game's login.

## Not synced (by design)
Settings/profile (per client), the current guide/step (per character file `CompletionRouteCharDB`).

# Testing policy — where each kind of test is allowed to run

Standing rule from Daniel (2026-08-25): **AI-driven character movement is not allowed on live
(Blizzard) servers.** Anything that moves a character runs only against a private server or a fully
offline environment. Logging into a live server is fine **only if the character does not move**.

How each harness complies:

| Harness | Where it runs | Moves a character? |
|---|---|---|
| `tools/vplayer.lua` (virtual player) | fully offline — pure Lua, no client, no server connection | simulated only; nothing touches any server |
| `tools/route_sweep.lua`, audits, exports | fully offline | no |
| `tools/run_flavor_verify.py` / `run_all_flavors.py` (in-game pass) | live server login | **no** — the character stands at the login spot for the whole session |

Why the in-game pass cannot move the character even by accident:
- The addon calls **no movement API** (`grep -rE 'MoveForward|TurnLeft|ClickToMove' CompletionRoute`
  is empty), and WoW protects those functions from insecure code anyway.
- The driver synthesizes **no keyboard events at all**, and its only clicks are UI chrome:
  the launcher's Play button, Enter World on character select, the Blizzard popup dismiss, and the
  addon's pinned secure /quit button. It never clicks into the 3D world.
- The in-game sweep (`autoSweep`) evaluates guide loading, step location and routing math in Lua;
  it reads the world, it does not act on it.

Screen etiquette (unchanged): the driver refuses to start, and stops between flavors, while a
wine/FFXI window or another live game owns the display. `--take-screen` overrides only when Daniel
has said the machine is free — **and even then, check for a live FFXI/wine session first; another
agent session may be driving it** (2026-08-25: exactly that happened).

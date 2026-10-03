# "Can we just run our own copy of WoW to test with?"

Asked 2026-08-24, while the subscription was running out.  Short answer: **a private server does not
solve this problem, and we do not need one.**  The long answer is worth writing down because it keeps
coming back.

## What a local server would and would not give us

| Want | Local emulator | Virtual player (`tools/vplayer.lua`) | Live client |
|---|---|---|---|
| Walk every guide end to end | yes, but one character at a time | **yes, all of them, in minutes** | one at a time, real time |
| Prove the router's order is optimal | no (routing is ours, not the server's) | **yes** | yes, slowly |
| Prove quest/step auto-completion fires | yes | **yes** | yes |
| Prove the real WoW Lua API still answers | **yes** | no | **yes** |
| Prove the frames/arrow actually draw | **yes** | no | **yes** |
| Cost | client patching, a server build per flavor | zero | subscription (except retail F2P) |

Only the bottom two rows are things a server would buy us, and a *free retail client* buys those too.

## Why the emulator route is a dead end here

The open-source cores are fine to use — AzerothCore, TrinityCore, CMaNGOS, VMaNGOS are all published
under open licences and running one locally is ordinary self-hosting.  The problem is the **client**:

* Those cores speak the protocol of *legacy* builds — 1.12.1, 2.4.3, 3.3.5a, 4.3.4, 5.4.8.
* The four clients on this machine are *modern* ones: Classic Era 1.15.x, TBC Anniversary 2.5.x,
  MoP Classic 5.5.x and retail 12.1.x.  None of them can connect to those cores.
* Bridging that gap means either obtaining a legacy client from a third party (that is Blizzard's
  copyrighted client, redistributed without a licence) or patching a modern client's connection and
  certificate checks so it will talk to a server Blizzard did not sign.  Neither is something this
  project will do.

So: **no legacy clients get downloaded for this repo.**  If a legacy client ever arrives through a
licence that actually permits it, AzerothCore + this addon on a 3.3.5a client would be a pleasant
extra test bed — but it is a nice-to-have, not the plan.

## What actually replaces "run a character through every route"

`tools/vplayer.lua` — see [VPLAYER.md](VPLAYER.md).  It runs the real addon against a mutable fake
world and plays every guide to completion: it walks to the current step through the real router,
performs the step's action against the world (accept puts the quest in the log, complete finishes the
objectives, turn-in flags it complete, buy fills the bags), and lets `Progress.Refresh()` advance
exactly as it does in the client.  Every guide, every flavor, no subscription, no server, no
character.  It is also the only method that keeps working after the sub lapses.

## What still needs a real client, and how to keep one

The virtual player cannot prove that Blizzard's own API still answers the way we assume, or that the
frames draw.  For that:

* **Retail stays free.**  The Starter Edition has no time limit and caps at level 20 — but the client,
  the addon, every API we call and every frame we draw are the real thing.  `run_flavor_verify.py`
  still works there; only the sweep's *content* is limited by what a level-20 character can reach.
* **Era / TBC Anniversary / MoP Classic go dark** when the subscription ends.  Everything already
  verified on them is recorded in `docs/verification.sqlite` (`ingame_sweeps`, `feature_runs`), and
  the virtual player covers their guides from here on.
* The last full in-game pass on all four flavors should therefore happen **before** the sub lapses.
  That is the one thing on this project with a real deadline.

#!/usr/bin/env python3
"""Verify ALL FOUR flavors in game, one deliberate launch each, in one hands-free command.

    python3 tools/run_all_flavors.py [--minutes 30] [_retail_ ...] [--collect] [--take-screen]

Order is deliberate: Era, TBC Anniversary and MoP Classic go dark when the subscription lapses, so
they run first; retail stays playable for free (Starter Edition, level 20) and runs last.

Between flavors it sets the launcher's GAME VERSION itself (--version-click), so nothing needs a
human at the keyboard. It refuses to start, and stops between flavors, if a wine/FFXI window is on
screen or a game is running - taking the display from a live session is never worth a verification
run. See docs/LOCAL_SERVER.md for why this cannot be replaced by a private server.
"""
import subprocess, sys, time, functools
print = functools.partial(print, flush=True)
from pathlib import Path
import Quartz

HERE = Path(__file__).resolve().parent
ORDER = ["_classic_era_", "_anniversary_", "_classic_", "_retail_"]


def windows():
    return [(w.get("kCGWindowOwnerName") or "", dict(w.get("kCGWindowBounds") or {}))
            for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly,
                                                       Quartz.kCGNullWindowID)]


def screen_busy(take_screen=False):
    """another game owns the display / the machine - do not take it"""
    if take_screen:
        # explicit go-ahead from Daniel ("you can take over the screen now"). A game left running is
        # not closed - WoW simply comes to the front over it.
        if (Quartz.CGSessionCopyCurrentDictionary() or {}).get("CGSSessionScreenIsLocked"):
            return "screen is locked"
        return None
    for owner, b in windows():
        if owner in ("wine", "FFXI on Mac") and b.get("Width", 0) > 400:
            return f"{owner} window on screen"
    for pat in ("horizon-loader.exe", "FFXiMain"):
        if subprocess.run(["pgrep", "-f", pat], capture_output=True).stdout.strip():
            return f"{pat} is running"
    if (Quartz.CGSessionCopyCurrentDictionary() or {}).get("CGSSessionScreenIsLocked"):
        return "screen is locked"
    return None


def main(argv):
    minutes = 30
    for a in argv:
        if a.startswith("--minutes"):
            minutes = int(a.split("=")[1]) if "=" in a else int(argv[argv.index(a) + 1])
    only = [a for a in argv if a.startswith("_")]
    take = "--take-screen" in argv
    flavors = only or ORDER

    done, skipped = [], []
    for flavor in flavors:
        busy = screen_busy(take)
        if busy:
            print(f"SKIP {flavor}: {busy}")
            skipped.append((flavor, busy))
            continue
        print(f"=== {flavor} ({minutes} min) ===")
        cmd = ["python3", str(HERE / "run_flavor_verify.py"), flavor,
               f"--minutes={minutes}", "--version-click"] + (["--take-screen"] if take else [])
        rc = subprocess.run(cmd).returncode
        (done if rc == 0 else skipped).append((flavor, f"exit {rc}"))
        time.sleep(20)   # let the client and launcher settle before the next one

    if "--collect" in argv:
        subprocess.run(["python3", str(HERE / "collect_verify.py")])
    print("\nran:", ", ".join(f for f, _ in done) or "nothing")
    if skipped:
        print("not run:", ", ".join(f"{f} ({why})" for f, why in skipped))
    return 0 if done and not skipped else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

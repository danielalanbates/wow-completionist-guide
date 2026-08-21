#!/usr/bin/env python3
"""One deliberate verification launch of ONE WoW flavor, end to end, with no typing in the client.

    python3 tools/run_flavor_verify.py _classic_era_ [--no-sweep] [--minutes 7]

Refuses if any WoW client or a wine (FFXI) window is already up. Arms the SavedVariables
(autoVerifyAll + autoSweep), presses Play in the Battle.net launcher (the launcher must already show
the right GAME VERSION - it remembers the last one; change it by hand or with --version-click), waits
for the client window, clicks Enter World on the selected character, screenshots the window every
30 s into docs/screenshots/run_<flavor>_<secs>.png, dismisses the Blizzard "blocked action" popup
if it appears, and after --minutes quits the client from outside (quit from inside is protected).
Then run tools/collect_verify.py (+ tools/sync_progress.lua runs by itself via the launchd agent).
Coordinates: launcher Play button = window origin + (155, 696); Enter World = client centre-bottom.
"""
import subprocess, sys, time, functools
print = functools.partial(print, flush=True)   # log is readable live when redirected to a file
from pathlib import Path
import Quartz

WOW = Path("/Volumes/x10/Video Games/Mac/World of Warcraft")
SHOTS = Path(__file__).resolve().parent.parent / "docs" / "screenshots"
HERE = Path(__file__).resolve().parent

def windows(onscreen=True):
    opt = Quartz.kCGWindowListOptionOnScreenOnly if onscreen else Quartz.kCGWindowListOptionAll
    return [(w.get("kCGWindowOwnerName") or "", w.get("kCGWindowNumber"), dict(w.get("kCGWindowBounds") or {}))
            for w in Quartz.CGWindowListCopyWindowInfo(opt, Quartz.kCGNullWindowID)]

def find(owner_sub, minw=600):
    for o, n, b in windows():
        if owner_sub in o and b.get("Width", 0) > minw: return n, b
    return None, None

def front_is(sub):
    f = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    info = subprocess.run(["lsappinfo", "info", "-only", "name", f], capture_output=True, text=True).stdout
    return sub in info

def click(x, y):
    for t in (Quartz.kCGEventMouseMoved, Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, t, (x, y), Quartz.kCGMouseButtonLeft))
        time.sleep(0.1)

def shot(win, path):
    SHOTS.mkdir(parents=True, exist_ok=True)
    subprocess.run(["screencapture", "-x", "-o", "-l", str(win), str(path)], check=False)

def main(argv):
    flavor = [a for a in argv if not a.startswith("--")][0]
    minutes = 7
    for a in argv:
        if a.startswith("--minutes="): minutes = int(a.split("=")[1])
    if subprocess.run(["pgrep", "-f", "World of Warcraft"], capture_output=True).stdout.strip():
        print("a WoW client is already running - not launching another (one app per variety)"); return 2
    import Quartz as _Q
    if (_Q.CGSessionCopyCurrentDictionary() or {}).get("CGSSessionScreenIsLocked"):
        print("screen is locked - clicks and captures cannot reach the client; unlock (or caffeinate -dimsu) first"); return 2
    subprocess.Popen(["caffeinate", "-dimsu", "-t", str(minutes * 60 + 600)])   # keep display awake for the run
    if any(o == "wine" for o, _, _ in windows()):
        print("FFXI (wine) window on screen - refusing to take over the display"); return 2
    arm = ["python3", str(HERE / "queue_verify.py"), flavor]
    if "--no-sweep" not in argv: arm.append("--sweep")
    arm.append(f"--quit-after={minutes * 60 - 30}")
    subprocess.run(arm, check=False)
    subprocess.run(["open", "/Applications/Battle.net.app"]); time.sleep(6)
    n, b = find("Battle.net", 800)
    if not n: print("no launcher window"); return 1
    if not front_is("Battle.net"): print("launcher not frontmost - not clicking"); return 1
    click(b["X"] + 155, b["Y"] + 696); print("pressed Play")
    t0 = time.time(); win = None
    while time.time() - t0 < 480:
        win, wb = find("Wow")
        if win: break
        time.sleep(5)
    if not win: print("client window never appeared"); return 1
    print("client window", win, wb, "after", int(time.time() - t0), "s")
    time.sleep(45)   # character select
    shot(win, SHOTS / f"run_{flavor.strip('_')}_charselect.png")
    if not front_is("Wow"): print("client not frontmost - not clicking Enter World"); return 1
    sx, sy = wb["Width"], wb["Height"]
    click(wb["X"] + sx * 0.498, wb["Y"] + sy * 0.918)   # Enter World
    print("clicked Enter World")
    start = time.time(); popup_done = False
    while time.time() - start < minutes * 60:
        el = int(time.time() - start)
        win, wb = find("Wow")
        if not win: print("client window gone"); break
        shot(win, SHOTS / f"run_{flavor.strip('_')}_{el:04d}.png")
        time.sleep(30)
    # the Blizzard "blocked from an action" popup (if any) sits under the minimap; Ignore is at ~(0.515, 0.24)
    if win and front_is("Wow"):
        click(wb["X"] + wb["Width"] * 0.5156, wb["Y"] + wb["Height"] * 0.24)
    time.sleep(1)
    subprocess.run(["osascript", "-e", 'tell application "World of Warcraft" to quit'], check=False)
    t1 = time.time()
    while time.time() - t1 < 120 and subprocess.run(["pgrep", "-f", "World of Warcraft"], capture_output=True).stdout.strip():
        time.sleep(3)
    print("client quit; run: python3 tools/collect_verify.py")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

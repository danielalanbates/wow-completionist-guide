#!/usr/bin/env python3
"""Drive a live WoW client to produce the in-game half of the verification chart.

    python3 tools/verify_ingame.py _anniversary_ [_classic_era_ ...]

For each flavor it: refuses to run if FFXI (a `wine` window) is on screen, brings the
Battle.net launcher up, picks the game version, presses Play, waits for the client window,
screenshots it, and quits the client cleanly so SavedVariables flush. CompletionRoute runs
/or verify + /or verifyfeatures on its own 25s/30s after login, so nothing has to be typed.
Afterwards run tools/collect_verify.py to fold the results into docs/verification.sqlite.

Playbook constraints this encodes (learned the hard way, see the memory file):
  * NEVER send synthetic keystrokes unless the target app is verifiably frontmost - WoW steals
    focus and the keys land in whatever is in front, which can be the user's own session.
  * Every foreground shell call re-fronts Terminal, so all clicks for one client must happen
    inside ONE python process after asserting `lsappinfo front` is the client.
  * screencapture -l <window id> works even when the window is occluded; the retina buffer is
    2x, so screenshot pixels are twice the click coordinates.
  * The client can take 3+ minutes to show a window when it loads off the external drive.
  * The CGWindow owner name is "Wow", not "World of Warcraft".
"""
import subprocess, sys, time
from pathlib import Path

WOW = Path("/Volumes/x10/Video Games/Mac/World of Warcraft")
SHOTS = Path(__file__).resolve().parent.parent / "docs" / "screenshots"


def windows():
    import Quartz
    out = []
    for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly,
                                               Quartz.kCGNullWindowID):
        out.append((w.get("kCGWindowOwnerName"), w.get("kCGWindowName"),
                    w.get("kCGWindowNumber"), w.get("kCGWindowBounds")))
    return out


def ffxi_on_screen():
    return any(o == "wine" for o, _, _, _ in windows())


def front_app():
    return subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()


def wait_for(owner, timeout=300):
    end = time.time() + timeout
    while time.time() < end:
        for o, n, num, b in windows():
            if o == owner and b and b["Width"] > 600:
                return num, b
        time.sleep(5)
    return None, None


def shot(window_id, path):
    SHOTS.mkdir(parents=True, exist_ok=True)
    subprocess.run(["screencapture", "-x", "-o", "-l", str(window_id), str(path)], check=False)
    return path


def main(flavors):
    if ffxi_on_screen():
        print("FFXI is on screen - refusing to take over the display. Re-run when it is closed.")
        return 2
    for fl in flavors:
        print(f"== {fl} ==")
        subprocess.run(["open", "-a", "/Applications/Battle.net.app"], check=False)
        time.sleep(30)
        print("  launcher up; front =", front_app())
        print("  NOTE: version selection is a per-page GAME VERSION dropdown (the full product")
        print("  list only appears on the retail page) and clicks need a +30pt window-origin offset.")
        num, b = wait_for("Wow", timeout=420)
        if not num:
            print("  no client window appeared - skipping")
            continue
        print(f"  client window {num} {b}")
        time.sleep(120)   # let CompletionRoute's 25s/30s auto-verifies run after character login
        shot(num, SHOTS / f"verify_{fl.strip('_')}.png")
        subprocess.run(["osascript", "-e", 'tell application "World of Warcraft" to quit'], check=False)
        time.sleep(45)
    print("now run: python3 tools/collect_verify.py")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["_anniversary_"]))

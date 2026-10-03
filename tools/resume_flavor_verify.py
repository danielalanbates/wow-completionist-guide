#!/usr/bin/env python3
"""Resume a run_flavor_verify.py run whose driver bailed AFTER the client came up (e.g. another app stole
focus at character select). Brings the client front, clicks Enter World, then does the same capture /
quit loop as the driver.   python3 tools/resume_flavor_verify.py _retail_ --minutes=30"""
import subprocess, sys, time
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from run_flavor_verify import find, front_is, click, shot, SHOTS

def main(argv):
    flavor = [a for a in argv if not a.startswith("--")][0]
    minutes = int(([a.split("=")[1] for a in argv if a.startswith("--minutes=")] or [7])[0])
    win, wb = find("Wow")
    if not win: print("no client window"); return 1
    subprocess.Popen(["caffeinate", "-dimsu", "-t", str(minutes * 60 + 600)])
    subprocess.run(["osascript", "-e", 'tell application "World of Warcraft" to activate'], check=False); time.sleep(3)   # open -a does not raise it
    if not front_is("Wow"): print("could not bring client front"); return 1
    shot(win, SHOTS / f"run_{flavor.strip('_')}_charselect2.png")
    click(wb["X"] + wb["Width"] * 0.5, wb["Y"] + wb["Height"] * 0.897); print("clicked Enter World", flush=True)
    start = time.time()
    while time.time() - start < minutes * 60:
        el = int(time.time() - start)
        win, wb = find("Wow")
        if not win: print("client window gone", flush=True); break
        shot(win, SHOTS / f"run_{flavor.strip('_')}_{el:04d}.png")
        time.sleep(30)
    if win and front_is("Wow"):
        click(wb["X"] + wb["Width"] * 0.5156, wb["Y"] + wb["Height"] * 0.24)
    time.sleep(1)
    subprocess.run(["osascript", "-e", 'tell application "World of Warcraft" to quit'], check=False)
    t1 = time.time()
    while time.time() - t1 < 120 and subprocess.run(["pgrep", "-f", "World of Warcraft"], capture_output=True).stdout.strip():
        time.sleep(3)
    print("client quit; run: python3 tools/collect_verify.py", flush=True); return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

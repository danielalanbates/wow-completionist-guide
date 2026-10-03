#!/usr/bin/env python3
"""Erase progress that a bulk /cr verifyall sweep wrote into characters' records.

    python3 tools/clean_sweep_progress.py [--apply]

Older builds ran the sweep against the live progress store, so loading all ~9000 guides
auto-completed a step in nearly every one of them. Real progress re-derives from the quest log
on the next login, so clearing these is safe. New builds sandbox the sweep (Account.BeginScratch),
so this is a one-off cleanup.

Heuristic: a character with progress recorded in more than THRESHOLD distinct guides was swept -
a human plays a handful of guides, not four thousand.
"""
import re, sys
from pathlib import Path

WOW = Path("/Volumes/x10/Video Games/Mac/World of Warcraft")
FLAVORS = ["_retail_", "_classic_", "_classic_era_", "_anniversary_"]
THRESHOLD = 50


def guide_counts(blob):
    return len(re.findall(r'\n\["[^"]+"\]\s*=\s*{', blob))


def main(argv):
    apply = "--apply" in argv
    total = 0
    for fl in FLAVORS:
        for sv in (WOW / fl).glob("WTF/Account/*/SavedVariables/CompletionRoute.lua"):
            text = sv.read_text(errors="replace")
            out, changed = [], 0
            # walk each ["done"] / ["skipped"] table and blank the swept ones
            i = 0
            while True:
                m = re.search(r'\["(done|skipped)"\]\s*=\s*{', text[i:])
                if not m:
                    out.append(text[i:])
                    break
                start = i + m.end() - 1
                depth = 0
                for j in range(start, len(text)):
                    if text[j] == "{":
                        depth += 1
                    elif text[j] == "}":
                        depth -= 1
                        if depth == 0:
                            break
                blob = text[start:j + 1]
                n = guide_counts(blob)
                out.append(text[i:start])
                if n > THRESHOLD:
                    out.append("{\n}")
                    changed += 1
                    print(f"  {sv.parent.parent.parent.name}/{sv.name}: cleared {m.group(1)} ({n} guides)")
                else:
                    out.append(blob)
                i = j + 1
            if changed:
                total += changed
                if apply:
                    sv.write_text("".join(out))
    print(("applied" if apply else "dry run - re-run with --apply") + f"; {total} table(s) affected")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

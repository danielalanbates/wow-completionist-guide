#!/usr/bin/env python3
"""Arm the in-client verification sweep for one or more WoW flavors, without typing in the client.

    python3 tools/queue_verify.py _classic_ _retail_ [--quit] [--demo] [--account-wide]

Sets `CompletionRouteDB.autoVerifyAll = true` (and optionally `autoVerifyQuit`) in each flavor's
account-level SavedVariables file. On the next login the addon runs the full guide sweep itself,
saves the result to CompletionRouteDB.verifyAll, and clears the flag. Then run
tools/collect_verify.py to fold everything into docs/verification.sqlite.

Why this exists: driving `/cr verifyall` through synthetic keystrokes is unreliable - WoW's chat
edit box regularly swallows all but the first character, which silently produces no results.
"""
import re, sys
from pathlib import Path

WOW = Path("/Volumes/x10/Video Games/Mac/World of Warcraft")


def arm(sv: Path, also_quit: bool, demo: bool = False, account_wide: bool = False) -> bool:
    text = sv.read_text(errors="replace")
    if not text.lstrip().startswith("CompletionRouteDB"):
        return False
    text = re.sub(r'\n\["auto(VerifyAll|VerifyQuit|Demo)"\][^\n]*\n', "\n", text)
    if account_wide:
        text = re.sub(r'\["accountWide"\]\s*=\s*(true|false)', '["accountWide"] = true', text)
    # insert right after the opening brace of the root table
    i = text.index("{")
    add = '\n["autoVerifyAll"] = true,'
    if demo:
        add += '\n["autoDemo"] = true,'
    if also_quit:
        add += '\n["autoVerifyQuit"] = true,'
    sv.write_text(text[:i + 1] + add + text[i + 1:])
    return True


def main(argv):
    also_quit = "--quit" in argv
    demo = "--demo" in argv
    account_wide = "--account-wide" in argv
    flavors = [a for a in argv if not a.startswith("--")] or ["_anniversary_"]
    n = 0
    for fl in flavors:
        for sv in (WOW / fl).glob("WTF/Account/*/SavedVariables/CompletionRoute.lua"):
            if arm(sv, also_quit, demo, account_wide):
                print("armed", sv)
                n += 1
            else:
                print("skipped (unexpected format)", sv)
    if n == 0:
        print("nothing armed - log in once so the addon writes its SavedVariables first")
        return 1
    print("now launch each flavor once; then: python3 tools/collect_verify.py")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

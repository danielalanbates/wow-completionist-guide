#!/usr/bin/env python3
# CompletionRoute :: tools/test_refresh_changed.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""tools/wiki/refresh_changed.changed_titles: edits and creations are listed, a page move contributes its new
main-namespace title (a moved page makes no edit entry), other log entries and moves into other namespaces do not.
Offline: a fake client, no wiki requests."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "wiki"))
import refresh_changed as rc


class Fake:
    def __init__(self, pages):
        self.pages, self.calls = pages, []

    def get(self, p):
        self.calls.append(p)
        return self.pages[len(self.calls) - 1]


pages = [
    {"query": {"recentchanges": [
        {"type": "edit", "title": "Quest A", "timestamp": "t1"},
        {"type": "log", "logtype": "move", "title": "Old Name", "timestamp": "t2",
         "logparams": {"target_ns": 0, "target_title": "New Name"}},
    ]}, "continue": {"rccontinue": "x", "continue": "-||"}},
    {"query": {"recentchanges": [
        {"type": "new", "title": "Npc B", "timestamp": "t3"},
        {"type": "log", "logtype": "delete", "title": "Gone", "timestamp": "t4", "logparams": {}},
        {"type": "log", "logtype": "move", "title": "Quest C", "timestamp": "t5",
         "logparams": {"target_ns": 2, "target_title": "User:Someone/Quest C"}},
    ]}},
]
cli = Fake(pages)
got = rc.changed_titles(cli, "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z")
fail = 0
if set(got) != {"Quest A", "New Name", "Npc B"}:
    print("FAIL titles", sorted(got)); fail = 1
if "log" not in cli.calls[0]["rctype"] or "loginfo" not in cli.calls[0]["rcprop"]:
    print("FAIL request does not ask for move log entries"); fail = 1
if cli.calls[1].get("rccontinue") != "x":
    print("FAIL continuation not followed"); fail = 1
print("test_refresh_changed: " + ("FAILED" if fail else "ok"))
sys.exit(fail)

#!/usr/bin/env python3
"""Collect /or verifyall results from each flavor's SavedVariables into docs/verification.sqlite.

Usage: python3 tools/collect_verify.py
Reads OpenRouteDB.verifyAll from every WoW flavor's WTF SavedVariables and upserts one
row per run into `runs`, one per failing guide into `failures`. Chart of record for the
"every guide works on every version" goal.
"""
import re, sqlite3, sys
from pathlib import Path

WOW = Path("/Volumes/x10/Video Games/Mac/World of Warcraft")
FLAVORS = ["_retail_", "_classic_", "_classic_era_", "_anniversary_"]
DB = Path(__file__).resolve().parent.parent / "docs" / "verification.sqlite"

def find_sv(flavor_dir):
    return sorted(flavor_dir.glob("WTF/Account/*/SavedVariables/OpenRoute.lua"))

def parse_verifyall(text):
    m = re.search(r'\["verifyAll"\]\s*=\s*{', text)
    if not m:
        return None
    # crude brace-matched slice
    i, depth = m.end() - 1, 0
    for j in range(i, len(text)):
        if text[j] == "{": depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                blob = text[i:j + 1]
                break
    else:
        return None
    def field(name):
        fm = re.search(r'\["%s"\]\s*=\s*"?([^",\n]*)"?,' % name, blob)
        return fm.group(1) if fm else None
    errors = re.findall(r'^\s*"((?:[^"\\]|\\.)*)",\s*$', blob, re.M)
    return {
        "flavor": field("flavor"), "total": int(field("total") or 0),
        "failed": int(field("failed") or 0), "started": field("startedAt"),
        "finished": field("finishedAt"), "errors": errors,
    }

def brace_slice(text, key):
    """Return the {...} blob assigned to ["key"] at any depth, or None."""
    m = re.search(r'\["%s"\]\s*=\s*{' % key, text)
    if not m:
        return None
    i, depth = m.end() - 1, 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    return None


def parse_featureverify(text):
    """OpenRouteDB.featureVerify -> {flavor, build, at, checks:[{feature,name,pass,detail}]}"""
    blob = brace_slice(text, "featureVerify")
    if not blob:
        return None

    def field(name):
        fm = re.search(r'\["%s"\]\s*=\s*"?([^",\n]*)"?,' % name, blob)
        return fm.group(1) if fm else None

    checks = []
    for cm in re.finditer(
            r'{\s*\["detail"\]\s*=\s*"((?:[^"\\]|\\.)*)",\s*\["pass"\]\s*=\s*(true|false),'
            r'\s*\["name"\]\s*=\s*"((?:[^"\\]|\\.)*)",\s*\["feature"\]\s*=\s*"([^"]*)",', blob):
        checks.append({"detail": cm.group(1), "pass": cm.group(2) == "true",
                       "name": cm.group(3), "feature": cm.group(4)})
    if not checks:  # key order is not guaranteed by the SV writer - fall back to a per-entry scan
        for entry in re.finditer(r'{\s*(\[".*?)\s*},', blob, re.S):
            e = entry.group(1)
            def f(k):
                fm = re.search(r'\["%s"\]\s*=\s*"?((?:[^"\\]|\\.)*?)"?,' % k, e, re.S)
                return fm.group(1) if fm else None
            if f("feature"):
                checks.append({"detail": f("detail") or "", "pass": (f("pass") == "true"),
                               "name": f("name") or "", "feature": f("feature")})
    return {"flavor": field("flavor"), "build": field("build"), "at": field("at"),
            "addon": field("addon"), "checks": checks}


def main():
    con = sqlite3.connect(DB)
    con.executescript("""
        CREATE TABLE IF NOT EXISTS runs(
            id INTEGER PRIMARY KEY, flavor TEXT, client_dir TEXT, started TEXT, finished TEXT,
            total INTEGER, ok INTEGER, failed INTEGER, UNIQUE(flavor, started));
        CREATE TABLE IF NOT EXISTS failures(
            run_id INTEGER REFERENCES runs(id), guide_id TEXT, error TEXT);
        CREATE TABLE IF NOT EXISTS feature_runs(
            id INTEGER PRIMARY KEY, flavor TEXT, client_dir TEXT, build TEXT, addon_version TEXT,
            at TEXT, passed INTEGER, failed INTEGER, UNIQUE(flavor, at));
        CREATE TABLE IF NOT EXISTS feature_checks(
            run_id INTEGER REFERENCES feature_runs(id), feature TEXT, name TEXT,
            pass INTEGER, detail TEXT);
        CREATE VIEW IF NOT EXISTS feature_matrix AS
            SELECT r.flavor, c.feature, c.name,
                   MAX(c.pass) AS pass, MAX(r.at) AS last_run
            FROM feature_runs r JOIN feature_checks c ON c.run_id = r.id
            GROUP BY r.flavor, c.feature, c.name;
    """)
    for fl in FLAVORS:
        for sv in find_sv(WOW / fl):
            text = sv.read_text(errors="replace")
            fv = parse_featureverify(text)
            if fv and fv["at"] and fv["checks"]:
                p = sum(1 for c in fv["checks"] if c["pass"])
                cur = con.execute(
                    "INSERT OR IGNORE INTO feature_runs(flavor, client_dir, build, addon_version, at, passed, failed)"
                    " VALUES(?,?,?,?,?,?,?)",
                    (fv["flavor"], fl, fv["build"], fv["addon"], fv["at"], p, len(fv["checks"]) - p))
                if cur.rowcount:
                    rid = cur.lastrowid
                    for c in fv["checks"]:
                        con.execute("INSERT INTO feature_checks(run_id, feature, name, pass, detail)"
                                    " VALUES(?,?,?,?,?)",
                                    (rid, c["feature"], c["name"], 1 if c["pass"] else 0, c["detail"]))
                    print(f"recorded features {fl} {fv['flavor']}: {p}/{len(fv['checks'])} passed")
            r = parse_verifyall(text)
            if not r or not r["finished"]:
                continue
            cur = con.execute(
                "INSERT OR IGNORE INTO runs(flavor, client_dir, started, finished, total, ok, failed)"
                " VALUES(?,?,?,?,?,?,?)",
                (r["flavor"], fl, r["started"], r["finished"], r["total"],
                 r["total"] - r["failed"], r["failed"]))
            if cur.rowcount:
                rid = cur.lastrowid
                for e in r["errors"]:
                    gid, _, err = e.partition(" :: ")
                    con.execute("INSERT INTO failures(run_id, guide_id, error) VALUES(?,?,?)", (rid, gid, err))
                print(f"recorded {fl} {r['flavor']}: {r['total']-r['failed']}/{r['total']} OK, {r['failed']} failed")
    con.commit()
    print("\n-- guide load runs --")
    for row in con.execute("SELECT id, flavor, client_dir, finished, ok, total, failed FROM runs ORDER BY id"):
        print(row)
    print("\n-- feature matrix (flavor x check) --")
    for row in con.execute(
            "SELECT flavor, feature, name, CASE pass WHEN 1 THEN 'PASS' ELSE 'FAIL' END, last_run"
            " FROM feature_matrix ORDER BY feature, name, flavor"):
        print("  %-8s %-8s %-34s %s  %s" % row)
    con.close()

if __name__ == "__main__":
    sys.exit(main())

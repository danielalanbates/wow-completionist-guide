#!/usr/bin/env python3
# CompletionRoute :: tools/check_teleports.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Check every id in CompletionRoute/Data/Teleports.lua against the Blizzard client tables of each flavor it is listed on.

    venv/bin/python tools/check_teleports.py [--cache DIR] [--fetch] [--wiki] [--data PATH]

Per entry and client (an `era` entry is checked on Classic Era AND WoW Forever, which share that code path):
  spell   SpellName[id] is the entry's name; the Rune of Teleportation reagent matches SpellReagents in both directions
  item    ItemSparse[id] is the entry's name; ItemEffect lists the entry's use spell; a 4-hour / 20-minute `cd` matches
          ItemEffect CoolDownMSec; `equip` matches ItemSparse InventoryType 12 (trinket) exactly where it is set
  hearth  a Hearthstone stand-in's use spell shares a cooldown with the Hearthstone (spell 8690): the same non-zero
          SpellCategories Category or ChargeCategory, or the same ItemEffect SpellCategoryID
  --wiki  every cited Warcraft Wiki page exists and holds the cited coordinate ({{Co|x|y|...}})
SpellName / ItemSparse / SpellReagents come from tools/db2/<flavor>/ (read only, tools/wiki/db2_fetch.py makes them).
ItemEffect, ItemXItemEffect, SpellCategories and Toy are not in that set: they are read from --cache (default
tools/teleports_db2/, gitignored) and downloaded there with --fetch, pinned to tools/wiki/fetch_db2.py BUILDS, >= 1.2 s
apart.  Without them the item and hearth checks are reported as skipped.  Exit status 1 on any mismatch.
"""
import csv, json, re, subprocess, sys, time, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DB2 = ROOT / "tools" / "db2"
sys.path.insert(0, str(ROOT / "tools" / "wiki"))
from fetch_db2 import BUILDS  # noqa: E402

csv.field_size_limit(1 << 28)
UA = "Mozilla/5.0 (compatible; db2-check)"
CLIENTS = {"era": ["era", "forever"], "tbc": ["tbc"], "mop": ["mop"], "retail": ["retail"]}
HEARTH_ITEM, HEARTH_SPELL = 6948, 8690

DUMP = r"""
local NS = {}
assert(loadfile(DATA_PATH))("CompletionRoute", NS)
local function enc(v)
    local t = type(v)
    if t == "string" then return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"' end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t ~= "table" then return "null" end
    if #v > 0 or next(v) == nil then
        local o = {} for i = 1, #v do o[i] = enc(v[i]) end
        local extra = {}
        for k, x in pairs(v) do if type(k) ~= "number" then extra[#extra + 1] = enc(tostring(k)) .. ":" .. enc(x) end end
        if #extra > 0 then for i = 1, #v do extra[#extra + 1] = enc(tostring(i)) .. ":" .. o[i] end return "{" .. table.concat(extra, ",") .. "}" end
        return "[" .. table.concat(o, ",") .. "]"
    end
    local o = {} for k, x in pairs(v) do o[#o + 1] = enc(tostring(k)) .. ":" .. enc(x) end
    return "{" .. table.concat(o, ",") .. "}"
end
local out = {}
for i, e in ipairs(NS.TeleportData) do local c = {} for k, v in pairs(e) do if type(v) ~= "function" then c[k] = v end end out[i] = enc(c) end
print("[" .. table.concat(out, ",") .. "]")
"""


def entries(path):
    lua = "DATA_PATH = " + json.dumps(str(path)) + "\n" + DUMP
    r = subprocess.run(["luajit", "-e", lua], cwd=ROOT, capture_output=True, text=True, check=True)
    return json.loads(r.stdout)


def read_rows(path, want_col, want_ids):
    """rows of a CSV whose `want_col` is in want_ids (None = all), keyed by that id (list of rows)"""
    out = {}
    if not path.exists():
        return None
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            try:
                k = int(row[want_col])
            except (KeyError, ValueError):
                continue
            if want_ids is None or k in want_ids:
                out.setdefault(k, []).append(row)
    return out


def fetch(cache, flavor, table):
    p = cache / flavor / f"{table}.csv"
    miss = p.with_suffix(".missing")
    if p.exists() or miss.exists():
        return p
    p.parent.mkdir(parents=True, exist_ok=True)
    time.sleep(1.2)
    url = f"https://wago.tools/db2/{table}/csv?build={BUILDS[flavor][1]}"
    r = subprocess.run(["curl", "-sS", "-L", "--compressed", "-m", "300", "-A", UA, "-w", "%{http_code}", "-o", str(p) + ".part", url],
                       capture_output=True, text=True)
    part = Path(str(p) + ".part")
    if r.returncode == 0 and r.stdout.strip() == "200" and part.stat().st_size > 50:
        part.replace(p)
    else:
        part.unlink(missing_ok=True)
        if r.stdout.strip() in ("400", "404"):
            miss.write_text(r.stdout.strip())
        else:
            raise RuntimeError(f"{url}: curl={r.returncode} http={r.stdout.strip()} {r.stderr.strip()}")
    return p


def wiki_page(cache, title):
    p = cache / "wiki" / (re.sub(r"[^A-Za-z0-9]+", "_", title) + ".json")
    if not p.exists():
        p.parent.mkdir(parents=True, exist_ok=True)
        time.sleep(1.2)
        url = "https://warcraft.wiki.gg/api.php?" + urllib.parse.urlencode(
            {"action": "parse", "page": title, "prop": "wikitext", "format": "json", "formatversion": 2, "redirects": 1})
        body = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=60).read()
        p.write_bytes(body)
    d = json.loads(p.read_text())
    return d.get("parse", {}).get("wikitext", "")


def main():
    args = sys.argv[1:]
    cache = Path(args[args.index("--cache") + 1]) if "--cache" in args else ROOT / "tools" / "teleports_db2"
    do_fetch, do_wiki = "--fetch" in args, "--wiki" in args
    data = entries(Path(args[args.index("--data") + 1]).resolve() if "--data" in args else ROOT / "CompletionRoute" / "Data" / "Teleports.lua")
    spells, items = set(), set()
    for e in data:
        (spells if e["kind"] == "spell" else items).add(int(e["id"]))
        if e.get("spell"):
            spells.add(int(e["spell"]))
    spells.add(HEARTH_SPELL)
    items.add(HEARTH_ITEM)
    fails, skipped, checked = [], set(), 0
    for fl in ["era", "forever", "tbc", "mop", "retail"]:
        names = read_rows(DB2 / fl / "SpellName.csv", "ID", spells) or {}
        sparse = read_rows(DB2 / fl / "ItemSparse.csv", "ID", items) or {}
        reagents = read_rows(DB2 / fl / "SpellReagents.csv", "SpellID", spells) or {}
        extra = {}
        for t in ("ItemEffect", "ItemXItemEffect", "SpellCategories", "Toy"):
            p = fetch(cache, fl, t) if do_fetch else cache / fl / f"{t}.csv"
            extra[t] = p if p.exists() else None
        effects = None
        if extra["ItemEffect"]:
            rows = read_rows(extra["ItemEffect"], "ID", None) or {}
            first = next(iter(rows.values()))[0] if rows else {}
            effects = {}
            if "ParentItemID" in first:
                for rs in rows.values():
                    for r in rs:
                        effects.setdefault(int(r["ParentItemID"]), []).append(r)
            elif extra["ItemXItemEffect"]:
                for iid, xs in (read_rows(extra["ItemXItemEffect"], "ItemID", items) or {}).items():
                    for x in xs:
                        for r in rows.get(int(x["ItemEffectID"]), []):
                            effects.setdefault(iid, []).append(r)
        cats = read_rows(extra["SpellCategories"], "SpellID", spells) if extra["SpellCategories"] else None
        toys = set((read_rows(extra["Toy"], "ItemID", items) or {}).keys()) if extra["Toy"] else set()

        def catset(spell):
            s = set()
            for r in (cats or {}).get(spell, []):
                for k in ("Category", "ChargeCategory"):
                    if r.get(k) not in (None, "", "0"):
                        s.add((k, r[k]))
            return s

        hearth_cats = catset(HEARTH_SPELL)
        hearth_eff = {r["SpellCategoryID"] for r in (effects or {}).get(HEARTH_ITEM, []) if r.get("SpellCategoryID") not in (None, "", "0")}
        for e in data:
            flavors = [c for f, on in (e.get("flavors") or {}).items() if on for c in CLIENTS.get(f, [])]
            if fl not in flavors:
                continue
            checked += 1
            key, iid = e["key"], int(e["id"])
            want = (e.get("names") or {}).get("retail" if fl == "retail" else fl, e["name"])
            bad = []
            if e["kind"] == "spell":
                got = names.get(iid, [{}])[0].get("Name_lang")
                if got != want:
                    bad.append(f"SpellName {iid} = {got!r}, data says {want!r}")
                rg = set()
                for r in reagents.get(iid, []):
                    for i in range(8):
                        v = r.get(f"Reagent_{i}")
                        if v not in (None, "", "0"):
                            rg.add(int(v))
                need = (e.get("reagent") or {}).get(fl)
                if need and int(need) not in rg:
                    bad.append(f"reagent {need} not in SpellReagents {sorted(rg)}")
                if not need and rg:
                    bad.append(f"SpellReagents lists {sorted(rg)} but the data has no reagent")
            else:
                row = sparse.get(iid, [{}])[0]
                if row.get("Display_lang") != want:
                    bad.append(f"ItemSparse {iid} = {row.get('Display_lang')!r}, data says {want!r}")
                if row:
                    trinket = row.get("InventoryType") == "12"
                    worn = bool((e.get("equip") or {}).get(fl))
                    if trinket != worn:
                        bad.append(f"InventoryType {row.get('InventoryType')} but equip = {worn}")
                if effects is None:
                    skipped.add(fl + " ItemEffect")
                else:
                    effs = effects.get(iid, [])
                    sp = {int(r["SpellID"]) for r in effs}
                    if int(e["spell"]) not in sp:
                        bad.append(f"ItemEffect spells {sorted(sp)} lack {e['spell']}")
                    if e.get("cd"):
                        cds = {int(r["CoolDownMSec"]) for r in effs if int(r["SpellID"]) == int(e["spell"])}
                        if cds and max(cds) > 0 and int(e["cd"]) * 1000 not in cds:
                            bad.append(f"cooldown {e['cd']} s, ItemEffect CoolDownMSec {sorted(cds)}")
                    if e.get("hearth"):
                        eff_cats = {r["SpellCategoryID"] for r in effs if r.get("SpellCategoryID") not in (None, "", "0")}
                        if cats is None:
                            skipped.add(fl + " SpellCategories")
                        elif not ((catset(int(e["spell"])) & hearth_cats) or (eff_cats & hearth_eff)):
                            bad.append(f"spell {e['spell']} shares no cooldown category with the Hearthstone ({sorted(hearth_cats)} / {sorted(hearth_eff)})")
            status = "FAIL " + "; ".join(bad) if bad else "ok"
            toy = " toy" if iid in toys else ""
            print(f"{fl:8} {key:28} {e['kind']:5} {iid:>8}{toy:4} {status}")
            if bad:
                fails.append(f"{fl} {key}: {'; '.join(bad)}")
    if do_wiki:
        co = re.compile(r"\{\{\s*co(?:ords)?\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|", re.I)
        for e in data:
            pages = list(e.get("wiki") or [])
            if not pages:
                src = e.get("src", "")
                m = re.match(r"wiki (.+?)(?: \(|;|$)", src)
                pages = [m.group(1).strip()] if m else []
                pm = re.search(r"point: wiki ([^);]+)", src)
                if pm:
                    pages.append(pm.group(1).strip())
            if not pages:
                fails.append(f"wiki {e['key']}: no page cited")
                print(f"wiki     {e['key']:28} FAIL no page cited")
                continue
            texts = [wiki_page(cache, t) for t in pages]
            bad = [t for t, x in zip(pages, texts) if not x]
            if e.get("hearth"):
                ok = (not bad) and (e["name"] in texts[0])
                what = f"names {e['name']!r}"
            else:
                ok = (not bad) and re.search(r"(?<!\d)%d(?!\d)" % int(e["id"]), texts[0]) is not None
                what = f"has id {e['id']}"
            q = (e.get("cond") or {}).get("quest") if isinstance(e.get("cond"), dict) else None
            if ok and isinstance(q, int):
                if any(re.search(r"(?<!\d)%d(?!\d)" % q, x) for x in texts):
                    what += f", quest {q}"
                else:
                    ok, what = False, f"cond quest {q} on none of the pages"
            cite = e.get("cite")
            if ok and isinstance(cite, list) and len(cite) == 3:
                pts = [(float(a), float(b)) for x in texts for a, b in co.findall(x)]
                if not any(abs(a - cite[1]) < 0.001 and abs(b - cite[2]) < 0.001 for a, b in pts):
                    ok, what = False, f"no {{{{Co|{fmt(cite[1])}|{fmt(cite[2])}|...}}}}"
                else:
                    what += f", Co {fmt(cite[1])},{fmt(cite[2])}"
            if bad:
                what = f"missing page(s) {bad}"
            print(f"wiki     {e['key']:28} {'ok  ' if ok else 'FAIL'} {pages[0]}: {what}")
            if not ok:
                fails.append(f"wiki {e['key']}: {pages}: {what}")
    print(f"\n{checked} entry-client checks, {len(fails)} failed" + (f"; skipped (no table, use --fetch): {', '.join(sorted(skipped))}" if skipped else ""))
    for f in fails:
        print("  " + f)
    sys.exit(1 if fails else 0)


def fmt(v):
    return ("%g" % v) if isinstance(v, (int, float)) else str(v)


if __name__ == "__main__":
    main()

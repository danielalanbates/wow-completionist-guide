# CompletionRoute :: tools/wiki/wikitext.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Small, tolerant MediaWiki wikitext helpers (no third-party deps) used by parse_wiki.py.

Only the shapes Warcraft Wiki actually uses are handled: balanced {{templates}} with nested
templates/links in their values, [[links|labels]], {{Coords|x|y|Zone|...}} / {{co|...}}, level-2 sections
and '*' bullets.  Everything is best-effort; callers count what fails.
"""
import html
import re

RE_LINK = re.compile(r"\[\[([^\[\]|]+)(?:\|([^\[\]]*))?\]\]")
RE_COORD = re.compile(r"\{\{\s*(?:co|coords|coord)\s*\|([^{}]*)\}\}", re.I)
RE_HEAD2 = re.compile(r"^==\s*([^=].*?)\s*==\s*$", re.M)
RE_NUM = re.compile(r"^-?\d+(?:\.\d+)?$")
NON_ARTICLE = ("file:", "image:", "category:", "media:", "wikipedia:", "wowpedia:", "user:", "template:", "special:",
               "help:", "warcraft wiki:", "w:", "wp:")
LANG = re.compile(r"^[a-z]{2}(?:-[a-z]+)?:")


def norm_title(t):
    """canonical page title: entities decoded, '_' -> ' ', anchor dropped, first letter upper"""
    t = html.unescape(t or "").replace("_", " ").split("#", 1)[0].strip()
    t = re.sub(r"\s+", " ", t)
    if t.startswith(":"):
        t = t[1:].strip()
    return t[:1].upper() + t[1:] if t else t


def find_templates(text, name_re):
    """yield (start, end, name, body) for every balanced {{name...}} whose name matches name_re (compiled,
    matched case-insensitively against the stripped name)"""
    i, n = 0, len(text)
    while True:
        i = text.find("{{", i)
        if i < 0:
            return
        j, depth = i, 0
        while j < n - 1:
            two = text[j:j + 2]
            if two == "{{":
                depth += 1
                j += 2
            elif two == "}}":
                depth -= 1
                j += 2
                if depth == 0:
                    break
            else:
                j += 1
        if depth != 0:
            return
        inner = text[i + 2:j - 2]
        nm = re.split(r"[|\n]", inner, 1)[0].strip()
        if name_re.fullmatch(nm):
            yield i, j, nm, inner
            i = j
        else:
            i += 2


def split_params(inner):
    """split a template body at top-level '|' -> (positional list, named dict); first piece = name"""
    parts, buf, d_t, d_l, k = [], [], 0, 0, 0
    s = inner
    while k < len(s):
        two = s[k:k + 2]
        if two == "{{":
            d_t += 1; buf.append(two); k += 2; continue
        if two == "}}":
            d_t -= 1; buf.append(two); k += 2; continue
        if two == "[[":
            d_l += 1; buf.append(two); k += 2; continue
        if two == "]]":
            d_l -= 1; buf.append(two); k += 2; continue
        c = s[k]
        if c == "|" and d_t == 0 and d_l == 0:
            parts.append("".join(buf)); buf = []
        else:
            buf.append(c)
        k += 1
    parts.append("".join(buf))
    pos, named = [], {}
    for p in parts[1:]:
        m = re.match(r"^\s*([\w\- ]+?)\s*=(.*)$", p, re.S)
        if m and "[[" not in m.group(1) and "{{" not in m.group(1):
            named[m.group(1).strip().lower()] = m.group(2).strip()
        else:
            pos.append(p.strip())
    return pos, named


def links(text):
    """[(target_title, label)] for article links (no files/categories/interwiki)"""
    out = []
    for m in RE_LINK.finditer(text or ""):
        tgt = m.group(1).strip()
        low = tgt.lower().lstrip(":")
        if low.startswith(NON_ARTICLE) or LANG.match(low):
            continue
        out.append((norm_title(tgt), (m.group(2) or tgt).strip()))
    return out


def coords(text):
    """[(x, y, zone, start, end)] for every {{Coords}}/{{co}} with numeric x,y and a zone"""
    out = []
    for m in RE_COORD.finditer(text or ""):
        pos, named = split_params("x|" + m.group(1))
        if len(pos) < 2:
            continue
        x, y = pos[0].strip().replace(",", "."), pos[1].strip().replace(",", ".")
        if not (RE_NUM.match(x) and RE_NUM.match(y)):
            continue
        zone = pos[2].strip() if len(pos) > 2 else ""
        zone = zone.replace("[[", "").replace("]]", "").split("|")[0].strip()
        fx, fy = float(x), float(y)
        if not (0 <= fx <= 100 and 0 <= fy <= 100):
            continue
        out.append((fx, fy, html.unescape(zone), m.start(), m.end()))
    return out


def sections(text):
    """{lower-case level-2 heading: body}; '' = the lead before the first heading"""
    out = {}
    heads = list(RE_HEAD2.finditer(text))
    out[""] = text[:heads[0].start()] if heads else text
    for i, h in enumerate(heads):
        body = text[h.end():heads[i + 1].start() if i + 1 < len(heads) else len(text)]
        key = h.group(1).strip().lower()
        if key not in out:
            out[key] = body
    return out


def plain(text):
    """wikitext -> short plain text for step notes (links -> labels, templates dropped, no '|')"""
    t = text or ""
    t = re.sub(r"<ref[^>]*/>", "", t)
    t = re.sub(r"<ref.*?</ref>", "", t, flags=re.S)
    t = re.sub(r"<!--.*?-->", "", t, flags=re.S)
    t = re.sub(r"<br\s*/?>", " ", t, flags=re.I)
    t = re.sub(r"<[^>]+>", "", t)
    t = RE_COORD.sub("", t)
    # simple display templates -> their last positional value ({{NPC||Name}}, {{Au|Name}}, {{item|Name}})
    for _ in range(3):
        t = re.sub(r"\{\{\s*(?:npc|au|item|itemlink|quest|questlong|loot|spell|achievement|faction|cost|money)\s*\|([^{}]*)\}\}",
                   lambda m: [p for p in m.group(1).split("|") if p.strip() and "=" not in p][-1:][0]
                   if [p for p in m.group(1).split("|") if p.strip() and "=" not in p] else "", t, flags=re.I)
        t = re.sub(r"\{\{[^{}]*\}\}", "", t)
    t = RE_LINK.sub(lambda m: (m.group(2) or m.group(1)).strip(), t)
    t = t.replace("'''", "").replace("''", "")
    t = html.unescape(t).replace("|", "/").replace("\n", " ")
    t = re.sub(r"\s+", " ", t).strip()
    return t

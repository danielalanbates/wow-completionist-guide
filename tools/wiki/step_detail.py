# CompletionRoute :: tools/wiki/step_detail.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""What a step with no map point says instead of a bare "No coordinates on the wiki" (tools/wiki/gen_wiki_guides.py).

The wiki often knows where a step is done without giving a coordinate.  In this order:
  1. "npc"    where the NPC or object stands, from its own page: the lead sentence ("... is a dwarf quest giver located
              at Whelgar's Excavation Site in the Wetlands."), else its infobox location field ("The wiki lists Bijou
              at Tazz'Alor, Lower Blackrock Spire.").  For an item objective, the page of what drops it.
              Classic clients (era, tbc, forever) never get a later place: a page that says its NPC stood elsewhere
              before the Cataclysm gives only that earlier place (Gen.place_links / Places.MOVED), a "formerly ..." part
              of the location field comes first, and a text that links a place made or moved in a later patch
              (Places.POST_CATA) or speaks of later times is not used.  MoP and Retail never take a "formerly" part.
              A text whose linked maps all disagree with the zone the generator chose for the step is not used.
  2. "quest"  the quest page's own directions: for a turn-in the Objectives sentence that names the ender and a place;
              for an objective the sentences of ==Notes== / ==Walkthrough== / ==Description== that name a place or a
              direction (at most two; a whole description is never quoted), else the Objectives sentence.
  3. nothing: the caller keeps the zone-level note it wrote before.
The detail is at most MAX_DETAIL characters, whole sentences only, and the whole note (what the step said, the
sentence that there is no exact spot, the detail) at most NOTE_CAP: the card shows 8 lines of a note, and a note of
that length fits them from a window 300 wide on (text model of tools/audit_step_text.lua); at the least width (240)
the card still cuts the last lines of the longest ones (the tooltip and the Details panel show every note whole).
A detail that does not fit is shortened by whole sentences or left out (room()).
Classic clients, beyond the rules of 1: a page that says where its NPC stood earlier ("was formerly located at ...",
"originally found in ...", "Before the Cataclysm, she was a quest giver in ...": RE_EARLIER) gives only that place, in
the "The wiki lists X at Y." form; a text that names a zone or place the client does not have (later_text) is not
used; "was a ... located in" is told in the present (the NPC is there on that client); the Alterac places the wiki
now files under the Hillsbrad Foothills are in the Alterac Mountains (CLASSIC_WORDS).
A step's NPC must be the one the text is about: a title that leads to another NPC's page is used only when the text
names the step's NPC in full.  An item's source always starts "Comes from <name>.".
The quest's own words: a Description sentence (the quest giver talking) needs a verb of going or finding and a
direction or place; in the first person (in the Notes too: quoted speech), a compass direction or a linked place
and a verb of going after "you" or at its start.  An Objectives sentence whose only
place is where the quest is handed in ("... to Galvan the Ancient in Stranglethorn") says nothing about an objective
and is not used for one.  A sentence that ends in ":" (a list or quote followed), or of under five words, is left out.
A detail that quotes coordinates from the wiki's prose is written without the "No exact spot" sentence.
No wiki markup, "|" or line break can reach a note: clean_sentence() returns None for a sentence it cannot render (a <name>, <class>, $N or gender placeholder that is not
a plain form of address, a template or bracket left over), and such a sentence is left out.
"""
import html
import re

import wikimaps
import wikitext as WT

NO_SPOT = "No exact spot on the wiki."      # the honest part: there is no exact point (tools/gen_completion_guides.py reads it)
MAX_DETAIL = 220
NOTE_CAP = 230                              # the whole note of a step with no point (see the module text)
PH = "\x00"                                 # a quest-text placeholder (<name>, $N, {{g|..}}) while a sentence is cleaned

# templates that stand for a word of the sentence: rendered as their last unnamed value
VALUE_TEMPLATES = {"npc", "au", "item", "itemlink", "quest", "questlong", "loot", "spell", "achievement", "faction", "c",
                   "mob", "object", "zone", "race", "class", "rep", "reputation"}
GENDER_TEMPLATES = {"g", "gender"}
# templates that add nothing to the words around them (coordinates, badges, editor marks)
SILENT_TEMPLATES = re.compile(r"co|coords?|sic|title|ref.*|.*-inline|.*-section|fact|citation needed|cn|verify|clr|-|"
                              r"stub.*|expac|classic only.*|removed.*|patch.*|#.*")
# a sentence left hanging where a coordinate or template was taken out ("found at .")
RE_DANGLING = re.compile(r"\b(?:at|in|of|to|the|from|near|and|or|a|an|by|on|around)\s*[.,;:!?)]|\(\s*[,;.]|[,;]\s*[.,;]")
HTML_TAGS = ("br|ref|small|big|sup|sub|span|div|nowiki|s|u|i|b|code|poem|blockquote|references|onlyinclude|noinclude|"
             "includeonly|gallery|center|font|tt|del|ins|p|li|ul|ol|table|tr|td|th|hr|math|pre|abbr|cite|q|em|strong")
RE_PLACEHOLDER = re.compile(r"<(?!\s*/?\s*(?:" + HTML_TAGS + r")\b)[^<>\n]{1,60}>|\$[A-Za-z]\b|\$[gG][^;\n]{0,40};")
RE_COMPASS = re.compile(r"\b(?:north|south|east|west)(?:ern|east|west|eastern|western|ward|wards)?\b|"
                        r"\b(?:northeast|northwest|southeast|southwest)(?:ern)?\b", re.I)
RE_CUE = re.compile(r"\b(?:near|nearby|inside|outside|beneath|behind|beyond|across|atop|upstairs|downstairs|entrance|"
                    r"cave|cavern|tower|camp|ruins?|mine|island|isle|coast|shore|beach|road|bridge|lake|river|hills?|"
                    r"valley|village|town|farm|keep|temple|inn|house|hut|tent|dock|docks|ramp|path|gate|gates|floor|"
                    r"basement|cellar|top of|bottom of|foot of|edge of|next to|in front of|between|center of|"
                    r"middle of)\b", re.I)
# where something is: the words of Gen.PRESENT (a lead sentence that says the subject is at a place)
# a sentence that sends the player somewhere or says where a thing is (with a linked place it counts as a direction)
RE_GO = re.compile(r"\b(?:go|head|travel|enter|find|found|search|look|seek|located|lies?|venture|journey|drops?|dropped|"
                   r"spawns?|kill|slay|gather|collect|hunt|follow|cross|climb|reach|explore|scout|visit)\b", re.I)
RE_VERB = re.compile(r"\b(?:is|are|was|were|be|can|could|will|would|has|have|had|should|must|may|might|do|does|need|needs|"
                     r"use|take|bring|speak|talk|get|make|come|comes|stand|stands|wander|wanders|roam|roams|patrol|patrols|"
                     r"swim|walk|run|ride|fly|turn|jump|open|click|loot|wait|start|starts)\b", re.I)
RE_FIRST_PERSON = re.compile(r"\b(?:I|me|my|mine|we|us|our|I'm|I've|I'll|I'd|we're|we've|we'll)\b")
# coordinates quoted in the wiki's prose: "(coordinates 33,36)", "at (26,60)"
RE_COORDS = re.compile(r"\(\s*(?:coord(?:inate)?s?:?\s*)?\d{1,2}(?:\.\d+)?\s*,\s*\d{1,2}(?:\.\d+)?\s*\)|"
                       r"\bcoord(?:inate)?s?:?\s*\d{1,2}(?:\.\d+)?\s*,\s*\d", re.I)
# an Objectives sentence's hand-in part: "to Galvan the Ancient in Stranglethorn", "return to Thotar in Razor Hill"
RE_HAND_IN = re.compile(r",?\s*(?:(?:and|then)\s+)?(?:\b(?:return|bring|take|deliver|give|report|speak|talk)\b[^.,;]*?\s)?"
                        r"\b(?:to|for|with)\s+(?:(?:(?:the|an?)\s+)?[A-Z][\w'-]*(?:\s+(?:[A-Z][\w'-]*|the|of|von|van|del|de))*|"
                        r"him|her|them)"
                        r"(?:\s+(?:in|at|near|outside|inside|on|of|within)\s+[^.;]*)?(?=[.;]|$)")
# Classic clients: a page that says where its NPC stood earlier.  Group 2, 3 or 4 is the rest of the sentence, whose links
# name that place (group 1 is empty).  (Places.MOVED, which the points use, is narrower and is not changed.)
RE_EARLIER = re.compile(
    r"\bused to (?:(?:be\s+)?(?:located|found|stand|live|reside)\b|be\s+(?=(?:in|at|inside|near)\s))()([^.\n]*)|"
    r"\b(?:formerly|originally|previously)\b,?\s[^.\n]{0,60}?\b(?:located|found|resid(?:ed|ing|es)|stood|standing|"
    r"stationed|appear(?:ed|s)?|seen|lived|(?:was|were)\s+(?=(?:just\s+)?(?:in|at|inside|near|outside|north|south|east|"
    r"west))|(?<=ly\s)(?=(?:in|at|inside|near|outside)\s))([^.\n]*)|"
    r"\b(?:before|prior to)\s[^.\n]{0,40}?(?:cataclysm|shattering)(?:\]\])?,?\s+(?:[\w'-]+\s+){0,5}?(?:was|were)\b([^.\n]*?\b(?:in|at|inside|near)\s+"
    r"(?:the\s+)?\[\[[^.\n]*)", re.I)
# Retail zones that are subzones under the same name on the Classic clients: naming one is not naming a later place
# ... and the part that says who asks: "Fleet Master Seahorn in Booty Bay wants you to"
RE_GIVER = re.compile(r"^[A-Z][^.,;]*?\s(?:in|at|of|near|outside)\s[^.;]*?\b(?:wants|needs|would like|has asked|asks|"
                      r"requests|is asking)\b")
RE_WHERE = re.compile(r"\b(?:in|at|inside|near|outside|around|throughout|along|beneath|within)\s+(?:the\s+)?[A-Z]")
CLASSIC_SUBZONES = {"campnarache", "deathknell", "echoisles", "northshire", "shadowglen", "valleyoftrials",
                    "coldridgevalley", "ammenvale", "sunstriderisle"}
# places a Classic client does not have that are not zone maps of Retail (or are, under a name the client resolves)
LATER_PLACES = ("Darkmoon Island", "Speedbarge", "Ruins of Auberdine", "Ruins of Southshore", "Icecrown Citadel", "Dalaran",
                "New Kargath", "Lor'danel")
# ... and the ones a quest's own text may name (a quest text of an old client may speak of Dalaran or Gilneas)
LATER_QUEST_PLACES = ("Cape of Stranglethorn", "Northern Stranglethorn", "Northern Barrens", "Southern Barrens",
                      "Ruins of Gilneas", "Ruins of Auberdine", "Ruins of Southshore", "Speedbarge", "Darkmoon Island",
                      "Lor'danel", "New Kargath", "Dalaran Crater")
# Classic clients: the Alterac Mountains are a zone of their own (the wiki files their places under Hillsbrad since 4.0.3)
CLASSIC_WORDS = ((re.compile(r"\b(Alterac Valley|Ruins of Alterac)( in (?:the )?)Hillsbrad Foothills\b"), r"\1\2Alterac Mountains"),)
# wiki notes about taking or handing in the quest, not about doing it
RE_NOT_OBJECTIVE = re.compile(r"\b(?:pick(?:ed)? up (?:this|the) quest|quest (?:is|can be|may be) (?:obtained|picked up|started|"
                              r"accepted)|turn(?:ed)? in|hand(?:ed)? in|prerequisite|rewards?|experience|reputation|patch)\b", re.I)
# "is an earth spirit at [[Kodo Rock]]": a lead that places its subject without one of the words of Gen.PRESENT
RE_IS_AT = re.compile(r"\b(?:is|are|was|were)\b[^.\[\]]{0,60}?\b(?:in|at|on|near|inside|outside|within)\s+(?:the\s+)?(?=\[\[)", re.I)
RE_LATER = re.compile(r"\b(?:cataclysm|shattering|during the|after the|now|currently|later|since)\b", re.I)
RE_FORMER = re.compile(r"\b(?:formerly|previously|originally)\b:?", re.I)
RE_NOPLACE = re.compile(r"^\W*(?:unknown|various|varies|none|n/?a|deceased|see below|multiple)\b|#Locations|\(lore\)", re.I)
UNI = {"‘": "'", "’": "'", "“": '"', "”": '"', "–": "-", "—": "-", "…": "...",
       " ": " ", "​": "", "‎": "", "﻿": ""}


def strip_blocks(text):
    """wikitext with the parts that are never prose taken out: comments, references, galleries, tables, headings,
    file / category / interwiki links (their captions nest links), and every template (a value template becomes its
    word, a gender template the placeholder mark, any other nothing)."""
    t = text or ""
    t = re.sub(r"<!--.*?-->", "", t, flags=re.S)
    t = re.sub(r"<ref[^>]*/>", "", t)
    t = re.sub(r"<ref.*?</ref>", "", t, flags=re.S | re.I)
    t = re.sub(r"<gallery.*?</gallery>", "", t, flags=re.S | re.I)
    t = re.sub(r"<nowiki>.*?</nowiki>", "", t, flags=re.S | re.I)
    out, i, low = [], 0, t.lower()
    while True:                                 # [[File:..|caption with [[links]]]]
        m = re.compile(r"\[\[\s*:?\s*(?:file|image|category|media|[a-z]{2}(?:-[a-z]+)?)\s*:").search(low, i)
        if not m:
            out.append(t[i:])
            break
        out.append(t[i:m.start()])
        j, depth = m.start(), 0
        while j < len(t):
            two = t[j:j + 2]
            if two == "[[":
                depth += 1
                j += 2
            elif two == "]]":
                depth -= 1
                j += 2
                if depth == 0:
                    break
            else:
                j += 1
        i = j
    t = "".join(out)

    def tmpl(m):
        parts = m.group(1).split("|")
        name = parts[0].strip().lower()
        if name in GENDER_TEMPLATES:
            return PH
        if name in VALUE_TEMPLATES:
            vals = [p.strip() for p in parts[1:] if p.strip() and "=" not in p]
            return vals[-1] if vals else ""
        if SILENT_TEMPLATES.fullmatch(name):
            return ""
        # any other template in the middle of a sentence stood for a word of it ("Kill at least level {{x}} enemies"):
        # the sentence cannot be rendered
        line_a = m.string.rfind("\n", 0, m.start()) + 1
        line_b = m.string.find("\n", m.end())
        before = m.string[line_a:m.start()].strip(" *#:")
        after = m.string[m.end():line_b if line_b >= 0 else len(m.string)].strip()
        return PH if (before and after[:1].isalnum()) else ""
    for _ in range(8):
        t2 = re.sub(r"\{\{([^{}]*)\}\}", tmpl, t)
        if t2 == t:
            break
        t = t2
    t = re.sub(r"__[A-Z]+__", "", t)
    keep = []
    for ln in t.split("\n"):
        s = ln.strip()
        if s.startswith(("{|", "|", "!", "=", ";")):
            continue
        keep.append(re.sub(r"^[*#:]+\s*", "", s))
    return "\n".join(keep)


def raw_sentences(text):
    """the sentences of a wikitext passage, still with their [[links]] (strip_blocks first), in order"""
    out = []
    for para in strip_blocks(text).split("\n"):
        para = re.sub(r"<br\s*/?>", " ", para, flags=re.I).strip()
        if not para:
            continue
        for s in re.split(r"(?<=[.!?])[\"']{0,3}\s+(?=[\"'\[A-Z0-9<])", para):
            if s.strip():
                out.append(s.strip())
    return out


def clean_sentence(raw, lo=12, hi=MAX_DETAIL):
    """one raw sentence -> plain text for a step note, or None when it cannot be rendered cleanly or is not between
    lo and hi characters.  A placeholder used as a form of address (", <name>") is taken out; any other placeholder
    drops the sentence."""
    t = RE_PLACEHOLDER.sub(PH, raw or "")
    t = re.sub(r"<[^<>]*>", "", t)
    # [[Blackrock Depths (WoW)]] shows as "Blackrock Depths": a page name's bracket tells pages apart, it is not text
    t = WT.RE_LINK.sub(lambda m: (m.group(2) or re.sub(r"\s*\([^()]*\)$", "", m.group(1).split("#")[0])).strip().lstrip(":").strip(), t)
    t = t.replace("'''", "").replace("''", "")
    t = html.unescape(t)
    for a, b in UNI.items():
        t = t.replace(a, b)
    t = re.sub(r",\s*" + PH + r"(?=\s*[.!?,;:]|\s*$)", "", t)        # "Well done, <name>."
    t = re.sub(r"^\s*" + PH + r"\s*[,!]\s*", "", t)                  # "<name>, go north."
    t = re.sub(r"\(\s*\)", "", t)
    t = re.sub(r"\s+", " ", t).strip()
    t = re.sub(r"\s+([,.;:!?])", r"\1", t)
    t = t.strip()
    if not t or re.search(r"[\x00-\x1f{}\[\]<>|=\\]", t) or RE_DANGLING.search(t) or t.count('"') % 2:
        return None
    if not (t[0].isalnum() or t[0] == '"'):
        return None
    if t[-1] == ":" or ":." in t:
        return None                 # "... on the second floor of the hotel:" - the list or quote that followed is gone
    t = t[0].upper() + t[1:]
    if t[-2:] == '."':
        t = t[:-2] + '".'           # ... the "Fields of Blood." -> ... the "Fields of Blood".  (a note ends in . ! or ?)
    if t[-1] not in ".!?":
        t += "."
    return t if lo <= len(t) <= hi else None


def enough(c, words=5, verb=False):
    """is a sentence more than a fragment or a label ("Location: Southern Forbidden Reach.")?  verb: it must also have
    a verb (a wiki note such as "Thai on the east side of the room." has none)"""
    return len(c.split()) >= words and not re.match(r"[A-Za-z]+:\s", c) and (not verb or bool(RE_GO.search(c) or RE_VERB.search(c)))


def classic_words(c):
    """a clean sentence as a Classic client has it: "X was a dwarf located in ..." in the present (the NPC is there),
    and the Alterac places in the Alterac Mountains"""
    m = re.match(r"([^.;:]*?)\b(was|were)\b", c)
    if m and not re.search(r"\b(?:is|are|which|who|that|where|when|he|she|it|they)\b", m.group(1)):     # the sentence's own verb
        c = m.group(1) + ("is" if m.group(2) == "was" else "are") + c[m.end():]
    for rx, to in CLASSIC_WORDS:
        c = rx.sub(to, c)
    return c


def shorten(text, limit):
    """a detail cut back to the whole sentences that fit in `limit`; None when nothing useful fits ("Comes from X."
    alone names no place)"""
    if len(text) <= limit:
        return text
    parts = re.split(r'(?<=[.!?])\s+(?=[A-Z"])', text)
    got = fit(parts, limit)
    if not got or (parts[0].startswith("Comes from ") and got == parts[0]):
        return None
    return got


def fit(parts, limit=MAX_DETAIL):
    """whole sentences, in order, while they fit in `limit` characters"""
    out, n = [], 0
    for p in parts:
        if n + len(p) + (1 if out else 0) > limit:
            break
        out.append(p)
        n += len(p) + (1 if len(out) > 1 else 0)
    return " ".join(out)


def location_parts(field):
    """an infobox location field -> [(raw part, formerly?)]: its <br> / ';' parts, and a "(formerly A, B)" bracket as a
    part of its own; a part that names no place ("Unknown (lore)", "Various") is left out"""
    out = []
    f = re.sub(r"\{\{\s*(?:co|coords|coord)\s*\|[^{}]*\}\}", "", field or "", flags=re.I)
    for seg in re.split(r"<br\s*/?>|;|\n", f, flags=re.I):
        inner = re.findall(r"\(\s*((?:formerly|previously|originally)\b[^()]*)\)", seg, flags=re.I)
        seg = re.sub(r"\(\s*(?:formerly|previously|originally)\b[^()]*\)", "", seg, flags=re.I)
        for s in [seg] + inner:
            s = s.strip()
            if not s or RE_NOPLACE.search(s):
                continue
            out.append((s, bool(RE_FORMER.search(s))))
    return out


def place_text(raw):
    """a location part -> "Kargath, Badlands", or None"""
    s = RE_FORMER.sub("", raw)
    s = re.sub(r"\(\s*'*\s*(?:classic|lore|retail|ghost|corpse|spirit|wow|vanilla|tbc|bc|wrath|wotlk|cata|cataclysm|mop|wod|legion|bfa|current|present|now)\s*'*\s*\)", "", s, flags=re.I)
    s = re.sub(r"\[\[([^\[\]|]+?)\s*\((?:Classic|Cataclysm|[a-z ]+)\)\]\]", r"[[\1]]", s)   # [[Feralas (Classic)]]
    t = clean_sentence(strip_blocks(s), lo=3, hi=120)
    return t.rstrip(".").strip(" ,") if t else None


class StepDetail:
    """the detail of one step with no point.  `gen` is the Gen it works for (page texts, titles, maps and the
    Classic-era place rules)."""

    def __init__(self, gen):
        self.g = gen
        self.cache = {}
        self.pc = {}
        self.qcache = {}

    # ---- helpers -----------------------------------------------------------------------------------
    def later_place(self, pg, fl):
        """is the linked page a place this client does not have as the wiki describes it: made or moved in a later
        patch (Places.POST_CATA), or a WoW Forever place on another client?"""
        k = (pg, fl)
        if k not in self.pc:
            forever = fl != "forever" and bool(re.match(r"\s*\{\{\s*forever only", self.g.places.text(pg)[:400], re.I))
            self.pc[k] = forever or (fl != "retail" and self.g.places.post_cata(pg, fl))
        return self.pc[k]

    def later_text(self, text, fl, quest=False):
        """Classic clients: does the text name a place the client does not have - a Retail zone under a name the
        client has no map of ("Shattrath City" on era), or one of LATER_PLACES?  A quest's own text is only checked
        for the places made at the Cataclysm in the old lands (LATER_QUEST_PLACES)."""
        if fl not in ("era", "tbc", "forever"):
            return False
        k = ("later", fl, quest)
        if k not in self.pc:
            names = set(LATER_QUEST_PLACES if quest else LATER_PLACES)
            if not quest:
                S, own = self.g.atlas.sets[fl], self.own_names(fl)
                for m in self.g.atlas.sets["retail"].maps.values():
                    n = re.sub(r"^The\s+", "", m["name"])
                    if m["type"] == 3 and len(n) >= 6 and re.fullmatch(r"[A-Za-z' -]+", n) and " - " not in n \
                            and wikimaps.norm(n) not in own and wikimaps.norm(n) not in CLASSIC_SUBZONES \
                            and S.resolve(m["name"]) is None:
                        names.add(n)
            self.pc[k] = re.compile(r"\b(?:" + "|".join(re.escape(n) for n in sorted(names, key=lambda n: (-len(n), n))) + r")\b")
        return bool(self.pc[k].search(text or ""))

    def earlier_place(self, page, text, fl):
        """Classic clients: None when the page does not say where its subject stood earlier (RE_EARLIER, in its lead
        and its history sections); else that place as "Morgan's Vigil, Burning Steppes" - the links of that sentence
        up to its first zone map - or "" when it links no place the client has."""
        secs = WT.sections(text)
        body = "\n".join(v for k, v in secs.items() if k == "" or "world of warcraft" in k or k in ("history", "background", "biography"))
        box = next(WT.find_templates(body, re.compile(r"npcbox|objectbox", re.I)), None)
        if box:
            body = body[:box[0]] + body[box[1]:]
        body = re.sub(r"<ref[^>]*/>|<ref.*?</ref>", "", body, flags=re.S | re.I)
        m = RE_EARLIER.search(body)
        if not m:
            return None
        seg, names, S = m.group(2) or m.group(3) or m.group(4) or "", [], self.g.atlas.sets[fl]
        for lk in re.finditer(r"\[\[[^\[\]]+\]\]", seg):
            if lk.group(0)[2:3].islower() or re.search(r"\((?:event|faction|organization)\)", lk.group(0)):
                continue            # "the [[goblin]] town of [[Gadgetzan]]": a common noun, not a place name
            t = next((x for x, _ in WT.links(lk.group(0))), None)
            pg, kind = self.g.resolve_title(t)
            if not pg or kind in ("npc", "object", "item", "quest", "achievement"):
                break
            if self.later_place(pg, fl) or self.later_text(pg, fl):
                break               # "... in [[Booty Bay]] in the [[Cape of Stranglethorn]]": the zone's later name
            zm = S.resolve(pg)
            if zm is None and kind != "place" and self.g.atlas.sets["retail"].resolve(pg) is None and names:
                break               # "[[Northpass Tower]] helped the Alliance ... the [[Crystal of Zin-Malor]]"
            n = re.sub(r"\s*\([^()]*\)$", "", pg)
            if n and n not in names:
                names.append(n)
            if zm is not None and S.maps[zm]["type"] == 3:
                break
        return ", ".join(names[:3])

    def own_names(self, fl):
        """the names of the client's own maps (normalised)"""
        k = ("names", fl)
        if k not in self.pc:
            self.pc[k] = {wikimaps.norm(re.sub(r"^The\s+", "", m["name"])) for m in self.g.atlas.sets[fl].maps.values()}
        return self.pc[k]

    def check(self, raw, fl, mid, added, draenor, classic):
        """-> (usable, informative).  usable: no linked place is later than the client (Classic clients), and the
        linked maps do not all disagree with the step's map `mid`.  informative: the text names more than that map (a
        town, building or other map, or a word of position)."""
        S, R = self.g.atlas.sets[fl], self.g.atlas.sets["retail"]
        found, info = [], False
        if classic and self.later_text(re.sub(r"\[\[[^\[\]|]*\|", "[[", raw) + " " + " ".join(t for t, _ in WT.links(raw)), fl):
            return False, False     # "... as well as Shattrath City and Dalaran" on era
        for t, _ in WT.links(raw):
            pg, kind = self.g.resolve_title(t)
            if not pg or kind in ("npc", "object", "item", "quest", "achievement"):
                continue
            if self.later_place(pg, fl):
                return False, False
            m = S.resolve(pg, added, draenor)
            if m is None:
                m = S.resolve(t, added, draenor)
            rm = R.resolve(pg)
            if fl != "retail" and rm is not None and R.maps[rm]["type"] == 3 and wikimaps.norm(
                    re.sub(r"^The\s+", "", R.maps[rm]["name"])) not in self.own_names(fl):
                return False, False     # a zone under a name only Retail has ("Northern Barrens")
            if m is not None and S.maps[m]["type"] >= 3:
                found.append(m)
                info = info or mid is None or not self.same_map(fl, m, pg, mid)
                continue
            if rm is not None and R.maps[rm]["type"] < 3:
                continue                # a world or continent ("the history in Azeroth") says nothing about where
            if kind == "place" or rm is not None:
                info = True
                z = self.g.place_zone(pg, fl, added, draenor) if kind == "place" else None
                if z is not None:
                    found.append(z)
        if mid is not None and found and not any(self.g.agree(fl, m, mid) for m in found):
            return False, False
        return True, info

    def zone_name(self, fl, mid):
        return self.g.atlas.sets[fl].maps[mid]["name"] if mid is not None and mid in self.g.atlas.sets[fl].maps else ""

    def same_map(self, fl, m, name, mid):
        """is map m (reached by the link `name`) the step's own map: the same id, or a map of the same name (the client
        has several maps called "Hall of the Guardian")?"""
        zn = wikimaps.norm(re.sub(r"^The\s+", "", self.zone_name(fl, mid)))
        return m == mid or (zn != "" and wikimaps.norm(re.sub(r"^The\s+", "", re.sub(r"\s*\([^()]*\)$", "", name or ""))) == zn)

    def beyond_zone(self, text, fl, mid):
        """does the text hold a word of position or a compass direction once the zone's own name is taken out
        ("Western Plaguelands" is not a direction)?"""
        zn = self.zone_name(fl, mid)
        t = re.sub(re.escape(re.sub(r"^The\s+", "", zn)), "", text, flags=re.I) if zn else text
        return bool(RE_CUE.search(t) or RE_COMPASS.search(t))

    def npc_place(self, title, fl, mid, added, draenor, depth=0):
        """where the linked NPC / object stands, in the wiki's words; for an item, where what drops it stands"""
        page, kind = self.g.resolve_title(title)
        if not page:
            return None
        k = (page, title, fl, mid, added, draenor)     # the title too: one that leads to another's page is judged by its name
        if k in self.cache:
            return self.cache[k]
        out = None
        if kind in ("npc", "object"):
            out = self.page_place(page, kind, fl, mid, added, draenor)
            # a title that leads to another subject's page (a shared page): only a text that names what was asked for
            words = [w.lower() for w in re.findall(r"[A-Za-z']{4,}", re.sub(r"\s*\([^()]*\)$", "", title))]
            asked = re.sub(r"\s*\([^()]*\)$", "", title).strip().lower()
            if out and wikimaps.norm(page) != wikimaps.norm(WT.norm_title(title)) and not (
                    words and re.search(r"(?<![\w'])" + re.escape(asked) + r"(?![\w'])", out.lower())):
                out = None          # "Seer Wiserunner" leads to the page of Doomsayer Wiserunner, a later NPC elsewhere
        elif depth == 0 and page in self.g.items:
            for src in self.g.items[page][1][:3]:
                sp, sk = self.g.resolve_title(src)
                if sk not in ("npc", "object"):
                    continue
                got = self.npc_place(src, fl, mid, added, draenor, 1)
                if got:
                    name = re.sub(r"\s*\([^()]*\)$", "", sp)
                    out = fit([f"Comes from {name}.", got])
                    if out and got in out:
                        break
                    out = None
        self.cache[k] = out
        return out

    def page_place(self, page, kind, fl, mid, added, draenor):
        g = self.g
        text = g.places.text(page)
        if not text:
            return None
        classic = fl in ("era", "tbc", "forever")
        name = re.sub(r"\s*\([^()]*\)$", "", page)
        if classic and kind == "npc" and g.places.classic_links(page) is not None:
            # the page says the NPC stood elsewhere before the Cataclysm: only that earlier place is true here
            names = []
            for t in g.place_links(page, fl):
                n = re.sub(r"\s*\([^()]*\)$", "", t)
                if n and n not in names:
                    names.append(n)
            if not names or (mid is not None and names == [g.atlas.sets[fl].maps[mid]["name"]]):
                return None
            return self.listed(name, ", ".join(names))
        box = next(WT.find_templates(text, re.compile(r"npcbox|objectbox", re.I)), None)
        lead = WT.sections(text).get("", "")
        if box:
            lead = lead[:box[0]] + lead[box[1]:]
        sents = raw_sentences(lead)
        first = next((s for s in sents if "'''" in s), sents[0] if sents else None)
        field = WT.split_params(box[3])[1].get("location", "") if box else ""
        parts = location_parts(field)
        if classic and any(p[1] for p in parts):
            # "formerly Southshore, Hillsbrad Foothills": the lead and the other parts describe a later time.  The
            # earlier place is used even when the step's zone tag says otherwise (the tag came from the later place).
            for raw, _former in [p for p in parts if p[1]]:
                ok, _info = self.check(raw, fl, None, added, draenor, classic)
                pt = place_text(raw) if ok else None
                if pt:
                    return self.listed(name, pt)
            return None
        if classic:
            ep = self.earlier_place(page, text, fl)
            if ep is not None:
                # "Marshal Maxwell was formerly located at Morgan's Vigil in the Burning Steppes": the lead and the
                # location field describe a later time
                if not ep or (mid is not None and ep.lower() == re.sub(r"^The\s+", "", g.atlas.sets[fl].maps[mid]["name"]).lower()):
                    return None
                return self.listed(name, ep)
        if first and (g.PRESENT.search(first) or RE_IS_AT.search(first)) and not (classic and RE_LATER.search(first)):
            ok, info = self.check(first, fl, mid, added, draenor, classic)
            c = clean_sentence(first) if ok else None
            if c and enough(c) and (info or self.beyond_zone(c, fl, mid) or self.names_place(first, fl, mid)):
                return classic_words(c) if classic else c
        parts = [p for p in parts if not p[1]]
        for raw, _former in parts:
            ok, info = self.check(raw, fl, mid, added, draenor, classic)
            pt = place_text(raw) if ok else None
            if pt and (info or self.beyond_zone(pt, fl, mid)):
                if mid is not None and pt.lower() == g.atlas.sets[fl].maps[mid]["name"].lower():
                    continue
                return self.listed(name, pt)
        return None

    def names_place(self, raw, fl, mid):
        """does the sentence link something after its word of place ("found in [[Tazz'Alor]]") that is neither an
        NPC, object, item or quest nor just the step's own map?  Many subzones have no entry in the title table."""
        m = self.g.PRESENT.search(raw) or RE_IS_AT.search(raw)
        S = self.g.atlas.sets[fl]
        for t, _ in WT.links(raw[m.end():] if m else ""):
            pg, kind = self.g.resolve_title(t)
            rm = self.g.atlas.sets["retail"].resolve(pg) if pg else None
            if rm is not None and self.g.atlas.sets["retail"].maps[rm]["type"] < 3:
                continue                # a world or continent
            if pg and kind is None and (mid is None or not self.same_map(fl, S.resolve(pg), pg, mid)):
                return True
        return False

    @staticmethod
    def listed(name, where):
        t = f"The wiki lists {name} at {where}."
        return t if len(t) <= MAX_DETAIL and not re.search(r"[\x00-\x1f{}\[\]<>|=\\]", t) else None

    def quest_sections(self, page):
        if page not in self.qcache:
            self.qcache = {} if len(self.qcache) > 64 else self.qcache
            self.qcache[page] = WT.sections(self.g.places.text(page))
        return self.qcache[page]

    def score(self, raw, clean, zone=""):
        """how much a sentence says about where: a compass direction 2, a linked place 2, a word of position 1 each (at
        most 2).  The step's own zone does not count: its name is taken out first."""
        zn = re.sub(r"^The\s+", "", zone or "")
        if zn:
            clean = re.sub(re.escape(zn), "", clean, flags=re.I)
        n = 2 if RE_COMPASS.search(clean) else 0
        cues = min(2, len(set(m.group(0).lower() for m in RE_CUE.finditer(clean))))
        R = self.g.atlas.sets["retail"]
        for t, _ in WT.links(raw):
            pg, kind = self.g.resolve_title(t)
            if pg and zn and wikimaps.norm(re.sub(r"^The\s+", "", re.sub(r"\s*\([^()]*\)$", "", pg))) == wikimaps.norm(zn):
                continue
            if pg and (kind == "place" or R.resolve(pg) is not None):
                # a linked place alone is often only a mention ("supplies from the Undercity")
                n += 2 if (cues or RE_GO.search(clean)) else 0
                break
        return n + cues

    @staticmethod
    def about(target):
        """the words that tell one objective from another: those of its target ("Lean Wolf Flank" -> lean, wolf, flank)"""
        return [w.lower().rstrip("s") for w in re.findall(r"[A-Za-z']{4,}", re.sub(r"\bslain\b", "", target or ""))]

    def told(self, raw, clean, zone):
        """is a Description sentence (the quest giver talking) a direction?  It needs a verb of going or finding and a
        compass direction, a linked place or a word of position; in the first person ("My own brother perished when
        the West Bridge ...") a compass direction or a linked place."""
        if not RE_GO.search(clean):
            return False
        zn = re.sub(r"^The\s+", "", zone or "")
        rest = re.sub(re.escape(zn), "", clean, flags=re.I) if zn else clean
        # score() of the bare verb: 2 exactly when the sentence links a place other than the step's zone
        strong = bool(RE_COMPASS.search(rest)) or self.score(raw, "go", zone) >= 2
        if RE_FIRST_PERSON.search(clean):
            # the quest giver about himself, unless he sends the player ("Go to ...", "... you will find ...")
            m = re.search(r"\byou\b", clean, re.I)
            return strong and bool(RE_GO.match(clean) or (m and RE_GO.search(clean, m.end())))
        return strong or bool(RE_CUE.search(rest))

    def quest_directions(self, act, r, who, note, target="", nobj=1, zone="", limit=MAX_DETAIL, fl="retail"):
        """the quest page's own words about where: see the module text"""
        secs = self.quest_sections(r["page_title"])
        seen = (note or "").lower()
        classic = fl in ("era", "tbc", "forever")
        objs = []
        for raw in raw_sentences(secs.get("objectives", "").split("\n*")[0]):
            c = clean_sentence(raw)
            if c and enough(c, 4) and c.lower().rstrip(".") not in seen and not self.later_text(c, fl, True):
                objs.append((raw, classic_words(c) if classic else c))
        if act == "T":
            words = [w.lower() for w in re.findall(r"[A-Za-z']{4,}", who or "")]
            # the ender by a whole word of the name ("Seers" in "the Water of the Seers" is not Seer Wiserunner)
            got = [c for raw, c in objs if any(re.search(r"(?<![\w'])" + re.escape(w) + r"(?![\w])", c.lower()) for w in words)
                   and self.places_it(raw, c, zone)]
            return fit(got[:1], limit) or None
        if act != "C":
            return None
        cand = []
        for sec in ("notes", "walkthrough", "description"):
            for raw in raw_sentences(secs.get(sec, "")):
                c = clean_sentence(raw, lo=25, hi=200)
                if c and (not enough(c, 5, True) or self.later_text(c, fl, True) or ((sec == "description" or RE_FIRST_PERSON.search(c)) and not self.told(raw, c, zone))):
                    continue
                if c and classic and re.search(r"\b(?:previously|formerly)\b.*\bnow\b", c, re.I):
                    continue        # "previously Elite, but now a normal mob": a later state of the game
                c = classic_words(c) if (c and classic and sec != "description") else c
                if c and c.lower().rstrip(".") not in seen and not RE_NOT_OBJECTIVE.search(c):
                    sc = self.score(raw, c, zone)
                    # a quest with several objectives: only a sentence that names this one's target
                    if nobj > 1 and not any(w in c.lower() for w in self.about(target)):
                        continue
                    if sc >= 2:
                        cand.append((-sc, len(cand), c))
        picked, n = [], 0
        for _sc, idx, c in sorted(cand):
            if len(picked) < 2 and n + len(c) + 1 <= limit + 1 and c not in [p[1] for p in picked]:
                picked.append((idx, c))
                n += len(c) + 1
        if picked:
            return fit([c for _i, c in sorted(picked)], limit) or None
        # the Objectives sentence, unless its only place is where the quest is handed in
        got = [c for raw, c in objs if self.places_it(raw, c, zone) and self.elsewhere(c, zone)]
        return fit(got[:1], limit) or None

    @staticmethod
    def elsewhere(clean, zone):
        """does an Objectives sentence name a place besides where the quest is taken or handed in ("Fleet Master
        Seahorn in Booty Bay wants you to ...", "... then return to Thotar in Razor Hill")?"""
        zn = re.sub(r"^The\s+", "", zone or "")
        rest = RE_HAND_IN.sub("", RE_GIVER.sub("", clean))
        rest = re.sub(re.escape(zn), "", rest, flags=re.I) if zn else rest
        return bool(RE_COMPASS.search(rest) or RE_WHERE.search(rest))

    def places_it(self, raw, clean, zone):
        """does an Objectives sentence say where ("... to Magistrate Maleb in Southshore"), beyond the step's own zone?"""
        zn = re.sub(r"^The\s+", "", zone or "")
        rest = re.sub(re.escape(zn), "", clean, flags=re.I) if zn else clean
        return self.score(raw, clean, zone) >= 1 or bool(re.search(r"\b(?:in|at|inside|near|outside)\s+(?:the\s+)?[A-Z]", rest))

    # ---- the step ----------------------------------------------------------------------------------
    def detail(self, fl, act, ents, r, mid, note, added, draenor, who="", nobj=1, limit=MAX_DETAIL):
        """-> (kind, text): ("npc", ...), ("quest", ...) or (None, None).  `limit`: the characters the note has room
        for (room())."""
        if limit < 20:
            return None, None
        for e in ents:
            if e.get("title"):
                t = self.npc_place(e["title"], fl, mid, added, draenor)
                t = shorten(t, limit) if t else None
                if t:
                    return "npc", t
        t = self.quest_directions(act, r, who, note, note, nobj, self.zone_name(fl, mid), limit, fl)
        return ("quest", t) if t else (None, None)


def whole(note):
    """a note the generator cut at its length limit, back to its last whole sentence (else its last whole word and
    "..."), so that what follows does not read as part of a broken sentence"""
    note = (note or "").rstrip()
    if note[-1:] in ".!?":
        return note
    ends = [m.end() for m in re.finditer(r"[.!?](?=\s)", note)]
    if ends and ends[-1] >= 20:
        return note[:ends[-1]]
    return note.rsplit(" ", 1)[0].rstrip(" ,;:-(") + "..."


def room(note):
    """the characters a detail may take so that the whole note stays within NOTE_CAP (at most MAX_DETAIL)"""
    note = (note or "").rstrip()
    return min(MAX_DETAIL, NOTE_CAP - len(note) - (0 if note[-1:] in ".!?" else 1) - len(NO_SPOT) - 2)


def with_detail(note, detail):
    """the note of a step with no point: what it said, that there is no exact spot, then the detail.  A detail that
    quotes coordinates from the wiki's prose is not introduced by that sentence (it would not be true)."""
    note = (note or "").rstrip()
    sep = "" if note[-1:] in ".!?" else "."
    if RE_COORDS.search(detail):
        return f"{note}{sep} {detail}"
    return f"{note}{sep} {NO_SPOT} {detail}"

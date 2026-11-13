#!/usr/bin/env python3
# CompletionRoute :: tools/test_step_detail.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""What a step with no map point says (tools/wiki/step_detail.py, used by tools/wiki/gen_wiki_guides.py).

    python3 tools/test_step_detail.py [--no-gen]

Part 1 needs no data: the text rules on small made-up wiki pages (markup cleaning, placeholders, no "|" in a note,
the length limit, an era client against a retail client for an NPC that moved).
Part 2 needs the local wiki tables (tools/wiki/wiki.sqlite, gitignored; without them it says so and passes; --no-gen
skips it): it generates the era guides twice into temp folders (--out: nothing in the checkout is written), once with
the detail switched off, and checks that only the notes of steps without a point differ.  About 40 seconds.
Temp folders: CR_TEST_TMP, else /private/tmp/claude-501 when it exists, else the system default.
"""
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools", "wiki"))
import gen_wiki_guides as G  # noqa: E402
import step_detail as SD  # noqa: E402

fails = checks = 0


def check(ok, what, got=None):
    global fails, checks
    checks += 1
    if not ok:
        fails += 1
        print("FAIL " + what + ("" if got is None else " :: " + repr(got)[:300]))


# ---- a small made-up wiki ---------------------------------------------------------------------------------------
PAGES = {
    "Magistrate Maleb": """{{Npcbox
 | name = Magistrate Maleb
 | location = [[Shadow Keep]] ([[Silverpine]])<br /> formerly [[Southshore]], [[Hillsbrad]]
}}
'''Magistrate Maleb''' is an [[elite]] [[worgen]] located inside [[Shadow Keep]], in [[Silverpine]].""",
    "Vivian": """{{Npcbox
 | location = [[Undercity]]
}}
'''Vivian''' is a [[Forsaken]] located in the [[Undercity]].

Before the [[Cataclysm (event)|Cataclysm]], she was located at [[Kargath]], [[Badlands]].""",
    "Ormer": """[[File:Ormer.jpg|thumb|Ormer at [[Whelgar's Site]].]]
{{Npcbox
 | location = [[Whelgar's Site]], [[Wetlands]]
}}
'''Ormer''' {{title|Prospector}} is a [[dwarf]] [[quest giver]] located at [[Whelgar's Site]]<ref>a note</ref> in the [[Wetlands]].<br>He dislikes raptors.""",
    "Laird": """{{Npcbox
 | location = [[Lordanel]], [[Darkshore]]
}}
'''Laird''' was a [[night elf]] located inside the inn of [[Auberdine]] in [[Darkshore]].""",
    "Lordanel": "A town.\n==Patch changes==\n*{{Patch 4.0.3a|note=Added.}}",
    "Zoner": """{{Npcbox
 | location = [[Wetlands]]
}}
'''Zoner''' is a [[dwarf]] located in the [[Wetlands]].""",
    "Strahad": """{{Npcbox
 | location = [[Northern Barrens]]
}}
'''Strahad''' is a [[human]] located in [[Ratchet]] of [[Northern Barrens]].""",
    "Islander": """{{Npcbox
 | location = [[Sky Isle]]
}}
'''Islander''' is a spirit.""",
    "Sky Isle": "{{Forever only|zone}}\nAn island.",
    "Thief": """{{Npcbox
 | location = [[Strahnbrad]], [[Alterac]]
}}
'''Thieves''' are [[human]]s found in [[Strahnbrad]] in [[Alterac]].""",
    "Maxwell": """{{Npcbox
 | location = [[Shadow Keep]]
}}
'''Maxwell''' is a [[human]] [[quest giver]] located deep within [[Shadow Keep]] between the Tomb and the Lyceum.

Maxwell was formerly located at [[Morgan's Vigil]] in the [[Badlands]].""",
    "Hollee": """{{Npcbox
 | location = [[Ruins of Auberdine]], [[Darkshore]]
}}
'''Hollee''' is a [[dwarf]] located in the [[Ruins of Auberdine]] in [[Darkshore]].

{{Classic only-section}}
Before the Cataclysm, she was a quest giver in [[Auberdine]].""",
    "Tranrek": """'''Tranrek''' is a [[goblin]] located in [[Shadow Keep]]. He used to be found in the [[goblin]] town of [[Ratchet]] and was affiliated with it.""",
    "Benedict": """'''Benedict''' is a [[human]] located in the cathedral of [[Undercity]].
==History==
Some time before the [[Cataclysm (event)|Cataclysm]] in 28 ADP, Benedict appointed a priest to retrieve an artifact, which was stolen by riders last seen in [[Wetlands]].""",
    "Gelvas": """{{Npcbox
 | location = [[Darkmoon Island]]
}}
'''Gelvas''' is a [[goblin]] located within the faire on [[Darkmoon Island]].""",
    "Doomsayer Wise": """'''Doomsayer Wise''' is a [[tauren]] [[rare mob]] located in a cave north of the [[Digsite]] in [[Wetlands]].

He was formerly known as '''Seer Wise'''.""",
    "Durgen": """'''Durgen''' is a [[dwarf]] located in the tunnel leading to [[Alterac Valley]] in the [[Hillsbrad Foothills]].""",
    "Rashona": """'''Rashona''' was an [[orc]] [[quest giver]] located in the inn in the Drag in [[Undercity]].""",
    "Discs": """'''The Discs''' are a set of artifacts which were created to transcribe the history in [[Azeroth]] as it unfolded.""",
    "Smelt": """==Objectives==
Bring forty Mithril Bars to [[Galvan the Ancient]] in [[Strahnbrad]].
==Description==
My own brother perished when the West Bridge over the span was destroyed.

It is called the shackle key - well, that is what they keep calling it near the gate.""",
    "Vision": """==Objectives==
Drink the Water of the Seers at the fire in [[Ratchet]].
==Description==
Trust me, this is no [[Ratchet]] boar hunt, so you had best have a care with them.
==Notes==
*At that point I sent someone south to find help near the gate.
*The hydra (previously elite, but now a normal mob) can be found near the gate of the keep.""",
    "Port": """==Objectives==
[[Crane Operator Bigglefuzz]] in [[Ratchet]] wants you to retrieve the port from Mad Magglish who is hiding in the Wailing Caverns.""",
    "Seahorn": """==Objectives==
[[Fleet Master Seahorn]] in [[Ratchet]] wants you to kill 10 Swashbucklers and bring back the charts.""",
    "Chett": """==Objectives==
Talk with the machine about its lists.
==Notes==
*The machine is on the second floor of the hotel near the gate:
*Thai on the east side.
*Location: Southern Reach.
*The seer can be found northwest of the village in a cave in the mountains (coordinates 33,36).""",
    "Cape": """==Objectives==
Collect the gem.
==Notes==
*Look for the trolls at the ruins near the coast of the distant Cape of Stranglethorn.""",
    "Noble Deaths": """{{Questbox
|name=Noble Deaths
}}
==Objectives==
Bring 7 Signet Rings to [[Magistrate Maleb|Magistrate Maleb]] in [[Southshore]].
*[[Signet Ring]] (7)

==Description==
I fear the leadership behind the [[Syndicate]] is bent on Southshore's ruin, <name>. We must strike hard.

Enter the ruins of [[Strahnbrad]], in the {{C|Alterac Mountains}} to the north. We think the Syndicate is using the area.

Bring me those rings, <lad/lass>, from the tower to the north.

==Notes==
*The rings drop from the nobles near the {{co|60.0|43.5|Alterac}} inn | upstairs.
*Pick up this quest in [[Southshore]], north of the inn.

==Completion==
You serve us well, <name>.""",
}
REDIRECT = {"Seer Wise": "Doomsayer Wise"}
TITLES = {"Maxwell": "npc", "Hollee": "npc", "Tranrek": "npc", "Benedict": "npc", "Gelvas": "npc", "Doomsayer Wise": "npc",
          "Durgen": "npc", "Rashona": "npc", "Discs": "object", "Morgan's Vigil": "place", "Darkmoon Island": "place",
          "Galvan the Ancient": "npc", "Crane Operator Bigglefuzz": "npc", "Fleet Master Seahorn": "npc",
          "Magistrate Maleb": "npc", "Vivian": "npc", "Ormer": "npc", "Laird": "npc", "Zoner": "npc", "Strahad": "npc",
          "Islander": "npc", "Thief": "npc", "Signet Ring": "item", "Southshore": "place", "Kargath": "place",
          "Strahnbrad": "place", "Auberdine": "place", "Lordanel": "place", "Ratchet": "place"}
MAPS = {1: "Hillsbrad", 2: "Silverpine", 3: "Badlands", 4: "Wetlands", 5: "Darkshore", 6: "Undercity", 7: "Alterac",
        8: "The Barrens", 11: "Azeroth"}
RETAIL_ONLY = {9: "Northern Barrens", 10: "Shadow Keep", 12: "Shattered City"}


class FakeSet:
    def __init__(self, maps, alias=None):
        self.maps = {i: {"name": n, "type": 4 if n == "Shadow Keep" else 2 if n == "Azeroth" else 3} for i, n in maps.items()}
        self.by = {n: i for i, n in maps.items()}
        self.by.update(alias or {})

    def resolve(self, name, added=None, draenor=False):
        return self.by.get(re.sub(r"^The ", "", name or "")) or self.by.get(name)


class FakeAtlas:
    def __init__(self):
        retail = FakeSet({**MAPS, **RETAIL_ONLY})
        era = FakeSet(MAPS, {"Northern Barrens": 8})        # the era map set knows the later name as an alias
        self.sets = {"era": era, "tbc": era, "forever": era, "mop": retail, "retail": retail}


class FakeGen:
    """the parts of Gen the detail uses, on the made-up wiki; the Classic-era place rules are the generator's own"""
    PRESENT = G.Gen.PRESENT
    place_links = G.Gen.place_links

    def __init__(self):
        self.places = G.Places.__new__(G.Places)
        self.places.cache = {}
        self.places.raw = sqlite3.connect(":memory:")
        self.places.raw.execute("create table pages(title text, wikitext text)")
        self.places.raw.executemany("insert into pages values (?,?)", PAGES.items())
        self.atlas = FakeAtlas()
        self.items = {"Signet Ring": (1, ["Syndicate", "Thief"])}
        self.moved_seen, self.place_rejected = set(), {}
        import collections
        self.place_rejected = collections.Counter()

    def resolve_title(self, t):
        t = REDIRECT.get(t, t)
        return (t, TITLES.get(t)) if t else (None, None)

    def agree(self, fl, a, b):
        return a == b

    def place_zone(self, page, fl, added=None, draenor=False):
        return None


def part1():
    print("text rules")
    c = SD.clean_sentence
    check(c("Enter the ruins of [[Strahnbrad]], in the Alterac Mountains to the '''north'''.")
          == "Enter the ruins of Strahnbrad, in the Alterac Mountains to the north.", "links and bold are rendered as words")
    check(c("Go to [[Blackrock Depths (WoW)]] and [[Kargath|the  outpost]]&nbsp;now.") == "Go to Blackrock Depths and the outpost now.",
          "a page-name bracket and an entity are not text", c("Go to [[Blackrock Depths (WoW)]] and [[Kargath|the  outpost]]&nbsp;now."))
    check(c("You serve your Alliance well, <name>.") == "You serve your Alliance well.", "a form of address is taken out")
    check(c("<name>, go north to the tower.") == "Go north to the tower.", "... at the start too")
    check(c("Bring it to me, <lad/lass>, from the tower.") == "Bring it to me, from the tower.", "... and in the middle")
    check(c("The <class> must go north to the tower.") is None, "a placeholder that is part of the sentence drops it")
    check(c("Greetings $N, go north to the tower.") is None, "$N drops the sentence")
    check(c("Go north {{unclosed to the tower.") is None and c("Go [north to the tower.") is None, "left-over markup drops the sentence")
    check(c("Go north | then east to the tower.") is None, "a bar never passes")
    check(c('You will find it in what is known as the "Fields of Blood."') == 'You will find it in what is known as the "Fields of Blood".',
          "a sentence that ends inside its quote gets no second full stop: the stop moves out of the quote")
    check(c("x" * 230 + ".") is None, "a sentence over the limit is left out, not cut")
    check(c("Head “north” — past the camp…") == 'Head "north" - past the camp...', "typographic characters become plain ones")
    rs = SD.raw_sentences(PAGES["Ormer"].split("}}\n", 1)[1])
    check(len(rs) == 2 and rs[0].startswith("'''Ormer'''") and "is a [[dwarf]]" in rs[0] and "ref" not in rs[0] and "title" not in rs[0],
          "templates, references and <br> are gone before sentences are split", rs)
    check("File:" not in " ".join(SD.raw_sentences(PAGES["Ormer"])), "a file link with a caption that links is taken out whole")
    check(SD.fit(["a" * 100 + ".", "b" * 100 + ".", "c" * 100 + "."]) == "a" * 100 + ". " + "b" * 100 + ".", "whole sentences while they fit")
    lp = SD.location_parts("[[A]] ([[B]]) and [[C]]<br /> formerly [[D]], [[E]]; Unknown (lore)")
    check(lp == [("[[A]] ([[B]]) and [[C]]", False), ("formerly [[D]], [[E]]", True)], "location field parts", lp)
    check(SD.location_parts("[[A]], [[B]] (formerly [[C]], [[D]])")[1] == ("formerly [[C]], [[D]]", True), "a (formerly ...) bracket is a part")
    check(SD.place_text("formerly [[Kargath]], [[Badlands (Classic)|Badlands]] (''Classic'')") == "Kargath, Badlands", "a location part as text",
          SD.place_text("formerly [[Kargath]], [[Badlands (Classic)|Badlands]] (''Classic'')"))
    check(SD.with_detail("Signet Ring (7)", "X.") == "Signet Ring (7). No exact spot on the wiki. X."
          and SD.with_detail("To Maleb.", "X.") == "To Maleb. No exact spot on the wiki. X.", "the note keeps what it said and says there is no exact spot")

    print("era against retail")
    g = FakeGen()
    d = SD.StepDetail(g)
    era = d.npc_place("Magistrate Maleb", "era", 1, None, False)
    ret = d.npc_place("Magistrate Maleb", "retail", 2, None, False)
    check(era == "The wiki lists Magistrate Maleb at Southshore, Hillsbrad.", "era: the 'formerly' place of the location field", era)
    check(ret == "Magistrate Maleb is an elite worgen located inside Shadow Keep, in Silverpine.", "retail: where the NPC stands today", ret)
    check(d.npc_place("Magistrate Maleb", "era", 2, None, False) == era, "era: the earlier place even when the step's zone tag is the later one")
    check(d.npc_place("Magistrate Maleb", "mop", 2, None, False) == ret, "mop is after the Cataclysm: the later place")
    check(d.npc_place("Vivian", "era", 3, None, False) == "The wiki lists Vivian at Kargath, Badlands.",
          "era: a page that says its NPC moved at the Cataclysm gives the earlier place (Places.MOVED)", d.npc_place("Vivian", "era", 3, None, False))
    check(d.npc_place("Vivian", "retail", 6, None, False) is None, "retail: 'located in the Undercity' adds nothing to the zone Undercity")
    check(d.npc_place("Laird", "era", 5, None, False) == "Laird is a night elf located inside the inn of Auberdine in Darkshore.",
          "era: the lead sentence, in the present; the location field's later town (Places.POST_CATA) is not used", d.npc_place("Laird", "era", 5, None, False))
    check(d.npc_place("Laird", "retail", 5, None, False).startswith("Laird was a night elf"), "retail keeps the wiki's past tense")
    check(d.npc_place("Laird", "retail", 5, None, False) is not None, "retail may use either")
    check(d.npc_place("Ormer", "era", 4, None, False) == "Ormer is a dwarf quest giver located at Whelgar's Site in the Wetlands.",
          "a lead sentence, cleaned", d.npc_place("Ormer", "era", 4, None, False))
    check(d.npc_place("Ormer", "era", 3, None, False) is None, "a text whose maps all disagree with the step's map is not used")
    check(d.npc_place("Zoner", "era", 4, None, False) is None, "a text that only repeats the zone is no detail")
    check(d.npc_place("Strahad", "era", 8, None, False) is None, "era: a zone name only Retail has is not shown", d.npc_place("Strahad", "era", 8, None, False))
    check(d.npc_place("Strahad", "retail", 9, None, False) == "Strahad is a human located in Ratchet of Northern Barrens.", "retail shows it")
    check(d.npc_place("Islander", "era", None, None, False) is None and d.npc_place("Islander", "retail", None, None, False) is None
          and d.npc_place("Islander", "forever", None, None, False) == "The wiki lists Islander at Sky Isle.", "a WoW Forever place only on Forever")
    it = d.npc_place("Signet Ring", "era", 7, None, False)
    check(it == "Comes from Thief. Thieves are humans found in Strahnbrad in Alterac.", "an item objective: what drops it and where that stands", it)

    # 2026-11-12 review of the first build
    print("review: later places on a Classic client, the wrong NPC, wording")
    np = lambda t, fl, mid=None: d.npc_place(t, fl, mid, None, False)
    check(np("Maxwell", "era") == "The wiki lists Maxwell at Morgan's Vigil, Badlands." and np("Maxwell", "forever") == np("Maxwell", "era")
          and np("Maxwell", "tbc") == np("Maxwell", "era"),
          "era, tbc, forever: 'was formerly located at' in the page body gives the earlier place, not the lead's later one", np("Maxwell", "era"))
    check(np("Maxwell", "retail") == "Maxwell is a human quest giver located deep within Shadow Keep between the Tomb and the Lyceum.",
          "retail: the lead", np("Maxwell", "retail"))
    check(np("Hollee", "era", 5) == "The wiki lists Hollee at Auberdine.", "era: 'Before the Cataclysm, she was a quest giver in ...'", np("Hollee", "era", 5))
    check(np("Hollee", "retail", 5) == "Hollee is a dwarf located in the Ruins of Auberdine in Darkshore.", "retail: the ruins", np("Hollee", "retail", 5))
    check(np("Tranrek", "era") == "The wiki lists Tranrek at Ratchet.", "era: 'used to be found in the [[goblin]] town of ...': the town, not the common noun", np("Tranrek", "era"))
    check(np("Benedict", "era") == "Benedict is a human located in the cathedral of Undercity.",
          "a history sentence that only mentions the Cataclysm is not an earlier place", np("Benedict", "era"))
    check(np("Gelvas", "era") is None and np("Gelvas", "tbc") is None and np("Gelvas", "retail") is not None,
          "era, tbc: a place the client does not have (Darkmoon Island) is not shown; retail shows it", (np("Gelvas", "era"), np("Gelvas", "retail")))
    check(d.later_text("as well as Shattered City and Dalaran", "era") and not d.later_text("in Shattered City", "retail")
          and d.later_text("on the distant Cape of Stranglethorn", "era", True) and not d.later_text("the mages of Dalaran", "era", True),
          "a Retail-only zone or a later place named in plain text; a quest's own text may speak of Dalaran")
    check(np("Seer Wise", "era") is None and np("Seer Wise", "retail") is None and np("Doomsayer Wise", "retail") is not None,
          "a title that leads to another NPC's page: not that NPC's place", np("Seer Wise", "retail"))
    check(np("Durgen", "era") == "Durgen is a dwarf located in the tunnel leading to Alterac Valley in the Alterac Mountains.",
          "era: Alterac Valley's entrance is in the Alterac Mountains", np("Durgen", "era"))
    check(np("Durgen", "retail") == "Durgen is a dwarf located in the tunnel leading to Alterac Valley in the Hillsbrad Foothills.", "retail: as the wiki says")
    check(np("Rashona", "era", 6) == "Rashona is an orc quest giver located in the inn in the Drag in Undercity."
          and np("Rashona", "retail", 6).startswith("Rashona was an orc"), "era: an NPC the wiki calls gone is there (present tense); retail: gone", np("Rashona", "era", 6))
    check(SD.classic_words("The Discs are a set which were created in the hall.") == "The Discs are a set which were created in the hall."
          and SD.classic_words("Bilge, of the company, was a goblin located at the port.") == "Bilge, of the company, is a goblin located at the port.",
          "only the sentence's own verb changes tense")
    check(np("Discs", "era") is None and np("Discs", "retail") is None, "a lead that names only a world or continent is lore, not a place", np("Discs", "retail"))
    for bad in ("The machine is on the second floor of the hotel:", "He hears something:. It is a forge."):
        check(SD.clean_sentence(bad) is None, "a sentence that ends in ':' (its list or quote is gone) is left out", SD.clean_sentence(bad))
    check(not SD.enough("Thai on the east side of the room.", 5, True) and not SD.enough("Location: Southern Forbidden Reach is here.")
          and SD.enough("Go north to the old tower.", 5, True) and not SD.enough("Kill him.", 4),
          "a fragment or a label is not a detail")
    check(SD.shorten("Comes from Thief. Thieves are humans found in Strahnbrad in Alterac.", 30) is None
          and SD.shorten("One two three. Four five six. Seven.", 30) == "One two three. Four five six.", "a detail is shortened by whole sentences; 'Comes from X.' alone is none")

    print("quest directions")
    r = {"page_title": "Noble Deaths"}
    t = d.quest_directions("T", r, "Magistrate Maleb", "To Magistrate Maleb.")
    check(t == "Bring 7 Signet Rings to Magistrate Maleb in Southshore.", "turn-in: the Objectives sentence that names the ender and a place", t)
    cdir = d.quest_directions("C", r, "", "Signet Ring (7)")
    check(cdir == "Enter the ruins of Strahnbrad, in the Alterac Mountains to the north.",
          "objective: the description's sentence that sends the player somewhere; not the quest giver about himself, not the notes about taking the quest", cdir)
    check("|" not in cdir and "<" not in cdir and "{" not in cdir and "[" not in cdir, "no markup in it")
    check(d.quest_directions("A", r, "Magistrate Maleb", "From Magistrate Maleb.") is None, "an accept takes nothing from the quest text")
    check(d.quest_directions("C", r, "", "Other Thing", "Other Thing", 2) is None,
          "several objectives: a direction that does not name this one is not used, and neither is an Objectives sentence whose only place is the hand-in",
          d.quest_directions("C", r, "", "Other Thing", "Other Thing", 2))
    qd = lambda page, act="C", who="", **k: d.quest_directions(act, {"page_title": page}, who, "Thing (1)", **k)
    check(qd("Smelt") is None, "objective: 'Bring ... to <ender> in <place>' and the quest giver's own story are no directions", qd("Smelt"))
    check(qd("Smelt", "T", "Galvan the Ancient") == "Bring forty Mithril Bars to Galvan the Ancient in Strahnbrad.", "... but the turn-in step uses that sentence")
    check(qd("Port") == "Crane Operator Bigglefuzz in Ratchet wants you to retrieve the port from Mad Magglish who is hiding in the Wailing Caverns.",
          "objective: an Objectives sentence that names where the thing is, is used", qd("Port"))
    check(qd("Vision", "T", "Seer Wise") is None and qd("Vision", "T", "Keeper of the Seers") is not None,
          "turn-in: the ender by a whole word of the name ('Seers' is not Seer Wise)", qd("Vision", "T", "Seer Wise"))
    check(qd("Vision", fl="era") == "Drink the Water of the Seers at the fire in Ratchet." and "hydra" in (qd("Vision", fl="retail") or ""),
          "the quest giver about himself with no verb of going after 'you' is no direction; era: not a note about a later state ('previously ... now')",
          (qd("Vision", fl="era"), qd("Vision", fl="retail")))
    check(qd("Seahorn") is None, "objective: '<giver> in <place> wants you to' names only where the quest is taken", qd("Seahorn"))
    ch = qd("Chett")
    check(ch == "The seer can be found northwest of the village in a cave in the mountains (coordinates 33,36).",
          "notes: the sentence before a list (':'), a fragment and a label are left out", ch)
    check(SD.with_detail("Talk to it.", ch) == "Talk to it. " + ch and SD.NO_SPOT not in SD.with_detail("Talk to it.", ch)
          and SD.NO_SPOT in SD.with_detail("Talk to it.", "Go 30, then 40 yards north."),
          "a detail that quotes coordinates is not introduced by 'No exact spot on the wiki.'")
    check(qd("Cape", fl="era") is None and qd("Cape", fl="retail") is not None, "era: a quest note that names a later zone is not used", qd("Cape", fl="era"))
    check(qd("Noble Deaths", limit=40) is None and len(qd("Noble Deaths", limit=80)) <= 80, "the directions keep to the room the note has")

    print("review: the whole note")
    long_pre = "Speak with the keeper of the old tower. " + "Then walk on and on " * 6 + "to begin your career as a soldier of"
    check(SD.whole(long_pre) == "Speak with the keeper of the old tower.", "a prose cut at its limit goes back to its last whole sentence", SD.whole(long_pre))
    check(SD.whole("Walk on and on and on until you reach the far gate of the old city and its tow") == "Walk on and on and on until you reach the far gate of the old city and its...",
          "... or to its last whole word", SD.whole("Walk on and on and on until you reach the far gate of the old city and its tow"))
    check(SD.whole("Signet Ring (7).") == "Signet Ring (7).", "a whole note is untouched")
    for pre in ("To Maleb.", "Signet Ring (7)", "x" * 150, "y" * 150 + "."):
        det = "d" * (SD.room(pre) - 1) + "."
        check(SD.room(pre) <= SD.MAX_DETAIL and len(SD.with_detail(pre, det)) <= SD.NOTE_CAP, "room(): the whole note stays within NOTE_CAP", (pre[:12], SD.room(pre)))
    check(SD.room("z" * 190) < 20 and d.detail("era", "T", [{"title": "Magistrate Maleb"}], r, 1, "z" * 190, None, False, "Magistrate Maleb", 1, SD.room("z" * 190)) == (None, None),
          "a note with no room left gets no detail (it keeps its zone wording)")
    kind, text = d.detail("era", "C", [{"title": "Signet Ring"}], r, 7, "Signet Ring (7)", None, False, "", 1, 60)
    check(kind == "quest" or text is None or len(text) <= 60, "a detail that does not fit is shortened or replaced, never cut", (kind, text))

    kind, text = d.detail("era", "T", [{"title": "Magistrate Maleb"}], r, 1, "To Magistrate Maleb.", None, False, "Magistrate Maleb")
    check(kind == "npc", "the NPC's place comes before the quest's directions", (kind, text))
    kind, text = d.detail("era", "C", [], r, 7, "Signet Ring (7)", None, False)
    check(kind == "quest" and len(text) <= SD.MAX_DETAIL, "the quest's directions when no page gives a place", (kind, text))
    check(d.detail("era", "A", [{"title": "Zoner"}], {"page_title": "Missing"}, 4, "From Zoner.", None, False) == (None, None),
          "nothing better than the zone: the caller keeps its zone-level note")


# ---- the generator, on the real data ---------------------------------------------------------------------------
BASELINE = """import sys
sys.path.insert(0, sys.argv[1])
import step_detail as SD
SD.StepDetail.detail = lambda self, *a, **k: (None, None)
SD.StepDetail.quest_directions = lambda self, *a, **k: None
import gen_wiki_guides as G
G.main(sys.argv[2:])
"""
STEP = re.compile(r"^[ACT] .*\|QID\|\d+\|")


def part2():
    if not os.path.exists(os.path.join(ROOT, "tools", "wiki", "wiki.sqlite")) or \
            not os.path.exists(os.path.join(ROOT, "tools", "wiki", "cache", "wiki_raw.sqlite")):
        print("skip: the local wiki tables are not here (generated data is not committed)")
        return
    print("the era guides with and without the detail")
    base = os.environ.get("CR_TEST_TMP") or ("/private/tmp/claude-501" if os.path.isdir("/private/tmp/claude-501") else None)
    work = tempfile.mkdtemp(prefix="cr_test_step_detail_", dir=base)
    try:
        wdir = os.path.join(ROOT, "tools", "wiki")
        with open(os.path.join(work, "baseline.py"), "w", encoding="utf-8") as f:
            f.write(BASELINE)
        args = ["era", "--no-contributions", "--no-spine", "--out"]
        for cmd in ([sys.executable, os.path.join(work, "baseline.py"), wdir] + args + [os.path.join(work, "old")],
                    [sys.executable, os.path.join(wdir, "gen_wiki_guides.py")] + args + [os.path.join(work, "new")]):
            p = subprocess.run(cmd, capture_output=True, text=True)
            if p.returncode != 0:
                check(False, "the generator ran", p.stderr[-400:])
                return
        old = open(os.path.join(work, "old", "Imported_Wiki_era.lua"), encoding="utf-8").read().split("\n")
        new = open(os.path.join(work, "new", "Imported_Wiki_era.lua"), encoding="utf-8").read().split("\n")
        check(len(old) == len(new), "the same number of lines (no step added, dropped or split)", (len(old), len(new)))
        pointed = changed = 0
        bad = {"pointed": [], "other": [], "tags": [], "note": [], "long": [], "cap": [], "glued": [], "wording": []}
        for a, b in zip(old, new):
            if not STEP.match(a):
                if a != b:
                    bad["other"].append(b)
                continue
            if "|M|" in a:
                pointed += 1
                if a != b:
                    bad["pointed"].append(b)
                continue
            if a == b:
                continue
            changed += 1
            ia, ib = a.rfind("|N|"), b.rfind("|N|")
            if a[:ia] != b[:ib]:
                bad["tags"].append(b)
            note = b[ib + 3:]
            det = note.split(SD.NO_SPOT + " ", 1)[-1].rstrip("|")
            said = SD.NO_SPOT in note or bool(SD.RE_COORDS.search(note))     # a detail with the wiki's coordinates is not "no exact spot"
            if not note.endswith("|") or "|" in note[:-1] or not said or re.search(r"[\[\]{}<>=\x00-\x1f]|''", det):
                bad["note"].append(b)
            if len(det) > SD.MAX_DETAIL or det[-1:] not in ".!?":
                bad["long"].append(b)
            # the whole note fits the card at the least window width (a prose step's note may have lost its cut tail)
            if len(note) - 1 > SD.NOTE_CAP:
                bad["cap"].append(b)
            if re.search(r"[^.!?]\. " + re.escape(SD.NO_SPOT), note) and re.search(r"\b(?:of|the|a|to|and|in)\. " + re.escape(SD.NO_SPOT), note):
                bad["glued"].append(b)
            if ":." in det or re.search(r"\b(?:formerly|originally|previously) (?:located|found)\b", det):
                bad["wording"].append(b)
        check(pointed > 3000 and not bad["pointed"], "every step with a point is byte for byte the same", bad["pointed"][:2])
        check(not bad["other"], "nothing but step lines changed", bad["other"][:2])
        check(changed > 1000, "steps without a point got a detail", changed)
        check(not bad["tags"], "their tags, keys and order are untouched: only the note differs", bad["tags"][:2])
        check(not bad["note"], "no bar, bracket or other markup in a new note, and it says there is no exact spot", bad["note"][:2])
        check(not bad["long"], "the detail is whole sentences within the limit", bad["long"][:2])
        check(not bad["cap"], "no rewritten note is longer than NOTE_CAP (the card's 8 lines at the least width)", bad["cap"][:2])
        check(not bad["glued"], "no full stop is glued to a note that was cut mid-sentence", bad["glued"][:2])
        check(not bad["wording"], "era: no ':.' and no 'formerly located' in a detail", bad["wording"][:2])
        text = "\n".join(new)
        det = "\n".join(ln for ln in new if SD.NO_SPOT in ln)
        m = re.search(r"\|N\|To Marshal Maxwell\. ([^|]*)\|", text)
        check(m and "Morgan's Vigil" in m.group(1) and "Blackrock Depths" not in m.group(1),
              "era: Marshal Maxwell is at Morgan's Vigil, not in Blackrock Depths", m and m.group(1))
        for later in ("Ruins of Auberdine", "Speedbarge", "Darkmoon Island", "Shattrath", "Icecrown", "Cape of Stranglethorn", "Fenris Keep",
                      "Alterac Valley in the Hillsbrad", "Ruins of Alterac in the Hillsbrad", "Doomsayer Wiserunner", "Quel'Lithien Lodge in"):
            check(later not in det, "era: no detail says '" + later + "'", [ln[-200:] for ln in new if SD.NO_SPOT in ln and later in ln][:1])
        m = re.search(r"C Smelt on, Smelt off\|QID\|2761\|[^\n]*\|N\|([^|]*)\|", text)
        check(m and "Galvan" not in m.group(1), "era: an objective step does not get the hand-in sentence (Smelt on, Smelt off)", m and m.group(1))
        m = re.search(r"\|N\|To Magistrate Henry Maleb\. ([^|]*)\|", text)
        check(m and "Southshore" in m.group(1) and "Shadowfang" not in m.group(1),
              "era: Magistrate Henry Maleb is in Southshore, not in Shadowfang Keep", m and m.group(1))
        check("Northern Barrens" not in "".join(ln for ln in new if SD.NO_SPOT in ln) and "Zephras" not in
              "".join(ln for ln in new if SD.NO_SPOT in ln), "era: no later zone name and no WoW Forever place in a detail")
        print(f"     {pointed} steps with a point unchanged, {changed} notes of steps without one rewritten")
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    part1()
    if "--no-gen" not in sys.argv[1:]:
        part2()
    print(f"{checks} checks, {fails} failed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

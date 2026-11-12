# Offline measurement only: never part of the build

Nothing in this folder is loaded by a TOC, installed by `tools/install.sh`, packaged by `tools/package_release.py`,
baked into a route order or read by any generator's default run. It exists for one question the owner may still ask:
**how many quest steps that have no point in the build would a reference database locate, and which wiki points lie
far from that reference?**

```
heavy.sh python3 tools/wiki/gen_wiki_guides.py --measure-fallback [era tbc mop retail forever]
heavy.sh python3 tools/coverage.py --guides tools/measure/out --db tools/measure/out/coverage.sqlite --label fallback-compare
```

| Path | What | Tracked |
|---|---|---|
| `tools/measure/questie/Imported_Quests_<era, tbc, mop, retail>.lua` | the reference: older quest guides made from a local Questie checkout (retail: Blizzard quest POI plus Questie givers). Generated before 2026-11-11 by tools now in `archive/questie-tooling/`. Forever uses the era file. | no (gitignored) |
| `tools/measure/out/Imported_Wiki_<flavor>.lua` | the comparison file: the wiki guides with reference points filled in. Its first statement is `error(...)`, so a client that loaded it would stop; the installer and the packager refuse its content. | no (gitignored) |

The run also writes two things into `docs/verification.sqlite`: the `wiki_point_sources` row of build `fallback`
(the build's own row is `no-fallback`) and table `wiki_fallback_conflict` (wiki points more than 300 yd from the
reference). It writes nothing under `CompletionRoute/`, and does not touch `tools/wiki/wiki.sqlite`, the spine or
`wiki_db2_conflict`. The second command charts the comparison in its own SQLite file, not in the project's.

Rules: never copy a file from here into `CompletionRoute/`. A reference point must never be written into a shipped
file by hand either; a wrong wiki point is fixed on the wiki or from Blizzard data.

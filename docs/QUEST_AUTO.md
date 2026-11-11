# Auto accept and turn-in (`Core/QuestAuto.lua`)

IDEAS #7, branch `auto-quest`, 2026-11-10. **Nothing here has run in a real WoW client.** It is tested offline only,
against fake quest-dialog clients (`tools/test_quest_auto.lua`). Daniel's beta is the first real test.

## What the player sees

* Off by default. Turn it on in **Options > CompletionRoute > Auto quests**, or with `/cr auto on`.
* With **Auto accept** on, talking to a quest giver accepts the quests the guide is about to ask for. With **Auto turn
  in** on, it hands in the guide's finished quests and takes the reward when there is nothing to choose.
* Everything else is left to the player: quests the guide does not want yet, quests that cost gold, a reward choice,
  a full quest log (chat says so).
* Hold **Shift** (or the key chosen in Options; Ctrl, Alt or none) when you talk to a quest giver to do it yourself.

`/cr auto` shows the settings and the last decision with its reason ("left alone: not in window", "costs gold" ...).
`/cr auto accept`, `/cr auto turnin` and `/cr auto reward` toggle one setting; `/cr auto on|off` sets accept and turn-in
together; `/cr auto key shift|ctrl|alt|none` picks the pause key. `/cr bug` reports include the settings and the last
eight decisions (`options.questAuto`).

## The rules

A quest is only ever touched when it belongs to a step of the **live window**: `P.order` in `Core/Progress.lua`, the
next `routing.window + 5` pending steps (24 + 5 by default) that the guide frame and the arrow follow. Any step of the
quest counts (accept, objective or turn-in). The rest of the guide never counts.

Checked in this order; the first one that fails leaves the dialog alone:

| Check | Accept | Turn in |
|---|---|---|
| The option is on | `autoAccept` | `autoTurnin` |
| The pause key is not held, and the conversation was not paused by it (below) | yes | yes |
| A quest giver is there: `UnitGUID("npc")` (or `"questnpc"`). Accept also allows a quest started from an item (`QUEST_DETAIL`'s `questStartItemID`) | yes | yes |
| Not a quest the game already accepted (`QuestGetAutoAccept`), not an area offer (`QuestIsFromAreaTrigger`), not a world or task quest | yes | - |
| Not dropped or locked by `Core/Skip.lua` (`/cr skip`) | yes | yes |
| In the live window | yes | yes |
| The player did not skip an accept step (for accept) or a turn-in step (for turn-in) of that quest in this guide | yes | yes |
| Costs no gold (`GetQuestMoneyToGet() == 0`) | yes | yes (on the progress page) |
| Not a daily, weekly or repeatable, unless its window step is that daily: a `!` step, or the guide is a Dailies or Daily Gold guide | yes | - |
| The quest log has room (`Router.QuestLog()`: count and `C_QuestLog.GetMaxNumQuestsCanAccept`); if not, one chat line says so | yes | - |
| Progress page: `IsQuestCompletable()` is true | - | yes |
| Reward page: 0 or 1 choice. With 2 or more it stops, leaves the dialog open and says so in one chat line, unless `autoChooseReward` is on and `ItemScore.ClearWinner` finds a clear upgrade | - | yes |

**Pause key.** Holding it on any dialog pauses the whole conversation with that quest giver: the quest text that follows
a gossip pick, the reward page after the progress page. The pause lasts while that NPC's dialogs keep coming at most
10 s apart (`QA.PAUSE_GAP`), so letting go of the key mid-conversation does not start clicking.

**Reward choice** (`UI/ItemScore.lua`, `IS.ClearWinner`). A choice wins only if every choice's item data has arrived, the
class can use it (`GetQuestItemInfo`'s `isUsable`), it beats what is worn in that slot by 10% or more (`IS.CLEAR_PCT`),
and it gains at least 1.5 times as much score as any other choice (`IS.CLEAR_RATIO`). The weights are per class, not
per spec, and have no item level, which is why anything less than clear is left to the player.

**No loops, one action per event.** Each dialog event makes at most one call that changes something. A quest picked from
an NPC's list is not picked again at that NPC for 60 s (`QA.MEMORY_S`), so a quest that was declined, or refused when
its text came up (gold, log full), is never re-opened in a loop. A repeated list event of the same NPC within 2 s waits
for the dialog to move on (Blizzard can fire `GOSSIP_SHOW` twice). Turn-ins are picked before accepts, because one may
open the next quest at the same NPC.

**Follow-ups.** Progress rebuilds `P.order` 0.3 s after a quest is accepted or turned in. A quest the same NPC offers at
once (its `|PRE|` is the quest just taken) must already count, so until that refresh the window is read straight from
`P.Pending(routing.window + 5)`: the same steps (the live reorder only permutes them). A full `P.Refresh()` there was
measured at up to about 20 ms; the pending read costs 0.06 to 0.34 ms.

## Events

| Event | What it does |
|---|---|
| `GOSSIP_SHOW` | Picks one quest from the NPC's gossip lists: a finished window quest to turn in first, else a window quest to accept |
| `QUEST_GREETING` | The same for a quest giver with several quests and no gossip text |
| `QUEST_DETAIL` | `AcceptQuest()` when the accept rules pass |
| `QUEST_PROGRESS` | `CompleteQuest()` (goes on to the reward page) when the turn-in rules pass and `IsQuestCompletable()` |
| `QUEST_COMPLETE` | `GetQuestReward(0)` with no choice, `GetQuestReward(1)` with one, the clear winner when allowed, else stops |
| `QUEST_ACCEPT_CONFIRM` | A party member started an escort: `ConfirmAcceptQuest()` only if that quest is in the window (then hides the `QUEST_ACCEPT` popup) |
| `GOSSIP_CLOSED`, `QUEST_FINISHED` | The dialog moved on: a repeated list event may act again |
| `QUEST_ACCEPTED`, `QUEST_TURNED_IN`, `QUEST_REMOVED` | The window is read from the pending steps until Progress refreshes |

## Client API matrix

One addon runs on five clients. Every function is looked up when it is called, never at load time, so a client that
lacks one simply skips that path. Source: the warcraft.wiki.gg API pages and their game-type lists (standard =
Retail 12.1.5, forever = WoW Forever 1.60.1, mists = MoP Classic 5.5.4, tbc = TBC Anniversary 2.5.6, vanilla = Classic Era
1.15.9), read on 2026-11-10. There are no FrameXML or API dumps on this Mac, so where the wiki has no page the row says so.

| API | Retail | Forever | MoP Classic | TBC Anniv. | Era | Use |
|---|---|---|---|---|---|---|
| `C_GossipInfo.GetAvailableQuests`, `GetActiveQuests` | yes | yes | yes | yes | yes | Gossip lists with `questID`, `frequency`, `repeatable`, `isComplete`, `isIgnored`. Wiki: Retail since 9.0.1, Era since 1.14.4, TBC since 2.5.5, the Wrath-to-MoP Classic line since 3.4.1 |
| `C_GossipInfo.SelectAvailableQuest`, `SelectActiveQuest` | yes | yes | yes | yes | yes | Called with the quest id (the wiki: the argument became an option id, the quest id, in 10.0.0) |
| `GetGossipAvailableQuests`, `GetGossipActiveQuests`, `SelectGossip*Quest(index)`, `GetNumGossip*Quests` | no | no | no | no | no | Removed in 9.0.1 / 1.14.4 / 2.5.5 / 3.4.1. Kept as a fallback for older builds: groups of 7 (available) or 6 (active) values, plus a quest id where a build appended one; title match otherwise |
| `QUEST_GREETING`, `GetNumAvailableQuests`, `GetNumActiveQuests` | yes | yes | yes | yes | yes | The greeting frame |
| `GetAvailableQuestInfo(i)` (5th return `questID`) | yes | yes | yes | yes | yes | The id was added in 9.0.1 on Retail; the wiki does not say whether the Classic clients return it, so a missing id falls back to the title |
| `GetAvailableTitle`, `GetActiveTitle`, `SelectAvailableQuest(i)`, `SelectActiveQuest(i)`, `GetActiveQuestID(i)` | ? | ? | ? | ? | ? | No warcraft.wiki.gg page found (the API wiki is under extended maintenance). Used only if present; the greeting path does nothing without the select functions; without `GetActiveQuestID` the title is matched; without `GetActiveTitle`'s second return the quest log decides "complete" |
| `QUEST_DETAIL` (payload `questStartItemID`), `GetQuestID`, `AcceptQuest`, `QuestIsDaily` | yes | yes | yes | yes | yes | Accept |
| `QuestIsWeekly` | yes | yes | no | no | no | Wiki lists Retail and Forever only |
| `QuestGetAutoAccept`, `QuestIsFromAreaTrigger`, `C_QuestLog.IsWorldQuest`, `C_QuestLog.IsRepeatableQuest` | yes | yes | no | no | no | Popups and repeatables; absent on the classic clients (nothing to guard there) |
| `IsQuestCompletable`, `CompleteQuest`, `GetNumQuestChoices`, `GetQuestItemInfo` (5th return `isUsable`), `GetQuestItemLink`, `GetQuestReward` | yes | yes | yes | yes | yes | Turn-in and reward |
| `GetQuestMoneyToGet` | ? | ? | ? | ? | ? | No wiki page found; long-standing quest-frame function. If a client lacks it the gold check passes (see open questions) |
| `QUEST_ACCEPT_CONFIRM` (`name`, `questTitle`), `ConfirmAcceptQuest` | yes | yes | yes | yes | yes | Escort shares. The third payload value `questID` was added in 12.0.5 (Retail); elsewhere the title is matched |
| `C_QuestLog.GetMaxNumQuestsCanAccept` | yes | yes | yes | yes | yes | Log cap (`Routing/Router.lua` `R.QuestLog`, with a per-flavor fallback) |
| `UnitGUID("npc")` | yes | yes | yes | yes | yes | "Is there a quest giver". Not confirmed for game-object quest givers (wanted posters); if it is nil there, those are left to the player |

Frequency values: `C_GossipInfo` and the greeting frame are read with `Enum.QuestFrequency` (Daily, Weekly,
ResetByScheduler) where the client has it, the old gossip API with `LE_QUEST_FREQUENCY_*`. `QuestIsDaily()` on the quest
text decides in the end.

## Tests and measurements

`luajit -joff tools/test_quest_auto.lua [flavors]` (1,154 checks on all five flavors on 2026-11-10, all pass). The real addon files
run on `tools/stubs.lua` with a fake dialog client per API family (`gossip`, `old`, `greeting`) on each flavor, with the
optional APIs only where the real client has them. Each rule above has a check, and every event is checked to make at
most one call. Thirteen deliberate breakages of `Core/QuestAuto.lua` (no window check, no skip check, no pause key, no
completable check, no gold check, always take the reward, no Skip check, no pending read, no pick memory, no busy
check, no popup guard, dailies always allowed, no log cap) each made the harness fail.

CPU of one decision (`luajit -joff`, the biggest wiki guide of each flavor that leaves a window, 202 to 245 steps):
about 0.01 ms per dialog event; right after a quest change (window from the pending steps) 0.06 ms (mop) to 0.34 ms
(retail), max 0.34 ms over 30 calls each. Measured with a route bake running on the same Mac.

## Not verified / open questions

* Nothing has run in a client: the event order, the payloads and the select-by-quest-id behaviour of every client are
  from the wiki, not observed.
* Whether `UnitGUID("npc")` is set for game-object quest givers (wanted posters, books). If not, they are not automated.
* Whether the classic clients return the quest id from `GetAvailableQuestInfo`; the title fallback compares the client's
  quest name (when it knows it) and the guide's step titles, so it may miss on non-English clients.
* `GetQuestMoneyToGet` at the quest-text stage: the check assumes it returns the money the quest needs.
* A reward whose item data has not arrived yet is never chosen; the dialog stays open (no retry when the data arrives).
* Players who use another auto-quest addon at the same time get two addons answering the same dialog; nothing detects that.

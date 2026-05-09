# Intern

A personal daily- and repeatable-quest tracker for WoW Classic-flavored
clients (Anniversary, Classic Era, and historically TBC / WotLK / Cata).

Intern keeps an opt-in list of dailies, reputation grinds, Children's Week
quests, "Wanted" bounties and honor quests, and shows what's left to do
today (and this month) in a small floating tracker window. It knows when
you've capped a faction so the relevant rep quest disappears from your
list automatically — no manual pruning.

## Features

- **Opt-in tracking.** Browse the full known-quest list and pick what you
  care about. The default set covers common dailies; the rest is yours
  to curate.
- **Floating tracker** with Questie-style chrome, click-to-collapse
  section and category headers, and click-an-entry to jump the quest
  log to that quest.
- **Reputation-cap awareness.** Tracks per-quest reputation caps (not
  just Exalted) — e.g. Sha'tar spillover quests stop showing once the
  Sha'tar bar hits Revered. Configurable: track everything, or hide
  rep quests once the cap is reached.
- **Faction-aware sub-grouping.** Reputation quests are grouped under
  the faction they actually move, both in the browse list and the
  tracker.
- **Children's Week race/faction filtering.** Auto-hides cross-faction
  CW variants based on orphan NPC and known race-locked quests.
- **Monthly tracking.** Quests like Consortium Membership Benefits
  (9884–9887) reset monthly rather than daily; Intern persists that
  state across sessions.
- **Honor quests, "Wanted" bounties, and dungeon quests** in their own
  categories.
- **Per-character state.** Tracked set, completion state, tracker
  layout, and collapsed sections all persist per character.
- **Minimap button** via LibDBIcon-1.0.

## Slash commands

| Command | Action |
|---|---|
| `/intern` | Open the main browse window. |
| `/intern tracker` | Toggle the floating tracker. |
| `/intern options` | Open the options panel. |
| `/intern reseed` | Re-apply the default tracked set (merges with existing — won't wipe your picks). |
| `/intern done <partial title>` | Retroactively mark a daily or monthly quest as completed (substring match on title). Useful when you turned a quest in before Intern was watching. |

## Install

### From CurseForge
*(Pending project approval.)*

### Manual
1. Download or clone this repo.
2. Drop the `Intern/` folder into
   `World of Warcraft/_classic_era_/Interface/AddOns/` (or
   `_anniversary_`, `_classic_`, etc., depending on your client).
3. Make sure **Ace3** and **LibDBIcon-1.0** are installed (separate
   addons — see below).
4. Restart WoW (a `/reload` is not enough the first time, because the
   `## Category:` TOC field is read on client start).

## Dependencies

- **Ace3** — required.
- **LibDBIcon-1.0** — required (for the minimap button).
- **LibDataBroker-1.1** — bundled.

When installing from CurseForge, the dependencies will be pulled
automatically by the CF/Overwolf client.

## Compatibility

TOC declares Interface IDs `11508` (Anniversary / Classic Era),
`20505` (TBC Classic), `30405` (WotLK Classic), and `40402` (Cataclysm
Classic). Active development and testing happens on the **Anniversary**
client — other flavors should work but receive less attention.

## License

[Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
(CC BY-NC-SA 4.0)](LICENSE).

You're welcome to fork, modify, and redistribute Intern, including the
modified version, as long as you (a) credit the original, (b) license
your derivative under the same terms, and (c) don't use it commercially.

## Author

Saiba.

# Changelog

GearFall — route Warbound gear to the alt that needs it most.

## Unreleased

### Added

- **Flush a stale "incoming gear" ledger.** An upgrade you mailed to an alt
  used to haunt them forever if the letter got returned or expired: its slot
  stayed blocked and the window kept "Arrived - equip it" state for gear that
  would never arrive. Now there's a way out: `/gear flush` clears the
  character you're playing, `/gear flush <alt>` or `/gear flush all` reach
  the others (all with a confirm), and the Distribution window shows a small
  orange "!" next to the Rescan button whenever upgrades promised to you are
  not visible anywhere — right-click it to clear the promise. The tooltip is
  honest: the mail may simply still be in transit.

## 0.2.2 - 2026-10-10 (stable)

### Fixed

- **Grey/white items are no longer suggested as "save for later" when they can
  never be an upgrade.** A Poor or Common item whose target slot is already
  worn (or awaited in the mail) at Uncommon quality or better can never beat
  it, no matter the level or the raw item level.

## 0.2.1 - 2026-10-10 (beta)

### Added

- Added a CHANGELOG and automation to upload new versions automatically 
  from GitHub to CurseForge, WoWInterface, and wago.io.

## 0.2.0 - 2026-10-10 (beta)

### Added

- **Ignore items** — keep items out of every scan and suggestion. A small
  shipped default list is ignored out of the box. You can ignore an item
  permanently, or ignore a single copy of an item — handy for gear you want
  to stash or sell; the ignore follows that exact copy through relogs, mail
  and trades, while other copies of the same item are judged normally.
  Right-click a row in the Distribution window, or use
  `/gear ignore <item> [once]`, `/gear ignore remove <item>` and
  `/gear ignore list`.

- **Equip Arrived** — a new one-click button in the Distribution window
  (bottom-left) that appears when an arrived upgrade is waiting for the
  character you're playing — in your bags or still in the mailbox. One
  click claims your arrived copies from the inbox and equips them one by
  one. If the game asks for confirmation (e.g. soulbound equips),
  the run politely waits for you to answer.

- **The Distribution window now opens by itself at the mailbox** when gear
  mailed to you is still sitting in the inbox, shown as
  "Arrived - equip it" rows — in addition to the existing trigger (mailable
  upgrades found in your bags).

- **Mailed upgrades are recognized on arrival.** An upgrade you mailed to
  your alt used to be judged as "not an upgrade" once it landed — because
  the next alt in line was a better fit — and got re-drafted away. Arrived
  gear is now pinned to you ("Arrived - equip it") until you equip it. If
  you equipped something better in the meantime, the item moves on down
  the roster as before.

### Fixed

- Gray (Poor) and white (Common) items are no longer suggested as upgrades
  when the slot already holds — or is about to receive by mail — a
  green-or-better item, whatever raw item level says. A statless item can
  now only fill an empty slot or replace other statless gear, and is
  flagged "safe to sell/enchant" otherwise.

- Guns, bows and crossbows now correctly count as two-handed weapons: a
  worn ranged weapon no longer leaves the off-hand looking "empty", so
  Survival hunters stop getting off-hand daggers drafted at them. Wands
  remain one-handed, so wand + off-hand frill stays legal. Gun-to-gun
  swaps keep working as plain upgrades.

- The Distribution window now keeps itself fresh: after looting or bag
  changes it rescans and self-corrects, instead of showing a stale plan
  until you hit Rescan manually.

## 0.1.1 - 2026-09-19 (beta)

### Fixed

- The dashboard no longer fails to build on the very first run of a fresh
  session ("Couldn't find inherited node CollectionsPagingFrameTemplate").

## 0.1.0 - 2026-09-19 (beta)

First tagged version. The full core flow works end to end: the addon
snapshots every alt's gear, scans your bags (and the open mailbox) for
Warbound/BoE gear, decides per item which alt benefits most, and assists
or performs the mail delivery.

### Alt roster

- Automatic per-alt snapshots on login and live recapture on
  equipment/level/spec changes: class, level, active spec, role, average
  item level, and the item in each of the 16 equipment slots, stored
  account-wide so any character can read any other's last-known state.
- Priority list on the Roster tab: priority tiers with dividers,
  drop-into-tier drag-and-drop, an exclusion drop-zone for alts that must
  never receive mail, free-form decorative tags, and a per-alt "Rules"
  dropdown. Hovering a row shows the full alt tooltip.

### Sendable scan

- Bags are scanned for Warbound-until-equipped and BoE items using the
  item's actual bound state.
- While a mailbox is open, the inbox is treated as a second inventory:
  every attachment is a scan-only candidate. Mail attachments are never
  auto-attached or mailed; claim them manually and rescan.
- The Sendable tab shows the current scan as an icon grid with per-item
  verdicts, live-refreshing as things move, and a "View from: \<alt\>"
  selector that re-judges every item for one chosen alt.

### Scoring & eligibility

- Per-alt scoring mode: Pawn scale (optional) or flat item level. Any
  positive delta counts as an upgrade; the first eligible, upgrading alt
  in priority order wins the item.
- Eligibility gates: class, level, armor tier (strict mode toggle),
  weapon-type rules including 2H vs 1H+offhand load-out swaps, and a stat
  sanity check for items the game won't describe.
- Respec-aware suggestions: items no current spec can use but a sibling
  spec could are held ("Respec required") instead of silently rejected.
- Trinket role classification: an in-game learned, per-class library of
  which specs use which trinkets, browsable via `/gear itemspecs`.

### Distribution window (mail assist)

- Docks next to the mailbox, auto-opens when a real upgrade exists, and
  groups rows into per-recipient mailable upgrades, "keep for yourself",
  and hold sections (level-up, load-out swap, respec) with per-alt
  segments and explanatory tooltips.
- "Mail All Upgrades" sends after a confirmation popup: each alt receives
  their own mail, batched to the attachment limit, with send success and
  failure handled per letter. Holds, non-upgrades and mailbox attachments
  never enter the plan.
- Every mailed item is logged to the send history (capped at 200), shown
  newest-first on the History tab.

### Dashboard & commands

- Dashboard tabs: Roster (priority list), Sendable, Settings (gearing
  rules, scoring modes, tags), History.
- Gearing-rule settings with per-alt override → account-wide → default
  resolution: `strictArmorType` (on) and `allowWeaponLoadoutSwap` (off).
- Commands: `/gear` (dashboard), `/gear mail`, `/gear update`,
  `/gear itemspecs`, `/gear wipe`; diagnostics via `/gear debug`.
  Destructive commands confirm first.

### Known limitations

- Mail is the only transfer path
- Only the active spec and currently equipped gear are considered.

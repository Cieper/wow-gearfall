# GearFall — Route Warbound gear to the alt that needs it most

GearFall is a gear-distribution planner for alt-aholics on WoW: Midnight. It learns about your characters, scans your bags and mailbox for Warbound-until-equipped and BoE gear, decides per item which alt benefits most, and gets it there with one click at the mailbox. No more vendoring a staff your mage would have loved, no more struggling on your new rogue while a pair of epic daggers collect dust in your bank.

**How it works:** Whenever you play a character, GearFall records your class, level, spec, and equipment — and keeps that picture current as you gear up. Open your mailbox and it scans your bags and mailbox for Warbound or BoE gear, walks your priority list, and shows the plan: "Those shoulders you looted from that rare are an upgrade for your Paladin, and the staff is an upgrade for your Druid." Like some characters more than others? Prioritize them — your Warrior gets upgraded before your Rogue. No background scanning: it costs nothing during normal play.

**Features:**

- **Priority tiers & roster** — drag alts into tiers, hide bank alts in a never-send exclusion zone, tag characters freely, and re-judge every item from any alt's perspective on the Sendable tab ("Planned: +40 iLvl," "Priority: Jane gets it (+300 vs your +40)").
- **Distribution window** — docks beside your mailbox and auto-opens when a real upgrade exists, grouped by recipient. Hit "Mail All Upgrades" and each alt receives their own mail with the new gear.
- **Loot from Mail** — got a mailbox full of gear where not everything is an upgrade? Cherry-pick the winners out and ignore the rest.
- **Smart about gear upgrades** — it respects your load-outs. Want to use a staff on an elemental Shaman? Holding an off-hand because you found a great main hand? That's fine! GearFall respects your choices that make sense, and fixes mistakes that may have snuck in over time. No more agility polearms on your Boomkin, and let's fix those mail bracers your DK accidentally equipped.
- **A use for every item** — items nobody can use *yet* are kept aside for now: "Requires Level 90," a load-out swap, or "A Holy spec could use this — keep it until you respec." And when no alt could ever use it but a class you haven't rolled would: **"ROLL ONE!"** — make that Demon Hunter instead of vendoring those warglaives. Items that fit but upgrade nobody are flagged safe to sell or disenchant, so destruction is never a gamble.
- **Item level by default, Pawn when you want it** — every alt is scored out of the box with a flat item level. Using Pawn to gear up alts? Install it, switch the alt to Pawn scoring in the roster, and GearFall scores with that alt's Pawn scale — the right scale is picked per spec automatically. Your draft strategy: biggest upgrade wins, or highest priority tier. Your current character competes too — winning items become "Keep for yourself" instead of mail.
- **A learned trinket brain** — every character that logs in teaches a per-class library of which specs use which trinkets, browsable via `/gear itemspecs`.
- **Send history** — every mailed item logged with the reason why.

**Beta limitations:**
- mail is the only transfer method.
- It won't distribute bank or warbank gear yet.

**Commands:** `/gear` or `/gearfall` opens the dashboard; `/gear mail`, `/gear update`, `/gear itemspecs`, `/gear help`, plus `/gear debug` diagnostics. Destructive commands confirm first.

**Planned features:**

- **Bank & Warband Bank scanning** — extend the scan to items parked in your bank and Warband Bank whenever they're open, so nothing stashed away escapes a verdict.
- **A respec-suggestion toggle** — Better off-spec support, for players who'd rather not have items held for specs their alts don't plan to play.
- **A better Settings tab and a minimap button** — the current one is a little barebones and could do with some easier configuration.

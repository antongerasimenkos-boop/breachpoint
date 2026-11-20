# Balance

The owner's first playtest verdict: "winning as builders is basically impossible." This document
records how that was measured, what was changed, and the final numbers.

## Method

`lune run balance` plays seeded, headless Build + Hunt rounds on the **real game modules**:
`Config` (every number), `BlockGrid` (placement, support, damage, repair), `Cooldowns`, and the bot
brains that the Studio practice bots also run:

- **FortPlanner:** a team fort of concentric two-high rings around the builders, with the block
  kind per ring chosen to maximise the weakest column.
- **HunterBrain:** Dijkstra over ground columns (travel time + time to break), so it attacks the
  weakest point. It tags with line of sight, uses Shockwave when surrounded and Sprint on long runs.
- **BuilderBrain:** repair the most damaged block in reach.

`lune run balance calibrate` bisects the hunter damage multiplier per team size until builders
win about 50%, and prints the table to paste into `Config.Hunter.DamageByBuilders`.

### Model assumptions (what the simulation does *not* capture)

| Assumption | Effect on the numbers |
|---|---|
| Hunter skill per round is drawn from [0.5, 1.0]: each breach swing lands with that probability (a miss still costs the cooldown), Shockwave is used with the same probability, and decisions take 0.2–0.45 s | Spreads outcomes the way uneven players do |
| Each builder's repair attention is drawn from [0.4, 0.95] (share of repair opportunities used) | Same |
| Builders waste 0–20% of their budget (misplaced or decorative blocks) | Same |
| Builders stand still inside the fort; real players can also dodge | Slightly pessimistic for builders |
| Straight-line movement between grid columns, no physics or terrain | Hunter travel is a little optimistic |
| Spike traps and doors are not simulated | Traps only slow the hunter, so builders are slightly underrated |
| The build phase is long enough to place the whole plan | True for bots (40 s practice, 50 s live) |

## Why builders lost in v1

Replaying the v1 numbers through the same simulation (`lune run balance 200 markdown v1`):

| Builders | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| Builder win % | 0% | 0% | 0% | 0% | 6% | 34% |
| Hunter wins after (avg) | 4 s | 8 s | 21 s | 29 s | 60 s | 66 s |
| Wall HP per column | 12 | 12 | 24 | 29 | 27 | 32 |

1. **Tags through a single broken block from outside the wall.** Tag reach was 7 studs + 4 leeway
   = 11, while the outside of a one-cell wall is 8 studs from the builder. One broken block ended
   the round.
2. **Paper walls.** Stone had 6 HP against a hunter doing ~2.9 damage per second.
3. **Tiny budget.** 40 points bought one thin ring.
4. **Hunt too long for the walls.** At 90 s, even decent forts fell.

## Iterations

| # | Change | Result (builder win %, 1→6 builders) | Lesson |
|---|---|---|---|
| 1 | Tag 4.5 + 3 leeway, block HP ×2.5–3.5, budget 64, Hunt 75 s, repair 2 HP/s, per-block repair cooldown | 54 / 58 / 58 / 34 / 48 / 38; upgrades: 100% or 0% | Repair speed close to hunter damage: time to breach = HP / (damage − repair) divides by ~0, so tiny changes flip rounds |
| 2 | Repair 1 HP/s, smaller upgrades, wider skill spread, refit damage table | Baseline 46 / 55 / 48 / 51 / 55 / 53; upgraded builders ~100%, upgraded hunter ~5% | Baseline fine; upgrades still decisive |
| 3 | Higher tiers trade efficiency for density, Bloodhound −1 s, builders waste 0–20% budget | 56 / 44 / 57 / 52 / 48 / 55; upgraded builders 77–100% | Calibration drove hunter damage down to ~0.5×, right back onto the repair knife-edge |
| 4 | Block HP ×2 so repairs are small relative to walls | 52 / 49 / 60 / 49 / 54 / 49; upgrades still 100% / 4% | Still steep |
| 5 | **No repairs under fire:** a block breached in the last 2 s can't be repaired | 51 / 52 / 56 / 58 / 53 / 68; still steep | Something else was making outcomes deterministic |
| 6 | **Model bug fixed:** skill was rolled every 0.1 s tick, so a "0.5 skill" hunter only swung a moment later (±12% damage). Now one roll per swing (a miss costs the cooldown) and Shockwave use is skill-gated. Shockwave damage 3 → 2, and its splash no longer locks repairs. The bot hunter got the same fix | Baseline 57 / 47 / 56 / 53 / 47 / 49; upgraded hunter 33–46%; upgraded builders 76–100% | Win-rate curve now smooth (~2 points per 1% of damage or wall HP) |
| 7 | Builder upgrades sized to that slope: Deep Pockets +6 → +2 budget, Metal 64 → 56 HP, Titanium 112 → 84 HP | see final table | Tuning stopped here (two iterations after #6, as agreed) |

## Final numbers

`lune run balance 200 markdown`: 200 seeded rounds per row, Hunt 75 s. "Hunter win time" is the
average over rounds the hunter won.

**Summary (builder win %, 1 → 6 builders):**

| Scenario | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| v1 (0.1.0) | 0 | 0 | 0 | 0 | 6 | 34 |
| **Final baseline (free kit)** | **56** | **46** | **56** | **48** | **46** | **50** |
| Builders fully upgraded vs base hunter | 63 | 58 | 74 | 69 | 60 | 67 |
| Hunter fully upgraded vs base builders | 46 | 38 | 44 | 34 | 34 | 36 |
| Both sides fully upgraded | 54 | 46 | 60 | 55 | 49 | 55 |
| Builders spend 6 budget on a generator | 56 | 46 | 51 | 42 | 43 | 50 |

Current hunter damage table: `DamageByBuilders = { 0.55, 0.77, 1.11, 1.42, 1.54, 1.74 }`.

**Against the target:**

- **Baseline, 45–55% at every team size:** met within sampling error. 1 and 3 builders sit at 56%,
  one point over and well inside the ±7 confidence interval.
- **No upgrade combination near 0% or 100%:** met. The extremes are 74% (3 fully upgraded builders
  against a base hunter) and 34% (fully upgraded hunter against 4–5 base builders). With both
  sides upgraded, results return to 46–60%.
- **Remaining gap, stated plainly:** a fully upgraded builder team still beats an un-upgraded
  hunter 58–74% of the time. This is a deliberate progression edge; whether it is too much is a
  design call for live data. The levers are Titanium HP and Deep Pockets.
- **Generator:** spending 6 budget on a coin generator costs a 4–6 point win chance at 4–5
  builders. That is the intended risk/reward.

**Full tables:**

Baseline: free kit (Wood + Stone), no perks or upgrades
| Builders | Builder win % (95% CI) | Hunter win time (avg s) | Wall HP / column | Blocks | Breaks | Repairs |
|---|---|---|---|---|---|---|
| 1 | 56% (± 7) | 64 | 80 | 16 | 1 | 45 |
| 2 | 46% (± 7) | 64 | 112 | 64 | 4 | 87 |
| 3 | 56% (± 7) | 65 | 165 | 72 | 4 | 133 |
| 4 | 48% (± 7) | 64 | 207 | 120 | 5 | 171 |
| 5 | 46% (± 7) | 64 | 215 | 144 | 7 | 167 |
| 6 | 50% (± 7) | 65 | 240 | 144 | 6 | 201 |

Builders fully upgraded (Metal, Titanium, Deep Pockets, Quick Hands) vs base hunter
| Builders | Builder win % (95% CI) | Hunter win time (avg s) | Wall HP / column | Blocks | Breaks | Repairs |
|---|---|---|---|---|---|---|
| 1 | 63% (± 7) | 65 | 85 | 16 | 1 | 52 |
| 2 | 58% (± 7) | 64 | 119 | 64 | 3 | 101 |
| 3 | 74% (± 6) | 69 | 179 | 55 | 3 | 155 |
| 4 | 69% (± 6) | 67 | 224 | 81 | 4 | 206 |
| 5 | 60% (± 7) | 65 | 224 | 109 | 4 | 214 |
| 6 | 67% (± 7) | 68 | 261 | 120 | 6 | 266 |

Hunter fully upgraded (Heavy Hitter, Bloodhound) vs base builders
| Builders | Builder win % (95% CI) | Hunter win time (avg s) | Wall HP / column | Blocks | Breaks | Repairs |
|---|---|---|---|---|---|---|
| 1 | 46% (± 7) | 63 | 80 | 16 | 2 | 44 |
| 2 | 38% (± 7) | 62 | 112 | 64 | 4 | 85 |
| 3 | 44% (± 7) | 63 | 165 | 72 | 4 | 129 |
| 4 | 34% (± 7) | 62 | 207 | 120 | 6 | 164 |
| 5 | 34% (± 7) | 62 | 215 | 144 | 9 | 161 |
| 6 | 36% (± 7) | 63 | 240 | 144 | 6 | 194 |

Both sides fully upgraded
| Builders | Builder win % (95% CI) | Hunter win time (avg s) | Wall HP / column | Blocks | Breaks | Repairs |
|---|---|---|---|---|---|---|
| 1 | 54% (± 7) | 63 | 85 | 16 | 1 | 50 |
| 2 | 46% (± 7) | 63 | 119 | 64 | 3 | 99 |
| 3 | 60% (± 7) | 66 | 179 | 55 | 3 | 152 |
| 4 | 55% (± 7) | 66 | 224 | 81 | 4 | 202 |
| 5 | 49% (± 7) | 63 | 224 | 109 | 5 | 209 |
| 6 | 55% (± 7) | 65 | 261 | 120 | 6 | 263 |

Builders spend 6 budget on a coin generator
| Builders | Builder win % (95% CI) | Hunter win time (avg s) | Wall HP / column | Blocks | Breaks | Repairs |
|---|---|---|---|---|---|---|
| 1 | 56% (± 7) | 64 | 80 | 17 | 1 | 45 |
| 2 | 46% (± 7) | 64 | 112 | 65 | 4 | 87 |
| 3 | 51% (± 7) | 65 | 160 | 65 | 3 | 132 |
| 4 | 42% (± 7) | 63 | 199 | 121 | 6 | 168 |
| 5 | 43% (± 7) | 63 | 211 | 145 | 7 | 168 |
| 6 | 50% (± 7) | 65 | 240 | 145 | 6 | 201 |

**In the real engine** (Studio, built place, Watch mode, 16 rounds): builders won 9, the hunter
won 7. Details and caveats below.

## Limits of this evidence

- **v0.3.0 additions are not measured.** Builder classes and hunt power-ups were added after the
  last calibration, and the bots don't use them, so every number on this page is without them.
  They are deliberately small (DECISIONS D45). Measure them with players, or add them to
  `sim/RoundSim.luau`, before retuning.
- The bots are not people. The simulation's skill and attention ranges are assumptions (listed
  above); real win rates will move with player skill and coordination. Treat the numbers as "the
  rules no longer decide the game", not as a prediction of live stats.
- **In-engine check (TESTING.md #21):** 16 bot-vs-bot rounds in Studio on the final config, in the
  built place, cycling 1→6 builders. Builders won 9 of 16 (56%; the 95% interval at n = 16 is
  roughly ±24 points). Every round went the distance: the hunter's wins came at 68–74 s of the
  75 s hunt. That is the "rules no longer decide the game" result the simulation predicts.
  Per team size the sample is 2–4 rounds, too few to confirm the per-size table. The split (small
  teams 8/10 builder wins, 4–6 builders 1/6) hints that the engine hunter does relatively better
  against large forts than the simulated one. To check, run `lune run balance` side by side with
  a longer Watch session (`practiceBots` 4–6, then `roundLog`) before retuning anything.
- Re-run `lune run balance calibrate` after any tuning change; the damage table is fitted, not
  hand-picked.

# Breachpoint: feature list

A plain list of what the game and its codebase actually contain, for describing the project
accurately. Nothing here has been published to Roblox: there are **no player numbers, visits or
revenue**, and none should be claimed. "Verified in Studio" means it was played and checked in Roblox
Studio by the developer (playtest log: [TESTING.md](TESTING.md)).

## Game

- **Genre:** asymmetric round-based multiplayer. Builders fortify a base in 50 s, then one hunter
  has 75 s to break in and tag everyone. Builders win if at least one survives.
- **Round flow:** server-controlled state machine (Waiting → Intermission → Build → Hunt → Results)
  with fair hunter selection, minimum player counts, leavers and late joiners.
- **Building:** 12×6×12 grid, per-builder budget, block tiers (Wood, Stone free; Metal, Titanium
  unlockable), doors, spike traps, a coin generator, support rules, a ghost preview on the client.
- **Hunter abilities:** Breach, Tag (line of sight), Shockwave, Sprint, all with server cooldowns.
  Builders can repair blocks, but not while the hunter is attacking that block.
- **Builder classes (3):** Engineer (repairs 20% faster), Scout (20% faster movement), Trapper
  (spike traps without buying them, +2 trap limit). Picked in the lobby, validated by the server,
  shown on the HUD.
- **Power-ups (4):** spawn during the hunt. Shield (blocks one tag), Speed (6 s boost) and Decoy
  (a frozen copy of the builder) for builders; Reveal (highlights all builders for 5 s) for the
  hunter. Spawning, pickup detection and effects all run on the server.
- **Practice mode:** alone in Studio, bots fill the other role; Watch mode lets bots play both
  sides. Bots use the same decision modules as the balance simulation.

## Progression and economy

- **XP and levels:** coins from round results also count as XP; the level curve gets steeper per
  level (max 50). Level-up banner and an event-feed line.
- **Daily quests:** 3 per day from a pool of 7 (place / break / repair blocks, play rounds, tag
  builders, win as builder or hunter), rotating by UTC day, each paying coins once.
- **Coins:** round rewards (participation, wins, survival, blocks still standing, tags), per-action
  rewards (repairs, breaks), a generator block, a 7-day login streak, lobby income.
- **Shop:** permanent unlocks paid in coins (block tiers, door, trap, two builder perks, two hunter
  upgrades).
- **Cosmetic crates:** coins only (no Robux anywhere in the game), odds shown before opening, four
  rarities, pity counters (epic within 10, legendary within 60), duplicates converted to coins,
  rolled on the server, animated reveal.

## Lobby and presentation

- **Leaderboard:** top 10 by wins, stored in an OrderedDataStore. In an unpublished Studio place
  it falls back to the current server's players and says so on the board.
- **MVP podium:** the last round's top three participants by coins earned, shown as frozen copies
  of their characters on gold, silver and bronze pedestals.
- **Kiosks:** Shop and Crates stations with proximity prompts that open the shop UI.
- **UI:** title screen with a camera flyover, phase/timer bar, role and class badge, level and XP
  bar, daily quest card, hotbar, ability cooldowns, wallet with animated coin changes, shop and
  crate screens, results screen with MVPs and round stats, event feed, toasts. All built in code.
- **Map and lighting:** generated from code (terrain canyon, fort zone, hunter cage, lobby
  balcony, props), golden-hour Future lighting with atmosphere, bloom, colour correction, sun rays.

## Engineering

- **Language and tools:** strict, typed Luau; Rojo; Rokit-pinned toolchain; Selene; StyLua;
  luau-lsp strict type check; Lune for tests and scripts.
- **Server authority:** clients only send intents; every remote is declared in one protocol file
  with typed argument checks and per-player rate limits; invalid traffic drains an abuse budget and
  leads to a kick.
- **RemoteGuard:** the validation/rate-limit layer extracted into a reusable MIT package with its
  own README and tests.
- **Player data:** session-locked DataStore saves (`UpdateAsync` locks, stale-lock takeover,
  autosave, `BindToClose` flush, retries with backoff and jitter), schema migrations v1 → v5,
  refusal of data from a newer schema, in-memory fallback in Studio.
- **Balance tooling:** a headless round simulation on the real game modules (`lune run balance`)
  and a calibration mode that fits hunter damage per team size. Simulated builder win rate went
  from 0% (v1) to 46–56% at 1–6 builders. Classes and power-ups were added after the last
  calibration and are not part of the simulation.
- **Tests:** 150 Lune unit tests across 11 spec files (state machine, roles, rate limiting,
  argument checks, session locking against a mock DataStore, migrations, grid rules, cooldowns,
  bot logic, shop, daily streak, rewards and MVP ranking, crates odds and pity, XP and quests).
- **Quality gate:** `lune run check` runs formatting, lint, strict type check, tests, the Rojo
  build and a smoke test that the built place contains every script unchanged.
- **Live testing:** every feature was played in Roblox Studio through the Studio MCP bridge with
  real mouse/keyboard input and screen captures; bugs found that way are listed in TESTING.md.

## Not done / limits

- Not published; no live metrics, no real multi-server DataStore or leaderboard test.
- Multiplayer was tested with bots and Play Solo only; a multi-client session was not run.
- Gameplay GIFs/video are not recorded yet (stills only).
- Balance numbers come from bots, not players.

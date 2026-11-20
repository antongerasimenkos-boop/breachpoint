# Status — 2026-11-20 (v0.3.0)

v1 (rounds, guarded networking, session-locked data, RemoteGuard, HUD, map, practice bots), v2
(balance, economy, crates, visuals) and v3 (XP, levels and daily quests, builder classes, hunt
power-ups, lobby leaderboard, MVP podium and kiosks, title and results screens, event feed) are
implemented. A plain feature list for the CV is in [FEATURES.md](FEATURES.md). Every quality gate passes. Nothing is
committed, pushed or published (see "Owner steps").

Balance in one line: builders won **0%** of simulated rounds at 1–4 builders in v1. With the final
tuning they win **46–56%** at every team size from 1 to 6, and no upgrade combination moves that
below 34% or above 74%. In the real engine (16 bot-vs-bot rounds in the built place) builders won
9 and the hunter 7, every round going to the last seconds. Details in [BALANCE.md](BALANCE.md).

## Verified

| What | How | Result |
|---|---|---|
| Formatting | `stylua --check src packages tests sim .lune` | clean |
| Lint | `selene src packages tests sim .lune` (roblox std) | 0 errors, 0 warnings |
| Strict types | `lune run typecheck` (luau-lsp 1.70.1 + Roblox definitions + Rojo sourcemap) | 0 type errors in `src/` and `packages/*/src` |
| Unit tests | `lune run test` | 150 passed, 0 failed (11 spec files) |
| Build | `rojo build -o build/Breachpoint.rbxl` | builds |
| Built place contents | `lune run verify-build` opens the `.rbxl` with Lune | all 49 scripts present, correct classes, sources identical to the repo |
| All of the above at once | `lune run check` | all 6 steps ok (2026-11-20, v0.3.0; rebuilt `build/Breachpoint.rbxl`, 56 scripts) |
| Balance | `lune run balance 200 markdown`: 200 seeded headless rounds per row, 1–6 builders, baseline + 4 upgrade scenarios, on the real game modules and bot brains | Baseline 56 / 46 / 56 / 48 / 46 / 50% builder wins; upgrade scenarios 34–74% |
| v1 live gameplay in Studio | 15 logged playtests (TESTING.md #1–15) | Pass; 3 game bugs found and fixed |
| v2 live in Studio | TESTING.md #16–19: economy through the real remotes (daily, shop, crates, pity, equip, rate limit), the new bot hunter brain in the real engine, shop/crate UI with real clicks and screen captures, the canyon map | Pass; 2 UI issues found and fixed |
| **The built `.rbxl` itself in Studio** | TESTING.md #20: the owner opened `build/Breachpoint.rbxl`; all 49 scripts hashed and compared with the repo; Play | 49/49 identical; no errors or warnings from our code. **Bug found and fixed:** shadows were off in the built place (D42) |
| **Bot-vs-bot on the final config, in the engine** | TESTING.md #21: Watch mode, 16 full rounds cycling 1→6 bot builders, event-based round logger | Builders 9 / hunter 7 (56%); every round went to 68–75 s. Per-size samples are too small to confirm the per-size table (see BALANCE.md) |
| **One real-input round per role on the final config** | TESTING.md #23: Builder (key 2 + clicks), Hunter (W, held left button, Q), shop and crate with real clicks; new captures in `docs/media` | Pass: blocks placed, 8 breaches accepted / 0 rate-limited, crate charged 250 and revealed the server prize; server log clean |
| Asset failures degrade gracefully | TESTING.md #22: with every asset returning HTTP 403 (owner's account was under a moderation block, since cleared) | No errors from our scripts, no stalls; all game assets are built-in `rbxasset://` content |
| **v0.3.0 features live in Studio** | TESTING.md #24–28: progression, classes, power-ups, lobby, title/results/feed, synced into the open place and played with real clicks and keys where the feature has input | Pass; 1 bug found and fixed (squashed lobby signs). Server and client logs clean |

## Not verified (and why)

| What | Why | Covered instead by |
|---|---|---|
| **Classes and power-ups in the balance numbers** | Added after the last calibration; bots don't use them | Kept small (D45). Measure with players or extend `sim/RoundSim.luau` before tuning |
| Leaderboard on a real OrderedDataStore | Needs a published place | In-memory fallback verified (#27); the OrderedDataStore calls are wrapped in `pcall` |
| Engineer repair speed, kiosk prompts with real input | Time box | Loadout multiplier in code; prompts placed and captured (#27) |
| **The rebuilt `.rbxl` with the shadows fix, opened in Studio** | The fix landed after the owner opened the file; Studio can't reload a file through MCP | Applied at runtime in the open build for #23 (same line the fix adds). The rebuilt file read with Lune: `GlobalShadows = true`, `Technology = Future`, `verify-build` 49 scripts identical |
| Per-team-size balance in the engine | 16 rounds = 2–4 per team size | Simulation table (BALANCE.md). The engine split (small teams 8/10, 4–6 builders 1/6) is worth a longer Watch session before any retune |
| Lighting.Technology at runtime | Can't be read through MCP (needs RobloxScript capability) | Future in the file (Lune) and per-pixel torch lighting visible in `docs/media/v2-arena.jpg` |
| Real multiplayer (2+ clients) | The Studio MCP bridge drives Play Solo only | RoundMachine specs; manual checklist in TESTING.md |
| Real DataStores and cross-server locking | The scratch place is unpublished | SessionStore specs (two simulated servers, one store) |
| Touch / mobile input, sound playback, 8+ players | Not testable through the bridge / no load test | UIScale and tap paths exist; assets verified to load |

## Owner steps

1. **Play it.** Close the open `Breachpoint.rbxl` without saving and reopen `build/Breachpoint.rbxl`
   (it was rebuilt with the shadows fix after you opened it). Try practice mode: one round as Builder, one as
   Hunter, and one in Watch mode with a few bot builders. Then go through the manual checklist in
   [TESTING.md](TESTING.md), including the *Clients and Servers* multiplayer section. To measure
   bot-vs-bot balance in Studio: Watch, `game.ServerStorage.BreachpointDebug:Invoke("practiceBots", 4)`,
   play a few rounds, then `Invoke("roundLog")`.
2. **Record media.** Shot list in [media/README.md](media/README.md). The stills in `docs/media`
   are now from the built place; gameplay GIFs are still to be recorded.
3. **Publish.** File → Publish to Roblox, then *Enable Studio Access to API Services* to test real
   DataStores. Practice bots are off on live servers (`Config.Solo.EnabledLive`).
4. **Optional:** change the copyright name in `packages/remote-guard/LICENSE`. Revisit the
   builder-upgrade edge (58–74% against a base hunter) once real players exist; see BALANCE.md.

The scratch Studio place *Place1* was never saved; close it without saving if it is still open.

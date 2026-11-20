# Testing

## Automated

```bash
lune run test          # all unit tests (Lune)
lune run test Round    # only spec files whose path contains "Round"
lune run check         # stylua --check, selene, typecheck, tests, rojo build, verify-build
lune run balance       # headless balance report (docs/BALANCE.md)
```

Specs live in `tests/` (game logic) and `packages/remote-guard/tests/` (the package). Only pure
modules are unit-tested. Anything that touches Roblox services is covered by the live Studio
playtests below.

## Live Studio playtest log

Every feature was synced into an open scratch place with `lune run studio-sync` and played through
the Studio MCP bridge (`start_stop_play`, `get_console_output`, `execute_luau` on the Server/Client
DataModels, `character_navigation`, `screen_capture`). "Console clean" means no errors or warnings
from our scripts.

| # | Date | Phase | What was checked | Result |
|---|------|-------|------------------|--------|
| 1 | 2026-11-19 | 1 skeleton | Synced 3 scripts via studio-sync; play → server + client entry points print boot lines | Pass, console clean |
| 2 | 2026-11-19 | 2 networking | From the Client DataModel: 40× valid `PlaceBlock` in one frame, `Breach("not a number")`, `Breach(NaN)`, `Tag(1, {smuggled})`, `UseAbility("Nuke")`. Server stats via `BreachpointDebug:Invoke("netStats")` | Pass: PlaceBlock 8 accepted / 32 RateLimited (capacity 8); Breach 2 BadArg; Tag 1 TooManyArgs; UseAbility 1 BadArg. Console clean |
| 3 | 2026-11-19 | 2 abuse budget | Same session, 20× malformed `Breach` | Pass: player kicked ("Too many invalid requests"), one intended `[Net] kicking …` warning |
| 4 | 2026-11-19 | 3 data | Play: in-memory fallback notice printed; `data` debug shows a template profile; `grant` coins +25 / hunterWins +1 → leaderstats Coins 25, Wins 1; `save` → raw record v3 with lock {jobId, placeId, at} and the new values | Pass, console clean apart from the intended notice |
| 5 | 2026-11-19 | 3 data | `rejoin` debug (release → load, the same-server rejoin path): lock present before, cleared after release, reload restores 40 coins and rebuilds leaderstats; stop play → BindToClose finishes with no warnings | Pass. Note: `Player:Kick()` ends a Studio Play Solo session, so PlayerRemoving is exercised through this debug path and the Lune specs, not a real leave |
| 6 | 2026-11-19 | 4 rounds | Solo practice in Play Solo: Waiting → Intermission (6 s) → Build. Player gets Role=Builder, Alive=true, teleported to a fort spawn, collision group `Builders`; RoundState attributes replicate (Phase, EndsAt, HunterId=-1 bot, Solo). `skip` through Hunt → Results → Intermission | Pass: rewards 65 coins (10 + 40 + 15), builderWins 1, roundsPlayed 1; back in the lobby as Spectator with the Default group |
| 7 | 2026-11-19 | 5 building | Through the real `PlaceBlock` remote: block on own cell, occupied cell, unsupported y=2, out-of-reach cell, valid Stone + stacked Metal | Pass: "Someone is standing there", "Occupied", "Blocks need support…", "Too far away"; 2 blocks placed, budget 40 → 34 |
| 8 | 2026-11-19 | 5 bots | Round 1: bot hunter walks from the hunt start (0, 3, 45) to the player at (8, 3, 8) and tags them in < 6 s. Round 2 (player = hunter): three bot builders build 48 blocks (16 each) | Pass: round 1 ends Hunter (AllBuildersCaught) |
| 9 | 2026-11-19 | 5 hunter | Player hunter next to a walled bot: Tag(-1) → "Something is in the way"; Tag(-2) → "Too far away"; 6× Breach on a Stone wall (HP 5,4,3,2,1,gone); Tag(-1) → ok; Shockwave → 9 blocks damaged, second Shockwave "Cooling down"; Sprint → WalkSpeed 28.8; screen capture of the arena | Pass after two fixes: (a) line of sight was a single eye-level ray that grazed the block above a gap → now body-to-body *or* head-to-head; (b) Sprint never ended because WalkSpeed is float32 and was compared with `==` → tolerance compare |
| 10 | 2026-11-19 | 5 builder | Round 1 as builder: place 2 Wood (budget 38), RemoveBlock own block → refund to 39; RemoveBlock(999999) → "That block is gone"; RepairBlock in Build → rejected; Hunt: debug-damage block to 1 HP, RepairBlock → 2, immediate repeat → "Repair is cooling down"; then the bot hunter tagged the player and later requests got the correct phase rejections | Pass, console clean |
| 11 | 2026-11-19 | 6 HUD | Screen captures: intermission (top bar "Next round in", countdown, practice role picker), build (BUILDER badge, "Builders alive 1/1 (practice)", hotbar with costs/HP, budget, controls hint), results ("HUNTER WINS", reason, "+10 coins", BUILDER (OUT) badge, toasts) | Pass. Toasts fade on schedule (0 left after 4 s); results panel hides on the next round |
| 12 | 2026-11-19 | 6 build input | Real mouse input (`user_mouse_input`): two clicks on the sand place two Wood blocks through BuildController → Net → server; green grid-snapped ghost preview visible next to them | Pass: budget 40 → 38 |
| 13 | 2026-11-19 | 6 hunter input | Real keyboard input: Q → Shockwave, E → Sprint; ability bar shows cooldown overlays (8.9 s / 8.3 s). Sprint ends after 3 s (WalkSpeed back to 18, confirming the float32 fix). Holding the left mouse button on a Stone block for 2.2 s | Pass: 6 Breach accepted, 0 rate-limited (client pacing respects server limits), block destroyed. Note for manual testers: MCP mouse coordinates are viewport pixels (screenshots are 1.25× scaled) offset by the 58 px top-bar inset |
| 14 | 2026-11-19 | 7 review fixes | After the self-review fixes (server-to-client remotes guarded, per-player connection cleanup, bounded PrimaryPart wait, type fixes): full solo round Build → Hunt → Results → Intermission via `skip`; rewards still 65 coins | Pass, console clean |
| 15 | 2026-11-19 | 7 exploit | From the client: `Notify:FireServer(...)` / `Effect:FireServer(...)` (server-to-client events) | Pass: logged `[Net] rejected BadArg … Notify is a server-to-client event` and charged to the abuse budget instead of queueing silently |
| 16 | 2026-11-19 | v2 economy | Through the real remotes: ClaimDaily twice (second refused), BuyItem Metal at 100 coins (refused), debug grant 5000, BuyItem Metal / again / unknown id, OpenCrate twice in one frame, three more opens, Equip into the wrong slot, Equip owned skin, Equip unowned trail | Pass: +100 daily, streak 1; coins add up exactly (5100 − 300 − 3×250 + 600 = 4650); pity counters 1/1 → 0/2 → 1/3; "Wait for the current crate" on the double open; the 4th rapid open dropped by the rate limiter; equip validation correct |
| 17 | 2026-11-19 | v2 bots | New HunterBrain bot in the real engine: solo builder idle at spawn | Pass: bot pathed in and tagged the player; round ended Hunter (AllBuildersCaught) |
| 18 | 2026-11-19 | v2 UI | Real clicks: Daily button, Shop button, Buy Metal, Crates tab, Open crate. Screen captures of the HUD, shop, crate odds and the reveal reel (saved in docs/media/v2-*.jpg) | Pass: wallet 3125 → 2825 with an "Unlocked" toast; hotbar shows Metal after the purchase; the reel stops on the server-rolled prize ("COMMON: 60 coins"). Fixed afterwards: the wallet updated before the reel stopped (now frozen during the reveal) and toasts drew behind the shop window (ZIndex) |
| 19 | 2026-11-19 | v2 map | Synced the canyon-outpost map: terrain, props, cage, lobby sign, golden-hour lighting; capture from above the fort | Pass, console clean. Future lighting can't be set through MCP (needs RobloxScript capability), so the scratch place renders with its default technology; the built place sets Future in default.project.json |
| 20 | 2026-11-20 | built place | The owner opened `build/Breachpoint.rbxl` itself in Studio. Every script in it hashed (FNV-1a, CRLF-normalised) and compared with the repo files; Play started; `Lighting.Technology` read from the file with Lune | Pass: 49/49 scripts identical to the repo, Technology = Future in the file. Console: data notice, `server ready`, `client ready`, no errors or warnings from our scripts. **Bug found:** `Lighting.GlobalShadows` was `false` in the built place (a Rojo-built place starts from engine class defaults), so the game had no shadows. Fixed in `default.project.json` and `MapService` (DECISIONS D42) |
| 21 | 2026-11-20 | v2 balance | Watch mode, bot-vs-bot on the final config in the real engine: 16 rounds cycling 1→6 bot builders against the bot hunter, recorded by the event-based round logger (`roundLog`). A driver skipped only idle time (Results, Intermission, and Build once no block had been placed for 4 s); every Hunt ran in full | Pass, console clean. Builders won 9 of 16 (56%). By team size, builder wins: 1 → 3/3, 2 → 1/3, 3 → 4/4, 4 → 0/2, 5 → 1/2, 6 → 0/2. Every round went the distance: hunter wins came at 68–74 s of the 75 s hunt, and the hunter broke 4–6 blocks per round (simulation: 1–7). Simulation baseline for comparison: 56 / 46 / 56 / 48 / 46 / 50% |
| 22 | 2026-11-20 | assets | While the owner's Roblox account was under a moderation block, Studio got HTTP 403 for every asset, including Roblox's default character animations and even built-in `rbxasset://sounds/*`, and "User is moderated" for one sound. Also called `HudController.playSound` directly with the failing id | Pass: no errors from our scripts and no stalled gameplay through the 16 rounds above; `playSound` with a failing id returns in 0.1 ms without an error. The game itself uses only built-in `rbxasset://` content and never waits on an asset load. After the owner cleared the block, a fresh Play logged 0 × 403 |
| 23 | 2026-11-20 | v2 real input | Built place, final config, with `GlobalShadows` set at runtime exactly as the D42 fix does (the open file predates the fix). **Builder:** key 2 (Stone), four real clicks on the sand. **Hunter:** W to walk to the bot fort, left button held 3 s on a Stone block, Q. **UI:** real clicks on Crates, Open crate, Nice!, Blocks tab, X. Captures replaced in `docs/media/v2-*.jpg` | Pass: 3 Stone blocks placed (budget 64 → 58; the 4th click hit an occupied cell), round reward +31 coins. 8 `Breach` accepted, 0 rate-limited; block 40 → 28.9 HP; Shockwave cooldown overlay shown. Crate: wallet 2606 → 2356, the reel stopped on the server prize ("RARE: Wallbreaker"). Torch light pools on the terrain in the overhead capture (per-pixel lights, as expected with Future). Server log: 512 lines, no warnings or errors, 0 × 403 |

#### v0.3.0 features (scripts synced into the open built place with `lune run studio-sync`)

| # | Date | Feature | What was checked | Result |
|---|------|---------|------------------|--------|
| 24 | 2026-11-20 | progression | Profile on join (level 1, 0/150 XP, today's quests: repair15, tag3, survive2); debug `grant tags +3`; one round won as builder; level-up banner captured | Pass: the tag quest completed and paid +200 coins once; the round win paid 175 coins → 175 XP → level 2 (25/200), `Level` attribute 2, survive2 at 1/2; banner and toast shown. Captures `v3-lobby-quests.jpg`, `v3-level-up.jpg` |
| 25 | 2026-11-20 | classes | Role badge in the build phase; `ChooseClass("Trapper")` mid-round and `ChooseClass("Ninja")`; next round placed 6 traps without owning the Trap unlock; `ChooseClass("Scout")` and walk speed across phases | Pass: badge "BUILDER · ENGINEER"; invalid class rejected by the remote guard; the Trapper placed 5 traps, the 6th refused ("You can place 5 Spike trap per round"); Scout speed 19.2 in Build, back to 16 between rounds |
| 26 | 2026-11-20 | power-ups | Debug-spawned Shield, Speed, Decoy and walked the builder onto them; set Shield and let the bot hunter reach the builder; as hunter, picked up Reveal | Pass: all picked up by the server distance check; speed 21.6 (16 × 1.35); decoy model spawned; "Your shield blocked a tag!" then caught on the next tag; Reveal put a highlight on all 3 bot builders |
| 27 | 2026-11-20 | lobby | Leaderboard after debug `grant builderWins +4` and a round; MVP podium after a bot round; kiosk prompts; capture from above | Pass: board "1. ANTONIRUS20 — 5 wins", footer "This server (DataStores unavailable)"; podium shows the 3 MVPs with names and coins; **bug found and fixed:** kiosk and podium signs were squashed (SurfaceGui default fixed canvas), now `PixelsPerStud`. Capture `v3-lobby.jpg` |
| 28 | 2026-11-20 | presentation | Title screen on join (real click on PLAY); as hunter: held the mouse on a wall and pressed Q; results after the round | Pass: title over the camera flyover, HUD hidden until PLAY, camera back to Custom after; feed line "The hunter broke through a wood block"; results screen with 3 MVP rows and "3 builders · 119 blocks still standing · 0 tags". Server and client logs: 0 warnings or errors. Captures `v3-title.jpg`, `v3-hunt-feed.jpg`, `v3-results.jpg`, `v3-build.jpg` |

Not covered for 0.3.0: Engineer's faster repair was checked in code only (the loadout multiplier),
not timed live; the OrderedDataStore path (needs a published place); the kiosk prompts were placed
and captured but not triggered with real input; classes and power-ups with 2+ real players.

### Bugs found by these playtests

| Playtest | Bug | Fix |
|---|---|---|
| #9 | Tag refused through a freshly opened gap: the single eye-level line-of-sight ray grazed the block above | Two rays (body and head height); either clear passes |
| #9 | Sprint never ended: `Humanoid.WalkSpeed` is float32, so `28.799999 == 28.8` was false | Tolerance compare |
| review → #15 | Server-to-client remotes had no server listener, so client spam would queue silently | Listen and charge the abuse budget |
| #18 | The wallet counted up before the crate reel stopped (spoiling the prize) | Wallet frozen during the reveal |
| #18 | Toasts drew behind the shop window | Toasts ZIndex 20 |
| #20 | No shadows in the built place: Rojo writes `Lighting.GlobalShadows = false` (engine class default) | Set explicitly in `default.project.json` and `MapService` (D42) |
| #27 | Lobby kiosk/podium signs squashed: `SurfaceGui` defaults to a fixed 800×600 canvas, `PixelsPerStud` was ignored | `SizingMode = PixelsPerStud` (also on the title sign, which now has a lobby-facing side) |
| balance sim | Hunter skill rolled per 0.1 s tick instead of per swing: damage almost skill-independent, outcomes knife-edge (also in the in-game bot hunter) | One roll per swing in both (BALANCE.md iteration 6) |
| #12 (harness) | First hunter click test missed: MCP mouse coordinates are viewport pixels with a top-bar inset, unlike the scaled screenshots | Test harness only; aimed by projecting the block with `WorldToViewportPoint` |

### Not covered live

- **The rebuilt place with the D42 shadows fix** has not been reopened in Studio. The fix was
  checked at runtime in the old build (#23), and the rebuilt file was read with Lune
  (`GlobalShadows = true`, `Technology = Future`, `verify-build` 49 scripts identical).
- **Lighting.Technology at runtime:** it can't be read through MCP. Future is confirmed in the
  file, and the captures show per-pixel torch lighting, but the engine's value was not read back.
- **Studio rendering needs the window on screen.** While the Studio window wasn't on screen, MCP
  captures showed only the UI on a white background, in Edit and in Play, even for a test part
  placed in front of the camera. After the owner restored the window, every capture rendered. This
  is an environment limit, not a game bug.
- Real multi-client sessions: Studio MCP drives Play Solo only. Multiplayer rules (min players,
  fairness, leavers, late joiners) are covered by the RoundMachine specs; see the manual checklist.
- Real DataStores and cross-server session locking: the scratch place is unpublished. These are
  covered by the SessionStore specs (two simulated servers, one store).

## Manual playtest checklist

For a human tester before publishing. Each item is a few seconds in Studio.

**Solo (Play, one player)**
- [ ] Output shows the in-memory DataStore notice and `[Breachpoint] server ready`, with no errors or warnings.
- [ ] The HUD shows "Next round in", a countdown and the Practice panel. Clicking Hunter outlines the button.
- [ ] Build phase: "You are a BUILDER" reveal, hotbar, budget 40. The ghost is green on sand and red outside the fort or in mid-air.
- [ ] Clicking places blocks; 1/2/3 switch type; X on your own block refunds it.
- [ ] As a builder you cannot walk out through the blue fort barrier.
- [ ] Hunt phase: the bot hunter leaves the cage, breaks walls and tags you; results show "HUNTER WINS".
- [ ] Next round as hunter: the cage holds you during Build. In the Hunt, click walls to breach them, click a bot to tag it, Q for Shockwave (red ring), E for Sprint.
- [ ] A tag through a wall is refused ("Something is in the way").
- [ ] Leaderstats Coins / Wins update after each round.

**Multiplayer (Test → Clients and Servers, 2–3 players)**
- [ ] With 1 of 2 players the server waits; with 2 the intermission starts with normal timings.
- [ ] Exactly one hunter, and the role rotates between rounds.
- [ ] A player joining mid-round spectates from the lobby until the next round.
- [ ] Closing the hunter's client mid-hunt ends the round as "ROUND VOID".
- [ ] Closing one builder's client: the others keep playing, and the round ends correctly when the rest are caught.

**Published place (live DataStores)**
- [ ] Enable Studio API access for DataStores, play, earn coins, stop, play again: coins persist.
- [ ] Two servers: leave server A and join server B quickly. B waits for A's release (watch the output) instead of loading stale data.

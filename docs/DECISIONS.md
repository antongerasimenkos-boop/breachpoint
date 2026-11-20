# Decisions log

Decisions made while building Breachpoint without the owner available, with the reasoning, so
they can be revisited. Newest at the bottom of each section.

## Tooling

- **D1 — Rokit-pinned toolchain.** `rokit.toml` pins rojo 7.7.1, selene 0.32.0, stylua 2.6.0,
  lune 0.11.1. Wally is not used: the project has no third-party runtime dependencies, which keeps
  the code a reviewer reads 100% our own.
- **D2 — One check command, written in Lune.** `lune run check` (`.lune/check.luau`) runs StyLua
  (check mode), Selene, the Lune tests and `rojo build`. A Lune script works the same on
  Windows/macOS/Linux, unlike a shell or PowerShell script.
- **D3 — Tests receive the kit as a parameter.** Spec files return `function(kit)`, so they never
  hard-code a path to the harness. That keeps the RemoteGuard package's tests portable.
- **D4 — String requires (`require("./X")`, `@self`) for pure modules.** Roblox and Lune
  resolve these the same way (verified in Studio on 2026-11-19). Pure logic modules can therefore
  run unchanged under Lune tests. Roblox-bound modules use instance paths
  (`ReplicatedStorage.Shared...`) because they cross Rojo roots.
- **D5 — `studio-sync`, a small one-way sync tool for live testing.** The Studio MCP bridge can
  run Luau in the open place, and Studio can make HTTP requests to `localhost`. So
  `lune run studio-sync` serves the Rojo tree, and a single `loadstring(HttpService:GetAsync(...))()`
  rebuilds the managed roots in Studio. Studio then always matches the repo without hand-copying
  scripts. `rojo build` remains the source of the deliverable place.
- **D20 — luau-lsp added to the toolchain.** The original toolchain was rojo/selene/stylua/lune. "Typed Luau"
  means little without a type checker, and Studio's checker can't be driven from the command line.
  So luau-lsp is pinned too, and `lune run typecheck` runs it with the official Roblox definitions
  from the luau-lsp repository at the pinned tag, cached in `build/`. luau-lsp can't open paths
  with non-ASCII characters (this repo lives in a Cyrillic-named folder), so the script then checks
  a copy in the temp folder. Spec files are excluded: they run under Lune, not Roblox.

## Game design

- **D7 — Name.** Kept the working title *Breachpoint*. It is original and describes the loop.
- **D8 — Builders are confined to the fort.** Without this, the optimal builder strategy is to run
  away, and building becomes pointless. Fort walls sit in a `FortBarrier` collision group that only
  collides with the `Builders` group, so the hunter walks through.
- **D9 — Hunter leaving voids the round** (winner `None`, participation coins only). Otherwise two
  friends could farm wins by having the hunter leave. All builders leaving untagged is voided
  for the same reason. If someone was caught first, the hunter wins.
- **D10 — A builder's death counts as caught; the hunter respawns.** Resetting must not be a way to
  dodge a tag, and the hunter dying (e.g. falling) must not end the round.
- **D11 — Late joiners spectate** until the next round instead of joining mid-round.
- **D12 — Practice mode is on in Studio and off on live servers** (`Config.Solo`). The design requires
  that a lone player in Studio can try the game. Live servers wait for 2 players. Bots call the same
  validated `try*` functions as players.
- **D13 — Blocks never fall.** Breaking a block does not collapse the blocks above it. Structural
  physics adds a lot of complexity and replication cost for little gameplay value here. Placement
  still requires support.
- **D14 — Block ids are never reused** across rounds, so a late click from the previous round can
  never hit a new block.
- **D15 — Rewards** (`Config.Rewards`): 10 coins for taking part, +40 and +15 survivor bonus for
  surviving builders, +60 for a hunter win, +10 per tag, +1 per block broken. Wins are tracked
  separately per role.
- **D16 — Line of sight for tags is two rays** (body and head height). A single ray grazed the block
  above a gap the hunter had just opened (found in playtest #9).

## Architecture

- **D17 — Round state replicates through attributes, not events.** `ReplicatedStorage.RoundState` and
  per-player attributes give late joiners the correct state for free. Remote events are used only
  for one-off facts (notifications, results, VFX).
- **D18 — Rejected requests still cost rate-limit tokens, and every rejection feeds an abuse budget.**
  Rate-limit hits cost 1 and malformed payloads cost 5 against a 60-point bucket that refills
  1 per second. An honest client never sends a malformed payload, so draining the budget means a
  modified client.
- **D19 — Studio-only debug hooks through a BindableFunction** (`ServerStorage.BreachpointDebug`).
  Command-bar and MCP code run in a different VM from game scripts and get their own module cache,
  so a BindableFunction is the reliable way to reach the running services. It is never created on
  live servers.
- **D21 — No third-party frameworks** (Knit, ProfileService, Promise, t). The resume promises these
  systems, so they are implemented here, small and readable, rather than imported.
- **D22 — The client preview reuses the server's BlockGrid rules** (via `insert`, which tolerates any
  replication order), so client and server can't disagree about what a valid placement is.

## Data

- **D23 — Session lock expiry is 300 s**, which is five autosave intervals (each autosave refreshes
  the lock). A lock that recent is treated as live: the load backs off (1, 2, 4… s with jitter) for
  6 attempts, then kicks with "still in use, rejoin in a minute". Older locks are taken over and
  the takeover is logged.
- **D24 — Live servers never fall back to memory.** Silently losing progress is worse than kicking.
  The in-memory store is used only in Studio, and the output says so. The notice uses `print`, not
  `warn`, because it is the expected state of an unpublished place.
- **D25 — Migration v1 → v2 assumes v1 `wins` were builder wins.** The v1 schema is hypothetical; the
  migration exists to show the mechanism, and its assumption is written down in the code.
- **D26 — Data from a newer schema is refused, not downgraded.** The player is kicked with "this
  server is out of date" and the record is left untouched.

## Out of scope / known limitations

- **D27 — No movement anti-cheat.** Range checks use server-side positions plus a small leeway
  (`Config.RangeLeeway`), which limits what a speed or teleport exploit gains, but character movement
  itself is client-authoritative, as it is by default on Roblox.
- **D28 — Assets.** Sounds use built-in `rbxasset://sounds/...` files (verified to load in Studio),
  so no uploads or asset ids are needed. Everything visual is built from Parts.
- **D29 — Rewards for a player whose data is still loading are dropped.** `DataService.increment`
  returns false until the profile loads, which takes a fraction of a second outside outages. A
  pending-rewards queue was judged not worth the complexity for a portfolio build.

## v2: balance, economy, visuals (2026-11-20)

- **D30: Balance is measured with a simulation on the real code, not tuned by feel.**
  `sim/RoundSim.luau` drives BlockGrid, Cooldowns and the same bot brains the Studio bots use.
  The modelling assumptions (skill ranges, builders standing still, straight-line movement) are
  listed in docs/BALANCE.md. A model is never the game, so the numbers are confirmed with
  bot-vs-bot rounds in Studio.
- **D31: Builders follow a team fort plan.** Pooled budgets into concentric two-high rings,
  with the tier per ring chosen to maximise the weakest column. This is "sensible play" for the
  balance target, and what the practice bots build.
- **D32: Hunter damage scales by team size through a fitted table**
  (`Config.Hunter.DamageByBuilders`) rather than a formula. Wall strength grows in steps as pooled
  budgets buy whole rings, so no simple formula fits. `lune run balance calibrate` refits it
  after any tuning change.
- **D33: Repairs must never out-heal a working hunter.** With repairs close to hunter damage,
  the time to breach (`HP / (damage - repair)`) divides by almost zero, and a 6% perk flipped
  rounds from 50% to 0% or 100% (iteration 2 in docs/BALANCE.md). Repairs are 1 HP per second
  with a 1 s per-block cooldown, so walls do the defending.
- **D34: Stone and Wood are the free baseline that balance targets; higher tiers buy density,
  not efficiency.** Metal (32 HP for 4 budget) and Titanium (56 for 7) give *less* HP per budget
  point than Stone (8 vs 10), but more HP per cell. With higher efficiency (iteration 2), a solo
  builder could put 88 HP into the inner ring instead of 56, and upgraded builders won ~100%.
  Existing players keep Metal (it was free in v1); the v3 → v4 migration grants it.
- **D35: Crates are cosmetic only and paid with coins only.** There is no Robux path, which keeps
  the game clear of paid-random-item rules. Odds are shown before opening, and pity and duplicate
  refunds limit bad luck. Rolls use a server-side `Random.new()`. The client animates toward the
  result it is given.
- **D36: Crate state saves with the next autosave, not immediately.** A forced save per open would
  hit the per-key write limit. A server crash can lose at most one autosave interval (60 s) of crate
  results, the same as any other progress.
- **D37: Traps live outside the block grid.** A trap is a floor plate. If it were a grid block, it
  would block the cell above it and the hunter's pathing would treat it as a wall. Traps can't be
  taken back once placed, and the simulation does not model them (they only slow the hunter, so the
  measured numbers slightly favour the hunter).
- **D38: Future lighting is set in default.project.json.** Lighting.Technology can't be read or
  written by game scripts or the MCP bridge (it needs RobloxScript capability). The built place
  uses Future; the scratch place used for captures keeps its default technology.
- **D39: No repairs under fire.** A block breached in the last 2 s can't be repaired; Shockwave
  splash doesn't count. Repairs patch chip damage and abandoned breaches, but they can never cancel
  the hunter's current attack. Even at 1 HP/s, repairs that could fully offset the attack kept
  recreating a knife-edge whenever calibration lowered hunter damage (BALANCE.md, iterations 3–5).
- **D40: Skill is rolled per swing, not per tick.** Rolling the hunter's skill every 0.1 s tick
  made a "50% skill" hunter only a moment slower (±12% damage), so every simulated round ended at
  almost the same time and a 5% change decided games. Now one roll per swing (a miss costs the
  cooldown) in both the simulation and the practice bot.
- **D41: Upgrades are sized against a measured slope.** Around 50%, the builder win rate moves
  about 2 points per 1% of wall HP or hunter damage. Each builder perk and hunter upgrade is
  therefore a few percent (Deep Pockets +2 budget, Heavy Hitter +6%, Bloodhound −1 s), and Metal
  and Titanium trade HP per budget for HP per cell.
- **D42: Lighting properties the look depends on are set explicitly.** A Rojo-built place starts
  from engine class defaults, not from Studio's new-place template, so `Lighting.GlobalShadows` was
  `false` in `build/Breachpoint.rbxl` (found when the built file was first opened in Studio). It is
  now set in `default.project.json` (so Edit mode matches) and again in `MapService` at runtime.
- **D43: XP is earned from round-result coins.** One number already sums everything a player did in
  a round (participation, wins, survival, standing blocks, tags), so XP follows it 1:1 instead of a
  second scoring table that could drift. Daily, crate and lobby coins don't give XP.
- **D44: Daily quests rotate by UTC day, not per player.** Everyone has the same three quests, which
  is simpler to reason about and to talk about with friends; quests count the stat increments the
  game already records (`DataService.incremented`), so no gameplay code knows about quests.
- **D45: Classes and power-ups stay small and outside the simulation.** Each is a modest
  specialisation (±20%, one blocked tag, a 5 s reveal). Bots don't use them, so measured bot balance
  is unchanged; their effect on player balance is unmeasured and flagged in BALANCE.md/STATUS.md.
- **D46: Power-up pickups are checked by the server, not by Touched events.** A 0.2 s distance check
  per pickup is cheap (two pickups at most) and can't be spoofed by a client firing touches.
- **D47: The leaderboard falls back visibly.** Unpublished Studio places can't use DataStores, so the
  board shows this server's players and labels itself "This server (DataStores unavailable)" rather
  than pretending to be global.

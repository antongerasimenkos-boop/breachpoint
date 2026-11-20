# Changelog

All notable changes to this project. Format based on [Keep a Changelog](https://keepachangelog.com/).

## [0.3.0] - 2026-11-20

Progression, classes, power-ups, a lobby showpiece and a presentation pass.

### Added
- XP and levels (round-result coins also count as XP), a level-up banner, and three rotating daily
  quests that pay coins. Data schema v5 (`xp`, `quests`) with a tested v4 → v5 migration that
  credits past rounds.
- Builder classes picked in the lobby: Engineer, Scout, Trapper (server-validated `ChooseClass`
  remote, class shown on the role badge).
- Hunt power-ups, fully server-side: Shield, Speed, Decoy (builders) and Reveal pulse (hunter).
- Lobby showpieces: wins leaderboard (OrderedDataStore, in-memory fallback in Studio), last round's
  MVP podium, shop and crate kiosks with proximity prompts.
- Title screen with a camera flyover; results screen with the top three MVPs and round stats; event
  feed for breaches, tags, power-ups and level-ups.

### Fixed
- Lobby signs used the default fixed-size canvas and looked squashed; they now size by pixels per
  stud. The title sign is readable from the lobby side too.

### Not measured
- Classes and power-ups are not in the balance simulation; the 0.2.0 balance numbers predate them.

## [0.2.0] - 2026-11-20

Balance, economy and visuals, after the owner's first playtest ("builders can't win, too little
money, it doesn't look polished").

### Balance
- Headless round simulation on the real game modules (`sim/RoundSim.luau`, `lune run balance`), with
  a calibration mode that fits hunter damage per team size. In v1, builders won 0% of simulated
  rounds at every team size. Final numbers are in [docs/BALANCE.md](docs/BALANCE.md).
- Bot builders and the bot hunter now share pure brains with the simulation (`FortPlanner`,
  `HunterBrain`, `BuilderBrain`), so Studio practice bots play the way the simulation measured.
- Retuned: tag reach (4.5 + 3 leeway, so no more tags through a single broken block from outside),
  block HP (Wood 16 / Stone 40 / Metal 56 / Titanium 84; higher tiers buy density, not
  efficiency), budget 64, Hunt 75 s, repairs 1 HP per second with a per-block cooldown and **no
  repairs on a block breached in the last 2 s**, Shockwave damage 2, and hunter damage scaled by
  team size (`Config.Hunter.DamageByBuilders`, fitted by the simulation).
- Fixed in the simulation and the bot hunter: hunter skill was rolled per 0.1 s tick instead of
  per swing, which made damage almost skill-independent and outcomes knife-edge.
- Practice "Watch" mode (bots on both sides) and a Studio round log for in-engine balance checks.
- Fixed: the built place had shadows off (`Lighting.GlobalShadows` defaults to false in a
  Rojo-built place); now set explicitly.

### Economy
- Much larger rewards: participation, team win, survivor bonus, blocks still standing, repairs,
  breaks, tags and hunter win. Daily login reward with a 7-day streak. Small lobby income.
- Coin generator block (pays its owner while it stands; the hunter earns a bounty for breaking it),
  doors builders walk through, spike traps that slow the hunter.
- Shop with permanent unlocks: Metal and Titanium tiers, Door, Spike trap, two builder perks (Deep
  Pockets +2 budget, Quick Hands −15% repair cooldown) and two hunter upgrades (Heavy Hitter +6%
  damage, Bloodhound −1 s Shockwave), sized so no combination decides games. Purchases are validated on the server and saved.
- Data schema v4 (nested unlocks, cosmetics, equipped, daily, pity) with a tested v3 → v4 migration;
  existing players keep Metal.

### Crates (cosmetic loot, coins only)
- No Robux anywhere. Odds are shown before opening, there are pity counters (Epic+ within 10
  opens, Legendary within 60), and duplicates convert to coins. Rolled on the server with
  `Random.new()`, at most one open per 1.5 s on top of the remote rate limit. Animated reveal reel.
- Cosmetics: block skins, hunter trails, titles above the head. No gameplay effect.

### Visuals
- Canyon-outpost map: terrain arena and canyon rim, paved fort floor, pylons, torches with fire,
  ruins, crates, banners, dead trees, an iron hunter cage with glowing bars and a lobby balcony
  with a sign.
- Golden-hour lighting: Future technology (project file), Atmosphere, Bloom, ColorCorrection,
  SunRays.
- Particles, screen shake, coin popups, trap and repair effects. Restyled UI: gradients, outlines,
  animated buttons, wallet with count-up, shop and crate screens, UIScale for phones.

## [0.1.0] - 2026-11-19

First complete playable version.

### Added
- Rojo project with Rokit-pinned toolchain (rojo, selene, stylua, lune, luau-lsp) and a single
  `lune run check` gate: format, lint, strict type check, unit tests, build, build smoke test.
- **RemoteGuard** package: typed argument checks (`t`), token-bucket `RateLimiter` and a guard
  pipeline for RemoteEvents/RemoteFunctions, with README, API docs, MIT license and tests.
- Protocol module declaring every remote with argument checks and per-player rate limits;
  NetService with an abuse budget that kicks clients sending malformed traffic.
- Session-locked player data (SessionStore): UpdateAsync locks, stale-lock takeover, autosave,
  BindToClose release, retries with backoff and jitter, schema migrations v1 → v3, refusal of
  newer-schema data, in-memory fallback in Studio. Leaderstats for coins and wins.
- Round system: pure RoundMachine over an explicit StateMachine, fair RoleAssigner, RoundService
  for teleports, collision groups, rewards and replicated state.
- Building: grid placement with budget, three block types, support rules, reach and overlap
  checks, remove-with-refund during build and repair during the hunt.
- Hunter kit: Breach, Tag (line of sight), Shockwave and Sprint, all with server cooldowns.
- Practice mode with bot builders and a bot hunter, enabled when alone in Studio.
- Code-generated map (arena, fort barrier, hunter cage, lobby, scenery, lighting) and code-built
  HUD (phase and timer, role badge and reveal, hotbar, ability cooldowns, toasts, results, practice
  role picker). Cheap VFX and sounds from built-in assets.
- Docs: README, architecture, decisions, testing log with manual checklist, status.

### Fixed during live Studio playtests
- Tag line of sight used a single eye-level ray that grazed blocks above a gap; it now passes if
  either the body-to-body or the head-to-head ray is clear.
- Sprint never ended: `Humanoid.WalkSpeed` is stored as float32, so the restore compared
  28.799999 with 28.8. It now compares with a tolerance.
- Server-to-client remotes had no server listener, so a client could fill the invocation queue.
  They are now charged to the abuse budget.

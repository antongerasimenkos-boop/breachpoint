# RemoteGuard

Typed argument validation and per-player rate limiting for Roblox `RemoteEvent` /
`RemoteFunction` handlers. Pure Luau, no dependencies, `--!strict`, unit-tested with Lune.

Every request from a client is hostile until proven otherwise. RemoteGuard puts one small,
predictable pipeline in front of each handler:

```
request ──► rate limit ──► argument count ──► per-argument checks ──► handler (xpcall)
               │                 │                    │                     │
               └─────────────────┴──── reject ────────┴─────────────────────┘
                                         │
                                  onReject(player, reason, detail)
```

- **Token-bucket rate limiting** per player: bursts up to `capacity`, sustained rate
  `refillPerSecond`. Buckets are weak-keyed and cleared with `forget(player)`.
- **Argument checks** that assume hostile input: finite numbers only (NaN/inf rejected), bounded
  integers, length-limited UTF-8 strings, enums, finite `Vector3`s, strict tables that reject
  unknown keys, dense arrays with a maximum length.
- **Extra arguments are rejected.** A payload smuggled after the expected arguments never reaches
  your handler.
- **Rejected requests still cost a token**, so spamming garbage drains the sender's own budget.
- **Handler errors are contained.** They are reported as `HandlerError` and never crash the
  connection.

## Install

Copy `src/` into your project as a ModuleScript named `RemoteGuard` (with Rojo, map the folder:
`"RemoteGuard": { "$path": "packages/remote-guard/src" }`). No other files are needed at runtime.

## Usage

```lua
local Players = game:GetService("Players")
local RemoteGuard = require(ReplicatedStorage.Packages.RemoteGuard)
local t = RemoteGuard.t

local placeGuard = RemoteGuard.new({
	name = "PlaceBlock",
	args = { t.integer(-6, 5), t.integer(0, 5), t.integer(-6, 5), t.literal("Wood", "Stone", "Metal") },
	rateLimit = { capacity = 8, refillPerSecond = 6 },
	onReject = function(player, reason, detail)
		-- e.g. count strikes and kick on abuse; log HandlerError as a bug
	end,
})

placeGuard:connect(remotes.PlaceBlock, function(player, x, y, z, kind)
	-- Only well-typed, in-budget requests get here.
	-- Game rules (phase, ownership, distance, cooldowns) are still your job.
end)

Players.PlayerRemoving:Connect(function(player)
	placeGuard:forget(player)
end)
```

RemoteFunctions work the same way. A rejected invoke returns `nil`:

```lua
statsGuard:bindFunction(remotes.GetStats, function(player)
	return buildStatsFor(player)
end)
```

## API

### `RemoteGuard.new(options): Guard`

| option | type | |
|---|---|---|
| `name` | `string` | Used in reject details and stats. Required. |
| `args` | `{ Check }` | One check per positional argument. Required (may be empty). |
| `rateLimit` | `{ capacity: number, refillPerSecond: number }?` | Per-player bucket owned by this guard. |
| `limiter` | `RateLimiter?` | A bucket shared with other guards (e.g. a global per-player budget). Checked before `rateLimit`. |
| `clock` | `(() -> number)?` | Time source for the owned bucket. Defaults to `os.clock`. Inject one in tests. |
| `onReject` | `((player, reason, detail) -> ())?` | Called for every rejected request. |

`reason` is one of `"RateLimited" | "TooManyArgs" | "BadArg" | "HandlerError"`.

### `Guard`

| member | |
|---|---|
| `guard:connect(remoteEvent, handler): RBXScriptConnection` | Guards `OnServerEvent`. |
| `guard:bindFunction(remoteFunction, handler)` | Sets a guarded `OnServerInvoke`. |
| `guard:wrap(handler): (player, ...) -> ...` | The guarded function itself, for custom wiring and tests. |
| `guard:check(player, ...): (boolean, Reason?, string?)` | Runs the pipeline without a handler. |
| `guard:forget(player)` | Clears the player's buckets. Call on `PlayerRemoving`. |
| `guard.stats` | `{ accepted: number, rejected: { [Reason]: number } }` |

### `RemoteGuard.RateLimiter`

```lua
local limiter = RemoteGuard.RateLimiter.new({ capacity = 10, refillPerSecond = 2, clock = os.clock })
limiter:consume(key, cost?)  --> boolean (spends nothing when it returns false)
limiter:peek(key)            --> tokens available now
limiter:forget(key)
```

### `RemoteGuard.t` — checks

A check is `(value: any) -> (boolean, string?)`.

| check | accepts |
|---|---|
| `t.any` | anything except `nil` |
| `t.boolean` | `true` / `false` |
| `t.number` | finite numbers (no NaN, no ±inf) |
| `t.numberRange(min, max)` | finite numbers in `[min, max]` |
| `t.integer(min?, max?)` | whole finite numbers, optionally bounded |
| `t.string(maxBytes?)` | valid UTF-8 strings, at most `maxBytes` (default 200) |
| `t.literal(...)` | exactly one of the listed values |
| `t.vector3` | `Vector3` with finite components |
| `t.instanceIsA(className)` | an `Instance` that `IsA(className)` and is parented |
| `t.optional(check)` | `nil` or a value passing `check` |
| `t.union(...)` | a value passing any of the checks |
| `t.array(check, maxLength)` | dense arrays (no holes, no extra keys) of valid items |
| `t.strictInterface(shape)` | tables with exactly these keys, each passing its check |

## What it does not do

RemoteGuard proves a request is **well-formed and within budget**. It cannot know your game
rules. Phase, role, ownership, distance and cooldown checks still belong in your handler, because
only the server's game state can answer them.

## Tests

```bash
lune run test remote-guard
```

The specs in `tests/` receive their harness as a parameter, so they run under any
`describe/it/expect` runner with the same shape.

## License

MIT, see [LICENSE](LICENSE).

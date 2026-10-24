# cis_libs — documentation

**Version 1.0.0**, the first public release. Contract **`api = 1`**.
`docs/archive/DOCUMENTATION-1.x.md` describes the unpublished development
builds that preceded 1.0.0. It is not current and documents no release.

The machine-readable contract is `api.lua`. It is not listed in `fxmanifest.lua`.
Load it with `loadfile`. `npm run test:api` fails if `api.lua` and the
registered surface disagree. `npm run gen-types` writes the tables in §6 from
that file; `npm run gen-types:check` fails if they drift.

---

## 0. Boundary

Three facts the suite enforces:

1. **`cis_libs` owns no table, reads no config file, and calls no third-party
   resource by name.** It is a boundary, not an implementation.
2. **The contract is versioned on its own.** `api.lua` declares `api = 1`; the
   product version (1.0.0) can move without it. A consumer checks the
   contract major, not the product version.
3. **A missing product is a refusal with a reason**, not a nil that looks like
   "not found". Run `cis_debug` on the server console.

```
cis_libs          boundary and primitives. Knows the shape of a capability.
   ▲  ▲  ▲        Knows nothing about who provides it.
   │  │  └── cis_keys     doors, keys (optional)
   │  └───── cis_bridge   third-party adapters (optional)
   └──────── cis_core     framework, config, migrations (optional)
```

`cis_libs` alone boots: zones, callbacks, entity sync, cache, logging, streaming,
points, commands, diagnostics. Every capability call with no provider answers
`false, reason`.

---

## 1. Install

OneSync on. Server build ≥ 4500. Both are declared on the manifest.

```cfg
ensure cis_libs
```

```lua example
dependency 'cis_libs'
shared_script '@cis_libs/init.lua'
```

`init.lua` is the only file a consumer may `shared_script`. Each Lua file is its
own chunk. `shared_script '@cis_libs/shared/registry.lua'` gives you a second
registry that nothing else can see.

Call with a colon:

```lua example
exports['cis_libs']:GetCapabilities()
```

Calling `Export` through a string index on the exports table is the same idea
done wrong: that table becomes argument 1.

A Lua function that you pass *into* an export (a zone `onEnter`, a callback
handler, a hook body) arrives as a funcref. Each call to it crosses the
boundary again, and it raises once your resource stops or restarts. Zones,
points and keybinds made through `init.lua` run in your resource and avoid
that (§5.2). Elsewhere an event name (`onEnterEvent`) or `'resource:Export'`
outlives a restart.

Editor types: add `cis_libs/types` to the Lua workspace. The stub is generated.
Do not edit it.

---

## 2. Capabilities

A capability is a named slot. A product registers a provider. First registration
wins. Only the owner may release it.

Slots: `framework`, `database`, `target`, `inventory`, `inventoryProvider`,
`doors`, `doorsClient`, `discord`, `security`, `dataProbe`, `migration`, `ui`.

A resource that registers a slot `cis_libs` does not declare is refused on every
boot. `WaitCapability(slot, timeoutMs?)` waits for a slot to fill (default
30000 ms) and returns `true, owner` or `false, reason`.

`GetCapabilities()` returns every slot, always. Empty is `owner = nil`,
`resolved = false`, never absent.

---

## 3. Configuration

`SetConfig(config?, security?, discord?)` — three arguments, not one table.
First successful supplier wins. A second caller gets `false` plus the owner.
`cis_core` is the intended supplier. Built-in defaults are not a supplier, so
the first real `SetConfig` is accepted.

`security` is merged over the default `Security` key by key, like `config`,
and always over fresh defaults: a key you leave out keeps its default
(`DropPlayer` stays `true`), and a second supply replaces the first one's
`AuthorizedResources` instead of adding to it.

```lua example
exports['cis_libs']:SetConfig({
    UpdateInterval = { Player = 500, Weapon = 500 },
}, {
    EventPrefix = 'cis_libs',
    AuthorizedResources = { 'cis_core', 'cis_keys', 'my_resource' },
    AllowAnyResource = false,
    DropPlayer = false,
}, {
    DiscordLogsLinks = {},
})
```

**Empty `Security.AuthorizedResources` is always restrictive.** That is the one
behaviour change in 1.0.0. There is no legacy exception, no marker file, and no
database probe. Mutating exports (`SyncCreate`, door writes, …) refuse every
foreign resource until the list names it, or until `AllowAnyResource = true`
(loud on every boot; do not ship with it on).

**Server convars outrank `SetConfig`.** `SetConfig` is honoured from whichever
resource calls it first; a convar is set in `server.cfg` before any resource
runs. So the security posture and the limits read a convar first, and only fall
back to what `SetConfig` supplied when that convar is unset or blank:

| Convar | Overrides | Default |
|---|---|---|
| `cis_authorized_resources` | `Security.AuthorizedResources` (comma or space separated) | unset |
| `cis_allow_any_resource` | `Security.AllowAnyResource` (`true` / `false`) | unset |
| `cis_config_supplier` | who may call `SetConfig` at all | unset: first caller |
| `cis_cb_rate_per_name` | `Config.CallbackLimits.PerName` | 20 |
| `cis_cb_rate_per_player` | `Config.CallbackLimits.PerPlayer` | 60 |
| `cis_cb_window_ms` | `Config.CallbackLimits.WindowMs` | 1000 |
| `cis_cb_max_inflight` | `Config.CallbackLimits.MaxInFlight` | 8 |
| `cis_cb_max_string_len` | `Config.CallbackLimits.MaxStringLen` | 4096 |
| `cis_check_version` | `Config.CheckVersion` (`true` / `false`) | unset |

Precedence for the posture, in order:

1. If **either** `cis_authorized_resources` or `cis_allow_any_resource` is set,
   the convars decide and `Security.AuthorizedResources` /
   `Security.AllowAnyResource` are **ignored whole** — `SetConfig` can neither
   narrow nor extend them. A named list still wins over allow-any.
2. Otherwise `Security` from `SetConfig` decides, exactly as in 1.0.0.
3. Otherwise the built-in default: restrictive.

```cfg
set cis_authorized_resources "cis_core,cis_keys,my_resource"
set cis_config_supplier "cis_core"
```

Use `set`, never `setr`: none of these may reach a client. The manifest
declares them under a `convar_category`, so txAdmin lists them. Limits are
re-read at most once a second, so a console `set` lands without a restart.

The client payload is a whitelist. Webhook URLs, drop handlers, and
`AuthorizedResources` do not leave the server. The allow-list also gates
`RegisterCapability` on both realms; for the client's half, the payload carries
a one-way digest of each allowed name (`Providers`), so a client can check a
caller it runs but cannot read the list. A client capability registered before
that payload arrives is held, then filed or refused.

`Security.EventPrefix` is **not** a prefix on every net event: every
`cis_libs:*` event is a literal. It prefixes only the legacy
`<EventPrefix>:doorlock:requestState` a client sends when no `doorsClient`
provider is registered, and `GetLibsPrefix()` reports it.

---

## 4. Diagnostics

| Command | Who | What |
|---|---|---|
| `cis_debug` | console, or a player with framework `admin` | ready flag, capability table, who supplied config. No secrets. |
| `cis_doctor` | console | `GetSelfCheck()`: each problem names its fix. |
| `cis_audit` | console | in-memory audit ring. |
| `cis_force_unregister <slot>` | console | vacates a slot. Restricted. |

`GetDiagnostics(opts?)` is counts only: never a player name, identifier, or IP.
`opts.collect = true` runs `collectgarbage` in **this** resource before
`memoryKb`. A collect in the caller’s Lua state does not collect cis_libs.
`memoryKb` is Lua kilobytes (`collectgarbage('count')`), not bytes.

---

## 5. Sync, callbacks, zones

- **Sync** is server-authoritative. Ids are namespaced by the invoking resource.
  Two resources may reuse the same id string; they are different records.
  `networked = true` is created and deleted on the server. A kind that cannot be
  made reliable refuses that flag. Default streaming radius 80. No hysteresis:
  one threshold for enter and leave.
- **Callbacks** across the wire return at most 6 values. `Cis.callback.await`
  errors on refusal by design; a translation layer must not inherit that.
  `RegisterCallback(name, handler, opts?)` takes `{ remote, ace, schema,
  maxStringLen }`; `remote = false` makes a callback server-only (a client is
  told `'unknown'`). Every client request is checked, in order: the player's
  budget across all names (`PerPlayer`), the name, the per-name rate
  (`PerName`), the ACE, payload size and string length (`MaxStringLen`), the
  schema, and handlers in flight (`MaxInFlight`). Refusals reach the client as
  `'rate'`, `'unknown'`, `'denied'`, `'too large'`, `'bad payload'` or `'busy'`.
  A player who drops rejects every await still waiting on them with
  `'player dropped'`.
- **Zones / points / keybinds** created through `init.lua` run in the calling
  resource (§5.2): their handlers are plain local functions. Through the
  exports (`CreateZone`, `CreatePoint`, `KeybindAdd`) a handler arrives as a
  funcref, or is an event name. **Hooks** take event names or export
  references. Server zones exist (`Cis.zones.server.*`) and do not draw.

### 5.1 Modules

Twenty-four pure-Lua modules ship in `files {}` and load on demand through
`Cis.require(name)`: `curve`, `heap`, `interp`, `lru`, `random`, `rate`,
`ringbuffer`, `set`, `sparse`, `window`, `array`, `class`, `cron`, `id`,
`json`, `locale`, `mathx`, `print`, `semver`, `string`, `table`, `time`,
`timer`, `validate`. Each loads into the **calling** resource's Lua state,
once per state, and installs no global. `Cis.require('unknown')` raises and
lists the valid names; `Cis.requireList()` returns them.

A resource's own files load the same way. `Cis.require('client.utils')`,
`Cis.require('client/utils')` and `Cis.require('./client/utils')` all read
`client/utils.lua` from the calling resource; `Cis.require('@other/shared/cfg')`
reads `shared/cfg.lua` from `other`. A file is read once per Lua state, loaded
as text only, and runs in its own environment: reads fall through to the
resource's globals, writes stay in the module. It receives
`(name, '@resource/path.lua')` like Lua's `require`, and a file that returns
nothing is cached as `true`. A path that leaves the resource (`..`, an
absolute path, a backslash) is refused, and a circular require raises naming
the chain.

The supported way to use a module is `shared_script '@cis_libs/init.lua'`
plus `Cis.require`. Loading a module file directly still sets its legacy
global (`CisLRU`, …) because this repository's suites and bench load them that
way; it is not a consumer integration.

Conventions shared by every module: functions take the container as their
first argument (`lru.get(cache, key)`, not `cache:get(key)`); a bad argument
from configuration answers `nil, reason`, while a programming error (a
non-number where only numbers make sense) raises; a point is `{ x, y, z }`,
`{ 1, 2, 3 }` or a FiveM `vector2`/`vector3`/`vector4`. Headings are GTA
headings: degrees, 0 facing +Y, 90 facing −X. Rate limiters and windows take
time in **seconds**.

The `array`, `set`, `ringbuffer` and `timer` objects also carry a metatable
whose `__index` is their module, so `a:map(fn)` is `array.map(a, fn)` and
`t:pause()` is `timer.pause(t)`; cron jobs have `job:stop()`, `job:isActive()`
and `job:nextRun()`. An `array` reads its explicit length `n` (or a plain
table's own `n`) rather than `#t`, so holes never shorten it, and nothing in it
mutates its input except `push` and `splice`.

The runtime modules read FiveM state in the **calling** resource:

| Module | Reads | Notes |
|---|---|---|
| `locale` | `LoadResourceFile(GetCurrentResourceName(), 'locales/<lang>.json')`, convar `cis:locale` | List the files in your own `files {}`. English is the fallback file and the fallback per key; `${name}` from a table argument, `%s` positionally; a missing key answers the key and warns once. |
| `print` | convar `cis:printlevel:<resource>`, then `cis:printlevel` | Levels `error` < `warn` < `info` (default) < `verbose` < `debug`. Read at load; `print.refresh()` re-reads. A filtered call formats nothing. |
| `timer` | `GetGameTimer`, `CreateThread`, `Wait` | A running timer is one thread asleep for exactly the time left. `setTimeout`/`setInterval` take the callback and delay in either order. |
| `cron` | `os.time`, `os.date`, `CreateThread`, `Wait` | Server **local** time (`{ utc = true }` for UTC). Day of month and day of week are ORed when both are restricted, as in Vixie cron. One scheduler thread per Lua state sleeps until the next due job; a stall runs a missed job once. |

Set convars a client must see with `setr`, e.g. `setr cis:locale "pt"` and
`setr cis:printlevel:my_shop "debug"`.

The reference below is generated from the `---@param`/`---@return`
annotations in each module's source by `npm run gen-types`, which also writes
the editor types; `npm run gen-types:check` fails when either is stale or a
module function is untyped.

<!-- generated:modules:begin -->

#### `array` — `Cis.require('array')`

Source: `shared/util/array.lua`.

| Function | Signature | Summary |
|---|---|---|
| `chunk` | `(a: table, size: integer) → table` | Consecutive pieces of at most size elements. |
| `concat` | `(a: table, ...: any) → table` | The array followed by each argument; an array-like argument is spread one level, anything else is appended as one element. |
| `every` | `(a: table, fn: fun(value: any, index: integer, array: table): any) → boolean` | Whether fn accepts every element (true for an empty array). |
| `filter` | `(a: table, fn: fun(value: any, index: integer, array: table): any) → table` | The elements fn accepts, in order, with no holes. |
| `find` | `(a: table, fn: fun(value: any, index: integer, array: table): any) → any, integer\|nil` | The first element fn accepts. |
| `findIndex` | `(a: table, fn: fun(value: any, index: integer, array: table): any) → integer\|nil` | The index of the first element fn accepts. |
| `flat` | `(a: table, depth?: integer) → table` | Nested array-likes spread into one array, to a depth. |
| `forEach` | `(a: table, fn: fun(value: any, index: integer, array: table)) → nil` | Call fn for every element. |
| `from` | `(list: table, n?: integer) → table` | A copy of a table as an array. |
| `groupBy` | `(a: table, keyOf: fun(value: any, index: integer): any) → table<any, table>` | Elements grouped by fn's answer. |
| `includes` | `(a: table, v: any) → boolean` | Whether the array holds v. |
| `indexOf` | `(a: table, v: any, from?: integer) → integer\|nil` | The first index holding a value equal (==) to v. |
| `isArray` | `(v: any) → boolean` | Whether a value is an array made by this module. |
| `isArrayLike` | `(v: any) → boolean` | Whether a table should be SPREAD by concat and flat: an array made here, a table with a numeric `n`, or a table whose every key is a positive integer (an empty table counts). |
| `join` | `(a: table, sep?: string) → string` | The elements joined into a string. |
| `len` | `(a: table) → integer` | The length: `n` when the table has one, else #t. |
| `map` | `(a: table, fn: fun(value: any, index: integer, array: table): any) → table` | A new array of fn's results. |
| `max` | `(a: table, keyOf?: fun(value: any, index: integer): any) → any, integer\|nil` | The largest element (the first one, on a tie). |
| `min` | `(a: table, keyOf?: fun(value: any, index: integer): any) → any, integer\|nil` | The smallest element (the first one, on a tie). |
| `new` | `(...: any) → table` | An array of the arguments, holes and trailing nils included. |
| `push` | `(a: table, ...: any) → integer` | Append values IN PLACE. |
| `reduce` | `(a: table, fn: fun(acc: any, value: any, index: integer, array: table): any, initial?: any) → any` | Fold left. |
| `reverse` | `(a: table) → table` | The elements in reverse order. |
| `slice` | `(a: table, i?: integer, j?: integer) → table` | Elements i..j inclusive. |
| `some` | `(a: table, fn: fun(value: any, index: integer, array: table): any) → boolean` | Whether fn accepts at least one element. |
| `sort` | `(a: table, less?: fun(x: any, y: any): boolean) → table` | A STABLE sort: elements the comparator calls equal keep their order. |
| `splice` | `(a: table, start: integer, deleteCount?: integer, ...: any) → table` | Remove deleteCount elements at start and insert the extra arguments there, IN PLACE. |
| `sum` | `(a: table) → number\|nil, string\|nil` | The sum of the elements; holes are skipped. |
| `unique` | `(a: table, keyOf?: fun(value: any, index: integer): any) → table` | The first occurrence of each distinct element (or of each distinct key). |
| `zip` | `(...: table) → table` | Tuples of the i-th element of every argument; as long as the LONGEST, shorter ones padded with holes. |

#### `class` — `Cis.require('class')`

Source: `shared/util/class.lua`.

| Function | Signature | Summary |
|---|---|---|
| `classOf` | `(obj: any) → table\|nil` | The class of an instance. |
| `instanceof` | `(obj: any, cls: table) → boolean` | Whether obj is an instance of cls or of any class derived from it. |
| `isClass` | `(value: any) → boolean` | Whether a value is a class made by this module. |
| `nameOf` | `(value: any) → string\|nil` | The name of a class, or of an instance's class. |
| `new` | `(name: string, super?: table) → table` | A new class, optionally inheriting from another made by this module. |
| `privates` | `() → fun(obj: table): table` | An accessor for private per-instance fields, backed by a weak-keyed table. |

#### `cron` — `Cis.require('cron')`

Source: `shared/util/cron.lua`.

| Function | Signature | Summary |
|---|---|---|
| `count` | `() → integer` | How many jobs are scheduled in this Lua state. |
| `isActive` | `(job: table) → boolean` | Whether a job is still scheduled. |
| `matches` | `(expr: string\|table, time?: number, opts?: table) → boolean\|nil, string\|nil` | Whether a moment falls in a minute the expression matches. |
| `next` | `(expr: string\|table, fromTime?: number, opts?: table) → number\|nil, string\|nil` | The first time strictly after fromTime that the expression matches. |
| `nextRun` | `(job: table) → number\|nil` | When a job runs next. |
| `parse` | `(expr: string) → table\|nil, string\|nil` | Parse a five-field expression or a macro. |
| `schedule` | `(expr: string\|table, fn: fun(job: table, due: number), opts?: table) → table\|nil, string\|nil` | Run fn at every time the expression matches, until stopped. |
| `stop` | `(job: table) → boolean` | Stop a job. |

#### `curve` — `Cis.require('curve')`

Source: `shared/algo/curve.lua`.

| Function | Signature | Summary |
|---|---|---|
| `catmullRom` | `(p0: table\|vector2\|vector3\|vector4\|nil, p1: table\|vector2\|vector3\|vector4, p2: table\|vector2\|vector3\|vector4, p3: table\|vector2\|vector3\|vector4\|nil, t: number, alpha?: number) → number, number, number` | Evaluate one Catmull-Rom segment from four control points. |
| `count` | `(path: table) → integer` | Number of control points, or 0 for a path built from nothing. |
| `hermite` | `(p0: table, p1: table, m0: table, m1: table, t: number) → number, number, number` | Cubic Hermite basis evaluation. |
| `length` | `(path: table) → number` | Total arc length of the path in metres, measured along the CURVE and not along the |
| `lengthOf` | `(points: table\|nil) → number` | Chord length of a polyline, summed. |
| `newPath` | `(points: table, opts?: table) → table` | Build an arc-length parameterised Catmull-Rom path. |
| `pointAt` | `(path: table, distance: number, out?: table) → table\|nil` | The point at `distance` metres along the path, as a table. |
| `pointAtT` | `(path: table, t: number, out?: table) → table\|nil` | The point at a fraction of the whole path, 0..1. |
| `pointAtXYZ` | `(path: table, distance: number) → number, number, number, boolean` | The point at `distance` metres along the path. |
| `sample` | `(path: table, count?: number) → table` | Evenly spaced samples along the path, for drawing a route, handing one to a native, |
| `tangentAtXYZ` | `(path: table, distance: number) → number, number, number` | Unit tangent (the direction of travel) at `distance` metres along the path. |

#### `heap` — `Cis.require('heap')`

Source: `shared/algo/heap.lua`.

| Function | Signature | Summary |
|---|---|---|
| `build` | `(list: table, less?: fun(a: any, b: any): boolean) → table` | Build a heap from an existing list in O(n). |
| `clear` | `(h: table) → nil` | Drop everything. |
| `dequeue` | `(q: table) → any` | Remove and return the highest-priority (lowest number) value. |
| `drain` | `(h: table) → table` | Pop everything into a sorted array, cheapest element first. |
| `enqueue` | `(q: table, value: any, priority?: number) → integer` | Add a value at a priority. |
| `isEmpty` | `(h: table) → boolean` | Is the heap empty? |
| `new` | `(less?: fun(a: any, b: any): boolean) → table` | Create an empty heap. |
| `newQueue` | `() → table` | A FIFO-ordered priority queue. |
| `peek` | `(h: table) → any` | The minimum, without removing it. |
| `peekQueue` | `(q: table) → any` | The next value without removing it. |
| `pop` | `(h: table) → any` | Remove and return the minimum. |
| `push` | `(h: table, value: any) → integer\|nil, string\|nil` | Add a value. |
| `remove` | `(h: table, value: any) → boolean` | Remove a specific value wherever it is. |
| `replaceTop` | `(h: table, value: any) → any, string\|nil` | Replace the minimum in place. |
| `size` | `(h: table) → integer` | How many values are queued. |

#### `id` — `Cis.require('id')`

Source: `shared/util/id.lua`.

| Function | Signature | Summary |
|---|---|---|
| `draw` | `(count?: number, alphabet?: string, rng?: table\|fun(): number) → string\|nil, string\|nil` | Draw `count` symbols from `alphabet`. |
| `newCounter` | `() → table` | A counter, for ids that must be readable and ordered. |
| `next` | `(counter: table, kind?: string) → string\|nil, string\|nil` | Take the next value from a counter. |
| `normaliseName` | `(raw: string, used?: table, opts?: table) → string\|nil, string\|nil` | Turn a display name into a key that is safe to use as a table key, a database column |
| `short` | `(prefix?: string, opts?: table) → string\|nil, string\|nil` | A short opaque id, optionally prefixed. |
| `uuid` | `(rng?: table\|fun(): number) → string\|nil, string\|nil` | An RFC 4122 version 4 shaped string, from the same injected generator. |

#### `interp` — `Cis.require('interp')`

Source: `shared/algo/interp.lua`.

| Function | Signature | Summary |
|---|---|---|
| `angleDelta` | `(a: number, b: number) → number` | Shortest signed difference from angle a to angle b, in radians. |
| `clamp` | `(v: number, lo: number, hi: number) → number\|nil, string\|nil` | Limit v to [lo, hi]. |
| `clamp01` | `(v: number) → number` | Limit v to [0, 1]. |
| `clampLength` | `(v: table\|vector2\|vector3\|vector4, maxLength: number, out?: table) → table` | Shorten a vector to at most maxLength. |
| `damp` | `(current: number, target: number, smoothTime: number, dt: number) → number` | Frame-rate independent exponential approach to target. |
| `dampAngle` | `(current: number, target: number, smoothTime: number, dt: number) → number` | damp() for an angle in radians, along the shortest arc. |
| `dampVec3` | `(current: table\|vector2\|vector3\|vector4, target: table\|vector2\|vector3\|vector4, smoothTime: number, dt: number, out?: table) → table` | damp() per component. |
| `dist2` | `(ax: number, ay: number, bx: number, by: number) → number` | Distance between two 2D points given as numbers. |
| `dist3` | `(ax: number, ay: number, az: number\|nil, bx: number, by: number, bz: number\|nil) → number` | Distance between two 3D points given as numbers; a nil z is 0. |
| `distance2D` | `(a: table\|vector2\|vector3\|vector4, b: table\|vector2\|vector3\|vector4) → number` | Planar distance between two points. |
| `distance3D` | `(a: table\|vector2\|vector3\|vector4, b: table\|vector2\|vector3\|vector4) → number` | Distance between two points; a missing z is 0. |
| `ease` | `(name: string, t: number) → number` | Apply the named easing curve to t in [0, 1]. |
| `hasEase` | `(name: any) → boolean` | Is `name` one of the curves in EASINGS? |
| `headingDelta` | `(a: number, b: number) → number` | Returns degrees in [-180, 180). |
| `headingToVector` | `(headingDeg: number) → number, number` | Returns x. |
| `inverseLerp` | `(a: number, b: number, v: number) → number` | Where v sits between a and b, as t. |
| `lerp` | `(a: number, b: number, t: number) → number` | Linear interpolation; t is not clamped. |
| `lerpClamped` | `(a: number, b: number, t: number) → number` | Linear interpolation with t clamped to [0, 1]. |
| `lerpHeading` | `(a: number, b: number, t: number) → number` | Interpolate two headings along the shortest arc. |
| `lerpVec3` | `(a: table\|vector2\|vector3\|vector4, b: table\|vector2\|vector3\|vector4, t: number, out?: table) → table` | Linear interpolation between two points. |
| `moveTowards` | `(current: number, target: number, maxDelta: number) → number` | Step current toward target by at most maxDelta. |
| `moveTowardsVec3` | `(current: table\|vector2\|vector3\|vector4, target: table\|vector2\|vector3\|vector4, maxDelta: number) → table` | Step a point toward a target by at most maxDelta metres. |
| `normalize` | `(v: table\|vector2\|vector3\|vector4, out?: table) → table` | Unit vector in the direction of v. |
| `remap` | `(v: number, inMin: number, inMax: number, outMin: number, outMax: number, clamped?: boolean) → number` | Map v from [inMin, inMax] to [outMin, outMax]. |
| `sign` | `(v: number) → integer` | The sign of v. |
| `smoothDamp` | `(current: number, target: number, velocity?: number, smoothTime: number, maxSpeed?: number, dt: number) → number, number` | Critically damped spring toward target (Unity-style SmoothDamp). |
| `smootherstep` | `(edge0: number, edge1: number, x: number) → number` | Ken Perlin's smootherstep of x between two edges. |
| `smoothstep` | `(edge0: number, edge1: number, x: number) → number` | Hermite smoothstep of x between two edges. |
| `vectorToHeading` | `(x: number, y: number) → number` | Returns degrees in [0, 360). |
| `wrap` | `(v: number, min: number, max: number) → number` | Wrap v into [min, max), correctly for negative input. |
| `wrapAngle` | `(rad: number) → number` | Wrap an angle in radians to [-pi, pi). |
| `wrapAnglePositive` | `(rad: number) → number` | Wrap an angle in radians to [0, 2pi). |
| `wrapDegrees` | `(deg: number) → number` | Wrap degrees to [0, 360). |

#### `json` — `Cis.require('json')`

Source: `shared/util/json.lua`.

| Function | Signature | Summary |
|---|---|---|
| `bind` | `(codec: table) → table\|nil, string\|nil` | Bind the functions to one codec, so a hot path does not pass it every call. |
| `check` | `(codec: table) → table\|nil, string\|nil` | Check that a value is shaped like a usable codec. |
| `checkEncodable` | `(value: any, opts?: table) → boolean, string\|nil` |  |
| `decode` | `(codec: table, text: string, opts?: table) → any, string\|nil` | Decode, refusing rather than raising. |
| `encode` | `(codec: table, value: any, opts?: table) → string\|nil, string\|nil` | Encode, refusing rather than raising. |
| `roundTrip` | `(codec: table, value: any, opts?: table) → any, string\|nil` | Encode and decode back, and return the value that survived. |
| `scanDepth` | `(text: string) → integer\|nil, string\|nil` | Measure nesting depth in JSON TEXT without parsing it. |
| `tryDecode` | `(codec: table, text: string, opts?: table) → boolean, any` | Decode, returning a boolean, for callers that cannot use the three-way form. |

#### `locale` — `Cis.require('locale')`

Source: `shared/util/locale.lua`.

| Function | Signature | Summary |
|---|---|---|
| `getLanguage` | `() → string\|nil` | The language in use. |
| `has` | `(key: string) → boolean` | Whether a key has a phrase. |
| `load` | `(lang?: string) → string\|nil, string\|nil` | Load a language from the calling resource's locales folder. |
| `set` | `(lang: string) → string\|nil, string\|nil` | Switch language; the same as load(lang). |
| `t` | `(key: string, ...: any) → string` | Translate a key. |

#### `lru` — `Cis.require('lru')`

Source: `shared/algo/lru.lua`.

| Function | Signature | Summary |
|---|---|---|
| `clear` | `(lru: table) → nil` | Empty the cache. |
| `count` | `(lru: table) → integer` | Number of live entries. |
| `each` | `(lru: table, fn: fun(key: any, value: any)) → number` | Call `fn(key, value)` for every entry, most recently used first. |
| `get` | `(lru: table, key: any) → any` | Look up a key and mark it as most recently used. |
| `has` | `(lru: table, key: any) → boolean` | Is a key present, without changing its recency? |
| `keys` | `(lru: table) → any[]` | Keys from most recently used to least. |
| `new` | `(capacity?: number) → table` | Create an empty cache. |
| `peek` | `(lru: table, key: any) → any` | Look up a key WITHOUT changing its recency. |
| `popOldest` | `(lru: table) → any, any` | Remove the least recently used entry. |
| `put` | `(lru: table, key: any, value: any) → any, string\|nil` | Store a value and mark it most recently used. |
| `remove` | `(lru: table, key: any) → any` | Remove a key, whatever its position in the order. |
| `removeWhere` | `(lru: table, predicate: fun(key: any, value: any): boolean) → integer` | Remove every entry for which `predicate(key, value)` is true. |

#### `mathx` — `Cis.require('mathx')`

Source: `shared/util/mathx.lua`.

| Function | Signature | Summary |
|---|---|---|
| `approx` | `(a: number, b: number, epsilon?: number) → boolean` | Equal within a tolerance that scales with the magnitude: \|a - b\| <= epsilon * max(1, \|a\|, \|b\|). |
| `clamp` | `(v: number, lo: number, hi: number) → number\|nil, string\|nil` | Clamp into [lo, hi]. |
| `fromHex` | `(s: string) → number\|nil, string\|nil` | Hexadecimal text back to a number. |
| `groupDigits` | `(n: number\|string, sep?: string, decimals?: integer) → string\|nil, string\|nil` | Thousands separators: 1234567.891 -> '1,234,567.891'. |
| `inverseLerp` | `(a: number, b: number, v: number) → number` | Where v sits between a and b, as a fraction: the inverse of lerp. |
| `lerp` | `(a: number\|vector2\|vector3\|vector4, b: number\|vector2\|vector3\|vector4, t: number) → number\|vector2\|vector3\|vector4` | Linear interpolation; t is not clamped. |
| `remap` | `(v: number, inMin: number, inMax: number, outMin: number, outMax: number, clamped?: boolean) → number` | Map v from [inMin, inMax] onto [outMin, outMax]. |
| `round` | `(n: number, decimals?: integer) → number` | Round half AWAY from zero, to a number of decimal places. |
| `toHex` | `(n: number, opts?: table) → string\|nil, string\|nil` | A whole number as hexadecimal text, with no prefix. |
| `weightedPick` | `(entries: table, rng?: table\|fun(): number) → any, integer\|nil` | A weighted random choice. |

#### `print` — `Cis.require('print')`

Source: `shared/util/print.lua`.

| Function | Signature | Summary |
|---|---|---|
| `debug` | `(...: any) → nil` | Print at level debug. |
| `error` | `(...: any) → nil` | Print at level error. |
| `getLevel` | `() → string, string` | The level in force. |
| `info` | `(...: any) → nil` | Print at level info. |
| `isEnabled` | `(level: string\|integer) → boolean` | Whether a message at this level would print. |
| `refresh` | `() → string, string` | Re-read the level from the convars. |
| `setLevel` | `(level: string\|integer) → boolean\|nil, string\|nil` | Override the level for this resource until the next refresh. |
| `verbose` | `(...: any) → nil` | Print at level verbose. |
| `warn` | `(...: any) → nil` | Print at level warn. |

#### `random` — `Cis.require('random')`

Source: `shared/algo/random.lua`.

| Function | Signature | Summary |
|---|---|---|
| `float` | `(min: number, max: number, rng?: table\|fun(): number) → number\|nil, string\|nil` | Float in [min, max). |
| `gaussian` | `(mean?: number, standardDeviation?: number, rng?: table\|fun(): number) → number` | Normally distributed value, mean 0 and standard deviation 1 unless told otherwise. |
| `integer` | `(lo: number, hi: number, rng?: table\|fun(): number) → integer\|nil, string\|nil` | Integer in [lo, hi] INCLUSIVE, uniformly. |
| `newGenerator` | `(seed?: number) → table` | A seeded, reproducible generator (MRG32k3a, the seed mixed nonlinearly; the same stream in Lua 5.4 and fengari). |
| `pick` | `(list: table, rng?: table\|fun(): number) → any` | One uniformly random element of a list. |
| `sample` | `(list: table, k: number, rng?: table\|fun(): number) → table` | `k` distinct elements of a list, in random order, WITHOUT touching the input. |
| `shuffle` | `(list: table, rng?: table\|fun(): number) → table\|nil` | Fisher-Yates shuffle, IN PLACE. |
| `weighted` | `(entries: table, rng?: table\|fun(): number) → any` | Weighted choice. |
| `weightedIndex` | `(weights: number[], rng?: table\|fun(): number) → integer\|nil` | Index of a weighted choice, for callers that keep weights and values in parallel |

#### `rate` — `Cis.require('rate')`

Source: `shared/algo/rate.lua`.

| Function | Signature | Summary |
|---|---|---|
| `allow` | `(r: table, key: any, now?: number, cost?: number) → boolean` | Try to spend `cost` from a key's budget. |
| `clear` | `(r: table) → nil` | Forget every key. |
| `count` | `(r: table) → integer` | How many keys the limiter is tracking, including fully restored ones that have not |
| `newFixed` | `(opts?: table) → table` | A counter that resets on an aligned boundary. |
| `newSliding` | `(opts?: table) → table` | A two-bucket sliding window estimate. |
| `newTokenBucket` | `(opts?: table) → table` | A continuously refilling bucket. |
| `peek` | `(r: table, key: any, now?: number) → table` | Inspect a key's budget WITHOUT spending from it. |
| `prune` | `(r: table, now?: number, idleSec?: number) → integer` | Drop keys that have not been touched for `idleSec`. |
| `reset` | `(r: table, key: any) → nil` | Forget one key entirely. |

#### `ringbuffer` — `Cis.require('ringbuffer')`

Source: `shared/algo/ringbuffer.lua`.

| Function | Signature | Summary |
|---|---|---|
| `capacity` | `(rb: table) → integer` | The fixed capacity. |
| `clear` | `(rb: table) → table` | Drop every entry; the capacity is kept. |
| `get` | `(rb: table, i: integer) → any` | The entry at position i, 1 = oldest; a negative i counts from the newest (-1 = newest). |
| `isEmpty` | `(rb: table) → boolean` | Whether it holds nothing. |
| `isFull` | `(rb: table) → boolean` | Whether the next push will overwrite. |
| `isRingBuffer` | `(value: any) → boolean` | Whether a value is a buffer made by this module. |
| `new` | `(capacity: integer) → table` | A new, empty buffer. |
| `peek` | `(rb: table) → any` | The oldest entry, without removing it. |
| `peekLast` | `(rb: table) → any` | The newest entry, without removing it. |
| `pop` | `(rb: table) → any` | Remove and return the NEWEST entry. |
| `push` | `(rb: table, v: any) → any, boolean` | Append at the newest end. |
| `shift` | `(rb: table) → any` | Remove and return the OLDEST entry. |
| `size` | `(rb: table) → integer` | Number of entries held. |
| `toArray` | `(rb: table) → table` | The entries oldest-first as a new array. |

#### `semver` — `Cis.require('semver')`

Source: `shared/util/semver.lua`.

| Function | Signature | Summary |
|---|---|---|
| `best` | `(candidates: table, range: string, opts?: table) → any\|nil, string\|nil` | The highest version in a list that satisfies `range`. |
| `compare` | `(a: string\|table, b: string\|table, opts?: table) → integer\|nil, string\|nil` | Compare two versions by SemVer precedence. |
| `eq` | `(a: string\|table, b: string\|table, opts?: table) → boolean\|nil, string\|nil` | Returns equal precedence (build metadata does not count), or nil and a reason. |
| `gte` | `(a: string\|table, b: string\|table, opts?: table) → boolean\|nil, string\|nil` | Returns a >= b, or nil and a reason (see compare). |
| `lt` | `(a: string\|table, b: string\|table, opts?: table) → boolean\|nil, string\|nil` | Returns a < b, or nil and a reason. |
| `parse` | `(v: string\|table, opts?: table) → table\|nil, string\|nil` | Parse a version into its parts. |
| `satisfies` | `(version: string\|table, range: string, opts?: table) → boolean\|nil, string\|nil` | Does `version` satisfy a range expression? |

#### `set` — `Cis.require('set')`

Source: `shared/algo/set.lua`.

| Function | Signature | Summary |
|---|---|---|
| `add` | `(s: table, v: any) → boolean\|nil, string\|nil` | Add a member. |
| `clear` | `(s: table) → table` | Remove every member. |
| `difference` | `(a: table, b: table) → table` | Members of a that are not in b, in a's order. |
| `equals` | `(a: table, b: table) → boolean` | Same members, order ignored. |
| `has` | `(s: table, v: any) → boolean` | Membership test. |
| `intersect` | `(a: table, b: table) → table` | Members of both sets, in a's order. |
| `isSet` | `(value: any) → boolean` | Whether a value is a set made by this module. |
| `isSubset` | `(a: table, b: table) → boolean` | Whether every member of a is in b. |
| `new` | `(list?: table) → table` | A new set, optionally filled from an array. |
| `remove` | `(s: table, v: any) → boolean` | Remove a member. |
| `size` | `(s: table) → integer` | Number of members. |
| `union` | `(a: table, b: table) → table` | Members of either set: a's in a's order, then b's new ones in b's order. |
| `values` | `(s: table) → table` | The members as a new array, in insertion order. |

#### `sparse` — `Cis.require('sparse')`

Source: `shared/algo/sparse.lua`.

| Function | Signature | Summary |
|---|---|---|
| `add` | `(set: table, value: any) → boolean` | Add a value. |
| `at` | `(set: table, index: integer) → any` | The value at a dense index. |
| `clear` | `(set: table, hard?: boolean) → integer` | Empty the set in O(1). |
| `count` | `(set: table) → integer` | How many values are in the set. |
| `each` | `(set: table, fn: fun(value: any, index: integer)) → integer` | Visit every value present when the walk started. |
| `has` | `(set: table, value: any) → boolean` | Is the value in the set? |
| `isEmpty` | `(set: table) → boolean` | Is the set empty? |
| `new` | `() → table` | An empty sparse set: O(1) add, has, remove, and an O(1) clear. |
| `remove` | `(set: table, value: any) → boolean` | Remove a value; the last element moves into its slot. |
| `staleCount` | `(set: table) → integer` | Debug only: slots held, live or stale. |
| `toArray` | `(set: table) → any[]` | The values, as a new array. |

#### `string` — `Cis.require('string')`

Source: `shared/util/string.lua`.

| Function | Signature | Summary |
|---|---|---|
| `camel` | `(s: string) → string` | 'give_money' -> 'giveMoney'. |
| `collapse` | `(s: string) → string` | Collapse every run of whitespace to one space and trim both ends. |
| `contains` | `(s: string, needle: string, ignoreCase?: boolean) → boolean` | Case-insensitive-ish containment test, matching the needle LITERALLY. |
| `endsWith` | `(s: string, suffix: string, ignoreCase?: boolean) → boolean` | Returns false for a non-string, and true for an empty suffix. |
| `hasUtf8` | `() → boolean` | Whether this runtime has the utf8 library. |
| `kebab` | `(s: string) → string` | 'GiveMoney' -> 'give-money'. |
| `levenshtein` | `(a: string, b: string, maxDistance?: integer) → integer\|nil, string\|nil` | Levenshtein edit distance between two strings. |
| `padEnd` | `(s: any, width: integer, fill?: string) → string` | Pad on the right to `width`. |
| `padStart` | `(s: any, width: integer, fill?: string) → string` | Pad on the left to `width`. |
| `pascal` | `(s: string) → string` | 'give_money' -> 'GiveMoney'. |
| `random` | `(pattern: string, rng?: table\|fun(): number) → string\|nil, string\|nil` | A random string shaped by a pattern, like ox_lib's string.random: '1' a digit, 'A' an upper-case letter, 'a' a lower-case letter, '.' a letter or digit, '^' makes the next character literal, anything else is itself. |
| `snake` | `(s: string) → string` | 'GiveMoney' -> 'give_money'. |
| `split` | `(s: string, sep: string, opts?: table) → string[]\|nil, string\|nil` | Split on a separator. |
| `startsWith` | `(s: string, prefix: string, ignoreCase?: boolean) → boolean` | Returns false for a non-string, and true for an empty prefix. |
| `suggest` | `(word: string, candidates: string[], opts?: table) → string\|nil, integer\|string\|nil` | Pick the closest candidate to `word`. |
| `truncate` | `(s: string, max: number, ellipsis?: string\|false) → string` | Cut to a maximum length, adding an ellipsis when it actually cut. |
| `words` | `(s: string) → string[]` | Break a string into words, in the sense the case converters mean. |

#### `table` — `Cis.require('table')`

Source: `shared/util/table.lua`.

| Function | Signature | Summary |
|---|---|---|
| `compareKeys` | `(a: any, b: any) → integer` | Total order over keys of ANY type. |
| `count` | `(t: any) → integer` | Number of direct keys. |
| `deepCopy` | `(value: any, seen?: table) → any` | Deep copy with CYCLE PROTECTION. |
| `deepCopyStrict` | `(value: any, opts?: table) → any, string\|nil` | Deep copy that REFUSES a cyclic or over-deep input. |
| `deepMerge` | `(base: table\|nil, overlay: table\|nil, policy?: string, opts?: table) → table\|nil, string\|nil` | Deep merge into a NEW table. |
| `deepMergeInto` | `(target: table, overlay: table\|nil, policy?: string, opts?: table) → table\|nil, string\|nil` | Deep merge that mutates `target` in place and returns it. |
| `deepSize` | `(t: any, opts?: table) → integer` | Number of key/value pairs at EVERY level. |
| `depth` | `(t: any, maxDepth?: integer) → integer` | How deeply nested a table is. |
| `each` | `(t: table, comparator: fun(a: any, b: any): boolean\|number\|nil, fn: fun(value: any, key: any): boolean\|nil) → boolean\|nil, string\|nil` | Iterate in the same order as CisTable.keys without allocating the key array. |
| `filter` | `(t: table, predicate: fun(value: any, key: any): any) → table\|nil, string\|nil` | Keep the entries whose `predicate(value, key)` is truthy. |
| `find` | `(t: table, predicate: fun(value: any, key: any): any) → any` | First value whose `predicate(value, key)` is truthy. |
| `findCycle` | `(t: any, maxDepth?: integer) → any[]\|nil` | Find the key path that closes a cycle. |
| `isArray` | `(t: any) → boolean` | Returns true only for a table whose keys are all integers. |
| `isEmpty` | `(t: any) → boolean` | Returns true for nil, a non-table, or a table with no entries. |
| `isMap` | `(t: any) → boolean` | Inverse of isArray, with one deliberate exception: an EMPTY table is a map. |
| `join` | `(list: table, sep?: string) → string` | Concatenate a list, skipping entries that are not strings or numbers. |
| `keys` | `(t: table, comparator?: fun(a: any, b: any): boolean\|number) → any[]\|nil` | Keys in a DETERMINISTIC order: the contiguous integer prefix 1..n first, in |
| `map` | `(t: table, fn: fun(value: any, key: any): any, opts?: table) → table\|nil, string\|nil` | Transform every value. |
| `reduce` | `(t: table, fn: fun(acc: any, value: any, key: any): any, initial?: any) → any, string\|nil` | Fold a table into one value. |
| `shallowCopy` | `(t: any) → any` | Shallow copy. |
| `sortBy` | `(list: table, keyOf: fun(item: any, index: integer): any, comparator?: fun(a: any, b: any): boolean\|number) → table\|nil, string\|nil` | Sort a LIST by a derived key. |
| `values` | `(t: table, comparator?: fun(a: any, b: any): boolean\|number) → any[]\|nil` | Values, index-aligned with CisTable.keys on the same table. |

#### `time` — `Cis.require('time')`

Source: `shared/util/time.lua`.

| Function | Signature | Summary |
|---|---|---|
| `elapsed` | `(now: number, since: number) → number` | Seconds elapsed between two instants: `now - since`. |
| `formatDuration` | `(seconds: number, opts?: table) → string` | Format a duration as "2h 14m". |
| `now` | `(clock: fun(): number) → number\|nil, string\|nil` | Read the clock from an INJECTED source. |
| `parseDuration` | `(text: string\|number) → number\|nil, string\|nil` | Parse a human duration back into seconds. |
| `parts` | `(seconds: number) → table` | Break a duration into { weeks, days, hours, minutes, seconds }. |
| `relative` | `(timestamp: number, now: number, opts?: table) → string` | Relative time in words: '3 minutes ago', 'in 3 minutes', 'just now'. |
| `roundTo` | `(seconds: number, unit?: number) → number` | Round a duration in SECONDS to a whole number of `unit`s, to the NEAREST, and return |

#### `timer` — `Cis.require('timer')`

Source: `shared/util/timer.lua`.

| Function | Signature | Summary |
|---|---|---|
| `clearInterval` | `(id: integer) → boolean` | Alias of `clearTimeout`. Cancel a timeout or an interval. |
| `clearTimeout` | `(id: integer) → boolean` | Cancel a timeout or an interval. |
| `forceEnd` | `(t: table, triggerOnEnd?: boolean) → boolean` | End now. |
| `getTimeLeft` | `(t: table, format?: string) → number\|table` | The time left. |
| `hasEnded` | `(t: table) → boolean` | Whether it has run out or been ended. |
| `isPaused` | `(t: table) → boolean` | Whether it is paused (a new timer with autoStart = false is paused). |
| `new` | `(ms: number, onEnd?: fun(timer: table), opts?: table) → table` | A countdown timer that calls onEnd when it runs out. |
| `pause` | `(t: table) → boolean` | Pause, keeping the time left. |
| `play` | `(t: table) → boolean` | Start or resume. |
| `restart` | `(t: table, autoStart?: boolean) → boolean` | Back to the full duration. |
| `setInterval` | `(a: function\|number, b: function\|number, ...: any) → integer` | Call fn every ms milliseconds until cleared. |
| `setTimeout` | `(a: function\|number, b: function\|number, ...: any) → integer` | Call fn once after a delay, unless cleared first. |

#### `validate` — `Cis.require('validate')`

Source: `shared/util/validate.lua`.

| Function | Signature | Summary |
|---|---|---|
| `boolean` | `(v: any, opts?: table) → boolean, string\|nil` | Check a boolean. |
| `clamp` | `(v: number, min?: number, max?: number) → number\|nil, string\|nil` | Constrain a number to a range. |
| `defaults` | `(value: table, schema: table) → table\|nil, string\|nil` | Fill a table's missing fields from a schema's `default` values. |
| `field` | `(value: any, spec: table, path?: string) → boolean, string\|nil` | Validate one value against a field spec. |
| `integer` | `(v: any, opts?: table) → boolean, string\|nil` | Check that a value has no fractional part. |
| `isFinite` | `(v: any) → boolean` | Whether a number is finite. |
| `isInteger` | `(v: any) → boolean` | Whether a number has no fractional part. |
| `number` | `(v: any, opts?: table) → boolean, string\|nil` | Check a number. |
| `schema` | `(value: table\|nil, schema: table, opts?: table) → boolean, string\|string[]\|nil` | Validate a whole table against a schema of field specs. |
| `string` | `(v: any, opts?: table) → boolean, string\|nil` | Check a string. |
| `tableValue` | `(v: any, opts?: table) → boolean, string\|nil` | Check a table, and optionally its SHAPE. |

#### `window` — `Cis.require('window')`

Source: `shared/algo/window.lua`.

| Function | Signature | Summary |
|---|---|---|
| `clear` | `(w: table) → nil` | Empty the ring, keeping its capacity. |
| `count` | `(stats: table, key: any, now: number) → integer` | Alias of `samples`. The number of live SAMPLES for `key` inside the window. |
| `dedupeCount` | `(d: table) → integer` | How many keys are being tracked, including expired ones not yet pruned. |
| `each` | `(w: table, fn: fun(value: any, time: number\|nil, index: integer)) → integer` | Walk from oldest to newest, calling `fn(value, time, index)`. |
| `extreme` | `(stats: table, key: any, now: number, wantMax?: boolean) → number\|nil` | Largest or smallest live sample, without building the result table. |
| `isSeen` | `(d: table, key: any, now: number) → boolean` | Is a key currently inside its window? |
| `new` | `(capacity: number) → table` | A fixed-capacity ring of the last N pushes. |
| `newDedupe` | `(windowSec: number) → table` | A per-key "seen recently" filter over a time window. |
| `newStats` | `(windowSec: number, bucketSec?: number) → table` | Count / min / max / sum / mean over a trailing time window, per key. |
| `newest` | `(w: table) → any, number\|nil` | The newest value without removing it. |
| `oldest` | `(w: table) → any, number\|nil` | The oldest value without removing it. |
| `pop` | `(w: table) → any, number\|nil` | Remove and return the OLDEST value. |
| `prune` | `(d: table, now: number) → integer` | Drop every key whose window has expired. |
| `pruneStats` | `(stats: table, now: number) → integer` | Drop keys with no live sample. |
| `push` | `(w: table, value: any, time?: number) → any` | Append a value, overwriting the oldest one when the ring is full. |
| `read` | `(stats: table, key: any, now: number) → table\|nil` | Read a key's window. |
| `record` | `(stats: table, key: any, value: number, now: number) → boolean` | Add a value to a key's window. |
| `reset` | `(d: table, key: any) → nil` | Forget a key entirely, so the next `seen` accepts it regardless of the window. |
| `samples` | `(stats: table, key: any, now: number) → integer` | The number of live SAMPLES for `key` inside the window. |
| `seen` | `(d: table, key: any, now: number) → boolean` | Would this key be ACCEPTED right now? |

<!-- generated:modules:end -->

---

### 5.2 What runs where

Since 1.1.0 a consumer's per-frame client work runs in **its own Lua VM**, the
way ox_lib's `lib` loads modules into the resource that uses it.

| Runs in the consumer (through `init.lua`) | Runs once, in cis_libs |
|---|---|
| `Cis.zones.*` (client), `Cis.points.*`, `Cis.keybind.add` | the player cache producer (`client/cache.lua`) |
| `Cis.player.vehicle` / `seat` / `weapon` / `serverId` / `playerId` / `on`, `Cis.cache`, `Cis.onCache` (a mirror) | sync records, the callback endpoint, capability slots, rate limits, audit, config |
| `Cis.world.*`, `Cis.raycast.*`, `Cis.streaming.*`, `Cis.vehicle.*` | the NUI layer (`Cis.ui.*`, one NUI focus per client) and `Cis.target.*` |
| `Cis.marker.*`, `Cis.scaleform.new`, `Cis.dui.new`, `Cis.anim.play`, `Cis.controls.*` | server zones, `Cis.player.near`, doors, hooks, inventory, logging |

**One source.** The engines are `client/core/*.lua`: files of pure logic with
no state at file scope. cis_libs runs the shared ones as client scripts and
wraps one instance behind its exports (`CreateZone`, `CreatePoint`,
`KeybindAdd`, `ClosestPed`, `RaycastCamera`, `RequestModelTimeout`,
`GetVehicleProperties`), which keep their owner checks and stop sweeps. A
consumer loads the same text with `LoadResourceFile` and a text-only `load`
into a sandbox that refuses global writes, on the **first call** that needs
it. A resource that never touches zones loads no zone code and runs no zone
thread; zones, points, markers and control holds each start one thread on
their first object and end it with their last.

**Handlers are local.** `Cis.zones.box(name, center, size, { onEnter =
function(zone, coords) ... end })`, `Cis.points.add({ coords, distance,
onEnter, onExit, nearby })` and `Cis.keybind.add({ name, description,
defaultKey, onPress, onRelease })` (or ox_lib's `onPressed` / `onReleased`)
call plain functions in the consumer. The event-name options still fire their
events. A keybind's commands and mapping belong to the consumer.

**The cache mirror.** cis_libs stays the single producer of player state: one
native pass per client. It pushes each change as the local client event
`cis_libs:cache`; a consumer's mirror takes one `GetCacheSnapshot` on its first
read and applies the pushes, accepting them only from cis_libs. After that,
`Cis.player.vehicle()` and the other mirrored reads cost no export call.
`Cis.player.coords()` stays a native read memoised per frame.

**Restarts.** A consumer's zones, points, keybinds and markers live in the
consumer, so a cis_libs restart does not remove them; the mirror takes a new
snapshot when cis_libs starts again, and while it is down reads fall back to
the natives for the ids and retry the snapshot at most once a second. When the
consumer itself stops, its VM goes with everything in it and FiveM drops its
commands; scaleform movies and DUI pages it still holds are released on its
`onResourceStop`. A key mapping stays in the player's settings by design.

## 6. Public surface

Generated from `api.lua`. Do not edit between the markers.

<!-- generated:begin -->

| Export | Realm | Signature | Returns | Since | Notes |
|---|---|---|---|---|---|
| `AddDoorGroup` | both | `server (groupData); client (data)` | server boolean, string; client boolean | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge doors API |
| `AddDoorToSystem` | both | `server (newDoorData, internal); client (data)` | server boolean, string; client boolean | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge doors API |
| `AddRadialItem` | client | `(data)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:AddRadialItem(data) |
| `AddSyncDespawnHandler` | client | `(fn)` | boolean, string | 1.0.0 | Cis.sync.onDespawn(fn) unstable |
| `AddSyncSpawnHandler` | client | `(fn)` | boolean, string | 1.0.0 | Cis.sync.onSpawn(fn) unstable |
| `AlertDialog` | client | `(data)` | string\|nil, string\|nil | 1.1.0 | exports.cis_libs:AlertDialog(data) |
| `AnimDict` | client | `(name, timeout?)` | string\|nil, string\|nil | 1.0.0 | Cis.streaming.animDict(name, timeout) |
| `AnimSet` | client | `(name, timeout?)` | string\|nil, string\|nil | 1.0.0 | Cis.streaming.animSet(name, timeout) |
| `AudioBank` | client | `(name, timeout?)` | string\|nil, string\|nil | 1.0.0 | Cis.streaming.audioBank(name, timeout) |
| `AutoLogError` | both | `server (err, event); client (err, context?)` | nil | 1.0.0 | Cis.log.error(message) from inside a pcall |
| `AwaitCallback` | both | `(name, ...)` | any | 1.0.0 | Cis.callback.await(name, ...) |
| `AwaitCallbackClient` | server | `(name, target, ...)` | boolean, any | 1.0.0 | Cis.callback.awaitClient(src, name, ...) |
| `BreakDoor` | server | `(identifier)` | any, string\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge doors API |
| `CallCallback` | both | `(name, cb?, ...)` | nil | 1.0.0 | Cis.callback.call(name, cb, ...) |
| `CallCallbackClient` | server | `(name, target, cb?, ...)` | string | 1.0.0 | Cis.callback.callClient(src, name, cb, ...) |
| `CancelProgress` | client | `()` | boolean | 1.1.0 | exports.cis_libs:CancelProgress() |
| `CancelSkillCheck` | client | `()` | boolean | 1.1.0 | exports.cis_libs:CancelSkillCheck() |
| `ClearRadialItems` | client | `()` | boolean | 1.1.0 | exports.cis_libs:ClearRadialItems() |
| `CloseAlertDialog` | client | `()` | boolean | 1.1.0 | exports.cis_libs:CloseAlertDialog() |
| `CloseInputDialog` | client | `()` | boolean | 1.1.0 | exports.cis_libs:CloseInputDialog() |
| `ClosestObject` | client | `(coords, maxDistance, filter, opts)` | integer\|false, vector3\|string\|nil | 1.0.0 | Cis.world.getClosestObject(coords, maxDistance, filter, opts) |
| `ClosestPed` | client | `(coords, maxDistance, filter, opts)` | integer\|false, vector3\|string\|nil | 1.0.0 | Cis.world.getClosestPed(coords, maxDistance, filter, opts) |
| `ClosestPlayer` | client | `(coords, maxDistance, filter, opts)` | integer\|false, vector3\|string\|nil, integer\|nil | 1.0.0 | Cis.world.getClosestPlayer(coords, maxDistance, filter, opts) |
| `ClosestVehicle` | client | `(coords, maxDistance, filter, opts)` | integer\|false, vector3\|string\|nil | 1.0.0 | Cis.world.getClosestVehicle(coords, maxDistance, filter, opts) |
| `CommandAdd` | server | `(name, options, handler)` | boolean, string\|nil | 1.0.0 | Cis.command.add(name, { params, restricted, help }, handler) |
| `CommandList` | server | `()` | table[] | 1.0.0 | Cis.command.list() |
| `CommandParse` | server | `(raw)` | string[] | 1.0.0 | no proxy equivalent; the argument splitter used by CommandAdd |
| `CommandRemove` | server | `(name)` | boolean, string\|nil | 1.0.0 | Cis.command.remove(name) |
| `CreatePed` | client | `(model, coords, heading?, options?)` | integer | 1.0.0 | no proxy equivalent; returns 0 on an invalid or unloaded model. The Lua global is CisCreatePed -- the CreatePed native keeps its own name |
| `CreatePoint` | client | `(data)` | integer\|false, string\|nil | 1.0.0 | Cis.points.add({ coords, distance, onEnter, onExit, nearby }) |
| `CreateTarget` | client | `(zoneType, name, coords, size, options?)` | boolean, string | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge target API |
| `CreateZone` | client | `(kind, name, a, b, options?)` | boolean, string | 1.0.0 | Cis.zones.box / Cis.zones.poly / Cis.zones.sphere |
| `DbInsert` | server | `(sql, params?)` | integer\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the oxmysql API (MySQL.insert.await), served by oxmysql or cis_database |
| `DbQuery` | server | `(sql, params?)` | table\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the oxmysql API (MySQL.query.await), served by oxmysql or cis_database |
| `DbScalar` | server | `(sql, params?)` | any | 1.0.0 | **deprecated** deprecated since 1.1.0; use the oxmysql API (MySQL.scalar.await), served by oxmysql or cis_database |
| `DbSingle` | server | `(sql, params?)` | table\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the oxmysql API (MySQL.single.await), served by oxmysql or cis_database |
| `DbTransaction` | server | `(queries)` | boolean, string | 1.0.0 | **deprecated** deprecated since 1.1.0; use the oxmysql API (MySQL.transaction.await), served by oxmysql or cis_database |
| `DbUpdate` | server | `(sql, params?)` | integer\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the oxmysql API (MySQL.update.await), served by oxmysql or cis_database |
| `DebugLog` | client | `(message)` | nil | 1.0.0 | Cis.log.debug(message) |
| `DetectDatabase` | both | `(configured?)` | CisDetection | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge detection |
| `DetectFramework` | both | `(configured?, custom?)` | CisDetection | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge detection |
| `DisableRadial` | client | `(state)` | boolean | 1.1.0 | exports.cis_libs:DisableRadial(state) |
| `DrawText3D` | client | `(x, y, z, text, settings?)` | nil | 1.0.0 | no proxy equivalent |
| `FixDoor` | server | `(identifier)` | any, string\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge doors API |
| `FollowCacheHeading` | client | `()` | boolean | 1.1.0 | Cis.player.on("heading", fn) -- init.lua calls it for the first heading listener |
| `GetAllDoorData` | server | `()` | table\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge doors API |
| `GetAllPoints` | client | `()` | integer[] | 1.1.0 | Cis.points.getAll() |
| `GetAllZones` | client | `()` | string[] | 1.1.0 | Cis.zones.getAll() |
| `GetAuditLog` | server | `(limit?)` | CisAuditEntry[]\|boolean, string | 1.0.0 | The capability and configuration change log, newest last. Gated on Security.AuthorizedResources like every other mutating call. Entries carry resource and slot names and never a player name, identifier or IP. Bounded by Config.AuditLines, default 500 |
| `GetCacheSnapshot` | client | `()` | CisCacheSnapshot | 1.1.0 | Cis.player.* and Cis.cache(key) -- init.lua takes this once per consumer |
| `GetCachedHeading` | client | `()` | number | 1.0.0 | Cis.player.heading(), which reads the native directly in a consumer VM |
| `GetCachedPed` | client | `()` | integer | 1.0.0 | Cis.player.ped(), which reads the native directly in a consumer VM |
| `GetCachedPlayerId` | client | `()` | integer | 1.0.0 | Cis.player.playerId() |
| `GetCachedSeat` | client | `()` | integer\|nil | 1.0.0 | Cis.player.seat() |
| `GetCachedServerId` | client | `()` | integer | 1.0.0 | Cis.player.serverId() |
| `GetCachedVehicle` | client | `()` | integer\|nil, integer\|nil | 1.0.0 | Cis.player.vehicle() |
| `GetCachedWeapon` | client | `()` | CisWeaponData\|nil | 1.0.0 | Cis.player.weapon() |
| `GetCapabilities` | both | `()` | table<string, table> | 1.0.0 | The one call that answers "which of my four resources is actually running". Returns { [slot] = { owner, resolved } } |
| `GetClientConfig` | client | `()` | table\|nil | 1.0.0 | no proxy equivalent; the config the server sent to this client |
| `GetClientLogging` | client | `()` | table | 1.0.0 | Cis.log.debug / info / warn / error |
| `GetClosestDoor` | client | `()` | table\|nil, string\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge doors API |
| `GetClosestPoint` | client | `()` | integer\|nil, number\|string\|nil | 1.0.0 | Cis.points.getClosest() |
| `GetClosestVehicle` | client | `()` | integer | 1.0.0 | no proxy equivalent; a 5 unit forward ray, then the nearest vehicle in the CVehicle pool within 5 units. The Lua global is CisGetClosestVehicle; the native GetClosestVehicle is left alone |
| `GetConfigSummary` | server | `()` | table | 1.0.0 | no proxy equivalent; the non-secret half of the server config |
| `GetCurrentWeaponData` | client | `(ped?)` | CisWeaponData | 1.0.0 | Cis.player.weapon() |
| `GetCurrentZones` | client | `()` | string[] | 1.1.0 | Cis.zones.getCurrent() |
| `GetDiagnostics` | both | `(opts?)` | CisDiagnostics | 1.0.0 | Counts, never player data: capability slots and owners, sync records by owner, pending callbacks, net handlers, error and warning counters, memory, uptime, and pass timings. The harness diffs counters and probes only; timings are a sibling so a pass does not fail every case |
| `GetDiscordConfig` | server | `()` | table | 1.0.0 | The outbound/webhook configuration SetConfig was handed, for the capability that does the sending. Server realm only -- it holds webhook URLs and is deliberately not on the client payload whitelist |
| `GetDiscordQueueDepth` | server | `()` | integer | 1.0.0 | no proxy equivalent; queued message count and dropped count |
| `GetDistanceBetweenCoords` | client | `(x1, y1, z1, x2, y2, z2, useZ?)` | number | 1.0.0 | no proxy equivalent |
| `GetDoorState` | both | `(doorId)` | boolean\|nil, string\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge doors API |
| `GetKnownTargets` | both | `()` | table | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge detection |
| `GetLastRefusal` | server | `()` | string\|nil | 1.0.0 | Read after a nil/false answer from a capability export to learn WHY it was refused. Returns a sentence naming the missing or failing capability, or nil when the last call succeeded. Additive: no existing return shape changes |
| `GetLibsPrefix` | server | `()` | string | 1.0.0 | no proxy equivalent; the configured Security.EventPrefix |
| `GetLogging` | server | `()` | table | 1.0.0 | Cis.log.debug / info / warn / error |
| `GetNearbyPoints` | client | `()` | integer[] | 1.1.0 | Cis.points.getNearby() |
| `GetNearbyZones` | client | `(coords?, radius?)` | string[] | 1.1.0 | Cis.zones.getNearby(coords, radius) |
| `GetNormalizedPlayer` | server | `(src)` | table\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge player API |
| `GetOnlineJobCount` | server | `(jobs)` | integer | 1.0.0 | no proxy equivalent; the callback cis_libs:getOnlineJobCount |
| `GetOpenContextMenu` | client | `()` | string\|nil | 1.1.0 | exports.cis_libs:GetOpenContextMenu() |
| `GetOpenMenu` | client | `()` | string\|nil | 1.1.0 | exports.cis_libs:GetOpenMenu() |
| `GetPlayerVehicleSeat` | client | `()` | integer\|nil | 1.0.0 | Cis.player.vehicle(), second return value |
| `GetPointsDebug` | client | `()` | CisPointsDebug | 1.0.0 | no proxy equivalent; the live debug record for the point pass |
| `GetSelfCheck` | server | `()` | CisSelfCheck | 1.0.0 | The boot self-check as data: { ok, problems = { { code, message, fix } } }. Each problem names the change that resolves it |
| `GetSyncedEntities` | client | `()` | table<string, integer | 1.0.0 | no proxy equivalent; the id-to-handle table of everything this client spawned |
| `GetSyncedEntity` | client | `(key)` | integer\|nil | 1.0.0 | Cis.sync.entity(key) |
| `GetTableSize` | client | `(t)` | integer | 1.0.0 | no proxy equivalent |
| `GetVehicleProperties` | client | `(vehicle)` | CisVehicleProps\|nil | 1.0.0 | Cis.vehicle.getProperties(vehicle) -- the same engine, in the caller VM |
| `GetZoneDebug` | client | `()` | CisZoneDebug | 1.0.0 | no proxy equivalent; the last grid pass cost in milliseconds |
| `HideContext` | client | `(onExit?)` | boolean | 1.1.0 | exports.cis_libs:HideContext(onExit) |
| `HideMenu` | client | `(onExit?)` | boolean | 1.1.0 | exports.cis_libs:HideMenu(onExit) |
| `HideRadial` | client | `()` | boolean | 1.1.0 | exports.cis_libs:HideRadial() |
| `HideTextUI` | client | `()` | boolean | 1.1.0 | exports.cis_libs:HideTextUI() |
| `HookOn` | both | `(name, fn, opts?)` | integer\|false, string\|nil | 1.0.0 | Cis.hooks.on(name, fn, opts) |
| `HookRemove` | both | `(id)` | boolean, string\|nil | 1.0.0 | Cis.hooks.remove(id) |
| `HookRun` | both | `(name, payload?)` | boolean, string\|nil, string\|nil | 1.0.0 | Cis.hooks.run(name, payload) |
| `InputDialog` | client | `(heading, rows, options?)` | table\|nil, string\|nil | 1.1.0 | exports.cis_libs:InputDialog(heading, rows, options) |
| `InventoryAdd` | server | `(src, item, amount, metadata?)` | boolean | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge inventory API |
| `InventoryCount` | both | `server (src, item); client (item)` | integer | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge inventory API |
| `InventoryHas` | both | `server (src, item, amount); client (item, amount)` | boolean | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge inventory API |
| `InventoryRemove` | server | `(src, item, amount)` | boolean | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge inventory API |
| `InvokingAllowed` | server | `()` | boolean | 1.0.0 | no proxy equivalent; ask before mutating. This is the supported way to avoid a refusal |
| `IsReady` | client | `()` | boolean | 1.0.0 | Cis.isReady, or Cis.ready(cb) |
| `IsTextUIOpen` | client | `()` | boolean, string\|nil | 1.1.0 | exports.cis_libs:IsTextUIOpen() |
| `KeybindAdd` | client | `(options)` | table\|false, string\|nil | 1.0.0 | Cis.keybind.add({ name, description, defaultKey, onPress, onRelease }) |
| `KeybindDisable` | client | `(id, state)` | boolean, string\|nil | 1.0.0 | no proxy equivalent; the id-based form of handle:disable(state) |
| `KeybindEnable` | client | `(id)` | boolean, string\|nil | 1.0.0 | no proxy equivalent; KeybindDisable(id, false) |
| `KeybindIsPressed` | client | `(id)` | boolean | 1.0.0 | no proxy equivalent; the id-based form of handle:isPressed() |
| `KeybindRemove` | client | `(id)` | boolean, string\|nil | 1.0.0 | no proxy equivalent; the id-based form of handle:destroy() |
| `Keybinds` | client | `()` | table[] | 1.0.0 | no proxy equivalent; every binding this library registered |
| `LockDoors` | server | `(identifier)` | integer, string\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge doors API |
| `LogDebug` | both | `server (message, discordType?); client (message)` | nil | 1.0.0 | Cis.log.debug(message) |
| `LogError` | both | `server (message, discordType?, errorInfo?); client (message)` | nil | 1.0.0 | Cis.log.error(message) |
| `LogInfo` | both | `server (message, discordType?); client (message)` | nil | 1.0.0 | Cis.log.info(message) |
| `LogWarn` | both | `server (message, discordType?); client (message)` | nil | 1.0.0 | Cis.log.warn(message) |
| `ModuleInfo` | both | `(name, opts?)` | CisModuleInfo | 1.0.0 | Cis.moduleInfo(name, opts) |
| `NearbyObjects` | client | `(coords, maxDistance, filter, opts)` | CisWorldEntry[]\|false, string | 1.0.0 | Cis.world.getNearbyObjects(coords, maxDistance, filter, opts) |
| `NearbyPeds` | client | `(coords, maxDistance, filter, opts)` | CisWorldEntry[]\|false, string | 1.0.0 | Cis.world.getNearbyPeds(coords, maxDistance, filter, opts) |
| `NearbyPlayers` | client | `(coords, maxDistance, filter, opts)` | CisWorldEntry[]\|false, string | 1.0.0 | Cis.world.getNearbyPlayers(coords, maxDistance, filter, opts) |
| `NearbyVehicles` | client | `(coords, maxDistance, filter, opts)` | CisWorldEntry[]\|false, string | 1.0.0 | Cis.world.getNearbyVehicles(coords, maxDistance, filter, opts) |
| `Notify` | both | `server (src, message, kind?); client (message, kind?)` | server boolean, string; client any, string\|nil | 1.0.0 | Cis.framework.notify(...). With a framework provider registered the call passes through to it untouched; with none, cis_libs delivers it itself through the same guards NotifyClient uses, so a server with no framework does not go mute and does not become the unbounded path. The two-argument client form sends `kind` in the message slot; this is pinned as a known defect in test/contracts.lua and is a MAJOR change to correct |
| `NotifyClient` | server | `(src, message, kind?)` | boolean, string | 1.0.0 | Called by a product to show a notification to one client, without hardcoding the event name owned by this library. Answers `false, reason` for a src that is not a connected player, truncates a message past 512 characters, and allows 10 a second per (src, calling resource) |
| `NotifyPlayer` | server | `(src, data)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:NotifyPlayer(src, data) |
| `OnPlayerCache` | client | `(key, cb)` | function\|nil, integer\|string | 1.0.0 | Cis.player.on(key, cb); stop it with RemovePlayerCacheListener(id) |
| `ProgressActive` | client | `()` | boolean | 1.1.0 | exports.cis_libs:ProgressActive() |
| `ProgressBar` | client | `(data)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:ProgressBar(data) |
| `ProgressCircle` | client | `(data)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:ProgressCircle(data) |
| `Ptfx` | client | `(name, timeout?)` | string\|nil, string\|nil | 1.0.0 | Cis.streaming.ptfx(name, timeout) |
| `PublishInventory` | server | `(src)` | boolean, string\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge inventory API |
| `PublishJobUpdate` | server | `(job, src?)` | boolean, string | 1.0.0 | Called by cis_core or any bridge target when a player changes job. Fires cis_libs:jobUpdated, so the event name stays owned by this library |
| `PublishPlayerLoaded` | server | `(job, src?)` | boolean, string\|nil | 1.0.0 | Called by cis_core or any bridge target when a player object exists. Fires cis_libs:playerLoaded |
| `RandomFloat` | client | `(lower, greater)` | number | 1.0.0 | no proxy equivalent |
| `RateOk` | server | `(src, name, windowMs?, maxHits?)` | boolean | 1.0.0 | no proxy equivalent; a resource may share the library rate limiter |
| `RaycastCamera` | client | `(flags, ignore, distance?, timeoutMs?)` | boolean\|nil, integer\|nil, vector3\|nil, vector3\|nil, integer\|nil | 1.0.0 | Cis.raycast.camera(flags, ignore, distance, timeoutMs) |
| `RaycastFromCoords` | client | `(origin, target, flags?, ignore?, timeoutMs?)` | boolean\|nil, integer\|nil, vector3\|nil, vector3\|nil, integer\|nil | 1.0.0 | Cis.raycast.fromCoords(origin, target, flags, ignore, timeoutMs) |
| `ReadyState` | both | `()` | boolean, boolean, string\|nil | 1.0.0 | Cis.isReady and Cis.isFailed, which read through to this in a consumer |
| `RegisterCallback` | both | `server (name, handler, opts?); client (name, fn)` | boolean, string\|nil | 1.0.0 | Cis.callback.register(name, handler) |
| `RegisterCapability` | both | `(slot, provider, contract?)` | server boolean, string; client boolean, string\|nil | 1.0.0 | Called by cis_core, cis_bridge and cis_keys with (slot, "resource:Export"). Gated on Security.AuthorizedResources on both realms; among allowed callers the first registration wins |
| `RegisterContext` | client | `(context)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:RegisterContext(context) |
| `RegisterMenu` | client | `(data, cb?)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:RegisterMenu(data, cb) |
| `RegisterRadial` | client | `(radial)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:RegisterRadial(radial) |
| `RemoveNearWatcher` | client | `(id)` | boolean, string | 1.0.0 | Cis.player.nearStop(id); the id WatchNear returns as its second value |
| `RemovePlayerCacheListener` | client | `(id)` | boolean, string\|nil | 1.0.0 | no proxy equivalent; the id OnPlayerCache returns as its second value |
| `RemovePoint` | client | `(id)` | boolean, string\|nil | 1.0.0 | Cis.points.remove(id) |
| `RemoveRadialItem` | client | `(id)` | boolean | 1.1.0 | exports.cis_libs:RemoveRadialItem(id) |
| `RemoveStatebagHandler` | both | `(cookie)` | boolean, string\|nil | 1.0.0 | Cis.statebag.remove(cookie) |
| `RemoveTarget` | client | `(name, isPed?)` | boolean, string | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge target API |
| `RemoveZone` | client | `(name)` | boolean, string\|nil | 1.0.0 | Cis.zones.remove(name) |
| `RequestInventorySync` | client | `()` | boolean | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge inventory API |
| `RequestLockDoors` | client | `(identifier)` | any, string\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge doors API |
| `RequestModelTimeout` | client | `(model, timeout?)` | boolean, integer | 1.0.0 | Cis.streaming.model(model, timeout) |
| `RequestUnlockDoors` | client | `(identifier)` | any, string\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge doors API |
| `Round` | client | `(num, numDecimalPlaces?)` | number | 1.0.0 | no proxy equivalent; math round to n places |
| `Scaleform` | client | `(name, timeout?)` | string\|nil, integer\|nil, string\|nil | 1.0.0 | Cis.streaming.scaleform(name, timeout) |
| `SecureNetOn` | server | `(name, fn, opts?)` | boolean | 1.0.0 | Cis.net.on(name, fn, opts) -> true when the event was bound |
| `SecurityReport` | server | `(src, reason)` | boolean | 1.0.0 | Cis.security.report(src, reason) |
| `SendDiscordLog` | server | `(webhookURL, title, message, color, ping)` | any | 1.0.0 | Cis.log.info with a discordType; no proxy equivalent for a raw webhook push |
| `ServerZoneBox` | server | `(center, size, opts?)` | integer\|false, string\|nil | 1.0.0 | Cis.zones.server.box(center, size, opts) |
| `ServerZoneContains` | server | `(id, coords)` | boolean, string\|nil | 1.0.0 | Cis.zones.server.contains(id, coords) |
| `ServerZonePlayers` | server | `(id)` | integer[]\|false, string\|nil | 1.0.0 | Cis.zones.server.players(id) |
| `ServerZonePoly` | server | `(points, opts?)` | integer\|false, string\|nil | 1.0.0 | Cis.zones.server.poly(points, opts) |
| `ServerZoneRemove` | server | `(id)` | boolean, string\|nil | 1.0.0 | Cis.zones.server.remove(id) |
| `ServerZoneSphere` | server | `(center, radius, opts?)` | integer\|false, string\|nil | 1.0.0 | Cis.zones.server.sphere(center, radius, opts) |
| `SetConfig` | server | `(config?, security?, discord?)` | boolean, string | 1.0.0 | Called by cis_core at boot with (config, security, discord). First registration wins; a second is refused and named. When the server convar cis_config_supplier names a resource, only that resource may call it. When cis_authorized_resources or cis_allow_any_resource is set, the security posture comes from the convars and the AuthorizedResources / AllowAnyResource passed here are ignored (DOCUMENTATION.md section 3). `security.AllowAnyResource` is the 1.0.0 opt-in escape hatch: with it true an EMPTY AuthorizedResources stops meaning restrictive, and the console warns on every boot |
| `SetDropPlayerHandler` | server | `(provider)` | boolean, string | 1.0.0 | Called by whoever ships the config, with "resource:Export". A FUNCTION cannot be sent across the boundary, which is why this exists |
| `SetMenuOptions` | client | `(id, options, index?)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:SetMenuOptions(id, options, index) |
| `SetUiLocale` | client | `(strings)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:SetUiLocale(strings) |
| `SetUiTheme` | client | `(data)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:SetUiTheme(data) |
| `SetVehicleProperties` | client | `(vehicle, props, fixVehicle?)` | boolean, string\|nil | 1.0.0 | no proxy equivalent; applies every field present, every time (there is no diff) |
| `ShowContext` | client | `(id)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:ShowContext(id) |
| `ShowMenu` | client | `(id, startIndex?)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:ShowMenu(id, startIndex) |
| `ShowTextUI` | client | `(text, options?)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:ShowTextUI(text, options) |
| `SkillCheck` | client | `(difficulty, inputs?)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:SkillCheck(difficulty, inputs) |
| `SkillCheckActive` | client | `()` | boolean | 1.1.0 | exports.cis_libs:SkillCheckActive() |
| `StatebagOnEntity` | both | `(key, handler, timeoutMs?)` | integer\|nil, string\|nil | 1.0.0 | Cis.statebag.onEntity(key, handler, timeoutMs) |
| `StatebagOnPlayer` | both | `(key, handler, timeoutMs?)` | integer\|nil, string\|nil | 1.0.0 | Cis.statebag.onPlayer(key, handler, timeoutMs) |
| `SyncClear` | server | `()` | integer\|nil, string\|nil | 1.0.0 | Cis.sync.clear() |
| `SyncCreate` | server | `(kind, data)` | string\|nil, string\|nil | 1.0.0 | Cis.sync.ped / Cis.sync.prop / Cis.sync.vehicle |
| `SyncList` | server | `()` | CisSyncSummary[], string\|nil | 1.0.0 | Cis.sync.list() |
| `SyncRemove` | server | `(id?)` | boolean, string | 1.0.0 | Cis.sync.remove(id) |
| `TargetAvailable` | client | `()` | boolean | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge target API |
| `TargetExists` | client | `(name)` | boolean | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge target API |
| `TextureDict` | client | `(name, timeout?)` | string\|nil, string\|nil | 1.0.0 | Cis.streaming.textureDict(name, timeout) |
| `Toast` | client | `(data)` | boolean, string\|nil | 1.1.0 | exports.cis_libs:Toast(data). The library's own NUI notification; Cis.ui.notify routes here when no ui provider is registered. Not Notify: that export is the framework notify, a different signature |
| `TriggerLibCallback` | client | `(name, cb?, ...)` | nil | 1.0.0 | the client-to-server round trip whose callback receives only the results |
| `TryAwaitCallback` | both | `(name, ...)` | boolean, any | 1.0.0 | Cis.callback.tryAwait(name, ...) -> ok, ... on success; false, reason on a refusal |
| `TryAwaitCallbackWithin` | client | `(name, timeoutMs, ...)` | boolean, any | 1.1.0 | Cis.callback.tryAwaitWithin(name, timeoutMs, ...) -> ok, ... ; a per-call timeout instead of Config.CallbackTimeout |
| `UiConfirm` | client | `(opts)` | any, string\|nil | 1.0.0 | Cis.ui.confirm(opts). A ui provider if registered, else the built-in AlertDialog. RETURNS, does not take a callback |
| `UiInput` | client | `(opts)` | any, string\|nil | 1.0.0 | Cis.ui.input(opts). A ui provider if registered, else the built-in InputDialog. RETURNS, does not take a callback |
| `UiNotify` | client | `(message, kind?)` | boolean, string\|nil | 1.0.0 | Cis.ui.notify(message, kind). NOT Cis.framework.notify: that one is player-targeted, rate-limited, and the one a server uses. This is the local toast |
| `UiProgress` | client | `(opts)` | boolean\|nil, string\|nil | 1.0.0 | Cis.ui.progress(opts). A ui provider if registered, else the built-in ProgressBar/ProgressCircle (opts.type = 'circle') |
| `UiTextUIHide` | client | `()` | boolean, string\|nil | 1.0.0 | Cis.ui.textUI.hide() |
| `UiTextUIIsOpen` | client | `()` | boolean | 1.0.0 | Cis.ui.textUI.isOpen() |
| `UiTextUIShow` | client | `(text, opts?)` | boolean, string\|nil | 1.0.0 | Cis.ui.textUI.show(text, opts) |
| `UnlockDoors` | server | `(identifier)` | integer, string\|nil | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge doors API |
| `UnregisterCapability` | server | `(slot)` | boolean | 1.0.0 | Called by a product on shutdown or handover. Only the slot owner may release it |
| `UpdateTarget` | client | `(name, newOptions?)` | boolean, string | 1.0.0 | **deprecated** deprecated since 1.1.0; use the cis_bridge target API |
| `WaitCapability` | server | `(slot, timeoutMs?)` | boolean, string | 1.0.0 | Waits up to timeoutMs for a capability slot to be filled. Returns true and the owner, or nil and a reason naming the slot. No proxy equivalent -- a consumer waits from its own resource. |
| `WaitReady` | both | `(timeout?)` | boolean | 1.0.0 | Cis.ready(cb, timeout) or Cis.wait(timeout) |
| `WatchNear` | client | `(coords, distance?, onEnter?, onExit?, onEnterEvent?, onExitEvent?)` | function, integer | 1.0.0 | Cis.player.near(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent) |
| `WeaponAsset` | client | `(name, timeout?)` | integer\|nil, string\|nil | 1.0.0 | Cis.streaming.weaponAsset(hash, timeout) |
| `ZoneContains` | client | `(name, point?)` | boolean | 1.0.0 | Cis.zones.contains(name, point) |

| Event | Since | Payload | Notes |
|---|---|---|---|
| `chat:addSuggestion` | 1.0.0 | server to client, (name, help, params) while the chat resource is started. The one new standard-resource integration allowed, used only by Cis.command.add. Sent to -1 on add and when chat starts, and to each player as they join |  |
| `chat:removeSuggestion` | 1.0.0 | server to client, (name) while the chat resource is started: the same seam, taking a suggestion back when its command is removed or its resource stops |  |
| `cis_libs:cache` | 1.1.0 | client, local: (key, value, seat, silent) -- seat rides on a vehicle push; silent marks a refresh with no change to announce |  |
| `cis_libs:capabilityChanged` | 1.0.0 | both realms: ({ slot, action, owner, previousOwner, resolved }) |  |
| `cis_libs:cb` | 1.0.0 | client to server and server to client: (name, key, ...). `key` is the caller's opaque pending token, echoed back unchanged. The client handler ignores a local TriggerEvent (`source` is empty): only the server can ask a client callback. |  |
| `cis_libs:cb:res` | 1.0.0 | client: (key, ok, ...) resolving an outstanding callback. Only a reply from the server counts; a local TriggerEvent (`source` is empty) is ignored. |  |
| `cis_libs:cb:serverRes` | 1.0.0 | server: (key, ok, ...) resolving an outstanding client callback |  |
| `cis_libs:client:getData` | 1.0.0 | server to client: ({ Config, EventPrefix, Providers }) on join, and to every client after SetConfig. Providers is "any" or the CisConfigUtil.digest of each Security.AuthorizedResources name (never the names), and gates client RegisterCapability. A local TriggerEvent is ignored. DoorData was not shipped in 1.0.0 |  |
| `cis_libs:client:inventory` | 1.0.0 | server to client: ({ [itemName] = count }), pushed by PublishInventory | **deprecated** deprecated since 1.1.0; use the cis_bridge inventory API |
| `cis_libs:client:showNotification` | 1.0.0 | server to client: (message, kind) |  |
| `cis_libs:client:syncBatch` | 1.0.0 | server to client: (n, upserts, removes). ONE event per player per pass, latent when it carries 32 entries or more. `n` numbers the batches sent to that player, and a client applies an entry only if no later batch has touched that key, so a reliable batch overtaking a latent one is safe. `upserts` are CLIENT-LOCAL records (identity `record.key`, the caller's id namespaced by its owning resource; `record.rev` is its revision); a networked record is never on this wire. `removes` are keys to despawn. The client applies a batch only from the server (a local TriggerEvent is ignored) and only when `n` is an integer in 1..2^31-1. |  |
| `cis_libs:client:uiNotify` | 1.1.0 | server to client: (data) a Notify table, sent by NotifyPlayer. Accepted only from the network: a local TriggerEvent of it is ignored |  |
| `cis_libs:jobUpdated` | 1.0.0 | server to client: ({ name, grade }), fired by PublishJobUpdate |  |
| `cis_libs:playerLoaded` | 1.0.0 | server to client: (job), fired by PublishPlayerLoaded |  |
| `cis_libs:server:getData` | 1.0.0 | client to server: no arguments, requests the config payload |  |
| `cis_libs:server:inventorySync` | 1.0.0 | client to server: no arguments, requests an inventory snapshot | **deprecated** deprecated since 1.1.0; use the cis_bridge inventory API |
| `cis_libs:server:syncGaveUp` | 1.0.0 | client to server: (key) the client could not load that record's model after its retries. The server stops believing the client holds it and holds back that revision for 30 s. |  |
| `cis_libs:server:syncSnapshot` | 1.0.0 | client to server: (held) sent when the client's sync scripts load, `held` being { [key] = rev } of what it still holds (nothing, on a fresh start). The server reconciles what it believed this player held against the claim, answers with one capped batch and lets the pass deliver the rest. Honoured once per 10 s per player. |  |

| `Cis.*` | Realm | Signature | Returns | Since | Notes |
|---|---|---|---|---|---|
| `Cis.anim.play` | client | `(ped, dict, clip, opts?)` | boolean, string\|nil | 1.1.0 |  |
| `Cis.cache` | client | `(key)` | any | 1.1.0 |  |
| `Cis.callback.await` | both | `(name, ...)` | any | 1.0.0 |  |
| `Cis.callback.awaitClient` | server | `(src, name, ...)` | boolean, any | 1.0.0 |  |
| `Cis.callback.awaitWithin` | client | `(name, timeoutMs, ...)` | any | 1.1.0 |  |
| `Cis.callback.call` | both | `(name, cb?, ...)` | nil | 1.0.0 |  |
| `Cis.callback.callClient` | server | `(src, name, cb?, ...)` | string | 1.0.0 |  |
| `Cis.callback.register` | both | `(name, handler, opts?)` | boolean, string\|nil | 1.0.0 |  |
| `Cis.callback.tryAwait` | both | `(name, ...)` | boolean, any | 1.0.0 |  |
| `Cis.callback.tryAwaitWithin` | client | `(name, timeoutMs, ...)` | boolean, any | 1.1.0 |  |
| `Cis.command.add` | server | `(name, options, handler)` | boolean, string\|nil | 1.0.0 |  |
| `Cis.command.list` | server | `()` | table[] | 1.0.0 |  |
| `Cis.command.remove` | server | `(name)` | boolean, string\|nil | 1.0.0 |  |
| `Cis.controls.disable` | client | `(...)` | integer\|false, string\|nil | 1.1.0 |  |
| `Cis.controls.enable` | client | `(id)` | boolean | 1.1.0 |  |
| `Cis.controls.isDisabled` | client | `(control)` | boolean | 1.1.0 |  |
| `Cis.db.insert` | server | `(sql, params?)` | integer\|nil | 1.0.0 | **deprecated** |
| `Cis.db.query` | server | `(sql, params?)` | table\|nil | 1.0.0 | **deprecated** |
| `Cis.db.scalar` | server | `(sql, params?)` | any | 1.0.0 | **deprecated** |
| `Cis.db.single` | server | `(sql, params?)` | table\|nil | 1.0.0 | **deprecated** |
| `Cis.db.transaction` | server | `(queries)` | boolean, string | 1.0.0 | **deprecated** |
| `Cis.db.update` | server | `(sql, params?)` | integer\|nil | 1.0.0 | **deprecated** |
| `Cis.doors.add` | both | `(data)` | boolean, string | 1.0.0 | **deprecated** |
| `Cis.doors.get` | both | `(id)` | boolean\|nil, string\|nil | 1.0.0 | **deprecated** |
| `Cis.doors.setState` | both | `(id, locked)` | boolean, string | 1.0.0 | **deprecated** |
| `Cis.dui.new` | client | `(opts)` | CisDuiPage\|nil, string\|nil | 1.1.0 |  |
| `Cis.framework.notify` | both | `server (srcOrNil, message, kind?); client (message, kind?)` | boolean, string | 1.0.0 |  |
| `Cis.framework.player` | server | `(src)` | table\|nil | 1.0.0 | **deprecated** |
| `Cis.hooks.on` | both | `(name, fn, opts?)` | integer\|false, string\|nil | 1.0.0 |  |
| `Cis.hooks.remove` | both | `(id)` | boolean, string\|nil | 1.0.0 |  |
| `Cis.hooks.run` | both | `(name, payload?)` | boolean, string\|nil, string\|nil | 1.0.0 |  |
| `Cis.inventory.add` | server | `(src, item, amount, metadata?)` | boolean | 1.0.0 | **deprecated** |
| `Cis.inventory.count` | both | `server (src, item); client (item)` | integer | 1.0.0 | **deprecated** |
| `Cis.inventory.has` | both | `server (src, item, amount?); client (item, amount?)` | boolean | 1.0.0 | **deprecated** |
| `Cis.inventory.remove` | server | `(src, item, amount)` | boolean | 1.0.0 | **deprecated** |
| `Cis.keybind.add` | client | `(options)` | table\|false, string\|nil | 1.0.0 |  |
| `Cis.log.debug` | both | `(message)` | nil | 1.0.0 |  |
| `Cis.log.error` | both | `(message)` | nil | 1.0.0 |  |
| `Cis.log.info` | both | `(message)` | nil | 1.0.0 |  |
| `Cis.log.warn` | both | `(message)` | nil | 1.0.0 |  |
| `Cis.marker.add` | client | `(opts)` | integer\|false, string\|nil | 1.1.0 |  |
| `Cis.marker.clear` | client | `()` | integer | 1.1.0 |  |
| `Cis.marker.remove` | client | `(id)` | boolean | 1.1.0 |  |
| `Cis.moduleInfo` | both | `(name, opts?)` | CisModuleInfo | 1.0.0 |  |
| `Cis.moduleProbe` | both | `()` | table | 1.0.0 |  |
| `Cis.net.on` | server | `(name, fn, opts?)` | boolean, string | 1.0.0 |  |
| `Cis.onCache` | client | `(key, fn)` | function\|nil, integer\|string | 1.1.0 |  |
| `Cis.player.coords` | client | `()` | vector3 | 1.0.0 |  |
| `Cis.player.heading` | client | `()` | number | 1.0.0 |  |
| `Cis.player.near` | client | `(coords, distance?, onEnter?, onExit?, onEnterEvent?, onExitEvent?)` | function, integer | 1.0.0 |  |
| `Cis.player.nearStop` | client | `(id)` | boolean, string | 1.1.0 |  |
| `Cis.player.on` | client | `(key, cb)` | function\|nil, integer\|string | 1.0.0 |  |
| `Cis.player.ped` | client | `()` | integer | 1.0.0 |  |
| `Cis.player.playerId` | client | `()` | integer | 1.0.0 |  |
| `Cis.player.seat` | client | `()` | integer\|nil | 1.0.0 |  |
| `Cis.player.serverId` | client | `()` | integer | 1.0.0 |  |
| `Cis.player.vehicle` | client | `()` | integer\|nil, integer\|nil | 1.0.0 |  |
| `Cis.player.weapon` | client | `()` | CisWeaponData\|nil | 1.0.0 |  |
| `Cis.points.add` | client | `(data)` | integer\|false, string\|nil | 1.0.0 |  |
| `Cis.points.getAll` | client | `()` | integer[] | 1.1.0 |  |
| `Cis.points.getClosest` | client | `()` | integer\|nil, number\|string\|nil | 1.0.0 |  |
| `Cis.points.getNearby` | client | `()` | integer[] | 1.1.0 |  |
| `Cis.points.remove` | client | `(id)` | boolean | 1.0.0 |  |
| `Cis.raycast.camera` | client | `(flags?, ignore?, distance?, timeoutMs?)` | boolean\|nil, integer\|nil, vector3\|nil, vector3\|nil, integer\|nil | 1.0.0 |  |
| `Cis.raycast.fromCoords` | client | `(origin, target, flags?, ignore?, timeoutMs?)` | boolean\|nil, integer\|nil, vector3\|nil, vector3\|nil, integer\|nil | 1.0.0 |  |
| `Cis.ready` | both | `(cb?, timeout?)` | boolean\|function | 1.0.0 |  |
| `Cis.require` | both | `(name)` | CisCurve\|CisHeap\|CisInterp\|CisLRU\|CisRandom\|CisRate\|CisRingBuffer\|CisSet\|CisSparse\|CisWindow\|CisArray\|CisClass\|CisCron\|CisId\|CisJson\|CisLocale\|CisMathX\|CisPrint\|CisSemver\|CisString\|CisTable\|CisTime\|CisTimer\|CisValidate\|any | 1.0.0 |  |
| `Cis.requireList` | both | `()` | string[] | 1.0.0 |  |
| `Cis.scaleform.new` | client | `(name, timeout?)` | CisScaleformMovie\|nil, string\|nil | 1.1.0 |  |
| `Cis.security.report` | server | `(src, reason)` | boolean | 1.0.0 |  |
| `Cis.statebag.onEntity` | both | `(key, handler, timeoutMs?)` | integer\|nil, string\|nil | 1.0.0 |  |
| `Cis.statebag.onPlayer` | both | `(key, handler, timeoutMs?)` | integer\|nil, string\|nil | 1.0.0 |  |
| `Cis.statebag.remove` | both | `(cookie)` | boolean, string\|nil | 1.0.0 |  |
| `Cis.streaming.animDict` | client | `(name, timeout?)` | string\|nil, string\|nil | 1.0.0 |  |
| `Cis.streaming.animSet` | client | `(name, timeout?)` | string\|nil, string\|nil | 1.0.0 |  |
| `Cis.streaming.audioBank` | client | `(name, timeout?)` | string\|nil, string\|nil | 1.0.0 |  |
| `Cis.streaming.model` | client | `(model, timeout?)` | boolean, integer | 1.0.0 |  |
| `Cis.streaming.ptfx` | client | `(name, timeout?)` | string\|nil, string\|nil | 1.0.0 |  |
| `Cis.streaming.release` | client | `(kind, asset)` | boolean | 1.1.0 |  |
| `Cis.streaming.scaleform` | client | `(name, timeout?)` | string\|nil, integer\|nil, string\|nil | 1.0.0 |  |
| `Cis.streaming.textureDict` | client | `(name, timeout?)` | string\|nil, string\|nil | 1.0.0 |  |
| `Cis.streaming.weaponAsset` | client | `(hash, timeout?)` | integer\|nil, string\|nil | 1.0.0 |  |
| `Cis.sync.clear` | both | `()` | integer\|false, string | 1.0.0 |  |
| `Cis.sync.entity` | both | `(key)` | integer\|nil | 1.0.0 |  |
| `Cis.sync.list` | both | `()` | CisSyncSummary[]\|false, string | 1.0.0 |  |
| `Cis.sync.onDespawn` | both | `(fn)` | boolean, string | 1.0.0 |  |
| `Cis.sync.onSpawn` | both | `(fn)` | boolean, string | 1.0.0 |  |
| `Cis.sync.ped` | both | `(data)` | string\|nil, string\|nil | 1.0.0 |  |
| `Cis.sync.prop` | both | `(data)` | string\|nil, string\|nil | 1.0.0 |  |
| `Cis.sync.remove` | both | `(id)` | boolean, string | 1.0.0 |  |
| `Cis.sync.vehicle` | both | `(data)` | string\|nil, string\|nil | 1.0.0 |  |
| `Cis.target.add` | client | `(zoneType, name, coords, size, options?)` | boolean, string | 1.0.0 | **deprecated** |
| `Cis.target.exists` | client | `(name)` | boolean | 1.0.0 | **deprecated** |
| `Cis.target.remove` | client | `(name, isPed?)` | boolean, string | 1.0.0 | **deprecated** |
| `Cis.target.update` | client | `(name, options?)` | boolean, string | 1.0.0 | **deprecated** |
| `Cis.ui.cancelProgress` | client | `()` | boolean | 1.1.0 |  |
| `Cis.ui.cancelSkillCheck` | client | `()` | boolean | 1.1.0 |  |
| `Cis.ui.closeAlert` | client | `()` | boolean | 1.1.0 |  |
| `Cis.ui.closeInput` | client | `()` | boolean | 1.1.0 |  |
| `Cis.ui.confirm` | client | `(opts)` | any, string\|nil | 1.0.0 |  |
| `Cis.ui.context.getOpen` | client | `()` | string\|nil | 1.1.0 |  |
| `Cis.ui.context.hide` | client | `(onExit?)` | boolean | 1.1.0 |  |
| `Cis.ui.context.register` | client | `(context)` | boolean, string\|nil | 1.1.0 |  |
| `Cis.ui.context.show` | client | `(id)` | boolean, string\|nil | 1.1.0 |  |
| `Cis.ui.input` | client | `(opts)` | any, string\|nil | 1.0.0 |  |
| `Cis.ui.menu.getOpen` | client | `()` | string\|nil | 1.1.0 |  |
| `Cis.ui.menu.hide` | client | `(onExit?)` | boolean | 1.1.0 |  |
| `Cis.ui.menu.register` | client | `(data, cb?)` | boolean, string\|nil | 1.1.0 |  |
| `Cis.ui.menu.setOptions` | client | `(id, options, index?)` | boolean, string\|nil | 1.1.0 |  |
| `Cis.ui.menu.show` | client | `(id, startIndex?)` | boolean, string\|nil | 1.1.0 |  |
| `Cis.ui.notify` | client | `(message, kind?)` | boolean, string\|nil | 1.0.0 |  |
| `Cis.ui.progress` | client | `(opts)` | boolean\|nil, string\|nil | 1.0.0 |  |
| `Cis.ui.progressActive` | client | `()` | boolean | 1.1.0 |  |
| `Cis.ui.radial.add` | client | `(data)` | boolean, string\|nil | 1.1.0 |  |
| `Cis.ui.radial.clear` | client | `()` | boolean | 1.1.0 |  |
| `Cis.ui.radial.disable` | client | `(state)` | boolean | 1.1.0 |  |
| `Cis.ui.radial.hide` | client | `()` | boolean | 1.1.0 |  |
| `Cis.ui.radial.register` | client | `(radial)` | boolean, string\|nil | 1.1.0 |  |
| `Cis.ui.radial.remove` | client | `(id)` | boolean | 1.1.0 |  |
| `Cis.ui.skillCheck` | client | `(difficulty, inputs?)` | boolean, string\|nil | 1.1.0 |  |
| `Cis.ui.skillCheckActive` | client | `()` | boolean | 1.1.0 |  |
| `Cis.ui.textUI.hide` | client | `()` | boolean, string\|nil | 1.0.0 |  |
| `Cis.ui.textUI.isOpen` | client | `()` | boolean | 1.0.0 |  |
| `Cis.ui.textUI.show` | client | `(text, opts?)` | boolean, string\|nil | 1.0.0 |  |
| `Cis.vehicle.getProperties` | client | `(vehicle)` | CisVehicleProps\|nil | 1.1.0 |  |
| `Cis.vehicle.setProperties` | client | `(vehicle, props, fixVehicle?)` | boolean, string\|nil | 1.1.0 |  |
| `Cis.wait` | both | `(timeout?)` | boolean | 1.0.0 |  |
| `Cis.waitFor` | both | `(fn, msg?, timeoutMs?)` | any, string\|nil | 1.0.0 |  |
| `Cis.world.getClosestObject` | client | `(coords?, maxDistance?, filter?, opts?)` | integer\|false, vector3\|string\|nil | 1.1.0 |  |
| `Cis.world.getClosestPed` | client | `(coords?, maxDistance?, filter?, opts?)` | integer\|false, vector3\|string\|nil | 1.1.0 |  |
| `Cis.world.getClosestPlayer` | client | `(coords?, maxDistance?, filter?, opts?)` | integer\|false, vector3\|string\|nil, integer\|nil | 1.1.0 |  |
| `Cis.world.getClosestPlayerId` | client | `(coords?, maxDistance?, includePlayer?)` | integer\|false, integer\|string\|nil, vector3\|nil | 1.1.0 |  |
| `Cis.world.getClosestVehicle` | client | `(coords?, maxDistance?, filter?, opts?)` | integer\|false, vector3\|string\|nil | 1.1.0 |  |
| `Cis.world.getNearbyObjects` | client | `(coords?, maxDistance?, filter?, opts?)` | CisWorldEntry[]\|false, string\|nil | 1.1.0 |  |
| `Cis.world.getNearbyPeds` | client | `(coords?, maxDistance?, filter?, opts?)` | CisWorldEntry[]\|false, string\|nil | 1.1.0 |  |
| `Cis.world.getNearbyPlayers` | client | `(coords?, maxDistance?, filter?, opts?)` | CisWorldEntry[]\|false, string\|nil | 1.1.0 |  |
| `Cis.world.getNearbyVehicles` | client | `(coords?, maxDistance?, filter?, opts?)` | CisWorldEntry[]\|false, string\|nil | 1.1.0 |  |
| `Cis.zones.box` | client | `(name, center, size, options?)` | boolean, string | 1.0.0 |  |
| `Cis.zones.contains` | client | `(name, point?)` | boolean | 1.0.0 |  |
| `Cis.zones.getAll` | client | `()` | string[] | 1.1.0 |  |
| `Cis.zones.getCurrent` | client | `()` | string[] | 1.1.0 |  |
| `Cis.zones.getNearby` | client | `(coords?, radius?)` | string[] | 1.1.0 |  |
| `Cis.zones.poly` | client | `(name, points, options?)` | boolean, string | 1.0.0 |  |
| `Cis.zones.remove` | client | `(name)` | boolean, string\|nil | 1.0.0 |  |
| `Cis.zones.server.box` | server | `(center, size, opts?)` | integer\|false, string\|nil | 1.0.0 |  |
| `Cis.zones.server.contains` | server | `(id, coords)` | boolean, string\|nil | 1.0.0 |  |
| `Cis.zones.server.players` | server | `(id)` | integer[]\|false, string\|nil | 1.0.0 |  |
| `Cis.zones.server.poly` | server | `(points, opts?)` | integer\|false, string\|nil | 1.0.0 |  |
| `Cis.zones.server.remove` | server | `(id)` | boolean, string\|nil | 1.0.0 |  |
| `Cis.zones.server.sphere` | server | `(center, radius, opts?)` | integer\|false, string\|nil | 1.0.0 |  |
| `Cis.zones.sphere` | client | `(name, center, radius?, options?)` | boolean, string | 1.0.0 |  |


<!-- generated:end -->

---

## 7. Net events this library owns

The generated event table is in §6. Doorlock names belong to `cis_keys`.
Framework event names belong to `cis_core`. `jobUpdated` and `playerLoaded` are
fired here when a product calls `PublishJobUpdate` / `PublishPlayerLoaded`.
The `getData` payload carries no `DoorData`.

---

## 8. Known defects, pinned not fixed

| Defect | Where | Why it is not fixed |
|---|---|---|
| `Cis.callback.await` returns at most 6 values across the wire | `server/callback.lua` | Widening it is a wire change. |
| Sync has no hysteresis | `server/sync.lua` | One radius for enter and leave. A second radius is a behaviour change. |

Client `Cis.framework.notify(message, kind)` sends the **message** in the
message slot. Pinned in `test/contracts.lua`. Do not “fix” the kind into that
slot.

---

## 9. Troubleshooting

| Symptom | First check |
|---|---|
| `nil index: 'exports'` | `ensure cis_libs` first, and `dependency 'cis_libs'` on the consumer |
| Every `Cis.*` call returns nil / `false, reason` | `cis_debug`. Look for `no provider installed` or empty `AuthorizedResources` |
| `SyncCreate` answers nil with no reason | Empty allow-list (restrictive). Add the resource, or see who `SetConfig` |
| Zones never fire | Through `init.lua` a handler is a plain function. Through the `CreateZone` export, pass a function (it becomes a funcref) or `onEnterEvent` |
| A zone of another resource is not found by `Cis.zones.contains` | Expected: through `init.lua` it tests the calling resource's own zones (§5.2) |
| A zone is at the wrong coordinates | Bracket-form export call — argument 1 was the exports table |
| `GetDiagnostics().memoryKb` climbs for 30 minutes then drops | You collected in the **caller** VM. Pass `{ collect = true }` |

---

## 10. Requirements and layout

- OneSync on. `/onesync` in the manifest.
- Server build 4500+. `/server:4500` in the manifest.
- `init.lua` is the only consumer include.

```
fxmanifest.lua
init.lua            the only file a consumer shared_scripts
api.lua             contract. not loaded at runtime
shared/             registry, defaults, detect, grid, algo/, util/
client/core/        engines run by cis_libs AND loaded into each consumer
client/  server/
types/              generated LuaLS stub
test/live/          live harness. not run by npm test
```

```
npm test
npm run test:all
```

Live harness: `test/LIVE.md`. Counts are not repeated here.

---

## Limitations

- The built-in NUI targets FiveM's CEF (Chromium 103). A ui provider replaces
  it per call; there is no way to replace one component and keep the rest.
- Empty `Security.AuthorizedResources` refuses mutating exports.
- A handler that crosses the exports boundary arrives as a funcref, and each
  call is another crossing. Zones, points and keybinds made through `init.lua`
  avoid that by running in the caller (§5.2); hooks and callbacks still cross.
- Networked entities are created and deleted on the server.
- This resource writes no files. Logs are console, the in-memory audit ring,
  and an optional discord capability.
- Live numbers (assertion counts, soak heap) belong in dated result JSON, not
  in this prose.
- A refusal whose first return is `nil` loses its reason at the exports
  boundary. Mutating APIs that can refuse should return `false, reason`.
  `SyncCreate` still returns bare `nil` on several refusals.

---

## Licence

Cisoko Community Source & Identity License 1.0. See `LICENSE.md`.

The resource folder must remain named `cis_libs`. You may modify the code and
run it on commercial servers. You may not rebrand it, claim authorship, or
disable the identity check.

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> ·
**Discord:** <https://discord.gg/cisoko> ·
**Issues:** <https://github.com/SpecialStos/cis_libs/issues>

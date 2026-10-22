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

```lua
dependency 'cis_libs'
shared_script '@cis_libs/init.lua'
```

`init.lua` is the only file a consumer may `shared_script`. Each Lua file is its
own chunk. `shared_script '@cis_libs/shared/registry.lua'` gives you a second
registry that nothing else can see.

Call with a colon:

```lua
exports['cis_libs']:GetCapabilities()
```

Calling `Export` through a string index on the exports table is the same idea
done wrong: that table becomes argument 1.

A Lua function cannot cross the FiveM exports boundary. Zone `onEnter`, callback
handlers, hook bodies, and command handlers that you pass *into* an export arrive
`nil`. Use an event name (`onEnterEvent`) or `'resource:Export'`.

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

`security` **replaces** `Security` outright. It is not merged.

```lua
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

The client payload is a whitelist. Webhook URLs, drop handlers, and
`AuthorizedResources` do not leave the server.

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
- **Zones / points / hooks:** event names, not functions. Server zones exist
  (`Cis.zones.server.*`) and do not draw.

### 5.1 Modules

Fifteen pure-Lua modules ship in `files {}` and load on demand through
`Cis.require(name)`: `curve`, `heap`, `interp`, `lru`, `random`, `rate`,
`sparse`, `window`, `id`, `json`, `semver`, `string`, `table`, `time`,
`validate`. Each loads into the **calling** resource's Lua state, once per
state, and installs no global. `Cis.require('unknown')` raises and lists the
valid names; `Cis.requireList()` returns them.

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

The reference below is generated from the `---@param`/`---@return`
annotations in each module's source by `npm run gen-types`, which also writes
the editor types; `npm run gen-types:check` fails when either is stale or a
module function is untyped.

<!-- generated:modules:begin -->

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
| `replaceTop` | `(h: table, value: any) → any` | Replace the minimum in place. |
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
| `put` | `(lru: table, key: any, value: any) → any` | Store a value and mark it most recently used. |
| `remove` | `(lru: table, key: any) → any` | Remove a key, whatever its position in the order. |
| `removeWhere` | `(lru: table, predicate: fun(key: any, value: any): boolean) → integer` | Remove every entry for which `predicate(key, value)` is true. |

#### `random` — `Cis.require('random')`

Source: `shared/algo/random.lua`.

| Function | Signature | Summary |
|---|---|---|
| `float` | `(min: number, max: number, rng?: table\|fun(): number) → number\|nil, string\|nil` | Float in [min, max). |
| `gaussian` | `(mean?: number, standardDeviation?: number, rng?: table\|fun(): number) → number` | Normally distributed value, mean 0 and standard deviation 1 unless told otherwise. |
| `integer` | `(lo: number, hi: number, rng?: table\|fun(): number) → integer\|nil, string\|nil` | Integer in [lo, hi] INCLUSIVE, uniformly. |
| `newGenerator` | `(seed?: number) → table` | A seeded, reproducible generator. |
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
| `clear` | `(w: table) → nil` | Empty the ring, keeping its allocated capacity. |
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

## 6. Public surface

Generated from `api.lua`. Do not edit between the markers.

<!-- generated:begin -->

| Export | Realm | Signature | Since | Notes |
|---|---|---|---|---|
| `AddDoorGroup` | both | `()` | 1.0.0 | no proxy equivalent; exports["cis_libs"]:AddDoorGroup(groupData) |
| `AddDoorToSystem` | both | `()` | 1.0.0 | Cis.doors.add(doorData) |
| `AddSyncDespawnHandler` | client | `(fn)` | 1.0.0 | Cis.sync.onDespawn(fn) unstable |
| `AddSyncSpawnHandler` | client | `(fn)` | 1.0.0 | Cis.sync.onSpawn(fn) unstable |
| `AnimDict` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.animDict(name, timeout) |
| `AnimSet` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.animSet(name, timeout) |
| `AudioBank` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.audioBank(name, timeout) |
| `AutoLogError` | both | `()` | 1.0.0 | Cis.log.error(message) from inside a pcall |
| `AwaitCallback` | both | `()` | 1.0.0 | Cis.callback.await(name, ...) |
| `AwaitCallbackClient` | server | `(name, target, ...)` | 1.0.0 | Cis.callback.awaitClient(src, name, ...) |
| `BreakDoor` | server | `(identifier)` | 1.0.0 | no proxy equivalent; exports["cis_libs"]:BreakDoor(identifier) |
| `CallCallback` | both | `()` | 1.0.0 | Cis.callback.call(name, cb, ...) |
| `CallCallbackClient` | server | `(name, target, cb?, ...)` | 1.0.0 | Cis.callback.callClient(src, name, cb, ...) |
| `ClosestObject` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.closestObject(coords, maxDistance, filter) |
| `ClosestPed` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.closestPed(coords, maxDistance, filter) |
| `ClosestPlayer` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.closestPlayer(coords, maxDistance, filter) |
| `ClosestVehicle` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.closestVehicle(coords, maxDistance, filter) |
| `CommandAdd` | server | `(name, options, handler)` | 1.0.0 | Cis.command.add(name, { params, restricted, help }, handler) |
| `CommandList` | server | `()` | 1.0.0 | Cis.command.list() |
| `CommandParse` | server | `(raw)` | 1.0.0 | no proxy equivalent; the argument splitter used by CommandAdd |
| `CommandRemove` | server | `(name)` | 1.0.0 | Cis.command.remove(name) |
| `CreatePed` | client | `(model, coords, heading?, options?)` | 1.0.0 | no proxy equivalent; returns 0 on an invalid or unloaded model |
| `CreatePoint` | client | `(data)` | 1.0.0 | Cis.points.add({ coords, distance, onEnter, onExit, nearby }) |
| `CreateTarget` | client | `(zoneType, name, coords, size, options?)` | 1.0.0 | Cis.target.add(zoneType, name, coords, size, options) |
| `CreateZone` | client | `(kind, name, a, b, options?)` | 1.0.0 | Cis.zones.box / Cis.zones.poly / Cis.zones.sphere |
| `DbInsert` | server | `(sql, params?)` | 1.0.0 | Cis.db.insert(sql, params) |
| `DbQuery` | server | `(sql, params?)` | 1.0.0 | Cis.db.query(sql, params) |
| `DbScalar` | server | `(sql, params?)` | 1.0.0 | Cis.db.scalar(sql, params) |
| `DbSingle` | server | `(sql, params?)` | 1.0.0 | Cis.db.single(sql, params) |
| `DbTransaction` | server | `(queries)` | 1.0.0 | Cis.db.transaction(queries). Driver-shaped list of { query, values } entries |
| `DbUpdate` | server | `(sql, params?)` | 1.0.0 | Cis.db.update(sql, params) |
| `DebugLog` | client | `(message)` | 1.0.0 | Cis.log.debug(message) |
| `DetectDatabase` | both | `(configured?)` | 1.0.0 | Asks the server which driver is running. Returns { name, resource, version, how, reason } |
| `DetectFramework` | both | `()` | 1.0.0 | Asks the server what framework it is actually running. Returns { name, resource, version, how, reason } |
| `DrawText3D` | client | `(x, y, z, text, settings?)` | 1.0.0 | no proxy equivalent |
| `FixDoor` | server | `(identifier)` | 1.0.0 | no proxy equivalent; exports["cis_libs"]:FixDoor(identifier) |
| `GetAllDoorData` | server | `()` | 1.0.0 | no proxy equivalent; the full door and group tables |
| `GetAuditLog` | server | `(limit?)` | 1.0.0 | The capability and configuration change log, newest last. Gated on Security.AuthorizedResources like every other mutating call. Entries carry resource and slot names and never a player name, identifier or IP. Bounded by Config.AuditLines, default 500 |
| `GetCachedHeading` | client | `()` | 1.0.0 | Cis.player.heading(), which reads the native directly in a consumer VM |
| `GetCachedPed` | client | `()` | 1.0.0 | Cis.player.ped(), which reads the native directly in a consumer VM |
| `GetCachedPlayerId` | client | `()` | 1.0.0 | Cis.player.playerId() |
| `GetCachedSeat` | client | `()` | 1.0.0 | Cis.player.seat() |
| `GetCachedServerId` | client | `()` | 1.0.0 | Cis.player.serverId() |
| `GetCachedVehicle` | client | `()` | 1.0.0 | Cis.player.vehicle() |
| `GetCachedWeapon` | client | `()` | 1.0.0 | Cis.player.weapon() |
| `GetCapabilities` | both | `()` | 1.0.0 | The one call that answers "which of my four resources is actually running". Returns { [slot] = { owner, resolved } } |
| `GetClientConfig` | client | `()` | 1.0.0 | no proxy equivalent; the config the server sent to this client |
| `GetClientLogging` | client | `()` | 1.0.0 | Cis.log.debug / info / warn / error |
| `GetClosestDoor` | client | `()` | 1.0.0 | no proxy equivalent; exports["cis_libs"]:GetClosestDoor() |
| `GetClosestPoint` | client | `()` | 1.0.0 | Cis.points.getClosest() |
| `GetClosestVehicle` | client | `()` | 1.0.0 | no proxy equivalent; a 5 unit forward ray, then a 5 unit radius search |
| `GetConfigSummary` | server | `()` | 1.0.0 | no proxy equivalent; the non-secret half of the server config |
| `GetCurrentWeaponData` | client | `(ped?)` | 1.0.0 | Cis.player.weapon() |
| `GetDiagnostics` | both | `(opts?)` | 1.0.0 | Counts, never player data: capability slots and owners, sync records by owner, pending callbacks, net handlers, error and warning counters, memory, uptime, and pass timings. The harness diffs counters and probes only; timings are a sibling so a pass does not fail every case |
| `GetDiscordConfig` | server | `()` | 1.0.0 | The outbound/webhook configuration SetConfig was handed, for the capability that does the sending. Server realm only -- it holds webhook URLs and is deliberately not on the client payload whitelist |
| `GetDiscordQueueDepth` | server | `()` | 1.0.0 | no proxy equivalent; queued message count and dropped count |
| `GetDistanceBetweenCoords` | client | `(x1, y1, z1, x2, y2, z2)` | 1.0.0 | no proxy equivalent |
| `GetDoorState` | both | `()` | 1.0.0 | Cis.doors.get(id) |
| `GetKnownTargets` | both | `()` | 1.0.0 | The ordered framework and driver tables detection uses. Shared so a product cannot disagree with the debug output about what is running |
| `GetLastRefusal` | server | `()` | 1.0.0 | Read after a nil/false answer from a capability export to learn WHY it was refused. Returns a sentence naming the missing or failing capability, or nil when the last call succeeded. Additive: no existing return shape changes |
| `GetLibsPrefix` | server | `()` | 1.0.0 | no proxy equivalent; the configured Security.EventPrefix |
| `GetLogging` | server | `()` | 1.0.0 | Cis.log.debug / info / warn / error |
| `GetNormalizedPlayer` | server | `(src)` | 1.0.0 | Cis.framework.player(src) |
| `GetOnlineJobCount` | server | `(jobs)` | 1.0.0 | no proxy equivalent; the callback cis_libs:getOnlineJobCount |
| `GetPlayerVehicleSeat` | client | `()` | 1.0.0 | Cis.player.vehicle(), second return value |
| `GetPointsDebug` | client | `()` | 1.0.0 | no proxy equivalent; the live debug record for the point pass |
| `GetSelfCheck` | server | `()` | 1.0.0 | The boot self-check as data: { ok, problems = { { code, message, fix } } }. Each problem names the change that resolves it |
| `GetSyncedEntities` | client | `()` | 1.0.0 | no proxy equivalent; the id-to-handle table of everything this client spawned |
| `GetSyncedEntity` | client | `(key)` | 1.0.0 | Cis.sync.entity(key) |
| `GetTableSize` | client | `(t)` | 1.0.0 | no proxy equivalent |
| `GetVehicleProperties` | client | `(vehicle)` | 1.0.0 | no proxy equivalent; the full property snapshot used by sync |
| `GetZoneDebug` | client | `()` | 1.0.0 | no proxy equivalent; the last grid pass cost in milliseconds |
| `HookOn` | both | `(name, fn, opts?)` | 1.0.0 | Cis.hooks.on(name, fn, opts) |
| `HookRemove` | both | `(id)` | 1.0.0 | Cis.hooks.remove(id) |
| `HookRun` | both | `(name, payload?)` | 1.0.0 | Cis.hooks.run(name, payload) |
| `InventoryAdd` | server | `(src, item, amount, metadata?)` | 1.0.0 | Cis.inventory.add(src, item, amount, metadata) |
| `InventoryCount` | both | `()` | 1.0.0 | Cis.inventory.count(item) on the client, Cis.inventory.count(src, item) on the server |
| `InventoryHas` | both | `()` | 1.0.0 | Cis.inventory.has(...) |
| `InventoryRemove` | server | `(src, item, amount)` | 1.0.0 | Cis.inventory.remove(src, item, amount) |
| `InvokingAllowed` | server | `()` | 1.0.0 | no proxy equivalent; ask before mutating. This is the supported way to avoid a refusal |
| `IsReady` | client | `()` | 1.0.0 | Cis.isReady, or Cis.ready(cb) |
| `KeybindAdd` | client | `(options)` | 1.0.0 | Cis.keybind.add({ name, description, defaultKey, onPress, onRelease }) |
| `Keybinds` | client | `()` | 1.0.0 | no proxy equivalent; every binding this library registered |
| `LockDoors` | server | `(identifier)` | 1.0.0 | Cis.doors.setState(identifier, true) |
| `LogDebug` | both | `()` | 1.0.0 | Cis.log.debug(message) |
| `LogError` | both | `()` | 1.0.0 | Cis.log.error(message) |
| `LogInfo` | both | `()` | 1.0.0 | Cis.log.info(message) |
| `LogWarn` | both | `()` | 1.0.0 | Cis.log.warn(message) |
| `ModuleInfo` | both | `(name, opts?)` | 1.0.0 | Cis.moduleInfo(name, opts) |
| `NearbyObjects` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.nearbyObjects(coords, maxDistance, filter) |
| `NearbyPeds` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.nearbyPeds(coords, maxDistance, filter) |
| `NearbyPlayers` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.nearbyPlayers(coords, maxDistance, filter) |
| `NearbyVehicles` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.nearbyVehicles(coords, maxDistance, filter) |
| `Notify` | both | `()` | 1.0.0 | Cis.framework.notify(...). With a framework provider registered the call passes through to it untouched; with none, cis_libs delivers it itself through the same guards NotifyClient uses, so a server with no framework does not go mute and does not become the unbounded path. The two-argument client form sends `kind` in the message slot; this is pinned as a known defect in test/contracts.lua and is a MAJOR change to correct |
| `NotifyClient` | server | `(src, message, kind?)` | 1.0.0 | Called by a product to show a notification to one client, without hardcoding the event name owned by this library. Answers `false, reason` for a src that is not a connected player, truncates a message past 512 characters, and allows 10 a second per (src, calling resource) |
| `OnPlayerCache` | client | `(key, cb)` | 1.0.0 | Cis.player.on(key, cb). The cb cannot cross the boundary; use a net event |
| `Ptfx` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.ptfx(name, timeout) |
| `PublishInventory` | server | `(src)` | 1.0.0 | Called by the inventory service. Pushes cis_libs:client:inventory to one player |
| `PublishJobUpdate` | server | `(job, src?)` | 1.0.0 | Called by cis_core when a player changes job. Fires cis_libs:jobUpdated, so the event name stays owned by this library |
| `PublishPlayerLoaded` | server | `(job, src?)` | 1.0.0 | Called by cis_core when a player object exists. Fires cis_libs:playerLoaded |
| `RandomFloat` | client | `(lower, greater)` | 1.0.0 | no proxy equivalent |
| `RateOk` | server | `(src, name, windowMs?, maxHits?)` | 1.0.0 | no proxy equivalent; a resource may share the library rate limiter |
| `RaycastCamera` | client | `(flags, ignore, distance?, timeoutMs?)` | 1.0.0 | Cis.raycast.camera(flags, ignore, distance, timeoutMs) |
| `RaycastFromCoords` | client | `(origin, target, flags?, ignore?, timeoutMs?)` | 1.0.0 | Cis.raycast.fromCoords(origin, target, flags, ignore, timeoutMs) |
| `RegisterCallback` | both | `()` | 1.0.0 | Cis.callback.register(name, handler) |
| `RegisterCapability` | both | `()` | 1.0.0 | Called by cis_core, cis_bridge and cis_keys with (slot, "resource:Export"). First registration wins |
| `RemoveNearWatcher` | client | `(id)` | 1.0.0 | Cis.player.nearStop(id); the id WatchNear returns as its second value |
| `RemovePoint` | client | `(id)` | 1.0.0 | Cis.points.remove(id) |
| `RemoveStatebagHandler` | both | `(cookie)` | 1.0.0 | Cis.statebag.remove(cookie) |
| `RemoveTarget` | client | `(name, isPed?)` | 1.0.0 | Cis.target.remove(name, isPed) |
| `RemoveZone` | client | `(name)` | 1.0.0 | Cis.zones.remove(name) |
| `RequestInventorySync` | client | `()` | 1.0.0 | Cis.inventory.count is a hint. This asks for a fresh one. Client only |
| `RequestLockDoors` | client | `(identifier)` | 1.0.0 | Cis.doors.setState(id, true) on the client |
| `RequestModelTimeout` | client | `(model, timeout?)` | 1.0.0 | Cis.streaming.model(model, timeout) |
| `RequestUnlockDoors` | client | `(identifier)` | 1.0.0 | Cis.doors.setState(id, false) on the client |
| `Round` | client | `(num, numDecimalPlaces?)` | 1.0.0 | no proxy equivalent; math round to n places |
| `Scaleform` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.scaleform(name, timeout) |
| `SecureNetOn` | server | `(name, fn, opts?)` | 1.0.0 | Cis.net.on(name, fn, opts) -> true when the event was bound |
| `SecurityReport` | server | `(src, reason)` | 1.0.0 | Cis.security.report(src, reason) |
| `SendDiscordLog` | server | `(webhookURL, title, message, color, ping)` | 1.0.0 | Cis.log.info with a discordType; no proxy equivalent for a raw webhook push |
| `ServerZoneBox` | server | `(center, size, opts?)` | 1.0.0 | Cis.zones.server.box(center, size, opts) |
| `ServerZoneContains` | server | `(id, coords)` | 1.0.0 | Cis.zones.server.contains(id, coords) |
| `ServerZonePlayers` | server | `(id)` | 1.0.0 | Cis.zones.server.players(id) |
| `ServerZonePoly` | server | `(points, opts?)` | 1.0.0 | Cis.zones.server.poly(points, opts) |
| `ServerZoneRemove` | server | `(id)` | 1.0.0 | Cis.zones.server.remove(id) |
| `ServerZoneSphere` | server | `(center, radius, opts?)` | 1.0.0 | Cis.zones.server.sphere(center, radius, opts) |
| `SetConfig` | server | `(config?, security?, discord?)` | 1.0.0 | Called by cis_core at boot with (config, security, discord). First registration wins; a second is refused and named. `security.AllowAnyResource` is the 1.0.0 opt-in escape hatch: with it true an EMPTY AuthorizedResources stops meaning restrictive, and the console warns on every boot |
| `SetDropPlayerHandler` | server | `(provider)` | 1.0.0 | Called by whoever ships the config, with "resource:Export". A FUNCTION cannot be sent across the boundary, which is why this exists |
| `SetVehicleProperties` | client | `(vehicle, props, fixVehicle?)` | 1.0.0 | no proxy equivalent; diffs against the last applied snapshot |
| `StatebagOnEntity` | both | `(key, handler, timeoutMs?)` | 1.0.0 | Cis.statebag.onEntity(key, handler, timeoutMs) |
| `StatebagOnPlayer` | both | `(key, handler, timeoutMs?)` | 1.0.0 | Cis.statebag.onPlayer(key, handler, timeoutMs) |
| `SyncClear` | server | `()` | 1.0.0 | Cis.sync.clear() |
| `SyncCreate` | server | `(kind, data)` | 1.0.0 | Cis.sync.ped / Cis.sync.prop / Cis.sync.vehicle |
| `SyncList` | server | `()` | 1.0.0 | Cis.sync.list() |
| `SyncRemove` | server | `(id?)` | 1.0.0 | Cis.sync.remove(id) |
| `TargetAvailable` | client | `()` | 1.0.0 | no proxy equivalent; true when a configured target provider is started |
| `TargetExists` | client | `(name)` | 1.0.0 | Cis.target.exists(name) |
| `TextureDict` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.textureDict(name, timeout) |
| `TriggerLibCallback` | client | `(name, cb?, ...)` | 1.0.0 | the client-to-server round trip whose callback receives only the results |
| `TryAwaitCallback` | both | `()` | 1.0.0 | Cis.callback.tryAwait(name, ...) -> ok, ... on success; false, reason on a refusal |
| `UiConfirm` | client | `(opts)` | 1.0.0 | Cis.ui.confirm(opts). Forward only -- no native dialog. RETURNS, does not take a callback |
| `UiInput` | client | `(opts)` | 1.0.0 | Cis.ui.input(opts). Forward only -- no native dialog. RETURNS, does not take a callback |
| `UiNotify` | client | `(message, kind?)` | 1.0.0 | Cis.ui.notify(message, kind). NOT Cis.framework.notify: that one is player-targeted, rate-limited, and the one a server uses. This is the local toast |
| `UiProgress` | client | `(opts)` | 1.0.0 | Cis.ui.progress(opts). Forward only -- cis_libs draws no bar |
| `UiTextUIHide` | client | `()` | 1.0.0 | Cis.ui.textUI.hide() |
| `UiTextUIIsOpen` | client | `()` | 1.0.0 | Cis.ui.textUI.isOpen() |
| `UiTextUIShow` | client | `(text, opts?)` | 1.0.0 | Cis.ui.textUI.show(text, opts) |
| `UnlockDoors` | server | `(identifier)` | 1.0.0 | Cis.doors.setState(identifier, false) |
| `UnregisterCapability` | server | `(slot)` | 1.0.0 | Called by a product on shutdown or handover. Only the slot owner may release it |
| `UpdateTarget` | client | `(name, newOptions?)` | 1.0.0 | Cis.target.update(name, options) |
| `WaitCapability` | server | `(slot, timeoutMs?)` | 1.0.0 | Waits up to timeoutMs for a capability slot to be filled. Returns true and the owner, or nil and a reason naming the slot. No proxy equivalent -- a consumer waits from its own resource. |
| `WaitReady` | both | `(timeout?)` | 1.0.0 | Cis.ready(cb, timeout) or Cis.wait(timeout) |
| `WatchNear` | client | `(coords, distance?, onEnter?, onExit?, onEnterEvent?, onExitEvent?)` | 1.0.0 | Cis.player.near(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent) |
| `WeaponAsset` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.weaponAsset(hash, timeout) |
| `ZoneContains` | client | `(name, point?)` | 1.0.0 | Cis.zones.contains(name, point) |

| Event | Since | Payload |
|---|---|---|
| `chat:addSuggestion` | 1.0.0 | server to client, (name, help, params) while the chat resource is started. The one new standard-resource integration allowed, used only by Cis.command.add |
| `cis_libs:capabilityChanged` | 1.0.0 | both realms: ({ slot, action, owner, previousOwner, resolved }) |
| `cis_libs:cb` | 1.0.0 | client to server and server to client: (name, key, ...) |
| `cis_libs:cb:res` | 1.0.0 | client: (key, ok, ...) resolving an outstanding callback |
| `cis_libs:cb:serverRes` | 1.0.0 | server: (key, ok, ...) resolving an outstanding client callback |
| `cis_libs:client:getData` | 1.0.0 | server to client: ({ Config, EventPrefix }) on join. DoorData was not shipped in 1.0.0 |
| `cis_libs:client:inventory` | 1.0.0 | server to client: ({ [itemName] = count }), pushed by PublishInventory |
| `cis_libs:client:showNotification` | 1.0.0 | server to client: (message, kind) |
| `cis_libs:client:syncRemove` | 1.0.0 | server to client: (key) despawn a synced entity. The same namespaced key the upsert carried. |
| `cis_libs:client:syncUpsert` | 1.0.0 | server to client: (record) for a nearby synced entity. The record's identity is `record.key` -- the caller's id namespaced by the owning resource -- and that is what a client keys its entity on. `record.id` is the caller's own id, carried for reference. |
| `cis_libs:jobUpdated` | 1.0.0 | server to client: ({ name, grade }), fired by PublishJobUpdate |
| `cis_libs:playerLoaded` | 1.0.0 | server to client: (job), fired by PublishPlayerLoaded |
| `cis_libs:server:getData` | 1.0.0 | client to server: no arguments, requests the config payload |
| `cis_libs:server:inventorySync` | 1.0.0 | client to server: no arguments, requests an inventory snapshot |
| `cis_libs:server:syncSnapshot` | 1.0.0 | client to server: no arguments, sent by the client when its sync scripts load. The server forgets what it believed this player held and re-sends everything currently visible, which is how a client restart recovers instead of staying permanently out of sync. |

| `Cis.*` | Realm | Signature | Since | Notes |
|---|---|---|---|---|
| `Cis.callback.await` | both | `(name, ...)` | 1.0.0 |  |
| `Cis.callback.awaitClient` | server | `(src, name, ...)` | 1.0.0 |  |
| `Cis.callback.call` | both | `(name, cb?, ...)` | 1.0.0 |  |
| `Cis.callback.callClient` | server | `(src, name, cb?, ...)` | 1.0.0 |  |
| `Cis.callback.register` | both | `(name, handler)` | 1.0.0 |  |
| `Cis.callback.tryAwait` | both | `(name, ...)` | 1.0.0 |  |
| `Cis.command.add` | server | `(name, options, handler)` | 1.0.0 |  |
| `Cis.command.list` | server | `()` | 1.0.0 |  |
| `Cis.command.remove` | server | `(name)` | 1.0.0 |  |
| `Cis.db.insert` | server | `(sql, params?)` | 1.0.0 |  |
| `Cis.db.query` | server | `(sql, params?)` | 1.0.0 |  |
| `Cis.db.scalar` | server | `(sql, params?)` | 1.0.0 |  |
| `Cis.db.single` | server | `(sql, params?)` | 1.0.0 |  |
| `Cis.db.transaction` | server | `(queries)` | 1.0.0 |  |
| `Cis.db.update` | server | `(sql, params?)` | 1.0.0 |  |
| `Cis.doors.add` | both | `(data)` | 1.0.0 |  |
| `Cis.doors.get` | both | `(id)` | 1.0.0 |  |
| `Cis.doors.setState` | both | `(id, locked)` | 1.0.0 |  |
| `Cis.framework.notify` | both | `()` | 1.0.0 |  |
| `Cis.framework.player` | server | `(src)` | 1.0.0 |  |
| `Cis.hooks.on` | both | `(name, fn, opts?)` | 1.0.0 |  |
| `Cis.hooks.remove` | both | `(id)` | 1.0.0 |  |
| `Cis.hooks.run` | both | `(name, payload?)` | 1.0.0 |  |
| `Cis.inventory.add` | server | `(src, item, amount, metadata?)` | 1.0.0 |  |
| `Cis.inventory.count` | both | `()` | 1.0.0 |  |
| `Cis.inventory.has` | both | `()` | 1.0.0 |  |
| `Cis.inventory.remove` | server | `(src, item, amount)` | 1.0.0 |  |
| `Cis.keybind.add` | client | `(options)` | 1.0.0 |  |
| `Cis.log.debug` | both | `(message)` | 1.0.0 |  |
| `Cis.log.error` | both | `(message)` | 1.0.0 |  |
| `Cis.log.info` | both | `(message)` | 1.0.0 |  |
| `Cis.log.warn` | both | `(message)` | 1.0.0 |  |
| `Cis.moduleInfo` | both | `(name, opts?)` | 1.0.0 |  |
| `Cis.moduleProbe` | both | `()` | 1.0.0 |  |
| `Cis.net.on` | server | `(name, fn, opts?)` | 1.0.0 |  |
| `Cis.player.coords` | client | `()` | 1.0.0 |  |
| `Cis.player.heading` | client | `()` | 1.0.0 |  |
| `Cis.player.near` | client | `(coords, distance?, onEnter?, onExit?, onEnterEvent?, onExitEvent?)` | 1.0.0 |  |
| `Cis.player.on` | client | `(key, cb)` | 1.0.0 |  |
| `Cis.player.ped` | client | `()` | 1.0.0 |  |
| `Cis.player.playerId` | client | `()` | 1.0.0 |  |
| `Cis.player.seat` | client | `()` | 1.0.0 |  |
| `Cis.player.serverId` | client | `()` | 1.0.0 |  |
| `Cis.player.vehicle` | client | `()` | 1.0.0 |  |
| `Cis.player.weapon` | client | `()` | 1.0.0 |  |
| `Cis.points.add` | client | `(data)` | 1.0.0 |  |
| `Cis.points.getClosest` | client | `()` | 1.0.0 |  |
| `Cis.points.remove` | client | `(id)` | 1.0.0 |  |
| `Cis.raycast.camera` | client | `(flags?, ignore?, distance?, timeoutMs?)` | 1.0.0 |  |
| `Cis.raycast.fromCoords` | client | `(origin, target, flags?, ignore?, timeoutMs?)` | 1.0.0 |  |
| `Cis.ready` | both | `(cb?, timeout?)` | 1.0.0 |  |
| `Cis.require` | both | `(name)` | 1.0.0 |  |
| `Cis.requireList` | both | `()` | 1.0.0 |  |
| `Cis.security.report` | server | `(src, reason)` | 1.0.0 |  |
| `Cis.statebag.onEntity` | both | `(key, handler, timeoutMs?)` | 1.0.0 |  |
| `Cis.statebag.onPlayer` | both | `(key, handler, timeoutMs?)` | 1.0.0 |  |
| `Cis.statebag.remove` | both | `(cookie)` | 1.0.0 |  |
| `Cis.streaming.animDict` | client | `(name, timeout?)` | 1.0.0 |  |
| `Cis.streaming.animSet` | client | `(name, timeout?)` | 1.0.0 |  |
| `Cis.streaming.audioBank` | client | `(name, timeout?)` | 1.0.0 |  |
| `Cis.streaming.model` | client | `(model, timeout?)` | 1.0.0 |  |
| `Cis.streaming.ptfx` | client | `(name, timeout?)` | 1.0.0 |  |
| `Cis.streaming.scaleform` | client | `(name, timeout?)` | 1.0.0 |  |
| `Cis.streaming.textureDict` | client | `(name, timeout?)` | 1.0.0 |  |
| `Cis.streaming.weaponAsset` | client | `(hash, timeout?)` | 1.0.0 |  |
| `Cis.sync.clear` | both | `()` | 1.0.0 |  |
| `Cis.sync.entity` | both | `(key)` | 1.0.0 |  |
| `Cis.sync.list` | both | `()` | 1.0.0 |  |
| `Cis.sync.onDespawn` | both | `(fn)` | 1.0.0 |  |
| `Cis.sync.onSpawn` | both | `(fn)` | 1.0.0 |  |
| `Cis.sync.ped` | both | `(data)` | 1.0.0 |  |
| `Cis.sync.prop` | both | `(data)` | 1.0.0 |  |
| `Cis.sync.remove` | both | `(id)` | 1.0.0 |  |
| `Cis.sync.vehicle` | both | `(data)` | 1.0.0 |  |
| `Cis.target.add` | client | `(zoneType, name, coords, size, options?)` | 1.0.0 |  |
| `Cis.target.exists` | client | `(name)` | 1.0.0 |  |
| `Cis.target.remove` | client | `(name, isPed?)` | 1.0.0 |  |
| `Cis.target.update` | client | `(name, options?)` | 1.0.0 |  |
| `Cis.ui.confirm` | client | `(opts)` | 1.0.0 |  |
| `Cis.ui.input` | client | `(opts)` | 1.0.0 |  |
| `Cis.ui.notify` | client | `(message, kind?)` | 1.0.0 |  |
| `Cis.ui.progress` | client | `(opts)` | 1.0.0 |  |
| `Cis.ui.textUI.hide` | client | `()` | 1.0.0 |  |
| `Cis.ui.textUI.isOpen` | client | `()` | 1.0.0 |  |
| `Cis.ui.textUI.show` | client | `(text, opts?)` | 1.0.0 |  |
| `Cis.wait` | both | `(timeout?)` | 1.0.0 |  |
| `Cis.waitFor` | both | `(fn, msg?, timeoutMs?)` | 1.0.0 |  |
| `Cis.zones.box` | client | `(name, center, size, options?)` | 1.0.0 |  |
| `Cis.zones.contains` | client | `(name, point?)` | 1.0.0 |  |
| `Cis.zones.poly` | client | `(name, points, options?)` | 1.0.0 |  |
| `Cis.zones.remove` | client | `(name)` | 1.0.0 |  |
| `Cis.zones.server.box` | server | `(center, size, opts?)` | 1.0.0 |  |
| `Cis.zones.server.contains` | server | `(id, coords)` | 1.0.0 |  |
| `Cis.zones.server.players` | server | `(id)` | 1.0.0 |  |
| `Cis.zones.server.poly` | server | `(points, opts?)` | 1.0.0 |  |
| `Cis.zones.server.remove` | server | `(id)` | 1.0.0 |  |
| `Cis.zones.server.sphere` | server | `(center, radius, opts?)` | 1.0.0 |  |
| `Cis.zones.sphere` | client | `(name, center, radius?, options?)` | 1.0.0 |  |


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
| No NUI ships here | `ui` slot | `progress` / `confirm` / `input` need a ui provider. notify and textUI fall back to native GTA. |

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
| Zones never fire | Handler was a function. Use `onEnterEvent` |
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

- No NUI page. `Cis.ui.progress`, `confirm`, and `input` need a ui provider.
- Empty `Security.AuthorizedResources` refuses mutating exports.
- A Lua function cannot be a zone, point, hook, or callback handler that
  crosses the exports boundary.
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

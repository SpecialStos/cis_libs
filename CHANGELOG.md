# Changelog

All notable changes to `cis_libs`. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

The **contract** is versioned separately and is still `api = 1`.

## [Unreleased]

Correctness, security and performance work across every layer, plus a
first-party NUI. Several fixes change a documented answer; they are listed
under **Changed** so nobody upgrades into them blind.

### Upgrading from 1.0.0

Check these first; each is a line under **Changed** or **Deprecated**.

1. **Authorise your resources.** With `Security.AuthorizedResources` (or the
   `cis_authorized_resources` convar) empty, door mutators, sync writes and
   `RegisterCapability` are refused. List every resource that needs them.
2. **Read the second return value.** `RegisterCallback`, `SecureNetOn`,
   `CommandAdd`, `KeybindAdd`, `HookOn`, the zone constructors, `heap.push`,
   `lru.put`, `mathx.clamp`, `cron.*` and `time.parseDuration` answer
   `false` or `nil` plus a reason where 1.0.0 raised, swapped or accepted.
3. **Names are owned.** A callback, command, keybind or net event name that
   another resource already holds is refused. Prefix yours with the resource
   name.
4. **Deprecated slots and `Detect*` exports** still work and warn once per
   calling resource. Move to cis_bridge before 2.0.0 removes them.
5. **A supplied `security` table is merged over the defaults.** To turn kicks
   off, say `DropPlayer = false`; leaving it out keeps them on.
6. **Wire events changed.** A resource that listened to
   `cis_libs:client:syncUpsert` directly, or posted NUI messages to the built-in
   page, must use the `Cis.*` API instead; the raw events are not a contract.

### Changed

- **The server zone pass runs only while a zone exists.** Its loop woke every
  500 ms from boot, with no zone and no player (0.05 to 0.08 ms each on the
  VPS profile). The first zone starts it, and it ends once the last zone is
  removed or its owner stops.

- **`SetConfig`'s `security` is merged over the default `Security`.** It
  replaced it outright, so a supplier that set only `AuthorizedResources` left
  `DropPlayer` nil and a player the guard reported was no longer kicked. A key
  left out now keeps its default. Each supply starts from fresh defaults, so a
  second supply still replaces the first one's allow-list. A supplier that
  wants kicks off says `DropPlayer = false`.
- **`local` must be exactly `true`, and it now applies to all three zone
  events.** It used to switch only when `insideEvent` was set, so a zone
  with only `onEnterEvent` and `local = true` sent a server event.
- **Degenerate zones are refused with a reason**: a poly with fewer than 3
  points or a non-finite or inverted `minZ`/`maxZ`, a box with a
  non-positive axis or a non-finite heading, and a sphere with a
  non-positive radius. Zones and points must lie within 100 km of the origin.
- **Streaming timeouts must be 0 to 600000 ms.** NaN, infinity, a negative
  or a non-number is refused before anything is requested.

- **The payload schema refuses infinity and can say `integer`.** A
  `number` that is +inf or -inf is refused unless the rule sets
  `finite = false`; NaN is always refused. `type = 'integer'` accepts a
  whole, finite number within +-2^53 (`3.0` counts). This applies to
  `SecureNetOn` and `RegisterCallback` schemas alike.
- **The rate limiter evicts expired buckets** instead of refusing every new
  name once a player holds 256, and a refusal at that cap is never escalated
  to a report or a kick. `RateOk` answers `false, 'cap'` for it. A string
  `src` is the same player as its number.
- **A networked record is not dropped when its entity keeps being deleted.**
  Past three re-creations a minute it backs off (5 s, doubling to 5 min) and
  keeps the record.
- **Sync upserts are batched**: a burst in one tick is one `syncBatch` per
  nearby player on the next tick. `cis_libs:server:syncGaveUp` takes a list
  of keys (up to 256); clients batch their give-ups.
- **cis_libs' own zone, point and near-watcher threads run on demand**, as a
  consumer's always did: started by the first zone, point or watcher and
  ended by the last. A client with none runs no loop (they woke about nine
  times a second). The zone thread still waits for readiness first.
- **`heading` is pushed only while something follows it.** The cache sent a
  `cis_libs:cache` event to every client resource 4-10 times a second while
  moving; now a consumer's `Cis.onCache('heading', ...)` asks for it with the
  new `FollowCacheHeading` export, and `Cis.player.heading()` reads the native.
- **The consumer mirror answers nil while cis_libs is stopped** instead of
  the last values (`Cis.player.vehicle()` kept naming a car the player may
  have left). The values come back with the re-snapshot on restart.
- **Point handlers get the point id** as a second argument:
  `onEnter(coords, id)`, `onExit(coords, id)`, `nearby(coords, id)`.
- Raycasts and `GetClosestVehicle` use the asynchronous LOS probe. The
  synchronous one blocked the game thread; `GetClosestVehicle` polls the
  probe only for a caller that can yield and otherwise answers from the
  vehicle pool alone.
- The `Round` export no longer rebinds the `ROUND` native inside cis_libs.
- **Per-frame client work runs in the consumer's own VM** (DOCUMENTATION.md
  §5.2). Through `init.lua`, `Cis.zones.*`, `Cis.points.*`, `Cis.keybind.add`,
  `Cis.raycast.*` and `Cis.streaming.*` no longer cross into cis_libs: each
  loads its engine from `client/core/*.lua` on first use and runs it locally.
  Zone, point and keybind handlers are plain local functions (no funcrefs),
  and these objects survive a cis_libs restart. `Cis.player.vehicle`, `seat`,
  `weapon`, `serverId`, `playerId` and `on` read a local mirror of the cache:
  one `GetCacheSnapshot` on the first read, then zero export calls.
  The export API (`CreateZone`, `CreatePoint`, `KeybindAdd`, ...) is unchanged
  and still serves callers of the exports. What a consumer can observe:
  - `Cis.zones.contains` and `Cis.points.getClosest` answer about the
    **calling resource's own** zones and points, not every resource's.
  - `Cis.keybind.add` registers the commands and the key mapping **under the
    calling resource**. A rebind a player saved under `cis_libs` does not
    carry over; the handle's methods now work.
  - `Cis.player.on` returns a real unsubscribe function and a local id (not
    an id for `RemovePlayerCacheListener`).
  - The `Config.Framework.Zones.Enabled` switch gates the exports only.
- **The cache pushes every change** as the local client event
  `cis_libs:cache` `(key, value, seat, silent)`; a pass that changes nothing
  pushes nothing.
- **Security posture is read from convars first.** `cis_authorized_resources`,
  `cis_allow_any_resource`, `cis_config_supplier`, `cis_check_version` and the
  `cis_cb_*` callback limits outrank `SetConfig`; a `convar_category` shows
  them in txAdmin. Without convars, `SetConfig` behaves as before.
- **`RegisterCallback` answers `false, reason`** on refusal (was a bare
  `false`) and takes `opts = { remote, ace, schema, maxStringLen }`. Every
  remote call's strings are capped (default 4096).
- **Sync wire events are one batch.** `cis_libs:client:syncUpsert` and
  `syncRemove` are replaced by `cis_libs:client:syncBatch` `(n, upserts,
  removes)`; clients report a give-up with `cis_libs:server:syncGaveUp`.
  Networked records are never streamed over sync events: the server creates
  the one entity and its metadata rides the `cis_sync` entity state bag.
- **`RegisterCapability` is gated on `Security.AuthorizedResources`** on both
  realms, like `SetDropPlayerHandler`. With the default (empty, restrictive)
  list, a provider such as `cis_bridge` must be listed to register. Clients
  get the list as one-way digests in the `cis_libs:client:getData` payload
  (`Providers`), never the names; a client registration that arrives before
  the payload is held and answered `true, 'held until ...'`, then filed or
  refused. First-come slots let any resource that started first own `ui`,
  `target`, `framework` or `security` for every consumer.
- **Server zones belong to one routing bucket** (`opts.bucket`, default 0).
- **World queries exclude the local player** (and player peds from ped
  queries) unless `opts.includeSelf` / `opts.includePlayers`.
- **Vehicle properties follow ox_lib field names and semantics**, including
  `bulletProofTyres = not canBurst`, extras 0..20 and tyres 45/47.
  `SetVehicleProperties` no longer diffs against a snapshot and returns
  `false, reason` without network control.
- **`Cis.ui.*` uses the built-in NUI** when no `ui` provider answers; the GTA
  feed and native help remain only as a fallback when the NUI is not loaded.
- **`InputDialog` textarea `min` / `max` are row counts**, as in ox_lib
  (default 3 and 20). They were character limits, so `{ min = 3, max = 10,
  autosize = true }` refused "ab" and cut the text at ten characters. Text
  length is `minLength` / `maxLength` on input and textarea (an input's
  `min` / `max` still mean its length), capped at 16384 UTF-16 units.
- **`InputDialog` checks every rule again in Lua** (bounds, lengths,
  `maxSelectedValues`, repeated picks, calendar dates, `#rgb`/`#rrggbb`) and a
  refused answer keeps the dialog open with the field marked; a disabled row
  returns its default. Select options cross to the page as indexes, so a
  value is returned exactly as passed (a Steam64 integer used to come back
  rounded and strand the dialog). A posted cancel is ignored when
  `allowCancel = false`.
- **`SkillCheck` is judged in Lua.** Lua places each zone, owns the clock and
  reads the keys; the page only draws. A press seen one frame late still
  counts (up to 34 ms); a round with no press fails once the needle passes.
- **An icon name that is not a built-in draws nothing** (and is logged once)
  where it drew the word. The built-in set is 63 icons, and about a hundred
  more Font Awesome names used by ox_lib callers (`home`, `cog`,
  `fa-solid fa-box-open`, `{ 'fas', 'box' }`) resolve to them.
- **`SetUiTheme` `colors` takes only the colour tokens** style.css reads
  (`accent`, `accent-fg`, `bg`, `surface`, `hover`, `border`, `fg`, `muted`,
  `backdrop`, `inform`, `success`, `warning`, `error`).
- **UI strings are capped in bytes and cut on a character** (client and
  `NotifyPlayer`); only invalid bytes become `?`.
- **The cache refreshes every 100-250 ms** (was 1 s) and emits `heading` and
  `shooting` changes.

- **`interp.headingToVector` / `vectorToHeading` follow GTA.** Heading 0 faces
  +Y and 90 faces −X, the vector `GetEntityForwardVector` answers:
  `(-sin h, cos h)`. They were 180° off.
- **`interp.headingDelta` is the shortest signed arc**, in [-180, 180), so
  `lerpHeading(10, 350, .5)` is 0 rather than 180.
- **`semver` is SemVer 2.0.0-strict by default.** `'1'`, `'1.2'`, `'v1.2.3'`,
  padded input, `'1..2'`, empty or `_` identifiers and leading zeros are
  refused with a reason; pass `{ loose = true }` to read hand-written versions.
  A version table is validated. Ranges follow node-semver, including `^0.x`,
  X-ranges with operators, `~>`, hyphen ranges and `includePrerelease`; an
  empty range or empty `||` alternative means any release, as in npm.
- **`json.checkEncodable` (and so `json.encode`) refuses tables codecs
  disagree on**: mixed string/number keys, sparse arrays, fractional or
  sub-1 number keys, each named by path.
- **`table.deepCopy` keeps keys by identity** and copies only values;
  **`table.map` keeps a nil result as nil** instead of `false`;
  **`table.reduce({}, fn)`** with no initial value answers `nil, reason`.
- **`rate`**: an omitted `now` reads `GetGameTimer() / 1000` (`os.time()`
  outside FiveM); a NaN or non-number `now` raises. It was coerced to 0, which
  pinned a fixed window shut forever.
- **`random.integer` and `generator:int` round fractional bounds inward**
  (`integer(1.5, 3.5)` draws 2 or 3) and refuse a range with no integer in it.
- **`string.truncate` counts characters**, not bytes, and floors a fractional
  `max`.
- **`heap.push` refuses nil** (and NaN under the default ordering) with
  `nil, reason`.
- **`GetClosestPoint` answers the caller's own nearest point**, as
  `GetAllPoints` already did; cis_libs still sees every point.
- **`RaycastCamera` refuses a distance that is infinite or over 100 km**, and
  `RaycastFromCoords` refuses a NaN or infinite origin or target.
- **`CisRandom` with a generator or a function raises for the 64-bit integer
  range** instead of answering a constant. With no generator,
  `integer(0, math.maxinteger)` now draws across the whole range.
- **`CisRandom.newGenerator` is now MRG32k3a with a nonlinearly mixed seed,
  so the sequence a given seed produces has changed.** MINSTD made seed k's
  stream seed 1's stream times k (mod 1), and seeds 0 and 2147483646 were the
  same generator. Different seeds now give unrelated streams, and the stream
  is identical under Lua 5.4 and fengari. `gen.state` is now six words, not
  one number. Anything that stored a seeded sequence must regenerate it.
- **`npm run test:all` also runs `npm run test:tools`**, the self-test for
  `lint.js`, `syntax-check.js`, `docs-check.js` and `mutate.js`
  (`test/tools-selftest.js`).
- **The release workflow is two jobs.** `build` has a read-only token, checks
  that the tag matches `package.json` and that the tag's commit is on main,
  runs the full gate and the mutation gate, and writes `SHA256SUMS` next to the
  zip. `publish` holds `contents: write`, has no checkout, verifies the
  checksum again and creates the draft release with the zip and `SHA256SUMS`
  attached.
- **Every CI job has a timeout**, and the nightly run has a concurrency group
  of its own, so a push to main no longer cancels it.
- **`engines.node` is now `>=24`**, the only Node version CI runs. `>=18` was
  never exercised.
- **`mathx.round` returns an integer unchanged** (A-M2). `round(7, 2)` is
  the integer 7 rather than 7.0, and an integer past 2^53, or
  `math.mininteger`, comes back exactly as given instead of going through a
  float. A `decimals` count past 308 in either direction is treated as 308.
- **`sparse.each` visits the values present when the walk started, even if
  the visitor removes them** (A-M4). It walks a copy, so removing the current
  value no longer skips later values or hands the visitor nil.
- **`sparse.add(set, NaN)` returns false** (A-M4), like a nil value.
- **A validate field spec passes `nonEmpty` to a string, and `min`, `max`,
  `nonEmpty` and `of` to a `table`** (A-M7). `nonEmpty` also reaches an
  `array` or `map` spec. `required` still means "not nil": an empty string
  needs `nonEmpty`.
- **`table.deepMerge` refuses a base or overlay nested deeper than
  `opts.maxDepth`** with `nil, why` (A-M8). It used to copy and recurse until
  the stack overflowed.
- **`validate.defaults` returns `nil, why` for a cyclic table or one nested
  deeper than 64 levels** (A-M8). It used to raise a stack overflow.
- **`locale.t` fills named values after formatting, not before** (A-M9). A
  `%` inside a `${name}` value now prints as it is and no longer shifts the
  positional arguments or raises. `%%` is now one `%` whenever any argument
  is given, including a table alone; with no argument the phrase is returned
  verbatim, as before. When the phrase does not fit its arguments the name-filled
  phrase is returned, with the values unescaped, and the warning is logged once.
- **`rate.prune` keeps a sliding limiter for its window plus one slice by
  default** (A-M5), so a key the ring still blocks is no longer freed early.
- **`window.record` accepts a sample older than the newest one** (A-M6). It
  is added to its own bucket and returns false only when it is older than the
  whole window.

- **A timer reuses its sleeping thread across pause and play** (A-M10). Each
  `play` used to spawn another thread, and a paused timer's old ones slept on
  until their original deadline, so 500 pause/play cycles left 501 threads.
  Now one thread serves the timer; it exits when it wakes on a paused or ended
  timer, and a later `play` starts a new one.
- **`string.suggest` returns the distance it matched on** (A-L1), the
  case-insensitive one, so it never exceeds `opts.maxDistance`. It used to
  re-score the winner in its real casing: `suggest('FOO', {'foo'})` answered 3
  against a maximum of 2.
- **`mathx.clamp` returns `nil, reason` for a NaN value or reversed bounds**
  (A-L10, A-L15), as `interp.clamp` and `validate.clamp` already do. It used
  to swap reversed bounds and pass NaN through, so the three clamps disagreed.
  A caller that relied on the swap must order its bounds.
- **`interp.ease` limits `t` to [0, 1]** (A-L10). The circ curves returned NaN
  above 1. An unknown name is still the identity, unlimited.
- **`interp.clampLength` treats a negative length as 0** (A-L10) and gives the
  zero vector; it used to flip the vector.
- **`curve.pointAtXYZ` on a closed path treats an infinite distance as 0**
  (A-L10); `inf % length` was NaN with `ok` true.
- **`heap.replaceTop` refuses nil, and NaN under the default ordering,** with
  `nil, reason` (A-L2), as `push` does. `heap.build` skips nil holes and
  such NaNs in its list.
- **`lru.put` refuses a nil or NaN key** with `nil, reason` (A-L3). A nil
  value is still a remove.
- **`cron.next` and `cron.matches` answer `nil, reason` for a time the platform
  cannot convert, and `matches` for one that is not a number** (A-L4). They
  raised from `os.date`, `math.floor` or inside the date arithmetic.
- **`mathx.groupDigits` returns `nil, reason` for a `decimals` outside 0 to 99**
  (A-L5); `string.format` raised for it. An integer is written out digit for
  digit, not through a float.
- **`string.padStart` and `padEnd` floor a fractional width and return the text
  unchanged for a missing, NaN or infinite one** (A-L6); they raised.
- **`rate.newFixed` and `newSliding` keep `limit = 0`** (A-L11), which allows
  nothing and reports an infinite `retryAfter`. It used to become 10. A
  negative or NaN limit still takes the default. `allow` refuses a nil or NaN
  key, and `peek` reports it with no allowance; both raised.
- **`window.isSeen` answers false and `window.prune` removes nothing when `now`
  is not a number** (A-L8), as `seen` already refuses it.
- **`id.normaliseName` keeps the uniqueness suffix inside `maxLength`** (A-L12)
  by trimming the name to make room, and answers `nil, reason` when even the
  suffix does not fit.
- **`time.parseDuration` answers `nil, reason` for a number too large for a
  double** (A-L13); it returned infinity.
- **`class` copies `__newindex` and `__gc` down to a subclass, and a parent
  `__index` function keeps answering after the subclass's own methods** (A-L9).
  A read-only parent was writable through a subclass.
- **Progress props are local objects.** `ProgressBar` / `ProgressCircle` created their props
  networked, which needs the server's entity policy to allow client-created entities (strict
  entity lockdown refuses them) and takes a network slot per prop. They are now created
  non-networked, as ox_lib creates them; other players see the animation without the prop.

- **A NUI message over 1 MiB is refused, not sent** (NUI-L11): the send
  returns `false, 'message too large'` and logs one error. A payload that size
  stalled CEF and the game frame.
- **The default `--cis-accent-fg` is dark ink (`#0b1220`)** (NUI-L12). White
  on the default accent `#4c8dff` was 3.2:1, under WCAG AA; dark ink is about
  5.9:1. `SetUiTheme({ colors = { ['accent-fg'] = '#fff' } })` restores it.
- **`SetUiLocale({ lang = 'de' })` sets the page language** (the html `lang`
  attribute, a BCP 47 tag; anything else is ignored), so a screen reader reads
  translated labels in the right voice (NUI-L12).
- **`random.integer`, `gen:int` and `gen:range` refuse instead of raising.**
  A bound past 2^53 (`integer(-1e300, 1e300)` raised inside `math.random`),
  or a span wider than 2^53 with an injected generator, answers `nil` and a
  reason. `gen:range` refuses a NaN or infinite bound, as `random.float` does.
- **`mathx.weightedPick` always picks an infinite weight** (the first one), as
  `random.weighted` does; it was skipped as if it were 0.
- **`validate.defaults` fails when a nested schema fails**, with its reason; it
  used to drop the field silently. A default that contains itself, or a schema
  nested deeper than 64, is refused.
- **`id.draw` takes 1 to 65536 symbols**, and `id.normaliseName` refuses a
  separator holding a letter or digit and a `maxLength` below 1 (a fraction is
  floored).
- **`string.levenshtein` and `string.suggest` refuse a negative or NaN
  ceiling**; `levenshtein('abc', 'xyz', -1)` answered 0, "identical".
- **`mathx.groupDigits` refuses a string with trailing garbage** (`'1234abc'`
  was grouped as `'1,234abc'`). `mathx.clamp`, `validate.clamp` and
  `interp.clamp` refuse a NaN bound, which handed the value back unclamped;
  `mathx.clamp` and `validate.clamp` answer a reason for a non-number bound
  instead of raising a compare error.
- **`SecureNetOn` (`Cis.net.on`) answers `false, reason` on every refusal,
  and checks its options at registration.** A schema the checker cannot read
  (a string, a rule that is not a table, an unknown type, a non-number
  `min`/`max`/`maxLen`) used to register, then refuse and report every
  payload, which on most servers kicked every player who sent the event. A
  NaN or infinite `windowMs`/`maxHits`, or `maxHits` 0, built a limiter
  window that never rolled or let the first hit through. A nil name raised.
  `RegisterCallback` checks its `schema` the same way.
- Every server export that can refuse now answers `false, reason`. `SyncCreate`
  (each validation refusal, the allow-list, `Config.Sync.Enabled = false`, a
  failed networked spawn), `SyncList` and `SyncClear` used to answer `nil`,
  which the exports boundary truncates, so the reason never arrived.
  `SyncRemove`, `AddDoorToSystem` and `AddDoorGroup` returned a bare `false`
  from a resource off the allow-list, and `UnregisterCapability` returned one to
  a non-holder; each now names why. `BreakDoor` and `FixDoor` answer the
  allow-list refusal as `false, reason` (nil still means no doors provider).
  `CallCallbackClient` with a bad target returned nothing; it now answers
  `false, reason` as well as telling `cb`, and refuses a player who is not
  connected before sending, as `AwaitCallbackClient` does.

### Added

- **The rest of the built-in interface under `Cis.ui`** (ox_lib names):
  `Cis.ui.context.register/show/hide/getOpen`, `Cis.ui.menu.register/show/
  hide/getOpen/setOptions`, `Cis.ui.radial.add/remove/clear/register/hide/
  disable`, `Cis.ui.skillCheck`, `skillCheckActive`, `cancelSkillCheck`,
  `progressActive`, `cancelProgress`, `closeAlert` and `closeInput`.
  Registrations are made again when cis_libs restarts.
- **Registrations held by cis_libs survive its restart.** `Cis.callback.register`,
  `Cis.target.add/update`, `Cis.sync.onSpawn/onDespawn`, `Cis.statebag.*`,
  `Cis.player.near` and the UI registrations above are recorded in the
  consumer and made again when cis_libs starts; watcher ids the consumer
  holds keep working. New `Cis.player.nearStop(id)`.
- **Zone and point queries:** `Cis.zones.getCurrent/getAll/getNearby` and
  `Cis.points.getAll/getNearby` (exports `GetCurrentZones`, `GetAllZones`,
  `GetNearbyZones`, `GetAllPoints`, `GetNearbyPoints`), answering names and
  ids of the caller's own zones and points.
- **Poly `thickness`** (ox_lib): a slab that many metres tall around the
  average z of the points, instead of z -1000 to 10000.
- **Keybinds:** `secondaryKey` and `secondaryMapper` (the `~!` alternate
  mapping), `disabled = true`, and `handle:getCurrentKey()`.
- **`Cis.world.getClosestPlayerId(coords, maxDistance, includePlayer)`** in
  ox_lib's order, `(playerIndex, ped, coords)`, within 2 m by default.
  `getClosestPlayer` keeps its documented order.
- **A per-call callback timeout:** `Cis.callback.awaitWithin(name, ms, ...)`
  and `tryAwaitWithin` (export `TryAwaitCallbackWithin`), 0 < ms <= 300000.
- `FollowCacheHeading` export (client).
- **Nine developer-experience modules** for `Cis.require`, bringing the count
  to twenty-four (DOCUMENTATION.md §5.1):
  - `locale` — per-resource `locales/<lang>.json`, language from the
    replicated convar `cis:locale` (else `en`), English fallback per file and
    per key, `${name}` and `%s` arguments, warn-once on a missing key.
  - `print` — `error`/`warn`/`info`/`verbose`/`debug` with colour prefixes;
    level from `cis:printlevel:<resource>`, then `cis:printlevel`, default
    `info`. A filtered call formats nothing.
  - `timer` — pausable `GetGameTimer` countdowns (`play`, `pause`, `restart`,
    `forceEnd`, `getTimeLeft`) that sleep for exactly the time left, and
    `setTimeout`/`setInterval`/`clearTimeout` with cancellation.
  - `cron` — five-field expressions with ranges, steps, lists and names,
    `@hourly`…`@yearly`, Vixie day-of-month/day-of-week OR semantics,
    `parse`/`next`/`matches`, and `schedule` on one scheduler thread per Lua
    state that sleeps until the next due job. Server local time, or UTC.
  - `class` — `class.new(name, super)`, constructors, `instanceof`, a
    `toString` hook, weak-table private fields.
  - `array` — explicit-length arrays (holes survive) with map, filter,
    reduce, find, slice, splice, concat, flat, a stable sort, unique,
    groupBy, chunk, zip, sum, min and max.
  - `set` and `ringbuffer` — an insertion-ordered Set with union, intersect
    and difference; a fixed-capacity ring buffer.
  - `mathx` — `round(n, decimals)`, `clamp`, `lerp` (FiveM vectors too),
    `inverseLerp`, `remap`, `approx`, `toHex`/`fromHex` exact to 2^53,
    `groupDigits`, and a `weightedPick` reproducible with a seeded generator.
- **`string.random(pattern, rng)`**, ox_lib's `'1AA111'` plate shape.
- **Consumer-side client helpers** (ox_lib parity), each loaded on first use
  and running in the caller's VM: `Cis.world.getClosestPed`,
  `Cis.world.getNearbyPeds` and their vehicle, object and player variants,
  `Cis.vehicle.getProperties` / `setProperties`, `Cis.marker.add` / `remove` /
  `clear` (one culled draw thread per resource, only while markers exist),
  `Cis.scaleform.new` (typed method calls, fullscreen / 3D draw, dispose),
  `Cis.dui.new`, `Cis.anim.play` (requests and releases the dictionary),
  `Cis.controls.disable` / `enable` / `isDisabled` (refcounted holds),
  `Cis.streaming.release`, `Cis.cache(key)` and `Cis.onCache(key, fn)`.
  Scaleforms and DUI pages still held are released when the resource stops.
- **`GetCacheSnapshot`** export: the mirror's one snapshot.
- **`client/core/`**: one source for the zone, point, keybind, world, shape
  test, streaming and vehicle engines, run by cis_libs behind its exports and
  by every consumer through `init.lua`. `npm run check-realms` and
  `gen-natives` now also check the client files listed in `files {}`.
- **Performance gates** in `test/contracts.lua` §19: a consumer with nothing
  registered runs zero threads; after the snapshot, 500 rounds of player
  reads, `zones.contains` and `points.getClosest` make zero export calls; a
  zone or point pass allocates nothing in the steady state.
- **First-party NUI** with no build step and no dependencies: `Toast`,
  `ProgressBar`/`ProgressCircle`, text UI, `AlertDialog`, `InputDialog`
  (11 field types), context menus, list menus, a radial menu, `SkillCheck`,
  themes and locale. One focus stack owns NUI focus; every blocking call has
  a single exit that releases focus, including when the caller stops.
  `NotifyPlayer(src, data)` sends a toast from the server.
- **Callback hardening**: per-player aggregate budget before any lookup,
  per-name rate, in-flight cap, ACE and schema options.
- **Keybind id exports** (`KeybindDisable`, `KeybindEnable`, `KeybindRemove`,
  `KeybindIsPressed`) and `RemovePlayerCacheListener`, because handle methods
  cannot cross exports.
- **`ReadyState`** export, so `Cis.isReady` / `Cis.isFailed` are correct in
  consumer resources.
- **`Cis.require` loads your own modules**: `'folder.file'`, `'folder/file'`
  and `'./file'` from the calling resource, `'@resource/folder/file'` from any
  resource. Read once per Lua state, text-only, in a private environment; see
  DOCUMENTATION.md §5.1.
- **A per-module function reference** (DOCUMENTATION.md §5.1) and typed module
  fields in `types/cis_libs.lua`, both generated from `---@param`/`---@return`
  annotations that every module function now carries.
- `.github/workflows/release.yml` refuses a tag that is not
  `v<package.json version>`.
- **A live server tier in CI.** The `live-server` job boots a real headless
  Linux FXServer (pinned build 35245, sha256-verified, cached), deploys
  cis_libs and the `test/live/` harness, runs the `server` and `lifecycle`
  tiers and fails on any FAIL, script error or boot error. It needs the
  `FIVEM_LICENSE_KEY` repository secret and skips with a notice without it
  (`tools/ci-fxserver.sh`, `tools/ci-live.js`, `npm run live:ci`,
  `npm run test:ci`; test/live/RUNBOOK.md, "CI").

### Deprecated

Since 1.1.0 and removed in 2.0.0. Everything below still works unchanged
until then. cis_libs logs one warning per calling resource and per name,
which is forgotten when that resource stops.

- **The framework, inventory, inventoryProvider, target, doors and
  doorsClient slots** move to cis_bridge, which detects the framework,
  inventory and target and exposes its own player, inventory, target and
  doors API. The raw exports `GetNormalizedPlayer`, `InventoryCount`,
  `InventoryHas`, `InventoryAdd`, `InventoryRemove`, `RequestInventorySync`,
  `PublishInventory`, `CreateTarget`, `RemoveTarget`, `UpdateTarget`,
  `TargetExists`, `TargetAvailable`, `AddDoorToSystem`, `AddDoorGroup`,
  `GetDoorState`, `GetAllDoorData`, `LockDoors`, `UnlockDoors`, `BreakDoor`,
  `FixDoor`, `RequestLockDoors`, `RequestUnlockDoors` and `GetClosestDoor`
  are deprecated with them, and so are the `Cis.framework.player`,
  `Cis.inventory.*`, `Cis.target.*` and `Cis.doors.*` proxies.
  `Notify` and `ShowNotification` stay: they never warn, because the
  notification has a built-in fallback that does not need a framework.
- **The database slot and the `Db*` exports** (`DbQuery`, `DbSingle`,
  `DbScalar`, `DbInsert`, `DbUpdate`, `DbTransaction`, and `Cis.db.*`).
  Call the oxmysql API (`MySQL.query.await` and its siblings) directly; it is
  served by oxmysql or by cis_database.
- **The dataProbe and migration slots** move to cis_core.
- **`DetectFramework`, `DetectDatabase` and `GetKnownTargets`** move to the
  cis_bridge detection.
- **The events `cis_libs:client:inventory` and `cis_libs:server:inventorySync`**
  go with the inventory slot. The server handler does not warn, because the
  sender is a player rather than a resource; `RequestInventorySync`, which
  fires it, warns its caller instead.
- **The config keys `Framework.Type`, `Framework.Inventory`,
  `Framework.Target.*` and `Framework.Database.*`** move to the cis_bridge
  config, because choosing a framework, inventory, target or database driver is
  detection. `Framework.Zones.Enabled` stays. Config keys do not warn.
- `GetKnownTargets`, `RequestInventorySync`, `RequestLockDoors` and
  `RequestUnlockDoors` warn under their own names, so they warn even when no
  provider is registered behind them.
- The `security`, `ui` and `discord` slots and the generic registry are not
  deprecated. Registering a deprecated slot from another resource also warns
  once. The types file marks every deprecated export and proxy
  `---@deprecated` with its replacement.

### Fixed

- The restrictive-posture warning printed
  `Security.AuthorizedResources is empty` twice in a row, as the reason and
  again in the explanation. It prints it once.
- **Security: a bad net payload is reported again after a pause.** The
  report was once per player and event for the whole connection, so a
  security provider that bans after N strikes never saw strike two. A run
  of bad payloads now ends after max(5000, 2 * windowMs) ms without one, and
  the next is a new report; a flood that keeps going is still one report.
- **Security: net events had no payload bounding** (only the first
  argument's schema), and `+inf`/`-inf` passed any schema rule without a
  `max` or `min`. Both are refused now; see **Changed**.
- **`mathx.toHex(math.mininteger)` looped forever**: `-n` wrapped back to a
  negative number. The magnitude is now taken in floats, so Lua 5.4 refuses
  it as beyond 2^53.
- **`CisRandom.integer(0, math.maxinteger)` always answered 0**, and the
  full integer range always answered `math.mininteger`: `hi - lo + 1`
  wrapped. The count no longer trusts the subtraction.
- **A scaleform call with an unknown explicit type sent a half-built call**
  and answered true. Every parameter is now typed before the method begins.
- **`'closest' .. nil` raised** when a world query had no kind; the kind is
  now checked first and refused by name. Queries no longer allocate a table
  per candidate entity.
- **A ready waiter read `Cis.isReady` as false**: the flag was set after the
  waiters ran.
- **A configured framework such as `ND_Core` was looked for as `ND_CORE`.**
  The name is compared in upper case; the resource is asked for as spelled.
- **`GetClosestPoint` raised on a player position with no z**; it is now
  refused with a reason.
- **A zone created inside `onEnter` was inserted into the grid bucket being
  walked**, which can skip zones or raise. Zone edges now run after the walk.
- **A point or zone at an infinite coordinate hung the client.** The grid
  walked `for x = -inf, inf` forever; coordinates beyond ±2^21 also
  collided in the cell key. The grid refuses bounds beyond 100 km, and its
  cell cap is NaN-safe.
- **A NaN streaming timeout polled for the rest of the session**, because
  `now >= NaN` is never true.
- **A hook that removed itself, or registered another, mid-run shifted the
  walk** and skipped the next hook. Hook lists are now copy-on-write.
- **`HookOn('')` answered a cookie**; it now answers `false` plus a reason.
- **Tests:** eight mutation rows no longer matched the source they mutate;
  they are re-anchored and killed. The lua54 driver now fails a suite that
  exits early or runs no assertion, and compares each suite's assertion
  count with the fengari run. `tools/mutate.js` gained a `lua54` check.

- A `'resource:export'` callback whose export was missing raised past the
  in-flight release: after eight such requests the player got `busy` from
  every callback until they reconnected. The lookup is guarded, the slot is
  always released, and a slot held past three timeouts is reclaimed.
  `TryAwaitCallback` no longer raises on it, and the client answers instead
  of leaving the server to time out.
- An idless sync upsert could generate an id an explicit record already
  had, and replace it. A networked spawn that timed out left its entity
  handle behind.
- An enter handler that removed a zone aborted the server zone pass for the
  remaining players. `/GIVE` passed `GIVE` as the first argument; an
  apostrophe opened a quote (`I'm` became `Im`).
- A saved vehicle with a window rolled down came back with that window
  removed: `IsVehicleWindowIntact` is false for both. The getter now rolls a
  not-intact window up, records it only if it is still not intact, and rolls
  it back down.
- `Points:add` returned an id for a point the grid refused (NaN coords, or a
  radius of about 1,780 m and up); `onEnter` never fired. It is refused with
  a reason now.
- Re-creating a zone with bad geometry destroyed the live one before the new
  one was validated. A non-number `insideInterval` raised; it is refused.
- Cached weapon attachments went stale on the same weapon; they are re-read
  every second while it is held.
- DUI texture dictionary names restarted at 1 after a consumer restart and
  reused a destroyed browser's dictionary; each load now has its own tag.
- Including `init.lua` twice built a second engine set whose zones could not
  be removed. `Cis.require` from two threads at once reported a false
  circular dependency; the guard is per coroutine and a second thread waits.
- `RequestWeaponAsset` was asked with p1 = 0 (31, as the native docs and
  ox_lib); `HaveAllStreamingRequestsCompleted` was called without its ped; a
  fractional streaming or raycast timeout raised on `%d`.
- The point pass allocated a closure on every discovery refresh; its grid
  visitor is now file-level, like the zone visitor.
- Every centred NUI panel (top and bottom toasts, centred text UI, progress,
  skill check) sat half its size off centre in FiveM: the standalone
  `translate` / `rotate` properties are Chromium 104, and CEF is 103. They are
  `transform` now, and `test/web/compat.test.mjs` fails on any CSS or JS
  feature newer than 103.
- A dialog closed on submit before Lua answered, so a refused or lost answer
  left focus and the cursor over nothing; it now closes when Lua says so, and
  gives focus back to what had it.
- A date like 2024-02-30 was accepted as 1 March.
- `AddRadialItem` with a list that passed the 64-item cap added part of it.
- The radial menu let Space jump through a click; the list menu closed on the
  right mouse button (control 177 is also RMB); a held Escape closed every
  layer at once.
- `ProgressBar` with an animation dictionary the game does not have froze the
  ped for the whole load timeout; it now skips the animation and logs the
  name. A progress started before the page loaded ran with nothing on screen;
  it now waits for the page, like the dialogs. The bar's `aria-valuenow`
  stayed at 0.
- A click on a link inside a context option also picked the option.
- `AwaitCallbackClient` hung forever when the target player dropped.
- Points never fired (the thread ran once); a stopping resource removed other
  resources' points; world queries used pool names that do not exist and
  returned nothing; keybinds, cache listeners, commands, hooks, statebag
  watchers and sync spawn hooks refused handlers from other resources.
- Statebag watchers handed the bag's netId to handlers as an entity, so they
  never fired on clients.
- Networked sync records lost their netId on update, so clients spawned and
  leaked their own networked copies; driven vehicles were teleported back;
  client retries never stopped; removals were broadcast per record to every
  player.
- Rotated box zones were cut off by an unrotated bounding box; scaleform
  requests always timed out; `DrawText3D` drew no text; raycasts hit the
  player's own ped and read status codes wrongly; help text split UTF-8.
- Diagnostics probes registered for both realms never ran.
- `Cis.require`: a circular require raised a stack overflow naming nothing; it
  now raises at once with the chain. `Cis.moduleInfo` handed out the loader's
  live `deps` list. `Cis.require('lru')` was typed as `table`.
- `Cis.waitFor` raised on a fractional `timeoutMs` (`%d` in Lua 5.4).
- `interp` and `curve` answered zeros for FiveM `vector2/3/4` points.
- `curve`: centripetal (alpha > 0) Catmull-Rom tangents lacked the knot
  scaling; they now match Barry-Goldman.
- `interp.moveTowardsVec3` never moved a 2D point; `smoothDamp` raised on a
  negative `maxSpeed`.
- `lru.each` looped forever or indexed nil when the callback called `get`,
  `remove` or `clear`.
- `rate`: a sliding-window key whose first call was refused raised on its next
  call.
- `random.sample(list, 2.5)` returned the whole list.
- `window.newDedupe` raised sub-second windows to one second; `window` stats
  mishandled negative timestamps.
- `sparse.clear` (soft) kept references to every former member.
- `id.uuid` raised on a `CisRandom` generator object.
- `json.decode` read a codec's `nil, err` (or dkjson's `nil, pos, err`) as a
  successful JSON null; `json.checkEncodable` and `table.findCycle` /
  `deepMerge` were exponential on shared subtables.
- `table.keys`/`values`/`each` invented or lost keys on arrays with holes;
  `table.sortBy` was not stable with a boolean comparator; `table.depth`
  could miss the deeper route to a shared table.
- `time.relative`/`formatDuration` and `validate` length/entry bounds raised
  on `%d` of a huge or fractional number; `validate.isInteger(math.huge)` was
  true.
- CI: both workflows used `runs-on: ${{ env.RUNNER }}`, which GitHub cannot
  evaluate, so neither could start. They now pin `ubuntu-24.04`, run with a
  read-only token (release: `contents: write`), and `tests` no longer runs
  twice for each commit on a pull-request branch.
- `npm run test:lua54` exits non-zero when no interpreter is found and `CI` is
  set (it skipped with exit 0).
- `npm run lint` failed on Windows when luacheck sat under a path with a
  space (`C:\Users\First Last\.cis-devtools`): the shell split it.
- `npm run package` builds a reproducible zip: fixed timestamps, entries in
  name order, verified by building twice.
- `.luarc.json` declared LuaJIT; FiveM runs CfxLua 5.4.
- `npm run live:deploy` died with a ReferenceError when `.live-env.json` had
  no `libDir`. The live tools also read `CIS_LIVE_ENV` / `CIS_LIVE_*`
  environment variables, and `console-bridge` can start a Linux FXServer.
- **The test suites no longer contain assertions that cannot fail.**
  `check(env.EXPORTS and true or true, ...)` in the client suite and
  `check(true, ...)` in the contracts suite are replaced by real checks: the
  client suite asserts that a networked record is not tracked as a local
  spawn, and the contracts suite binds `SecureNetOn` with
  `{ maxHits = 1, windowMs = 1000 }`, fires the event twice and requires that
  exactly one call got through.
- **A failing server-suite check is reported once.** The server suite printed
  its `FAIL` lines in the middle of the run and again at the end, so one
  failure counted as two. Only the final report prints them now.
- **The test preload order is the manifest's order.** `histogram` and `ready`
  were swapped and `shared/statebag.lua` was never preloaded. Both runners now
  end with the statebag file, load it with the natives it needs stubbed and
  restored, and stop with a diff if their list ever differs from
  `shared_scripts` in `fxmanifest.lua`.
- **`tools/lint.js` removes its temp copy of the tree.** It called
  `process.exit` inside `try`, so the cleanup never ran and every run left a
  `cis-luacheck-*` folder in the temp directory, on success and on failure.
- **`tools/syntax-check.js` parses the files it used to skip.** It gave up on a
  whole file at its first FiveM backtick hash literal or Lua 5.4 attribute, so
  `client/cache.lua` was never parsed and a real error after a hash literal went
  unseen. It now blanks only those constructs, with text of the same length,
  and parses the rest on its real line numbers. Its header no longer claims
  that CI runs `luac`; CI does not.
- **`tools/docs-check.js` reads every document and every export spelling.** It
  read five files and missed `exports.cis_libs:<Name>`, the form
  `DOCUMENTATION.md` uses 33 times. It now checks the live-test runbook and the
  unrun list in full, checks every other markdown file (`docs/archive`,
  `docs/handoff`) for broken links and anchors, recognises both export
  spellings for `cis_libs` only, and uses GitHub's anchor rule (each space a
  hyphen, underscore kept). The two links in `docs/archive/DOCUMENTATION-1.x.md`
  that pointed at a `LICENSE.md` that is not there now point at the real file.
- **The mutation gate no longer counts a crash as a kill.** `tools/mutate.js`
  treated any non-zero exit as "killed", including a runner that could not
  start, a signal, a timeout, or a crash before any test ran. A mutation now
  counts as killed only when the output shows a test failure; anything else is
  an `ERROR` row and fails the build. Two rows with the same id in
  `test/mutations.json` are refused.
- **The README examples are run.** Every `lua` fence in `README.md` and
  `DOCUMENTATION.md` is tagged `lua example` and executed by `test/examples.lua`
  against the real `init.lua`. The manifest snippet is compared with the real
  manifest, the `SetConfig` snippet must pass `CisDefaults.validate`, a
  `-- true` or `-- false` comment on a `local` line is asserted, and a new
  untagged fence fails the suite.
- **`README.md` and `test/live/RUNBOOK.md` say what CI runs.** The stubbed tier
  runs on every pull request, every push to main and nightly. The live server
  job is started on those events but skips, because the `FIVEM_LICENSE_KEY`
  secret is not set, so CI does not exercise that tier yet.
- `mathx.round(0.49999999999999994)` returned 1; it returns 0. The result
  of `round(1.5, 400)` was NaN and `round(1e308, 1)` was infinity; both
  return the value (A-M2).
- `mathx.approx` no longer calls an infinity equal to a huge finite number or
  to its opposite, and compares integers as floats so `approx(maxinteger, -1)`
  is false instead of wrapping to a tiny difference (A-M3).
- `string.levenshtein` with a ceiling returned the true distance when only the
  last cell was above it, and ignored the ceiling against an empty string. It
  returns ceiling + 1 in both (A-L1).
- `lru.removeWhere` raised when its predicate removed the entry it would visit
  next, or the one it was asked about (A-L3).
- A late `window.record` no longer moves the newest bucket backwards, which
  made live samples read as expired (A-M6).
- `array.sum` leaves the integers instead of wrapping once a sum passes the
  integer range, and `array.flat` keeps a table that contains itself as an
  element instead of overflowing the stack at an unbounded depth (A-L7).
- `window.clear` on a ring of infinite capacity returns; it walked every slot
  (A-L8).
- The seeded generator redraws up to 64 times instead of 8 before it folds a
  rejected draw. After 8 rejections the fold put roughly 1 draw in 512 of a
  half-period range on the top value (A-L14).
- The page's `notify:clear` handler is gone: nothing ever sent it (NUI-L11).
  A test now holds every page handler to an action Lua sends, and the reverse.
- A select or multi-select in an input dialog is named by `aria-labelledby`;
  its `<label for>` pointed at a div, so the listbox had no accessible name
  (NUI-L12).
- A context menu opened over a dialog paints above the dialog's backdrop, and
  a dialog opened from a context option paints above the menu: the two layers
  stack in the order they opened, not in document order (NUI-L5, page side).
- The page bundle test rejects a root-absolute or remote path in index.html
  (its rule let `/style.css` through) and fails on any `backdrop-filter`
  (NUI-N3).
- **Tooling.** The mutation gate no longer counts a `lua54` row as killed when
  the Lua 5.4 interpreter is missing (it reports an error), and the CI `mutate`
  job installs `lua5.4`. Rows M159, M332 and M426 are re-anchored. The suite
  driver fails a suite that ran no assertion (`passed=0`). `validate-api` compares
  versions numerically and refuses a `since` above the package version (E014);
  `api.lua` names the next release in `unreleased` so the entries that say
  `since = '1.1.0'` stay valid before the version bump. A vacuous `check(true)`
  in the contracts suite is a real assertion. The hooks documentation says a
  hook takes a callable or a `'resource:Export'` string, never an event name.
- Added `docs/MIGRATING-FROM-OX_LIB.md`, mapping ox_lib calls to the `api.lua`
  entries that do the same job.
- Re-registering the context menu on screen redraws it under a new token. The
  page kept showing the old options, and a click on index n ran the new list's
  option n.
- `RegisterContext` with a list is all or nothing: a bad entry no longer leaves
  the entries before it registered behind a `false`.
- `WatchNear` refuses coords without finite numeric `x`, `y` and `z`, a
  distance that is not a finite number above 0, and a non-string event name,
  with `nil` plus a reason. A string distance used to raise inside the shared
  near tick, and every watcher after it was never checked again; each watcher
  is now also checked in its own `pcall`.
- A zone or point removed while the player is inside hands `onExit` a
  `vector3`, as every pass exit does. It handed a plain table, so vector maths
  in the handler raised.
- Point enters run after the grid walk. An `onEnter` that created or removed a
  point changed the bucket being iterated (zones already queued their edges).
- `UpdateTarget` checks before it removes, and keeps the target's owner. It
  removed the old target and then created the new one with nothing between,
  so a provider that refused the new options (or no provider at all) left the
  caller with no target and a bare `false`. Now an unknown name, bad options or
  a missing provider answer `false` plus a reason with the target untouched, a
  refused create puts the old target back, and cis_libs updating a consumer's
  target no longer takes it from that consumer.
- **The spatial grid no longer raises on an AABB without z bounds.** `CisGrid.queryPoint` and
  `queryNeighbors` compared a caller's z with `aabb.minZ` and `aabb.maxZ` even when the AABB left
  them nil (which `insert` allows, and documents as "no z test"), so a 2D or half-open AABB raised
  the first time anything queried its cell with a z. A nil bound is now skipped. `insert` also
  checks each z bound on its own: a non-number z bound and `minZ > maxZ` are refused with a reason
  (a string bound used to be stored and then raise on every query of its cell).
- **The loop guard no longer builds a table every tick.** `CisLoopGuard.Body`, which wraps the
  cache, zone and point passes every frame, packed each result into a new table only to unpack it;
  the results now pass straight through. Return values (nil holes included) and the nil after a
  raise are unchanged, and now tested.
- **A UI the page refuses no longer strands the player.** `I.send` answers `false` and a reason
  when the page does not take a message (one NUI message is capped at 1 MiB). The alert, input,
  context, radial, list menu, skill check, progress and text UI openers ignored that answer, so an
  over-cap open kept NUI focus, keepInput or a control-disabling thread for a component nothing
  drew. Each now fails the open: focus and threads are released, an anim or props already started
  by a progress are undone, and the caller gets `false` (or `nil` for the dialogs) and a reason.
- **No hang on `math.huge`.** `set.new({ n = math.huge })`, `array.from` with
  an infinite count or `n`, `id.draw(math.huge)` and `curve.newPath` with
  `samples = math.huge` looped forever. An infinite or NaN `n` is not a length
  (`#t` is used), samples per segment are capped at 1024, and a NaN
  `samples` or `alpha` falls back to the default.
- **`table.deepCopy` and `array.flat` walk with an explicit stack**, so a
  200k-deep (non-cyclic) chain copies or flattens instead of overflowing the C
  stack. Cycles and shared tables are still copied once.
- **`string.levenshtein` with a ceiling walks only the 2 * cap + 1 diagonal
  band** (Ukkonen), so two long strings no longer cost the whole table.
- **Rolling windows refuse an infinite timestamp and a nil or NaN key.** One
  `record(s, k, v, math.huge)` blocked the key for good; `seen` and `record`
  raised "table index is nil". `newStats(math.huge)` falls back to 60 s.
- **Weighted picks survive finite weights that overflow.** Weights such as
  `{ 1e308, 1e308, 1 }` summed to infinity, and one entry won every draw; they
  are rescaled by the largest weight.
- **`interp` keeps NaN and infinity out of its answers.** `clamp01(NaN)` is 0,
  `wrap`/`wrapAngle` of infinity is the range start, `moveTowards` with a NaN
  step stays put, and `normalize`/`clampLength` handle a component whose square
  overflows.
- **`time.roundTo` no longer wraps** an integer product negative (or to 0 in
  a 32-bit build), and an infinite or NaN unit answers 0, not NaN.
- **`locale.t(nil)` answers `"nil"` and warns** instead of raising.
- **`RateOk` answers `false, reason` instead of raising**, for a nil, NaN or
  empty src, a nil name, or a `windowMs`/`maxHits` that is not a positive
  finite number (`maxHits` at least 1). A refused hit carries `'limited'`.
- **Rate keys that are not connected players are bounded.** playerDropped
  never freed a license string or a stale id, so a consumer's dynamic keys
  grew the limiter for the life of cis_libs. Idle ones are swept, and past
  1024 live ones a new key is refused with `'cap'`; a connected player is
  never refused for that bound.
- **A callback's bad payload is reported once per run, like a net event's.**
  Every schema refusal used to be a security report, so a client repeating
  one bad shape was a strike per request with a ban provider.
- The server console is rate-limited per message, as Discord already was. One
  message prints at most 20 times per 10 s window and the window prints at most
  500 lines in all; held copies are counted and said once as the window rolls,
  so a client tripping the same warning every frame no longer floods the
  console. At most 512 distinct messages are tracked per window.

### Security

- **A player can no longer hijack a networked sync record through its state
  bag.** The owning client of a networked entity can write that entity's
  `cis_sync` bag, and every client took any such bag at face value: a modded
  client could put a real key on its own ped, evict the real record on every
  client, make `GetSyncedEntity` return its entity and run spawn hooks with
  its value. The server now announces each networked key's network id
  (`cis_libs:client:syncNet`) and a client accepts the bag only on that
  entity; a cleared or garbled bag no longer untracks anything. The server
  also watches the bag, puts its own value back over any write it did not
  make (clears one it never wrote), logs once per player per minute and backs
  off a client that keeps writing. `Diagnostics` counts these as
  `syncRecords.forgedBags`.
- **Every GitHub Action is pinned by full commit SHA**, with the tag it came
  from in a trailing comment, in `tests.yml` and `release.yml`. A moved or
  compromised tag can no longer change what runs.
- **Checkouts keep no credentials** (`persist-credentials: false`), so no token
  sits in `.git/config` while `npm ci` and the tests run, and the only job
  with write permission runs no repository code.
- **Releases carry a `SHA256SUMS` asset** and cannot be built from a tag that
  is not on main.
- **A client's reply to a server-to-client callback must carry a boolean
  `ok`.** A truthy string, number or table in its place resolved the call and
  reached the caller unbounded as its first value. It now reaches the caller
  as `false, 'bad reply'`.
- **NUI callbacks run in strict mode** (`nui_callback_strict_mode 'true'`):
  FiveM refuses a post to `https://cis_libs/<cb>` whose Origin is not this
  resource's own page, so another resource's frame cannot reach them at all
  (NUI-N1).
- **The page has a Content-Security-Policy**: only its own scripts and styles
  run, no object, no base or form target; images from `https:` and `nui:`,
  callbacks over `https:` (NUI-N1).
- **Page `error` and `warn` reports need the session token and are rate
  limited** (10 per kind per 10 s; the dropped count is logged once the window
  ends), with control characters collapsed. Any frame could post forged or
  endless lines into the client log (NUI-N2).
- **A local zone event from another resource must carry that resource's
  prefix.** With `local = true`, a zone created by `shop` may only fire
  `shop:...` events. Before, any resource could have cis_libs fire
  `cis_libs:cache` or `onResourceStop` locally with cis_libs as the
  invoker, which the cache mirror and the stop guard both trust. Event names
  are now strings of 1 to 128 bytes.
- **`HookRemove` only removes the caller's own hooks** (cis_libs may remove
  any). Hook ids count up from 1, so a loop could strip every veto.
- **A net event's owner is always the caller.** `SecureNetOn` refuses a
  resource that binds another resource's export (`'bank:Withdraw'` from
  `thief`). The rate limit runs before the schema, and a bad payload is
  reported once per player and event per run of them, not once per event.
- **Net event payloads are size-bounded, like callbacks.** Before the schema
  and the handler, `SecureNetOn` refuses more than 32 arguments, a string
  (key or value) longer than `Config.CallbackLimits.MaxStringLen` (4096),
  more than 256 table entries across the payload, or nesting deeper than 8.
  A handler may set its own `maxArgs`, `maxStringLen`, `maxEntries` and
  `maxDepth`; a malformed one refuses the registration. An oversized
  payload is counted as `netSchemaRefused` and reported like a schema
  failure. Callbacks and net events share the one walker.
- **Server callback names are owned.** `RegisterCallback` refuses a name
  another resource holds (cis_libs may replace any).
- **`CommandAdd` refuses a name the server already knows**, another
  resource's command or a builtin (matched without regard to case), and a
  re-add that changes `restricted`. cis_libs provisions `add_ace` only for
  `group.*` principals; `builtin.everyone`, `player.*` and `identifier.*` are
  printed for the operator instead.
- **Door mutators (`BreakDoor`, `FixDoor`, `LockDoors`, `UnlockDoors`),
  `PublishPlayerLoaded` and `SetDropPlayerHandler` are allow-list gated**, like
  their siblings. A refusal keeps the old return shape plus a reason.
- **`KeybindAdd` refuses a name whose `+name` command another resource
  registered** (or a builtin, in any case). Each consumer's engine only saw
  its own bindings, so two resources could both bind `menu`.
- **NUI ids and tokens are opaque strings** (a counter plus 60 random bits).
  Any frame can post to `https://cis_libs/<callback>`, and ids counted from 1,
  so another resource's page could answer an open dialog.
- **Pending callback keys are opaque string tokens** (a counter plus 60
  random bits), on both realms. `CallCallbackClient` / `Cis.callback.callClient`
  return one where they returned an integer; it is only ever echoed back.
- **A forged `onResourceStart` replayed a consumer's records.** Any script can
  fire `onResourceStart` with `'cis_libs'` as its argument. Before, each
  consumer then re-registered every capability, net handler and hook onto the
  running cis_libs. Now a replay needs a real cis_libs stop first, and both the
  stop and the start must come from the engine. One real stop allows one replay.
- **A callback request's key was echoed back unbounded.** `cis_libs:cb` sent
  the client's key straight back in its reply, so a 32 KiB key came back as
  32 KiB. A key must now be a number, nil or a string of at most 64
  characters; any other key gets no reply.
- **Exploitable:** with the documented `add_ace resource.cis_libs
  command.add_ace allow` grant, any resource could have cis_libs run
  `add_ace builtin.everyone command.<any> allow`, opening another resource's
  admin command, or a builtin, to every player.
- **Exploitable:** any resource could replace another's net binding by naming
  that resource in a `'resource:export'` string, stripping its schema and
  rate limit; and could replace another's server callback by name.
- **Exploitable:** a net event handler was registered again on every consumer
  restart, so one client event ran N+1 times. The rate limiter counted window
  rolls as buckets and locked active players out of new events for the
  session.
- **Exploitable:** any client resource could forge the client's
  `cis_libs:cb`, `cis_libs:cb:res` and `cis_libs:client:syncBatch` with a
  local `TriggerEvent`: run a consumer's client callback with its own
  arguments, answer every in-flight `Cis.callback.await` (keys counted from 1)
  with its own data, and spawn or delete synced entities. All three now
  require a server `source`, and the batch number must be an integer in
  1..2^31-1, so one forged batch can no longer pin a key above every real one.
- **Exploitable:** `TriggerEvent('onResourceStop', 'victim')` from any
  client script released the victim's zones, points, keybinds (for the
  session), targets, client callbacks, cache listeners, near watchers,
  statebag watchers, hooks, NUI focus and capability slots, and destroyed a
  consumer's DUIs and scaleforms; naming `cis_libs` despawned every synced
  entity. Every client stop handler (16, plus the consumer-side ones in
  `init.lua` and the cache mirror) now ignores a stop that another script
  triggered: a real one has no script below the handler, so
  `GetInvokingResource()` is nil. `GetResourceState(name) == 'stopping'`
  cannot tell them apart — FiveM still reports `started` during the event.
  Server handlers are unchanged: a txAdmin restart arrives from a script.
- Any client resource could take over another's client callback name
  (`RegisterCallback` replaced it) and remove any resource's near watcher
  (`RemoveNearWatcher` had no owner check, and ids count from 1). Both now
  refuse a foreign owner with `false, reason`; the client `RegisterCallback`
  returns its reason on every refusal (was a bare `false`).
- **Exploitable:** any resource's page could drive the cis_libs NUI. A
  `postMessage` into its frame drew a fake dialog or stopped a skill check (the
  page now takes messages only from the NUI root), and a fetch could confirm
  an alert, pick a context or radial option, fill an input dialog or pass a
  skill check by counting ids from 1.
- **Exploitable:** the NUI's `escape` and `ready` callbacks carried no token,
  so any frame could cancel the top dialog through `escape`, or reset and
  close every open component through `ready`. The page now gets a session
  token from Lua in a handshake (a tokenless `ready` is answered with a
  `hello` only the cis_libs page receives, and only the `ready` that echoes
  it is acted on), and every Escape carries it. A page that has loaded
  ignores a later `hello`, so a forged `ready` cannot make it reset.
- **A context menu option can no longer fire a reserved or foreign event.**
  An option's `event` is fired from the cis_libs VM, so every handler saw
  cis_libs as the invoker: an option firing `onResourceStop` with
  `'cis_libs'` passed `CisRealStop` and every consumer marked the library
  stopped. `RegisterContext` now refuses an `event` that lacks the
  registering resource's own `<resource>:` prefix, is over 128 bytes, or is
  `onResourceStart`/`Stop`/`Starting`, `onClientResourceStart`/`Stop` or any
  `cis_libs:` or `__cfx_` name; the click checks again. Fire any other event
  from `onSelect`. `serverEvent` is unchanged.
- **A context id belongs to its registrant.** Another resource registering the
  same id got the menu silently; it now gets `false, 'context "<id>" is
  registered by <res>; pick a different id'`. The id is free once the holder
  stops.
- **Radial items and submenus belong to their registrant.**
  `RemoveRadialItem` and `ClearRadialItems` had no owner check, and
  `AddRadialItem` / `RegisterRadial` replaced another resource's same id, so
  any script could strip or swap every resource's entries. Adding or
  registering a held id now answers `false, 'radial item "<id>" is registered
  by <res>; ...'`; `RemoveRadialItem` answers `false` plus a reason for an
  unknown or foreign item (it was a bare `false`); `ClearRadialItems` removes
  only the caller's own items. cis_libs itself may still remove or clear
  anything.
- A forged `TriggerEvent('onResourceStop', 'victim')` from another server
  resource no longer releases the victim's capability slots, net handlers,
  callbacks, commands, server zones, sync records, hooks or state bags (a
  forger could then register into the slot the victim held). A stop counts at
  once when the engine fired it, the resource stopped itself, cis_libs fired it,
  or the invoker holds `command.stop`; any other invoker's stop counts one tick
  later, and only if the resource is no longer `started`. Limitation: an
  untrusted script that stops and restarts a resource in the same tick leaves
  the old instance's records in place until its next stop.
- `CommandAdd` no longer takes back an ACE it did not grant: when the restricted
  group already holds `command.<name>` (the operator's own `add_ace`), cis_libs
  neither re-writes it nor runs `remove_ace` on it when the command is removed.
  It also provisions only the groups listed in the new convar
  `cis_command_ace_groups` (default `group.admin`), so a resource calling
  `CommandAdd` can no longer have cis_libs grant its command to `group.user`;
  any other group gets a warning and the exact `add_ace` line to run.

## [1.0.0] — 2026-10-07

First public release. There is no earlier published version. Where an entry
below says "before 1.0.0", "used to" or "gone", it compares against the
unpublished development builds described in `docs/archive/DOCUMENTATION-1.x.md`,
for anyone who ran one of those.

### Licence

- Replaced MIT with the Cisoko Community Source & Identity License 1.0.
  Commercial servers may use and modify `cis_libs`. The folder name must stay
  `cis_libs`. Rebranding, authorship claims, and disabling the identity check
  are forbidden.
- Boot refuses a folder name other than `cis_libs`: `shared/identity.lua` first
  in `shared_scripts`, plus copies in `server/initialize.lua` (calls
  `StopResource`) and `client/initialize.lua`. Not in `init.lua` — that file is
  injected into consumers, where `GetCurrentResourceName()` is the consumer.
- Corrected the platform spelling to Cisoko.

The development builds' alias exports are not in 1.0.0: `Database*`, `GetFramework`, `GetGlobals`,
`GetPolyzones`, `CreateSafeCallback`, `CheckResourceVersion`. Use `DbQuery` /
`Cis.db.*`, `GetNormalizedPlayer`, `Cis.player.*`, `Cis.zones.*`,
`Cis.callback.register`. Door exports (`GetDoorState`, `LockDoors`, …) stay;
`Cis.doors.*` forwards to them.

### Behaviour

**An empty `Security.AuthorizedResources` is always restrictive. There is
no legacy exception, and nothing is classified, inferred or written to disk.**

Before 1.0.0 the empty list was resolved by asking the server about
itself: a marker file inside the resource folder, and a `dataProbe` capability
that reported whether the installed database held rows. A populated store meant
"legacy", i.e. permissive — so a resource that merely *had* a database was
granted the right to add, break and rewrite every door on the server.

Three separate ways that went wrong:

- **An update silently downgraded security.** The marker lived inside
  `cis_libs/`, which is exactly where an update puts a new version. Replacing
  the folder deleted the operator's own record of their restrictive decision,
  and the missing file was then read as "nothing recorded" — so the install
  fell through to permissive. A restrictive install became permissive because
  it was *upgraded*.
- **The decision depended on somebody else's latency.** The `dataProbe` thread
  left the posture undecided for up to 30 seconds while a database answered,
  and undecided meant permissive. A store that was merely slow unlocked every
  door for half a minute on every boot.
- **A marker carrying the wrong flag was read as evidence of history.** Presence
  was read as "a written config exists", which meant legacy, which meant
  permissive — so the restrictive boot wrote a file whose presence made the
  *next* boot permissive.

The posture is now a pure function of the operator's own configuration, decided
at load. `cis_libs` writes no files and asks nobody.

#### Migrating

Nothing is required. A server that already configured
`Security.AuthorizedResources` is unaffected — an explicit list behaves exactly
as it always has.

A server that relied on the legacy/permissive path — that is, one with an empty
list and products mutating doors — will now see those refusals, and each refusal
names the resource and the exact key to add:

```text
cis_libs refused PublishJobUpdate from cis_migrate: add 'cis_migrate' to Security.AuthorizedResources
```

The old behaviour is still available, deliberately and loudly:

```lua
Security.AllowAnyResource = true   -- default false; warns on every boot
```

A named `AuthorizedResources` still governs when both are set, so the more
careful configuration is never the weaker one.

### Added

- **Bench honesty (task 8.4).** The heap row that was labelled `dequeue()` is
  `enqueue 50 then dequeue 50`. New rows: `CisZoneGeom.contains` per shape, and
  a 64-player × 200-record sync visibility pass against the grid vs a naive
  walk. `npm run bench` prints interpreter, date, and workload notes.
- **Pass timings on `GetDiagnostics()` (task 8.1).** `shared/timing.lua`
  (`CisTiming`) records `zonePass`, `serverSyncPass`, `clientSyncPass`,
  `callbackRtt` and `exportCrossing`. The snapshot sits on `timings`, a sibling
  of `probes`, so `CisDiagnostics.Diff` does not walk it and the live harness
  is not failed by a pass. `shared/histogram.lua` remains job counts.
- `Security.AllowAnyResource` — the opt-in escape hatch described above.
  Validated as a boolean, default `false`, warned about on every boot while on.
- `GetLastRefusal()` — the reason for the most recent capability refusal made by
  **this** resource. A read refusal answers `nil`, and a `nil` first value
  truncates the return list at the exports boundary, so `nil, reason` is a shape
  that structurally cannot deliver an explanation. The reason travels out of
  band instead; no existing return shape moves. Scoped per calling resource,
  and cleared by the next successful call.
- `cis_audit [n]` and a `GetAuditLog(n)` export (task 3.9).
- **Editor types for the whole public surface (task 6.3).** `types/cis_libs.lua`
  is now a generated LuaLS stub carrying a type for every parameter and return
  of every export **and every `Cis.*` proxy**, plus a class per record and
  options table. Before this it emitted `---@param x any` for all 258
  parameters, and declared nothing at all about the `Cis.*` surface — which is
  the half a consumer actually calls. A consumer adds one path to their
  `.luarc.json` `workspace.library`; see DOCUMENTATION.md §1. `.luarc.json`
  ships for contributors.
- **`Cis.require(name)` is typed as the module, not as `table`.** One
  `---@overload` per module, generated from the same `modules` block the
  loader's allow-list is checked against.
- **`Cis.points` (client).** `Cis.points.add({ coords, distance, onEnter,
  onExit, nearby })` returns a numeric id; `Cis.points.remove(id)`;
  `Cis.points.getClosest()`. Grid-indexed, with a 15% hysteresis band so a player
  standing on the boundary does not enter and exit every pass, and `nearby`
  running only while inside.

  The id is a number this library allocates and never reuses, so a stale id is a
  `false` refusal rather than somebody else's point vanishing, and two
  resources that both want a point near the same door get two points with no
  name collision to resolve. `coords` and `distance` are **required** and are
  refused by name when absent: a defaulted radius is a specific number nobody
  asked for. As with zones, a function option is dropped across the exports
  boundary; the event-name twins carry the point id and do cross.
- **`Cis.net.on` schema.** `opts.schema` checks the first payload table (type,
  min, max, maxLen). A bad payload is refused, counted `netSchemaRefused`, and
  reported through `Cis.security.report`. Without schema nothing changes.
- **Server-verified zones.** `Cis.zones.server.box/sphere/poly`, `contains`,
  `players`, `remove`. Same containment math as the client (`shared/zonegeom.lua`).
  Ped coords are server-side.
- **`Cis.hooks`.** `on` / `run` / `remove`. First veto wins; a raise is a veto.
  Released when the owning resource stops.
- **`cis_doctor`.** Restricted console command: self-check problems with fixes,
  slot owners, missing providers. No secrets, no player identifiers.
- **`Cis.player.seat()` and `Cis.player.playerId()`.** Seat was only the second
  return of `vehicle()` before; playerId was not a cache key. `Cis.player.on('seat', cb)`
  fires on a seat change. `mount` is RedM-only and is not a key: this game is gta5.
- **Vehicle `lockState` and `livery`.** GetVehicleDoorLockStatus /
  SetVehicleDoorsLocked, and GetVehicleLivery as a field separate from
  `modLivery`. 0 is a real lock state. The getter does **not** roll windows up.
- **`Cis.waitFor(fn, msg, timeoutMs)`.** Polls every frame until `fn` answers a
  value. `false` is "not yet". Timeout answers `nil, reason` and names `msg`;
  it does not raise. Default 10000 ms. NaN and infinity are refused — both
  would loop forever.
- **`Cis.ui` (client).** `Cis.ui.notify`, `Cis.ui.textUI.show/hide/isOpen`
  with native fallbacks (GTA feed and help text); `Cis.ui.progress`,
  `Cis.ui.confirm`, `Cis.ui.input` forward only and answer `false, 'no ui provider'`
  without a provider. cis_libs still ships no NUI. This is not
  `Cis.framework.notify`: that one is player-targeted, rate-limited, and the
  call a server uses to tell a player something. Help text is one global slot;
  `ClearAllHelpMessages` on hide clears every help message, not just ours.

### Fixed

- **`cis_force_unregister` was open to any player.** The console command that
  strips a capability was registered without FiveM's restricted flag and
  ignored its source, so any connected player could revoke `security`,
  `database` or `framework` out of their own chat. It is now restricted,
  refuses a non-console source, and audits the attempt.
- **One resource stopping wiped every resource's sync records.** The
  `onResourceStop` handler reset the record table, the content index and the
  per-player sets for *any* resource. The drop was silent — a table going empty
  sends nothing — so every client holding another resource's synced prop kept
  it permanently, owned by nobody and despawnable by nobody.
- **`NotifyClient` and `Notify` disagreed about safety.** `NotifyClient`
  refused `src` 0 and −1 with a bare `false` and no reason while the rate limit
  one line below refused with one, and fired at a server id nobody was
  connected to while reporting success. `Notify`'s no-framework fallback had no
  guards at all, so the bounded path was the rarer one. Both now share one
  guarded delivery.
- **A pending callback outlived what created it.** A server-to-client await
  aimed at a player who had already left parked the caller for the full callback
  timeout. `playerDropped` now rejects that player's awaits at once with
  `player dropped`, and `onResourceStop` drops the stopped resource's own
  entries.
- **The zone debug drawing called two natives that do not exist**
  (`GetGameplayCamCoords` and `DrawText`), so `DrawText3D` raised on first call.
- **`server/selfcheck.lua` read a doubled path with `io.open`**, so its
  dependency check had never once reported anything.

### Removed

- The install marker (`configs/install.json`) and everything that read or wrote
  it. See the behaviour change above.
- The legacy/permissive classification and the deferred `dataProbe` probe.
  `dataProbe` remains a registrable capability slot for compatibility — a
  product that registers it is not refused — but nothing asks it anything.

### Fixed — documentation

- `reportRestrictive` cited "COMPATIBILITY.md section 6", which does not exist.
  The fix is now stated inline.
- **`api.lua` did not declare the `Cis.*` surface at all.** One manifest line
  copies 988 lines of proxies into a consumer's Lua state, and nothing read
  them: the contract that was validated was the half nobody calls. `api.lua` now
  carries every proxy with its realm, its typed parameters and its return shape,
  and `tools/validate-api.js` compares it against `init.lua` in both directions.
- **A type naming a class nobody declared.** A typo like `CisSyncRecrd` reads as
  a real type in review and costs a consumer the completion without any error.
  The validator now fails on an undeclared class reference, and on a declared
  class that no type references.
- **A documented contract that was never true:** `CisDefaults.validate` answers
  a bare `true` on success, so its `@return` line claiming "an array of strings,
  empty when ok" sent a caller written against the documentation to `#problems`
  on a `nil` — on the one path that always succeeds.
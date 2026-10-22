# Changelog

All notable changes to `cis_libs`. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

The **contract** is versioned separately and is still `api = 1`.

## [Unreleased]

Correctness, security and performance work across every layer, plus a
first-party NUI. Several fixes change a documented answer; they are listed
under **Changed** so nobody upgrades into them blind.

### Changed

- **`CommandAdd` refuses a name the server already knows**, another
  resource's command or a builtin (matched without regard to case), and a
  re-add that changes `restricted`. cis_libs provisions `add_ace` only for
  `group.*` principals; `builtin.everyone`, `player.*` and `identifier.*` are
  printed for the operator instead.
- **A net event's owner is always the caller.** `SecureNetOn` refuses a
  resource that binds another resource's export (`'bank:Withdraw'` from
  `thief`). The rate limit runs before the schema, and a bad payload is
  reported once per player and event, not once per event.
- **Server callback names are owned.** `RegisterCallback` refuses a name
  another resource holds (cis_libs may replace any).
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
- **Door mutators (`BreakDoor`, `FixDoor`, `LockDoors`, `UnlockDoors`),
  `PublishPlayerLoaded` and `SetDropPlayerHandler` are allow-list gated**, like
  their siblings. A refusal keeps the old return shape plus a reason.
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
- **Pending callback keys are opaque string tokens** (a counter plus 60
  random bits), on both realms. `CallCallbackClient` / `Cis.callback.callClient`
  return one where they returned an integer; it is only ever echoed back.
- **Server zones belong to one routing bucket** (`opts.bucket`, default 0).
- **World queries exclude the local player** (and player peds from ped
  queries) unless `opts.includeSelf` / `opts.includePlayers`.
- **Vehicle properties follow ox_lib field names and semantics**, including
  `bulletProofTyres = not canBurst`, extras 0..20 and tyres 45/47.
  `SetVehicleProperties` no longer diffs against a snapshot and returns
  `false, reason` without network control.
- **`Cis.ui.*` uses the built-in NUI** when no `ui` provider answers; the GTA
  feed and native help remain only as a fallback when the NUI is not loaded.
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

### Fixed

- **Exploitable:** with the documented `add_ace resource.cis_libs
  command.add_ace allow` grant, any resource could have cis_libs run
  `add_ace builtin.everyone command.<any> allow`, opening another resource's
  admin command, or a builtin, to every player.
- **Exploitable:** any resource could replace another's net binding by naming
  that resource in a `'resource:export'` string, stripping its schema and
  rate limit; and could replace another's server callback by name.
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
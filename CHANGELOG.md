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

### Fixed

- **Exploitable:** a net event handler was registered again on every consumer
  restart, so one client event ran N+1 times. The rate limiter counted window
  rolls as buckets and locked active players out of new events for the
  session.
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
- `npm run package` builds a reproducible zip: fixed timestamps, entries in
  name order, verified by building twice.
- `.luarc.json` declared LuaJIT; FiveM runs CfxLua 5.4.

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
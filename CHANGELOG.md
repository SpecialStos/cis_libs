# Changelog

All notable changes to `cis_libs`. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

The **contract** is versioned separately and is still `api = 1`.

## [1.0.0] — 2026-10-06

First public product version.

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

1.x alias exports are gone: `Database*`, `GetFramework`, `GetGlobals`,
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
  `.luarc.json` `workspace.library`; see DOCUMENTATION.md §4.9. `.luarc.json`
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
- **`Cis.ui` (client, ).** `Cis.ui.notify`, `Cis.ui.textUI.show/hide/isOpen`
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
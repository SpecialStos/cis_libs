# Delta Report 1 — §1 of the CIsoko build brief, verified against source

**Date:** 2026-09-29
**Subject:** `cis_libs` repository at `resources/[standalone]/cis_libs`
**Method:** everything below was extracted from source, not from `DOCUMENTATION.md`.
**Changes made:** none. This is a read-only audit. 48 uncommitted paths, exactly as found.

**Headline:** §1's *defect* list (§1.8) is accurate — all eight stand. §1's *state* chapter is
not: it describes a codebase that has never existed in a commit, and it instructs a subagent to
preserve a live bug.

---

## 0. The finding that reframes everything else

**There is no v1.0.0 in this repository. There is no released `cis_libs` here at all.**

`git log` is four commits, all labelled `v0.0.1` / `v0.1.0`:

```
0249976 v0.1.0   (2024-10-08)
b18f3d1 v0.1.0
53bb511 v.0.1.0
775d1f4 v0.0.1
```

The tree at `HEAD` contains `client/core.lua`, `client/polyzones.lua`, `server/server_error_handler.lua`,
`server/versionCheck.lua`, `sync/peds.lua`, `sync/props.lua`, `sync/vehicles.lua` — **none of which exist
in the working tree.** It has no `init.lua`, no `shared/` directory, no `server/callback.lua`, no
`server/security.lua`.

**27 of 52 Lua files have never been committed.** The entire architecture §1 describes — the `Cis`
proxy, the `shared/` modules, the callback system, the boundary model — lives only in an uncommitted
working tree.

`fxmanifest.lua` declares `version "1.0.0"`. That string is aspirational, not a release.

### What this means for the freeze

This directly answers the question of whether the `CallCallback` semantic change shipped silently.
**It never shipped in any commit** — `server/callback.lua` is untracked.

- It was not a silent commit. It was never committed.
- **The repository cannot tell us what broke whom.** The six escrow products consume some *release* of
  `cis_libs`; that artifact is not in this tree. The real-world trustworthiness of the existing compat
  shims is **unknowable from here** and must be checked against the actual shipped escrow bundle.
- §0.1's premise — "six escrowed products and ~2,000 deployed servers depend on current `cis_libs`
  behaviour" — is not verifiable from this repository. The freeze discipline remains correct, but it
  protects against *forward* breakage only, and **the freeze baseline itself is undefined** until
  someone identifies what actually shipped.

**Resolve this before Unit 0.1.** `COMPATIBILITY.md` is meant to document a frozen surface. A contract
derived from an unreleased working tree freezes nothing that any customer currently uses.

---

## 1. Public surface, enumerated from source

Extraction used the realm declared in `fxmanifest.lua` (14 client, 15 server, 6 shared scripts), not
filenames.

### 1.1 Exports — 52 server, 55 client

| Group | Server | Client |
|---|---|---|
| Callbacks | `RegisterCallback` `CallCallback` `AwaitCallback` `CallCallbackClient` `AwaitCallbackClient` `CreateSafeCallback` | `RegisterCallback` `CallCallback` `AwaitCallback` `TriggerLibCallback` |
| Database | `DbQuery` `DbSingle` `DbScalar` `DbInsert` `DbUpdate` `DbTransaction` `DatabaseExecute` `DatabaseFetchOne` `DatabaseFetchAll` `DatabaseInsert` `DatabaseUpdate` `DatabaseDelete` | — |
| Doors | `AddDoorToSystem` `AddDoorGroup` `GetDoorState` `GetAllDoorData` `LockDoors` `UnlockDoors` `BreakDoor` `FixDoor` | `AddDoorToSystem` `AddDoorGroup` `GetDoorState` `GetClosestDoor` `RequestLockDoors` `RequestUnlockDoors` |
| Sync | `SyncCreate` `SyncRemove` | `GetSyncedEntities` |
| Inventory | `InventoryAdd` `InventoryRemove` `InventoryCount` `InventoryHas` | `InventoryCount` `InventoryHas` |
| Target | — | `CreateTarget` `RemoveTarget` `UpdateTarget` `TargetExists` `TargetAvailable` |
| Zones | — | `CreateZone` `RemoveZone` `ZoneContains` `GetZoneDebug` `GetPolyzones` |
| Cache | — | `GetCachedPed` `GetCachedVehicle` `GetCachedWeapon` `GetCachedHeading` `GetCachedServerId` `OnPlayerCache` `WatchNear` `GetGlobals` |
| Framework | `GetFramework` `GetNormalizedPlayer` `GetOnlineJobCount` `Notify` | `GetFramework` `Notify` |
| Security | `SecureNetOn` `SecurityReport` `InvokingAllowed` `RateOk` `GetLibsPrefix` | — |
| Diagnostics | `GetConfigSummary` `GetDiscordQueueDepth` `GetLogging` | `GetClientConfig` `IsReady` `GetClientLogging` |
| Logging | `LogDebug` `LogInfo` `LogWarn` `LogError` `AutoLogError` | `LogDebug` `LogInfo` `LogWarn` `LogError` `AutoLogError` |
| Utilities | — | `Round` `RandomFloat` `GetTableSize` `GetDistanceBetweenCoords` `DrawText3D` `CreatePed` `DebugLog` `GetClosestVehicle` `GetVehicleProperties` `SetVehicleProperties` `GetPlayerVehicleSeat` `GetCurrentWeaponData` `RequestModelTimeout` |
| Misc | `WaitReady` `CheckResourceVersion` `SendDiscordLog` | `WaitReady` |

### 1.2 Net events

Registered (17):

```
cis_libs:cb                        cis_libs:client:toggleDoor
cis_libs:cb:res                    cis_libs:jobUpdated
cis_libs:cb:serverRes              cis_libs:playerLoaded
cis_libs:client:getData            QBCore:Client:OnJobUpdate
cis_libs:client:inventory          QBCore:Client:OnPlayerLoaded
cis_libs:client:showNotification   QBCore:Player:SetPlayerData
cis_libs:client:syncRemove         esx:playerLoaded
cis_libs:client:syncUpsert         esx:setJob
                                    qbx_core:client:onJobUpdate
                                    qbx_core:client:playerLoaded
```

Computed from the configured event prefix (5): `:doorlock:requestState` · `:doorlock:updateState` ·
`:doorlock:addDoor` · `:doorlock:addDoorGroup` · `:doorlock:doorBroken`

Event handlers (14): `gameEventTriggered` · `CEventNetworkPlayerEnteredVehicle` ·
`CEventNetworkPlayerLeftVehicle` · `onResourceStart` · `onResourceStop` · `onClientResourceStart` ·
`onClientResourceStop` · `playerDropped` · `ox_inventory:updateInventory` ·
`ox_inventory:openedInventory` · `QBCore:Server:PlayerLoaded` · `QBCore:Server:OnJobUpdate` ·
`esx:playerLoaded` · `esx:setJob`

### 1.3 Config keys read — 30

All confirmed present in `configs/master_config.lua`. **No `GetConvar` call exists anywhere in the
codebase.**

```
CheckVersion            CallbackTimeout         AimingCheckType
UpdateInterval.Player   UpdateInterval.Weapon   UpdateInterval.Vehicle
UpdateInterval.VehicleProperties
Framework.Type          Framework.Inventory     Framework.Zones.Enabled
Framework.Target.Enabled Framework.Target.Type Framework.Target.Debug
Framework.Database.Type Framework.Database.Collection
Doorlock.Enabled        Doorlock.Type           Doorlock.InteractableDistance
Doorlock.Persist        Sync.Enabled
Printing.Debug          Printing.UseDiscordLogs
DiscordConfig.DiscordLogsLinks  .Thumbnail  .FooterText  .FooterIcon
```

`UpdateInterval.Vehicle` and `UpdateInterval.VehicleProperties` are read by **nothing**. They are
documented as reserved and should be treated as reserved, not as API.

### 1.4 Discrepancies with DOCUMENTATION.md

**Three, all real. In all three the code is right and the doc is wrong.**

1. **Undocumented exports.** `IsReady`, `GetClientConfig`, `GetConfigSummary`, `InvokingAllowed`,
   `RateOk`, `GetDiscordQueueDepth`, `GetSyncedEntities` exist in code and appear in the boundary
   discussion, but are absent from the API reference surface listing.
2. **Undocumented net events.** `cis_libs:client:toggleDoor` is registered and never documented. The
   five `:doorlock:*` events are described in prose but their **computed-name** behaviour (derived
   from `Security.EventPrefix`, so a consumer cannot hardcode them) is not stated.
3. **Not a discrepancy — a confirmation.** `UpdateInterval.Vehicle` and `.VehicleProperties` are
   documented as "Reserved." Verified: no code reads them.

---

## 2. File tree and module layout

§1's assumed layout is **correct**, with one omission.

```
init.lua                    fxmanifest.lua
client/     13 files   (cache callback doorlock initialize inventory logging
                         streaming sync target utils vehicle weapon zones)
server/     10 files   (callback database discord doorlock initialize inventory
                         logging player security sync version)
framework/   2 files   (framework_client framework_server)
configs/     3 files   (discordLogs master security)
shared/      5 files   (config grid histogram pending ready)
```

37 library Lua files. **`shared/ready.lua` exists and §1 did not mention it.** It holds `CisReadyState`
and is *not* pure.

---

## 3. Stateful singletons — §1's list is wrong and under-counts

§1 named four. **There are twelve.** This matters more than any other correction in this report,
because the consumer-facing rule is "never `shared_script` this file" and §1's list is what a
subagent would print on that warning.

| File | Module-level state | In §1? |
|---|---|---|
| `client/cache.lua` | `CisCache` global, `listeners`, `nearWatchers` | ✅ |
| `client/zones.lua` | `zones`, `grid`, `inside` | ✅ (grid only) |
| `server/callback.lua` | `handlers`, `remotes`, `pending` | ✅ (keys only) |
| `server/security.lua` | `rates` | ✅ |
| `client/doorlock.lua` | `doors`, `doorGroups`, `addedTargets`, `grid` | ❌ **missing** |
| `client/target.lua` | `CreatedZones` | ❌ **missing** |
| `client/sync.lua` | `entities`, `records`, `spawning` | ❌ **missing** |
| `client/inventory.lua` | `counts` | ❌ **missing** |
| `client/callback.lua` | `handlers`, `pending` | ❌ **missing** |
| `server/doorlock.lua` | `DoorLock.doorStates` `.doorGroups` `.doorData`, `lastChange` | ❌ **missing** |
| `server/sync.lua` | `records` | ❌ **missing** |
| `server/player.lua` | `CisHistogram` store | ❌ **missing** |

**Safe to duplicate — genuinely pure, no state:**

- `shared/grid.lua` — pure functions
- `shared/config.lua` — pure functions
- `shared/pending.lua` — the store is passed *in* as an argument
- `shared/histogram.lua` — same; the store is passed in
- `shared/ready.lua` — **has** `CisReadyState` state, but duplicating it is harmless because a
  consumer's copy is only ever read, never marked ready

**Eight stateful files unmentioned in §1.** A consumer trusting §1's list could `shared_script`
`client/doorlock.lua` and end up with a second door index and a second target set.

---

## 4. Real dependency set

**`dependencies { '/onesync', '/server:4500' }` — no resource dependencies at all**, not even
optional ones. `fx_version 'cerulean'`, `game 'gta5'`, `lua54 'yes'`.

Runtime references to external resources — all optional, all guarded by `GetResourceState`:

| Resource | Refs | Used for |
|---|---:|---|
| `mysql-async`, `mongodb`, `oxmysql`, `ghmattimysql` | 41 | database driver selection |
| `ox_target`, `qb-target` | 20 | targeting bridge |
| `ox_inventory`, `codem-inventory`, `qb-inventory`, `qs-inventory` | 32 | inventory bridge |
| `qb-core`, `qbx_core`, `es_extended` | 20 | framework adapter |

**§1's "sole hard dependency is PolyZone" is wrong.** There is no PolyZone dependency, and there never
was in this tree.

**More importantly:** `client/target.lua` calls `exports.ox_target:*` directly (8 sites) and
`client/inventory.lua` / `server/inventory.lua` call `exports.ox_inventory:*` directly (10 sites).
These sit *outside* the `Cis.target` / `Cis.inventory` abstraction in a way no reader would expect
from the boundary model. They are genuine coupling seams and should be named as such in the
architecture.

---

## 5. Test harness

**§1.7's "There is no live test harness, no CI, and no conformance suite" is half wrong.**

**No CI.** `.github` does not exist. No `package.json` — `node_modules/fengari` is present but
**undeclared and uncommitted**, so a clean checkout cannot run the tests at all. No changelog file
exists anywhere.

**But a live harness now exists:** `cis_libstest`, a separate resource.

| Property | Value |
|---|---|
| Unit suite | `node test/run.js` — 105 assertions, no FiveM, ~2s |
| Loads | `shared/grid.lua` `shared/pending.lua` `shared/config.lua` `shared/histogram.lua` `cis_libstest/shared/report.lua` |
| Integration suite | 89 tests across both realms (39 server, 50 client) |
| Last run | 76 passed, 0 failed, 13 skipped |
| Report | JSON, written into the `cis_libstest` folder |
| Notable | teleport-driven zone enter/exit; JSON-encoder fuzzing; grid fuzzing against a brute-force reference |

**What the unit suite does not cover:** all 13 client files, all 10 server files, both framework files,
all 3 configs, and `init.lua` — roughly **3,400 of 3,900 library lines with zero unit coverage**. The
integration harness covers them, but it requires a live server and cannot run in CI as configured.

**Grid fuzzing is the strongest asset in the repo:** `queryPoint` and `queryNeighbors` are checked
against a brute-force reference over thousands of random points, which is what pins the property the
zones and doors depend on.

---

## 6. The eight §1.8 defects

| # | Defect | Verdict | Evidence |
|---|---|---|---|
| 1 | `CheckVersion` defaults `true`, fires outbound HTTP to a third-party GitHub Pages URL | **CONFIRMED** | `configs/master_config.lua:3`; URL at `server/version.lua:35`, appears exactly once |
| 2 | `AuthorizedResources` empty list allows any server-side caller | **CONFIRMED** | `configs/security_config.lua:5` ships `{}` |
| 3 | `Cis.db.transaction` on non-oxmysql fails at call time | **CONFIRMED** | `server/database.lua:245` |
| 4 | No capability registry | **CONFIRMED — absent** | no `registry/`; `dependencies{}` has no version syntax |
| 5 | No `Result` type; `nil` is ambiguous | **CONFIRMED — absent** | `nil` is still the failure signal across `Cis.db`, `Cis.doors`, `Cis.target` |
| 6 | Module-restart race unsolved | **CONFIRMED — absent** | no handle or liveness mechanism |
| 7 | No machine-readable contract | **CONFIRMED — absent** | no `api.lua` anywhere |
| 8 | No migrations, state layer, NUI, perf harness, observability | **CONFIRMED — absent** | `Cis.log` is still four print levels; `Doorlock.Persist` still creates `cis_doors` with no version table |

**Nothing to strike. All eight stand.** That is itself a delta: §1's defect list was accurate, and the
reason the brief reads as fiction is that §1's *state* chapter is not.

One refinement to #5: the specific example §1 gives — `Cis.framework.player()` returning bare `nil`
in standalone fallback — is correct and is a live instance of the defect.

---

## 7. What §1 missed entirely

1. **The `self` trap.** `exports[resource][name](...)` is an **unbound method call** that shifts every
   argument one slot left. `init.lua` carried this bug, and it silently corrupted every API call in
   the library — a zone created as `(kind, name, coords)` arrived as `(name, coords, size)`, so the
   zone's **name became its own coordinates** and creation returned `false` with no error raised.
   **Unit 0.3's subagent prompt instructs: "do not modify the existing boundary model or proxy
   mechanism — they are correct."** That instruction would have preserved a live bug. Documented now
   in `MEMORY.md` §1.

2. **A function can be handed back across the boundary, but not sent over.** Passing a callback into an
   export delivers `nil`; returning one works. This is why zone `onEnter`/`onExit`/`inside` and
   `Cis.player.on`/`near` require an `*Event` relay, and it is not in §1's §1.4 surface listing.

3. **A returned function is a callable reference table**, not a `function` — `type()` reports `table`,
   so a `type(x) == 'function'` check rejects a working handler.

4. **`cis_libstest` exists** — 89 integration tests with a JSON reporter and teleport-driven zone tests.

5. **A documentation set §1 does not reference:** `MEMORY.md`, `DOCUMENTATION.md` (~4,900 words),
   `MIGRATION_PROMPT.md`, `cis_libstest/README.md`.

6. **No `package.json` and no CI** — the existing test suite cannot run from a clean checkout.

7. **No changelog**, so §0.1's freeze baseline has nothing to point at.

---

## 8. The rule, applied

No implementation was performed — this is a report. Recording how the rule *"freeze the interface,
not the defect"* resolves each case:

| Case | Resolution |
|---|---|
| `CallCallback` numeric first arg | Keep local dispatch (that is the interface). Emit a deprecation warning at the call site when the first argument is numeric and the handler name does not end in `Client`. Zero interface change. |
| `AuthorizedResources` empty | Boot-time warning naming the exposure when the list is empty. Unit 0.1's restrictive default already covers new installs. |
| `db.transaction` on wrong driver | Unit 0.1's boot diagnostic is exactly this. |
| `framework.player` returning `nil` | Defect #5. The fix is the `Result` type in Unit 0.3, not a patch. |

---

## 9. Blockers before Unit 0.1

1. **What actually shipped.** The freeze baseline must be the escrow artifact, not this working tree.
   Until the shipped bundle is identified, `COMPATIBILITY.md` can only describe a surface no customer
   is on.
2. **Which surface `COMPATIBILITY.md` describes** — the working tree, or commit `0249976`. They are
   almost entirely different codebases.

Non-blocking but cheap, and it makes an existing gate enforceable: add a `package.json` and a CI job
running `node test/run.js`. Without them, Unit 0.1's "run the tests" gate is unverifiable from a clean
checkout, and any future subagent is asked to prove facts it can only quote.

---

## Addendum — defects found during Unit 0.1 (2026-09-29)

Found after the original audit. **Pinned by `test/contracts.lua`, not fixed** — Unit 0.1's
non-goals forbid behaviour changes, and each of these requires one.

### 9.1 `Cis.framework.notify` has a realm-asymmetric signature — **confirmed**

```lua
function Cis.framework.notify(srcOrNil, message, kind)
    if IS_SERVER then return exportCall('Notify', srcOrNil, message, kind) end
    if message == nil then return exportCall('Notify', srcOrNil, kind) end
    return exportCall('Notify', message, kind)
end
```

The client export is `Notify(message, kind)` — two parameters — while the proxy takes three and
reads the first as `srcOrNil`. A two-argument call resolves differently per realm:

| Call | Server | Client |
|---|---|---|
| `notify(nil, 'Hi', 'error')` | player `nil`, message `'Hi'` | message `'Hi'` ✓ |
| `notify('Hi', 'error')` | player `'Hi'`, message `'error'` | message `'error'` ✓ form, but src leaks |

`cis_tcvs`, `cis_storeRobberies`, and `cis_HawkEyeSurveillance` all call this. The fix is a
separate entry point per realm or a typed options table; the interface is frozen until 3.0.

### 9.2 `Cis.db.transaction` always times out and returns `nil` — **confirmed**

`Database.Transaction(queries, cb)` has arity 2. `exportAwait` calls `method(sql, params, cb)` —
so `cb` receives the **query list**, is never invoked, the promise never resolves, and the await
burns its full 15-second timeout before returning `nil`.

This means the `'transactions require oxmysql'` string at `server/database.lua:245` is
**unreachable through any export.** The contract in the brief (§1.8 defect 3) and in
`deltareport1.md` §6 describes behaviour that cannot occur. The real contract is `nil` after 15s,
on *every* driver including oxmysql.

`cis_housing` and `cis_phone` both call `Cis.db.transaction`. This is worse than the defect the
brief describes: it is not a wrong-answer-on-the-wrong-driver, it is a guaranteed 15-second stall
on the right one.

### 9.3 `server/callback.lua` remote dispatch **CONFIRMED BROKEN** — every argument is lost

> **Measured live 2026-09-29 on a Qbox server.** This was the highest-priority
> unmeasured item in the programme. The answer is worse than "may be broken".

**The measurement.** `cis_libstest` 2.0 registers a real handler on its own
resource and dispatches through the exact path in question:

```lua
exports['cis_libs']:RegisterCallback('cis:probe:bind', 'cis_libstest:cis_test:capture')
exports['cis_libs']:AwaitCallback('cis:probe:bind', 'ALPHA', 99)
```

**The result.** The handler was invoked but recorded **zero arguments**
(`n = 0`). Not shifted by one — *empty*. Expected `src`, `'ALPHA'`, `99`; got
nothing.

```
probe: remote handler binding -- the remote handler recorded nothing
probe: argument types survive the boundary  (the handler recorded 0 arguments)
probe: vector3 arguments survive the boundary  (the handler recorded nothing)
```

**What is and is not broken.** Control flow reaches the handler — the
`returnValue` and `returnsSeveral` probes both returned their values correctly,
so the lookup, the call, and the return path all work. Only the **arguments**
are lost, at or after the `__cfx_functionReference` call boundary.

`invoke` does:

```lua
local target = exports[ref.resource]
fn = target and target[ref.export]
if not isCallable(fn) then ... end
local results = table.pack(pcall(fn, src, ...))
```

`isCallable` accepts the reference table, so the guard passes. The arguments
are then dropped in the call itself. So the reference is **bound** (it needs no
`self` — the earlier reading of 9.3 as an unbound-method shift was wrong) but
it is **not argument-forwarding**.

**Consequence.** Every `Cis.callback.register(name, 'resource:exportName')`
handler receives no arguments. `cis_storeRobberies` is the only product using
`Cis.callback.register` and registers a **local function**, not a remote
reference, so **no shipped product is affected today**. The remote path has
simply never worked.

**Fix direction.** Stop calling an export across the boundary to obtain
behaviour. Either (a) pass the payload out of band — the caller stores
arguments in a table and the handler reads it, or (b) the `Cis.callback.register`
API takes a *named remote entry point* and cis_libs dispatches through a net
event carrying data, which does cross intact. (a) is smaller and testable.

### 9.3a (was 9.3) `server/callback.lua` remote dispatch — superseded by 9.3 above

```lua
local target = exports[ref.resource]
fn = target and target[ref.export]     -- bracket lookup on the exports table
...
local results = table.pack(pcall(fn, src, ...))
```

`MEMORY.md` §1 established that the bracket form yields an **unbound method**. Whether
`exports[res][name]` returns an unbound function or an already-bound callable reference was
**never measured** — we only measured the *return value* of an export, which does arrive callable.

If it is unbound, every remote handler invoked through `Cis.callback.register(name, 'res:export')`
receives `src` as its `self` and every argument shifts one slot left — the same class of silent
defect as the original, in the one path that was built specifically to be safe.

*(Superseded: measured live — see 9.3 above.)*

### 9.4 A guard gap found by testing, not by reading

Reordering `Cis.callback.callClient`'s parameters from `(name, src, …)` to `(src, name, …)` —
a plausible future refactor — **passed both `test/binding.lua` and the CI grep**. The grep
matches only the literal bracket-call shape; `binding.lua` never reached the four proxy wrappers
in `init.lua` that reorder before delegating.

`test/contracts.lua` (154 assertions) now covers argument slots for every proxy. Eleven planted
mutations, eleven caught, against two of seven before.

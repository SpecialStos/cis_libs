# COMPATIBILITY.md — the frozen contract for `cis_libs`

**Resource:** `cis_libs`
**Product version:** `1.0.0`
**Contract major (`api`):** `1`
**Migration set (`schema`):** `0`
**Date:** 2026-09-29

**What this document is.** The legal record of what `cis_libs` promises, what it
merely happens to do, and which of the two you are allowed to depend on. Six
escrow-protected products consume this library. A change that breaks one of them
is a defect in the change, not in the product.

**How to read it.** Every entry below is marked either **exercised** — called by
production code in at least one shipped product — or **unexercised**, which
means *published and frozen anyway*. The freeze protects the unexercised entries
too. A surface nobody calls is still a surface somebody may be about to call, and
"no current caller" is not the same question as "may this be removed".

**Where the facts come from.** The export tables, the parameter lists and the
net events below were extracted from source by `tools/lua-exports.js`, not
transcribed from `DOCUMENTATION.md`. `npm run test:api` fails if the tables and
the source ever disagree. Usage marks come from a scan of the product source
trees. Behaviour comes from measurement on a live server, not from reading the
code. Known defects come from the contract test suite in `test/contracts.lua`,
which pins them rather than fixing them.

---

## 1. The boundary, in one page

`cis_libs` is two things: a provider resource, and a `shared_script` consumer
import. Understanding the boundary is a precondition for reading everything
else, so it comes first.

### 1.1 The `self` trap

```lua
exports['cis_libs']:SomeExport(a, b)    -- CORRECT
exports['cis_libs']['SomeExport'](a, b) -- WRONG
```

The bracket form yields an **unbound method**: the exports table is expected as
the first argument. Without it, every argument shifts one place left. `cis_libs`
shipped this bug and it silently corrupted the entire library — a zone created
as `(kind, name, coords)` arrived as `(name, coords, size)`, so the zone's *name
became its own coordinates* and creation returned `false` with nothing logged.

**For consumers:** use the colon form, always. `lib.SomeExport(lib, a, b)` is
the only safe dynamic equivalent.

`cis_libs` itself is fixed (`init.lua`, `exportCall`), and the fix is guarded two
ways: `test/binding.lua` and `test/contracts.lua` assert the argument slots of
every proxy function, and CI greps for the bracket-call shape. See §12.

### 1.2 What survives the boundary

| Value | Result |
|---|---|
| Number, string, boolean, `vector3`, `vector4` | Preserved |
| Table (nested, arrays) | Preserved |
| `nil` | **Dropped** — the key vanishes from a returned table |
| Multiple return values | **Collapsed to the first** |
| **Function as an argument** | **Dropped** |
| Function as a return value | Arrives as a *callable reference table* |

A returned function comes back as `{ __cfx_functionReference = 'resource:line:col' }`
and **is callable** — verified with both `ref()` and `ref(ref)`. **`type()` reports
`table`, not `function`**, so a `type(x) == 'function'` check rejects a working
handler.

### 1.3 Exports return data; net events carry callbacks

A function cannot be sent *into* `cis_libs`, so every callback option has an
**Event twin**:

```lua
-- from another resource
Cis.zones.box('shop', centre, size, { onEnterEvent = 'myResource:shopEnter' })
Cis.player.near(coords, 10.0, nil, nil, 'myResource:nearEnter', 'myResource:nearExit')
RegisterNetEvent('myResource:shopEnter', function(zone, x, y, z) end)
```

The function forms (`onEnter`, `onExit`, `inside`) work only when `cis_libs`
itself calls them. From a consumer they arrive as `nil` and the callback never
fires. **`Cis.player.near` is used by exactly one caller (`cis_storeRobberies`)
and takes callbacks that cannot cross the boundary; that integration receives
`nil` today.** It is the clearest live bug in the product set and the clearest
candidate to migrate to `onEnterEvent`.

### 1.4 `shared_script` copies; it does not share

A consumer that adds `shared_script '@cis_libs/init.lua'` gets a **proxy table**,
not access to `CisReadyState`, `Config`, `Globals` or the zone grid. Each resource
runs its own Lua VM and the file is copied into it. See §10 for which files must
never be shared.

---

## 2. What is frozen, and what is not

**Frozen.** Every `Cis.*` function, every export, every net event name, and every
config key, in the forms listed here. A change to any of them is a **MAJOR**
change to the contract and requires the §11 removal process, or an explicit
decision not to remove.

**Not frozen, and deliberately so.**

- **Console output.** `cis_libs` logs to the console freely, including security
  warnings. Consumers do not parse it.
- **Internal return *reasons*.** Every fallible call returns `false, '<reason>'`.
  The reasons are documented and stable enough to log, but they are diagnostic
  text, not a contract. Branch on the boolean.
- **Which external resources are probed.** `GetResourceState` calls against
  `ox_target`, `qb-core` and friends may come and go.
- **`GetFramework`'s return value.** It returns a table of *callable reference
  tables* and works, but by accident of implementation. It is not an API. See §11.

---

## 3. Semver policy

### 3.1 MAJOR — a breaking change

A MAJOR bump is required for any of:

- removing or renaming a `Cis.*` function, an export name, or a net event;
- adding, removing, or reordering a parameter of an existing function or export;
- changing a return value, a return *type*, or a `false, '<reason>'` refusal into
  a silent `nil` (or the reverse);
- changing a default that a consumer may be relying on, **including a security
  default** — see §7;
- making a net event's name computed where it was literal, or the reverse.

**A breaking change never produces a silently wrong answer.** This is the whole
point of the rule and it is the reason the refusal return convention exists
throughout the library. An older consumer pinned to a prior contract major
receives an **explicit, typed refusal at the boundary** — a typed error carrying
the consumer's declared `api` major, the platform's current `api` major, and the
named incompatibility — **never** a call that appears to succeed with shifted or
misinterpreted arguments. A silent success is the failure mode that produced the
`self` trap; the policy exists to make it impossible to ship one.

Practically, that means: before a MAJOR change lands, every affected entry gets
an `['until']` in `api.lua`, a deprecation warning at the call site, and at least
one full major of coexistence. Only when the removal happens does the refusal
appear — and it appears then, loudly and with a type, not gradually.

### 3.2 MINOR — additive only

A MINOR bump is required for, and **limited to**, additions:

- a new `Cis.*` function, a new export, or a new net event;
- a new config key with a default that preserves current behaviour;
- a new field in a `Cis.*` return table.

A MINOR **MUST NOT** change the meaning of anything that already exists. Adding
a *positional* parameter to an existing function is MAJOR, not MINOR — the
boundary drops `nil`, so a caller that omits the new middle argument sends a
shifted one. This is precisely the `self` trap with a new hat on.

### 3.3 PATCH — bug fixes only

A PATCH bump fixes behaviour that does not match what this document already
promises. It **MUST NOT** change any documented behaviour, including turning a
silent wrong answer into a refusal: that is a *behaviour change* and takes a
MINOR at minimum, because a consumer that depended on the wrong answer is
detectable only by breaking.

### 3.4 The freeze and the six products

`cis_libs` is consumed by six escrow-protected products. A change that breaks
any of them is a defect in the change. The freeze is on the **whole published
surface**, not on the observed usage: the 37 proxy calls and 7 export calls the
products actually make are a *subset* of what is protected.

`cis_BetterFightEvolved` and `cis_pacificBankRobbery` make **zero** calls, and
the deployed `[standalone]/` copies of the other four show far less usage than
The source copies record that the deployed tree is stale
and the **source copies in `Desktop/ZCode/` are authoritative**. The freeze
baseline is therefore taken from the source copies, and the deployed tree must
be re-synced from source before the next release. No commit in this repository
records that, which is itself worth fixing.

---

## 4. The four manifest numbers

Every `cis_*` resource carries four numbers that move independently. Conflating
them is the mistake this section exists to prevent.

| Field | Lives in | Answers | Type | Bumped when |
|---|---|---|---|---|
| `version` | `fxmanifest.lua` | Which build of this product is it? | `MAJOR.MINOR.PATCH` | Every release. |
| `api` | `api.lua` | Which contract major can it speak? | **integer** | Only on a breaking change to its public surface. |
| `schema` | `api.lua` | Which migration set does its stored data assume? | **integer** | When the on-disk or in-database shape changes. |
| `cis_min_libs` | `fxmanifest.lua` | What platform floor does it need? | `MAJOR.MINOR.PATCH` | When it starts using a newer `cis_libs` capability. |

Rules:

- `api` is an **integer contract major**, not a semver. `api = 1` is contract
  major 1. A resource pinned to `api = 1` is refused by a platform at `api = 2`,
  with a typed refusal naming both majors.
- `schema` is a **set id**, not an ordering. Migration set 3 is not "more than"
  set 2 unless the migration graph says so.
- `cis_min_libs` is a floor on `cis_libs`' **`version`**, not on its `api`. A
  product can need a bug fix in `cis_libs` 1.2.0 without needing anything from
  contract major 2. Conflating these is how a platform ends up refusing a
  consumer that would have worked.
- Raising `api` **MUST** raise `cis_min_libs` to the `cis_libs` version that
  first shipped the new contract; and a `cis_libs` that raises its own `api`
  **MUST** ship a `CHANGELOG` entry naming the consumer majors it still accepts.

`cis_libs` is the platform, not a consumer of itself, so it carries no
`cis_min_libs`. It does carry `version "1.0.0"` in its manifest and `api = 1`,
`schema = 0` in `api.lua`.

The `api.lua` format is a single `return { ... }` of pure data. A consumer can read the
platform's declared contract without starting it:

```lua
local api = assert(loadfile('resources/cis_libs/api.lua'))()
if (api.api ~= 1) then
    error(('cis_libs contract major %d; this consumer speaks %d'):format(api.api, 1))
end
```

---

## 5. The `Cis.*` proxy surface — 50 entry points

Loaded by a consumer with `shared_script '@cis_libs/init.lua'`. **50 distinct
names, 52 realm-specific entries** (`Cis.inventory.count` and `Cis.inventory.has`
exist in both realms with different signatures).

Also set by `init.lua`, and part of the surface: `Cis.resource` (the string
`'cis_libs'`), `Cis.isReady`, `Cis.isFailed`.

### 5.1 Both realms (17)

| Function | Signature | State | Called by production code |
|---|---|---|---|
| `Cis.ready` | `(cb, timeout)` | stable | no |
| `Cis.wait` | `(timeout)` | stable | no |
| `Cis.framework.notify` | `(srcOrNil, message, kind)` | stable | **yes** — tcvs, storeRobberies, HawkEye |
| `Cis.callback.register` | `(name, handler)` | stable | **yes** — storeRobberies |
| `Cis.callback.await` | `(name, ...)` | stable | no |
| `Cis.callback.call` | `(name, cb, ...)` | stable | no |
| `Cis.doors.add` | `(data)` | stable | **yes** — storeRobberies |
| `Cis.doors.setState` | `(id, locked)` | stable | **yes** — storeRobberies |
| `Cis.doors.get` | `(id)` | stable | no |
| `Cis.sync.ped` | `(data)` | stable | no |
| `Cis.sync.prop` | `(data)` | stable | **yes** — housing |
| `Cis.sync.vehicle` | `(data)` | stable | no |
| `Cis.sync.remove` | `(id)` | stable | **yes** — housing |
| `Cis.log.debug` | `(message)` | stable | **yes** — tcvs, storeRobberies, HawkEye |
| `Cis.log.info` | `(message)` | stable | **yes** — tcvs, storeRobberies, HawkEye |
| `Cis.log.warn` | `(message)` | stable | **yes** — tcvs, storeRobberies, HawkEye |
| `Cis.log.error` | `(message)` | stable | **yes** — tcvs, storeRobberies, HawkEye |

`Cis.sync.*` resolve to **server-only** exports (`SyncCreate`, `SyncRemove` are
registered in `server/sync.lua` only). `init.lua` defines the proxies in both
realms for symmetry; calling them from a client is a no-op at best. The
documented realm is **server**.

`Cis.framework.notify` has three shapes and one of them is broken. See §11.1.

### 5.2 Client only (20)

| Function | Signature | State | Called by production code |
|---|---|---|---|
| `Cis.player.ped` | `()` | stable | **yes** — tcvs, storeRobberies, HawkEye, phone |
| `Cis.player.coords` | `()` | stable | **yes** — tcvs, storeRobberies, HawkEye |
| `Cis.player.heading` | `()` | stable | no |
| `Cis.player.vehicle` | `()` | stable | **yes** — housing |
| `Cis.player.weapon` | `()` | stable | **yes** — housing |
| `Cis.player.serverId` | `()` | stable | **yes** — storeRobberies, HawkEye, housing |
| `Cis.player.on` | `(key, cb)` | stable | **yes** — tcvs, storeRobberies, housing |
| `Cis.player.near` | `(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)` | stable | **yes** — storeRobberies |
| `Cis.zones.poly` | `(name, points, options)` | stable | **yes** — tcvs, storeRobberies |
| `Cis.zones.box` | `(name, center, size, options)` | stable | **yes** — tcvs |
| `Cis.zones.sphere` | `(name, center, radius, options)` | stable | **yes** — HawkEye, housing |
| `Cis.zones.remove` | `(name)` | stable | **yes** — tcvs, storeRobberies, HawkEye |
| `Cis.zones.contains` | `(name, point)` | stable | no |
| `Cis.target.add` | `(zoneType, name, coords, size, options)` | stable | **yes** — storeRobberies, HawkEye |
| `Cis.target.remove` | `(name, isPed)` | stable | **yes** — storeRobberies, HawkEye |
| `Cis.target.update` | `(name, options)` | stable | no |
| `Cis.target.exists` | `(name)` | stable | no |
| `Cis.streaming.model` | `(model, timeout)` | stable | **yes** — tcvs, storeRobberies, HawkEye, housing, phone |
| `Cis.inventory.count` | `(item)` | stable | **yes** — housing |
| `Cis.inventory.has` | `(item, amount)` | stable | **yes** — one caller, unidentified |

`Cis.player.ped`, `Cis.player.coords` and `Cis.player.heading` are answered
**locally** from natives, not through the exports boundary, when the proxy is
running in a consumer's VM. They are frozen in that shape.

### 5.3 Server only (15)

| Function | Signature | State | Called by production code |
|---|---|---|---|
| `Cis.framework.player` | `(src)` | stable | **yes** — tcvs, storeRobberies, HawkEye, phone |
| `Cis.inventory.add` | `(src, item, amount, metadata)` | stable | **yes** — tcvs, storeRobberies, HawkEye |
| `Cis.inventory.remove` | `(src, item, amount)` | stable | **yes** — HawkEye |
| `Cis.inventory.count` | `(src, item)` | stable | **yes** — housing |
| `Cis.inventory.has` | `(src, item, amount)` | stable | **yes** — one caller, unidentified |
| `Cis.db.query` | `(sql, params)` | stable | **yes** — tcvs, storeRobberies, HawkEye, phone |
| `Cis.db.single` | `(sql, params)` | stable | **yes** — tcvs, storeRobberies, phone |
| `Cis.db.scalar` | `(sql, params)` | stable | **yes** — tcvs, storeRobberies |
| `Cis.db.insert` | `(sql, params)` | stable | **yes** — tcvs, HawkEye, phone |
| `Cis.db.update` | `(sql, params)` | stable | **yes** — tcvs, HawkEye, phone |
| `Cis.db.transaction` | `(queries)` | stable | **yes** — housing, phone |
| `Cis.security.report` | `(src, reason)` | stable | **yes** — tcvs, storeRobberies, HawkEye, phone |
| `Cis.net.on` | `(name, fn)` | stable | **yes** — tcvs, storeRobberies, HawkEye, housing, phone |
| `Cis.callback.callClient` | `(src, name, cb, ...)` | stable | no |
| `Cis.callback.awaitClient` | `(src, name, ...)` | stable | no |

`Cis.db.*` are the **awaited** family: they block the calling coroutine and
return the driver's results, bounded by `Config.Framework.Database.Timeout`.
They are not usable inside a thread that must not yield.

### 5.4 The eleven unexercised proxy functions

```
Cis.callback.call          Cis.callback.await          Cis.callback.callClient
Cis.callback.awaitClient   Cis.doors.get               Cis.player.heading
Cis.sync.ped               Cis.sync.vehicle            Cis.target.exists
Cis.target.update          Cis.zones.contains
```

Plus `Cis.ready` and `Cis.wait`, which no product calls either.

**These are frozen.** They are documented surface, and the freeze protects
documented surface. They are not removal candidates in 1.x. They do tell you
something real: the products' actual needs are thin exactly here.

---

## 6. The export surface — 52 server, 55 client

Reached with `exports['cis_libs']:Name(...)`. **91 distinct names**; sixteen are
registered in both realms with different signatures.

"Reached by" is the `Cis.*` proxy that wraps it, if any. "Called by production
code" is from a scan of the product source trees.

### 6.1 Server — 52

| Export | Signature | Reached by | State | Called by production code |
|---|---|---|---|---|
| `AddDoorGroup` | `(groupData)` | — | stable | no |
| `AddDoorToSystem` | `(newDoorData, internal)` | — | **compat shim** | **yes** — storeRobberies |
| `AutoLogError` | `(err, event)` | — | stable | no |
| `AwaitCallback` | `(name, ...)` | `Cis.callback.await` | stable | no |
| `AwaitCallbackClient` | `(name, target, ...)` | `Cis.callback.awaitClient` | stable | no |
| `BreakDoor` | `(identifier)` | — | stable | no |
| `CallCallback` | `(name, cb, ...)` | `Cis.callback.call` | stable | no |
| `CallCallbackClient` | `(name, target, cb, ...)` | `Cis.callback.callClient` | stable | no |
| `CheckResourceVersion` | `(resourceName, resourceUrl, currentVersion)` | — | **compat shim** | **yes** — storeRobberies (deployed) |
| `CreateSafeCallback` | `(name, cb)` | — | **compat shim** | no |
| `DatabaseDelete` | `(sql, params, cb)` | — | **compat shim** | no |
| `DatabaseExecute` | `(query, params, callback)` | — | **compat shim** | no |
| `DatabaseFetchAll` | `(query, params, callback)` | — | **compat shim** | no |
| `DatabaseFetchOne` | `(query, params, callback)` | — | **compat shim** | no |
| `DatabaseInsert` | `(sql, params, cb)` | — | **compat shim** | no |
| `DatabaseUpdate` | `(sql, params, cb)` | — | **compat shim** | no |
| `DbInsert` | `(sql, params)` | `Cis.db.insert` | stable | no |
| `DbQuery` | `(sql, params)` | `Cis.db.query` | stable | no |
| `DbScalar` | `(sql, params)` | `Cis.db.scalar` | stable | no |
| `DbSingle` | `(sql, params)` | `Cis.db.single` | stable | no |
| `DbTransaction` | `(sql, params)` | `Cis.db.transaction` | stable | no |
| `DbUpdate` | `(sql, params)` | `Cis.db.update` | stable | no |
| `FixDoor` | `(identifier)` | — | stable | no |
| `GetAllDoorData` | `()` | — | stable | no |
| `GetConfigSummary` | `()` | — | stable | **yes** — one caller, unidentified |
| `GetDiscordQueueDepth` | `()` | — | stable | no |
| `GetDoorState` | `(doorId)` | `Cis.doors.get` | stable | no |
| `GetFramework` | `()` | — | **compat shim** | **yes** — storeRobberies |
| `GetLibsPrefix` | `()` | — | stable | **yes** — HawkEye |
| `GetLogging` | `()` | — | stable | **yes** — storeRobberies (deployed) |
| `GetNormalizedPlayer` | `(src)` | `Cis.framework.player` | stable | no |
| `GetOnlineJobCount` | `(jobs)` | — | stable | no |
| `InventoryAdd` | `(src, item, amount, metadata)` | `Cis.inventory.add` | stable | no |
| `InventoryCount` | `(src, item)` | `Cis.inventory.count` | stable | no |
| `InventoryHas` | `(src, item, amount)` | `Cis.inventory.has` | stable | no |
| `InventoryRemove` | `(src, item, amount)` | `Cis.inventory.remove` | stable | no |
| `InvokingAllowed` | `()` | — | stable | no |
| `LockDoors` | `(identifier)` | — | **compat shim** | **yes** — storeRobberies |
| `LogDebug` | `(message, discordType)` | `Cis.log.debug` | stable | **yes** — storeRobberies (deployed) |
| `LogError` | `(message, discordType, errorInfo)` | `Cis.log.error` | stable | **yes** — storeRobberies (deployed) |
| `LogInfo` | `(message, discordType)` | `Cis.log.info` | stable | **yes** — storeRobberies (deployed) |
| `LogWarn` | `(message, discordType)` | `Cis.log.warn` | stable | no |
| `Notify` | `(src, message, kind)` | — | stable | no |
| `RateOk` | `(src, name, windowMs, maxHits)` | — | stable | **yes** — one caller, unidentified |
| `RegisterCallback` | `(name, handler)` | `Cis.callback.register` | stable | no |
| `SecureNetOn` | `(name, fn)` | `Cis.net.on` | stable | no |
| `SecurityReport` | `(src, reason)` | `Cis.security.report` | stable | no |
| `SendDiscordLog` | `(webhookURL, title, message, color, ping)` | — | stable | no |
| `SyncCreate` | `(kind, data)` | `Cis.sync.ped / prop / vehicle` | stable | no |
| `SyncRemove` | `(id)` | `Cis.sync.remove` | stable | no |
| `UnlockDoors` | `(identifier)` | — | **compat shim** | **yes** — storeRobberies (deployed copy) |
| `WaitReady` | `(timeout)` | — | stable | no |

### 6.2 Client — 55

| Export | Signature | Reached by | State | Called by production code |
|---|---|---|---|---|
| `AddDoorGroup` | `(data)` | — | stable | no |
| `AddDoorToSystem` | `(data)` | — | **compat shim** | **yes** — storeRobberies |
| `AutoLogError` | `(err, context)` | — | stable | no |
| `AwaitCallback` | `(name, ...)` | `Cis.callback.await` | stable | no |
| `CallCallback` | `(name, cb, ...)` | `Cis.callback.call` | stable | no |
| `CreatePed` | `(model, coords, heading, options)` | — | stable | no |
| `CreateTarget` | `(zoneType, name, coords, size, options)` | `Cis.target.add` | stable | **yes** — storeRobberies, HawkEye |
| `CreateZone` | `(kind, name, a, b, options)` | `Cis.zones.box / poly / sphere` | stable | no |
| `DebugLog` | `(message)` | — | stable | no |
| `DrawText3D` | `(x, y, z, text, settings)` | — | stable | **yes** — storeRobberies (deployed) |
| `GetCachedHeading` | `()` | — | stable | no |
| `GetCachedPed` | `()` | — | stable | no |
| `GetCachedServerId` | `()` | `Cis.player.serverId` | stable | no |
| `GetCachedVehicle` | `()` | `Cis.player.vehicle` | stable | no |
| `GetCachedWeapon` | `()` | `Cis.player.weapon` | stable | no |
| `GetClientConfig` | `()` | — | stable | no |
| `GetClientLogging` | `()` | — | stable | **yes** — storeRobberies (deployed) |
| `GetClosestDoor` | `()` | — | stable | no |
| `GetClosestVehicle` | `()` | — | stable | no |
| `GetCurrentWeaponData` | `(ped)` | — | stable | no |
| `GetDistanceBetweenCoords` | `(x1, y1, z1, x2, y2, z2)` | — | stable | no |
| `GetDoorState` | `(doorId)` | `Cis.doors.get` | stable | no |
| `GetFramework` | `()` | — | **compat shim** | **yes** — storeRobberies |
| `GetGlobals` | `()` | — | **compat shim** | **yes** — storeRobberies |
| `GetPlayerVehicleSeat` | `()` | — | stable | no |
| `GetPolyzones` | `()` | — | **compat shim** | **yes** — storeRobberies (deployed) |
| `GetSyncedEntities` | `()` | — | stable | no |
| `GetTableSize` | `(t)` | — | stable | no |
| `GetVehicleProperties` | `(vehicle)` | — | stable | no |
| `GetZoneDebug` | `()` | — | stable | no |
| `InventoryCount` | `(item)` | `Cis.inventory.count` | stable | no |
| `InventoryHas` | `(item, amount)` | `Cis.inventory.has` | stable | no |
| `IsReady` | `()` | — | stable | no |
| `LogDebug` | `(message)` | `Cis.log.debug` | stable | **yes** — storeRobberies (deployed) |
| `LogError` | `(message)` | `Cis.log.error` | stable | **yes** — storeRobberies (deployed) |
| `LogInfo` | `(message)` | `Cis.log.info` | stable | **yes** — storeRobberies (deployed) |
| `LogWarn` | `(message)` | `Cis.log.warn` | stable | no |
| `Notify` | `(message, kind)` | — | stable | no |
| `OnPlayerCache` | `(key, cb)` | `Cis.player.on` | stable | no |
| `RandomFloat` | `(lower, greater)` | — | stable | no |
| `RegisterCallback` | `(name, fn)` | `Cis.callback.register` | stable | no |
| `RemoveTarget` | `(name, isPed)` | `Cis.target.remove` | stable | **yes** — storeRobberies, HawkEye |
| `RemoveZone` | `(name)` | `Cis.zones.remove` | stable | no |
| `RequestLockDoors` | `(identifier)` | `Cis.doors.setState(id, true)` | stable | no |
| `RequestModelTimeout` | `(model, timeout)` | `Cis.streaming.model` | stable | no |
| `RequestUnlockDoors` | `(identifier)` | `Cis.doors.setState(id, false)` | stable | no |
| `Round` | `(num, numDecimalPlaces)` | — | stable | no |
| `SetVehicleProperties` | `(vehicle, props, fixVehicle)` | — | stable | no |
| `TargetAvailable` | `()` | — | stable | no |
| `TargetExists` | `(name)` | `Cis.target.exists` | stable | no |
| `TriggerLibCallback` | `(name, cb, ...)` | — | stable | no |
| `UpdateTarget` | `(name, newOptions)` | `Cis.target.update` | stable | no |
| `WaitReady` | `(timeout)` | — | stable | no |
| `WatchNear` | `(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)` | `Cis.player.near` | stable | no |
| `ZoneContains` | `(name, point)` | `Cis.zones.contains` | stable | no |

### 6.3 The five `:doorlock:*` events are computed

`Security.EventPrefix` is an operator setting. All five doorlock event names are
built from it at runtime:

```
<Security.EventPrefix>:doorlock:requestState    client -> server  (identifier, state)
<Security.EventPrefix>:doorlock:updateState     server -> client  (doorId, locked)
<Security.EventPrefix>:doorlock:addDoor         server -> client  (doorData)
<Security.EventPrefix>:doorlock:addDoorGroup    server -> client  (groupData)
<Security.EventPrefix>:doorlock:doorBroken      server -> client  (doorId, broken)
```

**A consumer cannot hardcode these names.** With the shipped prefix they are
`cis_libs:doorlock:*`, and that is a coincidence of configuration, not a
contract. A consumer that hardcodes them works on a default install and breaks
silently on any server that changed the prefix — no error, no log line, doors
that simply never update.

The supported way:

```lua
local prefix = exports['cis_libs']:GetLibsPrefix()   -- server side
RegisterNetEvent(prefix .. ':doorlock:updateState', function(doorId, locked) ... end)
```

`cis_storeRobberies` calls `AddDoorToSystem` and receives these events, and it
cannot name them. It is one of the strongest arguments in the programme for
keeping the shims until 3.0 (§11).

`api.lua` writes the five with the literal placeholder
`${Security.EventPrefix}:doorlock:...`, because a manifest must state a name a
consumer can compute but not one it can assume.

---

## 7. The allow-list posture

> ### An empty `Security.AuthorizedResources` is a **setup convenience, not a production posture**.

An empty list means *any server-side resource* may add doors, break them, add
door groups, and create or rewrite sync entities for every player on the server.
That is not a theoretical exposure: it is a resource you have not written yet
making the decision for you.

On a **new install** an empty list is now **restrictive**: only `cis_libs` itself
may mutate, and a foreign caller is refused. The refusal is a boot-time console
message naming the exact fix:

```
Security.AuthorizedResources = { "cis_storeRobberies", "cis_housing" }
```

On an **existing install** — one that was already running `cis_libs` before this
default existed — the permissive behaviour is preserved. A legacy install is
detected by either of two signals:

1. a written config this library has left on disk
   (`configs/install.json`, written the first time a restrictive posture is
   applied); or
2. the `cis_doors` table, which only exists if `Config.Doorlock.Persist` was on
   and that bootstrap has already run.

Signal 2 needs a database query and is only conclusive when persistence is
configured, so the decision is made **synchronously** when `Persist` is off (the
shipped default) and **permissive until the query answers** when it is on. An
install that cannot be classified is never the one that gets broken.

### 7.1 The residual risk, stated plainly

The two signals cannot distinguish a legacy server that never enabled
`Doorlock.Persist` from a genuinely new one: neither left a trace. Such a
server's **first** boot under this change is restrictive, its doors are refused,
and it sees a six-line console message naming the resources to add. From the
second boot on, the written-config marker exists and it is permissive again.

This is the one place in this document where a security improvement can change
observable behaviour for an existing install. It is stated here rather than
buried because §3.1 requires it to be visible.

### 7.2 Refusals keep their return values

The four mutation call sites (`AddDoorToSystem`, `AddDoorGroup`, `Cis.sync.*`
create, `Cis.sync.*` remove) return exactly what they returned before — `false`
or `nil`, no second value. No new return value was added, so no consumer can
observe one. **Ask before you mutate**:

```lua
if not exports['cis_libs']:InvokingAllowed() then
    return print('not on the allow-list; add this resource to Security.AuthorizedResources')
end
```

### 7.3 `cis_libstest`

The integration harness mutates doors and sync, so **it is not exempt**. On a
fresh install its mutating tests will now fail — correctly, and informatively.
Add `"cis_libstest"` to `AuthorizedResources` on a test instance. The CI unit
suites are unaffected; they never load the doorlock or sync modules.

---

## 8. Net events

**25** in total: 20 literal, 5 computed from `Security.EventPrefix` (§6.3). Full
payloads are in `api.lua`; `npm run test:api` fails if this list and the manifest
disagree.

| Event | Direction | Payload |
|---|---|---|
| `cis_libs:cb` | **both** | `(name, key, ...)` — same name, different meaning each way |
| `cis_libs:cb:res` | server -> client | `(key, ok, ...)` |
| `cis_libs:cb:serverRes` | client -> server | `(key, ok, ...)` |
| `cis_libs:client:getData` | server -> client | `({ Config, EventPrefix, DoorData })` on join |
| `cis_libs:server:getData` | client -> server | no arguments |
| `cis_libs:client:showNotification` | server -> client | `(message, kind)` |
| `cis_libs:client:inventory` | server -> client | `({ [itemName] = count })` |
| `cis_libs:server:inventorySync` | client -> server | no arguments |
| `cis_libs:client:syncUpsert` | server -> client | `(record)` |
| `cis_libs:client:syncRemove` | server -> client | `(id)` |
| `cis_libs:client:toggleDoor` | server -> client | `({ doorId })` or `({ doorId = { ids } })` |
| `cis_libs:jobUpdated` | server -> client | `({ name, grade })` |
| `cis_libs:playerLoaded` | client local | `(job)` |
| `QBCore:Client:OnJobUpdate` | framework -> client | `(job)` |
| `QBCore:Client:OnPlayerLoaded` | framework -> client | `(playerData)` |
| `QBCore:Player:SetPlayerData` | framework -> client | `({ items })` |
| `qbx_core:client:playerLoaded` | framework -> client | `(playerData)` |
| `qbx_core:client:onJobUpdate` | framework -> client | `(job)` |
| `esx:playerLoaded` | framework -> client | `(player)` |
| `esx:setJob` | framework -> client | `(job)` |
| `<prefix>:doorlock:requestState` | client -> server | `(identifier, state)` |
| `<prefix>:doorlock:updateState` | server -> client | `(doorId, locked)` |
| `<prefix>:doorlock:addDoor` | server -> client | `(doorData)` |
| `<prefix>:doorlock:addDoorGroup` | server -> client | `(groupData)` |
| `<prefix>:doorlock:doorBroken` | server -> client | `(doorId, broken)` |

`cis_libs:client:toggleDoor` was registered and documented nowhere; it is here
now, and the validator (`E042`) will keep it from going missing again.

**Event handlers registered but not net events:** `gameEventTriggered`,
`CEventNetworkPlayerEnteredVehicle`, `CEventNetworkPlayerLeftVehicle`,
`onResourceStart`, `onResourceStop`, `onClientResourceStart`,
`onClientResourceStop`, `playerDropped`, `ox_inventory:updateInventory`,
`ox_inventory:openedInventory`, `QBCore:Server:PlayerLoaded`,
`QBCore:Server:OnJobUpdate`, `esx:playerLoaded`, `esx:setJob`. These are FiveM
built-ins or third-party events and are not part of the contract.

---

## 9. Config keys

**No `GetConvar` call exists anywhere in the codebase.** Everything is Lua
config, which is why these defaults are the contract.

### 9.1 `configs/master_config.lua` — `Config`

| Key | Default | Read by |
|---|---|---|
| `CheckVersion` | `false` | `server/version.lua` |
| `VersionCheckUrl` | `"https://api.cisoko.net/v1/cis_libs/version.txt"` | `server/version.lua` |
| `CallbackTimeout` | `10000` | server + client callback paths |
| `UpdateInterval.Player` | `1000` | `client/cache.lua` |
| `UpdateInterval.Weapon` | `1000` | `client/cache.lua` |
| `UpdateInterval.Vehicle` | `1000` | **read by nothing** — reserved |
| `UpdateInterval.VehicleProperties` | `5000` | **read by nothing** — reserved |
| `AimingCheckType` | `"default"` | `client/cache.lua` (`"default"` or `"configFlag"`) |
| `Framework.Type` | `"QBCORE"` | `QBCORE` / `QBOX` / `ESX` / `ESX-LEGACY` / `NONE` |
| `Framework.Inventory` | `"ox_inventory"` | `ox_inventory` / `qb-inventory` / `qs-inventory` / `codem-inventory` / `typical` |
| `Framework.Zones.Enabled` | `true` | `client/zones.lua` |
| `Framework.Target.Enabled` | `true` | `client/target.lua` |
| `Framework.Target.Type` | `"ox_target"` | `ox_target` / `qb-target` |
| `Framework.Target.Debug` | `false` | `client/target.lua` |
| `Framework.Database.Type` | `"oxmysql"` | `oxmysql` / `mysql-async` / `ghmattimysql` / `mongodb` |
| `Framework.Database.Collection` | `nil` | MongoDB only |
| `Framework.Database.Timeout` | `15000` | every awaited query |
| `Doorlock.Enabled` | `true` | `client/doorlock.lua` |
| `Doorlock.Type` | `"target"` | `target` / `DrawText3D` |
| `Doorlock.InteractableDistance` | `2.0` | both doorlock realms |
| `Doorlock.Persist` | `false` | `server/doorlock.lua`; SQL only |
| `Sync.Enabled` | `true` | `server/sync.lua` |
| `Printing.Debug` | `false` | both logging modules |
| `Printing.UseDiscordLogs` | `false` | `server/logging.lua`, `server/discord.lua` |

`UpdateInterval.Vehicle` and `.VehicleProperties` are documented as reserved and
are read by no code. They are frozen as configuration keys, and they are
**reserved, not API** — a resource may read them for its own polling, and
`cis_libs` will not start polling on them.

### 9.2 `configs/security_config.lua` — `Security`

| Key | Default | Notes |
|---|---|---|
| `EventPrefix` | `"cis_libs"` | Computes the five `:doorlock:*` names (§6.3) |
| `Debug` | `false` | |
| `AuthorizedResources` | `{}` | **See §7 before running this on a live server** |
| `DropPlayer` | `true`, then reassigned to `cisAnticheatDropPlayer` | boolean **or** `function(src, reason)` |

`Security.DropPlayer` is declared as a boolean and then overwritten with a
function in the same file. The function is the live value; the boolean is dead.
This was a real defect — `SecurityReport` tested the boolean and called the
global, so the configured function was never invoked — and it is now fixed and
covered.

### 9.3 `configs/discordLogs_config.lua` — `DiscordConfig`

| Key | Default |
|---|---|
| `Thumbnail` | `"https://i.imgur.com/s1Y6ykF.png"` |
| `FooterText` | `"fivem.cisoko.net - Shaping the Future of Roleplaying Games"` |
| `FooterIcon` | `"https://i.imgur.com/Ah7nsiv.png"` |
| `DiscordLogsLinks.MasterLogs` | `"CHANGE-ME-WITH-YOUR-WEBHOOK-LINK"` |
| `DiscordLogsLinks.CheatingLogs` | `"CHANGE-ME-WITH-YOUR-WEBHOOK-LINK"` |
| `DiscordLogsLinks.ErrorLogs` | `"CHANGE-ME-WITH-YOUR-WEBHOOK-LINK"` |

`Discord = DiscordConfig` is kept as an alias so older snippets that read
`Discord` still compile. Frozen.

### 9.4 What the client receives

`CisConfigUtil.clientPayload` sends a **whitelist** to clients: `UpdateInterval`,
`AimingCheckType`, `CallbackTimeout`, `Framework.Type`, `Framework.Inventory`,
`Framework.Zones`, `Framework.Target`, `Doorlock` (not `Persist`), `Printing.Debug`
(only), `Sync`, plus `EventPrefix` and `DoorData`. Webhooks, `Database`,
`AuthorizedResources` and `DropPlayer` never leave the server.
`test/run.lua` asserts this and the `/cis_debug` command re-checks it at runtime.

---

## 10. The stateful files — twelve

> **Never `shared_script` any file in this list.** A consumer that does gets a
> second instance of the state below: a second door index, a second target set, a
> second cache, a second ready gate, and native work multiplied by the number of
> resources that copied it.

| # | File | Module-level state |
|---|---|---|
| 1 | `client/cache.lua` | `CisCache` global, `listeners`, `nearWatchers`, and the `Globals` publisher |
| 2 | `client/zones.lua` | `zones`, `grid`, `inside` |
| 3 | `client/callback.lua` | `handlers`, `pending` |
| 4 | `client/doorlock.lua` | `doors`, `doorGroups`, `addedTargets`, `grid` |
| 5 | `client/target.lua` | `CreatedZones` |
| 6 | `client/sync.lua` | `entities`, `records`, `spawning` |
| 7 | `client/inventory.lua` | `counts` |
| 8 | `client/vehicle.lua` | `lastApplied` — **found in this pass, see below** |
| 9 | `server/callback.lua` | `handlers`, `remotes`, `pending` |
| 10 | `server/security.lua` | `rates` |
| 11 | `server/doorlock.lua` | `DoorLock.doorStates`, `.doorGroups`, `.doorData`, `lastChange` |
| 12 | `server/sync.lua` | `records` |

`server/player.lua` holds a `CisHistogram` store in a module local
(`CisHistogram` itself is pure, the store is not) and is a thirteenth on the same
rule; it is listed separately below because the original audit counted twelve.

### 10.1 Also stateful, found in this pass

The count above is the canonical twelve. These were not in that list and were
found by reading the files rather than the report. They carry the same warning:

| File | State | Consequence of duplicating |
|---|---|---|
| `framework/framework_client.lua` | global `Framework`, `FrameworkLoaded`, `playerId` | A second `Framework` global with `provider = 'NONE'`, silently breaking the doorlock job check |
| `framework/framework_server.lua` | global `CisFramework`, `FrameworkLoaded` | A second framework adapter; every player lookup diverges |
| `server/database.lua` | `Database` (driver, ready, warned) | A second driver selection and a second readiness flag |
| `client/utils.lua` | rebinds the **global** `CreatePed` | A native wrapped twice; the second wrapper is what `CreatePed` resolves to |
| `client/logging.lua` / `server/logging.lua` | global `Logging` | Level tables diverge between realms |
| `server/discord.lua` | global `DiscordQueue` | A second unbounded queue and a second drain thread |

### 10.2 Safe to duplicate

Genuinely pure, no state, no natives:

- `shared/grid.lua` — pure functions
- `shared/config.lua` — pure functions
- `shared/pending.lua` — the store is passed **in** as an argument
- `shared/histogram.lua` — same; the store is passed in
- `shared/ready.lua` — **has** `CisReadyState` state, but duplicating it is
  harmless: a consumer's copy is only ever read, never marked ready

---

## 11. The 3.0 removal list

Nothing in this section may be removed in 1.x or 2.x. Each entry names the
minimum major that permits deletion, the supported replacement, and what depends
on it.

### 11.1 Compat shims — removable at **3.0**

| Export | Realm(s) | Replacement | Depends on it |
|---|---|---|---|
| `AddDoorToSystem` | server, client | `Cis.doors.add(doorData)` | **cis_storeRobberies** |
| `LockDoors` | server | `Cis.doors.setState(id, true)` | **cis_storeRobberies** |
| `UnlockDoors` | server | `Cis.doors.setState(id, false)` | **cis_storeRobberies (deployed)** |
| `GetGlobals` | client | `Cis.player.*` and `Cis.sync.*`; no single replacement | **cis_storeRobberies** |
| `GetFramework` | server, client | `Cis.framework.player(src)` on the server; `Cis.framework.notify` on the client | **cis_storeRobberies** |
| `GetPolyzones` | client | `Cis.zones.poly` / `remove` / `contains` | **cis_storeRobberies (deployed)** |
| `DatabaseExecute` | server | `Cis.db.query(sql, params)` | — |
| `DatabaseFetchOne` | server | `Cis.db.single(sql, params)` | — |
| `DatabaseFetchAll` | server | `Cis.db.query(sql, params)` | — |
| `DatabaseInsert` | server | `Cis.db.insert(sql, params)` | — |
| `DatabaseUpdate` | server | `Cis.db.update(sql, params)` | — |
| `DatabaseDelete` | server | `Cis.db.query(sql, params)` | — |
| `CheckResourceVersion` | server | `Config.CheckVersion` + `Config.VersionCheckUrl` | **cis_storeRobberies (deployed)** |
| `CreateSafeCallback` | server | `Cis.callback.register(name, handler)` | — |

**`cis_storeRobberies` depends on five of these** — `AddDoorToSystem`,
`LockDoors`, `GetGlobals`, `GetFramework`, `GetPolyzones` — plus `UnlockDoors`
and `CheckResourceVersion` in the deployed copy. That dependency is the single
strongest argument in the programme for keeping every shim until 3.0 rather than
retiring them on a use count.

Two constraints on the removal itself:

- `DatabaseExecute` is called **internally** by `server/doorlock.lua`. Replacing
  it must land in the same release that removes it, or the door persistence path
  breaks first.
- `GetPolyzones` returns a table of *closures*, which a consumer can call but
  cannot introspect. Its replacement is three separate proxies with different
  signatures, so the migration is not mechanical.

### 11.2 Retained through 2.x, review at 3.0

Not shims. Listed so the 3.0 review does not have to rediscover them.

| Export | Why it stays |
|---|---|
| `BreakDoor`, `FixDoor` | No proxy equivalent. Removing them removes a capability. |
| `AddDoorGroup` | No proxy equivalent. |
| `GetDoorState` | Reached via `Cis.doors.get`. |
| `GetAllDoorData` | Used internally by `server/initialize.lua`. |
| `SendDiscordLog` | Raw webhook push; `Cis.log.*` routes through the queue and the config. |
| `GetLogging`, `GetClientLogging` | The documented way to reach the level table. |
| `GetConfigSummary`, `GetClientConfig`, `GetDiscordQueueDepth` | Diagnostic surface; `allowListConfigured` in `GetConfigSummary` is how a consumer checks §7 before mutating. |
| `IsReady`, `WaitReady` | Reached via `Cis.isReady` and `Cis.ready`. |
| `InvokingAllowed`, `RateOk`, `GetLibsPrefix` | Required to use the library correctly under §7. |
| `GetSyncedEntities`, `GetZoneDebug`, `GetClosestDoor`, `GetNormalizedPlayer`, `GetOnlineJobCount`, `TargetAvailable` | Introspection with no proxy. |

### 11.3 Removal procedure

1. Declare `deprecated = true` and an `['until']` in `api.lua`. The validator
   (`E011`, `E013`) refuses a deprecation with no destination or no end date.
2. Ship at least one full major of coexistence with a call-site warning.
3. Confirm no product depends on it — the usage scan is the record, and it
   is only as current as the last source scan.
4. Delete it and bump `api`. Consumers pinned to the prior major get the typed
   refusal from §3.1, not a silent wrong answer.

---

## 12. Verification

Everything in this document is checkable from a clean checkout:

```bash
npm ci
npm run test:all
```

Which is:

| Command | What it proves |
|---|---|
| `npm test` | 62 pure-module assertions, 27 binding assertions, 163 contract assertions — 252 in total |
| `npm run test:api-selftest` | The `api.lua` validator passes the real manifest and rejects all five broken fixtures |
| `npm run test:api` | `api.lua` matches the registered surface: 52 server, 55 client, 25 events |

The `self` trap is guarded three ways, and the third is the one that matters:

- `test/binding.lua` (27 assertions) — argument slots of the original proxy set,
  with a canary proving the stub models the shift.
- `test/contracts.lua` (163 assertions) — argument slots of **every** proxy,
  including the four that reorder before delegating, the export each one
  resolves to, the discriminator arguments (`sync.ped` vs `sync.prop`,
  `zones.box` vs `zones.sphere`), and a source-level pin on the shape of
  `exportCall` itself.
- CI greps for the bracket-call shape and for a hardcoded third-party host.

The middle one was added in this pass because the original guard had a real
hole, measured rather than assumed: swapping the argument order in
`Cis.callback.callClient` from `(name, src, ...)` to `(src, name, ...)` passed
**both** the old suite and the CI grep. Thirteen mutations were planted and
thirteen are now caught.

---

## 13. Known defects, pinned not fixed

The freeze forbids a behaviour change. These are real, reproduced, and pinned by
`test/contracts.lua` so that fixing one is a deliberate MAJOR decision rather
than an accident.

### 13.1 `Cis.framework.notify` sends the wrong argument on the client

`init.lua` defines:

```lua
function Cis.framework.notify(srcOrNil, message, kind)
    if IS_SERVER then
        return exportCall('Notify', srcOrNil, message, kind)
    end
    if message == nil then
        return exportCall('Notify', srcOrNil, kind)   -- one-arg form: correct
    end
    return exportCall('Notify', message, kind)         -- two-arg form: WRONG
end
```

The client `Notify` export takes `(message, kind)`. A consumer calling
`Cis.framework.notify('You won $500', 'success')` therefore sends `'success'` as
the **message** and `nil` as the kind. The one-argument form works. The two
branches disagree with each other, and the two-argument form is the broken one.

A scan of the product sources records `Cis.framework.notify` as consumed by tcvs,
storeRobberies and HawkEye and does not distinguish the arities, so the blast
radius is unknown. `Pinned by`: *"client notify: DEFECT PINNED — the kind is sent
in the message slot"*.

### 13.2 `Cis.db.transaction` returned nothing and burned the timeout (FIXED)

`exportAwait` calls `method(sql, params, cb)`, but `Database.Transaction` is
declared `(queries, cb)`. The completion callback arrived in a **third**
parameter the function never read, so `cb` was `nil` on entry.

Consequences, on **every** driver:

- on a non-`oxmysql` driver, the refusal callback was never invoked, the await
  never settled, the coroutine spun for the full
  `Config.Framework.Database.Timeout` (15 s by default), and the call returned
  **nothing at all** — not `false, 'transactions require oxmysql'`;
- on `oxmysql`, the driver was handed a nil callback and logged
  `Transaction parameters must be array or object, received 'undefined'`.

`Cis.db.transaction` is used by `cis_housing` and `cis_phone`, so both paid
that 15-second stall on every call.

**Fixed.** `DbTransaction` is now registered longhand rather than through
`exportAwait`, so the callback reaches slot 2. Deliberately not made
arity-aware inside `exportAwait`: exactly one method has a different shape, and
hiding a second calling convention in a shared helper is how the mismatch
happened in the first place.

Verified live on oxmysql: a `SELECT 1` transaction now completes well inside the
timeout, answers a value, and the driver logs nothing. On a non-oxmysql driver
it refuses promptly with `false, 'transactions require oxmysql'` — the string
this section previously called unreachable.

*Consumers:* `cis_housing` and `cis_phone` send oxmysql's shape — an array of
`{ query = ..., values = { ... } }` objects. An array of bare arrays is rejected
by the driver.

### 13.3 The remote-handler path shifted every argument (FIXED)

`server/callback.lua` resolved a `'resource:export'` handler as:

```lua
local target = exports[ref.resource]
fn = target[ref.export]        -- the bracket LOOKUP
...
local results = table.pack(pcall(fn, src, ...))
```

**Measured, in-VM, with no boundary in the way:** the bracket lookup *is* an
unbound method — the same trap as the bracket call form in §1. Calling
`fn('A','B','C')` delivered `('B','C')`; calling `fn(target,'A','B','C')`
delivered all three.

So a handler registered with `Cis.callback.register('name', 'res:export')`
received every one of the caller's arguments **and never `src`** — one slot
shifted, not the "zero arguments" an earlier draft of this document recorded.
The distinction decides the fix: a shift is fixed by passing the table, a drop
is not.

**Fixed.** `invoke` now calls `pcall(fn, target, src, ...)` for remote
handlers and is unchanged for local ones. A local handler is a plain function
and must keep its current call shape.

*An earlier revision of this section said the handler received zero arguments
and that this was the highest-priority unmeasured item. Both claims are wrong.
It was measured — a one-slot shift, not a drop — and the measurement is written
into the comment on `invoke` above, with the exact call shapes that show it.*

**Blast radius:** `cis_storeRobberies` calls `Cis.callback.register` but
registers a **local** function, so no shipped product was affected. The path
had simply never worked for anyone.

### 13.4 `Security.AuthorizedResources` is read once

An earlier draft recorded that it "was read once and never rebuilt; it is now re-read/
on demand". In the current source `rebuildAuthorized()` is called **once**, at
module load. Editing the list at runtime has no effect. Not changed: making it
live is a behaviour change. The list is read fresh on every **restart**, which is
the supported way.

### 13.5 Coupling seams outside the abstractions

`client/target.lua` calls the provider exports directly at 10 sites — 5
`exports.ox_target:*` and 5 `exports['qb-target']:*` — and
`client/inventory.lua` / `server/inventory.lua` call `exports.ox_inventory:*`
directly too. These sit outside the `Cis.target` / `Cis.inventory` abstraction
in a way no reader of the boundary model would expect. A third-party target or
inventory provider added in future must patch these files, not implement an
interface.

---

## 14. Changelog policy

**One page per version**, at `CHANGELOG/<version>.md`, committed with the
release. Not one running file: a running file is edited by six people and
diffed by nobody, and the question "what changed in 1.2.0" stops being answerable
once there are twenty entries.

```markdown
# 1.2.0 -- 2026-09-29

**Contract major:** 1 (unchanged)
**Schema:** 0 (unchanged)

## Added
## Changed
## Fixed
## Deprecated
## Removed
## Security
```

Rules:

- The header repeats all four numbers (§4). If any of them moved, the entry says
  which and why.
- Every entry names a consumer impact: who is affected and what they must do.
  "Fixed a typo" is not an entry; "database calls now time out at
  `Database.Timeout` instead of hanging forever" is.
- **Deprecated** entries name the shim, its `use`, and the `['until']` major.
  They must match `api.lua`; the validator is the tie-breaker.
- **Removed** entries name the major they became possible in and the shims
  removed with them.
- **Security** entries state the exposure, not just the change.

**Generation.** Where a page can be produced from what CI already knows, it is:
`api.lua` already carries `since` and `['until']` for every export and event, and
`tools/validate-api.js` can emit the Added and Removed sections directly. The
human-written parts are Changed, Fixed and Security, which are judgements about
behaviour and are the reason the page exists. The generator is
`tools/validate-api.js --changelog <version>`; until it lands, the `api.lua`
diff for the two files is the mechanical part and is a one-line command.

---

## 15. What this document does not cover

Stated so nobody infers more than is here.

- **It describes this source tree, not a deployed install.** Everything pinned
  above was read out of the code in this repository and is accurate about that
  code and about nothing outside it. A server running a different build of
  `cis_libs` may behave differently, and the shims' behaviour in production
  cannot be verified from here — only the live harness, on a running server,
  verifies that.
- **Return-value shapes.** Documented in `DOCUMENTATION.md`,
  not machine-checked here.
- **The integration harness.** `cis_libstest` (89 tests across both realms) needs
  a live fxserver and is not run in CI. Everything touching a native is
  integration-tested, not unit-tested.

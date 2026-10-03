# cis_libs — documentation

**Version 2.0.0.** This document describes the split architecture. The 1.x
document, which describes a single resource that owned tables, a framework
bridge, a database layer and a doorlock, is kept as `DOCUMENTATION-1.x.md` for
anyone upgrading. It is archived, not current: several things in it are no
longer true of this resource, and the file that says so is this one.

---

## §0 — Read this first

Three sentences that everything else follows from.

1. **`cis_libs` owns no table, reads no config file, and calls no third-party
   resource.** It is a boundary, not an implementation.
2. **The `Cis.*` API did not change.** Every name and signature from 1.0 still
   works. A consumer adds the same one manifest line and calls the same
   functions.
3. **Those two facts are both enforced by the test suite**, not asserted in a
   README. See §19.

If you are upgrading and something returns `nil` where it used to return a
value, the cause is almost certainly a product that is not started. Run
`cis_debug`. §8 is the command and §8.3 is the table it prints.

---

## §1 — Why the split exists

The platform is four resources, and the line between them is **who is allowed
to hold data**.

| Resource | Owns tables | Needs a licence key | Can be deleted freely |
|---|---|---|---|
| `cis_libs` | **no, ever** | no | yes |
| `cis_core` | yes (one: `cis_migrations`) | with purchase | no |
| `cis_bridge` | no | with purchase | no |
| `cis_keys` | yes | yes | no |

A server owner deletes libraries when they are unhappy. They cannot delete
their player records. **That property is what makes trying the platform safe**,
and safe trial is the single biggest driver of adoption. A free library that
quietly creates a table on someone's database turns "uninstall" into a data-loss
decision, and the property is gone.

So the split is not an aesthetic preference. It is the one design decision the
whole platform rests on, and `cis_libs`' test suite asserts it directly.

### 1.1 The dependency points the wrong way on purpose

```
cis_libs          boundary, primitives. Knows the SHAPE of a capability.
   ▲  ▲  ▲        and nothing about who provides it.
   │  │  │
   │  │  └── cis_keys        doors, keys, PINs, guest passes, ledger
   │  └───── cis_bridge      one adapter per third-party target
   └──────── cis_core        framework, state, config, migrations
```

A library that named its siblings would have a hard dependency on all of them,
and a library that can be thrown away cannot be wired to things that must be
bought. The dependency points inward: products register into the library, and
the library never calls them by name.

**Every product is optional.** `cis_libs` alone boots, serves zones, callbacks,
entity sync, caching and logging, and answers every capability call it cannot
serve with a refusal and a reason.

---

## §2 — The capability registry

`shared/registry.lua`. Pure, no natives, fully unit-tested.

A capability is a slot. A product registers a provider into it. `cis_libs`
forwards to whoever holds the slot.

```lua
-- in cis_core, at boot
exports['cis_libs']:RegisterCapability('framework', 'cis_core:CisCoreFramework')

-- in cis_libs
local ok, reason = CisRegistry.call('framework', 'NormalizedPlayer', src)
```

### 2.1 The registration form is a string, and it must be

```lua
RegisterCapability('database', 'cis_bridge:CisBridgeDatabaseOxmysql')  -- correct
RegisterCapability('database', function() ... end)                     -- WRONG
```

A function cannot be **sent** across the exports boundary. It arrives as `nil`,
the slot looks empty, and the failure surfaces as "the database is nil" hours
later. A function can be **returned**, so a `resource:Export` string — which
`cis_libs` resolves by asking for the reference back — is the only form that
works across a resource boundary. This is the same mechanism `RegisterCallback`
has always used for its `'resource:export'` form.

`CisRegistry` tests for a *callable* (`type == 'function'` **or**
`__cfx_functionReference`), never for `type == 'function'`. A reference that
crossed a boundary reports `type() == 'table'` while being perfectly callable,
and testing for `'function'` is the single most common way to break a
cross-resource registration. It fails silently.

### 2.2 First registration wins

A second resource cannot take a held slot. The attempt is refused and logged
with the name of the holder.

This is **not** a defence against a hostile resource — anything in your
`server.cfg` already has every permission you have, and pretending otherwise
would be theatre. It guards the two failures that actually happen:

- a bridge that registers twice on a partial restart and silently replaces a
  working provider;
- two products on one server that both believe they own the database.

Re-registering from the *same* resource is allowed and is not a conflict — that
is what a restart handler looks like.

### 2.3 The slots

| Slot | Provided by | Contract |
|---|---|---|
| `framework` | `cis_core` | `GetPlayer`, `GetPlayers`, `GetPlayerJob`, `NormalizedPlayer`, `Notify`, `ShowNotification`, `IsLoaded`, `HasPermission`, … |
| `database` | `cis_bridge` | `query`, `single`, `scalar`, `insert`, `update`, `transaction`, `ready` |
| `target` | `cis_bridge` | `available`, `create`, `remove`, `exists`, `named` |
| `inventory` | `cis_core` | `Count`, `Add`, `Remove`, `Has`, `Snapshot` |
| `inventoryProvider` | `cis_bridge` | `Name`, `Available`, `Count`, `Add`, `Remove` |
| `doors` | `cis_keys` | `state`, `lock`, `unlock`, `add`, `addGroup`, `breakDoor`, `fixDoor`, `all`, `persisted` |
| `doorsClient` | `cis_keys` | `add`, `addGroup`, `closest`, `state` |
| `discord` | `cis_bridge` | `Log`, `QueueDepth` |
| `security` | `cis_core` | `drop` |
| `dataProbe` | `cis_keys` | `hasRows` |
| `migration` | `cis_migrate` | `plan`, `apply`, `sources` (one dispatcher export) |

A call names the slot's method (`count`), and the provider's table is searched
for it in a fixed order: the exact key, then the provider-side name the slot
declares (`Count(src, item)` declares `Count`), then the key with its first
letter's case flipped. So `count` and `Count` both serve, and `target.named`
reaches an adapter's `name()`. The match is cached per method and dropped when
the provider restarts. When a resource stops, every slot it owns is released, so
a call answers "no provider registered" until it registers again.

Some methods **differ by realm where the realms genuinely differ**: the server's `Notify(src, message, kind)` can address a player, the
client's `ShowNotification(message, kind)` cannot. Forcing them into one
signature would mean one realm is always handed an argument that means nothing
there.

### 2.4 What a missing capability answers

Nothing here is a silent `nil`.

| Shape | Answers | Why |
|---|---|---|
| `Cis.db.query` | `nil, reason` | A `nil` here means "timed out or no driver", never "no rows" — and collapsing the two is how a slow query becomes a missing one |
| `Cis.db.transaction` | `false, reason` | A refusal has to arrive *before* the timeout, not instead of it. A caller holding a write lock for 15 seconds to be told no is worse than an error |
| `Cis.inventory.count` | `0` | A count is always a number; `if not count` is the test most consumers write |
| `Cis.inventory.add` | `false` | A mutation answers a boolean |
| `Cis.doors.get` | `nil` | `nil` is "no such door" and `false` is "unlocked", and they are **deliberately distinct** — a consumer that collapses them cannot tell a typo from an open door |
| `Cis.doors.setState` | `0` | Doors changed |
| `Cis.zones.*`, `Cis.target.*` | `false, reason` | The reason strings are published behaviour; a consumer across the boundary cannot read this console |

Each missing slot method warns **once**, not per call. A per-call warning on a
hot path is a denial-of-service against the operator's console.

---

## §3 — The three rules

These are unchanged from 1.0 and still the most expensive things to get wrong.

### 3.1 Colon form only

```lua
exports['cis_libs']:Notify(src, msg, 'error')    -- correct
exports['cis_libs']['Notify'](src, msg, 'error')  -- WRONG
```

The bracket form is an **unbound method** and expects the exports table as its
first argument. Calling it without self shifts every argument one slot left and
raises nothing. A zone created as `(kind, name, coords)` arrives as
`(name, coords, size)`, silently turning the name into the coordinates.

This exact mistake was in this library, in this helper. CI greps for it.

The **lookup** is broken the same way: `exports[res][name]` is a bare function
expecting the exports table first, so reading it and calling it with real
arguments is the same shift. Passing the table explicitly is exactly what the
colon syntax does.

### 3.2 A function can be handed back, but not sent

```lua
-- NEVER: onEnter arrives nil and silently never fires
Cis.zones.box('shop', centre, size, { onEnter = function() ... end })

-- CORRECT: event names are strings and do cross
Cis.zones.box('shop', centre, size, {
    onEnterEvent = 'shop:client:enterShop',
    onExitEvent  = 'shop:client:leaveShop',
    insideEvent  = 'shop:client:insideShop',
})
```

The same applies to `Cis.player.on(key, fn)`: the returned teardown function
survives the boundary as a callable reference table, but the listener argument
is dropped. Gate the listener on your own flag and drop it in `onResourceStop`.

### 3.3 Never `shared_script` a stateful file

`init.lua` is the only file meant for consumers. It is a **proxy**: it copies
into your Lua VM and forwards across the exports boundary. Everything else in
this resource holds process-global state, and `shared_script`ing one of those
multiplies its native work by your resource count. §17 lists them.

---

## §4 — `Cis.*`

### 4.1 Player (client)

| Call | Cost | Notes |
|---|---|---|
| `Cis.player.ped()` | free | |
| `Cis.player.coords()` | free | Memoised to one native per frame per calling VM. Keys on frame **and** ped, because a respawn hands out a new ped inside a still-current frame |
| `Cis.player.heading()` | free | Refreshed on the watchdog tick |
| `Cis.player.vehicle()` | crosses | `nil`, never `0`, when on foot — a consumer treating `0` as a handle gets a nil-index crash somewhere else |
| `Cis.player.weapon()` | crosses | A fresh table on change, never a mutation of the previous one: a reference held across frames is a snapshot |
| `Cis.player.serverId()` | crosses | Cache it at spawn; it does not change while connected |
| `Cis.player.on(key, fn)` | crosses | See §3.2 |

The three free reads are free because they are answered inside your own VM. The
rest cross — a marshal and a return trip each. That is fine at a zone creation
or a keypress and ruinous in a `Wait(0)` loop. Subscribe to `Cis.player.on`
instead.

### 4.2 Zones (client)

```lua
local ok, reason = Cis.zones.box(name, centre, size, options)
Cis.zones.sphere(name, centre, radius, options)
Cis.zones.poly(name, points, options)
Cis.zones.remove(name)              -- false, deliberately: removing twice is not an error
Cis.zones.contains(name, point)
```

Options: `onEnter`/`onExit`/`inside` (functions — see §3.2), `onEnterEvent` /
`onExitEvent` / `insideEvent` (strings, cross), `insideInterval` (default 500),
`minZ` (default `-1000.0`), `maxZ` (default `10000.0`), `heading`/`rotation`.

Pure and dependency-free: a spatial hash over `shared/grid.lua`, plus
`GetGameTimer`. No PolyZone, no ox_lib. `GetPolyzones()` is a deprecated
name-only shim kept for 1.x callers; there is no PolyZone adapter and there is
not going to be one.

> **`onEnterEvent` / `onExitEvent` / `insideEvent` are CLIENT CLAIMS.**
>
> Containment is computed on the client and the event carries whatever the
> client computed. cis_libs cannot validate your handler, and nothing here can
> make the claim true: a modified client fires the event from anywhere, for any
> player, at any moment. That is fine for "show a prompt" and it is a cheat
> vector for anything that grants something.
>
> If the handler matters: register it with `Cis.net.on(name, handler)` so it
> receives an **injected `source`** a client cannot choose, and is rate limited
> — a bare `RegisterNetEvent` gets neither. Then have the server check the claim
> is plausible. For anything where being wrong is expensive, use a
> server-verified zone instead (`Cis.zones.server.box/poly/sphere`), which
> computes containment server-side from server-side ped coordinates and cannot
> be forged at the cost of a timer.

### 4.3 Callbacks (both)

```lua
Cis.callback.register(name, handler)        -- handler, or 'resource:Export'
Cis.callback.await(name, ...)               -- yields; nil at the timeout
Cis.callback.call(name, cb, ...)
Cis.callback.callClient(src, name, cb, ...) -- server only
Cis.callback.awaitClient(src, name, ...)    -- server only
```

`'resource:Export'` is the form that works **from a consumer**: the handler is
not sent, it is fetched back on demand. It arrives as a callable reference
table, so it reports `type() == 'table'` — do not test for `'function'`. Its
return value may still come back `nil`; signal by side effect or net event.

`Cis.callback.await` **raises** rather than returning `false` when no handler
is registered. That is deliberate: a silent `false` is indistinguishable from a
handler that returned `false`, and the first is a bug you want to hear about
immediately.

**The wire capacity differs by direction, and the difference is deliberate.**

A **client** handler's answer travels back to the server with every value it
returned — including a `nil` in the middle, and a seventh value onward. That is
the direction real payloads travel, so nothing is dropped.

A **server** answer travelling *to* a client carries at most **six** values; a
seventh is dropped. That cap predates the library and is pinned as a known
defect in §12: widening it changes the wire for every client already built
against it. A server handler needing more than six values should return a single
table.

### 4.4 Sync (both)

```lua
Cis.sync.ped(data)      -- -> id | nil
Cis.sync.prop(data)
Cis.sync.vehicle(data)
Cis.sync.remove(id)     -- -> boolean; false means "no such entity" or "refused"
```

`kind` leads and is the discriminator, so three exports collapse into one
`SyncCreate` with no ambiguity. Calling again with the same id **moves** the
entity, as long as model and kind are unchanged.

Server-owned datasets. Hydration is always a **snapshot**, because OneSync
entity-pool culling makes deltas unsound: a client that never saw an entity
cannot apply the increments that followed it.

### 4.5 Database (server)

```lua
Cis.db.query(sql, params)      -- rows
Cis.db.single(sql, params)     -- row | nil
Cis.db.scalar(sql, params)     -- cell
Cis.db.insert(sql, params)     -- id
Cis.db.update(sql, params)     -- affected
Cis.db.transaction(queries)    -- oxmysql's shape only
```

All five yield and answer `nil` at `Config.Framework.Database.Timeout`. **A
`nil` means "timed out or no driver", never "no rows"** — use `single` or
`scalar` to ask about emptiness. That distinction is the whole contract and it
is why these are forwards rather than wrappers that normalise the `nil` away.

`transaction` takes a **list** of oxmysql `{ query, values }` entries, refuses
promptly on any other driver, and is the only call here that answers
`false, reason`.

### 4.6 Framework (server)

```lua
Cis.framework.player(src)   -- { id, name, job, identifier, money, metadata }
Cis.framework.notify(src, message, kind)
```

`Cis.framework.notify` on the **client** has a known defect, pinned rather than
fixed: the two-argument form sends `kind` in the *message* slot. Correcting it
is a MAJOR contract change, and `test/contracts.lua` asserts the current
behaviour so that a fix cannot land by accident. If that assertion ever flips,
the fix landed on purpose.

### 4.7 Inventory (both)

```lua
Cis.inventory.count(src, item)   -- server
Cis.inventory.add(src, item, amount, metadata)
Cis.inventory.remove(src, item, amount)
Cis.inventory.has(src, item, amount)
Cis.inventory.count(item)        -- client -- a HINT, see below
Cis.inventory.has(item, amount)
```

`Cis.inventory.count` is the one name in this file that exists on **both** sides
with a different signature. A consumer sharing a helper between realms has to
branch on `IsDuplicityVersion()` rather than on the function.

A client count is a **hint** and always was: a snapshot the server pushed, up to
one inventory event stale. **Never gate a server-side action on it.** The server
re-checks, and a player holding a gun at the moment of the check is holding it
regardless of what their client last reported.

### 4.8 Doors

```lua
Cis.doors.add(data)          -- true once registered, false when refused
Cis.doors.setState(id, locked)  -- a REQUEST on the client, applied on the server
Cis.doors.get(id)            -- the client's cached hint, not authority
```

Provided by `cis_keys`. The names and shapes are unchanged, so a consumer's
code does not change — but the credential model behind them is new, and the
1.x doorlock's job-scoped groups are the thing being replaced. See the
`cis_keys` README for why, and read it before shipping a robbery resource: a
job-scoped group means standing at one door of a bank opens every door in that
bank.

### 4.9 Security and networking (server)

```lua
Cis.security.report(src, reason)
Cis.net.on(eventName, fn)
```

`Cis.net.on` routes through the same gate as everything else: `src` injected as
the first argument, non-numeric sources dropped, a fixed-window per-(src, event)
rate limit, and a `pcall` so a bug in a handler is logged against the event name
rather than becoming a script error.

A **function** sent as `fn` is dropped, so from a consumer the event still
registers and is still checked but the handler arrives `nil`. Use
`RegisterNetEvent` plus your own source check today.

### 4.10 Logging

```lua
Cis.log.debug(message)  -- gated on Config.Printing.Debug, usually silent
Cis.log.info(message)
Cis.log.warn(message)
Cis.log.error(message)
```

`debug` is gated and the other three always print. That asymmetry is
deliberate: a warning suppressed by a debug flag is a warning nobody ever sees.
`tryExport` rather than a hard call, so a resource that stopped before this one
does not take the caller's thread down over a log line.

---

## §5 — The exports boundary

`exports['cis_libs']` is a **contract**, not an implementation detail. What is
published is in `api.lua`, and `npm run test:api` fails if that file and the
real registered surface ever differ.

<!-- generated:begin -->

| Export | Realm | Signature | Since | Notes |
|---|---|---|---|---|
| `AddDoorGroup` | both | `(groupData)` | 1.0.0 | no proxy equivalent; exports["cis_libs"]:AddDoorGroup(groupData) |
| `AddDoorToSystem` | both | `(newDoorData, internal)` | 1.0.0 | Cis.doors.add(doorData) **deprecated** unstable |
| `AutoLogError` | both | `(err, event)` | 1.0.0 | Cis.log.error(message) from inside a pcall |
| `AwaitCallback` | both | `(name, ...)` | 1.0.0 | Cis.callback.await(name, ...) |
| `AwaitCallbackClient` | server | `(name, target, ...)` | 1.0.0 | Cis.callback.awaitClient(src, name, ...) |
| `BreakDoor` | server | `(identifier)` | 1.0.0 | no proxy equivalent; exports["cis_libs"]:BreakDoor(identifier) |
| `CallCallback` | both | `(name, cb, ...)` | 1.0.0 | Cis.callback.call(name, cb, ...) |
| `CallCallbackClient` | server | `(name, target, cb, ...)` | 1.0.0 | Cis.callback.callClient(src, name, cb, ...) |
| `CheckResourceVersion` | server | `(resourceName, resourceUrl, currentVersion)` | 1.0.0 | Config.CheckVersion and Config.VersionCheckUrl **deprecated** unstable |
| `CreatePed` | client | `(model, coords, heading, options)` | 1.0.0 | no proxy equivalent; returns 0 on an invalid or unloaded model |
| `CreateSafeCallback` | server | `(name, cb)` | 1.0.0 | Cis.callback.register(name, handler); this skips the name and handler checks **deprecated** unstable |
| `CreateTarget` | client | `(zoneType, name, coords, size, options)` | 1.0.0 | Cis.target.add(zoneType, name, coords, size, options) |
| `CreateZone` | client | `(kind, name, a, b, options)` | 1.0.0 | Cis.zones.box / Cis.zones.poly / Cis.zones.sphere |
| `DatabaseDelete` | server | `(sql, params, cb)` | 1.0.0 | Cis.db.query(sql, params) **deprecated** unstable |
| `DatabaseExecute` | server | `(query, params, cb)` | 1.0.0 | Cis.db.query(sql, params) **deprecated** unstable |
| `DatabaseFetchAll` | server | `(query, params, cb)` | 1.0.0 | Cis.db.query(sql, params) **deprecated** unstable |
| `DatabaseFetchOne` | server | `(query, params, cb)` | 1.0.0 | Cis.db.single(sql, params) **deprecated** unstable |
| `DatabaseInsert` | server | `(sql, params, cb)` | 1.0.0 | Cis.db.insert(sql, params) **deprecated** unstable |
| `DatabaseUpdate` | server | `(sql, params, cb)` | 1.0.0 | Cis.db.update(sql, params) **deprecated** unstable |
| `DbInsert` | server | `(sql, params)` | 1.0.0 | Cis.db.insert(sql, params) |
| `DbQuery` | server | `(sql, params)` | 1.0.0 | Cis.db.query(sql, params) |
| `DbScalar` | server | `(sql, params)` | 1.0.0 | Cis.db.scalar(sql, params) |
| `DbSingle` | server | `(sql, params)` | 1.0.0 | Cis.db.single(sql, params) |
| `DbTransaction` | server | `(queries)` | 1.0.0 | Cis.db.transaction(queries). oxmysql only; queries are oxmysql array-of-{query, values} entries |
| `DbUpdate` | server | `(sql, params)` | 1.0.0 | Cis.db.update(sql, params) |
| `DebugLog` | client | `(message)` | 1.0.0 | Cis.log.debug(message) |
| `DetectDatabase` | both | `(configured)` | 2.0.0 | Asks the server which driver is running. Returns { name, resource, version, how, reason } |
| `DetectFramework` | both | `(configured, custom)` | 2.0.0 | Asks the server what framework it is actually running. Returns { name, resource, version, how, reason } |
| `DrawText3D` | client | `(x, y, z, text, settings)` | 1.0.0 | no proxy equivalent |
| `FixDoor` | server | `(identifier)` | 1.0.0 | no proxy equivalent; exports["cis_libs"]:FixDoor(identifier) |
| `GetAllDoorData` | server | `()` | 1.0.0 | no proxy equivalent; the full door and group tables |
| `GetAuditLog` | server | `(limit)` | 2.2.0 | The capability and configuration change log, newest last. Gated on Security.AuthorizedResources like every other mutating call. Entries carry resource and slot names and never a player name, identifier or IP. Bounded by Config.AuditLines, default 500 |
| `GetCachedHeading` | client | `()` | 1.0.0 | Cis.player.heading(), which reads the native directly in a consumer VM |
| `GetCachedPed` | client | `()` | 1.0.0 | Cis.player.ped(), which reads the native directly in a consumer VM |
| `GetCachedServerId` | client | `()` | 1.0.0 | Cis.player.serverId() |
| `GetCachedVehicle` | client | `()` | 1.0.0 | Cis.player.vehicle() |
| `GetCachedWeapon` | client | `()` | 1.0.0 | Cis.player.weapon() |
| `GetCapabilities` | both | `()` | 2.0.0 | The one call that answers "which of my four resources is actually running". Returns { [slot] = { owner, resolved } } |
| `GetClientConfig` | client | `()` | 1.0.0 | no proxy equivalent; the config the server sent to this client |
| `GetClientLogging` | client | `()` | 1.0.0 | Cis.log.debug / info / warn / error |
| `GetClosestDoor` | client | `()` | 1.0.0 | no proxy equivalent; exports["cis_libs"]:GetClosestDoor() |
| `GetClosestVehicle` | client | `()` | 1.0.0 | no proxy equivalent; a 5 unit forward ray, then a 5 unit radius search |
| `GetConfigSummary` | server | `()` | 1.0.0 | no proxy equivalent; the non-secret half of the server config |
| `GetCurrentWeaponData` | client | `(ped)` | 1.0.0 | Cis.player.weapon() |
| `GetDiagnostics` | both | `()` | 2.2.0 | Counts, never player data: capability slots and owners, sync records by owner, pending callbacks, net handlers, error and warning counters, memory and uptime. The harness takes one before and after every case and compares, which is the only way a cleanup claim can be checked |
| `GetDiscordConfig` | server | `()` | 2.0.0 | The outbound/webhook configuration SetConfig was handed, for the capability that does the sending. Server realm only -- it holds webhook URLs and is deliberately not on the client payload whitelist |
| `GetDiscordQueueDepth` | server | `()` | 1.0.0 | no proxy equivalent; queued message count and dropped count |
| `GetDistanceBetweenCoords` | client | `(x1, y1, z1, x2, y2, z2)` | 1.0.0 | no proxy equivalent |
| `GetDoorState` | both | `(doorId)` | 1.0.0 | Cis.doors.get(id) |
| `GetFramework` | both | `()` | 1.0.0 | Cis.framework.player(src) on the server; Cis.framework.notify on the client. Not an API: it returns a table of callable references **deprecated** unstable |
| `GetGlobals` | client | `()` | 1.0.0 | Cis.player.* and Cis.sync.*; there is no single replacement **deprecated** unstable |
| `GetKnownTargets` | both | `()` | 2.0.0 | The ordered framework and driver tables detection uses. Shared so a product cannot disagree with the debug output about what is running |
| `GetLastRefusal` | server | `()` | 2.2.0 | Read after a nil/false answer from a capability export to learn WHY it was refused. Returns a sentence naming the missing or failing capability, or nil when the last call succeeded. Additive: no existing return shape changes |
| `GetLibsPrefix` | server | `()` | 1.0.0 | no proxy equivalent; the configured Security.EventPrefix |
| `GetLogging` | server | `()` | 1.0.0 | Cis.log.debug / info / warn / error |
| `GetNormalizedPlayer` | server | `(src)` | 1.0.0 | Cis.framework.player(src) |
| `GetOnlineJobCount` | server | `(jobs)` | 1.0.0 | no proxy equivalent; the callback cis_libs:getOnlineJobCount |
| `GetPlayerVehicleSeat` | client | `()` | 1.0.0 | Cis.player.vehicle(), second return value |
| `GetPolyzones` | client | `()` | 1.0.0 | Cis.zones.poly / Cis.zones.remove / Cis.zones.contains **deprecated** unstable |
| `GetSelfCheck` | server | `()` | 2.2.0 | The boot self-check as data: { ok, problems = { { code, message, fix } } }. Each problem names the change that resolves it |
| `GetSyncedEntities` | client | `()` | 1.0.0 | no proxy equivalent; the id-to-handle table of everything this client spawned |
| `GetTableSize` | client | `(t)` | 1.0.0 | no proxy equivalent |
| `GetVehicleProperties` | client | `(vehicle)` | 1.0.0 | no proxy equivalent; the full property snapshot used by sync |
| `GetZoneDebug` | client | `()` | 1.0.0 | no proxy equivalent; the last grid pass cost in milliseconds |
| `InventoryAdd` | server | `(src, item, amount, metadata)` | 1.0.0 | Cis.inventory.add(src, item, amount, metadata) |
| `InventoryCount` | both | `(src, item)` | 1.0.0 | Cis.inventory.count(item) on the client, Cis.inventory.count(src, item) on the server |
| `InventoryHas` | both | `(src, item, amount)` | 1.0.0 | Cis.inventory.has(...) |
| `InventoryRemove` | server | `(src, item, amount)` | 1.0.0 | Cis.inventory.remove(src, item, amount) |
| `InvokingAllowed` | server | `()` | 1.0.0 | no proxy equivalent; ask before mutating. This is the supported way to avoid a refusal |
| `IsReady` | client | `()` | 1.0.0 | Cis.isReady, or Cis.ready(cb) |
| `LockDoors` | server | `(identifier)` | 1.0.0 | Cis.doors.setState(identifier, true) **deprecated** unstable |
| `LogDebug` | both | `(message, discordType)` | 1.0.0 | Cis.log.debug(message) |
| `LogError` | both | `(message, discordType, errorInfo)` | 1.0.0 | Cis.log.error(message) |
| `LogInfo` | both | `(message, discordType)` | 1.0.0 | Cis.log.info(message) |
| `LogWarn` | both | `(message, discordType)` | 1.0.0 | Cis.log.warn(message) |
| `Notify` | both | `(src, message, kind)` | 1.0.0 | Cis.framework.notify(...). With a framework provider registered the call passes through to it untouched; with none, cis_libs delivers it itself through the same guards NotifyClient uses, so a server with no framework does not go mute and does not become the unbounded path. The two-argument client form sends `kind` in the message slot; this is pinned as a known defect in test/contracts.lua and is a MAJOR change to correct |
| `NotifyClient` | server | `(src, message, kind)` | 2.0.0 | Called by a product to show a notification to one client, without hardcoding the event name owned by this library. Answers `false, reason` for a src that is not a connected player, truncates a message past 512 characters, and allows 10 a second per (src, calling resource) |
| `OnPlayerCache` | client | `(key, cb)` | 1.0.0 | Cis.player.on(key, cb). The cb cannot cross the boundary; use a net event |
| `PublishInventory` | server | `(src)` | 2.0.0 | Called by the inventory service. Pushes cis_libs:client:inventory to one player |
| `PublishJobUpdate` | server | `(job, src)` | 2.0.0 | Called by cis_core when a player changes job. Fires cis_libs:jobUpdated, so the event name stays owned by this library |
| `PublishPlayerLoaded` | server | `(job, src)` | 2.0.0 | Called by cis_core when a player object exists. Fires cis_libs:playerLoaded |
| `RandomFloat` | client | `(lower, greater)` | 1.0.0 | no proxy equivalent |
| `RateOk` | server | `(src, name, windowMs, maxHits)` | 1.0.0 | no proxy equivalent; a resource may share the library rate limiter |
| `RegisterCallback` | both | `(name, handler)` | 1.0.0 | Cis.callback.register(name, handler) |
| `RegisterCapability` | both | `(slot, provider)` | 2.0.0 | Called by cis_core, cis_bridge and cis_keys with (slot, "resource:Export"). First registration wins |
| `RemoveNearWatcher` | client | `(id)` | 2.2.0 | Cis.player.nearStop(id); the id WatchNear returns as its second value |
| `RemoveTarget` | client | `(name, isPed)` | 1.0.0 | Cis.target.remove(name, isPed) |
| `RemoveZone` | client | `(name)` | 1.0.0 | Cis.zones.remove(name) |
| `RequestInventorySync` | client | `()` | 2.0.0 | Cis.inventory.count is a hint. This asks for a fresh one. Client only |
| `RequestLockDoors` | client | `(identifier)` | 1.0.0 | Cis.doors.setState(id, true) on the client |
| `RequestModelTimeout` | client | `(model, timeout)` | 1.0.0 | Cis.streaming.model(model, timeout) |
| `RequestUnlockDoors` | client | `(identifier)` | 1.0.0 | Cis.doors.setState(id, false) on the client |
| `Round` | client | `(num, numDecimalPlaces)` | 1.0.0 | no proxy equivalent; math round to n places |
| `SecureNetOn` | server | `(name, fn, opts)` | 1.0.0 | Cis.net.on(name, fn, opts) -> true when the event was bound |
| `SecurityReport` | server | `(src, reason)` | 1.0.0 | Cis.security.report(src, reason) |
| `SendDiscordLog` | server | `(webhookURL, title, message, color, ping)` | 1.0.0 | Cis.log.info with a discordType; no proxy equivalent for a raw webhook push |
| `SetConfig` | server | `(config, security, discord)` | 2.0.0 | Called by cis_core at boot with (config, security, discord). First registration wins; a second is refused and named. `security.AllowAnyResource` is the 2.2.0 opt-in escape hatch: with it true an EMPTY AuthorizedResources stops meaning restrictive, and the console warns on every boot |
| `SetDropPlayerHandler` | server | `(provider)` | 2.0.0 | Called by whoever ships the config, with "resource:Export". A FUNCTION cannot be sent across the boundary, which is why this exists |
| `SetVehicleProperties` | client | `(vehicle, props, fixVehicle)` | 1.0.0 | no proxy equivalent; diffs against the last applied snapshot |
| `SyncCreate` | server | `(kind, data)` | 1.0.0 | Cis.sync.ped / Cis.sync.prop / Cis.sync.vehicle |
| `SyncRemove` | server | `(id)` | 1.0.0 | Cis.sync.remove(id) |
| `TargetAvailable` | client | `()` | 1.0.0 | no proxy equivalent; true when a configured target provider is started |
| `TargetExists` | client | `(name)` | 1.0.0 | Cis.target.exists(name) |
| `TriggerLibCallback` | client | `(name, cb, ...)` | 1.0.0 | the client-to-server round trip whose callback receives only the results |
| `TryAwaitCallback` | both | `(name, ...)` | 2.1.0 | Cis.callback.tryAwait(name, ...) -> ok, ... on success; false, reason on a refusal |
| `UnlockDoors` | server | `(identifier)` | 1.0.0 | Cis.doors.setState(identifier, false) **deprecated** unstable |
| `UnregisterCapability` | server | `(slot)` | 2.0.0 | Called by a product on shutdown or handover. Only the slot owner may release it |
| `UpdateTarget` | client | `(name, newOptions)` | 1.0.0 | Cis.target.update(name, options) |
| `WaitCapability` | server | `(slot, timeoutMs)` | 2.1.0 | Waits up to timeoutMs for a capability slot to be filled. Returns true and the owner, or nil and a reason naming the slot. No proxy equivalent -- a consumer waits from its own resource. |
| `WaitReady` | both | `(timeout)` | 1.0.0 | Cis.ready(cb, timeout) or Cis.wait(timeout) |
| `WatchNear` | client | `(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)` | 1.0.0 | Cis.player.near(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent) |
| `ZoneContains` | client | `(name, point)` | 1.0.0 | Cis.zones.contains(name, point) |

| Event | Since | Payload |
|---|---|---|
| `cis_libs:capabilityChanged` | 2.1.0 | both realms: ({ slot, action, owner, previousOwner, resolved }) |
| `cis_libs:cb` | 1.0.0 | client to server and server to client: (name, key, ...) |
| `cis_libs:cb:res` | 1.0.0 | client: (key, ok, ...) resolving an outstanding callback |
| `cis_libs:cb:serverRes` | 1.0.0 | server: (key, ok, ...) resolving an outstanding client callback |
| `cis_libs:client:getData` | 1.0.0 | server to client: ({ Config, EventPrefix }) on join. DoorData was removed in 2.0.0 |
| `cis_libs:client:inventory` | 1.0.0 | server to client: ({ [itemName] = count }), pushed by PublishInventory |
| `cis_libs:client:showNotification` | 1.0.0 | server to client: (message, kind) |
| `cis_libs:client:syncRemove` | 1.0.0 | server to client: (id) despawn a synced entity |
| `cis_libs:client:syncUpsert` | 1.0.0 | server to client: (record) for a nearby synced entity |
| `cis_libs:jobUpdated` | 1.0.0 | server to client: ({ name, grade }), fired by PublishJobUpdate |
| `cis_libs:playerLoaded` | 1.0.0 | server to client: (job), fired by PublishPlayerLoaded |
| `cis_libs:server:getData` | 1.0.0 | client to server: no arguments, requests the config payload |
| `cis_libs:server:inventorySync` | 1.0.0 | client to server: no arguments, requests an inventory snapshot |


<!-- generated:end -->
listed in `fxmanifest.lua` — loading it would put a table into every Lua state
at every boot for no gain. Read it on demand.

`api = 1` is the **contract major**, not the product version. It did not move
in 2.0.0, because no `Cis.*` name or signature changed.

---

## §6 — Net events this library owns

Every name below is fired or listened for **by this resource**. That is the
rule, and it is why the doorlock names and the framework event names are not
here — they belong to `cis_keys` and `cis_core` respectively. A net event name
that moves between resources is a name a product can rename without anyone
noticing until a consumer silently stops hearing about it.

<!-- generated:begin -->

| Event | Direction | Payload |
|---|---|---|
| `cis_libs:cb` | both | `(name, key, ...)` |
| `cis_libs:cb:res` | server → client | `(key, ok, ...)` |
| `cis_libs:cb:serverRes` | client → server | `(key, ok, ...)` |
| `cis_libs:server:getData` | client → server | none |
| `cis_libs:client:getData` | server → client | `({ Config, EventPrefix })` |
| `cis_libs:client:showNotification` | server → client | `(message, kind)` |
| `cis_libs:client:inventory` | server → client | `({ [item] = count })` |
| `cis_libs:server:inventorySync` | client → server | none |
| `cis_libs:client:syncUpsert` | server → client | `(record)` |
| `cis_libs:client:syncRemove` | server → client | `(id)` |
| `cis_libs:jobUpdated` | server → client | `({ name, grade })` |
| `cis_libs:playerLoaded` | server → client | `(job)` |

<!-- generated:end -->

`jobUpdated` and `playerLoaded` used to be fired by the framework layer. They
are now fired **here**, by a product calling `PublishJobUpdate` /
`PublishPlayerLoaded`. The name and the payload are unchanged, so a consumer
listening for them keeps working across a framework change — which is the whole
reason they stayed in this file.

**`DoorData` was removed from the `getData` payload in 2.0.0.** It was every
door on the server, walked to every connected player. Read the door state
through `Cis.doors.get` for the one you want.

---

## §7 — Configuration

`cis_libs` has no config file. `shared/defaults.lua` states the floor, and
`cis_core` hands over the operator's table through `SetConfig`.

| Key | Default | Notes |
|---|---|---|
| `CheckVersion` | **`false`** | Off is a security decision, not an oversight. When on, every boot fires an HTTPS GET to a hardcoded host with no operator opt-in. A commercial product should not phone home. |
| `CallbackTimeout` | `10000` | Raising is safe. **Lowering is the risky direction**: a `nil` that means "too early" is indistinguishable from a `nil` that means "no such thing". |
| `UpdateInterval` | 1000 each | Event-driven with a timer as a safety net. Each tick is ~10 natives plus a vector4 per player. 2000–3000 is usually indistinguishable in game. |
| `AimingCheckType` | `"default"` | `IsPlayerFreeAiming()`. `"configFlag"` is **not** the aiming state on current builds and reports false almost always. |
| `Framework.Type` | `"AUTO"` | `AUTO` asks the server what is running rather than trusting the name. |
| `Framework.Database.Type` | `"AUTO"` | |
| `Sync.Enabled` | `true` | |
| `Printing.Debug` | `false` | Verbose by design, some of it per-zone and per-entity. |
| `Printing.UseDiscordLogs` | **`false`** | The master switch for everything outbound. While false, nothing is sent anywhere and a placeholder webhook is inert. |

`Security.EventPrefix` is `"cis_libs"` and **should stay that way**. Changing it
moves every event name; any resource that triggers them directly must change in
the same edit, and the failure is silence, not an error.

### 7.1 First supplier wins

`SetConfig` refuses a second supplier and names the winner. cis_libs's own
defaults are **not** a supplier — they are the floor, and a product replacing
them is the intended path.

### 7.2 What a client is told

A hand-built whitelist in `shared/config.lua`, not a copy with secrets removed.
A key added to the server config does not reach a client until someone adds it
here. No webhook, no database block, no allow-list, no kick handler.

`CisConfigUtil.containsSecret` is asserted in the suite. Expected output of the
`cis_debug` check is `false`; `true` means the whitelist drifted and something
server-side is going to every connected player.

---

## §8 — Diagnostics

### 8.1 `cis_debug`

Server console, or in-game with admin permission. Prints derived state only: a
ready flag, one job count, one boolean about the client payload, and the
capability table. No config values, no webhook URLs, no identifiers — a debug
command that dumps config puts every secret on a server owner's screen and into
their client log.

### 8.2 The readiness gate

`cis_libs` marks itself ready when **its own** boot finishes, and does not wait
for a capability. This used to be the framework layer's job, which meant a
server running `cis_libs` alone with no `cis_core` never became ready and every
`Cis.ready`, zone create and client boot timed out on a library that was
working perfectly. "Optional" has to mean optional all the way down, including
in the boot sequence.

The **client** waits up to 15s for the server's payload, and on timeout runs on
the built-in defaults and says so. It does **not** mark itself failed: a client
that never hears back is degraded, not broken, and the old behaviour took every
`Cis.*` call on that client down with it.

### 8.3 The capability table

The answer to "why is the database nil", in one line, without reading any
source:

```
[cis_libs] --- capabilities ---
[cis_libs]   database          cis_bridge      resolved
[cis_libs]   discord           cis_bridge      resolved
[cis_libs]   doors             -               no provider installed
[cis_libs]   framework         cis_core        resolved
[cis_libs]   inventory         cis_core        resolved
[cis_libs]                      missing: snapshot
[cis_libs]   inventoryProvider cis_bridge      resolved
[cis_libs]   target            cis_bridge      resolved
[cis_libs] configuration supplied by: cis_core
```

A `missing:` line names declared methods the provider's table cannot serve in
this realm. Those calls answer the fallback value from §2.4, so the line usually
means a product version mismatch. It appears after the slot's first call.

`GetCapabilities()` returns the same data as a table, for a consumer that needs
it programmatically.

### 8.4 `cis_bridge`'s own command

```
cis_bridge                # conformance, every registered target
cis_bridge test database  # one target
```

Sends nothing, writes nothing to a player. `SKIP` is not `FAIL` — a server
without `qs-inventory` is not broken.

---

## §9 — Security

| Control | Where | What it actually does |
|---|---|---|
| Net-event gate | `server/security.lua` | `src` injected, non-numeric sources dropped, `pcall` per handler |
| Rate limit | `server/security.lua` | Fixed window, **per (src, event name)**, so a client firing four different events is not cut off by one shared budget |
| Resource allow-list | `configs` in `cis_core` | **Empty means nobody.** See §9.1 |
| Mutating gates | `server/proxy.lua` | `AddDoorToSystem` and `AddDoorGroup` check the allow-list **before** consulting the capability, so a provider added later inherits the check |
| Input validation | every entry point | Name types, coordinate nil-checks, unknown-enum refusals, refusal strings |
| Config sanitising | `CisDefaults.sanitize` | Functions dropped at any depth, recursion capped at 12 |
| Registration depth | `CisRegistry` | Unbounded recursion over a caller-supplied table is a denial-of-service surface |
| Client redaction | `shared/config.lua` | Whitelist, asserted |

### 9.1 The empty allow-list

`Security.AuthorizedResources = {}` means **no resource but the platform itself**
may add a door, break a door, or write a sync record.

That is the intended default and it is not a bug. A new server has no authorised
callers yet, and the honest answer to "who may mutate doors?" is nobody.
Defaulting to allow-all helps nobody during setup and leaves the exposure in
place afterwards, which is the part that matters at 3am.

**What it costs you:** a housing, robbery or garage resource whose calls start
returning `false`. That is a five-line fix — add its name to the list — and it
is not a reason to run allow-all.

**One exception, for existing installs:** if this library has already run on
this server — a config file it wrote, or a store that already has rows — the
empty list keeps the older permissive behaviour so an upgrade does not break a
working server overnight. `cis_debug` prints which way you fell.

### 9.2 What is deliberately not defended against

Anything in your `server.cfg` already has every permission you have. A resource
can read your database, call your exports, and read your files. The controls
here are against **accidents and sloppy code**, and they log loudly when they
fire. Presenting them as a security boundary against a hostile resource would be
theatre.

---

## §10 — Performance

- **Free reads** (client): `Cis.player.ped/coords/heading`. No boundary.
- **Crossings**: everything else. A marshal and a return trip each.
- **Memoisation**: `coords()` is one native per frame per calling VM. Keyed on
  frame **and** ped — a respawn hands out a new ped inside a still-current
  frame, and keying on the frame alone serves the dead one's coordinates until
  the next tick.
- **Hot paths**: zone and target `inside` callbacks run on a timer, default
  500ms. Lowering it is a straight trade of idle CPU for latency.
- **The registry is not on the hot path.** `CisRegistry.resolve` caches the
  resolved callable after the first success.
- **Logging is fire-and-forget** for audit rows, deliberately: an unlock must
  not wait on an `INSERT`. Failed audit writes are **counted and reported**,
  because a gap discovered during a dispute is worse than one found in advance.

---

## §11 — Upgrading from 1.x

1. **`cis_libs` alone still works.** Install it, `ensure` it, and nothing else
   changes. Zones, callbacks, sync, caching and logging all work with no
   products installed.
2. **Install `cis_core`** for a framework bridge and your configuration file.
   Without it you are on standalone mode: every job, permission and money
   helper returns its no-framework answer, and the console says so.
3. **Install `cis_bridge`** for third-party targets. Without it, target calls
   report unavailable and there is no database.
4. **`cis_doors` moved.** Enable `Doorlock.Persist` in `cis_keys`, not in
   `cis_core`. An existing `cis_doors` table is adopted, not recreated.
5. **`DoorData` is gone** from the client config payload (§6).
6. **The doorlock event prefix changed** from `cis_libs:doorlock:*` to
   `cis_keys:doorlock:*`. Any resource triggering those directly must change in
   the same edit.
7. **Nothing about a consumer's `Cis.*` code changes.** That was the constraint
   the split was designed around.

---

## §12 — Known defects, pinned not fixed

| Defect | Where | Why it is not fixed |
|---|---|---|
| `Cis.framework.notify(message, kind)` on the client sends `kind` in the message slot | `init.lua` | Correcting it is a MAJOR change. Pinned in `test/contracts.lua`. |
| `Cis.callback.await` returns at most 6 values across the wire | `server/callback.lua` | Widening it is a wire change. |
| `CisInventory` provider fallback reports 0 when a provider is absent | `cis_core` | Advisory by design; a count is always a number. |

---

## §13 — Troubleshooting

| Symptom | First thing to check |
|---|---|
| `nil index: 'exports'` on first call | Start order. `ensure cis_libs` first, or add `dependencies { 'cis_libs' }` to the **consuming** resource |
| Every `Cis.*` call returns nil | `cis_debug`. Look for `no provider installed` |
| Zones never fire | The callback is a function. It cannot cross. Use `onEnterEvent` |
| A zone is at the wrong coordinates | Bracket-form export call. §3.1 |
| `Cis.ready` never returns | 15s deadline, then `false`. Check the console for the config handshake |
| Notifications do not appear | `Config.Printing.UseDiscordLogs` is the outbound switch; the in-game feed is not affected |
| `HasItem always says no` | The configured inventory is not started; counts fall back to the framework's own table, which is usually empty |
| A zone reports as removed but still works | The provider's remove call returned nothing; success is decided from our record. See §14 |

---

## §14 — Coupling seams outside the abstractions

Stated rather than hidden, because each one is a place where a third-party
behaviour leaks in.

- **Target removals return nothing.** `ox_target:removeZone` and
  `qb-target:RemoveZone` return `nil`, so their return value cannot be used as
  a success flag. Success is decided from the library's own record of what it
  created. Reading the return value reports failure for a removal that worked.
- **`oxmysql` grew a `single` export.** Builds before it do not have one, and
  calling a missing export **raises**. The adapter probes at registration and
  falls back to the first row of a query.
- **qbx_core removed `GetCoreObject` in 1.9.** Both realms now use one
  detection function and both carry the `GetPlayer` fallback. They did not
  before, and the client half silently dropped to standalone.
- **qb-inventory reports failure as a string.** A string is truthy in Lua, so
  every call coerces explicitly.
- **`QBX:Client:OnJobUpdate` and friends** are third-party event names. They
  are declared in `cis_core`'s `api.lua` as dependencies, and the events
  `cis_libs` publishes in response are declared here.

---

## §15 — Layout

```
fxmanifest.lua          load order is documented and load-bearing
init.lua                THE ONLY FILE A CONSUMER shared_scripts
api.lua                 data. the machine-readable contract. not loaded at runtime
shared/
  defaults.lua          the config floor. no file to edit
  registry.lua          the capability registry. pure
  config.lua            the client redaction whitelist
  grid.lua              spatial hash
  detect.lua            framework/driver detection. pure, injected probes
  ready.lua  pending.lua  histogram.lua
  algo/  util/          15 pure modules
client/  server/
tools/                  luacheck, lua-exports, validate-api
test/                   453 assertions
```

---

## §16 — Requirements

- **OneSync must be on.** Entity sync and the cache read and mutate entity
  state on both sides. Declared in `fxmanifest.lua` as `/onesync`.
- **Server build 4500+.** Older builds lack natives this calls; they fail at
  the call rather than at startup, so the symptom is a runtime error in your
  console rather than a refused boot. Declared as `/server:4500`.

---

## §17 — Stateful files: never `shared_script` these

`init.lua` · `shared/grid.lua` · `shared/pending.lua` · `shared/ready.lua` ·
`shared/histogram.lua` · `client/cache.lua` · `client/zones.lua` ·
`client/callback.lua` · `client/target.lua` · `client/sync.lua` ·
`server/callback.lua` · `server/sync.lua` · `server/security.lua`

`shared_script`ing one multiplies its native work by your resource count. Two
copies of a zone grid is two grids, and the second one is empty.

---

## §18 — Tests

```
npm install
npm test              # 453 assertions, no FiveM server required
npm run test:luacheck # every .lua file parses
npm run test:api      # api.lua vs the real registered surface
npm run test:api-selftest
npm run test:all
```

| Suite | Assertions | What it covers |
|---|---|---|
| `test/run.lua` | 145 | grid, pending, config redaction, **the capability registry**, **the built-in defaults**, detection, histogram |
| `test/binding.lua` | 27 | the exports boundary, with a canary that proves the stub models the argument shift |
| `test/contracts.lua` | 163 | the declared surface vs the registered one, **the zero-table and zero-third-party invariants**, and source pins on the fixes that are easy to silently undo |
| `test/modules.lua` | 118 | the 15 pure algorithm and utility modules |

The integration harness (`cis_libstest`) is a **separate repository** and needs
a running fxserver. It is not run here.

---

## §19 — The invariants, and why they are tests

Three properties this repository would rather break a build than lose.

**1. No tables.** `test/contracts.lua` walks every path in `fxmanifest.lua` —
parsing the manifest, so the list cannot drift — and fails on a `CREATE TABLE`
or an `INSERT INTO` in any of them. The first person who adds one to a
convenience helper breaks the suite rather than the promise.

**2. No third-party resources.** The same walk fails on any call to
`ox_inventory`, `ox_target`, `oxmysql`, `es_extended`, `qb-core` or `qbx_core`.
A library that names its siblings cannot be thrown away.

**3. The API does not change quietly.** `api.lua` is checked against the real
registered surface on every commit, and the self-test proves the checker still
catches a broken declaration — because a validator that has stopped failing is
worse than no validator.

**A fourth, enforced by CI as a grep rather than a test:** no unbound
`exports[res][name](...)` calls anywhere in the tree. The tripwire's own
documentation is the header of the file that trips it, which is
`init.lua` — where the trap is explained, and where it once lived.

---

## §20 — Licence

MIT. See `LICENSE.md`. The attribution notice must be retained in every copy,
in source or binary form.

---

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> ·
**Discord:** <https://discord.gg/cisoko> ·
**Issues:** <https://github.com/SpecialStos/cis_libs/issues>

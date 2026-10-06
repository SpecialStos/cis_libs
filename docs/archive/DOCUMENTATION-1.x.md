> Historical. Describes cis_libs 1.x. Not current. See DOCUMENTATION.md.

# cis_libs — Documentation

**A standalone FiveM library and framework bridge.** Player state, callbacks,
spatial zones, an inventory bridge, a targeting bridge, door locks, entity sync,
a database layer, and logging. It depends on **no other library** — not ox_lib,
not PolyZone. It sits beside ESX / QBCore / QBOX and normalises the differences
so your resource can be written once.

Version **1.0.0**. Requires OneSync and server build 4500+.
See [LICENSE.md](LICENSE.md); the original author's name and the resource
name must be retained in all copies. The current tree is not MIT.

---

## How to read this document

**If you are an AI agent or a new contributor:** read §0 first, then §3. Almost
every mistake in an integration is a violation of one of those, and every one of
them fails *silently* — wrong data, no error, no log line. §0 is the short
version; §3 is the reasoning and the measurements behind it.

**If you are integrating:** §2 (install), §3 (boundary model), §6 (API
reference), §7 (recipes).
**If you are auditing a breaking change:** §10 onward is the frozen contract —
what may not change, and what is scheduled for removal at 3.0.
**If something is misbehaving:** §19 (troubleshooting), then §16 (known
defects, so you do not file a bug that is already known).

| § | Section | Read it when |
|---|---|---|
| **[0](#0-rules-that-break-code-silently)** | **[Rules that break code silently](#0-rules-that-break-code-silently)** | **Always, first** |
| [1](#1-what-this-is) | [What this is](#1-what-this-is) | Onboarding |
| [2](#2-install) | [Install](#2-install) | Setting up |
| **[3](#3-the-boundary-model)** | **[The boundary model](#3-the-boundary-model)** | **Before your first line of code** |
| [4](#4-performance-model) | [Performance model](#4-performance-model) | Deciding what to poll |
| [5](#5-quick-start) | [Quick start](#5-quick-start) | The shortest working example |
| [6](#6-api-reference) | [API reference](#6-api-reference) | Using a function |
| [7](#7-recipes) | [Recipes](#7-recipes) | Common tasks |
| [8](#8-security-model) | [Security model](#8-security-model) | Handling untrusted input |
| [9](#9-configuration-reference) | [Configuration reference](#9-configuration-reference) | Server setup |
| [10](#10-the-frozen-contract) | [The frozen contract](#10-the-frozen-contract) | Before changing anything |
| [11](#11-the-cis-surface--50-entry-points) | The `Cis.*` surface | Finding a proxy function |
| [12](#12-the-export-surface--52-server-55-client) | The export surface | Calling an export |
| [13](#13-allow-list-posture) | [Allow-list posture](#13-allow-list-posture) | Mutating doors or sync |
| [14](#14-net-events) | [Net events](#14-net-events) | Listening for events |
| [15](#15-stateful-files--twelve) | [Stateful files](#15-stateful-files--twelve) | Deciding what to `shared_script` |
| [16](#16-known-defects-pinned-not-fixed) | [Known defects, pinned not fixed](#16-known-defects-pinned-not-fixed) | Before filing a bug |
| [17](#17-compatibility-shims) | [Compatibility shims](#17-compatibility-shims) | On a legacy integration |
| [18](#18-testing) | [Testing](#18-testing) | Verifying your integration |
| [19](#19-troubleshooting) | [Troubleshooting](#19-troubleshooting) | When something misbehaves |
| [20](#21-changelog-policy) | [Changelog policy](#21-changelog-policy) | Releasing |
| [A](#appendix-a--brief-for-migrating-a-resource) | [Appendix A — migrating a resource](#appendix-a--brief-for-migrating-a-resource) | Moving an existing resource |

---

## 0. Rules that break code silently

Six rules. Every one of them fails **without raising an error** — you get wrong
data, or no data, and nothing in the console tells you why. This library has
shipped one of these bugs itself, in a form that silently corrupted every
single API call it had.

### 0.1 The `self` trap — the one that will cost you an afternoon

```lua
exports['cis_libs']:SomeExport(a, b)    -- CORRECT
exports['cis_libs']['SomeExport'](a, b) -- WRONG
```

The bracket form is an unbound method: the exports table is expected as the
first argument, so every argument shifts one place left and nothing raises.
The **lookup** is unbound the same way, so a dynamically resolved handler loses
its first argument too. Measured, not assumed: see [§3.1](#the-self-trap).

```bash
# in your own resource, this must return nothing
grep -rnE "exports['cis_libs'][" --include=*.lua . | grep -v ':[[:space:]]*--'
```
### 0.2 A function can be handed *back*, never sent *over*

| Direction | Works? | Notes |
|---|---|---|
| Function as an **argument** | **No** | Arrives `nil` |
| Function as a **return value** | Yes | Arrives as a callable reference table |

This is the single most consequential asymmetry in the library. You **cannot
pass a callback into `cis_libs`**. Every callback option has an **Event twin**
that does work — use it.

```lua
-- WRONG from a consumer: onEnter arrives nil and silently never fires
Cis.zones.box('shop', centre, size, { onEnter = function() end })

-- RIGHT
Cis.zones.box('shop', centre, size, {
    onEnterEvent = 'myResource:shopEnter',   -- receives (zoneName, x, y, z)
    onExitEvent  = 'myResource:shopExit',
})
RegisterNetEvent('myResource:shopEnter', function(zoneName, x, y, z) end)
```

A returned function arrives as `{ __cfx_functionReference = 'res:line:col' }`
and **is callable** — but `type()` reports `table`, so a
`type(x) == 'function'` check rejects a handler that works fine.

### 0.3 `shared_script` copies; it does not share

Each resource runs in its own Lua VM. `shared_script '@cis_libs/init.lua'` gives
you a **proxy table**, not access to the library's internals. A consumer does
**not** see `Config`, `Security`, `Globals`, `CisReadyState` or `CisCache`;
reading them from another resource yields `nil`.

**Never `shared_script` a stateful file.** You would get a second player cache,
a second polling thread, and native calls multiplied by your resource count.
The twelve files that hold process-global state are listed in
[§15](#15-stateful-files--twelve). The pure `shared/` modules are safe to copy.

### 0.4 Server-to-client handlers work by name, not by function

A function cannot be sent across, but one *returned* from an export comes back
callable. Export your handler on your own resource and register it by
reference:

```lua
exports('myResource:handlePurchase', function(src, item, amount) ... end)
Cis.callback.register('purchase', 'myResource:handlePurchase')
```

### 0.5 Subscribe; do not poll

`ped()`, `coords()` and `heading()` are free. Everything else crosses a
boundary. An export call at 60 Hz means you are polling something you should be
subscribing to — **fixing the loop beats optimising the call.**

### 0.6 A refusal explains itself

Anything that can decline returns a reason as a second value, because a caller
on the other side cannot read `cis_libs`'s console. Always capture it:

```lua
local ok, why = Cis.zones.box('shop', centre, size, {})
if not ok then print(why) end   -- e.g. 'coords arrived as nil'
```

---
## 1. What this is

`cis_libs` is a standalone FiveM resource providing the pieces almost every
server rewrites: player state, a callback system, spatial zones, an inventory
bridge, a targeting bridge, door locks, entity sync, a database layer, and
logging. It depends on no other library — not ox_lib, not PolyZone.

It is not a framework and does not replace your framework. It sits beside
ESX / QBCore / QBOX and normalises the differences so your resource can be
written once.

Version 1.0.0. Requires OneSync and server build 4500+.

---

## 2. Install

1. Place the folder in your server's `resources/` directory.
2. Add `ensure cis_libs` to `server.cfg` **before** any resource that uses it.
   A consumer that starts first will time out waiting for configuration.
3. Edit `configs/master_config.lua` to match your server.
4. In each consuming resource's manifest:

```lua
shared_script '@cis_libs/init.lua'
```

5. In each consuming resource's Lua:

```lua
Cis.ready(function(ok)
    if not ok then
        print('cis_libs did not load; falling back')
        return
    end
    -- safe to use the Cis API from here
end)
```

`Cis.ready` takes a callback and returns a boolean. It resolves `false` if
`cis_libs` failed to hand over configuration within 15 seconds. **Gate your
startup work on it** — calling the API before configuration arrives is the most
common integration bug.

```lua
-- Also available, if you need a plain boolean (server-side works too)
local ok = Cis.wait(15000)
```

---

## 3. The boundary model

This is the section that matters. Everything else follows from it.

### `shared_script` copies; it does not share

Each resource runs in its own Lua VM. When your resource executes
`shared_script '@cis_libs/init.lua'`, the file is loaded **into your VM** and
produces a *proxy* table. Your resource does not get a handle on `cis_libs`'s
internal state. It gets a set of functions, most of which forward across a
resource boundary to reach that state.

FiveM has no cross-resource shared memory. Exports and net events are the only
two channels between resources.

### What survives the exports boundary

Measured, not assumed, against FiveM server build in use by `cis_libstest`:

| Value | Result |
|---|---|
| Number, string, boolean | Preserved |
| Table (nested, arrays) | Preserved |
| `nil` | Dropped — a key holding nil disappears from a returned table |
| Multiple return values | Collapsed to the first value only |
| **Function, as an argument** | **Dropped** |
| **Function, as a return value** | Arrives as a **callable reference table** |

The asymmetry is the thing to internalise: **a function can be handed back, but
not sent over.**

- Sending a callback in is impossible. `Cis.player.near(coords, 5.0, fn)`
  delivers `fn` as nil, and an options table carrying `onEnter` arrives empty.
- Receiving one works. It comes back as
  `{ __cfx_functionReference = 'resource:line:col' }` and **is callable** — but
  `type()` reports `table`, so never test for `'function'`. Check for
  `__cfx_functionReference` instead.

So zone `onEnter`/`onExit`/`inside` callbacks and `Cis.player.on` /
`Cis.player.near` cannot take a callback from a consumer resource, while a
**server-side** handler in another resource is reachable by name. See
[Registering a handler](#registering-a-handler).

### The `self` trap

```lua
exports['cis_libs']:SomeExport(a, b)    -- correct
exports['cis_libs']['SomeExport'](a, b) -- WRONG: every argument shifts left by one
```

The bracket form looks equivalent but is not. It yields an **unbound method**,
so the exports table is expected as the first argument. With no `self`, a call
intended as `(kind, name, coords)` arrives as `(name, coords, size)` — a zone
name silently becomes its own coordinates, with no error raised anywhere.

If you must call an export dynamically, pass the table explicitly:

```lua
local lib = exports['cis_libs']
lib.SomeExport(lib, a, b)   -- correct
```

`cis_libs`'s own `init.lua` hit exactly this, and it cost a long debugging
session. If you write dynamic export calls, use the colon form.

### Refusals explain themselves

Anything that can decline returns a reason as a second value, because a caller
on the other side cannot read cis_libs's console:

```lua
local ok, why = Cis.zones.box('shop', coords, size, {})
if not ok then
    print(why)   -- e.g. 'coords arrived as nil (the exports boundary dropped them)'
end
```

### Reading state you genuinely need

A companion resource cannot read `Config`, `Security` or the ready state
directly, even though those are plain globals inside `cis_libs`. Use these:

| Need | Call |
|---|---|
| Is the library up? | `Cis.wait(timeout)` or `exports['cis_libs']:IsReady()` |
| What config did the server choose? | `exports['cis_libs']:GetConfigSummary()` (server) |
| What config did the server send me? | `exports['cis_libs']:GetClientConfig()` (client) |
| The configured event prefix | `exports['cis_libs']:GetLibsPrefix()` |
| Would my mutation be allowed? | `exports['cis_libs']:InvokingAllowed()` |
| Check a rate limit budget | `exports['cis_libs']:RateOk(src, name, windowMs, maxHits)` |

`GetConfigSummary` and `GetClientConfig` are whitelists — no webhooks, no
credentials, no database connection details, no allow-list contents.

The pure `shared/` modules (`grid`, `pending`, `histogram`, `config`) have no
natives, so a companion resource may `shared_script` them directly and keep its
own copy. That is the supported way to get zero-boundary calls on pure logic.

### Stateless logic can be duplicated. Stateful singletons cannot.

This is the rule that decides every design question in this library.

`cis_libs` owns process-global state that must exist exactly once:

| State | Why it must be a singleton |
|---|---|
| `CisCache` (ped, vehicle, seat, weapon) | One watchdog thread polling natives. Fifteen copies means fifteen times the native calls. |
| The zone spatial grid | A single index over every zone. Per-resource copies mean fifteen copies of every zone. |
| Pending callback keys | Must match one-to-one with the server/client counterpart in cis_libs. |
| Rate limiters | Counted per player across the whole server, not per resource. |

**So: never `shared_script '@cis_libs/client/cache.lua'` or any other stateful
file from your resource.** You would get a second cache, a second watchdog
thread, a second `Globals` table, and a per-frame cost multiplied by your
resource count. This is the single most damaging thing you can do to this
library.

By contrast the pure modules have **zero** native references and are safe to
load for an independent copy when you genuinely want one:

- `shared/grid.lua` — spatial hash
- `shared/pending.lua` — incrementing keys with timeout sweep
- `shared/histogram.lua` — job counts
- `shared/config.lua` — config whitelist

If you want your own private zone grid, that is a legitimate use. You just
accept the memory cost and the fact that you are no longer sharing cis_libs' index.

### Two call styles

`init.lua` detects whether it is running inside `cis_libs` itself
(`IS_SELF`) or inside a consumer, and picks the cheapest path available:

```lua
function Cis.player.coords()
    local frame = GetFrameCount()
    local ped = currentPed()
    if coordFrame == frame and coordPed == ped and coordValue then
        return coordValue      -- one native per frame, for the whole client
    end
    ...
end
```

Inside `cis_libs`, this reads the cache table directly. Inside a consumer, it
calls natives directly and memoises per frame. **Either way it never crosses
the boundary.**

---

## 4. Performance model

### Free — no boundary crossing

These are direct native calls for a consumer. Call them freely.

| Call | Cost |
|---|---|
| `Cis.player.ped()` | `PlayerPedId()` |
| `Cis.player.coords()` | `GetEntityCoords`, memoised to once per frame |
| `Cis.player.heading()` | `GetEntityHeading` |

### Costs a boundary crossing

Everything not on that list. At low call rates (zone creation, notifications, a
DB query) this is irrelevant. **In a `Wait(0)` loop it is not.**

Four consumer-facing calls cross the boundary, and they are the ones to watch:

| Call | Function | Better approach |
|---|---|---|
| `Cis.player.vehicle()` | `init.lua` → `Cis.player.vehicle` | `Cis.player.on('vehicle', cb)` |
| `Cis.player.weapon()` | `init.lua` → `Cis.player.weapon` | `Cis.player.on('weapon', cb)` |
| `Cis.player.serverId()` | `init.lua` → `Cis.player.serverId` | Cache it yourself at spawn |
| `Cis.inventory.count(item)` | `init.lua` → `Cis.inventory.count` | Cache it, refresh on change events |

Named rather than line-numbered on purpose: a line citation goes stale the
moment anything above it is edited, and this file has been wrong about that
before.

### Poll versus subscribe

The boundary cost is a symptom, not the disease. An export call at 60 Hz means
you are polling something you should be subscribing to. Fixing the loop beats
optimising the call.

```lua
-- Wrong: 60 boundary crossings per second, forever
CreateThread(function()
    while true do
        local vehicle = Cis.player.vehicle()
        if vehicle then
            -- do the thing
        end
        Wait(0)
    end
end)

-- Right: one subscription, one export, no per-frame work
local vehicle, seat
Cis.player.on('vehicle', function(current)
    vehicle = current
end)
```

`Cis.player.on` returns an unsubscribe function. Call it when your resource
stops.

Valid keys: `ped`, `vehicle`, `weapon`, `armed`, `aiming`.

### Idle budget

With no consumer polling, `cis_libs` idles at:

- one fallback poll every `Config.UpdateInterval.Player` ms (default 1000),
  costing roughly ten natives plus one `vec4` allocation per tick
- no `Wait(0)` loop, with two deliberate exceptions:
  - `DrawText3D` while a door is in range, in `DrawText3D` door mode
  - a zone whose `insideInterval` is `0`

The fallback poll exists because events miss things — respawn, a seat change
with no game event, a weapon swap. Lowering the interval trades native calls
for fresher data. Do not lower it below 250ms.

---

## 5. Quick start

```lua
Cis.ready(function(ok)
    if not ok then return end

    -- Zones
    Cis.zones.box('shop', vector3(1200.0, 800.0, 30.0), vector3(20.0, 20.0, 5.0), {
        onEnter = function(coords)
            print('entered shop')
        end,
        onExit = function(coords)
            print('left shop')
        end,
    })

    -- Per-frame zone callback
    Cis.zones.sphere('marker', vector3(0.0, 0.0, 0.0), 3.0, {
        insideInterval = 100,
        inside = function(coords)
            DrawText3D(coords.x, coords.y, coords.z + 1.0, 'Hello', { 255, 255, 255, 215 })
        end,
    })

    -- Server callbacks
    if IsDuplicityVersion() then
        Cis.callback.register('my:resource:getBalance', function(src)
            return 100
        end)
    else
        local balance = Cis.callback.await('my:resource:getBalance')
    end

    -- Cleanup on stop
    AddEventHandler('onResourceStop', function(resource)
        if resource == GetCurrentResourceName() then
            Cis.zones.remove('shop')
        end
    end)
end)
```

---

## 6. API reference

Client and server namespaces are marked. Calling a server function on the
client is a no-op returning nil, and vice versa.

### `Cis.ready` / `Cis.wait`

```lua
Cis.ready(function(ok) end)   -- callback form
Cis.ready(timeout)            -- number form, returns boolean
Cis.wait(timeout)             -- returns boolean
```

Resolve `false` means `cis_libs` failed to deliver configuration. Treat the API
as unavailable.

### `Cis.player` — client

| Function | Returns | Notes |
|---|---|---|
| `Cis.player.ped()` | ped | Free |
| `Cis.player.coords()` | vector3 | Free. Memoised per frame |
| `Cis.player.heading()` | number | Free |
| `Cis.player.vehicle()` | `entity, seat` or `nil` | **Crosses boundary.** Seat is `-1` for driver |
| `Cis.player.weapon()` | `table` or `nil` | **Crosses boundary.** `{hash, ammo, ammoType, attachments}`; `nil` when unarmed |
| `Cis.player.serverId()` | number | **Crosses boundary** |
| `Cis.player.on(key, cb)` | unsubscribe fn | `cb(current, previous)` |
| `Cis.player.near(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)` | `unsubscribe, id` | Polls at 200ms, no zone needed. Callbacks are cis_libs-only; use the event forms from a consumer. Events receive `(distance)` |

`Cis.player.weapon()` returns a fresh table when the ammo count changes rather
than mutating the one you were handed. Holding a reference across frames gives
you a stale snapshot; call the function again.

The unsubscribe function each returns does cross the boundary as a callable
reference, but the `cb` you pass in does not — so those two are only useful
inside `cis_libs`. Gate any callback on a flag you control and tear down in
`onResourceStop`; see [Cleaning up subscriptions](#cleaning-up-subscriptions).

### `Cis.callback`

| Function | Realm | Notes |
|---|---|---|
| `Cis.callback.register(name, handler)` | server | See below |
| `Cis.callback.call(name, cb, ...)` | server | Local. `cb(ok, ...)` |
| `Cis.callback.await(name, ...)` | server | Local. Returns handler result |
| `Cis.callback.callClient(src, name, cb, ...)` | server | `cb(ok, ...)` |
| `Cis.callback.awaitClient(src, name, ...)` | server | Yields |
| `Cis.callback.await(name, ...)` | client | Yields, times out |
| `Cis.callback.call(name, cb, ...)` | client | `cb(ok, ...)` |

#### Registering a handler

**Server-to-client callbacks work today.** Your client is told the callback name
and the server awaits the client's answer, so no function ever crosses a
resource boundary:

```lua
-- client
Cis.callback.register('my:confirmPurchase', function(item, price)
    -- show a prompt, then:
    return true
end)
```

**A handler in another server-side resource works, by name.** A function cannot
be *sent* across, but one *returned* from an export comes back callable. Export
the handler on your own resource and register it by name:

```lua
-- in your resource
exports('myResource:handlePurchase', function(src, item, amount)
    if not allowedItems[item] then return false end
    return Cis.inventory.remove(src, 'cash', amount * item.price)
end)

Cis.callback.register('purchase', 'myResource:handlePurchase')  -- true / false
```

Passing the function itself registers nothing and returns `false` — always check
the return value.

**Known caveat:** a handler called through the reference runs and receives its
arguments, but its return value may arrive as `nil`. Until that is resolved,
have a remote handler signal its result by side effect or a net event rather
than by return value.

**A zone callback from a consumer still does not work**, because `onEnter` is an
argument rather than a return. That needs a net-event relay and is not
implemented yet; treat `Cis.zones.*` callbacks as cis_libs-internal only.

**Every call times out** at `Config.CallbackTimeout` (default 10000ms). Await
returns `nil` on timeout; callback style invokes `cb(false, 'timeout')`.

`Cis.callback.call` and `await` dispatch **locally** and pass every argument
through as data. A number is never reinterpreted as a player ID. To reach a
specific client, use `callClient` / `awaitClient`.

Pending keys are bound to the player they were sent to. A client cannot resolve
or forge another player's callback.

### `Cis.zones` — client

```lua
Cis.zones.poly(name, points, options)
Cis.zones.box(name, center, size, options)
Cis.zones.sphere(name, center, radius, options)
Cis.zones.remove(name)              -- returns false if unknown
Cis.zones.contains(name, point)     -- returns boolean
```

Returns `true` on creation. On refusal it returns `false` **and a reason**:

```lua
local ok, why = Cis.zones.box('shop', centre, size, {})
```

Reasons include `zones disabled by config`, `name arrived as <type>`, and
`coords arrived as nil (the exports boundary dropped them)`. Always capture the
second value when a call fails — it is nearly always more useful than a stack
trace.

`options` for all kinds:

| Key | Default | Notes |
|---|---|---|
| `onEnter` | — | `cb(coords)` — **cis_libs only**, a function cannot cross the boundary |
| `onExit` | — | `cb(coords)` — cis_libs only |
| `inside` | — | `cb(coords)` — cis_libs only |
| `onEnterEvent` | — | Event name. Receives `(zoneName, x, y, z)` on the **server** |
| `onExitEvent` | — | Event name, same payload |
| `insideEvent` | — | Event name, fires on `insideInterval` |
| `insideInterval` | `500` if a callback is set | `0` = every frame |
| `debug` | `false` | Visualises the shape |

**From a consumer resource, use the `*Event` forms.** A function passed in
`options` arrives nil, so `onEnter` silently does nothing:

```lua
Cis.zones.box('shop', centre, size, {
    onEnterEvent = 'myResource:shopEnter',
    onExitEvent  = 'myResource:shopExit',
})

RegisterNetEvent('myResource:shopEnter', function(zoneName, x, y, z)
    print(('entered %s at %.0f,%.0f'):format(zoneName, x, z))
end)
```

`inside` or `insideEvent` both drive `insideInterval`; setting either one
supplies the default cadence.

Poly only: `minZ` (`-1000`), `maxZ` (`10000`).
Box only: `heading` or `rotation` (`0`). `size` accepts a `vector3` or a single
number for a cube.

Creating a zone with an existing name replaces it.

**`insideInterval = 0` is the only thing that ticks per frame.** At most one
zone should use it. For anything else, prefer a lower `insideInterval` over `0`.

Zone `onExit` fires within ~200ms of leaving, independent of how fast you move.

### `Cis.target` — client

```lua
Cis.target.add(zoneType, name, coords, size, options)
Cis.target.remove(name, isPed)
Cis.target.update(name, options)
Cis.target.exists(name)
```

`zoneType` is `'box'`, `'sphere'`, or `'ped'`. For `'ped'`, pass
`options.entity`.

`options` is passed to the target provider: `{ options = {...}, distance = 2.0 }`,
plus `rotation` for box zones.

Bridges `ox_target` or `qb-target` per `Config.Framework.Target.Type`. `remove`
returns `true` when the target was known and the provider call completed, and
`false, reason` otherwise — the providers' own removal calls return nothing, so
success is decided from cis_libs's bookkeeping. `update` removes and recreates;
treat it as a rebuild, not a patch.

### `Cis.doors`

```lua
Cis.doors.add(data)          -- server: broadcasts to all clients
Cis.doors.setState(id, locked)
Cis.doors.get(id)            -- client, returns the client's cached hint
```

`data`:

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Unique string |
| `model` | yes | String or hash |
| `coords` | yes | Door model position |
| `interactCoords` | no | Where the prompt appears; defaults to `coords` |
| `locked` | no | Default false |
| `maxDistance` | no | Defaults to `Config.Doorlock.InteractableDistance` |
| `groups` | no | Array of job names permitted |
| `groupId` | no | Doors sharing a group toggle together |

`setState` is a **request**. The server validates permission and distance
before applying. `get` returns the client's cached state, which is a hint and
not authority.

### `Cis.sync` — server

```lua
Cis.sync.ped(data)
Cis.sync.prop(data)
Cis.sync.vehicle(data)
Cis.sync.remove(id)
```

`data`:

| Field | Required | Notes |
|---|---|---|
| `model` | yes | String or hash |
| `coords` | yes | `{x, y, z}` or vector3. **Validated; a record without it is rejected** |
| `id` | no | Generated if absent |
| `heading` | no | Default 0 |
| `networked` | no | Default true |
| `scope` | no | Broadcast radius, default 80 |
| `dynamic` | no | Rebroadcast on a 2s timer so players entering range receive it |
| `freeze` | prop only | Default true for props |
| `props` | vehicle only | Vehicle properties table |

Call `Cis.sync.ped(data)` again to update an existing entity. Re-sending
identical data is a no-op. When the model or kind is unchanged the client
**moves the existing entity** rather than respawning it, so dynamic entities do
not flicker. A model or kind change is the only thing that forces a respawn.

`Config.Sync.Enabled = false` makes all of these no-ops without unloading.

### `Cis.db` — server

```lua
Cis.db.query(sql, params)        -- rows
Cis.db.single(sql, params)       -- one row
Cis.db.scalar(sql, params)       -- one cell
Cis.db.insert(sql, params)       -- insert id
Cis.db.update(sql, params)
Cis.db.transaction(queries)      -- oxmysql only; queries are { {query=, values=}} entries
```

Always parameterised — never interpolate user input into the SQL string.

Each of these yields and gives up after `Config.Framework.Database.Timeout`
(default 15000ms), returning `nil`. They cannot park your coroutine forever.

> `transaction` is **oxmysql only**. Send oxmysql's own shape — an array of
> `{ query = ..., values = { ... } }` objects — and on any other driver it
> refuses promptly with `false, 'transactions require oxmysql'`. It used to
> burn the full timeout and return `nil` on *every* driver, because the awaited
> wrapper called it as `(sql, params, cb)` while it takes `(queries, cb)`. That
> is fixed and verified live; see [§16](#16-known-defects-pinned-not-fixed).

`Cis.db.scalar` unwraps a single cell on SQL drivers and the first non-`_id`
field on MongoDB, so it is consistent across drivers.

### `Cis.inventory`

```lua
-- client (cache read, no boundary for has/count semantics but count does cross)
Cis.inventory.count(item)
Cis.inventory.has(item, amount)

-- server
Cis.inventory.count(src, item)
Cis.inventory.has(src, item, amount)
Cis.inventory.add(src, item, amount, metadata)
Cis.inventory.remove(src, item, amount)
```

Client counts are a **cached hint** pushed by the server. Do not use them to
gate a server-side action — re-check on the server. `add` and `remove` return
the underlying inventory result; a rejected removal returns false.

### `Cis.framework` — server

```lua
Cis.framework.player(src)      -- normalised player
Cis.framework.notify(srcOrNil, message, kind)
```

The normalised player has the same shape regardless of framework:

```lua
{
    id = src,
    name = 'First Last',
    job = { name = 'police', grade = 0 },
    identifier = 'ABC12345',
    money = { cash = 500, bank = 2000 },  -- account table, normalised across ESX and QB
    metadata = { ... },                    -- nil if the framework exposes none
}
```

### `Cis.security` — server

```lua
Cis.security.report(src, reason)   -- logs, then applies Security.DropPlayer
```

### `Cis.log` — both

```lua
Cis.log.debug(message)
Cis.log.info(message)
Cis.log.warn(message)
Cis.log.error(message)
```

`debug` is gated on `Config.Printing.Debug`. **Warnings and errors always
print.** If you are not seeing an error in a `pcall`, that is a bug — report it.

### `Cis.net` — server

```lua
-- from a consumer resource: a reference, because a function cannot be SENT
-- across the exports boundary
exports('myResource:handleThing', function(src, payload) end)
Cis.net.on('my:resource:doThing', 'myResource:handleThing')

-- inside cis_libs itself, a plain function also works
Cis.net.on(eventName, function(src, ...) end)
```

Registers a net event that validates `source` and rate-limits per player
(8 per second by default) before invoking your handler. Prefer this over
`RegisterNetEvent` for any event a client can reach.

**From a consumer, the handler must be a `'resource:export'` reference.** A
function passed *into* an export arrives `nil` — the same rule that gives zone
callbacks their `*Event` twins — and the event would otherwise be registered
with no handler at all. The function form works only from inside `cis_libs`. A
refusal to register is logged rather than being silent.

### `Cis.streaming` — client

```lua
Cis.streaming.model(model, timeout)  -- returns loaded, hash
```

Yields until the model loads or the timeout expires. Replaces the
`RequestModel` + `Wait(0)` loop every resource otherwise writes.

---

## 7. Recipes

### Track the vehicle without polling

```lua
local vehicle, seat

Cis.player.on('vehicle', function(current, previous)
    vehicle = current
    if not current then
        seat = nil
        return
    end
    -- One boundary crossing per vehicle change, not per frame.
    local _, s = Cis.player.vehicle()
    seat = s
end)

CreateThread(function()
    while true do
        if vehicle then
            -- your per-frame work, reading local `vehicle` and `seat`
        end
        Wait(0)
    end
end)
```

### Cleaning up subscriptions

`Cis.player.on` and `Cis.player.near` return an unsubscribe function. Whether
that function survives the return trip across the resource boundary is not
guaranteed in every server build, so **prefer explicit teardown**:

```lua
-- Reliable: drop the subscription when your resource stops
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    myState.active = false   -- your callback becomes a no-op
end)
```

Write callbacks that check a flag and return early. That pattern works whether
or not the unsubscribe function is honoured, and it survives a `cis_libs`
restart that drops the subscription behind your back.

### A shop that opens while you stand in it

```lua
Cis.zones.box('shop', coords, vector3(20.0, 20.0, 5.0), {
    onEnter = function() openMenu() end,
    onExit  = function() closeMenu() end,
})
```

Do not wrap this in a loop. If you need continuous work while inside, add an
`inside` callback with an explicit `insideInterval`.

### Per-frame text at a fixed point

```lua
Cis.zones.sphere('marker', coords, 2.0, {
    insideInterval = 0,   -- the only per-frame zone you should have
    inside = function(c)
        DrawText3D(c.x, c.y, c.z + 1.0, 'Press ~INPUT_CONTEXT~', { 255, 255, 255 })
    end,
})
```

### A door restricted to a job

```lua
Cis.doors.add({
    id = 'police_door_1',
    model = 'v_warehousedoor01a',
    coords = vector3(...),
    groups = { 'police', 'ambulance' },
    maxDistance = 2.0,
})
```

Players in a listed job may toggle it when within `maxDistance`. Admins always
pass the permission check. The server enforces both.

### A server-authoritative item grant

```lua
-- server
Cis.callback.register('shop:buy', function(src, item, amount)
    if not allowedItems[item] then return false end
    local ok = Cis.inventory.remove(src, 'cash', amount * item.price)
    if not ok then return false end
    Cis.inventory.add(src, item, amount)
    return true
end)

-- client
local bought = Cis.callback.await('shop:buy', 'bread', 2)
```

Never trust `allowedItems` from the client. Re-check price, stock, and
ownership on the server. The client cache is a hint, not authority.

### Removing zones on resource stop

```lua
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Cis.zones.remove('shop')
end)
```

---

## 8. Security model

### Trust boundaries

**The client is untrusted.** Anything the client sends is a request, not a
fact. The client's inventory count, its door state cache, and its coordinates
are all hints.

`cis_libs` enforces server-side on the paths that matter:

| Mutation | Server checks |
|---|---|
| Door state change | Job permission **and** distance from the door |
| Callback invocation | `source` validation, per-player rate limit |
| Callback response | Key bound to the originating player |
| Entity sync | Invoke-source allow-list |
| Inventory add/remove | Framework-level validation |

### Allow-list

`Security.AuthorizedResources` restricts which server-side resources may
mutate doors and entity sync.

```lua
Security.AuthorizedResources = {
    'my_doors_resource',
    'my_sync_resource',
}
```

**An empty list allows any server-side caller.** That is a deliberate default
for ease of setup, not a recommendation. Populate it in production.

### Kick handler

`Security.DropPlayer` accepts a boolean or a function:

```lua
Security.DropPlayer = function(src, reason)
    DropPlayer(src, 'You were removed: ' .. reason)
end
```

The shipped config defines `cisAnticheatDropPlayer` and assigns it, so custom
kick messages work out of the box.

### Your events

For any event a client can reach, use `Cis.net.on`. Export the handler on your
own resource and pass it by reference:

```lua
-- in your resource
exports('myResource:handleThing', function(src, payload)
    if not validate(src, payload) then return end
end)

Cis.net.on('my:resource:doThing', 'myResource:handleThing')
```

This validates `source` is a real player and rate-limits per player. Using
`RegisterNetEvent` directly gets you neither.

Passing the function itself does not work from a consumer: a function sent
into an export arrives `nil`, so the event would be registered with no handler.
The function form is for use from inside `cis_libs` only.

---

## 9. Configuration reference

`configs/master_config.lua`:

| Key | Default | Notes |
|---|---|---|
| `CheckVersion` | `false` | Outbound HTTP on every start, to the operator-configured `VersionCheckUrl`. Off by default; the shipped value points at `api.cisoko.net` and no third-party host is hardcoded |
| `CallbackTimeout` | `10000` | ms |
| `UpdateInterval.Player` | `1000` | Fallback poll. Do not go below 250 |
| `UpdateInterval.Weapon` | `1000` | |
| `UpdateInterval.Vehicle` | `1000` | Reserved |
| `UpdateInterval.VehicleProperties` | `5000` | Reserved |
| `AimingCheckType` | `"default"` | or `"configFlag"` |
| `Framework.Type` | `"QBCORE"` | `ESX`, `ESX-LEGACY`, `QBCORE`, `QBOX`, `NONE` |
| `Framework.Inventory` | `"ox_inventory"` | or `qb-inventory`, `qs-inventory`, `codem-inventory`, `typical` |
| `Framework.Target.Type` | `"ox_target"` | or `qb-target` |
| `Framework.Database.Type` | `"oxmysql"` | or `mysql-async`, `ghmattimysql`, `mongodb` |
| `Framework.Database.Collection` | `nil` | MongoDB only. Required for MongoDB drivers |
| `Framework.Database.Timeout` | `15000` | ms before an awaited query gives up |
| `Doorlock.Type` | `"target"` | or `DrawText3D` |
| `Doorlock.Persist` | `false` | Stores doors in `cis_doors` |
| `Sync.Enabled` | `true` | `false` makes `Cis.sync.*` a no-op |
| `Printing.Debug` | `false` | Gates `Cis.log.debug` only |
| `Printing.UseDiscordLogs` | `false` | |

If the configured framework fails to load, `cis_libs` falls back to standalone
mode and prints a warning. Standalone mode means player lookups return nil — it
is visible, not silent, but check your console if the bridge seems inert.

`configs/discordLogs_config.lua` — webhook URLs. Never sent to clients.
`configs/security_config.lua` — event prefix, allow-list, kick handler. Never
sent to clients.

The client receives a whitelist: framework type, inventory, target, door mode,
debug, intervals. Webhooks, database settings, the kick handler, and the
allow-list stay server-side.

---

__SPLIT__
## 10. The frozen contract

### 10.x What is frozen, and what is not

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

### 10.x Semver policy

#### 10.2.1 MAJOR — a breaking change

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

#### 10.2.2 MINOR — additive only

A MINOR bump is required for, and **limited to**, additions:

- a new `Cis.*` function, a new export, or a new net event;
- a new config key with a default that preserves current behaviour;
- a new field in a `Cis.*` return table.

A MINOR **MUST NOT** change the meaning of anything that already exists. Adding
a *positional* parameter to an existing function is MAJOR, not MINOR — the
boundary drops `nil`, so a caller that omits the new middle argument sends a
shifted one. This is precisely the `self` trap with a new hat on.

#### 10.2.3 PATCH — bug fixes only

A PATCH bump fixes behaviour that does not match what this document already
promises. It **MUST NOT** change any documented behaviour, including turning a
silent wrong answer into a refusal: that is a *behaviour change* and takes a
MINOR at minimum, because a consumer that depended on the wrong answer is
detectable only by breaking.

#### 10.2.4 The freeze and the six products

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

### 10.x The four manifest numbers

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

## 11. The `Cis.*` surface — 50 entry points

Loaded by a consumer with `shared_script '@cis_libs/init.lua'`. **50 distinct
names, 52 realm-specific entries** (`Cis.inventory.count` and `Cis.inventory.has`
exist in both realms with different signatures).

Also set by `init.lua`, and part of the surface: `Cis.resource` (the string
`'cis_libs'`), `Cis.isReady`, `Cis.isFailed`.

### 10.Both realms (17)

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

`Cis.framework.notify` has three shapes and one of them is broken. See §3.1.

### 10.Client only (20)

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

### 10.Server only (15)

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

### 10.The eleven unexercised proxy functions

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

## 12. The export surface — 52 server, 55 client

Reached with `exports['cis_libs']:Name(...)`. **91 distinct names**; sixteen are
registered in both realms with different signatures.

"Reached by" is the `Cis.*` proxy that wraps it, if any. "Called by production
code" is from a scan of the product source trees.

### 11.Server — 52

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

### 11.Client — 55

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

### 11.The five `:doorlock:*` events are computed

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

## 13. Allow-list posture

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

### 12.The residual risk, stated plainly

The two signals cannot distinguish a legacy server that never enabled
`Doorlock.Persist` from a genuinely new one: neither left a trace. Such a
server's **first** boot under this change is restrictive, its doors are refused,
and it sees a six-line console message naming the resources to add. From the
second boot on, the written-config marker exists and it is permissive again.

This is the one place in this document where a security improvement can change
observable behaviour for an existing install. It is stated here rather than
buried because §3.1 requires it to be visible.

### 12.Refusals keep their return values

The four mutation call sites (`AddDoorToSystem`, `AddDoorGroup`, `Cis.sync.*`
create, `Cis.sync.*` remove) return exactly what they returned before — `false`
or `nil`, no second value. No new return value was added, so no consumer can
observe one. **Ask before you mutate**:

```lua
if not exports['cis_libs']:InvokingAllowed() then
    return print('not on the allow-list; add this resource to Security.AuthorizedResources')
end
```

### 12.`cis_libstest`

The integration harness mutates doors and sync, so **it is not exempt**. On a
fresh install its mutating tests will now fail — correctly, and informatively.
Add `"cis_libstest"` to `AuthorizedResources` on a test instance. The CI unit
suites are unaffected; they never load the doorlock or sync modules.

---

## 14. Net events

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

## 15. Stateful files — twelve

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

### 14.Also stateful, found in this pass

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

### 14.Safe to duplicate

Genuinely pure, no state, no natives:

- `shared/grid.lua` — pure functions
- `shared/config.lua` — pure functions
- `shared/pending.lua` — the store is passed **in** as an argument
- `shared/histogram.lua` — same; the store is passed in
- `shared/ready.lua` — **has** `CisReadyState` state, but duplicating it is
  harmless: a consumer's copy is only ever read, never marked ready

---

## 16. Known defects, pinned not fixed

The freeze forbids a behaviour change. These are real, reproduced, and pinned by
`test/contracts.lua` so that fixing one is a deliberate MAJOR decision rather
than an accident.

### 15.`Cis.framework.notify` sends the wrong argument on the client

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

### 15.`Cis.db.transaction` returned nothing and burned the timeout (FIXED)

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

### 15.The remote-handler path shifted every argument (FIXED)

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

### 15.`Security.AuthorizedResources` is read once

An earlier draft recorded that it "was read once and never rebuilt; it is now re-read/
on demand". In the current source `rebuildAuthorized()` is called **once**, at
module load. Editing the list at runtime has no effect. Not changed: making it
live is a behaviour change. The list is read fresh on every **restart**, which is
the supported way.

### 15.Coupling seams outside the abstractions

`client/target.lua` calls the provider exports directly at 10 sites — 5
`exports.ox_target:*` and 5 `exports['qb-target']:*` — and
`client/inventory.lua` / `server/inventory.lua` call `exports.ox_inventory:*`
directly too. These sit outside the `Cis.target` / `Cis.inventory` abstraction
in a way no reader of the boundary model would expect. A third-party target or
inventory provider added in future must patch these files, not implement an
interface.

---

__SPLIT__
## 17. Compatibility shims

Existing `exports['cis_libs']:...` names still work.

| Export | Behavior |
|---|---|
| `GetFramework` | Same method names. Methods come back as callable reference tables, so they work — but that is an implementation detail, not an API. Prefer `Cis.framework.*`. Times out in 15s rather than waiting forever |
| `GetGlobals` | Same live table shape, fed by the event-driven cache |
| `RequestLockDoors` / `RequestUnlockDoors` | Send locked / unlocked explicitly. No longer aliases |
| `DatabaseFetchOne` | Returns one **row**, not a scalar. Use `Cis.db.scalar` for a cell |
| `CallCallback` / `AwaitCallback` | **Local dispatch only.** To reach a client use `CallCallbackClient` / `AwaitCallbackClient` |
| `CreateTarget`, `GetPolyzones`, `GetVehicleProperties`, `Log*` | Unchanged names, new implementations |
| `cis_libs:jobUpdated`, `cis_libs:playerLoaded` | Still emitted |

### Migrating from the old `CallCallback`

If you previously relied on passing a numeric first argument to address a
client, that now dispatches locally.

```lua
-- Before
Cis.callback.call('my:cb', 5, function(ok, ...) end)   -- reached player 5

-- Now
Cis.callback.callClient(5, 'my:cb', function(ok, ...) end)
```

---

## 18. Testing

**Pure tests**, no FiveM required — 397 assertions, no FiveM server. 62 over the
`shared/` modules, 27 on the exports boundary, 163 on the declared surface, and
118 on the utility and algorithm layer.
and the test harness's own JSON encoder:

```
node test/run.js
```

The grid tests fuzz `queryPoint` and `queryNeighbors` against a brute-force
reference over thousands of random points, which is what pins the property the
zones and doors depend on. If you change `shared/grid.lua`, keep those passing.

**Integration tests** live in the separate `cis_libstest` resource and need a
running server. They exercise the real API on both realms — including
teleport-driven zone enter/exit — and write a JSON report into their own folder:

```
ensure cis_libs
ensure cis_libstest
```
```
cistest          -- console or admin: server suite + every connected client
cistest_server   -- server suite only
cistest_client   -- client suite only
```

See https://github.com/SpecialStos/cis_libstest before running it. Mutating tests (inventory
changes, doors, spawned entities) are **off by default** — turn them on only on
a test instance. The suite teleports the player around, so run it somewhere
heartbeat-based anti-cheat is not watching.

Measured boundary behaviour in this document came from that harness. When
something here disagrees with reality, believe the harness.

---

## 19. Troubleshooting

**`Cis.ready` resolves false.** `cis_libs` did not deliver configuration within
15s. Check that `ensure cis_libs` precedes your resource in `server.cfg` and
that the server did not error on start.

**Everything works but the framework is inert.** Console will say
`Framework provider unavailable; using standalone mode`. Your
`Config.Framework.Type` does not match what is running, or the framework
resource is not started. Player lookups return nil in this state.

**`Cis.db.*` returns nil.** The driver was not ready at start, or the query
exceeded `Database.Timeout`. Check the console for the driver message.

**A zone never fires.** Confirm `Config.Framework.Zones.Enabled` is not false.
Check the name is unique and the shape is what you think — `inside` needs
`insideInterval` or it defaults to 500ms.

**Doors do not respond.** Server checks both job permission and distance. The
player must be within `maxDistance` of `interactCoords`. If the target
provider is missing, `cis_libs` falls back to DrawText3D and logs a warning.

**Entity sync does nothing.** `Cis.sync.*` is server-side and gated on
`CisInvokingAllowed()`. If `Security.AuthorizedResources` is non-empty, your
resource must be listed.

**A zone is created but nothing fires, or a name becomes coordinates.** You
called an export with the bracket form. See
[the `self` trap](#the-self-trap).

**A callback never fires when set from another resource.** A function cannot be
passed into an export. Use the `*Event` form.

**Something broke after upgrading.** The most likely change is
`Cis.callback.call` no longer addressing a client by numeric first argument.
See [migration](#migrating-from-the-old-callcallback).

**A call returns `false` with no obvious cause.** Capture the second return
value; it carries a reason. See [Refusals explain themselves](#refusals-explain-themselves).


---


---

---

## 20. The utility and algorithm layer

Fifteen pure modules under `shared/`. No natives, no exports, no globals beyond
one table each, and **no state held inside a module** — state is passed in and
returned out, so all of it runs and is tested under fengari with no FiveM
server. That is deliberate: a utility you cannot test is a utility you do not
trust.

### Algorithms — `shared/algo/`

| Module | For | The one thing to know |
|---|---|---|
| `CisInterp` | clamp, lerp, remap, wrap, 31 easing curves, vector and angle maths | `damp()` is **frame-rate independent**: the same elapsed time reaches the same value at 15, 60 or 240 fps. That is the whole reason to prefer it to a per-frame constant |
| `CisCurve` | Catmull-Rom and cubic Hermite splines with arc-length lookup | Ask for "30 metres along the path", not `t = 0.3` — `t` is not proportional to distance, so driving by `t` accelerates through short chords and crawls through long ones |
| `CisRate` | fixed window, sliding counter, token bucket | All three differ **only** in boundary behaviour. Windows are in **seconds**, and keys are independent, so one player's traffic never consumes another's |
| `CisWindow` | ring buffer, sliding dedupe, bucketed stats | The stats aggregator's memory is constant regardless of event rate |
| `CisRandom` | Fisher–Yates, unbiased integers, weighted choice, Gaussian, seedable generator | `math.random` in LuaJIT is **not** a CSPRNG. The generator is an object so seeding is not global state |
| `CisLRU` | O(1) least-recently-used cache | Includes a section on when a plain table is the better answer |
| `CisHeap` | binary min-heap and a FIFO priority queue | FiveM has no heap, and a sorted table is O(n) per insert. This is where one earns its keep |
| `CisSparse` | generation-counter sparse set | `clear()` is O(1) and iteration costs the size, not the number of slots ever written |

### Utilities — `shared/util/`

| Module | For |
|---|---|
| `CisTable` | deep copy with cycle protection, deep merge with an explicit policy, count, find/filter/map/reduce, stable sort |
| `CisString` | case conversion, split, truncate, Levenshtein and `suggest()` for "did you mean" on a typo'd command |
| `CisValidate` | checkers returning `true` or `false, '<reason>'` — the library's refusal convention, applied to input |
| `CisTime` | duration constants, format/parse, relative time, with `now` injected so it is testable |
| `CisJson` | the refusal layer over an **injected** codec. It ships no encoder: FiveM already has one, and a second would be a second thing to keep correct |
| `CisId` | short readable ids (`door_7F2K9Q1M4XB3`) from an injectable RNG. **Not** a security token |
| `CisSemver` | compare and `satisfies()` with ranges, wildcards, AND and OR |

```lua
-- let the path do the arithmetic instead of integrating speed yourself
local pos = CisCurve.pointAt(route, speed * elapsed, out)

-- frame-rate independent smoothing: identical at 15, 60 or 240 fps
local smooth = CisInterp.damp(current, target, 0.35, dt)

-- rate limit PER PLAYER, not globally
if not CisRate.allow(limiter, 'purchase:' .. src, GetGameTimer() / 1000, 1) then
    return Tell(src, 'slow down')
end
```

**Not framework-related.** Nothing here touches a player, a door or a query —
that is the existing surface. This is the generic layer underneath it, safe for
a consumer to copy privately because it holds no state.

### A known contract mismatch

`CisId.short` takes a bare **function** returning `[0,1)`, while
`CisRandom.newGenerator()` returns an **object** with `:float()`. Bridge them
with a closure until one signature absorbs the other:

```lua
local gen = CisRandom.newGenerator(4242)
local id = CisId.short('door', { rng = function() return gen:float() end, length = 12 })
```

### Measured quirks of the test VM

These are properties of **fengari**, the Lua used to run the test suite, not of
the modules — but they will bite anyone extending the suite, so they are written
down:

- `table.sort` rejects a comparator returning `-1/0/1`; it requires a boolean.
  Real Lua accepts both.
- Lua patterns have **no alternation**, so `match('^(a|b)

**One page per version**, at `CHANGELOG/<version>.md`, committed with the
release. Not one running file: a running file is edited by six people and
diffed by nobody, and the question "what changed in 1.2.0" stops being answerable
once there are twenty entries.

```markdown
# 1.2.0 -- 2026-09-29

**Contract major:** 1 (unchanged)
**Schema:** 0 (unchanged)

### Added
### Changed
### Fixed
### Deprecated
### Removed
### Security
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


---

## 21. Changelog policy

**One page per version**, at `CHANGELOG/<version>.md`, committed with the
release. Not one running file: a running file is edited by six people and
diffed by nobody, and the question "what changed in 1.2.0" stops being answerable
once there are twenty entries.

```markdown
# 1.2.0 -- 2026-09-29

**Contract major:** 1 (unchanged)
**Schema:** 0 (unchanged)

### Added
### Changed
### Fixed
### Deprecated
### Removed
### Security
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


---

## 22. What this repository verifies

Everything in this document is checkable from a clean checkout:

```bash
npm ci
npm run test:all
```

Which is:

| Command | What it proves |
|---|---|
| `npm test` | 62 pure-module, 27 binding, 163 contract, 118 module — 397 in total |
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


---

## 23. What this document does not cover

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

---

## Appendix A — brief for migrating a resource

Hand this to whoever is rebuilding a resource onto `cis_libs`. It is
self-contained: they need no context from this repository beyond the files it
names.

---

We have a FiveM library called `cis_libs` in `resources/[standalone]/cis_libs`.
It replaces the things our resources each reimplement: player state, callbacks,
zones, inventory access, targeting, door locks, entity sync, a database layer,
and logging. It does not depend on ox_lib or PolyZone.

Rebuild our existing resources to use it properly, then verify the result.

**Read these two files before writing a single line of code.** They contain
behaviour that was measured on a live server, not assumed, and getting any of it
wrong produces silent corruption rather than an error:

- `cis_libs/DOCUMENTATION.md` — the traps, the reasoning behind the API, and
  the full integration guide. Everything below is drawn from it.

You will also want `cis_libs/README.md` for the short version.

---

### The non-negotiable facts

They are stated once, in [§0](#0-rules-that-break-code-silently), and they are
not repeated here:

| # | Rule | Section |
|---|---|---|
| 1 | The `self` trap — the bracket form of an export call shifts every argument one slot | [§0.1](#01-the-self-trap--the-one-that-will-cost-you-an-afternoon) |
| 2 | A function can be handed *back* across the boundary, never sent *over* | [§0.2](#02-a-function-can-be-handed-back-never-sent-over) |
| 3 | `shared_script` copies; it does not share | [§0.3](#03-shared_script-copies-it-does-not-share) |
| 4 | A server-side handler in another resource works by reference | [§0.4](#04-server-to-client-handlers-work-by-name-not-by-function) |
| 5 | Subscribe; do not poll | [§0.5](#05-subscribe-do-not-poll) |
| 6 | A refusal explains itself — capture the second return value | [§0.6](#06-a-refusal-explains-itself) |

§3 is the reasoning and the measurements behind rules 1, 2 and 3.

---
## What to hunt for

Grep the codebase for each of these. They are the work.

| Anti-pattern | Replace with |
|---|---|
| `CreateThread` + `Wait(0)` + `PlayerPedId`/`GetEntityCoords` | `Cis.player.coords()`, `Cis.player.ped()` |
| `Wait(0)` loops polling player or vehicle state | `Cis.player.on('vehicle', cb)` and friends |
| Custom "is player near X" loops | `Cis.player.near()` or `Cis.zones.*` |
| `ox_lib` / `PolyZone` imports and zone calls | `Cis.zones.box` / `.sphere` / `.poly` |
| Direct `exports.ox_inventory:GetItemCount` for reads | `Cis.inventory.count(item)` |
| `TriggerServerEvent` for request/response | `Cis.callback.*` |
| Per-frame `exports.ox_lib:...` or `exports.qb_*:...` | `Cis.*` equivalents |
| Custom entity-streaming threads | `Cis.sync.ped` / `.prop` / `.vehicle` |
| Per-resource framework branching (`if esx ... else qb`) | `Cis.framework.player(src)` |
| Custom door state tables + per-frame distance loops | `Cis.doors.add` / `.setState` |
| Own log prefix and level scheme | `Cis.log.debug` / `.info` / `.warn` / `.error` |
| `exports['cis_libs'][` (bracket form) | colon form — see fact 1 |

Also add, to each resource's manifest:

```lua
shared_script '@cis_libs/init.lua'
```

and gate startup on readiness:

```lua
Cis.ready(function(ok)
    if not ok then return end
    -- safe to use the Cis API from here
end)
```

`ensure cis_libs` must come before any resource that uses it in `server.cfg`.

---

### How to work

### Phase 1 — Audit (do this yourself, do not delegate)

Read every resource's manifest and Lua files yourself. Build a list: which
resources use cis_libs already, which use ox_lib or PolyZone, and which are
self-contained. This map drives the work and is wrong if you delegate it
without reading the code.

Produce a short written audit before changing anything. Note anything ambiguous
rather than guessing.

### Phase 2 — Migrate (delegate this)

**Split the work across sub-agents.** One agent per resource, or one agent per
concern (zones / callbacks / doors / sync) if a single resource is large. Run
them concurrently.

Each sub-agent prompt must include, verbatim:

1. The five non-negotiable facts above, in full.
2. The path to `cis_libs/DOCUMENTATION.md`, with the
   instruction to read them before writing code.
3. Exactly one resource or concern to handle, named explicitly.
4. The rule: do not edit `cis_libs` itself. If something looks missing or wrong
   in the library, report it back rather than patching it.
5. The rule: do not guess. If the API is ambiguous, read the docs, then say so.

Give each agent a disjoint file set so they cannot collide.

### Phase 3 — Verify (do this yourself)

Do not trust a green report from a sub-agent. Read the diffs.

Then, with a test server running:

```
ensure cis_libs
ensure cis_libstest
```

`/cistest` in the console or as admin runs both realms, teleports the player
around to exercise zone enter/exit, and writes a JSON report into the
`cis_libstest` folder. `node test/run.js` runs the pure unit tests with no
server.

**The teleport tests hold the player in place for seconds and will trip
heartbeat-based anti-cheat.** Run them on a test instance.

Anything the JSON reports as `skipped` was not verified. Say so explicitly
rather than counting it as a pass.

---

### Definition of done

- Zero occurrences of `exports['cis_libs'][` anywhere.
- Zero self-written `Wait(0)` loops that poll player, vehicle, or weapon state.
- Zero ox_lib or PolyZone imports left in migrated resources.
- Every resource's manifest has `shared_script '@cis_libs/init.lua'` and its
  startup is gated on `Cis.ready`.
- `node test/run.js` passes.
- `/cistest` runs with **zero failures**, and every remaining `skipped` is
  listed with the reason it was skipped.
- Anything deliberately left alone is stated out loud with the reason.

### Reporting back

Report: what changed per resource, what you deliberately did not change and
why, anything in `cis_libs` you believe is a bug (do not fix it), and the final
test result including every skip. If you are unsure about a decision, say you
were unsure rather than presenting it as settled.

---

### Support

- Docs: https://docs.cisoko.net
- Discord: https://discord.gg/cisoko
- License: [LICENSE.md](LICENSE.md)
, x)` matches the
  literal string `a|b` and passes silently. Any range or choice validation built
  on a pattern containing `|` is wrong.
- `pairs` does not walk the array part in ascending order, so a positional
  counter over a config array is not safe here.

---

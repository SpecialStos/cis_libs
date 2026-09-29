# cis_libs — implementation guide

For developers writing resources that consume `cis_libs`. Read [How the boundary
works](#how-the-boundary-works) before you write your first line — almost every
integration mistake comes from misunderstanding that one section.

- [What this is](#what-this-is)
- [Install](#install)
- [How the boundary works](#how-the-boundary-works)
- [The performance model](#the-performance-model)
- [Quick start](#quick-start)
- [API reference](#api-reference)
- [Recipes](#recipes)
- [Security model](#security-model)
- [Configuration reference](#configuration-reference)
- [Compatibility shims](#compatibility-shims)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)

---

## What this is

`cis_libs` is a standalone FiveM resource providing the pieces almost every
server rewrites: player state, a callback system, spatial zones, an inventory
bridge, a targeting bridge, door locks, entity sync, a database layer, and
logging. It depends on no other library — not ox_lib, not PolyZone.

It is not a framework and does not replace your framework. It sits beside
ESX / QBCore / QBOX and normalises the differences so your resource can be
written once.

Version 1.0.0. Requires OneSync and server build 4500+.

---

## Install

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

## How the boundary works

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

## The performance model

### Free — no boundary crossing

These are direct native calls for a consumer. Call them freely.

| Call | Cost |
|---|---|
| `Cis.player.ped()` | `PlayerPedId()` |
| `Cis.player.coords()` | `GetFrameCoords`, memoised to once per frame |
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

## Quick start

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

## API reference

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
Cis.db.transaction(queries)      -- oxmysql only
```

Always parameterised — never interpolate user input into the SQL string.

Each of these yields and gives up after `Config.Framework.Database.Timeout`
(default 15000ms), returning `nil`. They cannot park your coroutine forever.

`transaction` returns `false, 'transactions require oxmysql'` on other drivers.

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
Cis.net.on(eventName, function(src, ...) end)
```

Registers a net event that validates `source` and rate-limits per player
(8 per second by default) before invoking your handler. Prefer this over
`RegisterNetEvent` for any event a client can reach.

### `Cis.streaming` — client

```lua
Cis.streaming.model(model, timeout)  -- returns loaded, hash
```

Yields until the model loads or the timeout expires. Replaces the
`RequestModel` + `Wait(0)` loop every resource otherwise writes.

---

## Recipes

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

## Security model

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

For any event a client can reach, use `Cis.net.on`:

```lua
Cis.net.on('my:resource:doThing', function(src, payload)
    if not validate(src, payload) then return end
end)
```

This validates `source` is a real player and rate-limits per player. Using
`RegisterNetEvent` directly gets you neither.

---

## Configuration reference

`configs/master_config.lua`:

| Key | Default | Notes |
|---|---|---|
| `CheckVersion` | `true` | Outbound HTTP to a third-party GitHub Pages URL on every start. Turn off unless you want it |
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

## Compatibility shims

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

## Testing

**Pure tests**, no FiveM required — 105 assertions over the `shared/` modules
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

Read `cis_libstest/README.md` before running it. Mutating tests (inventory
changes, doors, spawned entities) are **off by default** — turn them on only on
a test instance. The suite teleports the player around, so run it somewhere
heartbeat-based anti-cheat is not watching.

Measured boundary behaviour in this document came from that harness. When
something here disagrees with reality, believe the harness.

---

## Troubleshooting

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

- `cis_libs/MEMORY.md` — the traps, and the reasoning behind the API
- `cis_libs/DOCUMENTATION.md` — the full API reference and integration guide

You will also want `cis_libs/README.md` for the short version.

---

## Non-negotiable facts

These were each learned the expensive way. Violating any of them breaks code
without raising an error.

### 1. The `self` trap — read this twice

```lua
exports['cis_libs']:SomeExport(a, b)    -- CORRECT
exports['cis_libs']['SomeExport'](a, b) -- WRONG
```

The bracket form looks identical and is not. It yields an unbound method, so
the exports table is expected as the first argument. Without it, **every
argument shifts one place left**.

`cis_libs` shipped this bug itself. `Cis.zones.box(name, centre, size, {})`
reached the library as `Cis.zones.box(centre, size, {}, ???)` — the zone's
**name became its own coordinates**, and creation silently returned false.

If you must call an export dynamically, the only safe form is:

```lua
local lib = exports['cis_libs']
lib.SomeExport(lib, a, b)
```

Grep every `exports['cis_libs'][` in the codebase. There must be zero.

### 2. A function can be handed back, but not sent over

| Direction | Works? | Notes |
|---|---|---|
| Function as an **argument** | **No** | Arrives `nil` |
| Function as a **return value** | Yes | Arrives as a callable reference table |

`type()` reports `table` for a returned function, not `function`. Never test for
`'function'` when receiving one.

Consequence: **you cannot pass a callback into cis_libs.** Use the event forms
described below.

### 3. `shared_script` copies; it does not share

Each resource has its own Lua VM. Loading a `shared_script` copies the file in.

**Never** `shared_script '@cis_libs/client/cache.lua'` or any other stateful
file. You would get a second player cache, a second 1-second polling thread, a
second `Globals` table, and native calls multiplied by your resource count. This
is the single most damaging mistake available to you.

The pure `shared/` modules (`grid`, `pending`, `histogram`, `config`) contain no
natives and are safe to copy when you genuinely want a private instance.

### 4. Callbacks cross as net events, never as functions

Zone and proximity callbacks have a "Event twin" for exactly this reason:

```lua
Cis.zones.box('shop', centre, size, {
    onEnterEvent = 'myResource:shopEnter',   -- receives (zoneName, x, y, z)
    onExitEvent  = 'myResource:shopExit',
    insideEvent  = 'myResource:shopInside',
})

RegisterNetEvent('myResource:shopEnter', function(zoneName, x, y, z)
    -- ...
end)
```

Same for proximity:

```lua
Cis.player.near(coords, 10.0, nil, nil, 'myResource:nearEnter', 'myResource:nearExit')
```

### 5. Exports return data, not behaviour

Server-side handlers owned by another resource work by name:

```lua
-- in this resource
exports('myResource:handlePurchase', function(src, item, amount) ... end)
Cis.callback.register('purchase', 'myResource:handlePurchase')
```

Known caveat: a handler called this way runs and receives its arguments, but
its **return value may come back `nil`**. Signal results by side effect or an
event until that is resolved.

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

## How to work

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
2. The path to `cis_libs/MEMORY.md` and `cis_libs/DOCUMENTATION.md`, with the
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

## Definition of done

- Zero occurrences of `exports['cis_libs'][` anywhere.
- Zero self-written `Wait(0)` loops that poll player, vehicle, or weapon state.
- Zero ox_lib or PolyZone imports left in migrated resources.
- Every resource's manifest has `shared_script '@cis_libs/init.lua'` and its
  startup is gated on `Cis.ready`.
- `node test/run.js` passes.
- `/cistest` runs with **zero failures**, and every remaining `skipped` is
  listed with the reason it was skipped.
- Anything deliberately left alone is stated out loud with the reason.

## Reporting back

Report: what changed per resource, what you deliberately did not change and
why, anything in `cis_libs` you believe is a bug (do not fix it), and the final
test result including every skip. If you are unsure about a decision, say you
were unsure rather than presenting it as settled.

---

## Support

- Docs: https://docs.cisoko.net
- Discord: https://discord.gg/cisoko
- License: [LICENSE.md](LICENSE.md)

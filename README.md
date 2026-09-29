# cis_libs

Standalone FiveM library and framework bridge. Other resources should use this for player state, callbacks, zones, inventory, targeting, doors, entity sync, database, and logging. It does not depend on ox_lib or PolyZone.

Version **1.0.0**.

## Install

1. Put this folder in `resources`.
2. Add `ensure cis_libs` to `server.cfg` before resources that use it.
3. Edit `configs/master_config.lua` to match the server (framework, inventory, target, database).

Consumers add one line to their manifest:

```lua
shared_script '@cis_libs/init.lua'
```

That sets a global `Cis` table. Hot reads (coords, ped, vehicle) stay in that VM. Mutations go through exports on `cis_libs`.

## Consumer rules

These are what make other resources cheaper. They only work if callers stop doing the work themselves.

- Do not run a `PlayerPedId` / `GetEntityCoords` / weapon loop. Use `Cis.player` or `Cis.player.near`.
- Do not call ESX or QB callbacks. Use `Cis.callback`.
- Do not call inventory exports for a count. Use `Cis.inventory`.
- Do not add PolyZone or ox_lib zones in a new resource. Use `Cis.zones`.
- Do not `TriggerServerEvent` into `cis_libs` events. Use the API. Net events are an internal transport.
- Door, item, and money changes go through the server API. The client cache is a hint, not authority.

Idle budget of this resource: no `Wait(0)` loop except DrawText3D while a door is actually in range, and only when a zone has opted into per-frame drawing. Natives run when a consumer asks, or when a game event says the ped, vehicle, or weapon changed. A fallback poll (`Config.UpdateInterval.Player`, default 1000ms) covers what events miss — respawn, seat change, weapon swap. Lowering it trades idle native calls for fresher `Globals`.

## API

```lua
Cis.ready(function(ok) end)
Cis.wait(15000)

Cis.player.ped()
Cis.player.coords()          -- one native per frame for the whole client
Cis.player.vehicle()         -- entity, seat; nil on foot
Cis.player.weapon()
Cis.player.on('vehicle', function(current, previous) end)
Cis.player.near(coords, distance, onEnter, onExit)

Cis.callback.register(name, fn)     -- server
Cis.callback.await(name, ...)       -- local dispatch, always times out
Cis.callback.call(name, cb, ...)
Cis.callback.callClient(src, name, cb, ...)   -- server -> client
Cis.callback.awaitClient(src, name, ...)

Cis.framework.player(src)           -- server
Cis.framework.notify(srcOrNil, message, kind)
Cis.inventory.count(item)           -- client cache, O(1)
Cis.inventory.has(item, amount)
Cis.inventory.add(src, item, amount)
Cis.inventory.remove(src, item, amount)

Cis.zones.poly(name, points, options)
Cis.zones.box(name, center, size, options)
Cis.zones.sphere(name, center, radius, options)
Cis.target.add / .remove
Cis.doors.add / .setState / .get
Cis.sync.ped / .prop / .vehicle
Cis.db.query / .single / .scalar / .insert / .update / .transaction
Cis.security.report(src, reason)
Cis.log.debug / .info / .warn / .error
```

`Cis.callback.call` dispatches locally and passes every argument through as data — a number is never reinterpreted as a player id. Use `callClient` / `awaitClient` to address a specific player.

Zone `inside` callbacks default to 500ms. A zone that must draw every frame sets `insideInterval = 0` and is the only zone that ticks per frame.

Callbacks use one client event and one server event. Pending keys increment and are **bound to the player they were sent to**, so a client cannot resolve another player's callback or forge a response. Await and callback style both time out (default 10s, `Config.CallbackTimeout`).

`Cis.db.*` awaits give up after `Config.Framework.Database.Timeout` (default 15s) and return `nil` rather than parking the coroutine forever.

## Compatibility shims

Existing `exports['cis_libs']:...` names still work:

| Export | Behavior |
|---|---|
| `GetFramework` | Same method names. `HasItem`, `GetOnlineJobCount`, and `TriggerServerCallback` complete. Times out in 15s instead of waiting forever. |
| `GetGlobals` | Same live table shape, fed by the event-driven cache. |
| `RequestLockDoors` / `RequestUnlockDoors` | Send locked / unlocked explicitly. They are no longer aliases. |
| `DatabaseFetchOne` | Returns one **row**, not a scalar. Use `Cis.db.scalar` for a cell. |
| `CallCallback` / `AwaitCallback` | Local dispatch only. To reach a client, use the new `CallCallbackClient` / `AwaitCallbackClient`. |
| `CreateTarget`, `GetPolyzones`, `GetVehicleProperties`, `Log*` | Unchanged names, new implementations. |
| `cis_libs:jobUpdated`, `cis_libs:playerLoaded` | Still emitted. |

## Config

Server-only files:

- `configs/master_config.lua` — framework, inventory, target, database, doors, debug
- `configs/discordLogs_config.lua` — webhook URLs (never sent to clients)
- `configs/security_config.lua` — event prefix, authorized resources, drop-player

The client receives a whitelist: framework type, inventory, target, door mode, debug, intervals. Webhooks, database settings, the drop-player function, and the allow-list stay on the server.

Set `Security.AuthorizedResources` to a non-empty list to restrict door and sync mutations to those resources. An empty list allows any server-side caller.

`Security.DropPlayer` accepts either a boolean or a `function(src, reason)`. The shipped `configs/security_config.lua` assigns the function so custom kick messages work.

`Config.Doorlock.Persist = true` stores doors in `cis_doors` when the SQL driver is ready.

`Config.Sync.Enabled = false` turns `Cis.sync.*` into a no-op without unloading the resource.

## Entity sync

`Cis.sync.*` records are versioned. Re-sending an identical record is a no-op, so a record only rebroadcasts when its data actually changes. Records marked `dynamic` rebroadcast on a timer so players who walk into range still receive them — the client moves an existing entity in place rather than respawning it, so a moving entity does not flicker. A change of `model` or `kind` is the only thing that forces a despawn and respawn.

## Debug

- Client command `cis_debug` prints ped, vehicle, and last zone pass time.
- Server command `cis_debug` (console or admin) prints ready state and whether the client payload contains secrets.

Pure tests (no FiveM):

```
node test/run.js
```

## Support

- Integration guide: [DOCUMENTATION.md](DOCUMENTATION.md) — read
  [How the boundary works](DOCUMENTATION.md#how-the-boundary-works) before
  writing your first consumer
- Docs: https://docs.cisoko.net
- Discord: https://discord.gg/cisoko
- License: [LICENSE.md](LICENSE.md)

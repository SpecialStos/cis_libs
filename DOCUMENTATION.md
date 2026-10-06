# cis_libs — documentation

**Version 1.0.0.** Contract **`api = 1`**. The archived monolith document is
`docs/archive/DOCUMENTATION-1.x.md`. It is not current.

The machine-readable contract is `api.lua`. It is not listed in `fxmanifest.lua`.
Load it with `loadfile`. `npm run test:api` fails if `api.lua` and the
registered surface disagree. `npm run gen-types` writes the tables in §6 from
that file; `npm run gen-types:check` fails if they drift.

---

## 0. Boundary

Three facts the suite enforces:

1. **`cis_libs` owns no table, reads no config file, and calls no third-party
   resource by name.** It is a boundary, not an implementation.
2. **The `Cis.*` names did not change in the 2.0 split.** A 1.x consumer keeps
   the same manifest line and the same calls. The contract major is still `1`.
3. **A missing product is a refusal with a reason**, not a nil that looks like
   "not found". Run `cis_debug` on the server console.

```
cis_libs          boundary and primitives. Knows the shape of a capability.
   ▲  ▲  ▲        Knows nothing about who provides it.
   │  │  └── cis_keys     doors, keys (optional)
   │  └───── cis_bridge   third-party adapters (optional)
   └──────── cis_core     framework, config, migrations (optional)
```

`cis_libs` alone boots: zones, callbacks, entity sync, cache, logging, streaming,
points, commands, diagnostics. Every capability call with no provider answers
`false, reason`.

---

## 1. Install

OneSync on. Server build ≥ 4500. Both are declared on the manifest.

```cfg
ensure cis_libs
```

```lua
dependency 'cis_libs'
shared_script '@cis_libs/init.lua'
```

`init.lua` is the only file a consumer may `shared_script`. Each Lua file is its
own chunk. `shared_script '@cis_libs/shared/registry.lua'` gives you a second
registry that nothing else can see.

Call with a colon:

```lua
exports['cis_libs']:GetCapabilities()
```

Calling `Export` through a string index on the exports table is the same idea
done wrong: that table becomes argument 1.

A Lua function cannot cross the FiveM exports boundary. Zone `onEnter`, callback
handlers, hook bodies, and command handlers that you pass *into* an export arrive
`nil`. Use an event name (`onEnterEvent`) or `'resource:Export'`.

Editor types: add `cis_libs/types` to the Lua workspace. The stub is generated.
Do not edit it.

---

## 2. Capabilities

A capability is a named slot. A product registers a provider. First registration
wins. Only the owner may release it.

Slots: `framework`, `database`, `target`, `inventory`, `inventoryProvider`,
`doors`, `doorsClient`, `discord`, `security`, `dataProbe`, `migration`, `ui`.

A resource that registers a slot `cis_libs` does not declare is refused on every
boot. `WaitCapability(slot, timeoutMs?)` waits for a slot to fill (default
30000 ms) and returns `true, owner` or `false, reason`.

`GetCapabilities()` returns every slot, always. Empty is `owner = nil`,
`resolved = false`, never absent.

---

## 3. Configuration

`SetConfig(config?, security?, discord?)` — three arguments, not one table.
First successful supplier wins. A second caller gets `false` plus the owner.
`cis_core` is the intended supplier. Built-in defaults are not a supplier, so
the first real `SetConfig` is accepted.

`security` **replaces** `Security` outright. It is not merged.

```lua
exports['cis_libs']:SetConfig({
    UpdateInterval = { Player = 500, Weapon = 500 },
}, {
    EventPrefix = 'cis_libs',
    AuthorizedResources = { 'cis_core', 'cis_keys', 'my_resource' },
    AllowAnyResource = false,
    DropPlayer = false,
}, {
    DiscordLogsLinks = {},
})
```

**Empty `Security.AuthorizedResources` is always restrictive.** That is the one
behaviour change in 1.0.0. There is no legacy exception, no marker file, and no
database probe. Mutating exports (`SyncCreate`, door writes, …) refuse every
foreign resource until the list names it, or until `AllowAnyResource = true`
(loud on every boot; do not ship with it on).

The client payload is a whitelist. Webhook URLs, drop handlers, and
`AuthorizedResources` do not leave the server.

---

## 4. Diagnostics

| Command | Who | What |
|---|---|---|
| `cis_debug` | console, or a player with framework `admin` | ready flag, capability table, who supplied config. No secrets. |
| `cis_doctor` | console | `GetSelfCheck()`: each problem names its fix. |
| `cis_audit` | console | in-memory audit ring. |
| `cis_force_unregister <slot>` | console | vacates a slot. Restricted. |

`GetDiagnostics(opts?)` is counts only: never a player name, identifier, or IP.
`opts.collect = true` runs `collectgarbage` in **this** resource before
`memoryKb`. A collect in the caller’s Lua state does not collect cis_libs.
`memoryKb` is Lua kilobytes (`collectgarbage('count')`), not bytes.

---

## 5. Sync, callbacks, zones

- **Sync** is server-authoritative. Ids are namespaced by the invoking resource.
  Two resources may reuse the same id string; they are different records.
  `networked = true` is created and deleted on the server. A kind that cannot be
  made reliable refuses that flag. Default streaming radius 80. No hysteresis:
  one threshold for enter and leave.
- **Callbacks** across the wire return at most 6 values. `Cis.callback.await`
  errors on refusal by design; a translation layer must not inherit that.
- **Zones / points / hooks:** event names, not functions. Server zones exist
  (`Cis.zones.server.*`) and do not draw.

Modules (fifteen, via `Cis.require`): `curve`, `heap`, `interp`, `lru`,
`random`, `rate`, `sparse`, `window`, `id`, `json`, `semver`, `string`,
`table`, `time`, `validate`. `Cis.require('unknown')` raises.

---

## 6. Public surface

Generated from `api.lua`. Do not edit between the markers.

<!-- generated:begin -->

| Export | Realm | Signature | Since | Notes |
|---|---|---|---|---|
| `AddDoorGroup` | both | `()` | 1.0.0 | no proxy equivalent; exports["cis_libs"]:AddDoorGroup(groupData) |
| `AddDoorToSystem` | both | `()` | 1.0.0 | Cis.doors.add(doorData) |
| `AddSyncDespawnHandler` | client | `(fn)` | 1.0.0 | Cis.sync.onDespawn(fn) unstable |
| `AddSyncSpawnHandler` | client | `(fn)` | 1.0.0 | Cis.sync.onSpawn(fn) unstable |
| `AnimDict` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.animDict(name, timeout) |
| `AnimSet` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.animSet(name, timeout) |
| `AudioBank` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.audioBank(name, timeout) |
| `AutoLogError` | both | `()` | 1.0.0 | Cis.log.error(message) from inside a pcall |
| `AwaitCallback` | both | `()` | 1.0.0 | Cis.callback.await(name, ...) |
| `AwaitCallbackClient` | server | `(name, target, ...)` | 1.0.0 | Cis.callback.awaitClient(src, name, ...) |
| `BreakDoor` | server | `(identifier)` | 1.0.0 | no proxy equivalent; exports["cis_libs"]:BreakDoor(identifier) |
| `CallCallback` | both | `()` | 1.0.0 | Cis.callback.call(name, cb, ...) |
| `CallCallbackClient` | server | `(name, target, cb?, ...)` | 1.0.0 | Cis.callback.callClient(src, name, cb, ...) |
| `ClosestObject` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.closestObject(coords, maxDistance, filter) |
| `ClosestPed` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.closestPed(coords, maxDistance, filter) |
| `ClosestPlayer` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.closestPlayer(coords, maxDistance, filter) |
| `ClosestVehicle` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.closestVehicle(coords, maxDistance, filter) |
| `CommandAdd` | server | `(name, options, handler)` | 1.0.0 | Cis.command.add(name, { params, restricted, help }, handler) |
| `CommandList` | server | `()` | 1.0.0 | Cis.command.list() |
| `CommandParse` | server | `(raw)` | 1.0.0 | no proxy equivalent; the argument splitter used by CommandAdd |
| `CommandRemove` | server | `(name)` | 1.0.0 | Cis.command.remove(name) |
| `CreatePed` | client | `(model, coords, heading?, options?)` | 1.0.0 | no proxy equivalent; returns 0 on an invalid or unloaded model |
| `CreatePoint` | client | `(data)` | 1.0.0 | Cis.points.add({ coords, distance, onEnter, onExit, nearby }) |
| `CreateTarget` | client | `(zoneType, name, coords, size, options?)` | 1.0.0 | Cis.target.add(zoneType, name, coords, size, options) |
| `CreateZone` | client | `(kind, name, a, b, options?)` | 1.0.0 | Cis.zones.box / Cis.zones.poly / Cis.zones.sphere |
| `DbInsert` | server | `(sql, params?)` | 1.0.0 | Cis.db.insert(sql, params) |
| `DbQuery` | server | `(sql, params?)` | 1.0.0 | Cis.db.query(sql, params) |
| `DbScalar` | server | `(sql, params?)` | 1.0.0 | Cis.db.scalar(sql, params) |
| `DbSingle` | server | `(sql, params?)` | 1.0.0 | Cis.db.single(sql, params) |
| `DbTransaction` | server | `(queries)` | 1.0.0 | Cis.db.transaction(queries). Driver-shaped list of { query, values } entries |
| `DbUpdate` | server | `(sql, params?)` | 1.0.0 | Cis.db.update(sql, params) |
| `DebugLog` | client | `(message)` | 1.0.0 | Cis.log.debug(message) |
| `DetectDatabase` | both | `(configured?)` | 1.0.0 | Asks the server which driver is running. Returns { name, resource, version, how, reason } |
| `DetectFramework` | both | `()` | 1.0.0 | Asks the server what framework it is actually running. Returns { name, resource, version, how, reason } |
| `DrawText3D` | client | `(x, y, z, text, settings?)` | 1.0.0 | no proxy equivalent |
| `FixDoor` | server | `(identifier)` | 1.0.0 | no proxy equivalent; exports["cis_libs"]:FixDoor(identifier) |
| `GetAllDoorData` | server | `()` | 1.0.0 | no proxy equivalent; the full door and group tables |
| `GetAuditLog` | server | `(limit?)` | 1.0.0 | The capability and configuration change log, newest last. Gated on Security.AuthorizedResources like every other mutating call. Entries carry resource and slot names and never a player name, identifier or IP. Bounded by Config.AuditLines, default 500 |
| `GetCachedHeading` | client | `()` | 1.0.0 | Cis.player.heading(), which reads the native directly in a consumer VM |
| `GetCachedPed` | client | `()` | 1.0.0 | Cis.player.ped(), which reads the native directly in a consumer VM |
| `GetCachedPlayerId` | client | `()` | 1.0.0 | Cis.player.playerId() |
| `GetCachedSeat` | client | `()` | 1.0.0 | Cis.player.seat() |
| `GetCachedServerId` | client | `()` | 1.0.0 | Cis.player.serverId() |
| `GetCachedVehicle` | client | `()` | 1.0.0 | Cis.player.vehicle() |
| `GetCachedWeapon` | client | `()` | 1.0.0 | Cis.player.weapon() |
| `GetCapabilities` | both | `()` | 1.0.0 | The one call that answers "which of my four resources is actually running". Returns { [slot] = { owner, resolved } } |
| `GetClientConfig` | client | `()` | 1.0.0 | no proxy equivalent; the config the server sent to this client |
| `GetClientLogging` | client | `()` | 1.0.0 | Cis.log.debug / info / warn / error |
| `GetClosestDoor` | client | `()` | 1.0.0 | no proxy equivalent; exports["cis_libs"]:GetClosestDoor() |
| `GetClosestPoint` | client | `()` | 1.0.0 | Cis.points.getClosest() |
| `GetClosestVehicle` | client | `()` | 1.0.0 | no proxy equivalent; a 5 unit forward ray, then a 5 unit radius search |
| `GetConfigSummary` | server | `()` | 1.0.0 | no proxy equivalent; the non-secret half of the server config |
| `GetCurrentWeaponData` | client | `(ped?)` | 1.0.0 | Cis.player.weapon() |
| `GetDiagnostics` | both | `(opts?)` | 1.0.0 | Counts, never player data: capability slots and owners, sync records by owner, pending callbacks, net handlers, error and warning counters, memory, uptime, and pass timings. The harness diffs counters and probes only; timings are a sibling so a pass does not fail every case |
| `GetDiscordConfig` | server | `()` | 1.0.0 | The outbound/webhook configuration SetConfig was handed, for the capability that does the sending. Server realm only -- it holds webhook URLs and is deliberately not on the client payload whitelist |
| `GetDiscordQueueDepth` | server | `()` | 1.0.0 | no proxy equivalent; queued message count and dropped count |
| `GetDistanceBetweenCoords` | client | `(x1, y1, z1, x2, y2, z2)` | 1.0.0 | no proxy equivalent |
| `GetDoorState` | both | `()` | 1.0.0 | Cis.doors.get(id) |
| `GetKnownTargets` | both | `()` | 1.0.0 | The ordered framework and driver tables detection uses. Shared so a product cannot disagree with the debug output about what is running |
| `GetLastRefusal` | server | `()` | 1.0.0 | Read after a nil/false answer from a capability export to learn WHY it was refused. Returns a sentence naming the missing or failing capability, or nil when the last call succeeded. Additive: no existing return shape changes |
| `GetLibsPrefix` | server | `()` | 1.0.0 | no proxy equivalent; the configured Security.EventPrefix |
| `GetLogging` | server | `()` | 1.0.0 | Cis.log.debug / info / warn / error |
| `GetNormalizedPlayer` | server | `(src)` | 1.0.0 | Cis.framework.player(src) |
| `GetOnlineJobCount` | server | `(jobs)` | 1.0.0 | no proxy equivalent; the callback cis_libs:getOnlineJobCount |
| `GetPlayerVehicleSeat` | client | `()` | 1.0.0 | Cis.player.vehicle(), second return value |
| `GetPointsDebug` | client | `()` | 1.0.0 | no proxy equivalent; the live debug record for the point pass |
| `GetSelfCheck` | server | `()` | 1.0.0 | The boot self-check as data: { ok, problems = { { code, message, fix } } }. Each problem names the change that resolves it |
| `GetSyncedEntities` | client | `()` | 1.0.0 | no proxy equivalent; the id-to-handle table of everything this client spawned |
| `GetSyncedEntity` | client | `(key)` | 1.0.0 | Cis.sync.entity(key) |
| `GetTableSize` | client | `(t)` | 1.0.0 | no proxy equivalent |
| `GetVehicleProperties` | client | `(vehicle)` | 1.0.0 | no proxy equivalent; the full property snapshot used by sync |
| `GetZoneDebug` | client | `()` | 1.0.0 | no proxy equivalent; the last grid pass cost in milliseconds |
| `HookOn` | both | `(name, fn, opts?)` | 1.0.0 | Cis.hooks.on(name, fn, opts) |
| `HookRemove` | both | `(id)` | 1.0.0 | Cis.hooks.remove(id) |
| `HookRun` | both | `(name, payload?)` | 1.0.0 | Cis.hooks.run(name, payload) |
| `InventoryAdd` | server | `(src, item, amount, metadata?)` | 1.0.0 | Cis.inventory.add(src, item, amount, metadata) |
| `InventoryCount` | both | `()` | 1.0.0 | Cis.inventory.count(item) on the client, Cis.inventory.count(src, item) on the server |
| `InventoryHas` | both | `()` | 1.0.0 | Cis.inventory.has(...) |
| `InventoryRemove` | server | `(src, item, amount)` | 1.0.0 | Cis.inventory.remove(src, item, amount) |
| `InvokingAllowed` | server | `()` | 1.0.0 | no proxy equivalent; ask before mutating. This is the supported way to avoid a refusal |
| `IsReady` | client | `()` | 1.0.0 | Cis.isReady, or Cis.ready(cb) |
| `KeybindAdd` | client | `(options)` | 1.0.0 | Cis.keybind.add({ name, description, defaultKey, onPress, onRelease }) |
| `Keybinds` | client | `()` | 1.0.0 | no proxy equivalent; every binding this library registered |
| `LockDoors` | server | `(identifier)` | 1.0.0 | Cis.doors.setState(identifier, true) |
| `LogDebug` | both | `()` | 1.0.0 | Cis.log.debug(message) |
| `LogError` | both | `()` | 1.0.0 | Cis.log.error(message) |
| `LogInfo` | both | `()` | 1.0.0 | Cis.log.info(message) |
| `LogWarn` | both | `()` | 1.0.0 | Cis.log.warn(message) |
| `ModuleInfo` | both | `(name, opts?)` | 1.0.0 | Cis.moduleInfo(name, opts) |
| `NearbyObjects` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.nearbyObjects(coords, maxDistance, filter) |
| `NearbyPeds` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.nearbyPeds(coords, maxDistance, filter) |
| `NearbyPlayers` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.nearbyPlayers(coords, maxDistance, filter) |
| `NearbyVehicles` | client | `(coords, maxDistance, filter)` | 1.0.0 | Cis.world.nearbyVehicles(coords, maxDistance, filter) |
| `Notify` | both | `()` | 1.0.0 | Cis.framework.notify(...). With a framework provider registered the call passes through to it untouched; with none, cis_libs delivers it itself through the same guards NotifyClient uses, so a server with no framework does not go mute and does not become the unbounded path. The two-argument client form sends `kind` in the message slot; this is pinned as a known defect in test/contracts.lua and is a MAJOR change to correct |
| `NotifyClient` | server | `(src, message, kind?)` | 1.0.0 | Called by a product to show a notification to one client, without hardcoding the event name owned by this library. Answers `false, reason` for a src that is not a connected player, truncates a message past 512 characters, and allows 10 a second per (src, calling resource) |
| `OnPlayerCache` | client | `(key, cb)` | 1.0.0 | Cis.player.on(key, cb). The cb cannot cross the boundary; use a net event |
| `Ptfx` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.ptfx(name, timeout) |
| `PublishInventory` | server | `(src)` | 1.0.0 | Called by the inventory service. Pushes cis_libs:client:inventory to one player |
| `PublishJobUpdate` | server | `(job, src?)` | 1.0.0 | Called by cis_core when a player changes job. Fires cis_libs:jobUpdated, so the event name stays owned by this library |
| `PublishPlayerLoaded` | server | `(job, src?)` | 1.0.0 | Called by cis_core when a player object exists. Fires cis_libs:playerLoaded |
| `RandomFloat` | client | `(lower, greater)` | 1.0.0 | no proxy equivalent |
| `RateOk` | server | `(src, name, windowMs?, maxHits?)` | 1.0.0 | no proxy equivalent; a resource may share the library rate limiter |
| `RaycastCamera` | client | `(flags, ignore, distance?, timeoutMs?)` | 1.0.0 | Cis.raycast.camera(flags, ignore, distance, timeoutMs) |
| `RaycastFromCoords` | client | `(origin, target, flags?, ignore?, timeoutMs?)` | 1.0.0 | Cis.raycast.fromCoords(origin, target, flags, ignore, timeoutMs) |
| `RegisterCallback` | both | `()` | 1.0.0 | Cis.callback.register(name, handler) |
| `RegisterCapability` | both | `()` | 1.0.0 | Called by cis_core, cis_bridge and cis_keys with (slot, "resource:Export"). First registration wins |
| `RemoveNearWatcher` | client | `(id)` | 1.0.0 | Cis.player.nearStop(id); the id WatchNear returns as its second value |
| `RemovePoint` | client | `(id)` | 1.0.0 | Cis.points.remove(id) |
| `RemoveStatebagHandler` | both | `(cookie)` | 1.0.0 | Cis.statebag.remove(cookie) |
| `RemoveTarget` | client | `(name, isPed?)` | 1.0.0 | Cis.target.remove(name, isPed) |
| `RemoveZone` | client | `(name)` | 1.0.0 | Cis.zones.remove(name) |
| `RequestInventorySync` | client | `()` | 1.0.0 | Cis.inventory.count is a hint. This asks for a fresh one. Client only |
| `RequestLockDoors` | client | `(identifier)` | 1.0.0 | Cis.doors.setState(id, true) on the client |
| `RequestModelTimeout` | client | `(model, timeout?)` | 1.0.0 | Cis.streaming.model(model, timeout) |
| `RequestUnlockDoors` | client | `(identifier)` | 1.0.0 | Cis.doors.setState(id, false) on the client |
| `Round` | client | `(num, numDecimalPlaces?)` | 1.0.0 | no proxy equivalent; math round to n places |
| `Scaleform` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.scaleform(name, timeout) |
| `SecureNetOn` | server | `(name, fn, opts?)` | 1.0.0 | Cis.net.on(name, fn, opts) -> true when the event was bound |
| `SecurityReport` | server | `(src, reason)` | 1.0.0 | Cis.security.report(src, reason) |
| `SendDiscordLog` | server | `(webhookURL, title, message, color, ping)` | 1.0.0 | Cis.log.info with a discordType; no proxy equivalent for a raw webhook push |
| `ServerZoneBox` | server | `(center, size, opts?)` | 1.0.0 | Cis.zones.server.box(center, size, opts) |
| `ServerZoneContains` | server | `(id, coords)` | 1.0.0 | Cis.zones.server.contains(id, coords) |
| `ServerZonePlayers` | server | `(id)` | 1.0.0 | Cis.zones.server.players(id) |
| `ServerZonePoly` | server | `(points, opts?)` | 1.0.0 | Cis.zones.server.poly(points, opts) |
| `ServerZoneRemove` | server | `(id)` | 1.0.0 | Cis.zones.server.remove(id) |
| `ServerZoneSphere` | server | `(center, radius, opts?)` | 1.0.0 | Cis.zones.server.sphere(center, radius, opts) |
| `SetConfig` | server | `(config?, security?, discord?)` | 1.0.0 | Called by cis_core at boot with (config, security, discord). First registration wins; a second is refused and named. `security.AllowAnyResource` is the 1.0.0 opt-in escape hatch: with it true an EMPTY AuthorizedResources stops meaning restrictive, and the console warns on every boot |
| `SetDropPlayerHandler` | server | `(provider)` | 1.0.0 | Called by whoever ships the config, with "resource:Export". A FUNCTION cannot be sent across the boundary, which is why this exists |
| `SetVehicleProperties` | client | `(vehicle, props, fixVehicle?)` | 1.0.0 | no proxy equivalent; diffs against the last applied snapshot |
| `StatebagOnEntity` | both | `(key, handler, timeoutMs?)` | 1.0.0 | Cis.statebag.onEntity(key, handler, timeoutMs) |
| `StatebagOnPlayer` | both | `(key, handler, timeoutMs?)` | 1.0.0 | Cis.statebag.onPlayer(key, handler, timeoutMs) |
| `SyncClear` | server | `()` | 1.0.0 | Cis.sync.clear() |
| `SyncCreate` | server | `(kind, data)` | 1.0.0 | Cis.sync.ped / Cis.sync.prop / Cis.sync.vehicle |
| `SyncList` | server | `()` | 1.0.0 | Cis.sync.list() |
| `SyncRemove` | server | `(id?)` | 1.0.0 | Cis.sync.remove(id) |
| `TargetAvailable` | client | `()` | 1.0.0 | no proxy equivalent; true when a configured target provider is started |
| `TargetExists` | client | `(name)` | 1.0.0 | Cis.target.exists(name) |
| `TextureDict` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.textureDict(name, timeout) |
| `TriggerLibCallback` | client | `(name, cb?, ...)` | 1.0.0 | the client-to-server round trip whose callback receives only the results |
| `TryAwaitCallback` | both | `()` | 1.0.0 | Cis.callback.tryAwait(name, ...) -> ok, ... on success; false, reason on a refusal |
| `UiConfirm` | client | `(opts)` | 1.0.0 | Cis.ui.confirm(opts). Forward only -- no native dialog. RETURNS, does not take a callback |
| `UiInput` | client | `(opts)` | 1.0.0 | Cis.ui.input(opts). Forward only -- no native dialog. RETURNS, does not take a callback |
| `UiNotify` | client | `(message, kind?)` | 1.0.0 | Cis.ui.notify(message, kind). NOT Cis.framework.notify: that one is player-targeted, rate-limited, and the one a server uses. This is the local toast |
| `UiProgress` | client | `(opts)` | 1.0.0 | Cis.ui.progress(opts). Forward only -- cis_libs draws no bar |
| `UiTextUIHide` | client | `()` | 1.0.0 | Cis.ui.textUI.hide() |
| `UiTextUIIsOpen` | client | `()` | 1.0.0 | Cis.ui.textUI.isOpen() |
| `UiTextUIShow` | client | `(text, opts?)` | 1.0.0 | Cis.ui.textUI.show(text, opts) |
| `UnlockDoors` | server | `(identifier)` | 1.0.0 | Cis.doors.setState(identifier, false) |
| `UnregisterCapability` | server | `(slot)` | 1.0.0 | Called by a product on shutdown or handover. Only the slot owner may release it |
| `UpdateTarget` | client | `(name, newOptions?)` | 1.0.0 | Cis.target.update(name, options) |
| `WaitCapability` | server | `(slot, timeoutMs?)` | 1.0.0 | Waits up to timeoutMs for a capability slot to be filled. Returns true and the owner, or nil and a reason naming the slot. No proxy equivalent -- a consumer waits from its own resource. |
| `WaitReady` | both | `(timeout?)` | 1.0.0 | Cis.ready(cb, timeout) or Cis.wait(timeout) |
| `WatchNear` | client | `(coords, distance?, onEnter?, onExit?, onEnterEvent?, onExitEvent?)` | 1.0.0 | Cis.player.near(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent) |
| `WeaponAsset` | client | `(name, timeout?)` | 1.0.0 | Cis.streaming.weaponAsset(hash, timeout) |
| `ZoneContains` | client | `(name, point?)` | 1.0.0 | Cis.zones.contains(name, point) |

| Event | Since | Payload |
|---|---|---|
| `chat:addSuggestion` | 1.0.0 | server to client, (name, help, params) while the chat resource is started. The one new standard-resource integration allowed, used only by Cis.command.add |
| `cis_libs:capabilityChanged` | 1.0.0 | both realms: ({ slot, action, owner, previousOwner, resolved }) |
| `cis_libs:cb` | 1.0.0 | client to server and server to client: (name, key, ...) |
| `cis_libs:cb:res` | 1.0.0 | client: (key, ok, ...) resolving an outstanding callback |
| `cis_libs:cb:serverRes` | 1.0.0 | server: (key, ok, ...) resolving an outstanding client callback |
| `cis_libs:client:getData` | 1.0.0 | server to client: ({ Config, EventPrefix }) on join. DoorData was not shipped in 1.0.0 |
| `cis_libs:client:inventory` | 1.0.0 | server to client: ({ [itemName] = count }), pushed by PublishInventory |
| `cis_libs:client:showNotification` | 1.0.0 | server to client: (message, kind) |
| `cis_libs:client:syncRemove` | 1.0.0 | server to client: (key) despawn a synced entity. The same namespaced key the upsert carried. |
| `cis_libs:client:syncUpsert` | 1.0.0 | server to client: (record) for a nearby synced entity. The record's identity is `record.key` -- the caller's id namespaced by the owning resource -- and that is what a client keys its entity on. `record.id` is the caller's own id, carried for reference. |
| `cis_libs:jobUpdated` | 1.0.0 | server to client: ({ name, grade }), fired by PublishJobUpdate |
| `cis_libs:playerLoaded` | 1.0.0 | server to client: (job), fired by PublishPlayerLoaded |
| `cis_libs:server:getData` | 1.0.0 | client to server: no arguments, requests the config payload |
| `cis_libs:server:inventorySync` | 1.0.0 | client to server: no arguments, requests an inventory snapshot |
| `cis_libs:server:syncSnapshot` | 1.0.0 | client to server: no arguments, sent by the client when its sync scripts load. The server forgets what it believed this player held and re-sends everything currently visible, which is how a client restart recovers instead of staying permanently out of sync. |

| `Cis.*` | Realm | Signature | Since | Notes |
|---|---|---|---|---|
| `Cis.callback.await` | both | `(name, ...)` | 1.0.0 |  |
| `Cis.callback.awaitClient` | server | `(src, name, ...)` | 1.0.0 |  |
| `Cis.callback.call` | both | `(name, cb?, ...)` | 1.0.0 |  |
| `Cis.callback.callClient` | server | `(src, name, cb?, ...)` | 1.0.0 |  |
| `Cis.callback.register` | both | `(name, handler)` | 1.0.0 |  |
| `Cis.callback.tryAwait` | both | `(name, ...)` | 1.0.0 |  |
| `Cis.command.add` | server | `(name, options, handler)` | 1.0.0 |  |
| `Cis.command.list` | server | `()` | 1.0.0 |  |
| `Cis.command.remove` | server | `(name)` | 1.0.0 |  |
| `Cis.db.insert` | server | `(sql, params?)` | 1.0.0 |  |
| `Cis.db.query` | server | `(sql, params?)` | 1.0.0 |  |
| `Cis.db.scalar` | server | `(sql, params?)` | 1.0.0 |  |
| `Cis.db.single` | server | `(sql, params?)` | 1.0.0 |  |
| `Cis.db.transaction` | server | `(queries)` | 1.0.0 |  |
| `Cis.db.update` | server | `(sql, params?)` | 1.0.0 |  |
| `Cis.doors.add` | both | `(data)` | 1.0.0 |  |
| `Cis.doors.get` | both | `(id)` | 1.0.0 |  |
| `Cis.doors.setState` | both | `(id, locked)` | 1.0.0 |  |
| `Cis.framework.notify` | both | `()` | 1.0.0 |  |
| `Cis.framework.player` | server | `(src)` | 1.0.0 |  |
| `Cis.hooks.on` | both | `(name, fn, opts?)` | 1.0.0 |  |
| `Cis.hooks.remove` | both | `(id)` | 1.0.0 |  |
| `Cis.hooks.run` | both | `(name, payload?)` | 1.0.0 |  |
| `Cis.inventory.add` | server | `(src, item, amount, metadata?)` | 1.0.0 |  |
| `Cis.inventory.count` | both | `()` | 1.0.0 |  |
| `Cis.inventory.has` | both | `()` | 1.0.0 |  |
| `Cis.inventory.remove` | server | `(src, item, amount)` | 1.0.0 |  |
| `Cis.keybind.add` | client | `(options)` | 1.0.0 |  |
| `Cis.log.debug` | both | `(message)` | 1.0.0 |  |
| `Cis.log.error` | both | `(message)` | 1.0.0 |  |
| `Cis.log.info` | both | `(message)` | 1.0.0 |  |
| `Cis.log.warn` | both | `(message)` | 1.0.0 |  |
| `Cis.moduleInfo` | both | `(name, opts?)` | 1.0.0 |  |
| `Cis.moduleProbe` | both | `()` | 1.0.0 |  |
| `Cis.net.on` | server | `(name, fn, opts?)` | 1.0.0 |  |
| `Cis.player.coords` | client | `()` | 1.0.0 |  |
| `Cis.player.heading` | client | `()` | 1.0.0 |  |
| `Cis.player.near` | client | `(coords, distance?, onEnter?, onExit?, onEnterEvent?, onExitEvent?)` | 1.0.0 |  |
| `Cis.player.on` | client | `(key, cb)` | 1.0.0 |  |
| `Cis.player.ped` | client | `()` | 1.0.0 |  |
| `Cis.player.playerId` | client | `()` | 1.0.0 |  |
| `Cis.player.seat` | client | `()` | 1.0.0 |  |
| `Cis.player.serverId` | client | `()` | 1.0.0 |  |
| `Cis.player.vehicle` | client | `()` | 1.0.0 |  |
| `Cis.player.weapon` | client | `()` | 1.0.0 |  |
| `Cis.points.add` | client | `(data)` | 1.0.0 |  |
| `Cis.points.getClosest` | client | `()` | 1.0.0 |  |
| `Cis.points.remove` | client | `(id)` | 1.0.0 |  |
| `Cis.raycast.camera` | client | `(flags?, ignore?, distance?, timeoutMs?)` | 1.0.0 |  |
| `Cis.raycast.fromCoords` | client | `(origin, target, flags?, ignore?, timeoutMs?)` | 1.0.0 |  |
| `Cis.ready` | both | `(cb?, timeout?)` | 1.0.0 |  |
| `Cis.require` | both | `(name)` | 1.0.0 |  |
| `Cis.requireList` | both | `()` | 1.0.0 |  |
| `Cis.security.report` | server | `(src, reason)` | 1.0.0 |  |
| `Cis.statebag.onEntity` | both | `(key, handler, timeoutMs?)` | 1.0.0 |  |
| `Cis.statebag.onPlayer` | both | `(key, handler, timeoutMs?)` | 1.0.0 |  |
| `Cis.statebag.remove` | both | `(cookie)` | 1.0.0 |  |
| `Cis.streaming.animDict` | client | `(name, timeout?)` | 1.0.0 |  |
| `Cis.streaming.animSet` | client | `(name, timeout?)` | 1.0.0 |  |
| `Cis.streaming.audioBank` | client | `(name, timeout?)` | 1.0.0 |  |
| `Cis.streaming.model` | client | `(model, timeout?)` | 1.0.0 |  |
| `Cis.streaming.ptfx` | client | `(name, timeout?)` | 1.0.0 |  |
| `Cis.streaming.scaleform` | client | `(name, timeout?)` | 1.0.0 |  |
| `Cis.streaming.textureDict` | client | `(name, timeout?)` | 1.0.0 |  |
| `Cis.streaming.weaponAsset` | client | `(hash, timeout?)` | 1.0.0 |  |
| `Cis.sync.clear` | both | `()` | 1.0.0 |  |
| `Cis.sync.entity` | both | `(key)` | 1.0.0 |  |
| `Cis.sync.list` | both | `()` | 1.0.0 |  |
| `Cis.sync.onDespawn` | both | `(fn)` | 1.0.0 |  |
| `Cis.sync.onSpawn` | both | `(fn)` | 1.0.0 |  |
| `Cis.sync.ped` | both | `(data)` | 1.0.0 |  |
| `Cis.sync.prop` | both | `(data)` | 1.0.0 |  |
| `Cis.sync.remove` | both | `(id)` | 1.0.0 |  |
| `Cis.sync.vehicle` | both | `(data)` | 1.0.0 |  |
| `Cis.target.add` | client | `(zoneType, name, coords, size, options?)` | 1.0.0 |  |
| `Cis.target.exists` | client | `(name)` | 1.0.0 |  |
| `Cis.target.remove` | client | `(name, isPed?)` | 1.0.0 |  |
| `Cis.target.update` | client | `(name, options?)` | 1.0.0 |  |
| `Cis.ui.confirm` | client | `(opts)` | 1.0.0 |  |
| `Cis.ui.input` | client | `(opts)` | 1.0.0 |  |
| `Cis.ui.notify` | client | `(message, kind?)` | 1.0.0 |  |
| `Cis.ui.progress` | client | `(opts)` | 1.0.0 |  |
| `Cis.ui.textUI.hide` | client | `()` | 1.0.0 |  |
| `Cis.ui.textUI.isOpen` | client | `()` | 1.0.0 |  |
| `Cis.ui.textUI.show` | client | `(text, opts?)` | 1.0.0 |  |
| `Cis.wait` | both | `(timeout?)` | 1.0.0 |  |
| `Cis.waitFor` | both | `(fn, msg?, timeoutMs?)` | 1.0.0 |  |
| `Cis.zones.box` | client | `(name, center, size, options?)` | 1.0.0 |  |
| `Cis.zones.contains` | client | `(name, point?)` | 1.0.0 |  |
| `Cis.zones.poly` | client | `(name, points, options?)` | 1.0.0 |  |
| `Cis.zones.remove` | client | `(name)` | 1.0.0 |  |
| `Cis.zones.server.box` | server | `(center, size, opts?)` | 1.0.0 |  |
| `Cis.zones.server.contains` | server | `(id, coords)` | 1.0.0 |  |
| `Cis.zones.server.players` | server | `(id)` | 1.0.0 |  |
| `Cis.zones.server.poly` | server | `(points, opts?)` | 1.0.0 |  |
| `Cis.zones.server.remove` | server | `(id)` | 1.0.0 |  |
| `Cis.zones.server.sphere` | server | `(center, radius, opts?)` | 1.0.0 |  |
| `Cis.zones.sphere` | client | `(name, center, radius?, options?)` | 1.0.0 |  |


<!-- generated:end -->

---

## 7. Net events this library owns

The generated event table is in §6. Doorlock names belong to `cis_keys`.
Framework event names belong to `cis_core`. `jobUpdated` and `playerLoaded` are
fired here when a product calls `PublishJobUpdate` / `PublishPlayerLoaded`.
`DoorData` was removed from the `getData` payload in 2.0.0.

---

## 8. Known defects, pinned not fixed

| Defect | Where | Why it is not fixed |
|---|---|---|
| `Cis.callback.await` returns at most 6 values across the wire | `server/callback.lua` | Widening it is a wire change. |
| Sync has no hysteresis | `server/sync.lua` | One radius for enter and leave. A second radius is a behaviour change. |
| No NUI ships here | `ui` slot | `progress` / `confirm` / `input` need a ui provider. notify and textUI fall back to native GTA. |

Client `Cis.framework.notify(message, kind)` sends the **message** in the
message slot. Pinned in `test/contracts.lua`. Do not “fix” the kind into that
slot.

---

## 9. Troubleshooting

| Symptom | First check |
|---|---|
| `nil index: 'exports'` | `ensure cis_libs` first, and `dependency 'cis_libs'` on the consumer |
| Every `Cis.*` call returns nil / `false, reason` | `cis_debug`. Look for `no provider installed` or empty `AuthorizedResources` |
| `SyncCreate` answers nil with no reason | Empty allow-list (restrictive). Add the resource, or see who `SetConfig` |
| Zones never fire | Handler was a function. Use `onEnterEvent` |
| A zone is at the wrong coordinates | Bracket-form export call — argument 1 was the exports table |
| `GetDiagnostics().memoryKb` climbs for 30 minutes then drops | You collected in the **caller** VM. Pass `{ collect = true }` |

---

## 10. Requirements and layout

- OneSync on. `/onesync` in the manifest.
- Server build 4500+. `/server:4500` in the manifest.
- `init.lua` is the only consumer include.

```
fxmanifest.lua
init.lua            the only file a consumer shared_scripts
api.lua             contract. not loaded at runtime
shared/             registry, defaults, detect, grid, algo/, util/
client/  server/
types/              generated LuaLS stub
test/live/          live harness. not run by npm test
```

```
npm test
npm run test:all
```

Live harness: `test/LIVE.md`. Counts are not repeated here.

---

## Limitations

- No NUI page. `Cis.ui.progress`, `confirm`, and `input` need a ui provider.
- Empty `Security.AuthorizedResources` refuses mutating exports.
- A Lua function cannot be a zone, point, hook, or callback handler that
  crosses the exports boundary.
- Networked entities are created and deleted on the server.
- This resource writes no files. Logs are console, the in-memory audit ring,
  and an optional discord capability.
- Live numbers (assertion counts, soak heap) belong in dated result JSON, not
  in this prose.
- A refusal whose first return is `nil` loses its reason at the exports
  boundary. Mutating APIs that can refuse should return `false, reason`.
  `SyncCreate` still returns bare `nil` on several refusals.

---

## Licence

MIT. See `LICENSE.md`.

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> ·
**Discord:** <https://discord.gg/cisoko> ·
**Issues:** <https://github.com/SpecialStos/cis_libs/issues>

# Migrating from ox_lib

This maps the ox_lib calls a script most often makes to the cis_libs entry that
does the same job. Every cis_libs name below is an `api.lua` entry; the exact
parameters and return values are in the generated tables of
[DOCUMENTATION.md](../DOCUMENTATION.md). Where `api.lua` has no entry, the row
says **no equivalent**, and this guide does not suggest a workaround.

cis_libs is not a drop-in `lib`. There is no global `lib` table. Load the
library with `@cis_libs/init.lua` and call `Cis.*` (or the exports). A mapped
call can differ in argument order, return values or what runs in your resource,
so read the entry before swapping it.

## Where the shape differs

- **Return values.** Many cis_libs calls return `ok, reason` (`false` plus a
  reason on a refusal) instead of raising. ox_lib often raises or returns
  nothing. Check the first return.
- **Dialogs return, they do not take a callback.** `Cis.ui.confirm` and
  `Cis.ui.input` yield and return; `Cis.ui.progress` yields until done.
- **Zones are named, not objects.** `Cis.zones.box(name, center, size, options?)`
  registers a zone under `name`; you remove it with `Cis.zones.remove(name)`.
  ox_lib returns a zone object.
- **A handler that crosses a resource boundary** is a callable reference or a
  `'resource:Export'` string. A function cannot be sent to another resource.

## Calls

| ox_lib | cis_libs | Notes |
|---|---|---|
| `lib.callback.register(name, fn)` | `Cis.callback.register(name, handler, opts?)` | Returns `true`, or `false` plus a reason. Rebound when cis_libs restarts. |
| `lib.callback.await(name, delay, ...)` | `Cis.callback.await(name, ...)` | No `delay` argument. `Cis.callback.tryAwait` returns `ok, ...` instead of raising. |
| `lib.callback(name, delay, cb, ...)` | `Cis.callback.call(name, cb?, ...)` | |
| `lib.callback.await(name, playerId, ...)` (server to client) | `Cis.callback.awaitClient(src, name, ...)` | Server only. `Cis.callback.callClient` takes a callback. |
| client call with a time limit | `Cis.callback.awaitWithin(name, timeoutMs, ...)` | Client only. `tryAwaitWithin` returns `ok, ...`. |
| `lib.notify(data)` | `Cis.ui.notify(message, kind?)` | Client. The server-to-player form is the `NotifyPlayer` export. |
| `lib.showTextUI(text, opts)` | `Cis.ui.textUI.show(text, opts?)` | `Cis.ui.textUI.hide()`, `Cis.ui.textUI.isOpen()`. |
| `lib.hideTextUI()` | `Cis.ui.textUI.hide()` | |
| `lib.progressBar(data)` / `lib.progressCircle(data)` | `Cis.ui.progress(opts)` | `type = 'circle'` selects the circle. `Cis.ui.cancelProgress()` and `Cis.ui.progressActive()` exist. |
| `lib.skillCheck(difficulty, inputs)` | `Cis.ui.skillCheck(difficulty, inputs?)` | `Cis.ui.cancelSkillCheck()`, `Cis.ui.skillCheckActive()`. |
| `lib.alertDialog(data)` | `Cis.ui.confirm(opts)` | Options are `header`, `content`, `cancel`, `labels`. `Cis.ui.closeAlert()` closes it. |
| `lib.inputDialog(heading, rows, options)` | `Cis.ui.input(opts)` | Options are `heading`, `rows`, `options`. `Cis.ui.closeInput()` closes it. |
| `lib.registerContext(data)` | `Cis.ui.context.register(context)` | Then `Cis.ui.context.show(id)`, `Cis.ui.context.hide(onExit?)`, `Cis.ui.context.getOpen()`. |
| `lib.showContext(id)` | `Cis.ui.context.show(id)` | |
| `lib.registerMenu(data, cb)` | `Cis.ui.menu.register(data, cb?)` | Then `Cis.ui.menu.show(id, startIndex?)`, `hide`, `setOptions(id, options, index?)`, `getOpen`. |
| `lib.addRadialItem(items)` | `Cis.ui.radial.add(data)` | Also `register`, `remove(id)`, `clear()`, `hide()`, `disable(state)`. |
| `lib.zones.box / sphere / poly` | `Cis.zones.box / sphere / poly` | Named zones, see above. `Cis.zones.contains(name, point?)`, `getAll()`, `getCurrent()`, `getNearby(coords?, radius?)`. |
| (no ox_lib equivalent) server-side zones | `Cis.zones.server.box / sphere / poly / remove / contains / players` | Server only. |
| `lib.points.new(data)` | `Cis.points.add(data)` | Returns an id. `Cis.points.remove(id)`, `getClosest()`, `getAll()`, `getNearby()`. |
| `lib.addKeybind(data)` | `Cis.keybind.add(options)` | `onPress` / `onRelease`, or ox_lib's `onPressed` / `onReleased`. Handle has `disable`, `isPressed`, `reset`, `destroy`, `getCurrentKey`. |
| `lib.addCommand(name, props, cb)` | `Cis.command.add(name, options, handler)` | Server only. The handler is called `(src, args, raw)`. A consumer resource cannot pass a function across the boundary; see the entry. `Cis.command.remove`, `Cis.command.list`. |
| `cache.ped`, `cache.vehicle`, `cache.seat`, `cache.weapon`, `cache.playerId`, `cache.serverId` | `Cis.cache(key)` or `Cis.player.ped()` / `vehicle()` / `seat()` / `weapon()` / `playerId()` / `serverId()` | Keys: aiming, armed, heading, ped, playerId, seat, serverId, shooting, vehicle, weapon. |
| `lib.onCache(key, cb)` | `Cis.onCache(key, fn)` | Also `Cis.player.on(key, cb)`. |
| `lib.getClosestPlayer / Ped / Vehicle / Object` | `Cis.world.getClosestPlayer / Ped / Vehicle / Object(coords?, maxDistance?, filter?, opts?)` | `getClosestPlayerId` returns the player id. |
| `lib.getNearbyPlayers / Peds / Vehicles / Objects` | `Cis.world.getNearbyPlayers / Peds / Vehicles / Objects(coords?, maxDistance?, filter?, opts?)` | Return `false` plus a reason on a refusal. |
| `lib.raycast.cam(flags, ignore, distance)` | `Cis.raycast.camera(flags?, ignore?, distance?, timeoutMs?)` | `Cis.raycast.fromCoords(origin, target, ...)`. |
| `lib.requestModel(model, timeout)` | `Cis.streaming.model(model, timeout?)` | Also `animDict`, `animSet`, `ptfx`, `textureDict`, `weaponAsset`, `audioBank`, `scaleform`; `Cis.streaming.release(kind, asset)`. |
| `lib.requestAnimDict`, `lib.requestAnimSet`, `lib.requestNamedPtfxAsset`, `lib.requestStreamedTextureDict`, `lib.requestWeaponAsset`, `lib.requestScriptAudioBank`, `lib.requestScaleformMovie` | `Cis.streaming.animDict`, `animSet`, `ptfx`, `textureDict`, `weaponAsset`, `audioBank`, `scaleform` | Each takes `(name, timeout?)`. |
| `lib.getVehicleProperties(vehicle)` | `Cis.vehicle.getProperties(vehicle)` | |
| `lib.setVehicleProperties(vehicle, props)` | `Cis.vehicle.setProperties(vehicle, props, fixVehicle?)` | |
| `lib.waitFor(cb, msg, timeout)` | `Cis.waitFor(fn, msg?, timeoutMs?)` | |
| `lib.print.info / warn / error / debug` | `Cis.log.info / warn / error / debug(message)` | |
| `lib.require` | **no equivalent** | `Cis.require(name)` loads one of cis_libs's named utility modules, not a file by path. `Cis.requireList()` lists them. |
| `lib.table`, `lib.string`, `lib.math`, `lib.array`, `lib.class`, `lib.cron`, `lib.locale`, `lib.timer` and other modules | `Cis.require('table')`, `'string'`, `'mathx'`, `'array'`, `'class'`, `'cron'`, `'locale'`, `'timer'`, ... | The modules exist, but their function lists are cis_libs's own. Do not assume the same function names. See DOCUMENTATION.md section on `Cis.require`. |
| `lib.versionCheck` | **no equivalent** | |
| `lib.checkDependency` | **no equivalent** | `Cis.require('semver')` compares versions; you write the check. |
| `lib.getFilesInDirectory` | **no equivalent** | |
| `lib.load`, `lib.loadJson` | **no equivalent** | |
| `lib.hasLoadedSharedScripts` | **no equivalent** | `Cis.ready(cb?, timeout?)` waits for cis_libs itself. |

## Order of work

1. Replace `shared_script '@ox_lib/init.lua'` with `shared_script '@cis_libs/init.lua'`
   and add `cis_libs` to `dependencies`.
2. Swap calls by the table. Run the resource and watch for a `false, reason`
   return where ox_lib would have raised.
3. Anything marked **no equivalent** stays on ox_lib (keep it as a dependency)
   or is rewritten by you.

The framework, inventory, target, doors and database helpers that older
cis_libs releases carried are deprecated here and live in `cis_bridge`; they are
not an ox_lib replacement either.

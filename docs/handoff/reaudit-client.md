<!-- Independent read-only re-audit, 2026-10-22, of branch claude/vigilant-hamilton-3b0fva at or just before e0561a2. Line numbers may drift slightly. NOT YET ACTED ON. Scratch harness paths it mentions were in the cloud session and are gone. -->

## Client audit of cis_libs (branch claude/vigilant-hamilton-3b0fva), read-only

**Overall grade: B-.** The engine design is strong: one source runs per VM, passes allocate nothing, native usage is careful and the suite is broad. What holds it back is three local-event forgery holes, two get/set or registration bugs that lose data silently, and gaps against ox_lib in the surface consumers actually use.

**How I checked.** `npm test` passes (10 suites, 3050 assertions). Every PascalCase call in scope was resolved against `tools/natives/natives_{gta,cfx}.json`. All names resolve; the only arity or argument problems are listed under Correctness. Behavioural claims marked **[verified]** were reproduced under lua5.4 with the scratch scripts in `/tmp/claude-0/audit/` (`probe.lua`, `mirror.lua`, `require_race.lua`, `double_load.lua`, `natives.js`).

### 1. Security (malicious co-resident client resource)
1. **High: client callback net events accept local forgeries.** `client/callback.lua:15` (`cis_libs:cb`) and `:53` (`cis_libs:cb:res`) have no `source ~= ''` check. Pending keys are sequential integers (`shared/pending.lua:13-14`).
   - Scenario: `for k=1,500 do TriggerEvent('cis_libs:cb:res', k, true, fakeData) end` resolves every in-flight `Cis.callback.await` of every consumer with attacker data.
   - Forging `cis_libs:cb` runs any consumer's client callback with attacker arguments. The reply then goes to the server under an attacker-chosen key.
   - The repo already has the fix pattern: `fromServer()` in `client/initialize.lua:73-76`.
2. **High: `cis_libs:client:syncBatch` accepts local forgeries** (`client/sync.lua:437`). A forged batch can spawn arbitrary local entities and delete synced ones.
   - Scenario: `TriggerEvent('cis_libs:client:syncBatch', 1e12, nil, {'shop_ped'})` deletes the ped. It also sets `touched['shop_ped']=1e12` (`sync.lua:382-392`), so `touch()` refuses every later legitimate upsert for that key for the rest of the session.
3. **Medium-high: forged `onResourceStop`.** None of the 15 handlers check that the named resource is really stopping (no `GetResourceState(res)=='stopping'` test anywhere). Calling `TriggerEvent('onResourceStop','victim')`:
   - releases the victim's zones (`client/zones.lua:112`), points (`points.lua:75`), keybinds, which are retired for the session (`keybind.lua:101`), targets (`target.lua:152`), client callbacks (`callback.lua:129`), cache listeners and near watchers (`cache.lua:588`) and statebag watchers (`shared/statebag.lua:254`);
   - frees capability slots (`proxy.lua:46`);
   - destroys the consumer's DUIs and scaleforms (`init.lua:316`).
   - `TriggerEvent('onResourceStop','cis_libs')` despawns every client-local synced entity while cis_libs keeps running (`sync.lua:582-584`).
4. **Medium: capability slots can be squatted or hijacked.** `RegisterCapability` is first-come with no allow-list (`shared/registry.lua:258-264`). Combined with item 3 (evict the real provider, then register), an attacker can own the `ui`, `target` or `framework` slots and intercept or forge `Cis.ui.input` and `Cis.ui.confirm` results for every consumer.
5. **Medium: client callback names can be hijacked.** `RegisterCallback` overwrites `handlers[name]` (`callback.lua:123`) or `remotes[name]` (`callback.lua:114`) with no foreign-owner refusal, and `CisOwned.track` silently moves ownership. Zones, targets and keybinds all refuse this.
6. **Low-medium: `RemoveNearWatcher` has no owner check** (`cache.lua:454-468`, `:579`). Ids are sequential, so `for i=1,1e3 do exports.cis_libs:RemoveNearWatcher(i) end` removes everyone's watchers. `CisCache.off` does check the owner (`cache.lua:440-443`).

The cache mirror's forged-push guard holds **[verified]**: `mirror.lua:61-63` refuses a push from any other resource. I found no loader or sandbox escape in `init.lua`: path traversal, `..`, backslash and bytecode are all refused.

### 2. Correctness
1. **Medium: vehicle windows are not symmetric between get and set.** The getter records every window where `IsVehicleWindowIntact` is false (`core/vehicle.lua:97-101`), and set calls `RemoveVehicleWindow` on each (`:294-298`). ox_lib calls `RollUpWindow` before this check because a rolled-down window reads as not intact; it was deliberately dropped here, and `test/client.lua:580` enforces that. A car saved with a window down would come back with that window removed. The game behaviour is the precedent's, not something I reproduced in-game.
2. **Medium: a point can be "added" but never fire.** `Points:add` ignores the `Grid.insert` refusal (`core/points.lua:206`) and still returns an id. A large radius (about 1,780 m or more) or NaN coords means `onEnter` never fires, while `getClosest` still returns the point **[verified]**. `Zones:register` does check the result.
3. **Medium: re-creating a zone with bad geometry destroys the live one.** The old zone is removed at `core/zones.lua:179-181`, before the poly is validated at `:212-222`. Re-creating `'shop'` with an empty point list returns false and the original is gone **[verified]**. Separately, a string `insideInterval` raises at `:205` **[verified]**.
4. **Medium: the mirror stays stale while cis_libs is stopped.** `onResourceStop` sets `snapped=false` but keeps `values` (`mirror.lua:80-85`), and `get` returns them (`:158-163`). `Cis.player.vehicle()` keeps answering the old handle **[verified]**.
5. **Medium: consumer state kept inside cis_libs is lost on a cis_libs restart, with no re-registration.** This covers `Cis.callback.register` (`init.lua:1159`), `Cis.target.*` (`:594`), `Cis.sync.onSpawn/onDespawn` (`:1277-1285`), `Cis.statebag.*` (`:480-486`) and `Cis.player.near` (`:420`). Zones, points and keybinds survive by design; these do not, and nothing signals the consumer.
6. **Low-medium: cached weapon attachments go stale.** With the same weapon hash, `refreshWeapon` only re-reads ammo (`cache.lua:251-266`). A suppressor added while the weapon is held is invisible until the player switches weapons.
7. **Low-medium: DUI texture names are reused after a consumer restart.** `cis_dui_<res>_<n>` restarts at 1 (`core/dui.lua:53-58`), but runtime texture dictionaries are never freed. The file's own comment says names are never reused, and they are. This likely shows the destroyed browser's texture; ox_lib adds `GetGameTimer`/random to avoid it.
8. **Low: including init.lua twice creates a second engine set.** There is no load guard (`init.lua:265`). The first copy's zones are orphaned, cannot be removed, and keep firing on their own thread **[verified]**.
9. **Low: `Cis.require` reports a false cycle under concurrency.** Two threads requiring a module whose body yields get "circular dependency X -> X" from the shared guard (`init.lua:1349-1365`) **[verified]**.
10. **Low: `onExit` receives a different coords type on removal.** A remove-triggered exit gets a plain table, while the normal path gets the coords object (`core/zones.lua:403-406`, `core/points.lua:237-240`) **[verified]**. Vector math on it in a handler raises.
11. **Low: fractional timeouts crash.** `%d` with a fractional timeout raises in Lua 5.4 (`core/streaming.lua:153,184`, `core/raycast.lua:59`) **[verified]**. This is the same class already fixed in `waitFor`.
12. **Low: native argument issues.**
    - `RequestWeaponAsset(hash,0,0)` (`core/streaming.lua:53`); the native docs and ox_lib use 31 for p1.
    - `HaveAllStreamingRequestsCompleted()` is called without its `Ped` argument (`client/streaming.lua:27`).
    - The global `Round` (`client/utils.lua:58`) shadows the ROUND native, contrary to the file's "no native is rebound" claim.
13. **Low: smaller issues.**
    - Keybind cross-resource name refusal only works within one VM; consumer instances don't see each other (`core/keybind.lua:179-188`).
    - In cis_libs' VM, `Cis.player.coords()` uses `CisCache.ped`, which can be up to 250 ms stale after a model swap. Coords then read (0,0,0), causing spurious exit/enter on the export-path zones, points and near watchers (`init.lua:184`).
    - A world filter returning a truthy non-`true` value rejects the entity (`core/world.lua:64`).
    - Latent: `queryPoint` raises on an item with a nil `minZ` (`shared/grid.lua:151`); no current caller hits it.

### 3. Per-frame cost
- **Medium: the heading push fans out to every resource.** `setField('heading')` (`cache.lua:200`) calls `TriggerEvent` on every change, 4-10 times a second while moving. That call is dispatched to every client resource's runtime. Consumers read heading through the native anyway (`init.lua:213`), so the push only serves `onCache('heading')`.
- **Low-medium:** `StartExpensiveSynchronousShapeTestLosProbe` (`core/raycast.lua:79`, `client/vehicle.lua:64`) blocks the game thread; the native docs say to use the async probe.
- **Low: idle loops kept for the legacy export path.** In cis_libs' VM, zones (`client/zones.lua:88,102`, the inside pass every 250 ms with zero zones), points (`points.lua:65`) and near watchers (`cache.lua:344`) always run, about 9 idle wake-ups a second. `CisLoopGuard.Body` allocates a `table.pack` per tick (`shared/loopguard.lua:44`).
- **Low:** world queries allocate one table per pool entry plus a redundant `DoesEntityExist` call each (`core/world.lua:94,104,113`).
- **Cross-VM hot paths still in the consumer surface:** `Cis.statebag.*`, one funcref call per bag change; `Cis.player.near`; `Cis.ui.*`; `Cis.inventory.*`; `Cis.callback.*`.
- **Clean:** zone and point passes, markers and controls allocate nothing per pass, and threads exist only while their records exist.

### 4. Gaps versus ox_lib's client
- `Cis.ui` wraps 7 of the 33 interface exports. Context menu, menu, radial, skillCheck, progress cancel/active and close-alert have no `Cis.*` wrapper (`init.lua:450-477`).
- **Zones:**
  - no zone object or handle;
  - no getCurrent/Nearby/AllZones (`insideNames` exists at `core/zones.lua:563` but isn't exposed);
  - no poly `thickness`, so a ported zone spans z -1000 to 10000 (`:215`).
- **Points:** no getAll or getNearby; handlers get coords rather than the point.
- **Keybinds:** no secondaryKey/secondaryMapper, `getCurrentKey` or `disabled` option.
- **World:** `getClosestPlayer` returns (ped, coords, index), not ox_lib's (id, ped, coords), and there is no default maxDistance.
- **Callbacks:** no per-call timeout or delay.
- No setClipboard, getRelativeCoords or grid exposure, and scaleform methods can't return values.

### What keeps it from an A
1. Add the `source ~= ''` check to `cis_libs:cb`, `cis_libs:cb:res` and `cis_libs:client:syncBatch`.
2. Ignore forged `onResourceStop` (check the resource's state is `stopping`) in all 15 handlers.
3. Close capability-slot squatting and eviction, client callback name hijack, and the missing `RemoveNearWatcher` owner check.
4. Fix the vehicle window get/set asymmetry.
5. Make `Points:add` refuse when `Grid.insert` fails; validate zone geometry before removing the old zone; type-check `insideInterval`.
6. Clear mirror values when cis_libs stops; give consumers a re-register path, or local engines, for callbacks, targets, sync hooks, statebag watchers and near watchers across a cis_libs restart.
7. Refresh weapon attachments on the same hash; make DUI texture names unique per load.
8. Add a load guard to init.lua; key the require cycle guard per coroutine.
9. Stop pushing heading on every change; start the legacy export-path loops on demand; use the async LOS probe.
10. Fix the native arguments: weapon-asset flag 31, the ped for `HaveAllStreamingRequestsCompleted`, remove the `Round` shadow, `%s` instead of `%d` for timeouts.
11. Close the ox_lib gaps in the consumer surface: UI wrappers, zone/point queries, keybind secondary keys, world return-order compatibility.

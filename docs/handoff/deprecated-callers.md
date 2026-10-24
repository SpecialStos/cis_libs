<!-- Written 2026-10-24 for the cis_core session that moves cis_core off the deprecated cis_libs slots (docs/V1.md D17). Read-only search, spot-checked against cis_core origin/main. Line numbers are at the commits named below. -->

# cis_libs 1.1.0 deprecated API: call sites in cis_core and cis_bridge

Searched:
- `cis_core` HEAD `929438d` ("The docs claimed the framework bridge was untested. It was not."). `git fetch` done; `origin/main` is the same commit `929438d`, so the working tree and origin/main are identical. Searched with `git grep ... origin/main`.
- `cis_bridge` HEAD `b379bc4` ("docs: owner test page and morning progress for v1"), branch `bridge-v1`, clean worktree. Searched with `git grep ... HEAD`.

Facade in use: both repos call cis_libs ONLY through `exports['cis_libs']:X(...)` (colon form). Neither loads `@cis_libs/init.lua` (so no `Cis.*` calls), and neither uses `exports.cis_libs.X`. `cis_libs/init.lua` has no `RegisterCapability` / `GetCapability` text; the registry calls are raw exports (cis_libs/api.lua:1092 `RegisterCapability`, :1113 `UnregisterCapability`, :1123 `WaitCapability`).

Not deprecated (so not listed as findings): `GetCapabilities`, `SetConfig`, `WaitReady`, `PublishJobUpdate`, `SetDropPlayerHandler`, `Notify`. The generic registry stays in v1 (docs/V1.md § 2.1).

## A. cis_core@929438d, production code (calls into cis_libs)

| repo@commit | path:line | realm | deprecated API | exact code line | replacement |
|---|---|---|---|---|---|
| cis_core@929438d | client/inventory.lua:28 | client | event `cis_libs:client:inventory` (listener) | `RegisterNetEvent('cis_libs:client:inventory', function(items)` | cis_bridge inventory API. NOTE: cis_bridge has no client inventory export at b379bc4 (client exports are only GetPlayerData, IsLoaded, Notify, AddTargetZone, AddTargetEntity, RemoveTarget). cis_core's client inventory count has no bridge replacement yet. |
| cis_core@929438d | client/inventory.lua:36 | client | `RequestInventorySync` | `exports['cis_libs']:RequestInventorySync()` | cis_bridge inventory API (same gap as above) |
| cis_core@929438d | client/inventory.lua:92 | client | `InventoryCount` | `return exports['cis_libs']:InventoryCount(item) >= (amount or 1)` | cis_bridge inventory API (same gap) |
| cis_core@929438d | client/inventory.lua:113 | client | slot `inventory` (RegisterCapability) | `exports['cis_libs']:RegisterCapability('inventory', 'cis_core:CisCoreInventoryClient')` | cis_bridge inventory API; drop the registration (cis_bridge's own adapter reads cis_core) |
| cis_core@929438d | framework/framework_client.lua:53 | client | `DetectFramework` | `local choice = exports['cis_libs']:DetectFramework(framework.Type, framework.Custom)` | cis_bridge detection |
| cis_core@929438d | framework/framework_client.lua:317 | client | `InventoryHas` | `return exports['cis_libs']:InventoryHas(item, amount or 1)` | cis_bridge inventory API (client gap) |
| cis_core@929438d | framework/framework_client.lua:413 | client | slot `framework` (RegisterCapability) | `exports['cis_libs']:RegisterCapability('framework', 'cis_core:CisCoreFramework')` | cis_bridge player API (bridge reads cis_core through adapters/framework/cis_core.lua); drop the registration |
| cis_core@929438d | framework/framework_server.lua:166 | server | `DetectFramework` | `local choice = exports['cis_libs']:DetectFramework(` | cis_bridge detection |
| cis_core@929438d | framework/framework_server.lua:582 | server | `InventoryAdd` | `return exports['cis_libs']:InventoryAdd(serverId, item, amount)` | cis_bridge `AddItem` |
| cis_core@929438d | framework/framework_server.lua:586 | server | `InventoryRemove` | `return exports['cis_libs']:InventoryRemove(source, item, amount)` | cis_bridge `RemoveItem` |
| cis_core@929438d | framework/framework_server.lua:590 | server | `InventoryHas` | `return exports['cis_libs']:InventoryHas(source, item, 1)` | cis_bridge `GetItemCount` (compare >= 1) |
| cis_core@929438d | framework/framework_server.lua:635 | server | `InventoryAdd` | `return exports['cis_libs']:InventoryAdd(serverId, 'markedbills', 1, { worth = amount })` | cis_bridge `AddItem` |
| cis_core@929438d | framework/framework_server.lua:655 | server | `InventoryAdd` | `return exports['cis_libs']:InventoryAdd(serverId, 'markedbills', 1, { worth = amount })` | cis_bridge `AddItem` |
| cis_core@929438d | framework/framework_server.lua:676 | server | `InventoryRemove` | `return exports['cis_libs']:InventoryRemove(serverId, 'markedbills', 1)` | cis_bridge `RemoveItem` |
| cis_core@929438d | framework/framework_server.lua:689 | server | `InventoryRemove` | `return exports['cis_libs']:InventoryRemove(serverId, 'markedbills', 1)` | cis_bridge `RemoveItem` |
| cis_core@929438d | framework/framework_server.lua:1016 | server | slot `framework` (RegisterCapability) | `exports['cis_libs']:RegisterCapability('framework', 'cis_core:CisCoreFramework')` | cis_bridge player API; drop the registration |
| cis_core@929438d | framework/framework_server.lua:1064 | server | `PublishInventory` (QBCore:Server:PlayerLoaded handler) | `exports['cis_libs']:PublishInventory(src)` | cis_bridge inventory API (no publish needed) |
| cis_core@929438d | framework/framework_server.lua:1075 | server | `PublishInventory` (esx:playerLoaded handler) | `exports['cis_libs']:PublishInventory(src)` | cis_bridge inventory API |
| cis_core@929438d | server/inventory.lua:124 | server | `PublishInventory` | `exports['cis_libs']:PublishInventory(src)` | cis_bridge inventory API |
| cis_core@929438d | server/initialize.lua:73 | server | slot `inventory` (RegisterCapability) | `exports['cis_libs']:RegisterCapability('inventory', 'cis_core:CisCoreInventory')` | cis_bridge inventory API; drop the registration |
| cis_core@929438d | server/migrations.lua:59 | server | `DbQuery` (via `libs()` = `exports['cis_libs']`, defined :41) | `local created = libs():DbQuery(('CREATE TABLE IF NOT EXISTS %s ('` | oxmysql API (`MySQL.query.await`), served by oxmysql or cis_database. Note cis_core's fxmanifest `dependencies` lists only `cis_libs`. |
| cis_core@929438d | server/migrations.lua:66 | server | `DbQuery` | `local rows = libs():DbQuery(('SELECT id FROM %s'):format(LEDGER), {})` | `MySQL.query.await` |
| cis_core@929438d | server/migrations.lua:118 | server | `DbTransaction` | `local txOk, txWhy = libs():DbTransaction(queries)` | `MySQL.transaction.await` |
| cis_core@929438d | server/migrations.lua:127 | server | `DbUpdate` | `local ran = libs():DbUpdate(s.sql, s.values)` | `MySQL.update.await` |
| cis_core@929438d | server/migrations.lua:132 | server | `DbUpdate` | `local recorded = libs():DbUpdate(ledgerSql, { m.id, os.time(), GetGameTimer() - startedAt })` | `MySQL.update.await` |
| cis_core@929438d | server/state.lua:132 | server | `DbQuery` (via `libs()`, defined :52) | `local rows = libs():DbQuery(` | `MySQL.query.await` |
| cis_core@929438d | server/state.lua:198 | server | `DbSingle` | `local existing = libs():DbSingle(` | `MySQL.single.await` |
| cis_core@929438d | server/state.lua:202 | server | `DbUpdate` | `local affected = libs():DbUpdate(` | `MySQL.update.await` |
| cis_core@929438d | server/state.lua:209 | server | `DbInsert` | `local id = libs():DbInsert(` | `MySQL.insert.await` |
| cis_core@929438d | server/state.lua:309 | server | `DbUpdate` | `local affected = libs():DbUpdate(` | `MySQL.update.await` |
| cis_core@929438d | server/state.lua:327 | server | `DbUpdate` | `local affected = libs():DbUpdate(('DELETE FROM %s WHERE owner = ?'):format(TABLE), { ownerName })` | `MySQL.update.await` |
| cis_core@929438d | server/state.lua:418 | server | `DbQuery` | `local rows = libs():DbQuery(` | `MySQL.query.await` |

## B. cis_core@929438d, reads of deprecated slot names through the (kept) `GetCapabilities` snapshot

These do not call a deprecated export, but they read slot names that go away in 2.0.0 (`database`, `target`, `inventory`, `framework`, `doorsClient`). After removal the slots read as empty.

| repo@commit | path:line | realm | deprecated API | exact code line | replacement |
|---|---|---|---|---|---|
| cis_core@929438d | server/initialize.lua:119 | server | slot `target` read | `targetProvider = caps.target and caps.target.owner or nil,` | drop the field or ask cis_bridge (`GetSummary`) |
| cis_core@929438d | server/initialize.lua:120 | server | slot `database` read | `databaseProvider = caps.database and caps.database.owner or nil,` | drop the field; `database` slot goes to nothing |
| cis_core@929438d | server/doctor.lua:128 | server | slot `framework` read | `local owner = caps.framework` | cis_bridge `GetSummary` / `GetBridgeReport` |
| cis_core@929438d | server/doctor.lua:168 | server | slots `database`, `target`, `inventory`, `framework`, `doorsClient` read | `for _, slot in ipairs({ 'database', 'target', 'inventory', 'framework', 'doorsClient', 'discord' }) do` | keep only `discord` (not deprecated); report the rest from cis_bridge |

## C. cis_core@929438d, config keys handed to cis_libs `SetConfig`

`server/initialize.lua:46`: `local ok, why = exports['cis_libs']:SetConfig(Config, Security, DiscordConfig)` sends the whole `Config`, so every `Config.Framework.*` key below reaches cis_libs. All server realm (`configs/master_config.lua` is a server script). Replacement for all: the cis_bridge config.

| repo@commit | path:line | realm | deprecated API | exact code line | replacement |
|---|---|---|---|---|---|
| cis_core@929438d | configs/master_config.lua:135 | server | `Framework.Type` | `Type = "AUTO",` | cis_bridge config |
| cis_core@929438d | configs/master_config.lua:143 | server | `Framework.Inventory` | `Inventory = "ox_inventory",` | cis_bridge config |
| cis_core@929438d | configs/master_config.lua:157-160 | server | `Framework.Target.*` (Enabled :158, Type :159, Debug :160) | `Target = {` | cis_bridge config |
| cis_core@929438d | configs/master_config.lua:164 | server | `Framework.Database.*` | `Database = {` | cis_bridge config (driver choice is detection) |
| cis_core@929438d | configs/master_config.lua:180 | server | `Framework.Database.Type` | `Type = "AUTO",` | cis_bridge config |
| cis_core@929438d | configs/master_config.lua:185 | server | `Framework.Database.Collection` | `Collection = 'cis_migrations',` | cis_bridge config (or cis_core's own migrations config) |
| cis_core@929438d | configs/master_config.lua:190 | server | `Framework.Database.Timeout` | `Timeout = 15000,` | cis_bridge config |

Same keys, other cis_core files (not calls into cis_libs, but they validate or read the keys that go away): `server/validate_config.lua:77-78, 452-474, 506-509` (validation), `server/commands.lua:94-95`, `server/doctor.lua:93-102, 151`, `server/initialize.lua:79-82, 117-118` (log/summary reads), and cis_core writes `Config.Framework.Type` at `framework/framework_server.lua:189, 202, 245, 366, 419` and `framework/framework_client.lua:63, 80, 92, 140, 146, 153`. Decide during the migration whether cis_core keeps `Config.Framework.*` as its own keys (then they must stop being forwarded) or moves them.

## D. cis_core@929438d, metadata and test doubles that name the deprecated API (not live calls; update with the code)

| repo@commit | path:line | realm | deprecated API | exact code line | replacement |
|---|---|---|---|---|---|
| cis_core@929438d | api.lua:220 | n/a (manifest of events) | event `cis_libs:client:inventory` | `['cis_libs:client:inventory'] = {` | remove with the listener |
| cis_core@929438d | test/framework_env.lua:457 | test (server mock) | `DbQuery` | `FrameworkEnv.export('DbQuery', function(sql, params)` | replace mock with an oxmysql `MySQL` fake |
| cis_core@929438d | test/framework_env.lua:491 | test | `DbSingle` | `FrameworkEnv.export('DbSingle', function(sql, params)` | same |
| cis_core@929438d | test/framework_env.lua:514 | test | `DbInsert` | `FrameworkEnv.export('DbInsert', function(sql, params)` | same |
| cis_core@929438d | test/framework_env.lua:525 | test | `DbUpdate` | `FrameworkEnv.export('DbUpdate', function(sql, params)` | same |
| cis_core@929438d | test/framework_env.lua:583 | test | `DbTransaction` | `FrameworkEnv.export('DbTransaction', function(queries)` | same |
| cis_core@929438d | test/framework_env.lua:900 | test | `DetectFramework` | `FrameworkEnv.export('DetectFramework', function(configured, custom)` | model cis_bridge detection |
| cis_core@929438d | test/framework_env.lua:958 | test | `RegisterCapability` | `FrameworkEnv.export('RegisterCapability', function() return true end)` | remove with the registrations |
| cis_core@929438d | test/framework_env.lua:961 | test | `PublishInventory` | `FrameworkEnv.export('PublishInventory', function() return true end)` | remove |
| cis_core@929438d | test/framework_env.lua:972-974 | test | `InventoryAdd`, `InventoryRemove`, `InventoryHas` | `FrameworkEnv.export('InventoryAdd', function(src) return hasPlayer(src) end)` (and :973 Remove, :974 Has) | mock cis_bridge AddItem / RemoveItem / GetItemCount |
| cis_core@929438d | test/framework_env.lua:983-987 | test | `DbQuery`, `DbSingle`, `DbUpdate`, `DbInsert`, `DbTransaction` (stub set) | `FrameworkEnv.export('DbQuery', function() return nil end)` (:984 Single, :985 Update, :986 Insert, :987 Transaction) | oxmysql fake |
| cis_core@929438d | test/scenarios/08_adversarial.lua:44 | test | `PublishInventory` | `Env.export('PublishInventory', function(src)` | remove or move to bridge mock |
| cis_core@929438d | test/scenarios/11_inventory.lua:21,24,27,30 | test | `InventoryAdd`, `InventoryRemove`, `InventoryHas`, `PublishInventory` | `Env.export('InventoryAdd', function(src, item, amount, metadata)` (:24 Remove, :27 Has, :30 Publish) | mock cis_bridge AddItem / RemoveItem / GetItemCount |

Docs that describe the same listener or keys (out of scope for code, listed so they get edited too): CALLBACKS.md:66, DOCUMENTATION.md:266-271, 665-685, MIGRATION.md:199, PLATFORM_NOTES.md:40-213.

## E. cis_bridge@b379bc4

Slot registrations: NONE. No `RegisterCapability`, `UnregisterCapability`, `GetCapability`, `HasCapability` or `WaitCapability` call exists at HEAD outside `test/contract.lua` (a compliance rule list, `SLOT_CALLS` at :162, and a deprecated-name table at :196-238, which only name the APIs). No use of `GetNormalizedPlayer`, `Inventory*`, `PublishInventory`, `CreateTarget` / `UpdateTarget` / `TargetExists` / `TargetAvailable`, door exports, `DetectFramework`, `DetectDatabase`, `GetKnownTargets`, either deprecated event, or any deprecated config key. cis_bridge's own `RemoveTarget` export (api.lua:146, client/v1.lua:198, init.lua:18) is its own function, excluded.

One live user of a deprecated cis_libs export family remains: the `Db*` proxy.

| repo@commit | path:line | realm | deprecated API | exact code line | replacement |
|---|---|---|---|---|---|
| cis_bridge@b379bc4 | server/lib.lua:37 | server | `DbQuery`, `DbSingle`, `DbScalar`, `DbInsert`, `DbUpdate`, `DbTransaction` (names in the engine forwarding list) | `'DbQuery', 'DbSingle', 'DbScalar', 'DbInsert', 'DbUpdate', 'DbTransaction',` | oxmysql API (`MySQL.*.await`); cis_libs docs say "nothing" moves to cis_bridge |
| cis_bridge@b379bc4 | server/lib.lua:40 | server | the actual call: all six `Db*` exports, by name | `return exports['cis_libs'][name](exports['cis_libs'], ...)` | forward to the `MySQL` global of oxmysql / cis_database instead |
| cis_bridge@b379bc4 | shared/lib/shim.lua:356 | server (only reached through server/lib.lua `GetDbProxy`) | `DbQuery` via `engine:` | `function p.query(sql, params) return engine:DbQuery(sql, params) end` | `MySQL.query.await` |
| cis_bridge@b379bc4 | shared/lib/shim.lua:357 | server | `DbSingle` | `function p.single(sql, params) return engine:DbSingle(sql, params) end` | `MySQL.single.await` |
| cis_bridge@b379bc4 | shared/lib/shim.lua:358 | server | `DbScalar` | `function p.scalar(sql, params) return engine:DbScalar(sql, params) end` | `MySQL.scalar.await` |
| cis_bridge@b379bc4 | shared/lib/shim.lua:359 | server | `DbInsert` | `function p.insert(sql, params) return engine:DbInsert(sql, params) end` | `MySQL.insert.await` |
| cis_bridge@b379bc4 | shared/lib/shim.lua:360 | server | `DbUpdate` | `function p.update(sql, params) return engine:DbUpdate(sql, params) end` | `MySQL.update.await` |
| cis_bridge@b379bc4 | shared/lib/shim.lua:403 | server | `DbTransaction` | `return engine:DbTransaction(out)` | `MySQL.transaction.await` |
| cis_bridge@b379bc4 | test/shim.lua:479,483,487,491,495,499 | test (fake engine) | `DbQuery`, `DbSingle`, `DbScalar`, `DbInsert`, `DbUpdate`, `DbTransaction` | `DbQuery = function(_, sql, params)` (and :483 Single, :487 Scalar, :491 Insert, :495 Update, :499 Transaction) | fake `MySQL` |
| cis_bridge@b379bc4 | api.lua:169 | n/a (api manifest text) | `Db*` named in the `GetDbProxy` doc | `use = "The legacy MySQL / oxmysql surface over cis_libs' Db* exports, including the transaction bind-key normalisation"` | reword with the code |

Other cis_libs calls in cis_bridge are NOT deprecated: `CreateZone`, `RemoveZone`, `ZoneContains`, `RegisterCallback`, `TryAwaitCallback`, `CallCallback` (server/lib.lua:33-36).

## Notes for the planner

1. cis_core is the big remaining consumer: 2 slots registered on both realms (`framework`, `inventory`: 4 RegisterCapability lines), 15 Inventory/Publish/Request/Detect export calls (plus 1 event listener), and 12 `Db*` calls (migrations.lua x5, state.lua x7).
2. Gap: cis_core's CLIENT inventory (`InventoryCount`, `InventoryHas`, the `cis_libs:client:inventory` listener and `RequestInventorySync`) has no cis_bridge client replacement at b379bc4.
3. Gap: `Db*` goes to "nothing", so cis_core and cis_bridge must call the oxmysql `MySQL` API directly (cis_core declares only `cis_libs` as a dependency today).
4. `bridge-off-slots` precondition (docs/V1.md § 3 Removal) looks satisfied on the bridge side except for the `Db*` proxy above, which is an export, not a slot.

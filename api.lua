-- cis_libs -- machine-readable API contract.
--
-- Pure data. Loadable with loadfile() without starting the provider, without
-- a FiveM server, and without executing a single line of the library. The
-- specification is API_SPEC.md; the freeze and the exercised/unexercised
-- marking are in COMPATIBILITY.md.
--
-- This file is NOT listed in fxmanifest.lua, on purpose. Adding it as a
-- shared_script would execute it inside cis_libs's own VM and publish a
-- global that no consumer can see anyway, because `shared_script
-- '@cis_libs/init.lua'` COPIES the file into the consumer's VM rather than
-- sharing it (MEMORY.md section 4). Read it on demand:
--
--     local f = assert(loadfile('resources/cis_libs/api.lua'))
--     local api = f()
--
-- `until` is a Lua reserved word, so every occurrence is written ['until'].
--
-- Validated in CI by tools/validate-api.js against what the source actually
-- registers. If the two disagree, CI fails.

return {
    name = 'cis_libs',
    -- The PRODUCT version, which is also what fxmanifest.lua reports and what
    -- server/version.lua compares an operator's update endpoint against. It
    -- must equal the `version` directive in fxmanifest.lua and the one in
    -- package.json; the validator now fails on any disagreement, because the
    -- three drifting apart is how a build ends up telling every customer it is
    -- permanently outdated.
    --
    -- 2.0.0 is the split: the monolith became cis_libs / cis_core /
    -- cis_bridge. The contract major below did NOT move, because no `Cis.*`
    -- name or signature changed -- that was the constraint the split was
    -- designed around, and it is the reason a 1.0 consumer needs no edit.
    version = '2.0.0',
    -- Contract major. Bumped only by a breaking change; see COMPATIBILITY.md
    -- section 3. An older consumer pinned to a prior major gets an explicit
    -- typed refusal, never a silently wrong answer.
    api = 1,
    -- Migration set id. A consumer records the `schema` it was written
    -- against and the platform answers with the one it now needs.
    schema = 0,

    exports = {
        -- ------------------------------------------------------------- doors
        AddDoorToSystem = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Cis.doors.add(doorData)',
            realm = 'both',
            signature = { server = '(newDoorData, internal)', client = '(data)' },
        },
        AddDoorGroup = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; exports["cis_libs"]:AddDoorGroup(groupData)',
            realm = 'both',
            signature = { server = '(groupData)', client = '(data)' },
        },
        GetDoorState = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.doors.get(id)',
            realm = 'both',
            signature = { server = '(doorId)', client = '(doorId)' },
        },
        GetAllDoorData = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the full door and group tables',
            realm = 'server',
            signature = '()',
        },
        LockDoors = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Cis.doors.setState(identifier, true)',
            realm = 'server',
            signature = '(identifier)',
        },
        UnlockDoors = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Cis.doors.setState(identifier, false)',
            realm = 'server',
            signature = '(identifier)',
        },
        BreakDoor = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; exports["cis_libs"]:BreakDoor(identifier)',
            realm = 'server',
            signature = '(identifier)',
        },
        FixDoor = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; exports["cis_libs"]:FixDoor(identifier)',
            realm = 'server',
            signature = '(identifier)',
        },
        RequestLockDoors = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.doors.setState(id, true) on the client',
            realm = 'client',
            signature = '(identifier)',
        },
        RequestUnlockDoors = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.doors.setState(id, false) on the client',
            realm = 'client',
            signature = '(identifier)',
        },
        GetClosestDoor = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; exports["cis_libs"]:GetClosestDoor()',
            realm = 'client',
            signature = '()',
        },

        -- ---------------------------------------------------------- callbacks
        RegisterCallback = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.callback.register(name, handler)',
            realm = 'both',
            signature = { server = '(name, handler)', client = '(name, fn)' },
        },
        CallCallback = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.callback.call(name, cb, ...)',
            realm = 'both',
            signature = { server = '(name, cb, ...)', client = '(name, cb, ...)' },
        },
        AwaitCallback = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.callback.await(name, ...)',
            realm = 'both',
            signature = { server = '(name, ...)', client = '(name, ...)' },
        },
        CallCallbackClient = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.callback.callClient(src, name, cb, ...)',
            realm = 'server',
            signature = '(name, target, cb, ...)',
        },
        AwaitCallbackClient = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.callback.awaitClient(src, name, ...)',
            realm = 'server',
            signature = '(name, target, ...)',
        },
        CreateSafeCallback = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Cis.callback.register(name, handler); this skips the name and handler checks',
            realm = 'server',
            signature = '(name, cb)',
        },
        TriggerLibCallback = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'the client-to-server round trip whose callback receives only the results',
            realm = 'client',
            signature = '(name, cb, ...)',
        },

        -- ----------------------------------------------------------- database
        DbQuery = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.db.query(sql, params)',
            realm = 'server',
            signature = '(sql, params)',
        },
        DbSingle = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.db.single(sql, params)',
            realm = 'server',
            signature = '(sql, params)',
        },
        DbScalar = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.db.scalar(sql, params)',
            realm = 'server',
            signature = '(sql, params)',
        },
        DbInsert = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.db.insert(sql, params)',
            realm = 'server',
            signature = '(sql, params)',
        },
        DbUpdate = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.db.update(sql, params)',
            realm = 'server',
            signature = '(sql, params)',
        },
        DbTransaction = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.db.transaction(queries). oxmysql only; queries are oxmysql array-of-{query, values} entries',
            realm = 'server',
            signature = '(queries)',
        },
        DatabaseExecute = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Cis.db.query(sql, params)',
            realm = 'server',
            signature = '(query, params, cb)',
        },
        DatabaseFetchOne = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Cis.db.single(sql, params)',
            realm = 'server',
            signature = '(query, params, cb)',
        },
        DatabaseFetchAll = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Cis.db.query(sql, params)',
            realm = 'server',
            signature = '(query, params, cb)',
        },
        DatabaseInsert = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Cis.db.insert(sql, params)',
            realm = 'server',
            signature = '(sql, params, cb)',
        },
        DatabaseUpdate = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Cis.db.update(sql, params)',
            realm = 'server',
            signature = '(sql, params, cb)',
        },
        DatabaseDelete = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Cis.db.query(sql, params)',
            realm = 'server',
            signature = '(sql, params, cb)',
        },

        -- ---------------------------------------------------------- inventory
        InventoryCount = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.inventory.count(item) on the client, Cis.inventory.count(src, item) on the server',
            realm = 'both',
            signature = { server = '(src, item)', client = '(item)' },
        },
        InventoryHas = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.inventory.has(...)',
            realm = 'both',
            signature = { server = '(src, item, amount)', client = '(item, amount)' },
        },
        InventoryAdd = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.inventory.add(src, item, amount, metadata)',
            realm = 'server',
            signature = '(src, item, amount, metadata)',
        },
        InventoryRemove = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.inventory.remove(src, item, amount)',
            realm = 'server',
            signature = '(src, item, amount)',
        },

        -- -------------------------------------------------------------- zones
        CreateZone = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.box / Cis.zones.poly / Cis.zones.sphere',
            realm = 'client',
            signature = '(kind, name, a, b, options)',
        },
        RemoveZone = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.remove(name)',
            realm = 'client',
            signature = '(name)',
        },
        ZoneContains = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.contains(name, point)',
            realm = 'client',
            signature = '(name, point)',
        },
        GetPolyzones = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Cis.zones.poly / Cis.zones.remove / Cis.zones.contains',
            realm = 'client',
            signature = '()',
        },
        GetZoneDebug = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the last grid pass cost in milliseconds',
            realm = 'client',
            signature = '()',
        },

        -- ------------------------------------------------------------- target
        CreateTarget = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.target.add(zoneType, name, coords, size, options)',
            realm = 'client',
            signature = '(zoneType, name, coords, size, options)',
        },
        RemoveTarget = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.target.remove(name, isPed)',
            realm = 'client',
            signature = '(name, isPed)',
        },
        UpdateTarget = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.target.update(name, options)',
            realm = 'client',
            signature = '(name, newOptions)',
        },
        TargetExists = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.target.exists(name)',
            realm = 'client',
            signature = '(name)',
        },
        TargetAvailable = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; true when a configured target provider is started',
            realm = 'client',
            signature = '()',
        },

        -- --------------------------------------------------------------- sync
        SyncCreate = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.sync.ped / Cis.sync.prop / Cis.sync.vehicle',
            realm = 'server',
            signature = '(kind, data)',
        },
        SyncRemove = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.sync.remove(id)',
            realm = 'server',
            signature = '(id)',
        },
        GetSyncedEntities = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the id-to-handle table of everything this client spawned',
            realm = 'client',
            signature = '()',
        },

        -- -------------------------------------------------------------- cache
        GetCachedPed = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.ped(), which reads the native directly in a consumer VM',
            realm = 'client',
            signature = '()',
        },
        GetCachedHeading = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.heading(), which reads the native directly in a consumer VM',
            realm = 'client',
            signature = '()',
        },
        GetCachedVehicle = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.vehicle()',
            realm = 'client',
            signature = '()',
        },
        GetCachedWeapon = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.weapon()',
            realm = 'client',
            signature = '()',
        },
        GetCachedServerId = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.serverId()',
            realm = 'client',
            signature = '()',
        },
        OnPlayerCache = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.on(key, cb). The cb cannot cross the boundary; use a net event',
            realm = 'client',
            signature = '(key, cb)',
        },
        WatchNear = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.near(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)',
            realm = 'client',
            signature = '(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)',
        },
        GetGlobals = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Cis.player.* and Cis.sync.*; there is no single replacement',
            realm = 'client',
            signature = '()',
        },

        -- ---------------------------------------------------------- platform
        -- The five exports below are the seam between this library and the
        -- products that plug into it. They are not consumer API -- a consumer
        -- calls `Cis.*` and never these -- but they are stable, they are what
        -- cis_core and cis_bridge call, and they are the reason a consumer's
        -- code does not change when the platform underneath it does.
        SetConfig = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by cis_core at boot with (config, security, discord). First registration wins; a second is refused and named',
            realm = 'server',
            signature = '(config, security, discord)',
        },
        GetDiscordConfig = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The outbound/webhook configuration SetConfig was handed, for the capability that does the sending. Server realm only -- it holds webhook URLs and is deliberately not on the client payload whitelist',
            realm = 'server',
            signature = '()',
        },
        RegisterCapability = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by cis_core, cis_bridge and cis_keys with (slot, "resource:Export"). First registration wins',
            realm = 'both',
            signature = '(slot, provider)',
        },
        UnregisterCapability = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by a product on shutdown or handover. Only the slot owner may release it',
            realm = 'server',
            signature = '(slot)',
        },
        GetCapabilities = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The one call that answers "which of my four resources is actually running". Returns { [slot] = { owner, resolved } }',
            realm = 'both',
            signature = '()',
        },
        GetKnownTargets = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The ordered framework and driver tables detection uses. Shared so a product cannot disagree with the debug output about what is running',
            realm = 'both',
            signature = '()',
        },
        DetectFramework = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Asks the server what framework it is actually running. Returns { name, resource, version, how, reason }',
            realm = 'both',
            signature = '(configured, custom)',
        },
        DetectDatabase = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Asks the server which driver is running. Returns { name, resource, version, how, reason }',
            realm = 'both',
            signature = '(configured)',
        },
        SetDropPlayerHandler = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by whoever ships the config, with "resource:Export". A FUNCTION cannot be sent across the boundary, which is why this exists',
            realm = 'server',
            signature = '(provider)',
        },
        PublishJobUpdate = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by cis_core when a player changes job. Fires cis_libs:jobUpdated, so the event name stays owned by this library',
            realm = 'server',
            signature = '(job, src)',
        },
        PublishPlayerLoaded = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by cis_core when a player object exists. Fires cis_libs:playerLoaded',
            realm = 'server',
            signature = '(job, src)',
        },
        NotifyClient = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by a product to show a notification to one client, without hardcoding the event name owned by this library',
            realm = 'server',
            signature = '(src, message, kind)',
        },
        RequestInventorySync = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.inventory.count is a hint. This asks for a fresh one. Client only',
            realm = 'client',
            signature = '()',
        },
        PublishInventory = {
            since = '2.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by the inventory service. Pushes cis_libs:client:inventory to one player',
            realm = 'server',
            signature = '(src)',
        },

        -- ---------------------------------------------------------- framework
        GetFramework = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Cis.framework.player(src) on the server; Cis.framework.notify on the client. Not an API: it returns a table of callable references',
            realm = 'both',
            signature = '()',
        },
        GetNormalizedPlayer = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.framework.player(src)',
            realm = 'server',
            signature = '(src)',
        },
        Notify = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.framework.notify(...). The two-argument client form sends `kind` in the message slot; this is pinned as a known defect in test/contracts.lua and is a MAJOR change to correct',
            realm = 'both',
            signature = { server = '(src, message, kind)', client = '(message, kind)' },
        },
        GetOnlineJobCount = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the callback cis_libs:getOnlineJobCount',
            realm = 'server',
            signature = '(jobs)',
        },

        -- ----------------------------------------------------------- security
        SecureNetOn = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.net.on(name, fn)',
            realm = 'server',
            signature = '(name, fn)',
        },
        SecurityReport = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.security.report(src, reason)',
            realm = 'server',
            signature = '(src, reason)',
        },
        InvokingAllowed = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; ask before mutating. This is the supported way to avoid a refusal',
            realm = 'server',
            signature = '()',
        },
        RateOk = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; a resource may share the library rate limiter',
            realm = 'server',
            signature = '(src, name, windowMs, maxHits)',
        },
        GetLibsPrefix = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the configured Security.EventPrefix',
            realm = 'server',
            signature = '()',
        },

        -- -------------------------------------------------------- diagnostics
        GetConfigSummary = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the non-secret half of the server config',
            realm = 'server',
            signature = '()',
        },
        GetClientConfig = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the config the server sent to this client',
            realm = 'client',
            signature = '()',
        },
        IsReady = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.isReady, or Cis.ready(cb)',
            realm = 'client',
            signature = '()',
        },
        WaitReady = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.ready(cb, timeout) or Cis.wait(timeout)',
            realm = 'both',
            signature = { server = '(timeout)', client = '(timeout)' },
        },
        GetDiscordQueueDepth = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; queued message count and dropped count',
            realm = 'server',
            signature = '()',
        },
        GetLogging = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.debug / info / warn / error',
            realm = 'server',
            signature = '()',
        },
        GetClientLogging = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.debug / info / warn / error',
            realm = 'client',
            signature = '()',
        },
        SendDiscordLog = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.info with a discordType; no proxy equivalent for a raw webhook push',
            realm = 'server',
            signature = '(webhookURL, title, message, color, ping)',
        },

        -- ----------------------------------------------------------- logging
        LogDebug = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.debug(message)',
            realm = 'both',
            signature = { server = '(message, discordType)', client = '(message)' },
        },
        LogInfo = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.info(message)',
            realm = 'both',
            signature = { server = '(message, discordType)', client = '(message)' },
        },
        LogWarn = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.warn(message)',
            realm = 'both',
            signature = { server = '(message, discordType)', client = '(message)' },
        },
        LogError = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.error(message)',
            realm = 'both',
            signature = { server = '(message, discordType, errorInfo)', client = '(message)' },
        },
        AutoLogError = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.error(message) from inside a pcall',
            realm = 'both',
            signature = { server = '(err, event)', client = '(err, context)' },
        },

        -- --------------------------------------------------------- utilities
        Round = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; math round to n places',
            realm = 'client',
            signature = '(num, numDecimalPlaces)',
        },
        RandomFloat = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent',
            realm = 'client',
            signature = '(lower, greater)',
        },
        GetTableSize = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent',
            realm = 'client',
            signature = '(t)',
        },
        GetDistanceBetweenCoords = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent',
            realm = 'client',
            signature = '(x1, y1, z1, x2, y2, z2)',
        },
        DrawText3D = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent',
            realm = 'client',
            signature = '(x, y, z, text, settings)',
        },
        CreatePed = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; returns 0 on an invalid or unloaded model',
            realm = 'client',
            signature = '(model, coords, heading, options)',
        },
        DebugLog = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.debug(message)',
            realm = 'client',
            signature = '(message)',
        },
        GetClosestVehicle = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; a 5 unit forward ray, then a 5 unit radius search',
            realm = 'client',
            signature = '()',
        },
        GetVehicleProperties = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the full property snapshot used by sync',
            realm = 'client',
            signature = '(vehicle)',
        },
        SetVehicleProperties = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; diffs against the last applied snapshot',
            realm = 'client',
            signature = '(vehicle, props, fixVehicle)',
        },
        GetPlayerVehicleSeat = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.vehicle(), second return value',
            realm = 'client',
            signature = '()',
        },
        GetCurrentWeaponData = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.weapon()',
            realm = 'client',
            signature = '(ped)',
        },
        RequestModelTimeout = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.streaming.model(model, timeout)',
            realm = 'client',
            signature = '(model, timeout)',
        },

        -- ------------------------------------------------------------ version
        CheckResourceVersion = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'Config.CheckVersion and Config.VersionCheckUrl',
            realm = 'server',
            signature = '(resourceName, resourceUrl, currentVersion)',
        },
    },

    -- Every name below is fired or listened for BY THIS RESOURCE. That is the
    -- rule, and it is why the doorlock names and the framework event names are
    -- absent: they belong to the products that own those concerns now
    -- (cis_keys and cis_core respectively). A net event name that moves between
    -- resources is a name a product can rename without anyone noticing until a
    -- consumer silently stops hearing about it.
    --
    -- `cis_libs:jobUpdated` and `cis_libs:playerLoaded` used to be fired by the
    -- framework layer and are now fired HERE, by a product calling
    -- PublishJobUpdate / PublishPlayerLoaded. The name and the payload shape are
    -- unchanged, so a consumer listening for them keeps working across a
    -- framework change -- which is the whole reason they stayed in this file.
    events = {
        ['cis_libs:cb'] = {
            since = '1.0.0',
            payload = 'client to server and server to client: (name, key, ...)',
        },
        ['cis_libs:cb:res'] = {
            since = '1.0.0',
            payload = 'client: (key, ok, ...) resolving an outstanding callback',
        },
        ['cis_libs:cb:serverRes'] = {
            since = '1.0.0',
            payload = 'server: (key, ok, ...) resolving an outstanding client callback',
        },
        ['cis_libs:client:getData'] = {
            since = '1.0.0',
            payload = 'server to client: ({ Config, EventPrefix }) on join. DoorData was removed in 2.0.0',
        },
        ['cis_libs:server:getData'] = {
            since = '1.0.0',
            payload = 'client to server: no arguments, requests the config payload',
        },
        ['cis_libs:client:showNotification'] = {
            since = '1.0.0',
            payload = 'server to client: (message, kind)',
        },
        ['cis_libs:client:inventory'] = {
            since = '1.0.0',
            payload = 'server to client: ({ [itemName] = count }), pushed by PublishInventory',
        },
        ['cis_libs:server:inventorySync'] = {
            since = '1.0.0',
            payload = 'client to server: no arguments, requests an inventory snapshot',
        },
        ['cis_libs:client:syncUpsert'] = {
            since = '1.0.0',
            payload = 'server to client: (record) for a nearby synced entity',
        },
        ['cis_libs:client:syncRemove'] = {
            since = '1.0.0',
            payload = 'server to client: (id) despawn a synced entity',
        },
        ['cis_libs:jobUpdated'] = {
            since = '1.0.0',
            payload = 'server to client: ({ name, grade }), fired by PublishJobUpdate',
        },
        ['cis_libs:playerLoaded'] = {
            since = '1.0.0',
            payload = 'server to client: (job), fired by PublishPlayerLoaded',
        },
    },
}

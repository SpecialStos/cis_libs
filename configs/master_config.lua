-- =============================================================================
--  cis_libs -- master configuration  (SERVER SIDE ONLY)
--
--  Read this file before you change it. Every key below ships with a default
--  that is safe to run on a live server as-is, so a fresh clone can be
--  `ensure`d and will work without an edit. Nothing in this file contains a
--  secret, a licence key, a database name, or the address of anyone's server.
--
--  Two rules that cover everything here:
--
--    * The server reads this file once, at boot. A change needs
--      `restart cis_libs`. Each client fetches its own copy of this config when
--      it initialises, so a player who is already connected keeps the old
--      values until they reconnect.
--
--    * The copy handed to clients is redacted. Webhook URLs, the database
--      block, the authorised-resource list and the kick handler are stripped
--      before the payload leaves the server, so no value in this file is ever
--      readable from a player's machine.
--
--  Keys marked SECURITY below had their default chosen for a reason. Flipping
--  one is a decision with consequences, not a convenience toggle.
-- =============================================================================

Config = {}

-- --------------------------------------------------------------------- SECURITY
-- Outbound "is there a newer version of cis_libs?" check.
--
-- OFF BY DEFAULT, and that is a security decision rather than an oversight.
-- When this was on, every single boot fired an HTTPS GET to a hardcoded host,
-- unconditionally, with no operator opt-in. That is three problems at once:
--
--   * supply chain -- whoever controls the endpoint controls what this library
--     claims its own version is, and can echo arbitrary script content into an
--     operator's console via the changelog field. A commercial product should
--     not phone home.
--   * air-gapped and offline servers -- the request carries no timeout of its
--     own and the boot thread waits on it.
--   * consent -- nobody was asked.
--
-- SAFE DEFAULT: false. Leave it false on a production server.
-- IF YOU SET IT TRUE: an outbound request leaves your machine on every boot. It
-- is a GET; nothing about your server is sent in it.
Config.CheckVersion = false

-- Only read when Config.CheckVersion is true. Leaving it empty or nil while
-- CheckVersion is true is safe: the library warns once and sends nothing rather
-- than guessing a host.
--
-- The default below points at the publisher's own domain (CIsoko), NOT at a
-- third party, and it is unreachable unless you opt in above. It is here so the
-- feature works out of the box for anyone who wants it.
--
-- Want zero contact with the publisher? Either leave Config.CheckVersion
-- false, or replace this with your own mirror:
--
--     Config.VersionCheckUrl = "https://your-domain.example/cis_libs/version.txt"
--
-- The endpoint is not published yet, so an opt-in install gets a failed
-- request and the existing "Version check failed; continuing startup." warning.
-- Nothing else changes.
--
-- Do NOT paste a hostname here "just to test it" on a live server: the response
-- body is printed into your console and its changelog lines are printed as-is.
Config.VersionCheckUrl = "https://api.cisoko.net/v1/cis_libs/version.txt"

-- ------------------------------------------------------------------ CALLBACKS
-- How long, in milliseconds, a callback (server -> client round trip) waits
-- before it gives up and returns nil to the caller.
--
-- SAFE DEFAULT: 10000 (10s). Generous on purpose: it costs nothing while
-- idle, because a callback only starts its clock when one is actually sent.
-- IF YOU LOWER IT: a slow client, a heavy framework, or a database query in
-- flight on the server side can push a real response past the deadline. The
-- caller then gets nil, and a nil that means "too early" is indistinguishable
-- from a nil that means "no such thing". Consumers that retry should be told
-- about this setting first.
-- IF YOU RAISE IT: a genuinely lost callback keeps a pending entry alive
-- longer. That is bounded and small, so raising it is far safer than lowering.
Config.CallbackTimeout = 10000

-- ------------------------------------------------------------------- CADENCE
-- Fallback poll interval, in milliseconds, for the client-side Globals table.
--
-- The cache is primarily event-driven: entering a vehicle, drawing a weapon and
-- joining are all applied the moment they happen, not on a timer. This table is
-- only the safety net for what events miss -- a respawn, a seat change with no
-- game event, a weapon swap the event never reported.
--
-- SAFE DEFAULTS: Player 1000, Weapon 1000, Vehicle 1000.
-- Each tick costs roughly ten natives plus a vector4 allocation per player.
-- Lowering these is a straight trade of idle CPU for fresher data, and the
-- values are clamped to a 100ms floor. On a busy server, 1000 is already
-- aggressive; 2000-3000 is usually indistinguishable in a game and cheaper.
Config.UpdateInterval = {
    Player = 1000,
    Weapon = 1000,

    -- NOT POLLED BY THIS RESOURCE. Read only by a companion resource that syncs
    -- vehicle properties, which does its own timing. Changing it here has no
    -- effect unless such a consumer exists.
    Vehicle = 1000,
    VehicleProperties = 5000,
}

-- --------------------------------------------------------------------- AIMING
-- Which native decides whether the local player is aiming, i.e. whether the
-- "aiming" field in the Globals table is true.
--
--   "default"    -- IsPlayerFreeAiming(). Reads the real game state.
--   "configFlag" -- GetPedConfigFlag(ped, 78). A specific ped flag, which is
--                   not the aiming state on current game builds.
--
-- SAFE DEFAULT: "default". The alternative is kept because some frameworks
-- override player peds in ways that made the original native unreliable, but
-- on a stock ped the config flag is the wrong signal and the Globals table
-- will report aiming as false almost always. Only use it if you have measured
-- the difference on your own server.
Config.AimingCheckType = "default"

-- ----------------------------------------------------------------- FRAMEWORK
-- Which framework this server runs, and which companion resources are present.
--
-- Every value here is a NAME OF A RESOURCE to look for, never a connection
-- string, never a database name. If the named resource is not started when
-- cis_libs boots, the library prints one line and drops to standalone ("NONE")
-- mode rather than erroring; set Type = "NONE" yourself if you want no
-- framework at all.
Config.Framework = {
    -- "ESX", "ESX-LEGACY", "QBCORE", "QBOX", or "NONE".
    -- SAFE DEFAULT: "QBCORE". Wrong pick? No harm done, but the log line
    -- "Framework provider unavailable; using standalone mode" means every
    -- job, permission and money helper below returns its no-framework answer.
    Type = "AUTO",

    -- "ox_inventory", "qb-inventory", "qs-inventory", "codem-inventory", or
    -- "typical".
    -- SAFE DEFAULT: "ox_inventory". Inventory calls are advisory: if the named
    -- resource is not started, counts fall back to the framework's own item
    -- table, which on a stock framework is usually empty. The symptom is
    -- "HasItem always says no", not a crash.
    Inventory = "ox_inventory",

    -- Zone helpers (box / sphere / poly). Used by consumers; this resource
    -- only runs the disabled check.
    -- SAFE DEFAULT: true. Setting false makes every zone export return
    -- false, 'zones disabled by config' instead of creating anything.
    Zones = {
        Enabled = true,
    },

    -- The target provider, for door prompts and any consumer using targets.
    -- SAFE DEFAULTS: Enabled true, Type "ox_target". With Enabled true and no
    -- target resource started, target calls report unavailable and the
    -- doorlock falls back to DrawText3D with a warning, rather than breaking.
    Target = {
        Enabled = true,
        Type = "ox_target", -- "qb-target" / "ox_target"
        Debug = false, -- logs every target create/remove. Off by default: it is
                       -- noisy and prints zone and door identifiers.
    },

    Database = {
        -- "oxmysql", "mysql-async", "ghmattimysql", "mongodb".
        -- This is the NAME OF THE DRIVER RESOURCE to use. Connection details
        -- live in that resource's own config, never here and never in this
        -- repository.
        -- SAFE DEFAULT: "oxmysql". If the named driver is not started, the
        -- library prints "Database driver unavailable: <name>" and every
        -- database call returns nil. Only oxmysql supports transactions;
        -- picking another driver makes Cis.db.transaction refuse by design and
        -- say so at boot.
        Type = "AUTO",

        -- MongoDB only. Collection name for the cis_doors table. Leave nil for
        -- every other driver; it is ignored when they are selected.
        Collection = nil,

        -- Milliseconds before an awaited query gives up and calls back nil.
        -- SAFE DEFAULT: 15000. Raising it only makes a stalled query hang
        -- longer; lowering it makes slow queries look like missing ones.
        Timeout = 15000,
    }
}

-- ------------------------------------------------------------------ DOORLOCK
Config.Doorlock = {
    -- SAFE DEFAULT: true.
    -- IF YOU SET IT FALSE: the client returns out of its doorlock setup before
    -- registering any of its five doorlock net events. Nothing refuses the
    -- call and nothing logs an error -- incoming door updates are simply never
    -- received, and doors opened on one player stay open on everyone else. It
    -- is a silent failure, so leave it on unless you know you want doors
    -- client-local.
    Enabled = true,

    -- How a player is offered a door.
    --   "target"   -- a target-entity prompt; falls back to DrawText3D with a
    --                 warning if no target provider is running.
    --   "DrawText3D"-- always the floating-text method, no target resource
    --                 needed, but it costs a proximity check every frame.
    -- SAFE DEFAULT: "target".
    Type = "target",

    -- How close, in metres, a player must be for the prompt to appear.
    -- SAFE DEFAULT: 2.0. Raising it past a few metres makes doors usable
    -- through walls; lowering it makes them fiddly to reach in a vehicle.
    InteractableDistance = 2.0,

    -- SECURITY-adjacent, and the safe direction is the shipped one.
    -- SAFE DEFAULT: false. Turning this ON creates a `cis_doors` table in your
    -- database on the next boot and stores every door and its state in SQL, so
    -- doors survive a restart and a crash.
    -- Before you turn it on, know that it writes to your database: this is the
    -- only key in this file that creates a table. Nothing in this repository
    -- stores credentials for it; the connection details stay in your own
    -- driver's configuration, which is not part of this resource.
    -- Turning it back OFF does NOT drop the table. It stops using it.
    Persist = false,
}

-- ---------------------------------------------------------------------- SYNC
-- Entity sync: door states and entity state shared between players.
-- SAFE DEFAULT: true. false stops the library both listening for and applying
-- incoming sync records. Mutating doors still works; doors simply stop being
-- consistent between players.
Config.Sync = {
    Enabled = true,
}

-- ------------------------------------------------------------------- LOGGING
Config.Printing = {
    -- Extra diagnostics on top of the normal console output: native failures,
    -- target create/remove, cache and zone internals. Verbose by design, and
    -- some of it is per-zone and per-entity, so it is loud on a busy server.
    -- SAFE DEFAULT: false. Turn it on to diagnose, turn it off afterwards.
    Debug = false,

    -- SECURITY: this is the master switch for everything outbound.
    -- SAFE DEFAULT: false. While it is false nothing is ever sent to Discord,
    -- so the placeholder webhook URLs in configs/discordLogs_config.lua are
    -- inert no matter what they contain -- that is deliberate, see the comment
    -- in that file.
    -- Turning it ON starts posting to whichever webhook URLs you configured.
    -- Those URLs are then a live secret: anyone holding one can read your log
    -- channel and, for the cheating and error channels, post into it.
    UseDiscordLogs = false
}
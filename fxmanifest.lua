-- =============================================================================
--  CIsoko Library System -- the shared boundary
--
--  WHAT THIS IS: a library, not a standalone script. On its own it shows
--  nothing and does nothing visible. It exists to be CONSUMED by your own
--  resources, which call it through its exports and its net events:
--
--      local doors = exports["cis_libs"]:GetClosestDoor(coords)
--
--  WHAT THIS IS NOT, and this is the load-bearing part of the design:
--
--  It owns NO DATABASE TABLE. It reads no config file. It reaches no framework.
--  It calls no third-party resource. It is the boundary -- the naming, the
--  marshalling, the gating, the primitives -- and nothing else. A server owner
--  can delete it and lose nothing they cannot reinstall, which is the property
--  that makes trying the platform safe.
--
--  What it used to do all of that is now in products that plug in behind it:
--
--      cis_core    framework abstraction, state, config, inventory service
--      cis_bridge  one adapter per third-party target, plus conformance tests
--      cis_keys    doors, keys, scoped credentials, the access ledger
--
--  Those are OPTIONAL. Every one of them registers a capability with
--  `exports['cis_libs']:RegisterCapability(slot, 'resource:Export')` and the
--  matching `Cis.*` call forwards to it. With none of them installed this
--  resource still boots, still serves zones, callbacks, entity sync, caching
--  and logging, and says out loud which capability is missing rather than
--  answering nil forever. Run `cis_debug` in the server console for that table.
--
--  START ORDER -- THIS IS THE ONE THAT BITES PEOPLE:
--
--      ensure cis_libs        -- must come FIRST
--      ensure cis_core        -- then the products, in this order
--      ensure cis_bridge
--      ensure my_resource     -- anything that consumes them, AFTER
--
--  In your server.cfg, cis_libs has to be started before every resource that
--  uses it. A consumer that starts first finds no exports and fails on its
--  first call, usually with a nil index that points nowhere near the cause. To
--  be immune to ordering entirely, add a dependency to the CONSUMING resource:
--
--      dependencies { 'cis_libs' }
--
--  REQUIREMENTS, both enforced below and not negotiable:
--
--    * OneSync must be on. The entity sync and cache layers read and mutate
--      entity state on both sides of the wire and cannot run in legacy mode.
--    * Server build 4500 or newer. Older builds lack natives this calls; they
--      fail at the call, not at startup, so the symptom is a runtime error in
--      your console rather than a refused boot.
--
--  api.lua IS DELIBERATELY NOT LISTED BELOW, and that is intentional. It is the
--  machine-readable data contract -- every export, every net event, every
--  argument and return shape -- written as a Lua table so tools can read it.
--  It defines nothing and runs nothing. Listing it here would only load it
--  into the Lua state at every boot and cache a copy per client for no gain.
--  Read it on demand instead: it is documentation a machine can check, and
--  `npm run test:api` validates it against the real registered surface.
--
--  Configuration: there is none here. `shared/defaults.lua` states the floor,
--  and a product hands over the real table through `exports['cis_libs']:
--  SetConfig`. See cis_core for the file an operator edits.
-- =============================================================================

fx_version 'cerulean'
game 'gta5'

name "Cisoko - Library System - Shared Boundary"
description "Zero-dependency shared library. Owns no table, no config, no framework."
author "Cisoko"
version "2.0.0"
lua54 'yes'

dependencies {
    '/onesync',
    '/server:4500',
}

-- Load order is not cosmetic. defaults and registry come first because
-- config.lua installs the Config/Security globals from them, and everything
-- downstream reads those globals. init.lua comes last among the shared scripts
-- because it captures the exports table and would otherwise be able to run
-- before the modules it forwards to exist.
shared_scripts {
    'shared/defaults.lua',
    'shared/registry.lua',
    'shared/grid.lua',
    'shared/pending.lua',
    'shared/config.lua',
    'shared/histogram.lua',
    'shared/ready.lua',
    'shared/detect.lua',
    'shared/algo/curve.lua',
    'shared/algo/heap.lua',
    'shared/algo/interp.lua',
    'shared/algo/lru.lua',
    'shared/algo/random.lua',
    'shared/algo/rate.lua',
    'shared/algo/sparse.lua',
    'shared/algo/window.lua',
    'shared/util/id.lua',
    'shared/util/json.lua',
    'shared/util/semver.lua',
    'shared/util/string.lua',
    'shared/util/table.lua',
    'shared/util/time.lua',
    'shared/util/validate.lua',
    'init.lua',
}

client_scripts {
    'client/initialize.lua',
    'client/logging.lua',
    'client/streaming.lua',
    'client/utils.lua',
    'client/weapon.lua',
    'client/vehicle.lua',
    'client/cache.lua',
    'client/zones.lua',
    'client/callback.lua',
    -- target.lua is the abstraction and the spec registry; the provider calls
    -- are in cis_bridge. See the header for why that split exists.
    'client/target.lua',
    'client/proxy.lua',
    'client/sync.lua',
}

server_scripts {
    'server/logging.lua',
    'server/security.lua',
    'server/callback.lua',
    'server/player.lua',
    'server/version.lua',
    'server/proxy.lua',
    'server/sync.lua',
    'server/initialize.lua',
}

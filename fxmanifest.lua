-- cis_libs — shared boundary. Owns no table, no config file, no framework.
-- ensure cis_libs first. Consumers need a dependency and the init shared_script.
-- OneSync on. Server build 4500+. api.lua is the contract; not loaded at runtime.

fx_version 'cerulean'
game 'gta5'

name "Cisoko - Library System"
description "Zero-dependency shared library. Owns no table, no config, no framework."
author "Cisoko"
version "1.0.0"
lua54 'yes'

dependencies {
    '/onesync',
    '/server:4500',
}

-- Server convars that OUTRANK SetConfig (DOCUMENTATION.md §3). Plain `set`, never
-- `setr`: none of these may reach a client. Blank means "not set, SetConfig
-- decides", which is why the two switches are strings and not CV_BOOL: a checkbox
-- has no "not set", and a written-out `false` would pin the posture.
convar_category 'cis_libs' {
    'Security and limits (a set convar wins over SetConfig)',
    {
        { 'Resources allowed to mutate doors and sync (comma list)', 'cis_authorized_resources', 'CV_STRING', '' },
        { 'Allow ANY resource to mutate: true / false / blank', 'cis_allow_any_resource', 'CV_STRING', '' },
        { 'Resource allowed to call SetConfig', 'cis_config_supplier', 'CV_STRING', '' },
        { 'Callback requests per name per window', 'cis_cb_rate_per_name', 'CV_INT', '20', 1, 10000 },
        { 'Callback requests per player per window', 'cis_cb_rate_per_player', 'CV_INT', '60', 1, 100000 },
        { 'Callback rate window (ms)', 'cis_cb_window_ms', 'CV_INT', '1000', 100, 60000 },
        { 'Callback handlers in flight per player', 'cis_cb_max_inflight', 'CV_INT', '8', 1, 1000 },
        { 'Longest string a client may send (chars)', 'cis_cb_max_string_len', 'CV_INT', '4096', 16, 1048576 },
        { 'Check for updates: true / false / blank', 'cis_check_version', 'CV_STRING', '' },
    },
}

-- Load order is load-bearing: identity before anything that could run as a
-- rename, diagnostics before loops, defaults/registry before config, init.lua
-- last so it captures a complete exports table.
-- Folder name must stay cis_libs (LICENSE.md). Consumers never load identity.lua.
shared_scripts {
    'shared/identity.lua',
    'shared/diagnostics.lua',
    'shared/timing.lua',
    'shared/loopguard.lua',
    'shared/defaults.lua',
    'shared/registry.lua',
    'shared/grid.lua',
    'shared/zonegeom.lua',
    'shared/hooks.lua',
    'shared/pending.lua',
    'shared/utf8.lua',
    'shared/owned.lua',
    'shared/config.lua',
    'shared/histogram.lua',
    'shared/ready.lua',
    'shared/detect.lua',
    'shared/statebag.lua',
    'init.lua',
}

-- Declared for Cis.require, not executed at boot.
-- Quoted paths only: a test harness matches .lua paths anywhere in this file.
files {
    'shared/algo/curve.lua',
    'shared/algo/heap.lua',
    'shared/algo/interp.lua',
    'shared/algo/lru.lua',
    'shared/algo/random.lua',
    'shared/algo/rate.lua',
    'shared/algo/ringbuffer.lua',
    'shared/algo/set.lua',
    'shared/algo/sparse.lua',
    'shared/algo/window.lua',
    'shared/util/array.lua',
    'shared/util/class.lua',
    'shared/util/cron.lua',
    'shared/util/id.lua',
    'shared/util/json.lua',
    'shared/util/locale.lua',
    'shared/util/mathx.lua',
    'shared/util/print.lua',
    'shared/util/semver.lua',
    'shared/util/string.lua',
    'shared/util/table.lua',
    'shared/util/time.lua',
    'shared/util/timer.lua',
    'shared/util/validate.lua',
    -- The NUI page, listed file by file rather than as a glob: the release zip
    -- and the live deploy are built from this block and do not expand globs.
    'web/index.html',
    'web/style.css',
    'web/js/app.js',
    'web/js/context.js',
    'web/js/core.js',
    'web/js/dialog.js',
    'web/js/markdown.js',
    'web/js/menu.js',
    'web/js/nav.js',
    'web/js/notify.js',
    'web/js/progress.js',
    'web/js/queue.js',
    'web/js/radial.js',
    'web/js/skill.js',
    'web/js/skillcheck.js',
    'web/js/textui.js',
    'web/js/validate.js',
    -- CONSUMER-ONLY ENGINES: loaded by init.lua into the client VM of a consumer on
    -- first use (the cache mirror, markers, scaleforms, DUI, animations and
    -- control holds). cis_libs never runs them, so they are files, not scripts;
    -- the engines cis_libs ALSO runs are client_scripts below.
    'client/core/mirror.lua',
    'client/core/marker.lua',
    'client/core/scaleform.lua',
    'client/core/dui.lua',
    'client/core/anim.lua',
    'client/core/controls.lua',
}

ui_page 'web/index.html'

client_scripts {
    -- The engines first. Each is one file of pure logic that cis_libs runs here
    -- AND a consumer loads into its own VM through init.lua (Cis.zones and the
    -- rest), so the wrappers below and every consumer share one source.
    'client/core/zones.lua',
    'client/core/points.lua',
    'client/core/keybind.lua',
    'client/core/world.lua',
    'client/core/raycast.lua',
    'client/core/streaming.lua',
    'client/core/vehicle.lua',
    'client/initialize.lua',
    'client/logging.lua',
    'client/streaming.lua',
    'client/utils.lua',
    'client/weapon.lua',
    'client/vehicle.lua',
    'client/cache.lua',
    'client/zones.lua',
    'client/points.lua',
    'client/world.lua',
    'client/raycast.lua',
    'client/keybind.lua',
    'client/ui.lua',
    'client/interface/nui.lua',
    'client/interface/focus.lua',
    'client/interface/theme.lua',
    'client/interface/notify.lua',
    'client/interface/textui.lua',
    'client/interface/progress.lua',
    'client/interface/alert.lua',
    'client/interface/input.lua',
    'client/interface/context.lua',
    'client/interface/menu.lua',
    'client/interface/radial.lua',
    'client/interface/skillcheck.lua',
    'client/callback.lua',
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
    'server/command.lua',
    'server/zones.lua',
    'server/interface.lua',
    'server/initialize.lua',
    'server/selfcheck.lua',
}

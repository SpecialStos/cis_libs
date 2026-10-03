-- The orchestrator. Server side runs the suites; client side executes them.
--
-- WHY THIS DOES NOT USE cis_libs CALLBACKS FOR ITS OWN CONTROL CHANNEL.
-- A harness built on the thing it is testing cannot report that the thing is
-- broken: a callback registry that has stopped dispatching is exactly the
-- failure the harness exists to catch, and a harness waiting on a callback is
-- simply waiting. So everything here runs on plain events (`cis_test:*`) and
-- plain exports, and cis_libs is only ever the SUBJECT.
--
-- WHAT IT MAY WRITE. The harness writes one results file per run with
-- SaveResourceFile, plus status.json, which the agent reads instead of console
-- scrollback. cis_libs writes no files at all; that boundary is checked by
-- test/contracts.lua and the harness deliberately does not inherit it, or there
-- would be no way to record what a run found.
--
-- NEVER LOGGED: player names, identifiers or IPs. A run id, a server id and
-- counts are enough to read a result, and those are what get printed.

fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'cis_test'
description 'Live conformance harness for cis_libs. Not shipped.'
author 'cis_libs'
version '0.0.0'

dependencies {
    'cis_libs',
    '/onesync',
}

-- ORDER MATTERS HERE, and it was wrong once. status.lua writes status.json as
-- soon as it loads, so it must load AFTER the suites have registered -- placed
-- between control.lua and report.lua it wrote a status.json with an empty
-- `suites` array, and tools/live-run.js read that as "every suite needs a
-- player" and skipped an entire run on a server with no player connected. The
-- suites are registered by the three suites/* scripts; status.lua is loaded once
-- they are all in.
server_scripts {
    'server/json.lua',
    'server/runner.lua',
    'server/control.lua',
    'server/report.lua',
    'server/suites/server.lua',
    'server/suites/player.lua',
    'server/suites/lifecycle.lua',
    'server/status.lua',
    'server/commands.lua',
}

client_scripts {
    'client/player.lua',
    'client/player_suites.lua',
    'client/bridge.lua',
}
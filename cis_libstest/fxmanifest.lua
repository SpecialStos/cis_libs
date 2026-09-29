fx_version 'cerulean'
game 'gta5'

name "Cisoko - Library Test Harness"
description "Exercises the cis_libs API on client and server and writes a JSON report."
author "Cisoko"
version "2.0.0"
lua54 'yes'

-- This is a SEPARATE resource. cis_libs must start first.
dependencies {
    'cis_libs',
}

-- A resource gets its own Lua VM: shared_script COPIES a file, it does not
-- share cis_libs's globals. So this resource loads what it needs itself.
-- @cis_libs/init.lua gives the Cis proxy table, whose functions cross the
-- boundary to the real library. The four shared/ modules are pure (no natives),
-- so a local copy is safe and is the same source under test.
shared_scripts {
    '@cis_libs/init.lua',
    '@cis_libs/shared/grid.lua',
    '@cis_libs/shared/pending.lua',
    '@cis_libs/shared/histogram.lua',
    '@cis_libs/shared/config.lua',
    'shared/report.lua',
    'shared/runner.lua',
    'shared/probe.lua',
    'config.lua',
}

client_scripts {
    'client/suite.lua',
    'client/init.lua',
}

server_scripts {
    'server/suite.lua',
    'server/init.lua',
}

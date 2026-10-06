-- The second consumer. Deliberately collides with cis_test on every name.
--
-- WHY A SECOND CONSUMER AT ALL. cis_libs promises that two resources may use
-- the same zone name, the same callback name, the same sync id and the same
-- target name without seeing each other's work, and that stopping one releases
-- only its own. None of that is checkable from inside one resource: a single
-- consumer creating a zone twice proves nothing, because there is no second
-- owner to collide with.
--
-- So this resource uses THE SAME NAMES cis_test does. Every answer here is
-- therefore "did the collision stay isolated", which is the property the whole
-- capability and ownership model exists to provide.
--
-- DELIBERATELY NOT AUTHORIZED. The harness config allow-lists `cis_test` and
-- `cis_test_providers` and not this one, so every mutating export answered from
-- here comes back refused with a reason. That is not an accident of the config:
-- it is the only way the security cases have something real to refuse, and a
-- test rig that quietly granted itself every permission would be testing a
-- world no operator runs.

fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'cis_test_b'
description 'The second live-harness consumer. Collides on purpose. Not shipped.'
author 'cis_libs'
version '0.0.0'

dependencies {
    'cis_libs',
    '/onesync',
}

-- The DIRECT INCLUDE, which is the half of 5.1 that protects a consumer.
-- cis_libs moved its fifteen modules to files {}, so nothing installs them
-- for anybody. A resource that wants one includes the file itself, and each
-- module still installs its legacy global on that path -- proven here on both
-- realms, together with the vararg count that makes the two paths differ.
server_scripts {
    'shared/includeprobe.lua',
    '@cis_libs/shared/algo/lru.lua',
    'server/collide.lua',
}

client_scripts {
    'shared/includeprobe.lua',
    '@cis_libs/shared/algo/lru.lua',
    'client/collide.lua',
}
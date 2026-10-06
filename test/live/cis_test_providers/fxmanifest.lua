-- Stage 2.2. Fake providers for every capability slot, server and client.
--
-- WHY THIS RESOURCE EXISTS AT ALL. The live server is vanilla. There is no
-- cis_core, no database, no target library and no discord bridge, so every slot
-- on a real install is held by a product and a test cannot tell "the library
-- refused because nothing is installed" from "the library is broken". This
-- resource takes every slot with a recording fake, so a failure means the
-- LIBRARY failed rather than the environment.
--
-- WHY THE FAKES RECORD. The plan's contract is that every capability call
-- forwards its arguments EXACTLY. "Exactly" is not checkable by asserting that
-- something was returned; it is checkable by asserting what the other side saw.
-- GetCalls(slot) returns the ring, and a test reads the arguments off it.
--
-- WHY THE FAULTS EXIST. The interesting failures are the ones where a provider
-- misbehaves: raises, returns nil, answers false, takes too long, or answers
-- with the wrong shape. A suite that only ever sees a well-behaved provider
-- proves that cis_libs works with cis_libs.
--
-- It is also the CONFIG SUPPLIER. It calls SetConfig with an allow-list naming
-- only itself and cis_test -- deliberately NOT cis_test_b, so the refusal paths
-- have something real to refuse -- and with DropPlayer false, so a security
-- case can never actually remove the player.

fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'cis_test_providers'
description 'Recording fakes for every cis_libs capability slot, plus the config the harness runs under.'
author 'cis_libs'
version '0.0.0'

-- Deliberately not the contract cis_libs ships. The providers resource is the
-- ENVIRONMENT, not a consumer: it is allowed to be installed next to anything.
dependencies {
    'cis_libs',
    '/onesync',
}

shared_scripts {
    'shared/ring.lua',
}

server_scripts {
    'server/fakes.lua',
    'server/config.lua',
}

client_scripts {
    'client/fakes.lua',
}
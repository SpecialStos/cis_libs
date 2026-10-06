-- The THIRD consumer, and the only one that exists because a fixture could not
-- do its job.
--
-- WHY THIS IS HERE. Two live cases are about OWNERSHIP: one resource stopping
-- must take its own records and nobody else's, and one resource must not be
-- able to answer another's callback. Both need a second resource that actually
-- OWNS something.
--
-- `cis_test_b` does not, and cannot. It is deliberately absent from
-- AuthorizedResources -- correctly, because it is what the security cases need
-- something to refuse -- so every mutating export it calls comes back refused
-- before any state is created. Its `SyncCreate` therefore returns nothing, it
-- owns no record, and a case asserting "cis_test_b owns at least one record"
-- fails for a reason that has nothing to do with the property under test.
--
-- That failure was being read as a library defect. It was the fixture: the
-- case could never have passed, because the resource it names is not permitted
-- to own the thing it asks about.
--
-- So this resource is the authorized second consumer. It owns a sync record and
-- a callback, and does nothing else -- no collisions, no security cases. Its
-- whole purpose is to be a real owner that another resource's stop must not
-- disturb.

fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'cis_test_c'
description 'The authorized second live-harness consumer. Owns state on purpose. Not shipped.'
author 'cis_libs'
version '0.0.0'

dependencies {
    'cis_libs',
    '/onesync',
}

server_scripts {
    'server/own.lua',
}

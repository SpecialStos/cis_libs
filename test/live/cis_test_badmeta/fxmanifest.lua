-- Deliberately wrong. Started ONLY by the cases that need it.
--
-- This resource is a FIXTURE, and everything in it is a defect. It exists so
-- that the checks that should refuse something can be shown refusing it on a
-- real server instead of being asserted about in the abstract.
--
-- Three faults, one per rule that needs proving:
--
--   1. It includes @cis_libs/init.lua WITHOUT declaring `dependency
--      'cis_libs'`. That is the self-check's `missing_dependency`, and the fix
--      text has to name the manifest line an operator should add.
--   2. It declares a contract major cis_libs does not speak. Registration
--      must refuse, and the reason must name the field AND which resource to
--      update -- an operator with two products has to know which one is wrong.
--   3. It has a `cis_requires` entry for a slot the harness releases first, so
--      the "capability released mid-run" path has something real to break on.
--
-- IT IS NEVER ENSURED ALONG WITH THE HARNESS. Starting it during a normal run
-- would put a resource with a broken contract and a missing dependency into
-- every boot, which is precisely the state an operator is trying to avoid.
--
-- It also does NOT include this file's own name in the manifest's dependency
-- list on purpose -- that is fault 1, and fixing it would delete the fixture.

fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'cis_test_badmeta'
description 'A deliberately broken consumer, used only by the checks that must refuse it. Not shipped.'
author 'cis_libs'
version '0.0.0'

-- FAULT 1: @cis_libs/init.lua is included below, and `cis_libs` is NOT in this
-- list. FiveM will start this resource whenever it happens to be in the cfg,
-- with no ordering guarantee relative to cis_libs.

-- FAULT 2: a contract major this cis_libs does not speak.
cis_libs_contract '99'

-- FAULT 3: a requirement for a slot the harness releases before this starts.
cis_requires {
    'migration',
}

shared_scripts {
    '@cis_libs/init.lua',
}

server_scripts {
    'server/claim.lua',
}
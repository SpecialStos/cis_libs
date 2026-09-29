-- Test harness configuration. Read on both realms.

CisTestConfig = {
    -- DANGER: these tests change real server state (inventory, database rows,
    -- spawned entities, door states). Off by default so a stray /cistest on a
    -- live server cannot damage anything. Turn on only on a test instance.
    RunMutating = false,

    -- Per-test deadline. Raise if your database is genuinely slow.
    TimeoutMs = 8000,

    -- File written inside the cis_libstest resource folder.
    -- nil = cis-test-report-<unix timestamp>.json
    OutputFile = nil,

    -- Ask connected clients to run their suite too.
    RunClientTests = true,

    -- How long the server waits for client results before writing the report.
    ClientWaitMs = 15000,

    -- Print a line per test as it completes.
    Verbose = true,
}

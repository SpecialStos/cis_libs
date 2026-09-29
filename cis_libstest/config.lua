-- Test harness configuration. Read on both realms.

CisTestConfig = {
    -- DANGER: changes real server state (inventory items, doors, spawned
    -- entities, database rows). Off by default so a stray /cistest on a live
    -- server cannot damage anything. Every mutating test is reported as
    -- `skipped` with this reason when off.
    RunMutating = false,

    -- Boundary probes. These are read-only and safe; they exist to MEASURE
    -- behaviour that was previously assumed, and several of them fail loudly
    -- when the engine's semantics differ from the documented model.
    RunProbes = true,

    -- Teleporting tests move the player around for seconds at a time. This
    -- trips heartbeat-based anti-cheat (phylax_ac has kicked us for it), so
    -- set false when one is running.
    RunTeleport = true,

    -- Per-test deadline. Raise for a genuinely slow database.
    TimeoutMs = 8000,

    -- File written inside the cis_libstest resource folder.
    -- nil = cis-test-report-<unix timestamp>.json
    OutputFile = nil,

    -- Ask connected clients to run their suite too.
    RunClientTests = true,

    -- How long the server waits for client results before writing the report.
    -- The teleport and multi-player tests are slow; do not cut this short.
    ClientWaitMs = 25000,

    -- Print a line per test as it completes.
    Verbose = true,
}

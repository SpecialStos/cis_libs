-- Writing the run down.
--
-- ONE FILE PER RUN, WHOLE-FILE WRITES, NEVER AN APPEND.
--
-- The harness MAY write files -- cis_libs may not, and that is the boundary the
-- contract test enforces. This is the one place the harness writes, and it
-- writes the same way the library is forbidden to: SaveResourceFile with a
-- complete body, so a run that dies half way leaves either a complete file or
-- no file, never a truncated one that parses as truth.
--
-- TWO FILES. results_<runId>.json keeps the history; results_latest.json is the
-- one an operator or a reviewer reads. Both are written from the same body in
-- the same pass, so they cannot disagree.

CisTestReport = {}

local function runBody(runId, tally)
    return {
        run = runId,
        commit = CisTestRunner.Commit(),
        server = GetConvar('sv_hostname', 'unknown'),
        -- Player COUNT, never a name. A results file gets attached to a ticket.
        players = CisTestRunner.PlayerCount(),
        tally = tally,
        cases = CisTestRunner.Results(),
    }
end

local function write(path, body)
    local ok, err = pcall(SaveResourceFile, GetCurrentResourceName(), path, body, -1)
    if not ok then
        -- Loudly, and without taking the run down. A read-only data directory
        -- must cost the operator the FILE, not the RESULTS, which are already
        -- on the console line by line.
        print(('[cis_test] could not write %s: %s'):format(path, tostring(err)))
        return false
    end
    return true
end

function CisTestReport.Write(runId, tally)
    local body = CisTestJson.encode(runBody(runId, tally))
    local wroteHistory = write(('results_%s.json'):format(runId), body)
    local wroteLatest = write('results_latest.json', body)
    print(('[cis_test] results: %s%s'):format(
        wroteHistory and ('results_%s.json'):format(runId) or '(not written)',
        wroteLatest and ' + results_latest.json' or ''))
    return wroteHistory or wroteLatest
end
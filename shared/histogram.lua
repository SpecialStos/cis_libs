-- Job counts: how many connected players are in each job, and by how much that
-- has moved.
--
-- Pass timings are CisTiming in shared/timing.lua. Do not put them here.
--
-- PURE, and safe to duplicate -- the store is passed
-- in. The store is what is NOT pure: `server/player.lua` holds one in a module
-- local, and that file is a thirteenth stateful file for exactly this reason.

CisHistogram = {}

function CisHistogram.new()
    return {
        counts = {},
        players = {},
    }
end

local function jobName(job)
    if type(job) == 'table' then
        return job.name
    end
    return job
end

-- Counts never go below zero. A double remove, or a remove for a player this
-- store never saw, must not produce a negative population -- a negative count
-- answers "is anyone a police officer" with yes, and that is the wrong answer
-- for a gate.
local function bump(store, name, delta)
    if not name then
        return
    end
    store.counts[name] = math.max(0, (store.counts[name] or 0) + delta)
end

-- One call, not "join then count". A player who changes job passes through here
-- once and both buckets are adjusted, so a job change can never be observed
-- between the two steps and never double-counts. Returning early on an
-- unchanged job is what keeps a heartbeat calling this at 1Hz free.
function CisHistogram.set(store, src, job)
    local name = jobName(job)
    local previous = store.players[src]
    if previous == name then
        return
    end
    if previous then
        bump(store, previous, -1)
    end
    store.players[src] = name
    if name then
        bump(store, name, 1)
    end
end

function CisHistogram.remove(store, src)
    local previous = store.players[src]
    if previous then
        bump(store, previous, -1)
    end
    store.players[src] = nil
end

function CisHistogram.count(store, jobs)
    if type(jobs) == 'string' then
        return store.counts[jobs] or 0
    end
    if type(jobs) ~= 'table' then
        return 0
    end
    local total = 0
    for i = 1, #jobs do
        total = total + (store.counts[jobs[i]] or 0)
    end
    return total
end

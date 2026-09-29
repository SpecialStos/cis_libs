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

local function bump(store, name, delta)
    if not name then
        return
    end
    store.counts[name] = math.max(0, (store.counts[name] or 0) + delta)
end

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

-- Incrementing pending-key map with timeout sweep. No natives.

CisPending = {}

function CisPending.new()
    return {
        nextKey = 0,
        items = {},
    }
end

function CisPending.alloc(store, payload, expireAt)
    store.nextKey = store.nextKey + 1
    local key = store.nextKey
    store.items[key] = {
        payload = payload,
        expireAt = expireAt,
    }
    return key
end

-- Take, not peek, and it reports a miss by returning nil.
function CisPending.take(store, key)
    local item = store.items[key]
    if not item then
        return nil
    end
    store.items[key] = nil
    return item
end

-- Read without consuming. For a caller that must decide whether it owns the entry
function CisPending.peek(store, key)
    return store.items[key]
end

-- Expire everything due, then report it.
function CisPending.sweep(store, now, onExpire)
    local expired = {}
    for key, item in pairs(store.items) do
        if item.expireAt <= now then
            expired[#expired + 1] = { key = key, item = item }
        end
    end
    for i = 1, #expired do
        store.items[expired[i].key] = nil
    end
    if not onExpire then
        return #expired
    end
    local failures = 0
    for i = 1, #expired do
        local ok, err = pcall(onExpire, expired[i].key, expired[i].item)
        if not ok then
            failures = failures + 1
            -- Reported through the log when there is one, and printed when there is
            if Logging and Logging.Error then
                Logging.Error(('cis_libs: pending onExpire raised for key %s: %s')
                    :format(tostring(expired[i].key), tostring(err)))
            else
                print(('[cis_libs] pending onExpire raised for key %s: %s')
                    :format(tostring(expired[i].key), tostring(err)))
            end
        end
    end
    return #expired - failures
end

function CisPending.count(store)
    local n = 0
    for _ in pairs(store.items) do
        n = n + 1
    end
    return n
end

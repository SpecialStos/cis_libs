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

function CisPending.take(store, key)
    local item = store.items[key]
    if not item then
        return nil
    end
    store.items[key] = nil
    return item
end

function CisPending.sweep(store, now, onExpire)
    for key, item in pairs(store.items) do
        if item.expireAt <= now then
            store.items[key] = nil
            if onExpire then
                onExpire(key, item)
            end
        end
    end
end

function CisPending.count(store)
    local n = 0
    for _ in pairs(store.items) do
        n = n + 1
    end
    return n
end

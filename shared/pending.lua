-- Incrementing pending-key map with timeout sweep. No natives.
--
-- PURE, and safe for a consumer to `shared_script` for a private copy
-- (COMPATIBILITY.md §10.2). The store is passed IN rather than held as a module
-- local, which is what makes that safe: this file owns no state at all, so two
-- copies cannot disagree about anything.
--
-- That is the difference from the stateful files. A key allocated here has to be
-- resolved by the SAME store on the other end of the wire, so a copy is only
-- useful when both ends of the exchange are the copy -- never as a way to reach
-- a store inside cis_libs.

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

-- Take, not peek, and it reports a miss by returning nil. A response that
-- arrives twice, or after the sweep already expired the key, is dropped rather
-- than delivered -- the alternative is resolving a promise the caller has
-- already rejected.
--
-- DESTRUCTIVE, which matters wherever the caller has not yet established that
-- it is entitled to the entry. Use `peek` to answer that question first: see
-- the response handler in server/callback.lua, where a client naming a key it
-- does not own used to destroy another player's callback and leave nothing
-- behind to time out.
function CisPending.take(store, key)
    local item = store.items[key]
    if not item then
        return nil
    end
    store.items[key] = nil
    return item
end

-- Read without consuming. For a caller that must decide whether it owns the
-- entry before the entry is destroyed -- an authorisation question, which
-- should never be answered by an action that already changed the state.
function CisPending.peek(store, key)
    return store.items[key]
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

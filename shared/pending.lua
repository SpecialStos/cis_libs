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

-- Expire everything due, then report it.
--
-- The COLLECTION PASS AND THE REPORTING PASS ARE SEPARATE, and that is the
-- whole fix. `onExpire` used to be called from inside the iteration over
-- `store.items`, uncaught, so one consumer whose expire handler raised -- which
-- is exactly what happens when the handler logs and the logger is already gone
-- -- left every OTHER expired key in the store for ever, and made every
-- subsequent sweep raise at the same key. The store leaked one key at a time and
-- nothing said so.
--
-- The keys are collected first and removed first, so the store is consistent
-- before any consumer code runs, and each `onExpire` is called under its own
-- pcall: one bad handler reports its own error and the rest still run.
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
            -- Reported through the log when there is one, and printed when there
            -- is not. Silently swallowing it is what let the leak run unnoticed
            -- in the first place.
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

-- Least-recently-used cache: O(1) get, put and remove, bounded memory.
--
-- PURE. The cache is a value; nothing here is a module local. Two caches, two
-- resources, two copies of this file -- they cannot disagree, because there is
-- nothing to disagree about.
--
-- WHY A LIST AND NOT A PLAIN TABLE
--
-- A plain table is already O(1) get and O(1) insert. The only thing it cannot
-- do is evict, because it has no order. The obvious way to add one is to track
-- an "age" number per key and, at capacity, walk the whole table looking for
-- the oldest. That walk is O(n) and it happens on the insert that overflows --
-- which, in a cache that is constantly at capacity, is most of them. A cache
-- that costs O(n) to keep is not a cache.
--
-- A doubly linked list of entries gives the order directly: a get moves the
-- entry to the front (two pointer writes, O(1)) and an overflow evicts from the
-- back (O(1)). Every operation here is O(1) with no scan and no sorting. The
-- list nodes carry the key and the value inline, so the map and the list point
-- at the SAME node -- one allocation per entry rather than two, and a lookup
-- never has to follow a second indirection to get from the map to the list.
--
-- WHY DOUBLY linked and not singly
--
-- A singly linked list has no backward pointer, so removing an arbitrary entry
-- (an explicit remove, or an eviction from the middle) needs the previous node
-- -- a scan. Eviction is always from the back, where a singly list is fine, but
-- an explicit `remove(key)` is the common case here: a player disconnects and
-- every cached value keyed by their server id has to go. That is a removal
-- from the MIDDLE, and it is why the list is doubly linked.
--
-- WHEN A PLAIN TABLE IS THE BETTER ANSWER
--
-- Honestly, often:
--
--   * If nothing is ever evicted, this is a plain table with extra steps. Use
--     a table.
--   * If the working set is small and known and you rebuild it anyway -- the
--     per-frame entity caches, a zone list loaded at start -- eviction is not
--     the problem and neither is memory.
--   * If you are caching tens of items, the bookkeeping costs more than the
--     memory you saved, and a table is simpler to read.
--
-- This module earns its keep at the size where memory actually hurts and the
-- working set does not fit: name resolution for thousands of players, per-
-- weapon attachment previews, a route cache. The `capacity` is a hard ceiling,
-- so the worst case is known in advance instead of being a slow leak that only
-- shows up on a full server.
--
-- MEMORY BOUND
--
--   live entries   <= capacity, always, enforced on every put
--   per entry      one node table (key, value, prev, next) plus one map slot
--   clear()        releases the map and the list; the GC reclaims both at the
--                  next collection, it is not immediate
--
-- `capacity` may be nil for an unbounded cache: nothing is ever evicted and the
-- structure degenerates to a table with a doubly linked list attached. That is
-- legal and is what you want when the size is bounded by something else (a
-- fixed set of player ids, say) and the bound is enforced by the caller.

CisLRU = {}

-- Sentinel head and tail. Using real sentinel nodes rather than nil at the
-- ends means every unlink is the same three lines and no branch: there is no
-- "is this the first node" case to get wrong. The sentinels are never returned
-- to a caller -- `size` counts real entries, and every walk stops at them.
local function sentinel()
    return { key = nil, value = nil }
end

--- Create an empty cache.
--- @param capacity number|nil  maximum live entries. nil, a non-number, or a
---        value below 1 means UNBOUNDED (nothing is evicted) -- except 0 and
---        negatives, which are clamped to 1. A zero-capacity cache silently
---        drops every put and then looks like a cache that is broken, which is
---        a much worse outcome than holding one entry.
--- @return table  the cache; treat it as a value and hand it to every function
function CisLRU.new(capacity)
    local cap
    if type(capacity) == 'number' and capacity == capacity then
        cap = math.floor(capacity)
        if cap < 1 then cap = 1 end
    end
    local head = sentinel()
    local tail = sentinel()
    head.next = tail
    tail.prev = head
    return {
        capacity = cap,          -- nil == unbounded
        size = 0,
        map = {},
        head = head,             -- most recently used side
        tail = tail,             -- least recently used side
    }
end

local function unlink(lru, node)
    node.prev.next = node.next
    node.next.prev = node.prev
    node.prev, node.next = nil, nil
end

local function pushFront(lru, node)
    local first = lru.head.next
    node.prev = lru.head
    node.next = first
    first.prev = node
    lru.head.next = node
end

--- Look up a key and mark it as most recently used.
---@param lru
---@param key
--- @return any  the stored value, or nil when the key is absent. A stored
---         value of nil is indistinguishable from an absent key, which is the
---         Lua convention and the reason `put(key, nil)` is a remove.
function CisLRU.get(lru, key)
    local node = lru.map[key]
    if not node then
        return nil
    end
    -- Already at the front: the unlink/relink is still correct but it is four
    -- writes for nothing, and a cache read in a hot loop reads the same key
    -- many times in a row.
    if lru.head.next ~= node then
        unlink(lru, node)
        pushFront(lru, node)
    end
    return node.value
end

--- Look up a key WITHOUT changing its recency.
---
--- The read that must not count as a use. A "is this player cached" check in
--- a hot loop that silently promotes the entry would keep exactly the entries
--- nobody is really using, and the cache would never evict them.
---@param lru
---@param key
--- @return any  the value, or nil
function CisLRU.peek(lru, key)
    local node = lru.map[key]
    if not node then
        return nil
    end
    return node.value
end

--- Is a key present, without changing its recency?
---@param lru
---@param key
--- @return boolean
function CisLRU.has(lru, key)
    return lru.map[key] ~= nil
end

--- Store a value and mark it most recently used.
---
--- Updating an existing key does NOT change the size and does not evict: it
--- reuses the node. That is the whole point of keeping the node in the map, and
--- it is why a caller updating a value every frame does not churn the list.
---
--- @param value any  nil is treated as a REMOVE, because a table cannot hold a
---        nil and pretending otherwise would make a key that is present with a
---        nil value indistinguishable from one that is absent in a way the
---        caller cannot detect.
--- @return any  the key that had to be evicted to make room, or nil. The
---         caller needs the KEY rather than the value to invalidate whatever
---         it built on top of the cache.
function CisLRU.put(lru, key, value)
    if value == nil then
        CisLRU.remove(lru, key)
        return nil
    end

    local node = lru.map[key]
    if node then
        node.value = value
        if lru.head.next ~= node then
            unlink(lru, node)
            pushFront(lru, node)
        end
        return nil
    end

    node = { key = key, value = value }
    lru.map[key] = node
    pushFront(lru, node)
    lru.size = lru.size + 1

    if lru.capacity and lru.size > lru.capacity then
        local _, evictedKey = CisLRU.popOldest(lru)
        return evictedKey
    end
    return nil
end

--- Remove the least recently used entry.
---@param lru
--- @return any, any  the evicted value and the evicted key; nil, nil when the
---         cache is empty
function CisLRU.popOldest(lru)
    local last = lru.tail.prev
    if last == lru.head then
        return nil
    end
    local value, key = last.value, last.key
    unlink(lru, last)
    lru.map[key] = nil
    lru.size = lru.size - 1
    return value, key
end

--- Remove a key, whatever its position in the order.
---@param lru
---@param key
--- @return any  the removed value, or nil when the key was not present
function CisLRU.remove(lru, key)
    local node = lru.map[key]
    if not node then
        return nil
    end
    local value = node.value
    unlink(lru, node)
    lru.map[key] = nil
    lru.size = lru.size - 1
    return value
end

--- Remove every entry for which `predicate(key, value)` is true.
---
--- O(n), and that is honest rather than incidental: there is no other way to
--- answer "drop everything belonging to this player" in a structure whose index
--- is by key. It is here because the case is real -- a player disconnects and
--- their route cache, their name cache and their pending lookups all have to go
-- at once -- and because a caller who wrote it as a loop of remove() calls would
--- get the same O(n) with more code.
---
--- Removing while walking is safe: the walk holds the successor before unlinking.
---@param lru
---@param predicate
--- @return number  how many entries were removed
function CisLRU.removeWhere(lru, predicate)
    if type(predicate) ~= 'function' then
        return 0
    end
    local removed = 0
    local node = lru.head.next
    while node ~= lru.tail do
        local successor = node.next
        if predicate(node.key, node.value) then
            unlink(lru, node)
            lru.map[node.key] = nil
            lru.size = lru.size - 1
            removed = removed + 1
        end
        node = successor
    end
    return removed
end

--- Number of live entries. O(1): a counter, not a walk.
---@param lru
--- @return number
function CisLRU.count(lru)
    return lru.size
end

--- Empty the cache.
---
--- Both structures are replaced rather than emptied in place. Assigning nil to
--- every map slot and every next pointer is O(n) AND leaves the tables with
--- their full allocated capacity, so the memory is not actually released. New
--- tables cost two allocations and hand the old ones straight to the collector.
function CisLRU.clear(lru)
    local head = sentinel()
    local tail = sentinel()
    head.next = tail
    tail.prev = head
    lru.map = {}
    lru.head = head
    lru.tail = tail
    lru.size = 0
end

--- Keys from most recently used to least.
---@param lru
--- @return table  a NEW array. The live list is not walkable from outside and
---         should not be: a caller iterating it while the cache is being
---         modified would be reading a list that is being relinked underneath.
function CisLRU.keys(lru)
    local out = {}
    local node = lru.head.next
    while node ~= lru.tail do
        out[#out + 1] = node.key
        node = node.next
    end
    return out
end

--- Call `fn(key, value)` for every entry, most recently used first.
---
--- The visitor MUST NOT put or remove during the walk -- doing so relinks the
--- node the walk is standing on. That restriction is deliberate: a walk that
--- silently corrupts itself is worse than one that says so, and the safe
--- pattern (collect the keys, mutate, then walk) is two lines.
function CisLRU.each(lru, fn)
    if type(fn) ~= 'function' then
        return 0
    end
    local node = lru.head.next
    local seen = 0
    while node ~= lru.tail do
        fn(node.key, node.value)
        seen = seen + 1
        node = node.next
    end
    return seen
end

-- Least-recently-used cache: O(1) get, put and remove, bounded memory.

local M = {}

-- Sentinel head and tail. Using real sentinel nodes rather than nil at the ends means
local function sentinel()
    return { key = nil, value = nil }
end

--- Create an empty cache.
--- @param capacity number|nil  maximum live entries. nil, a non-number, or a
--- @return table  the cache; treat it as a value and hand it to every function
function M.new(capacity)
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

local function unlink(_, node)
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
--- @param lru
--- @param key
--- @return any  the stored value, or nil when the key is absent. A stored
function M.get(lru, key)
    local node = lru.map[key]
    if not node then
        return nil
    end
    -- Already at the front: the unlink/relink is still correct but it is four writes
    if lru.head.next ~= node then
        unlink(lru, node)
        pushFront(lru, node)
    end
    return node.value
end

--- Look up a key WITHOUT changing its recency.
--- @param lru
--- @param key
--- @return any  the value, or nil
function M.peek(lru, key)
    local node = lru.map[key]
    if not node then
        return nil
    end
    return node.value
end

--- Is a key present, without changing its recency?
--- @param lru
--- @param key
--- @return boolean
function M.has(lru, key)
    return lru.map[key] ~= nil
end

--- Store a value and mark it most recently used.
--- @param value any  nil is treated as a REMOVE, because a table cannot hold a
--- @param lru
--- @param key
--- @return any  the key that had to be evicted to make room, or nil. The
function M.put(lru, key, value)
    if value == nil then
        M.remove(lru, key)
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
        local _, evictedKey = M.popOldest(lru)
        return evictedKey
    end
    return nil
end

--- Remove the least recently used entry.
--- @param lru
--- @return any, any  the evicted value and the evicted key; nil, nil when the
function M.popOldest(lru)
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
--- @param lru
--- @param key
--- @return any  the removed value, or nil when the key was not present
function M.remove(lru, key)
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

-- at once -- and because a caller who wrote it as a loop of remove() calls would
--- Remove every entry for which `predicate(key, value)` is true.
--- @param lru
--- @param predicate
--- @return number  how many entries were removed
function M.removeWhere(lru, predicate)
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
--- @param lru
--- @return number
function M.count(lru)
    return lru.size
end

--- Empty the cache. Both structures are replaced rather than emptied in place.
--- @param lru
--- @return nil  it mutates the cache in place
function M.clear(lru)
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
--- @param lru
--- @return table  a NEW array. The live list is not walkable from outside and
function M.keys(lru)
    local out = {}
    local node = lru.head.next
    while node ~= lru.tail do
        out[#out + 1] = node.key
        node = node.next
    end
    return out
end

--- Call `fn(key, value)` for every entry, most recently used first.
--- @param lru
--- @param fn
--- @return number  how many entries were visited; 0 when fn is not a function. Most recently used first.
function M.each(lru, fn)
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

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisLRU = M
end

return M

-- Least-recently-used cache: O(1) get, put and remove, bounded memory.

local M = {}

-- Sentinel head and tail. Using real sentinel nodes rather than nil at the ends means
local function sentinel()
    return { key = nil, value = nil }
end

--- Create an empty cache.
---@param capacity? number  maximum live entries. nil, a non-number, or a
---@return table  the cache; treat it as a value and hand it to every function
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
---@param lru table
---@param key any
---@return any  nil when absent
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
---@param lru table
---@param key any
---@return any  nil when absent
function M.peek(lru, key)
    local node = lru.map[key]
    if not node then
        return nil
    end
    return node.value
end

--- Is a key present, without changing its recency?
---@param lru table
---@param key any
---@return boolean
function M.has(lru, key)
    return lru.map[key] ~= nil
end

--- Store a value and mark it most recently used.
---@param lru table
---@param key any
---@param value any  nil is treated as a REMOVE, because a table cannot hold a
---@return any  the key evicted to make room, or nil
---@return string|nil reason  why the key was refused: nil and NaN cannot index the map
function M.put(lru, key, value)
    if key == nil or key ~= key then
        if value == nil then
            return nil
        end
        return nil, ('cannot use %s as a cache key'):format(tostring(key))
    end
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
---@param lru table
---@return any value
---@return any key
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
---@param lru table
---@param key any
---@return any  the removed value, or nil
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
---@param lru table
---@param predicate fun(key: any, value: any): boolean
---@return integer  how many entries were removed
function M.removeWhere(lru, predicate)
    if type(predicate) ~= 'function' then
        return 0
    end
    -- A snapshot, as in each: a predicate that removes the next entry would leave
    -- a cursor on an unlinked node.
    local nodes = {}
    local n = 0
    local node = lru.head.next
    while node ~= lru.tail do
        n = n + 1
        nodes[n] = node
        node = node.next
    end
    local removed = 0
    for i = 1, n do
        node = nodes[i]
        if lru.map[node.key] == node and predicate(node.key, node.value) then
            -- The predicate may have removed this very node itself.
            if lru.map[node.key] == node then
                unlink(lru, node)
                lru.map[node.key] = nil
                lru.size = lru.size - 1
                removed = removed + 1
            end
        end
    end
    return removed
end

--- Number of live entries. O(1): a counter, not a walk.
---@param lru table
---@return integer
function M.count(lru)
    return lru.size
end

--- Empty the cache. Both structures are replaced rather than emptied in place.
---@param lru table
---@return nil  it mutates the cache in place
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
---@param lru table
---@return any[]  most recently used first
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
---
--- The order is a SNAPSHOT taken before the first call, so `fn` may call get,
--- put, remove or clear on the same cache. Walking the live list could not
--- survive that: a `get` relinks the node being visited to the front, so its
--- `next` is the old head and the walk revisits it forever, and a `remove` of
--- the successor leaves the cursor on an unlinked node with no `next` at all.
--- An entry removed before its turn is skipped; its current value is passed.
---@param lru table
---@param fn fun(key: any, value: any)
---@return number  how many entries were visited; 0 when fn is not a function. Most recently used first.
function M.each(lru, fn)
    if type(fn) ~= 'function' then
        return 0
    end
    local nodes = {}
    local n = 0
    local node = lru.head.next
    while node ~= lru.tail do
        n = n + 1
        nodes[n] = node
        node = node.next
    end
    local seen = 0
    for i = 1, n do
        node = nodes[i]
        -- Still live, and still THIS node: a remove-then-put of the same key
        -- makes a new node, and the old one must not be visited for it.
        if lru.map[node.key] == node then
            fn(node.key, node.value)
            seen = seen + 1
        end
    end
    return seen
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisLRU = M
end

return M

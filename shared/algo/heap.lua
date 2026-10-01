-- Binary min-heap, and the priority queue built on it.
--
-- PURE. The heap is a value; the comparator is supplied by the caller.
--
-- WHY A HEAP, GIVEN FIVE-M HAS NO SORTED COLLECTION
--
-- The alternative to a heap is a sorted array. It is not slower at READING --
-- binary search in a sorted array is O(log n) and reading the front is O(1),
-- exactly like a heap. It is the INSERT that is O(n): putting a value in
-- order means shifting every element after it, and a memmove of n elements is
-- not a pointer decrement however the runtime implements it. For a work queue
-- that receives work continuously, inserts are the operation that matters, so
-- the sorted array is O(n) per push and the heap is O(log n) with no shifting
-- at all.
--
-- What the heap gives up, and the caller has to know:
--
--   * ORDER. Popping returns the minimum but not the second smallest, so a
--     full sorted list is not available without draining. `drain` drains.
--   * SEARCH. There is no "find this value" in O(log n); finding an arbitrary
--     entry is O(n) (`remove`). Only the MINIMUM is O(1). If a workload is
--     dominated by deleting a KNOWN element, the heap is the wrong structure
--     and a map of heaps, or a different design, is called for.
--   * TIES. With equal keys the order is unspecified. `newQueue` below exists
--     because that is a real problem for a task scheduler and not a footnote.
--
-- The heap array is 1-based so the children of node i are 2i and 2i+1 and the
-- parent is i/2. Zero-based would need `2i+1` and `2i+2` and an extra branch in
-- every sift, for a table that Lua indexes from 1 anyway.
--
-- COMPLEXITY
--
--   push        O(log n) worst case, O(1) when the new value is already the
--               new minimum
--   pop         O(log n)
--   peek        O(1)
--   replaceTop  O(log n) -- the decrease-key operation Dijkstra and A* need
--   build       O(n)     -- bottom-up heapify, see below
--   drain       O(n log n)
--   remove      O(n)     -- a scan to find it, then a sift to fix the hole

CisHeap = {}

--- Create an empty heap.
--- @param less function|nil  `less(a, b)` must be a STRICT weak ordering: true
---        when a sorts before b. Required to be consistent (antisymmetric and
---        transitive) or the sift loops do not terminate -- there is no way to
---        check that cheaply, so a broken comparator is a hang, not an error.
---        nil means plain `<` on the values themselves, which is a total order
---        for numbers and for strings.
--- @return table  the heap
function CisHeap.new(less)
    return {
        items = {},
        size = 0,
        less = less,
    }
end

local function before(h, a, b)
    if h.less then
        return h.less(a, b)
    end
    return a < b
end

-- Move the element at `index` up or down until the heap property holds.
local function sift(h, index)
    local items = h.items
    local n = h.size
    while true do
        local left = index * 2
        local right = left + 1
        local smallest = index
        if left <= n and before(h, items[left], items[smallest]) then
            smallest = left
        end
        if right <= n and before(h, items[right], items[smallest]) then
            smallest = right
        end
        if smallest == index then
            return
        end
        items[index], items[smallest] = items[smallest], items[index]
        index = smallest
    end
end

--- Add a value.
---@param h
---@param value
--- @return number  the new size
function CisHeap.push(h, value)
    local n = h.size + 1
    h.items[n] = value
    h.size = n
    -- Sift UP from the new leaf. Walking up is what makes insert O(log n) and
    -- not O(n): a value that belongs at the bottom never moves at all.
    while n > 1 do
        local parent = math.floor(n * 0.5)
        if before(h, h.items[n], h.items[parent]) then
            h.items[n], h.items[parent] = h.items[parent], h.items[n]
            n = parent
        else
            break
        end
    end
    return h.size
end

--- Remove and return the minimum.
---@param h
--- @return any  nil when the heap is empty. "Empty" has to be representable
---         because a work queue drains, and a sentinel value here would be a
---         value the caller has to check for anyway.
function CisHeap.pop(h)
    if h.size < 1 then
        return nil
    end
    local top = h.items[1]
    local last = h.items[h.size]
    h.items[h.size] = nil
    h.size = h.size - 1
    if h.size > 0 then
        -- Move the last leaf to the root and sift it DOWN. Replacing the root
        -- with the last element rather than shifting everything up is the whole
        -- reason pop is O(log n).
        h.items[1] = last
        sift(h, 1)
    end
    return top
end

--- The minimum, without removing it. O(1).
---@param h
--- @return any  nil when empty
function CisHeap.peek(h)
    if h.size < 1 then
        return nil
    end
    return h.items[1]
end

--- Replace the minimum in place.
---
--- The decrease-key operation. Dijkstra and A* both need it: a node whose
--- distance improves while it is still in the queue is updated in O(log n) here
--- rather than by pushing a duplicate and hoping the stale copy is skipped
--- later. That is the difference between an A* that is correct and one that is
--- correct only if you remember to check for duplicates on pop.
---
---@param h
---@param value
--- @return any  the new minimum; nil when the heap was empty, in which case
---         nothing was changed
function CisHeap.replaceTop(h, value)
    if h.size < 1 then
        return nil
    end
    h.items[1] = value
    -- Only ever sifts DOWN. Replacing the root can only make it too large for
    -- its position, never too small, and a sift-up pass would be a no-op that
    -- costs O(log n) anyway.
    sift(h, 1)
    return h.items[1]
end

--- Remove a specific value wherever it is.
---
--- O(n) to find it, because a binary heap has no secondary index and adding one
--- means the value has to be a node object the heap tracks, which changes what
--- the heap can hold. Honest cost, stated rather than hidden: this is the price
--- of the O(log n) push.
---@param h
---@param value
--- @return boolean  whether the value was found and removed
function CisHeap.remove(h, value)
    local items = h.items
    for i = 1, h.size do
        if items[i] == value then
            local last = items[h.size]
            items[h.size] = nil
            h.size = h.size - 1
            if i <= h.size then
                items[i] = last
                -- The hole can break the property in EITHER direction: the value
                -- that moved in from the end may belong higher (sift up) or
                -- lower (sift down). Try up first, and only sift down if it did
                -- not move -- so this is at most one O(log n) pass either way,
                -- not two.
                local j = i
                local moved = false
                while j > 1 do
                    local parent = math.floor(j * 0.5)
                    if before(h, items[j], items[parent]) then
                        items[j], items[parent] = items[parent], items[j]
                        j = parent
                        moved = true
                    else
                        break
                    end
                end
                if not moved then
                    sift(h, i)
                end
            end
            return true
        end
    end
    return false
end

--- How many values are queued. O(1).
---@param h
--- @return number
function CisHeap.size(h)
    return h.size
end

--- Is the heap empty?
---@param h
--- @return boolean
function CisHeap.isEmpty(h)
    return h.size < 1
end

--- Drop everything. The backing array is replaced rather than nil-filled: a
--- table does not shrink when its entries are nil'd, so a drained heap would
--- keep its peak allocation forever.
---@param h
--- @return nil  it mutates the heap in place; there is nothing to hand back
function CisHeap.clear(h)
    h.items = {}
    h.size = 0
end

--- Pop everything into a sorted array, cheapest element first.
---@param h
--- @return table  a NEW array; the heap is left empty
function CisHeap.drain(h)
    local out = {}
    local n = h.size
    for i = 1, n do
        out[i] = h.items[i]
    end
    table.sort(out, h.less)
    h.items = {}
    h.size = 0
    return out
end

--- Build a heap from an existing list in O(n).
---
--- Bottom-up heapify: start at the last PARENT (n/2, not n) and sift every
--- internal node down. Every leaf is already a valid heap of size one, so they
--- are never touched, and each sift is bounded by the height of its subtree.
--- The total is O(n) rather than the O(n log n) of n pushes -- the difference
--- is that push pays a full sift-up from the leaf every time, while heapify
--- pays one sift-down per node over a shrinking subtree.
---
--- The input list is NOT modified; the heap takes its own copy of the
--- references.
--- @param list table  array of values
--- @param less function|nil  as CisHeap.new
--- @return table  the heap
function CisHeap.build(list, less)
    local h = CisHeap.new(less)
    if type(list) ~= 'table' then
        return h
    end
    local n = #list
    for i = 1, n do
        h.items[i] = list[i]
    end
    h.size = n
    for i = math.floor(n * 0.5), 1, -1 do
        sift(h, i)
    end
    return h
end

-- ========================================================== PRIORITY QUEUE

--- A FIFO-ordered priority queue.
---
--- This exists because "put these tasks in priority order" is the actual use
--- and it is the one place the heap's unspecified tie order bites. Two items
--- with the same priority MUST come out in the order they went in, or a frame's
--- worth of scheduled work runs in a different order every time the heap happens
--- to arrange it -- which is the kind of nondeterminism that only reproduces on
--- someone else's machine.
---
--- So the queue wraps every entry with a monotonic sequence number and compares
--- priority first, sequence second. The sequence is what makes equal priorities
--- FIFO, and it is not optional: without it the ordering is whatever the sift
--- operations happened to produce.
---
--- The wrapper allocates one small table per enqueued item. That is a real cost
--- and it is paid here rather than in CisHeap, so the heap stays a container of
--- arbitrary values for a caller who has their own tie-break.
--- @return table  the queue; use enqueue / dequeue / peekQueue
--- @return table  a heap ordered by priority, then insertion order, so equal priorities dequeue first-in-first-out
function CisHeap.newQueue()
    local h = CisHeap.new(function(a, b)
        if a.priority == b.priority then
            return a.seq < b.seq
        end
        return a.priority < b.priority
    end)
    h.seq = 0
    return h
end

--- Add a value at a priority. Lower sorts first.
---@param q
---@param value
---@param priority
--- @return number  the new size
function CisHeap.enqueue(q, value, priority)
    if type(priority) ~= 'number' or priority ~= priority then
        priority = math.huge
    end
    q.seq = q.seq + 1
    return CisHeap.push(q, { value = value, priority = priority, seq = q.seq })
end

--- Remove and return the highest-priority (lowest number) value.
---@param q
--- @return any  nil when the queue is empty
function CisHeap.dequeue(q)
    local entry = CisHeap.pop(q)
    if not entry then
        return nil
    end
    return entry.value
end

--- The next value without removing it.
---@param q
--- @return any  nil when empty
function CisHeap.peekQueue(q)
    local entry = CisHeap.peek(q)
    if not entry then
        return nil
    end
    return entry.value
end

-- Binary min-heap, and the priority queue built on it.

local M = {}

--- Create an empty heap.
--- @param less function|nil  `less(a, b)` must be a STRICT weak ordering: true
--- @return table  the heap
function M.new(less)
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
--- @param h
--- @param value
--- @return number  the new size
function M.push(h, value)
    local n = h.size + 1
    h.items[n] = value
    h.size = n
    -- Sift UP from the new leaf. Walking up is what makes insert O(log n) and not O(n):
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
--- @param h
--- @return any  nil when the heap is empty. "Empty" has to be representable
function M.pop(h)
    if h.size < 1 then
        return nil
    end
    local top = h.items[1]
    local last = h.items[h.size]
    h.items[h.size] = nil
    h.size = h.size - 1
    if h.size > 0 then
        -- Move the last leaf to the root and sift it DOWN.
        h.items[1] = last
        sift(h, 1)
    end
    return top
end

--- The minimum, without removing it.
--- @param h
--- @return any  nil when empty
function M.peek(h)
    if h.size < 1 then
        return nil
    end
    return h.items[1]
end

--- Replace the minimum in place.
--- @param h
--- @param value
--- @return any  the new minimum; nil when the heap was empty, in which case
function M.replaceTop(h, value)
    if h.size < 1 then
        return nil
    end
    h.items[1] = value
    -- Only ever sifts DOWN. Replacing the root can only make it too large for its
    sift(h, 1)
    return h.items[1]
end

--- Remove a specific value wherever it is.
--- @param h
--- @param value
--- @return boolean  whether the value was found and removed
function M.remove(h, value)
    local items = h.items
    for i = 1, h.size do
        if items[i] == value then
            local last = items[h.size]
            items[h.size] = nil
            h.size = h.size - 1
            if i <= h.size then
                items[i] = last
                -- The hole can break the property in EITHER direction: the value that
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
--- @param h
--- @return number
function M.size(h)
    return h.size
end

--- Is the heap empty?
--- @param h
--- @return boolean
function M.isEmpty(h)
    return h.size < 1
end

--- Drop everything. The backing array is replaced rather than nil-filled: a table does
--- @param h
--- @return nil  it mutates the heap in place; there is nothing to hand back
function M.clear(h)
    h.items = {}
    h.size = 0
end

--- Pop everything into a sorted array, cheapest element first.
--- @param h
--- @return table  a NEW array; the heap is left empty
function M.drain(h)
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
--- @param list table  array of values
--- @param less function|nil  as CisHeap.new
--- @return table  the heap
function M.build(list, less)
    local h = M.new(less)
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


--- A FIFO-ordered priority queue.
--- @return table  the queue; use enqueue / dequeue / peekQueue
function M.newQueue()
    local h = M.new(function(a, b)
        if a.priority == b.priority then
            return a.seq < b.seq
        end
        return a.priority < b.priority
    end)
    h.seq = 0
    return h
end

--- Add a value at a priority. Lower sorts first.
--- @param q
--- @param value
--- @param priority
--- @return number  the new size
function M.enqueue(q, value, priority)
    if type(priority) ~= 'number' or priority ~= priority then
        priority = math.huge
    end
    q.seq = q.seq + 1
    return M.push(q, { value = value, priority = priority, seq = q.seq })
end

--- Remove and return the highest-priority (lowest number) value.
--- @param q
--- @return any  nil when the queue is empty
function M.dequeue(q)
    local entry = M.pop(q)
    if not entry then
        return nil
    end
    return entry.value
end

--- The next value without removing it.
--- @param q
--- @return any  nil when empty
function M.peekQueue(q)
    local entry = M.peek(q)
    if not entry then
        return nil
    end
    return entry.value
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisHeap = M
end

return M

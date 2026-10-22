-- A fixed-capacity ring buffer: push is O(1) and, once full, overwrites the
-- OLDEST entry. The shape for "the last N log lines", "the last N frame times",
-- "the last N positions" -- anything that must stay bounded however long the
-- server runs.
--
-- Function style like every other module (`ringbuffer.push(rb, v)`), and method
-- style too (`rb:push(v)`), because a buffer's metatable __index is this module.
--
-- Index 1 is always the OLDEST entry still held and size() the newest. A count
-- is kept explicitly, so nil is a storable value and never shortens the buffer.

local M = {}

local RingMT = { __index = M }

--- A new, empty buffer.
---@param capacity integer  at least 1
---@return table  the buffer
function M.new(capacity)
    if type(capacity) ~= 'number' or capacity < 1 or capacity % 1 ~= 0 or capacity == math.huge then
        error(('ringbuffer.new: capacity must be a whole number of at least 1, got %s'):format(tostring(capacity)), 2)
    end
    capacity = math.tointeger(capacity) or capacity
    return setmetatable({ _buf = {}, _head = 1, _count = 0, _cap = capacity }, RingMT)
end

--- Whether a value is a buffer made by this module.
---@param value any
---@return boolean
function M.isRingBuffer(value)
    return type(value) == 'table' and getmetatable(value) == RingMT
end

--- Append at the newest end.
---@param rb table  the buffer
---@param v any  any value, nil included
---@return any  the entry that was overwritten when the buffer was full, else nil
---@return boolean  whether an entry was overwritten (nil alone cannot say, since nil is storable)
function M.push(rb, v)
    local cap = rb._cap
    if rb._count < cap then
        local slot = (rb._head + rb._count - 1) % cap + 1
        rb._buf[slot] = v
        rb._count = rb._count + 1
        return nil, false
    end
    local head = rb._head
    local evicted = rb._buf[head]
    rb._buf[head] = v
    rb._head = head % cap + 1
    return evicted, true
end

--- Remove and return the OLDEST entry.
---@param rb table  the buffer
---@return any  the entry, or nil when empty
function M.shift(rb)
    if rb._count == 0 then
        return nil
    end
    local head = rb._head
    local v = rb._buf[head]
    rb._buf[head] = nil
    rb._head = head % rb._cap + 1
    rb._count = rb._count - 1
    return v
end

--- Remove and return the NEWEST entry.
---@param rb table  the buffer
---@return any  the entry, or nil when empty
function M.pop(rb)
    if rb._count == 0 then
        return nil
    end
    local slot = (rb._head + rb._count - 2) % rb._cap + 1
    local v = rb._buf[slot]
    rb._buf[slot] = nil
    rb._count = rb._count - 1
    return v
end

--- The entry at position i, 1 = oldest; a negative i counts from the newest (-1 = newest).
---@param rb table  the buffer
---@param i integer
---@return any  the entry, or nil outside 1..size
function M.get(rb, i)
    if type(i) ~= 'number' or i % 1 ~= 0 then
        return nil
    end
    local n = rb._count
    if i < 0 then
        i = n + i + 1
    end
    if i < 1 or i > n then
        return nil
    end
    return rb._buf[(rb._head + i - 2) % rb._cap + 1]
end

--- The oldest entry, without removing it.
---@param rb table  the buffer
---@return any
function M.peek(rb)
    return M.get(rb, 1)
end

--- The newest entry, without removing it.
---@param rb table  the buffer
---@return any
function M.peekLast(rb)
    return M.get(rb, -1)
end

--- Number of entries held.
---@param rb table  the buffer
---@return integer
function M.size(rb)
    return rb._count
end

--- The fixed capacity.
---@param rb table  the buffer
---@return integer
function M.capacity(rb)
    return rb._cap
end

--- Whether the next push will overwrite.
---@param rb table  the buffer
---@return boolean
function M.isFull(rb)
    return rb._count == rb._cap
end

--- Whether it holds nothing.
---@param rb table  the buffer
---@return boolean
function M.isEmpty(rb)
    return rb._count == 0
end

--- Drop every entry; the capacity is kept.
---@param rb table  the buffer
---@return table  the same buffer
function M.clear(rb)
    rb._buf = {}
    rb._head = 1
    rb._count = 0
    return rb
end

--- The entries oldest-first as a new array.
---@param rb table  the buffer
---@return table  an array with `n` set, so nil entries keep their place
function M.toArray(rb)
    local out = { n = rb._count }
    local buf, head, cap = rb._buf, rb._head, rb._cap
    for i = 1, rb._count do
        out[i] = buf[(head + i - 2) % cap + 1]
    end
    return out
end

RingMT.__len = M.size
RingMT.__tostring = function(rb)
    return ('RingBuffer(%s/%s)'):format(tostring(rb._count), tostring(rb._cap))
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisRingBuffer = M
end

return M

-- Sparse set with a generation counter: O(1) add, remove, and -- the point of it --

local M = {}

-- 2^53. Past this a generation counter can no longer be trusted to be distinct from
local MAX_GENERATION = 9007199254740992

-- The point of the structure is that clear is O(1), and the price is that it never
local SWEEP_FLOOR = 64

-- The slot map is WEAK-KEYED. A soft clear only bumps the generation, so every
-- value from the old generation is still a key here; with strong keys a
-- cleared set pinned everything it had ever held until the next sweep. A live
-- value is still held strongly by `dense`, so weakness never drops a member.
local SLOTS_MODE = { __mode = 'k' }

local function newSlots()
    return setmetatable({}, SLOTS_MODE)
end

--- An empty sparse set: O(1) add, has, remove, and an O(1) clear.
---@return table
function M.new()
    return {
        slots = newSlots(),    -- value -> { gen, index }
        dense = {},    -- index -> value, valid for 1..size
        size = 0,
        generation = 1,
        -- Slots ever written, live or stale.
        written = 0,
    }
end

-- Drop every slot that is not from the current generation.
local function sweepSlots(set)
    local live = newSlots()
    for value, slot in pairs(set.slots) do
        if slot.gen == set.generation then
            live[value] = slot
        end
    end
    set.slots = live
    set.written = set.size
end

--- Add a value.
---@param set table
---@param value any
---@return boolean  false for nil, NaN or a value already present
function M.add(set, value)
    -- NaN is no table key: the slot write below would raise after size had grown.
    if value == nil or value ~= value then
        return false
    end
    -- `or 0` so a set assembled by hand rather than by new() still works; a missing
    local written = set.written or 0
    if written > SWEEP_FLOOR and written > 2 * set.size then
        sweepSlots(set)
    end
    local slot = set.slots[value]
    if slot and slot.gen == set.generation then
        return false
    end
    set.size = set.size + 1
    set.dense[set.size] = value
    set.slots[value] = { gen = set.generation, index = set.size }
    set.written = (set.written or 0) + 1
    return true
end

--- Is the value in the set?
---@param set table
---@param value any
---@return boolean
function M.has(set, value)
    local slot = set.slots[value]
    if slot == nil then
        return false
    end
    return slot.gen == set.generation
end

--- Remove a value; the last element moves into its slot.
---@param set table
---@param value any
---@return boolean  false when it was not present
function M.remove(set, value)
    local slot = set.slots[value]
    if slot == nil or slot.gen ~= set.generation then
        return false
    end
    -- Swap the last element into the hole.
    local last = set.dense[set.size]
    set.dense[slot.index] = last
    -- Update the moved element's slot IN PLACE rather than allocating a replacement.
    local lastSlot = set.slots[last]
    lastSlot.index = slot.index
    set.dense[set.size] = nil
    set.slots[value] = nil
    set.size = set.size - 1
    -- The slot really is gone, so the counter has to say so.
    if set.written then
        set.written = set.written - 1
    end
    return true
end

-- bug: a caller that needs a deterministic order across removals wants a
--- The value at a dense index. The order changes on remove.
---@param set table
---@param index integer
---@return any  nil outside 1..count
function M.at(set, index)
    if type(index) ~= 'number' or index < 1 or index > set.size then
        return nil
    end
    return set.dense[index]
end

--- Visit every value present when the walk started.
---@param set table
---@param fn fun(value: any, index: integer)
---@return integer  how many were visited
function M.each(set, fn)
    if type(fn) ~= 'function' then
        return 0
    end
    -- Capture the bound first: a visitor that adds to the set grows `size`, and reading
    local n = set.size
    -- Walk a copy: a visitor that removes the value it is handed moves the last
    -- value into the hole, and the live array would skip it and then run off its end.
    local values = {}
    for i = 1, n do
        values[i] = set.dense[i]
    end
    for i = 1, n do
        fn(values[i], i)
    end
    return n
end

--- The values, as a new array.
---@param set table
---@return any[]  a NEW array
function M.toArray(set)
    local out = {}
    for i = 1, set.size do
        out[i] = set.dense[i]
    end
    return out
end

--- Empty the set in O(1). The old members are no longer referenced.
---@param set table
---@param hard? boolean  also drop the stale slots
---@return integer  the new generation
function M.clear(set, hard)
    if hard then
        set.slots = newSlots()
        set.written = 0
    end
    -- A fresh dense array in BOTH modes: it is one allocation, so the clear stays
    -- O(1), and the old array was the other place a cleared set kept its former
    -- members alive.
    set.dense = {}
    set.size = 0
    if set.generation >= MAX_GENERATION then
        -- Unreachable, and handled anyway because "unreachable" is a property of the
        set.slots = newSlots()
        set.dense = {}
        set.written = 0
        set.generation = 1
        return 1
    end
    set.generation = set.generation + 1
    return set.generation
end

--- How many values are in the set.
---@param set table
---@return integer
function M.count(set)
    return set.size
end

--- Is the set empty?
---@param set table
---@return boolean
function M.isEmpty(set)
    return set.size < 1
end

--- Debug only: slots held, live or stale. O(slots).
---@param set table
---@return integer  live plus stale slots
function M.staleCount(set)
    -- Counting is O(slots) and defeats the purpose of the structure, so this is a debug
    local n = 0
    for _ in pairs(set.slots) do
        n = n + 1
    end
    return n
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisSparse = M
end

return M

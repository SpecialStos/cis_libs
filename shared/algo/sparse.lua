-- Sparse set with a generation counter: O(1) add, remove, and -- the point of it --

local M = {}

-- 2^53. Past this a generation counter can no longer be trusted to be distinct from
local MAX_GENERATION = 9007199254740992

-- The point of the structure is that clear is O(1), and the price is that it never
local SWEEP_FLOOR = 64

function M.new()
    return {
        slots = {},    -- value -> { gen, index }
        dense = {},    -- index -> value, valid for 1..size
        size = 0,
        generation = 1,
        -- Slots ever written, live or stale.
        written = 0,
    }
end

-- Drop every slot that is not from the current generation.
local function sweepSlots(set)
    local live = {}
    for value, slot in pairs(set.slots) do
        if slot.gen == set.generation then
            live[value] = slot
        end
    end
    set.slots = live
    set.written = set.size
end

function M.add(set, value)
    if value == nil then
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

function M.has(set, value)
    local slot = set.slots[value]
    if slot == nil then
        return false
    end
    return slot.gen == set.generation
end

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
function M.at(set, index)
    if type(index) ~= 'number' or index < 1 or index > set.size then
        return nil
    end
    return set.dense[index]
end

function M.each(set, fn)
    if type(fn) ~= 'function' then
        return 0
    end
    -- Capture the bound first: a visitor that adds to the set grows `size`, and reading
    local n = set.size
    for i = 1, n do
        fn(set.dense[i], i)
    end
    return n
end

function M.toArray(set)
    local out = {}
    for i = 1, set.size do
        out[i] = set.dense[i]
    end
    return out
end

function M.clear(set, hard)
    if hard then
        set.dense = {}
        set.slots = {}
        set.written = 0
    end
    set.size = 0
    if set.generation >= MAX_GENERATION then
        -- Unreachable, and handled anyway because "unreachable" is a property of the
        set.slots = {}
        set.dense = {}
        set.written = 0
        set.generation = 1
        return 1
    end
    set.generation = set.generation + 1
    return set.generation
end

function M.count(set)
    return set.size
end

function M.isEmpty(set)
    return set.size < 1
end

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

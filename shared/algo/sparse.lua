-- Sparse set with a generation counter: O(1) add, remove, and -- the point of
-- it -- O(1) clear.
--
-- PURE. The set is a value. Nothing here is a module local.
--
-- THE PROBLEM THIS SOLVES
--
-- "Empty this collection" is written a hundred different ways and almost all of
-- them are O(n) or worse. The obvious one is
--
--     for k in pairs(players) do players[k] = nil end
--
-- which is a full hash traversal, and it is not free in a way that is easy to
-- see from the call site: nil-ing an entry out of a Lua table does not shrink
-- the table, and the next insert into that same table can trigger a rehash of
-- the whole thing. So the clear is O(n) AND the work that follows it is O(n)
-- again.
--
-- At FiveM scale that is not a micro-optimisation. PlayerDropped in a loop, a
-- zone resync, an inventory rebuild, a resource restart: each of those wants a
-- clean slate, and each of them is O(n) in the number of players with an
-- unbounded constant that nobody can predict. A server that has been up for six
-- hours has a players table that has been rehashed a hundred times, and its
-- clear cost is not the clear cost of a fresh one.
--
-- The fix is to stop deleting anything. Each slot stores the GENERATION it was
-- written in, and the set has a current generation. Clearing increments the
-- generation, and every slot from before the increment is stale by definition.
-- That is one addition, and the whole collection is logically empty.
--
-- The dense array is what keeps the collection iterable. `pairs()` over a
-- generation-tagged hash is wrong -- it would walk every slot ever written,
-- including all the stale ones, which is exactly the O(n) this is here to
-- avoid. So there are two structures: a hash for O(1) membership and an array
-- for ordered, allocation-free iteration. The array is only ever read up to
-- `size`, which the generation bump resets, so a clear is `size = 0` plus one
-- increment. The stale entries in the array are overwritten by the next adds.
--
-- COST OF A CLEAR
--
--   O(1) to make the set empty
--   O(1) to iterate whatever was added since
--   O(n) ONCE, at the next rehash, because the array is full of pointers to
--      values that are no longer referenced by the set
--
-- That last line is the honest cost and it is why `clear(set, true)` exists: a
-- set that is cleared once an hour and refilled to 50 entries should hand the
-- old array to the collector rather than keep a 50k-slot table alive for it.
--
-- DUPLICATES
--
-- This is a SET, not a map: a value is either in it or it is not, and adding a
-- value twice is a no-op. Two separate players with the same server id are the
-- same key and there is no way to hold both -- if a caller needs that, it needs a
-- map (CisPending, CisLRU, the limiters), not this.
--
-- The one value that cannot be stored is nil, because nil is what "absent"
-- looks like in a Lua table. add(set, nil) is a documented no-op.

CisSparse = {}

-- 2^53. Past this a generation counter can no longer be trusted to be distinct
-- from every earlier one in a double, and a stale slot could start looking live.
-- It is not reachable in any real process (at one clear per millisecond it is
-- 285 million years) and it costs one comparison per clear to be sure of that.
local MAX_GENERATION = 9007199254740992

-- The point of the structure is that clear is O(1), and the price is that it
-- never deletes anything -- so a set that is cleared repeatedly grows its slots
-- table without bound while count() stays at 0. That is the worst kind of leak:
-- the API reports the set as empty for the whole time it is growing.
--
-- The sweep is therefore LAZY, and it cannot live in clear(): after a clear
-- `size` is 0, so a `stale > 2 * size` test would fire on every single clear
-- and turn the O(1) clear into the O(n) traversal this file exists to avoid.
--
-- So the check runs in add(), where size has grown back, and it is paid for out
-- of the adds that caused it: after a sweep `written` equals `size`, and another
-- sweep needs `size` to have doubled. Amortised, that is one comparison per add
-- and a traversal per doubling -- still O(1) amortised, which is the claim the
-- header makes.
--
-- The floor keeps a tiny set from thrashing. Without it, a set that holds one
-- entry between clears sweeps on every single add, and a sweep of a growing
-- table costs more than the adds it is amortising against.
local SWEEP_FLOOR = 64

--- Create an empty set.
--- @return table  { slots, dense, size, generation, written }
--- @return table  a fresh empty set: { slots, dense, size, generation, written }
function CisSparse.new()
    return {
        slots = {},    -- value -> { gen, index }
        dense = {},    -- index -> value, valid for 1..size
        size = 0,
        generation = 1,
        -- Slots ever written, live or stale. Maintained in O(1) by add and
        -- remove so the sweep test never has to walk the table to find out.
        written = 0,
    }
end

-- Drop every slot that is not from the current generation. O(written), and
-- called only when written has already grown past the threshold that makes it
-- worth it.
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

--- Add a value.
---@param set
---@param value
--- @return boolean  true when the value was not already present. The return is
---         what lets a caller use the set as a "is this new" filter:
---         `if CisSparse.add(set, id) then onFirstSight(id) end`
function CisSparse.add(set, value)
    if value == nil then
        return false
    end
    -- `or 0` so a set assembled by hand rather than by new() still works; a
    -- missing counter would otherwise compare nil against a number and raise
    -- inside the module's hottest function.
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

--- Is a value present?
---@param set
---@param value
--- @return boolean
function CisSparse.has(set, value)
    local slot = set.slots[value]
    if slot == nil then
        return false
    end
    return slot.gen == set.generation
end

--- Remove a value.
---@param set
---@param value
--- @return boolean  whether it was there to remove
function CisSparse.remove(set, value)
    local slot = set.slots[value]
    if slot == nil or slot.gen ~= set.generation then
        return false
    end
    -- Swap the last element into the hole. That is what keeps removal O(1):
    -- shifting everything after the hole down is the O(n) that made a plain
    -- table the wrong structure, and the order of a SET is not part of its
    -- contract, so nothing observable is lost.
    local last = set.dense[set.size]
    set.dense[slot.index] = last
    -- Update the moved element's slot IN PLACE rather than allocating a
    -- replacement. Removal is the operation that runs per player per tick in
    -- the streaming loops, and a fresh table per removal is 512 tables a frame
    -- of pure garbage for a bookkeeping update.
    local lastSlot = set.slots[last]
    lastSlot.index = slot.index
    set.dense[set.size] = nil
    set.slots[value] = nil
    set.size = set.size - 1
    -- The slot really is gone, so the counter has to say so. Without this the
    -- sweep threshold drifts upward as a caller removes instead of adds, and
    -- the set pays for a sweep long after the slots are gone.
    if set.written then
        set.written = set.written - 1
    end
    return true
end

--- The value at a 1-based position, in insertion order modulo removals.
---
--- The order is stable for adds and scrambled by removes, because remove swaps
--- the last element into the hole. That is a feature of the structure, not a
-- bug: a caller that needs a deterministic order across removals wants a
--- sorted list, not a set.
---@param set
---@param index
--- @return any  nil when `index` is out of range
function CisSparse.at(set, index)
    if type(index) ~= 'number' or index < 1 or index > set.size then
        return nil
    end
    return set.dense[index]
end

--- Call `fn(value, index)` for every value, in dense order.
---
--- The walk touches exactly `size` entries, never more. It is not a `pairs()`
--- over the slots, which is the entire reason the dense array exists.
---@param set
---@param fn
--- @return number  how many values were visited
function CisSparse.each(set, fn)
    if type(fn) ~= 'function' then
        return 0
    end
    -- Capture the bound first: a visitor that adds to the set grows `size`,
    -- and reading set.size on every iteration would then walk past the entries
    -- that were just created, whose slots are valid but whose position has not
    -- been reached yet.
    local n = set.size
    for i = 1, n do
        fn(set.dense[i], i)
    end
    return n
end

--- The live values as a plain array.
---
--- A copy, because the dense array has stale entries past `size` and handing
--- the caller the live table would expose them. The copy is O(size), which is
--- the point: after this the caller can iterate with pairs(), sort, serialise,
--- or anything else without a snapshot being taken mid-change.
---@param set
--- @return table
function CisSparse.toArray(set)
    local out = {}
    for i = 1, set.size do
        out[i] = set.dense[i]
    end
    return out
end

--- Empty the set in O(1).
---
--- The slots are NOT swept here, deliberately. At this point `size` is 0, so a
--- "stale slots outnumber live ones" test would fire on every clear and turn
--- the O(1) clear into the O(n) traversal the structure exists to avoid. The
--- sweep happens lazily during `add`, where `size` has grown back and the cost
--- amortises against the adds that caused it. See SWEEP_FLOOR above.
---
--- @param hard boolean|nil  when true, also drop the dense array so the memory
---        goes back to the collector. The O(1) part is the same either way --
---        dropping a table reference is one assignment -- but the COLLECTOR only
---        reclaims the old array at its next cycle, so `hard` is about when the
---        memory comes back, not about the cost of the call.
---@param set
--- @return number  the generation the set is now on
function CisSparse.clear(set, hard)
    if hard then
        set.dense = {}
        set.slots = {}
        set.written = 0
    end
    set.size = 0
    if set.generation >= MAX_GENERATION then
        -- Unreachable, and handled anyway because "unreachable" is a property of
        -- the caller's uptime and not of this code. Below this point the
        -- generation is still exactly representable and still distinct from
        -- every value any live slot holds.
        set.slots = {}
        set.dense = {}
        set.written = 0
        set.generation = 1
        return 1
    end
    set.generation = set.generation + 1
    return set.generation
end

--- How many values are in the set. O(1).
---@param set
--- @return number
function CisSparse.count(set)
    return set.size
end

--- Is the set empty?
---@param set
--- @return boolean
function CisSparse.isEmpty(set)
    return set.size < 1
end

--- The number of hash slots ever written, including stale ones. Only useful as
--- a diagnostic: it is what a caller watches to decide whether the next clear
--- should be `hard`.
---
--- It is BOUNDED now. It used to grow one entry per add for the life of the
--- process while `count()` reported 0, which is the shape of a leak the API
--- actively hides. See SWEEP_FLOOR for why the sweep is not in clear().
---@param set
--- @return number
function CisSparse.staleCount(set)
    -- Counting is O(slots) and defeats the purpose of the structure, so this
    -- is a debug helper and is named like one. It is here because "is my set
    -- leaking" is otherwise unanswerable: count() is always correct and always
    -- small, which is exactly what a leak looks like.
    local n = 0
    for _ in pairs(set.slots) do
        n = n + 1
    end
    return n
end

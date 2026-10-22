-- A Set: membership in O(1), iteration in insertion order, and the algebra
-- (union, intersect, difference) returning NEW sets.
--
-- Function style like every other module -- `set.add(s, v)` -- and, because a
-- set carries a metatable whose __index is this module, method style too:
-- `s:add(v)`. The two are the same function.
--
-- ORDER. values() answers members in the order they were first added, and
-- remove keeps that order (a tombstone is compacted away lazily, so a remove is
-- O(1) amortised and never reshuffles what is left). Deterministic order is
-- what makes a set safe to drive a UI list or a test from.
--
-- MEMBERS. Anything Lua can use as a table key: nil and NaN cannot be, and are
-- refused by name rather than silently dropped.

local M = {}

local SetMT = { __index = M }

-- A compaction is due when more than half the list is tombstones.
local function compact(s)
    local list, out, n = s._list, {}, 0
    local index = s._index
    for i = 1, s._slots do
        local v = list[i]
        if v ~= nil and index[v] ~= nil then
            n = n + 1
            out[n] = v
            index[v] = n
        end
    end
    s._list = out
    s._slots = n
end

local function badMember(v)
    if v == nil then
        return 'a set cannot hold nil'
    end
    if v ~= v then
        return 'a set cannot hold NaN (it is not equal to itself, so it can never be found)'
    end
    return nil
end

--- A new set, optionally filled from an array.
---@param list? table  an array of members; nil and NaN entries are skipped. `list.n` is honoured, so holes do not stop the fill
---@return table  the set
function M.new(list)
    local s = setmetatable({ _index = {}, _list = {}, _slots = 0, _count = 0 }, SetMT)
    if type(list) == 'table' then
        local n = type(list.n) == 'number' and list.n or #list
        for i = 1, n do
            local v = list[i]
            if badMember(v) == nil then
                M.add(s, v)
            end
        end
    end
    return s
end

--- Whether a value is a set made by this module.
---@param value any
---@return boolean
function M.isSet(value)
    return type(value) == 'table' and getmetatable(value) == SetMT
end

--- Add a member.
---@param s table  the set
---@param v any  the member
---@return boolean|nil  true when it was added, false when it was already there
---@return string|nil  why, for nil or NaN
function M.add(s, v)
    local why = badMember(v)
    if why then
        return nil, why
    end
    if s._index[v] ~= nil then
        return false
    end
    local slot = s._slots + 1
    s._slots = slot
    s._list[slot] = v
    s._index[v] = slot
    s._count = s._count + 1
    return true
end

--- Remove a member.
---@param s table  the set
---@param v any  the member
---@return boolean  true when it was there
function M.remove(s, v)
    if v == nil or v ~= v then
        return false
    end
    local slot = s._index[v]
    if slot == nil then
        return false
    end
    s._index[v] = nil
    s._list[slot] = nil
    s._count = s._count - 1
    if s._count == 0 then
        s._list = {}
        s._slots = 0
    elseif s._slots > 8 and s._count * 2 < s._slots then
        compact(s)
    end
    return true
end

--- Membership test.
---@param s table  the set
---@param v any
---@return boolean
function M.has(s, v)
    if v == nil or v ~= v then
        return false
    end
    return s._index[v] ~= nil
end

--- Number of members.
---@param s table  the set
---@return integer
function M.size(s)
    return s._count
end

--- The members as a new array, in insertion order.
---@param s table  the set
---@return table  a dense array with `n` set
function M.values(s)
    local out, n = {}, 0
    local list, index = s._list, s._index
    for i = 1, s._slots do
        local v = list[i]
        if v ~= nil and index[v] == i then
            n = n + 1
            out[n] = v
        end
    end
    out.n = n
    return out
end

--- Remove every member.
---@param s table  the set
---@return table  the same set
function M.clear(s)
    s._index = {}
    s._list = {}
    s._slots = 0
    s._count = 0
    return s
end

--- Members of either set: a's in a's order, then b's new ones in b's order.
---@param a table  a set
---@param b table  a set
---@return table  a NEW set
function M.union(a, b)
    local out = M.new()
    local av, bv = M.values(a), M.values(b)
    for i = 1, av.n do M.add(out, av[i]) end
    for i = 1, bv.n do M.add(out, bv[i]) end
    return out
end

--- Members of both sets, in a's order.
---@param a table  a set
---@param b table  a set
---@return table  a NEW set
function M.intersect(a, b)
    local out = M.new()
    local av = M.values(a)
    local bIndex = b._index
    for i = 1, av.n do
        if bIndex[av[i]] ~= nil then M.add(out, av[i]) end
    end
    return out
end

--- Members of a that are not in b, in a's order.
---@param a table  a set
---@param b table  a set
---@return table  a NEW set
function M.difference(a, b)
    local out = M.new()
    local av = M.values(a)
    local bIndex = b._index
    for i = 1, av.n do
        if bIndex[av[i]] == nil then M.add(out, av[i]) end
    end
    return out
end

--- Whether every member of a is in b.
---@param a table  a set
---@param b table  a set
---@return boolean
function M.isSubset(a, b)
    if a._count > b._count then
        return false
    end
    local bIndex = b._index
    for v in pairs(a._index) do
        if bIndex[v] == nil then return false end
    end
    return true
end

--- Same members, order ignored.
---@param a table  a set
---@param b table  a set
---@return boolean
function M.equals(a, b)
    return a._count == b._count and M.isSubset(a, b)
end

SetMT.__len = M.size
SetMT.__tostring = function(s)
    return ('Set(%d)'):format(s._count)
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisSet = M
end

return M

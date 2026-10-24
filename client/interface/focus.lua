-- NUI focus, as a stack.
--
-- SetNuiFocus is one global switch per resource, and several components can
-- want it at once: a context menu opens an input dialog, which is answered,
-- and the menu underneath must get its cursor back. So nobody calls the
-- natives but this file. A component PUSHES an entry when it opens and POPS it
-- when it closes, from wherever it is in the stack; the natives always reflect
-- the TOP entry, and an empty stack releases focus entirely.
--
-- ESCAPE goes to the top entry that has an onEscape handler. The page only
-- reports that Escape was pressed; which component that cancels is decided
-- here, so a dialog over a menu closes the dialog and leaves the menu.
--
-- Focus can never be stranded: an owner's entries are popped when that
-- resource stops, everything is released when cis_libs stops or the page
-- reloads, and every blocking component pops in the same path that resolves
-- its promise (see I.settle in each file).

local I = CisInterface
local F = {}
I.focus = F

local stack = {}
-- What the natives were last told, so a pop that changes nothing is free.
local applied = { focus = false, cursor = false, keepInput = false }

local function apply()
    local top = stack[#stack]
    local want = {
        focus = top ~= nil,
        cursor = top ~= nil and top.cursor ~= false,
        keepInput = top ~= nil and top.keepInput == true,
    }
    if want.focus ~= applied.focus or want.cursor ~= applied.cursor then
        SetNuiFocus(want.focus, want.cursor)
    end
    if want.keepInput ~= applied.keepInput then
        SetNuiFocusKeepInput(want.keepInput)
    end
    applied = want
end

local function indexOf(key)
    for i = #stack, 1, -1 do
        if stack[i].key == key then
            return i
        end
    end
    return nil
end

--- @param key string  one entry per key; pushing a key again moves it to the top
--- @param opts table|nil  { cursor = true, keepInput = false, owner, onEscape = fn }
function F.push(key, opts)
    opts = opts or {}
    local at = indexOf(key)
    if at then
        table.remove(stack, at)
    end
    stack[#stack + 1] = {
        key = key,
        cursor = opts.cursor ~= false,
        keepInput = opts.keepInput == true,
        owner = opts.owner or 'cis_libs',
        onEscape = opts.onEscape,
    }
    apply()
    return #stack
end

function F.pop(key)
    local at = indexOf(key)
    if not at then
        return false
    end
    table.remove(stack, at)
    apply()
    return true
end

function F.has(key)
    return indexOf(key) ~= nil
end

function F.top()
    local top = stack[#stack]
    return top and top.key or nil
end

function F.stack()
    local out = {}
    for i = 1, #stack do
        out[i] = stack[i].key
    end
    return out
end

-- Escape: the topmost entry with a handler decides. A handler that returns
-- false (a menu with canClose = false) swallows it.
function F.escape()
    for i = #stack, 1, -1 do
        local entry = stack[i]
        if type(entry.onEscape) == 'function' then
            local ok, err = pcall(entry.onEscape)
            if not ok then
                I.log('error', ('escape handler for %s raised: %s'):format(entry.key, tostring(err)))
                F.pop(entry.key)
            end
            return entry.key
        end
    end
    return nil
end

-- Safety net after the components have cleaned up: nothing a stopped
-- resource opened may keep the cursor.
function F.releaseOwner(owner)
    local changed = false
    for i = #stack, 1, -1 do
        if stack[i].owner == owner then
            table.remove(stack, i)
            changed = true
        end
    end
    if changed then
        apply()
    end
    return changed
end

function F.clear()
    stack = {}
    -- Forced through even if we believe focus is already off: this is the
    -- path that runs when something else may have touched the natives.
    applied = { focus = true, cursor = true, keepInput = true }
    apply()
end

-- Only the live page's Escape: it carries the session token (nui.lua), so
-- another frame posting here cannot cancel the top dialog.
I.on('escape', { token = '?string' }, function(data)
    if I.isSession(data.token) then
        F.escape()
    end
end)

I.onStop(function(resource, all)
    if all then
        F.clear()
    else
        F.releaseOwner(resource)
    end
end)

I.onReset(function()
    F.clear()
end)

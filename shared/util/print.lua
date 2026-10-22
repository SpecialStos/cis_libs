-- Levelled console output: print.error / warn / info / verbose / debug.
--
--   local print = Cis.require('print')
--   print.info('loaded', count, 'shops')
--   print.debug('state', someTable)            -- tables are JSON-encoded
--
-- THE LEVEL is read per resource from the convar `cis:printlevel:<resource>`,
-- else the global `cis:printlevel`, else 'info'. Levels, most to least severe:
-- error, warn, info, verbose, debug; a message prints when its level is at or
-- above the configured one. On the client, set the convar with `setr` so it
-- replicates. The level is read once, at load; call `print.refresh()` after
-- changing a convar at runtime, or `print.setLevel(name)` to override.
--
-- A FILTERED CALL COSTS ONE COMPARISON. The check runs before anything is
-- converted, concatenated or encoded, so `print.debug(hugeTable)` on a server
-- at 'info' does no work. For a message that is expensive to BUILD, guard the
-- building too: `if print.isEnabled('debug') then print.debug(dump()) end`.
--
-- Output goes through the global `print` with a colour prefix (^1 error, ^3
-- warn, ^7 info, ^4 verbose, ^6 debug) and a ^7 reset, so a coloured message
-- never bleeds into the next console line.

local M = {}

local LEVELS = { error = 1, warn = 2, info = 3, verbose = 4, debug = 5 }
local NAMES = { 'error', 'warn', 'info', 'verbose', 'debug' }
local PREFIX = { '^1[ERROR]', '^3[WARN]', '^7[INFO]', '^4[VERBOSE]', '^6[DEBUG]' }
local DEFAULT = 3

local current = DEFAULT
local source = 'default'

local function convar(name)
    if type(GetConvar) ~= 'function' then
        return ''
    end
    local ok, v = pcall(GetConvar, name, '')
    if ok and type(v) == 'string' then
        return (v:gsub('^%s+', ''):gsub('%s+$', ''))
    end
    return ''
end

local function resourceName()
    if type(GetCurrentResourceName) == 'function' then
        local ok, name = pcall(GetCurrentResourceName)
        if ok and type(name) == 'string' then
            return name
        end
    end
    return nil
end

-- A level name, any case, or its number 1-5.
local function toLevel(value)
    if type(value) == 'number' then
        if value % 1 == 0 and value >= 1 and value <= 5 then
            return math.tointeger(value) or value
        end
        return nil
    end
    if type(value) ~= 'string' then
        return nil
    end
    local lower = value:lower()
    if LEVELS[lower] then
        return LEVELS[lower]
    end
    local n = tonumber(value)
    if n then
        return toLevel(n)
    end
    return nil
end

local function stringify(v)
    if type(v) == 'table' then
        local codec = json
        if type(codec) == 'table' and type(codec.encode) == 'function' then
            local ok, text = pcall(codec.encode, v, { indent = true })
            if ok and type(text) == 'string' then
                return text
            end
        end
    end
    return tostring(v)
end

local function emit(level, ...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do
        parts[i] = stringify((select(i, ...)))
    end
    print(('%s %s^7'):format(PREFIX[level], table.concat(parts, '\t')))
end

--- Re-read the level from the convars.
---@return string  the level now in force
---@return string  where it came from: the convar name, or 'default'
function M.refresh()
    local res = resourceName()
    local candidates = {}
    if res then
        candidates[1] = 'cis:printlevel:' .. res
    end
    candidates[#candidates + 1] = 'cis:printlevel'
    current, source = DEFAULT, 'default'
    for _, name in ipairs(candidates) do
        local raw = convar(name)
        if raw ~= '' then
            local level = toLevel(raw)
            if level then
                current, source = level, name
                break
            end
            print(('^3[WARN] cis_libs print: convar %s is %q, which is not a level. Use one of: %s^7')
                :format(name, raw, table.concat(NAMES, ', ')))
        end
    end
    return NAMES[current], source
end

--- Override the level for this resource until the next refresh.
---@param level string|integer  'error', 'warn', 'info', 'verbose', 'debug', or 1-5
---@return boolean|nil  true once set
---@return string|nil  why, for an unknown level
function M.setLevel(level)
    local l = toLevel(level)
    if not l then
        return nil, ('%s is not a level. Use one of: %s'):format(tostring(level), table.concat(NAMES, ', '))
    end
    current, source = l, 'setLevel'
    return true
end

--- The level in force.
---@return string  its name
---@return string  where it came from
function M.getLevel()
    return NAMES[current], source
end

--- Whether a message at this level would print.
---@param level string|integer
---@return boolean  false for an unknown level
function M.isEnabled(level)
    local l = toLevel(level)
    return l ~= nil and l <= current
end

--- Print at level error. Arguments are joined with tabs; a table is JSON-encoded.
---@param ... any
---@return nil
function M.error(...)
    if current < 1 then return end
    emit(1, ...)
end

--- Print at level warn.
---@param ... any
---@return nil
function M.warn(...)
    if current < 2 then return end
    emit(2, ...)
end

--- Print at level info.
---@param ... any
---@return nil
function M.info(...)
    if current < 3 then return end
    emit(3, ...)
end

--- Print at level verbose.
---@param ... any
---@return nil
function M.verbose(...)
    if current < 4 then return end
    emit(4, ...)
end

--- Print at level debug.
---@param ... any
---@return nil
function M.debug(...)
    if current < 5 then return end
    emit(5, ...)
end

M.refresh()

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisPrint = M
end

return M

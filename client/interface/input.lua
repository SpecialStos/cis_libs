-- Input dialog. Blocking: an array of values (one per row, nil for an empty
-- optional field) or nil on cancel.
--
-- Rows are copied field by field into what the page needs, so nothing the
-- caller put in a row (a function, a huge table) crosses to the page. The
-- answer is checked here against EVERY rule the page enforces -- type, offered
-- option, required, number and length bounds, maxSelectedValues, duplicates,
-- date, time and colour formats -- because the page is a browser and anything
-- in it can post any answer. An answer that fails is refused: the dialog stays
-- open AND the page is told which field, so it shows the error rather than
-- sitting there with nothing to say.
--
-- THE PAGE NEVER CLOSES THE DIALOG ITSELF. It used to close on submit and
-- then post the answer; an answer Lua refused (or a fetch that was lost) left
-- the cursor and focus up over an invisible dialog. Now it closes when Lua
-- settles and says so.
--
-- A SELECTION IS AN INDEX. Options cross to the page as 1..n and come back as
-- 1..n; the caller's own values never make the round trip. A JavaScript
-- number cannot hold a Steam64 id, so a value above 2^53 used to come back
-- rounded, fail the exact check, and strand the dialog.

local I = CisInterface

local TYPES = {
    input = 'string', textarea = 'string', color = 'string', date = 'string', time = 'string',
    number = 'number', slider = 'number', checkbox = 'boolean',
    select = 'option', ['multi-select'] = 'options', ['date-range'] = 'range',
}
local SIZES = { xs = true, sm = true, md = true, lg = true, xl = true }
local MAX_ROWS = 32
local MAX_OPTIONS = 200
-- The longest text a field takes when the row sets no maxLength, in the units
-- the page counts (UTF-16), and the page gets the same number as its maxlength.
local MAX_TEXT = 16384
local current = nil -- { id, owner, rows, allowCancel, p }

local function primitive(v)
    local t = type(v)
    return t == 'string' or t == 'number' or t == 'boolean'
end

local function readOptions(list)
    local out = {}
    if type(list) ~= 'table' then
        return out
    end
    for _, o in ipairs(list) do
        if #out >= MAX_OPTIONS then break end
        if type(o) == 'table' and (type(o.value) == 'string' or type(o.value) == 'number') then
            out[#out + 1] = { value = o.value, label = I.str(o.label, 256) or I.str(o.value, 256) or '' }
        elseif type(o) == 'string' or type(o) == 'number' then
            out[#out + 1] = { value = o, label = I.str(o, 256) or '' }
        end
    end
    return out
end

local function indexOf(options, v)
    for i, o in ipairs(options) do
        if o.value == v then return i end
    end
    return nil
end

local function readDefault(v)
    if primitive(v) then
        return type(v) == 'string' and I.str(v, 4096) or v
    end
    if type(v) == 'table' then
        local out = {}
        for i = 1, math.min(#v, MAX_OPTIONS) do
            if primitive(v[i]) then out[#out + 1] = v[i] end
        end
        return out
    end
    return nil
end

local function count(v)
    return type(v) == 'number' and v == v and v >= 0 and math.floor(v) or nil
end

local function readRow(row)
    if type(row) == 'string' then
        row = { type = 'input', label = row }
    end
    if type(row) ~= 'table' then
        return nil
    end
    local kind = TYPES[row.type] and row.type or 'input'
    local minv = type(row.min) == 'number' and row.min or I.str(row.min, 32)
    local maxv = type(row.max) == 'number' and row.max or I.str(row.max, 32)
    if kind == 'slider' then
        minv = type(minv) == 'number' and minv or 0
        maxv = type(maxv) == 'number' and maxv or 100
    end
    -- LENGTHS. An input's min/max are its length, as in ox_lib. A textarea's
    -- min/max are ROW counts, as in ox_lib: `{ min = 3, max = 10, autosize }`
    -- used to reject "ab" and cap the text at ten characters. Either takes an
    -- explicit minLength / maxLength.
    local minLength = count(row.minLength)
    local maxLength = count(row.maxLength)
    if kind == 'input' then
        minLength = minLength or count(minv)
        maxLength = maxLength or count(maxv)
    end
    if kind == 'input' or kind == 'textarea' then
        maxLength = math.min(maxLength or MAX_TEXT, MAX_TEXT)
    end
    return {
        type = kind,
        label = I.str(row.label, 256) or '',
        description = I.str(row.description, 1024),
        placeholder = I.str(row.placeholder, 256),
        icon = I.icon(row.icon),
        required = row.required == true,
        disabled = row.disabled == true,
        default = readDefault(row.default),
        min = minv,
        max = maxv,
        minLength = minLength,
        maxLength = maxLength,
        step = I.num(row.step, 0),
        precision = I.num(row.precision, 0, 10),
        password = row.password == true,
        checked = row.checked == true,
        options = (kind == 'select' or kind == 'multi-select') and readOptions(row.options) or nil,
        maxSelectedValues = I.num(row.maxSelectedValues, 1),
        clearable = row.clearable == true,
        autosize = row.autosize == true,
    }
end

-- What the page is sent for a row: the same fields, with each option's value
-- replaced by its index and the default by the index (or indexes) it names.
local function wireRow(r)
    if not r.options then
        return r
    end
    local w = {}
    for k, v in pairs(r) do w[k] = v end
    w.options = {}
    for i, o in ipairs(r.options) do
        w.options[i] = { value = i, label = o.label }
    end
    if r.type == 'select' then
        w.default = r.default ~= nil and indexOf(r.options, r.default) or nil
    else
        local picked = {}
        if type(r.default) == 'table' then
            for _, v in ipairs(r.default) do
                picked[#picked + 1] = indexOf(r.options, v)
            end
        end
        w.default = picked
    end
    return w
end

local DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function dateOk(v)
    if type(v) ~= 'string' then return false end
    local y, m, d = v:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    if not y then return false end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m < 1 or m > 12 or d < 1 then return false end
    local leap = (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
    return d <= ((m == 2 and leap) and 29 or DAYS[m])
end

local function dateInRange(row, v)
    if not dateOk(v) then return false end
    if dateOk(row.min) and v < row.min then return false end
    if dateOk(row.max) and v > row.max then return false end
    return true
end

local function inBounds(row, n)
    if type(row.min) == 'number' and n < row.min then return false end
    if type(row.max) == 'number' and n > row.max then return false end
    return true
end

-- The page's index back to the caller's value, or nil if it names nothing.
local function picked(row, v)
    if type(v) ~= 'number' or v ~= math.floor(v) then
        return nil
    end
    local o = row.options[v]
    return o and o.value or nil
end

-- A disabled field cannot be changed by the player, so its value is the one
-- it was opened with, whatever the page sends.
local function disabledValue(row)
    local d = row.default
    local want = TYPES[row.type]
    if want == 'boolean' then
        if type(d) == 'boolean' then return d end
        return row.checked
    elseif want == 'option' then
        return indexOf(row.options, d) and d or nil
    elseif want == 'options' then
        local out = {}
        for _, v in ipairs(type(d) == 'table' and d or {}) do
            if indexOf(row.options, v) then out[#out + 1] = v end
        end
        return out
    elseif want == 'number' then
        return type(d) == 'number' and d or nil
    elseif want == 'string' then
        return type(d) == 'string' and d ~= '' and d or nil
    end
    return nil
end

-- One returned value against the row it answers. nil (or '') is "empty".
-- Returns ok, the value the caller gets.
local function check(row, v)
    if row.disabled then
        return true, disabledValue(row)
    end
    if v == '' then
        v = nil
    end
    local want = TYPES[row.type]
    if v == nil then
        if want == 'boolean' then
            v = false
        else
            return not row.required, nil
        end
    end
    if want == 'string' then
        if type(v) ~= 'string' or #v > 65536 or not CisUtf8.valid(v) then return false end
        if row.type == 'color' then
            return (v:match('^#%x%x%x$') or v:match('^#%x%x%x%x%x%x$')) ~= nil, v
        elseif row.type == 'date' then
            return dateInRange(row, v), v
        elseif row.type == 'time' then
            local h, m = v:match('^(%d%d):(%d%d)$')
            return h ~= nil and tonumber(h) <= 23 and tonumber(m) <= 59, v
        end
        local n = CisUtf8.units(v)
        if row.minLength and n < row.minLength then return false end
        if row.maxLength and n > row.maxLength then return false end
        return true, v
    elseif want == 'number' then
        if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then return false end
        return inBounds(row, v), v
    elseif want == 'boolean' then
        if type(v) ~= 'boolean' then return false end
        return v or not row.required, v
    elseif want == 'option' then
        local value = picked(row, v)
        return value ~= nil, value
    elseif want == 'options' then
        if type(v) ~= 'table' then return false end
        local out, seen = {}, {}
        for _, x in pairs(v) do
            local value = picked(row, x)
            if value == nil or seen[x] then return false end
            seen[x] = true
            out[#out + 1] = value
        end
        if #out == 0 and row.required then return false end
        if row.maxSelectedValues and #out > row.maxSelectedValues then return false end
        return true, out
    elseif want == 'range' then
        if type(v) ~= 'table' or not dateInRange(row, v[1]) or not dateInRange(row, v[2]) or v[1] > v[2] then
            return false
        end
        return true, { v[1], v[2] }
    end
    return false
end

local function settle(s, values)
    if current ~= s then
        return false
    end
    current = nil
    I.focus.pop('input')
    I.send('input:close', { id = s.id })
    s.p:resolve(values)
    return true
end

--- @param heading string
--- @param rows table  a list of row tables (or plain strings, which are text inputs)
--- @param options table|nil  { allowCancel, size, labels }
local function inputDialog(heading, rows, options)
    if type(heading) ~= 'string' then
        return nil, ('input dialog needs a heading string, got %s'):format(type(heading))
    end
    if type(rows) ~= 'table' or #rows == 0 then
        return nil, 'input dialog needs a non-empty list of rows'
    end
    if options ~= nil and type(options) ~= 'table' then
        return nil, ('options must be a table, got %s'):format(type(options))
    end
    options = options or {}
    local clean, wire = {}, {}
    for i = 1, math.min(#rows, MAX_ROWS) do
        local r = readRow(rows[i])
        if not r then
            return nil, ('row %d is not a table or a string'):format(i)
        end
        clean[i] = r
        wire[i] = wireRow(r)
    end
    local owner = I.caller()
    if current then
        return nil, 'an input dialog is already open'
    end
    if not I.waitReady() then
        return nil, 'ui not ready'
    end
    if current then
        return nil, 'an input dialog is already open'
    end
    local allowCancel = options.allowCancel ~= false
    local s = { id = I.nextId(), owner = owner, rows = clean, allowCancel = allowCancel, p = promise.new() }
    current = s
    local ok, err = pcall(function()
        I.focus.push('input', {
            owner = owner,
            onEscape = function()
                if allowCancel then settle(s, nil) end
            end,
        })
        local labels = type(options.labels) == 'table' and options.labels or {}
        I.send('input:open', {
            id = s.id,
            heading = I.str(heading, 256) or '',
            rows = wire,
            options = {
                allowCancel = allowCancel,
                size = SIZES[options.size] and options.size or nil,
                labels = { confirm = I.str(labels.confirm, 64), cancel = I.str(labels.cancel, 64) },
            },
        })
    end)
    if not ok then
        I.log('error', ('input dialog failed to open: %s'):format(tostring(err)))
        settle(s, nil)
        return nil, 'input dialog failed to open'
    end
    return Citizen.Await(s.p)
end

local function closeInputDialog()
    if not current then
        return false
    end
    return settle(current, nil)
end

I.on('input', { id = 'string', cancelled = '?boolean', values = '?table' }, function(data)
    local s = current
    if not s or s.id ~= data.id then
        return
    end
    if data.cancelled then
        -- A dialog that cannot be cancelled cannot be cancelled by a post either.
        if s.allowCancel then settle(s, nil) end
        return
    end
    if type(data.values) ~= 'table' then
        return
    end
    local out = {}
    for i, row in ipairs(s.rows) do
        local ok, value = check(row, data.values[i])
        if not ok then
            I.stats.rejected = I.stats.rejected + 1
            I.send('input:invalid', { id = s.id, index = i })
            return
        end
        out[i] = value
    end
    settle(s, out)
end)

I.onStop(function(resource, all)
    if current and (all or current.owner == resource) then
        settle(current, nil)
    end
end)

I.onReset(function()
    if current then
        settle(current, nil)
    end
end)

exports('InputDialog', inputDialog)
exports('CloseInputDialog', closeInputDialog)

I.input = { open = inputDialog, close = closeInputDialog }

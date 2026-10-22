-- Input dialog. Blocking: an array of values (one per row, nil for an empty
-- optional field) or nil on cancel.
--
-- Rows are copied field by field into what the page needs, so nothing the
-- caller put in a row (a function, a huge table) crosses to the page. The
-- answer is checked against the rows it was asked for before the caller sees
-- it: a value of the wrong type, a select value that was not offered, or a
-- missing required field is a malformed payload and is ignored (the dialog
-- stays open), exactly like an unknown id.

local I = CisInterface

local TYPES = {
    input = 'string', textarea = 'string', color = 'string', date = 'string', time = 'string',
    number = 'number', slider = 'number', checkbox = 'boolean',
    select = 'option', ['multi-select'] = 'options', ['date-range'] = 'range',
}
local SIZES = { xs = true, sm = true, md = true, lg = true, xl = true }
local MAX_ROWS = 32
local MAX_OPTIONS = 200
local current = nil -- { id, owner, rows, p }

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
            out[#out + 1] = { value = o.value, label = I.str(o.label, 256) or tostring(o.value) }
        elseif type(o) == 'string' or type(o) == 'number' then
            out[#out + 1] = { value = o, label = tostring(o) }
        end
    end
    return out
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
    return {
        type = kind,
        label = I.str(row.label, 256) or '',
        description = I.str(row.description, 1024),
        placeholder = I.str(row.placeholder, 256),
        icon = I.str(row.icon, 256),
        required = row.required == true,
        disabled = row.disabled == true,
        default = readDefault(row.default),
        min = minv,
        max = maxv,
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

local function offered(row, v)
    for _, o in ipairs(row.options or {}) do
        if o.value == v then return true end
    end
    return false
end

-- One returned value against the row it answers. nil is "empty".
local function valueOk(row, v)
    if v == nil then
        return not row.required or row.disabled
    end
    local want = TYPES[row.type]
    if want == 'string' then
        return type(v) == 'string' and #v <= 65536
    elseif want == 'number' then
        return type(v) == 'number' and v == v
    elseif want == 'boolean' then
        return type(v) == 'boolean'
    elseif want == 'option' then
        return offered(row, v)
    elseif want == 'options' then
        if type(v) ~= 'table' then return false end
        for _, x in pairs(v) do
            if not offered(row, x) then return false end
        end
        return true
    elseif want == 'range' then
        return type(v) == 'table' and type(v[1]) == 'string' and type(v[2]) == 'string'
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
    local clean = {}
    for i = 1, math.min(#rows, MAX_ROWS) do
        local r = readRow(rows[i])
        if not r then
            return nil, ('row %d is not a table or a string'):format(i)
        end
        clean[i] = r
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
    local s = { id = I.nextId(), owner = owner, rows = clean, p = promise.new() }
    current = s
    local allowCancel = options.allowCancel ~= false
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
            rows = clean,
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

I.on('input', { id = 'integer', cancelled = '?boolean', values = '?table' }, function(data)
    local s = current
    if not s or s.id ~= data.id then
        return
    end
    if data.cancelled then
        settle(s, nil)
        return
    end
    if type(data.values) ~= 'table' then
        return
    end
    local out = {}
    for i, row in ipairs(s.rows) do
        local v = data.values[i]
        if not valueOk(row, v) then
            I.stats.rejected = I.stats.rejected + 1
            return
        end
        out[i] = v
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

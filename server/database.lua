-- A GLOBAL, deliberately, and not a file local.
--
-- `GetConfigSummary` in server/initialize.lua reports `databaseReady` by
-- reading `Database.ready`. While this table was `local`, that read resolved a
-- global that never existed, so `databaseReady` was permanently false on every
-- server -- including ones where the driver had initialised perfectly. A
-- consumer gating work on that field was told the database was never ready.
-- A file local is nil across the resource boundary, not an error, so nothing
-- pointed at the mistake.
--
-- It is global for the same reason `Config`, `Security` and `Logging` are: each
-- is process-global state, and a second copy would mean a second driver
-- selection and a second readiness flag. Do not re-localise it.
Database = {
    driver = nil,
    ready = false,
    warned = false,
    transactionWarned = false,
}

local function driverName()
    return Config and Config.Framework and Config.Framework.Database and Config.Framework.Database.Type or 'AUTO'
end

-- What the last Init() concluded, for cis_debug and the boot report.
Database.detected = nil

-- A custom driver adapter: a resource exposing a query export, or a function
-- on a global `CisCustomDatabase`. The same escape hatch as
-- CisCustomFramework -- for a driver this library has never heard of, nobody
-- should have to edit its source.
local function customDriver()
    local global = rawget(_G, 'CisCustomDatabase')
    if type(global) == 'table' and type(global.resource) == 'string' and global.resource ~= '' then
        return global
    end
    local custom = Config and Config.Framework and Config.Framework.Database
        and Config.Framework.Database.Custom
    if type(custom) == 'table' and type(custom.resource) == 'string' and custom.resource ~= '' then
        return custom
    end
    return nil
end

-- Existence probe for an export: does the resource publish this name?
--
-- RESOLVES rather than calls. Calling a query export with dummy arguments is
-- how a probe turns into a real query, and a raise inside the pcall is
-- indistinguishable from "no such export" -- so a working driver was reported
-- as absent. Both a function and a callable reference table count as present;
-- nil means the name is not published.
local function probeExport(resource, exportName)
    if type(exportName) ~= 'string' or exportName == '' then
        return true
    end
    local ok, fn = pcall(function()
        return exports[resource][exportName]
    end)
    if not ok or fn == nil then
        return false
    end
    if type(fn) == 'function' then
        return true
    end
    return type(fn) == 'table' and rawget(fn, '__cfx_functionReference') ~= nil
end

local function mongoCollection(override)
    return override or (Config and Config.Framework and Config.Framework.Database and Config.Framework.Database.Collection)
end

local function started(name)
    return GetResourceState(name) == 'started'
end

-- Runs at load, and only once. A driver resource that has not started yet is
-- reported as unavailable here and picked up by the onResourceStart handler at
-- the bottom of the file; nothing retries on a timer, because a driver that is
-- not configured should not be paid for on every tick of the server's life.
function Database.Init()
    local name = driverName()
    local custom = customDriver()

    if custom then
        -- A custom driver is used if it is started and answers to the export
        -- it advertises. Refusing loudly beats falling back to a stock driver
        -- the operator did not ask for.
        local exportName = type(custom.query) == 'string' and custom.query or 'query'
        if not started(custom.resource) then
            Database.driver = nil
            Database.detected = {
                name = 'NONE', resource = custom.resource, version = nil, how = 'custom',
                reason = ('custom driver %q is not started'):format(custom.resource),
            }
            print('cis_libs: Database driver unavailable: ' .. Database.detected.reason)
        elseif not probeExport(custom.resource, exportName) then
            Database.driver = nil
            Database.detected = {
                name = 'NONE', resource = custom.resource, version = nil, how = 'custom',
                reason = ('custom driver %q exposes no %q export'):format(custom.resource, exportName),
            }
            print('cis_libs: Database driver unavailable: ' .. Database.detected.reason)
        else
            Database.driver = 'CUSTOM'
            Database.custom = custom
            Database.detected = {
                name = (custom.name or 'CUSTOM'):upper(), resource = custom.resource,
                version = GetResourceMetadata(custom.resource, 'version'), how = 'custom',
                reason = ('custom driver %q'):format(custom.resource),
            }
        end
    elseif name == 'AUTO' then
        local choice = CisDetect.database(name, started, function(r)
            return GetResourceMetadata(r, 'version')
        end)
        Database.detected = choice
        if choice.name == 'NONE' then
            Database.driver = nil
            print('cis_libs: no database driver detected (' .. choice.reason .. ')')
        else
            Database.driver = choice.name
            -- Config is REWRITTEN to what was actually found, so a consumer
            -- reading Config.Framework.Database.Type -- including the client,
            -- which receives it in the config payload -- sees the truth.
            if Config and Config.Framework and Config.Framework.Database then
                Config.Framework.Database.Type = choice.name
            end
        end
    elseif name == 'oxmysql' and started('oxmysql') then
        Database.driver = 'oxmysql'
    elseif name == 'mysql-async' and started('mysql-async') then
        Database.driver = 'mysql-async'
    elseif name == 'ghmattimysql' and started('ghmattimysql') then
        Database.driver = 'ghmattimysql'
    elseif name == 'mongodb' and started('mongodb') then
        Database.driver = 'mongodb'
        if exports.mongodb.isConnected and not exports.mongodb:isConnected() then
            print('cis_libs: MongoDB is not connected')
        end
    else
        Database.driver = nil
        print('cis_libs: Database driver unavailable: ' .. tostring(name))
    end
    Database.ready = Database.driver ~= nil
end

-- Every call made while the driver is unavailable funnels through here, and
-- the complaint is printed once. The callback still runs with nil so a caller
-- that forgot to check `Database.ready` gets a value it can test instead of a
-- parked coroutine.
local function missing(cb)
    if not Database.warned then
        Database.warned = true
        print('cis_libs: database call ignored; driver was not ready at start')
    end
    if cb then
        cb(nil)
    end
end

local DEFAULT_TIMEOUT = 15000

-- 15s. Long enough to cover a cold connection and a locked table on a loaded
-- box, short enough that a consumer's own retry budget is not spent waiting on
-- a query that will never come back.
local function queryTimeout()
    local db = Config and Config.Framework and Config.Framework.Database
    return (db and db.Timeout) or DEFAULT_TIMEOUT
end

-- Drivers do not always invoke their callback (a dropped connection, a query
-- the backend never answers). Without a deadline the awaiting coroutine would
-- be parked forever, so resolve nil on timeout instead.
--
-- The 10ms poll is the whole point of this function rather than a plain
-- Citizen.Await: a promise has no deadline, so the loop below is what enforces
-- one. 10ms bounds the overshoot past the deadline to 10ms while adding a
-- hundred scheduler wakeups only to calls that are genuinely slow -- a query
-- that answers immediately never reaches the loop body twice. Polling at 0
-- would busy-spin a core for the full 15s on every hung query.
--
-- The whole call is wrapped in a thread because the driver callbacks are
-- invoked on the scheduler from outside this coroutine; `settled` is the
-- handoff between them, and the flag is what stops a late callback from
-- resolving an already-timed-out promise.
local function await(fn)
    local p = promise.new()
    local settled = false

    CreateThread(function()
        fn(function(...)
            if settled then
                return
            end
            settled = true
            p:resolve({ ... })
        end)
    end)

    local deadline = GetGameTimer() + queryTimeout()
    while not settled and GetGameTimer() < deadline do
        Wait(10)
    end

    if not settled then
        Database.warned = true
        return nil
    end
    return table.unpack(Citizen.Await(p))
end

function Database.Query(sql, params, cb)
    if not Database.ready then
        return missing(cb)
    end
    -- A custom driver is dispatched first: the operator configured it because
    -- the stock branches below would not serve their database.
    --
    -- The exports table is passed EXPLICITLY. `exports[res][name]` is an
    -- unbound method, and calling it without the table consumes `sql` as
    -- `self` -- so the adapter would receive the query where it expected the
    -- exports table and fail in a way that looks like a SQL error.
    if Database.driver == 'CUSTOM' and Database.custom then
        local c = Database.custom
        if type(c.run) == 'function' then
            c.run(sql, params or {}, cb)
            return
        end
        local res, fn = c.resource, type(c.query) == 'string' and c.query or 'query'
        if fn and fn ~= '' then
            exports[res][fn](exports[res], sql, params or {}, cb)
        else
            missing(cb)
        end
        return
    end
    -- `exports.oxmysql.query` and `exports.oxmysql:execute` are the same call
    -- under two names. `execute` is the older export; `query` is what current
    -- oxmysql publishes. Reading the name off the exports table and falling
    -- back is the only probe that works on both, and it costs one field read.
    if Database.driver == 'oxmysql' then
        if exports.oxmysql.query then
            exports.oxmysql:query(sql, params or {}, cb)
        else
            exports.oxmysql:execute(sql, params or {}, cb)
        end
    elseif Database.driver == 'mysql-async' then
        exports['mysql-async']:mysql_fetch_all(sql, params or {}, cb)
    elseif Database.driver == 'ghmattimysql' then
        exports.ghmattimysql:execute(sql, params or {}, cb)
    elseif Database.driver == 'mongodb' then
        -- The mongodb branches take a document table in place of (sql, params):
        -- `collection` names the collection, and `query` (or `params` itself) is
        -- the filter. Every SQL branch takes SQL. A caller that has to work on
        -- both drivers builds the table; this adapter is the only place that
        -- knows the two shapes.
        exports.mongodb:find({
            collection = mongoCollection(params and params.collection),
            query = params and (params.query or params) or {},
        }, cb)
    end
end

function Database.Single(sql, params, cb)
    if not Database.ready then
        return missing(cb)
    end
    -- Older oxmysql has no `single` export at all, so the fallback re-queries
    -- and takes the first row. The `rows and rows[1] or nil` in each branch is
    -- deliberate: an empty result and a nil result must be the same value to
    -- the caller, or every consumer grows a "was it a miss or a failure" branch.
    if Database.driver == 'oxmysql' then
        if exports.oxmysql.single then
            exports.oxmysql:single(sql, params or {}, cb)
        else
            Database.Query(sql, params, function(rows)
                if cb then
                    cb(rows and rows[1] or nil)
                end
            end)
        end
    elseif Database.driver == 'mysql-async' then
        exports['mysql-async']:mysql_fetch_all(sql, params or {}, function(rows)
            if cb then
                cb(rows and rows[1] or nil)
            end
        end)
    elseif Database.driver == 'ghmattimysql' then
        exports.ghmattimysql:execute(sql, params or {}, function(rows)
            if cb then
                cb(rows and rows[1] or nil)
            end
        end)
    elseif Database.driver == 'mongodb' then
        exports.mongodb:findOne({
            collection = mongoCollection(params and params.collection),
            query = params and (params.query or params) or {},
        }, function(success, documents)
            if cb then
                cb(success and documents and documents[1] or nil)
            end
        end)
    end
end

function Database.Scalar(sql, params, cb)
    if not Database.ready then
        return missing(cb)
    end
    if Database.driver == 'oxmysql' then
        exports.oxmysql:scalar(sql, params or {}, cb)
    elseif Database.driver == 'mysql-async' then
        exports['mysql-async']:mysql_fetch_scalar(sql, params or {}, cb)
    elseif Database.driver == 'ghmattimysql' then
        exports.ghmattimysql:scalar(sql, params or {}, cb)
    elseif Database.driver == 'mongodb' then
        -- SQL scalar returns a single cell, so unwrap the first field of the
        -- document rather than handing back the whole record.
        Database.Single(sql, params, function(doc)
            local value = nil
            if type(doc) == 'table' then
                for key in pairs(doc) do
                    if key ~= '_id' then
                        value = doc[key]
                        break
                    end
                end
                if value == nil and doc._id ~= nil then
                    value = doc._id
                end
            elseif doc ~= nil then
                value = doc
            end
            if cb then
                cb(value)
            end
        end)
    end
end

function Database.Insert(sql, params, cb)
    if not Database.ready then
        return missing(cb)
    end
    if Database.driver == 'oxmysql' then
        exports.oxmysql:insert(sql, params or {}, cb)
    elseif Database.driver == 'mysql-async' then
        exports['mysql-async']:mysql_insert(sql, params or {}, cb)
    elseif Database.driver == 'ghmattimysql' then
        exports.ghmattimysql:insert(sql, params or {}, cb)
    elseif Database.driver == 'mongodb' then
        exports.mongodb:insertOne({
            collection = mongoCollection(params and params.collection),
            document = params and (params.document or params) or {},
        }, function(success, _, insertedIds)
            if cb then
                cb(success and insertedIds and (insertedIds[1] or insertedIds[0]) or nil)
            end
        end)
    end
end

function Database.Update(sql, params, cb)
    if not Database.ready then
        return missing(cb)
    end
    -- `affectedRows` is synthesised on the mongodb side so a consumer written
    -- against the SQL shape does not need a second code path per driver. It
    -- returns rather than falling through, because the tail below issues SQL.
    if Database.driver == 'mongodb' then
        exports.mongodb:update({
            collection = mongoCollection(params and params.collection),
            query = params and params.query or {},
            update = params and params.update or {},
        }, function(success, updatedCount)
            if cb then
                cb(success, { affectedRows = updatedCount })
            end
        end)
        return
    end
    Database.Query(sql, params, cb)
end

function Database.Delete(sql, params, cb)
    if not Database.ready then
        return missing(cb)
    end
    -- Same shape as Update above: the mongodb branch returns the affected count
    -- and never reaches the SQL statement in the tail.
    if Database.driver == 'mongodb' then
        exports.mongodb:delete({
            collection = mongoCollection(params and params.collection),
            query = params or {},
        }, function(success, deletedCount)
            if cb then
                cb(success, { affectedRows = deletedCount })
            end
        end)
        return
    end
    Database.Query(sql, params, cb)
end

-- Only oxmysql exposes a transaction export. The other three drivers cannot be
-- made to work, and the failure otherwise surfaces as a bare `nil` in a
-- consumer's code with nothing on the console to connect it to. Say so once,
-- at boot, naming the driver and the setting that has to change.
local function transactionSupportDiagnostic()
    if not Database.ready or Database.driver == 'oxmysql' then
        return
    end
    print(('[cis_libs] DATABASE: driver %q does not support transactions.')
        :format(tostring(Database.driver)))
    print('  Cis.db.transaction cannot be made to work on it. The refusal string is')
    print('  "transactions require oxmysql" and the fix is to set')
    print(('  Config.Framework.Database.Type = "oxmysql" (it is %q right now).')
        :format(tostring(driverName())))
    print('  See COMPATIBILITY.md section 13.2 for the exact current return contract.')
end

function Database.Transaction(queries, cb)
    if not Database.ready then
        return missing(cb)
    end
    if Database.driver ~= 'oxmysql' then
        -- Console only, and only the first time. The return contract below is
        -- byte-identical to what it has always been; a consumer that reads the
        -- refusal is not disturbed by the extra line.
        if not Database.transactionWarned then
            Database.transactionWarned = true
            local caller = GetInvokingResource and GetInvokingResource() or nil
            print(('[cis_libs] DATABASE: Cis.db.transaction refused; called by %s.')
                :format(caller and tostring(caller) or 'cis_libs'))
        end
        if cb then
            cb(false, 'transactions require oxmysql')
        end
        return
    end
    exports.oxmysql:transaction(queries, cb)
end

-- The three names this library used before Query/Single were the spelling.
-- Kept as thin forwards so an existing consumer's export call keeps working;
-- they add no behaviour and there is no reason to add any.
function Database.Execute(query, params, callback)
    Database.Query(query, params, callback)
end

function Database.FetchOne(query, params, callback)
    Database.Single(query, params, callback)
end

function Database.FetchAll(query, params, callback)
    Database.Query(query, params, callback)
end

-- Callback-style method -> await-style export, in one shape ONLY:
-- `method(sql, params, cb)`. A method with any other parameter list does not
-- belong through this helper. See DbTransaction below for what that costs.
local function exportAwait(method)
    return function(sql, params)
        return await(function(cb)
            method(sql, params, cb)
        end)
    end
end

exports('DatabaseExecute', Database.Execute)
exports('DatabaseFetchOne', Database.FetchOne)
exports('DatabaseFetchAll', Database.FetchAll)
exports('DatabaseInsert', Database.Insert)
exports('DatabaseUpdate', Database.Update)
exports('DatabaseDelete', Database.Delete)
exports('DbQuery', exportAwait(Database.Query))
exports('DbSingle', exportAwait(Database.Single))
exports('DbScalar', exportAwait(Database.Scalar))
exports('DbInsert', exportAwait(Database.Insert))
exports('DbUpdate', exportAwait(Database.Update))

-- NOT exportAwait(Database.Transaction). `exportAwait` is hard-coded to
-- `method(sql, params, cb)`, and `Database.Transaction` is `(queries, cb)` --
-- so `queries` landed in the `sql` slot and the completion callback landed in a
-- third parameter the function never reads. `cb` was nil on entry, the
-- transaction was never invoked, the await spun for the full 15s timeout and
-- returned nil, and oxmysql logged "Transaction parameters must be array or
-- object, received 'undefined'" on every call. `cis_housing` and `cis_phone`
-- hit that on every transaction.
--
-- Two things were true at once and neither alone explained the symptom: the
-- call took 15 seconds (the await's deadline, not the driver's) and returned
-- nil (the timeout, not a refusal), while the driver logged an error about
-- parameters that a correct call would never have produced.
--
-- Written out longhand rather than teaching exportAwait to be arity-aware:
-- exactly one method has a different shape, and a second calling convention
-- hidden inside a helper is how the mismatch happened in the first place.
exports('DbTransaction', function(queries)
    return await(function(cb)
        Database.Transaction(queries, cb)
    end)
end)

Database.Init()
if Database.driver then
    print('cis_libs: database initialized (' .. Database.driver .. ')')
end
transactionSupportDiagnostic()

-- The late-start path. fxmanifest does not declare the driver as a
-- dependency, because which driver a server runs is the server's choice and a
-- hard dependency on a resource that may not be installed stops the whole
-- resource from starting. So a driver started after cis_libs is caught here
-- instead, and only then -- `Database.ready` short-circuits every later event,
-- so this handler costs one field read on unrelated resource starts.
AddEventHandler('onResourceStart', function(resourceName)
    if Database.ready then
        return
    end
    local name = driverName()
    if resourceName == name or (name == 'mongodb' and resourceName == 'mongodb') then
        -- Clear the "driver was not ready at start" latch, or the first
        -- complaint would be swallowed and the real state never reported.
        Database.warned = false
        Database.Init()
        if Database.driver then
            print('cis_libs: database initialized (' .. Database.driver .. ')')
        end
        -- A driver that starts after cis_libs never saw the boot diagnostic
        -- above, so say it here instead of leaving the gap unexplained.
        Database.transactionWarned = false
        transactionSupportDiagnostic()
    end
end)

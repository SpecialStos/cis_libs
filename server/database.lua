local Database = {
    driver = nil,
    ready = false,
    warned = false,
    transactionWarned = false,
}

local function driverName()
    return Config and Config.Framework and Config.Framework.Database and Config.Framework.Database.Type or 'oxmysql'
end

local function mongoCollection(override)
    return override or (Config and Config.Framework and Config.Framework.Database and Config.Framework.Database.Collection)
end

local function started(name)
    return GetResourceState(name) == 'started'
end

function Database.Init()
    local name = driverName()
    if name == 'oxmysql' and started('oxmysql') then
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

local function queryTimeout()
    local db = Config and Config.Framework and Config.Framework.Database
    return (db and db.Timeout) or DEFAULT_TIMEOUT
end

-- Drivers do not always invoke their callback (a dropped connection, a query
-- the backend never answers). Without a deadline the awaiting coroutine would
-- be parked forever, so resolve nil on timeout instead.
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

function Database.Execute(query, params, callback)
    Database.Query(query, params, callback)
end

function Database.FetchOne(query, params, callback)
    Database.Single(query, params, callback)
end

function Database.FetchAll(query, params, callback)
    Database.Query(query, params, callback)
end

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
exports('DbTransaction', exportAwait(Database.Transaction))

Database.Init()
if Database.driver then
    print('cis_libs: database initialized (' .. Database.driver .. ')')
end
transactionSupportDiagnostic()

AddEventHandler('onResourceStart', function(resourceName)
    if Database.ready then
        return
    end
    local name = driverName()
    if resourceName == name or (name == 'mongodb' and resourceName == 'mongodb') then
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

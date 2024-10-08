-- cis_libs/server/database.lua

local Database = {}

-- Initialize the database connection based on the config
function Database.Init()
    if Config.Framework.Database.Type == "oxmysql" or
       Config.Framework.Database.Type == "mysql-async" or
       Config.Framework.Database.Type == "ghmattimysql" then
    elseif Config.Framework.Database.Type == "mongodb" then
        -- Check if MongoDB is connected
        if not exports.mongodb:isConnected() then
            print("Error: MongoDB is not connected")
        end
    else
        print("Unsupported database type: " .. Config.Framework.Database.Type)
    end
end

-- Execute a database query
function Database.Execute(query, params, callback)
    if Config.Framework.Database.Type == "oxmysql" then
        exports.oxmysql:execute(query, params, callback)
    elseif Config.Framework.Database.Type == "mysql-async" then
        exports['mysql-async']:mysql_execute(query, params, callback)
    elseif Config.Framework.Database.Type == "ghmattimysql" then
        exports.ghmattimysql:execute(query, params, callback)
    elseif Config.Framework.Database.Type == "mongodb" then
        -- For MongoDB, we're using the update function as it's closest to 'execute'
        --https://github.com/nbredikhin/fivem-mongodb
        exports.mongodb:update({
            collection = Config.Framework.Database.Collection,
            query = params.query or {},
            update = params.update or {},
        }, function(success, updatedCount)
            if callback then
                callback(success, {affectedRows = updatedCount})
            end
        end)
    else
        print("Unsupported database type: " .. Config.Framework.Database.Type)
    end
end

-- Fetch a single row from the database
function Database.FetchOne(query, params, callback)
    if Config.Framework.Database.Type == "oxmysql" then
        exports.oxmysql:scalar(query, params, callback)
    elseif Config.Framework.Database.Type == "mysql-async" then
        exports['mysql-async']:mysql_fetch_scalar(query, params, callback)
    elseif Config.Framework.Database.Type == "ghmattimysql" then
        exports.ghmattimysql:scalar(query, params, callback)
    elseif Config.Framework.Database.Type == "mongodb" then
        exports.mongodb:findOne({
            collection = Config.Framework.Database.Collection,
            query = params,
        }, function(success, documents)
            if callback then
                callback(success, documents and documents[1] or nil)
            end
        end)
    else
        print("Unsupported database type: " .. Config.Framework.Database.Type)
    end
end

-- Fetch multiple rows from the database
function Database.FetchAll(query, params, callback)
    if Config.Framework.Database.Type == "oxmysql" then
        exports.oxmysql:execute(query, params, callback)
    elseif Config.Framework.Database.Type == "mysql-async" then
        exports['mysql-async']:mysql_fetch_all(query, params, callback)
    elseif Config.Framework.Database.Type == "ghmattimysql" then
        exports.ghmattimysql:execute(query, params, callback)
    elseif Config.Framework.Database.Type == "mongodb" then
        exports.mongodb:find({
            collection = Config.Framework.Database.Collection,
            query = params,
        }, callback)
    else
        print("Unsupported database type: " .. Config.Framework.Database.Type)
    end
end

-- Insert a row and return the inserted ID
function Database.Insert(query, params, callback)
    if Config.Framework.Database.Type == "oxmysql" then
        exports.oxmysql:insert(query, params, callback)
    elseif Config.Framework.Database.Type == "mysql-async" then
        exports['mysql-async']:mysql_insert(query, params, callback)
    elseif Config.Framework.Database.Type == "ghmattimysql" then
        exports.ghmattimysql:insert(query, params, callback)
    elseif Config.Framework.Database.Type == "mongodb" then
        exports.mongodb:insertOne({
            collection = Config.Framework.Database.Collection,
            document = params,
        }, function(success, insertedCount, insertedIds)
            if callback then
                callback(success, insertedIds and insertedIds[0] or nil)
            end
        end)
    else
        print("Unsupported database type: " .. Config.Framework.Database.Type)
    end
end

-- Update rows in the database
function Database.Update(query, params, callback)
    if Config.Framework.Database.Type == "oxmysql" then
        exports.oxmysql:execute(query, params, callback)
    elseif Config.Framework.Database.Type == "mysql-async" then
        exports['mysql-async']:mysql_execute(query, params, callback)
    elseif Config.Framework.Database.Type == "ghmattimysql" then
        exports.ghmattimysql:execute(query, params, callback)
    elseif Config.Framework.Database.Type == "mongodb" then
        exports.mongodb:update({
            collection = Config.Framework.Database.Collection,
            query = params.query,
            update = params.update,
        }, function(success, updatedCount)
            if callback then
                callback(success, {affectedRows = updatedCount})
            end
        end)
    else
        print("Unsupported database type: " .. Config.Framework.Database.Type)
    end
end

-- Delete rows from the database
function Database.Delete(query, params, callback)
    if Config.Framework.Database.Type == "oxmysql" then
        exports.oxmysql:execute(query, params, callback)
    elseif Config.Framework.Database.Type == "mysql-async" then
        exports['mysql-async']:mysql_execute(query, params, callback)
    elseif Config.Framework.Database.Type == "ghmattimysql" then
        exports.ghmattimysql:execute(query, params, callback)
    elseif Config.Framework.Database.Type == "mongodb" then
        exports.mongodb:delete({
            collection = Config.Framework.Database.Collection,
            query = params,
        }, function(success, deletedCount)
            if callback then
                callback(success, {affectedRows = deletedCount})
            end
        end)
    else
        print("Unsupported database type: " .. Config.Framework.Database.Type)
    end
end

-- Export functions
exports('DatabaseExecute', Database.Execute)
exports('DatabaseFetchOne', Database.FetchOne)
exports('DatabaseFetchAll', Database.FetchAll)
exports('DatabaseInsert', Database.Insert)
exports('DatabaseUpdate', Database.Update)
exports('DatabaseDelete', Database.Delete)

-- Initialize the database when the resource starts
AddEventHandler('onResourceStart', function(resourceName)
    if (GetCurrentResourceName() ~= resourceName) then
        return
    end
    Database.Init()
    print('Database initialized for ' .. Config.Framework.Database.Type)
end)
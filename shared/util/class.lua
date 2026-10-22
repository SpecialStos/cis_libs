-- Classes: single inheritance, a constructor, instanceof, readable tostring,
-- and private fields held in a weak table.
--
--   local class = Cis.require('class')
--   local Animal = class.new('Animal')
--   function Animal:constructor(name) self.name = name end
--   function Animal:speak() return self.name .. ' makes a sound' end
--
--   local Dog = class.new('Dog', Animal)
--   function Dog:constructor(name)
--       Dog.super.constructor(self, name)      -- the parent's constructor, explicitly
--   end
--   function Dog:speak() return self.name .. ' barks' end
--
--   local rex = Dog:new('Rex')                  -- or Dog('Rex')
--   class.instanceof(rex, Animal)               -- true
--
-- CHEAP CALLS. A class is the metatable of its instances and its own __index,
-- and a subclass's metatable __index is its parent: a method call is a table
-- lookup up the chain, with no closure made per call or per instance.
--
-- TOSTRING. tostring(instance) is 'Dog: <address>' unless the class (or an
-- ancestor) defines `toString`, which is then used. Other metamethods (__eq,
-- __lt, __add, ...) defined on a parent BEFORE the subclass is created are
-- copied down, because Lua reads metamethods with rawget and never follows
-- __index for them.
--
-- PRIVATE FIELDS. `class.privates()` returns an accessor bound to a weak-keyed
-- table. Keep it local to the file that defines the class: only code holding
-- the accessor can reach the fields, and an instance that is collected takes
-- its private table with it.
--
--   local private = class.privates()
--   function Account:constructor(balance) private(self).balance = balance end
--   function Account:balance() return private(self).balance end

local M = {}

-- Every class this module made, weakly: isClass must not keep a class alive.
local classes = setmetatable({}, { __mode = 'k' })

local METAMETHODS = {
    '__eq', '__lt', '__le', '__add', '__sub', '__mul', '__div', '__mod', '__pow',
    '__unm', '__idiv', '__band', '__bor', '__bxor', '__shl', '__shr', '__bnot',
    '__concat', '__len', '__call', '__close',
}

-- The address part of the default tostring, read without the class's own
-- __tostring getting in the way.
local function address(t)
    local mt = getmetatable(t)
    local saved = mt and rawget(mt, '__tostring')
    if saved then rawset(mt, '__tostring', nil) end
    local text = tostring(t)
    if saved then rawset(mt, '__tostring', saved) end
    return (text:match('^%a+:%s*(.+)$') or text)
end

local function instanceTostring(self)
    local cls = getmetatable(self)
    local custom = cls.toString
    if type(custom) == 'function' then
        return tostring(custom(self))
    end
    return ('%s: %s'):format(rawget(cls, '__className'), address(self))
end

local function construct(cls, ...)
    if classes[cls] == nil then
        error('class: new must be called on a class -- Thing:new(...) or Thing(...), not Thing.new(...)', 3)
    end
    local obj = setmetatable({}, cls)
    local ctor = cls.constructor
    if type(ctor) == 'function' then
        ctor(obj, ...)
    end
    return obj
end

local function classNew(cls, ...)
    return construct(cls, ...)
end

--- A new class, optionally inheriting from another made by this module.
---@param name string  shown by tostring and className
---@param super? table  the parent class
---@return table  the class: define methods on it, then call Class:new(...) or Class(...)
function M.new(name, super)
    if type(name) ~= 'string' or name == '' then
        error(('class.new: name must be a non-empty string, got %s'):format(type(name)), 2)
    end
    if super ~= nil and classes[super] == nil then
        error(('class.new: the parent of %s is not a class made by class.new (got %s)')
            :format(name, type(super)), 2)
    end
    local cls = {}
    cls.__index = cls
    cls.__className = name
    cls.__tostring = instanceTostring
    cls.super = super
    cls.new = classNew
    if super then
        for _, mm in ipairs(METAMETHODS) do
            local f = rawget(super, mm)
            if f ~= nil then cls[mm] = f end
        end
    end
    -- The class's own metatable: inherited lookups go to the parent, and calling
    -- the class constructs an instance.
    setmetatable(cls, {
        __index = super,
        __call = construct,
        __tostring = function() return ('class %s'):format(name) end,
    })
    classes[cls] = true
    return cls
end

--- Whether a value is a class made by this module.
---@param value any
---@return boolean
function M.isClass(value)
    return type(value) == 'table' and classes[value] == true
end

--- Whether obj is an instance of cls or of any class derived from it.
---@param obj any
---@param cls table
---@return boolean
function M.instanceof(obj, cls)
    if type(obj) ~= 'table' or classes[cls] == nil then
        return false
    end
    local c = getmetatable(obj)
    while c ~= nil do
        if c == cls then
            return true
        end
        if classes[c] == nil then
            return false
        end
        c = rawget(c, 'super')
    end
    return false
end

--- The class of an instance.
---@param obj any
---@return table|nil  nil when obj is not an instance of a class made here
function M.classOf(obj)
    if type(obj) ~= 'table' then
        return nil
    end
    local c = getmetatable(obj)
    if classes[c] then
        return c
    end
    return nil
end

--- The name of a class, or of an instance's class.
---@param value any
---@return string|nil
function M.nameOf(value)
    if M.isClass(value) then
        return rawget(value, '__className')
    end
    local c = M.classOf(value)
    return c and rawget(c, '__className') or nil
end

--- An accessor for private per-instance fields, backed by a weak-keyed table.
---@return fun(obj: table): table  private(obj) answers obj's private table, creating it on first use
function M.privates()
    local store = setmetatable({}, { __mode = 'k' })
    return function(obj)
        local p = store[obj]
        if p == nil then
            p = {}
            store[obj] = p
        end
        return p
    end
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisClass = M
end

return M

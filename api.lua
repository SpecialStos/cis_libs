-- cis_libs -- machine-readable API contract.
--
-- Pure data. Loadable with loadfile() without starting the provider, without
-- a FiveM server, and without executing a single line of the library. The
-- specification is DOCUMENTATION.md.
--
-- This file is NOT listed in fxmanifest.lua, on purpose. Adding it as a
-- shared_script would execute it inside cis_libs's own VM and publish a
-- global that no consumer can see anyway, because `shared_script
-- '@cis_libs/init.lua'` COPIES the file into the consumer's VM rather than
-- sharing it. Read it on demand:
--
--     local f = assert(loadfile('resources/cis_libs/api.lua'))
--     local api = f()
--
-- `until` is a Lua reserved word, so every occurrence is written ['until'].
--
-- Validated in CI by tools/validate-api.js against what the source actually
-- registers. If the two disagree, CI fails.

return {
    name = 'cis_libs',
    -- The PRODUCT version, which is also what fxmanifest.lua reports and what
    -- server/version.lua compares an operator's update endpoint against. It
    -- must equal the `version` directive in fxmanifest.lua and the one in
    -- package.json; the validator now fails on any disagreement, because the
    -- three drifting apart is how a build ends up telling every customer it is
    -- permanently outdated.
    --
    -- 1.0.0 is the first public product: the monolith became cis_libs / cis_core /
    -- cis_bridge. The contract major below did NOT move, because no `Cis.*`
    -- name or signature changed -- that was the constraint the split was
    -- designed around, and it is the reason a 1.0 consumer needs no edit.
    version = '1.0.0',
    -- Contract major. Bumped only by a breaking change. An older consumer
    -- pinned to a prior major gets an explicit
    -- typed refusal, never a silently wrong answer.
    api = 1,
    -- Migration set id. A consumer records the `schema` it was written
    -- against and the platform answers with the one it now needs.
    schema = 0,

    -- ================================================================ modules
    --
    -- The twenty-four loadable modules, and the ONE place a consumer can name one.
    -- `Cis.require(name)` reads a file from inside this resource and runs it, so
    -- the set of names that means anything is a security boundary: a name that
    -- were not here, and not in REQUIRE_MODULES in init.lua, and not in the
    -- `files {}` block of fxmanifest.lua, would be a caller naming a path.
    --
    -- This list, REQUIRE_MODULES, and `files {}` must agree EXACTLY. The
    -- validator fails the build when they do not, in both drift directions: a
    -- module that loads but is undeclared cannot be found by anyone reading the
    -- documentation, and a module declared but not loadable is a name that
    -- raises for every caller.
    --
    -- `deps` is NOT repeated here on purpose. The dependency edge is declared
    -- once, in REQUIRE_MODULES, and copied here it would be a second answer to a
    -- question that already has one -- and a second answer is one nobody checks.
    -- The loader uses that one; the unit suite proves the edges work by driving
    -- the dedupe path in `window`, which is where three of them meet.
    modules = {
        curve = { path = 'shared/algo/curve.lua', since = '1.0.0' },
        heap = { path = 'shared/algo/heap.lua', since = '1.0.0' },
        interp = { path = 'shared/algo/interp.lua', since = '1.0.0' },
        lru = { path = 'shared/algo/lru.lua', since = '1.0.0' },
        random = { path = 'shared/algo/random.lua', since = '1.0.0' },
        rate = { path = 'shared/algo/rate.lua', since = '1.0.0' },
        ringbuffer = { path = 'shared/algo/ringbuffer.lua', since = '1.1.0' },
        set = { path = 'shared/algo/set.lua', since = '1.1.0' },
        sparse = { path = 'shared/algo/sparse.lua', since = '1.0.0' },
        window = { path = 'shared/algo/window.lua', since = '1.0.0' },
        array = { path = 'shared/util/array.lua', since = '1.1.0' },
        class = { path = 'shared/util/class.lua', since = '1.1.0' },
        cron = { path = 'shared/util/cron.lua', since = '1.1.0' },
        id = { path = 'shared/util/id.lua', since = '1.0.0' },
        json = { path = 'shared/util/json.lua', since = '1.0.0' },
        locale = { path = 'shared/util/locale.lua', since = '1.1.0' },
        mathx = { path = 'shared/util/mathx.lua', since = '1.1.0' },
        print = { path = 'shared/util/print.lua', since = '1.1.0' },
        semver = { path = 'shared/util/semver.lua', since = '1.0.0' },
        string = { path = 'shared/util/string.lua', since = '1.0.0' },
        table = { path = 'shared/util/table.lua', since = '1.0.0' },
        time = { path = 'shared/util/time.lua', since = '1.0.0' },
        timer = { path = 'shared/util/timer.lua', since = '1.1.0' },
        validate = { path = 'shared/util/validate.lua', since = '1.0.0' },
    },

    exports = {
        -- ------------------------------------------------------------- doors
        AddDoorToSystem = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge doors API',
            realm = 'both',
            params = { server = { { name = 'newDoorData', type = 'table', doc = 'the door record, handed to the provider unexamined' }, { name = 'internal', type = 'any', why = 'a flag forwarded to the provider and never read by cis_libs, so nothing here can know what a provider makes of it', doc = 'a flag passed straight through and never read here' } }, client = { { name = 'data', type = 'table', doc = 'the door record, forwarded unexamined to the doorsClient slot' } } },
            returns = { server = { { type = 'boolean, string', doc = 'false plus a reason when the caller is off Security.AuthorizedResources, or when no doors provider is registered' } }, client = { { type = 'boolean', doc = 'registered or not; false on refusal' } } },
        },
        AddDoorGroup = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge doors API',
            realm = 'both',
            params = { server = { { name = 'groupData', type = 'table', doc = "the group record handed to the provider's addGroup" } }, client = { { name = 'data', type = 'table', doc = 'the group record; the key set is provider-defined and nothing here validates it' } } },
            returns = { server = { { type = 'boolean, string', doc = 'false plus a reason when the caller is not allow-listed, or when no doors provider is registered' } }, client = { { type = 'boolean', doc = 'registered or not; false on refusal' } } },
        },
        GetDoorState = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge doors API',
            realm = 'both',
            params = { server = { { name = 'doorId', type = 'string|integer', doc = 'the door id' } }, client = { { name = 'doorId', type = 'string|integer', doc = 'the door id string' } } },
            returns = { server = { { type = 'boolean|nil, string|nil', doc = 'nil means no such door and false means that door is unlocked -- the two are kept distinct on purpose' } }, client = { { type = 'boolean|nil, string|nil', doc = 'nil = no such door, false = unlocked; on a refusal the second slot carries the reason instead, so count the arity before reading it' } } },
        },
        GetAllDoorData = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge doors API',
            realm = 'server',
            params = {},
            returns = { { type = 'table|nil', doc = "the provider's FULL door table, to whoever asks. Deprecated because Cis.doors.list() is scoped to the calling resource and refuses one that is not authorised, while this hands over the whole table" } },
        },
        LockDoors = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge doors API',
            realm = 'server',
            params = { { name = 'identifier', type = 'string|integer', doc = 'the group or door identifier' } },
            returns = { { type = 'integer, string|nil', doc = "0 when no doors provider is registered; 0 plus a reason naming Security.AuthorizedResources when the caller is not on the allow-list" } },
        },
        UnlockDoors = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge doors API',
            realm = 'server',
            params = { { name = 'identifier', type = 'string|integer', doc = 'the group or door identifier' } },
            returns = { { type = 'integer, string|nil', doc = "0 when no doors provider is registered; 0 plus a reason naming Security.AuthorizedResources when the caller is not on the allow-list" } },
        },
        BreakDoor = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge doors API',
            realm = 'server',
            params = { { name = 'identifier', type = 'string|integer', doc = 'the door identifier. Allow-list gated like every other door mutation' } },
            returns = { { type = 'any, string|nil', why = "the provider's value, and the nil-when-no-provider answer is preserved on purpose rather than normalised to false", doc = "the provider's value; nil when no doors provider is registered, and the nil is preserved on purpose rather than normalised to false; nil plus a reason naming Security.AuthorizedResources when the caller is not on the allow-list" } },
        },
        FixDoor = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge doors API',
            realm = 'server',
            params = { { name = 'identifier', type = 'string|integer', doc = 'the door identifier. Allow-list gated like every other door mutation' } },
            returns = { { type = 'any, string|nil', why = "the provider's value, and the nil-when-no-provider answer is preserved on purpose rather than normalised to false", doc = "the provider's value; nil when no doors provider is registered; nil plus a reason when the caller is not on the allow-list" } },
        },
        RequestLockDoors = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge doors API',
            realm = 'client',
            params = { { name = 'identifier', type = 'string', doc = 'the group or door identifier, sent to the doorsClient provider as RequestState with lock = true' } },
            returns = { { type = 'any, string|nil', why = 'with a provider, its value; with no provider, the raw TriggerServerEvent return, whose value this body does not define', doc = 'nil when the ready wait fails; with a provider, its value plus a reason on refusal; with NO provider, the raw TriggerServerEvent return, whose value this body does not define' } },
        },
        RequestUnlockDoors = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge doors API',
            realm = 'client',
            params = { { name = 'identifier', type = 'string', doc = 'the group or door identifier, sent to the doorsClient provider as RequestState with lock = false' } },
            returns = { { type = 'any, string|nil', why = 'with a provider, its value; with no provider, the raw TriggerServerEvent return, whose value this body does not define', doc = 'the same three-way shape as RequestLockDoors' } },
        },
        GetClosestDoor = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge doors API',
            realm = 'client',
            params = {},
            returns = { { type = 'table|nil, string|nil', doc = "the provider's { id, distance, door } -- the NEAREST door to the LOCAL player, and it takes no coordinates. On refusal nil plus the reason, so count the arity before reading slot two" } },
        },

        -- ---------------------------------------------------------- callbacks
        RegisterCallback = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.callback.register(name, handler)',
            realm = 'both',
            params = { server = { { name = 'name', type = 'string', doc = 'a non-empty handler name, the key everything else is filed under' }, { name = 'handler', type = 'function|string|table', doc = 'a function, a callable reference table (a function passed from another resource; released when that resource stops), or a "resource:Export" string; nil fails all three. A later registration of the same name by the SAME resource replaces the earlier one, whatever its kind; a name another resource holds is refused (cis_libs may replace any)' }, { name = 'opts', type = 'table', optional = true, doc = "{ remote = true|false, ace = 'object', schema = { field = { type, min, max, maxLen, optional, finite } }, maxStringLen = n }. remote defaults to TRUE (1.0.0 behaviour); remote = false makes the callback unreachable from any client, which is answered 'unknown' exactly as for a missing name. ace is checked with IsPrincipalAceAllowed('player.<src>', ace) and refused 'denied'. schema checks the FIRST argument and refuses 'bad payload' (and reports the player); its rules are the same as SecureNetOn's, so type may be integer and infinity is refused unless finite = false. maxStringLen replaces the default string cap (Config.CallbackLimits.MaxStringLen, 4096) for this callback; every remote call is capped, keys and values. A malformed option is refused, never ignored" } }, client = { { name = 'name', type = 'string', doc = 'a non-empty handler name; a non-string or "" is refused before anything is stored, and so is a name another resource holds (the owner may replace its own; a name is free again once its owner stops)' }, { name = 'fn', type = 'function|string', doc = 'a callable, or a "resource:Export" string' } } },
            returns = { server = { { type = 'boolean, string|nil', doc = "true once bound; false plus the reason (also logged) on a refusal" } }, client = { { type = 'boolean, string|nil', doc = 'true once stored; false plus the reason (also logged) on a refusal' } } },
        },
        CallCallback = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.callback.call(name, cb, ...)',
            realm = 'both',
            params = { server = { { name = 'name', type = 'string', doc = 'a previously registered name' }, { name = 'cb', type = 'function', optional = true, doc = 'invoked with the whole reply; a function passed from another resource (a callable reference table) is accepted. Anything not callable refuses and calls nothing at all' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the unbounded tail, packed then forwarded whole -- nothing past N is dropped' } }, client = { { name = 'name', type = 'string', doc = "the handler name, shipped as the event's first field" }, { name = 'cb', type = 'function', optional = true, doc = 'invoked as cb(ok, ...) with the whole reply. A NIL cb is legal and silently discards the answer' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the unbounded tail, forwarded bare; packing happens on arrival and values are serialised, so no function can cross' } } },
            returns = { server = { { type = 'nil', doc = "nothing comes back on any path; the outcome only ever arrives as cb(false, 'unknown') or cb(false, 'error')" } }, client = { { type = 'nil', doc = "nothing comes back and the pending key is discarded. A refusal is never a return: it arrives later as cb(false, reason), one of 'timeout', 'rate', 'unknown' or 'error'" } } },
        },
        AwaitCallback = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.callback.await(name, ...)',
            realm = 'both',
            params = { server = { { name = 'name', type = 'string', doc = 'a previously registered name, quoted in the raise message on refusal' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the unbounded tail, forwarded bare -- no pack, no local list, nothing dropped' } }, client = { { name = 'name', type = 'string', doc = 'a previously registered name, stringified into the raise message' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the unbounded tail, forwarded bare' } } },
            returns = { server = { { type = 'any', why = "the handler's own result list, whose arity and types the handler alone decides", doc = "the handler's results, unpacked with their count so a nil in the middle survives. A refusal RAISES rather than returning, so a caller that does not pcall takes the hit" } }, client = { { type = 'any', why = "the handler's own result list, whose arity and types the handler alone decides", doc = "every value the server sent -- up to six, unpacked with their count so a nil in the middle survives. A refusal RAISES" } } },
        },
        -- The awaiting form that reports a refusal instead of raising,
        -- for callers that cannot have an exception thrown through their thread.
        -- Answers `ok, ...` on success and `false, reason` on a refusal; the
        -- return shape lives in `use` because a signature is a parameter list
        -- and the validator enforces that.
        TryAwaitCallbackWithin = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.callback.tryAwaitWithin(name, timeoutMs, ...) -> ok, ... ; a per-call timeout instead of Config.CallbackTimeout',
            realm = 'client',
            params = { { name = 'name', type = 'string', doc = 'a previously registered server callback name' }, { name = 'timeoutMs', type = 'number', doc = 'this call own timeout, milliseconds in (0, 300000]; anything else is refused with a reason' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the arguments for the handler' } },
            returns = { { type = 'boolean, any', why = "the handler's own result list, whose arity and types the handler alone decides", doc = "true plus the whole packed reply; false plus a reason otherwise ('timeout' once the limit passes). Never raises" } }
        },
        TryAwaitCallback = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.callback.tryAwait(name, ...) -> ok, ... on success; false, reason on a refusal',
            realm = 'both',
            params = { server = { { name = 'name', type = 'string', doc = 'a previously registered name, quoted in the refusal string' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the unbounded tail, packed then forwarded whole' } }, client = { { name = 'name', type = 'string', doc = 'a previously registered name' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the unbounded tail, forwarded bare' } } },
            returns = { server = { { type = 'boolean, any', why = "the handler's own result list, whose arity and types the handler alone decides", doc = "true plus the handler's whole result list, so a nil in the middle survives; false plus a reason otherwise. Slot 1 is always the ok flag, never a handler value" } }, client = { { type = 'boolean, any', why = "the handler's own result list, whose arity and types the handler alone decides", doc = 'true plus the whole packed reply; false plus a reason otherwise, and it never raises' } } },
        },
        CallCallbackClient = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.callback.callClient(src, name, cb, ...)',
            realm = 'server',
            params = { { name = 'name', type = 'string', doc = 'the callback the CLIENT answers' }, { name = 'target', type = 'integer', doc = 'a connected player server id; anything else is refused and nobody is told' }, { name = 'cb', type = 'function', optional = true, doc = 'a consumer-side function, consumed on the consumer side, so it does not cross' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the unbounded tail; the client caps it at 32 args and answers "too large"' } },
            returns = { { type = 'string', doc = 'the pending key, an opaque random token. A bad target returns NOTHING and instead calls cb(false, reason)' } },
        },
        AwaitCallbackClient = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.callback.awaitClient(src, name, ...)',
            realm = 'server',
            params = { { name = 'name', type = 'string', doc = 'the callback the CLIENT answers' }, { name = 'target', type = 'integer', doc = 'a connected player id; a plausible-but-absent id is refused rather than parked' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the unbounded tail; the client caps it at 32 args' } },
            returns = { { type = 'boolean, any', why = "the handler's own result list, whose arity and types the handler alone decides", doc = "true plus the client's results; false plus a reason for a bad target, a disconnect, a timeout or a drop. A promise rejection raises inside the await, and a pcall is what turns it into a value" } },
        },
        TriggerLibCallback = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'the client-to-server round trip whose callback receives only the results',
            realm = 'client',
            params = { { name = 'name', type = 'string', doc = 'the handler name' }, { name = 'cb', type = 'function', optional = true, doc = 'called with the handler values on success and with a BARE nil on failure, so the two are indistinguishable' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the unbounded tail, forwarded bare' } },
            returns = { { type = 'nil', doc = 'nothing comes back; the callback is the only answer channel' } },
        },

        -- ----------------------------------------------------------- database
        DbQuery = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the oxmysql API (MySQL.query.await), served by oxmysql or cis_database',
            realm = 'server',
            params = { { name = 'sql', type = 'string', doc = 'the statement' }, { name = 'params', type = 'table|any', optional = true, why = "the driver's own bind-parameter format, passed through unexamined -- this is the seam to whatever driver is registered, and a library that typed it would be typing somebody else's API", doc = "the driver's bind parameters, passed through unchanged and never inspected here" } },
            returns = { { type = 'table|nil', doc = 'the rows; nil means no provider, and the reason is out of band behind GetLastRefusal' } },
        },
        DbSingle = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the oxmysql API (MySQL.single.await), served by oxmysql or cis_database',
            realm = 'server',
            params = { { name = 'sql', type = 'string', doc = 'the statement' }, { name = 'params', type = 'table|any', optional = true, why = "the driver's own bind-parameter format, passed through unexamined -- this is the seam to whatever driver is registered, and a library that typed it would be typing somebody else's API", doc = "the driver's bind parameters, passed through unchanged and never inspected here" } },
            returns = { { type = 'table|nil', doc = 'the row; nil means no provider, reason via GetLastRefusal' } },
        },
        DbScalar = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the oxmysql API (MySQL.scalar.await), served by oxmysql or cis_database',
            realm = 'server',
            params = { { name = 'sql', type = 'string', doc = 'the statement' }, { name = 'params', type = 'table|any', optional = true, why = "the driver's own bind-parameter format, passed through unexamined -- this is the seam to whatever driver is registered, and a library that typed it would be typing somebody else's API", doc = "the driver's bind parameters, passed through unchanged and never inspected here" } },
            returns = { { type = 'any', why = "the driver's own scalar, which is a number, a string or a boolean depending on the statement", doc = 'the scalar; nil means no provider, reason via GetLastRefusal' } },
        },
        DbInsert = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the oxmysql API (MySQL.insert.await), served by oxmysql or cis_database',
            realm = 'server',
            params = { { name = 'sql', type = 'string', doc = 'the statement' }, { name = 'params', type = 'table|any', optional = true, why = "the driver's own bind-parameter format, passed through unexamined -- this is the seam to whatever driver is registered, and a library that typed it would be typing somebody else's API", doc = "the driver's bind parameters, passed through unchanged and never inspected here" } },
            returns = { { type = 'integer|nil', doc = 'the insert id; nil means no provider, reason via GetLastRefusal' } },
        },
        DbUpdate = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the oxmysql API (MySQL.update.await), served by oxmysql or cis_database',
            realm = 'server',
            params = { { name = 'sql', type = 'string', doc = 'the statement' }, { name = 'params', type = 'table|any', optional = true, why = "the driver's own bind-parameter format, passed through unexamined -- this is the seam to whatever driver is registered, and a library that typed it would be typing somebody else's API", doc = "the driver's bind parameters, passed through unchanged and never inspected here" } },
            returns = { { type = 'integer|nil', doc = 'the affected count; nil means no provider, reason via GetLastRefusal' } },
        },
        DbTransaction = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the oxmysql API (MySQL.transaction.await), served by oxmysql or cis_database',
            realm = 'server',
            params = { { name = 'queries', type = 'table', doc = 'a LIST of queries, not (sql, params) -- the one deliberate asymmetry in the database block' } },
            returns = { { type = 'boolean, string', doc = 'the deliberate exception: refusal is false plus a reason, because a driver without transactions would otherwise hold the caller for the full timeout and answer nil -- indistinguishable from a lost query' } },
        },
        ClosestPed = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.world.getClosestPed(coords, maxDistance, filter, opts)',
            realm = 'client',
            params = { { name = 'coords', type = 'vector3|table', doc = 'the point to measure from. Refused by name when absent, never defaulted -- the origin is a real place and a zone that is really at (0,0) is a bug report about the wrong zone' }, { name = 'maxDistance', type = 'number', doc = 'metres; nil or a non-positive value means NO distance limit, which is the difference between "everything" and "nothing"' }, { name = 'filter', type = 'function', doc = '`fun(entity, coords): boolean` -- must return TRUE to keep. It runs once per candidate, per call, under pcall: an error skips that entity and is counted as worldFilterErrors, and a truthy NON-boolean excludes, because a consumer writing `return entity` meant to filter and would otherwise get none at all' }, { name = 'opts', type = 'table', doc = '`{ includePlayers = true }` adds the peds of OTHER players and `{ includeSelf = true }` your own. Both off by default: the pool holds player peds too, and a ped query means NPCs' } },
            returns = { { type = 'integer|false, vector3|string|nil', doc = 'the handle and its coords, or false plus a reason. A dead pool entity is never a candidate' } }
        },
        ClosestVehicle = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.world.getClosestVehicle(coords, maxDistance, filter, opts)',
            realm = 'client',
            params = { { name = 'coords', type = 'vector3|table', doc = 'the point to measure from. Refused by name when absent, never defaulted -- the origin is a real place and a zone that is really at (0,0) is a bug report about the wrong zone' }, { name = 'maxDistance', type = 'number', doc = 'metres; nil or a non-positive value means NO distance limit, which is the difference between "everything" and "nothing"' }, { name = 'filter', type = 'function', doc = '`fun(entity, coords): boolean` -- must return TRUE to keep. It runs once per candidate, per call, under pcall: an error skips that entity and is counted as worldFilterErrors, and a truthy NON-boolean excludes, because a consumer writing `return entity` meant to filter and would otherwise get none at all' }, { name = 'opts', type = 'table', doc = 'reserved; accepted and ignored for this kind' } },
            returns = { { type = 'integer|false, vector3|string|nil', doc = 'the handle and its coords, or false plus a reason' } }
        },
        ClosestObject = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.world.getClosestObject(coords, maxDistance, filter, opts)',
            realm = 'client',
            params = { { name = 'coords', type = 'vector3|table', doc = 'the point to measure from. Refused by name when absent, never defaulted -- the origin is a real place and a zone that is really at (0,0) is a bug report about the wrong zone' }, { name = 'maxDistance', type = 'number', doc = 'metres; nil or a non-positive value means NO distance limit, which is the difference between "everything" and "nothing"' }, { name = 'filter', type = 'function', doc = '`fun(entity, coords): boolean` -- must return TRUE to keep. It runs once per candidate, per call, under pcall: an error skips that entity and is counted as worldFilterErrors, and a truthy NON-boolean excludes, because a consumer writing `return entity` meant to filter and would otherwise get none at all' }, { name = 'opts', type = 'table', doc = 'reserved; accepted and ignored for this kind' } },
            returns = { { type = 'integer|false, vector3|string|nil', doc = 'the handle and its coords, or false plus a reason' } }
        },
        ClosestPlayer = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.world.getClosestPlayer(coords, maxDistance, filter, opts)',
            realm = 'client',
            params = { { name = 'coords', type = 'vector3|table', doc = 'the point to measure from. Refused by name when absent, never defaulted -- the origin is a real place and a zone that is really at (0,0) is a bug report about the wrong zone' }, { name = 'maxDistance', type = 'number', doc = 'metres; nil or a non-positive value means NO distance limit, which is the difference between "everything" and "nothing"' }, { name = 'filter', type = 'function', doc = '`fun(entity, coords): boolean` -- must return TRUE to keep. It runs once per candidate, per call, under pcall: an error skips that entity and is counted as worldFilterErrors, and a truthy NON-boolean excludes, because a consumer writing `return entity` meant to filter and would otherwise get none at all' }, { name = 'opts', type = 'table', doc = '`{ includeSelf = true }` puts the LOCAL player back in. Off by default: the closest player to where you stand is otherwise always you, at 0 m' } },
            returns = { { type = 'integer|false, vector3|string|nil, integer|nil', doc = 'the PLAYER PED and its coords, plus WHICH player in slot 3 -- the arity differs from the other three on purpose, because reading slot 2 as a player id gives a server id' } }
        },
        NearbyObjects = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.world.getNearbyObjects(coords, maxDistance, filter, opts)',
            realm = 'client',
            params = { { name = 'coords', type = 'vector3|table', doc = 'the point to measure from. Refused by name when absent, never defaulted -- the origin is a real place and a zone that is really at (0,0) is a bug report about the wrong zone' }, { name = 'maxDistance', type = 'number', doc = 'metres; nil or a non-positive value means NO distance limit, which is the difference between "everything" and "nothing"' }, { name = 'filter', type = 'function', doc = '`fun(entity, coords): boolean` -- must return TRUE to keep. It runs once per candidate, per call, under pcall: an error skips that entity and is counted as worldFilterErrors, and a truthy NON-boolean excludes, because a consumer writing `return entity` meant to filter and would otherwise get none at all' }, { name = 'opts', type = 'table', doc = 'reserved; accepted and ignored for this kind' } },
            returns = { { type = 'CisWorldEntry[]|false, string', doc = 'SORTED by distance so element 1 is the closest, and NEVER nil: nothing in range is an empty list, which is a real answer and not the same as a missing provider' } }
        },
        NearbyPeds = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.world.getNearbyPeds(coords, maxDistance, filter, opts)',
            realm = 'client',
            params = { { name = 'coords', type = 'vector3|table', doc = 'the point to measure from. Refused by name when absent, never defaulted -- the origin is a real place and a zone that is really at (0,0) is a bug report about the wrong zone' }, { name = 'maxDistance', type = 'number', doc = 'metres; nil or a non-positive value means NO distance limit, which is the difference between "everything" and "nothing"' }, { name = 'filter', type = 'function', doc = '`fun(entity, coords): boolean` -- must return TRUE to keep. It runs once per candidate, per call, under pcall: an error skips that entity and is counted as worldFilterErrors, and a truthy NON-boolean excludes, because a consumer writing `return entity` meant to filter and would otherwise get none at all' }, { name = 'opts', type = 'table', doc = '`{ includePlayers = true }` adds the peds of OTHER players and `{ includeSelf = true }` your own. Both off by default: the pool holds player peds too, and a ped query means NPCs' } },
            returns = { { type = 'CisWorldEntry[]|false, string', doc = 'sorted by distance, never nil' } }
        },
        NearbyPlayers = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.world.getNearbyPlayers(coords, maxDistance, filter, opts)',
            realm = 'client',
            params = { { name = 'coords', type = 'vector3|table', doc = 'the point to measure from. Refused by name when absent, never defaulted -- the origin is a real place and a zone that is really at (0,0) is a bug report about the wrong zone' }, { name = 'maxDistance', type = 'number', doc = 'metres; nil or a non-positive value means NO distance limit, which is the difference between "everything" and "nothing"' }, { name = 'filter', type = 'function', doc = '`fun(entity, coords): boolean` -- must return TRUE to keep. It runs once per candidate, per call, under pcall: an error skips that entity and is counted as worldFilterErrors, and a truthy NON-boolean excludes, because a consumer writing `return entity` meant to filter and would otherwise get none at all' }, { name = 'opts', type = 'table', doc = '`{ includeSelf = true }` puts the LOCAL player back in. Off by default: the closest player to where you stand is otherwise always you, at 0 m' } },
            returns = { { type = 'CisWorldEntry[]|false, string', doc = 'sorted by distance, never nil. Each entry carries the player id as well' } }
        },
        NearbyVehicles = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.world.getNearbyVehicles(coords, maxDistance, filter, opts)',
            realm = 'client',
            params = { { name = 'coords', type = 'vector3|table', doc = 'the point to measure from. Refused by name when absent, never defaulted -- the origin is a real place and a zone that is really at (0,0) is a bug report about the wrong zone' }, { name = 'maxDistance', type = 'number', doc = 'metres; nil or a non-positive value means NO distance limit, which is the difference between "everything" and "nothing"' }, { name = 'filter', type = 'function', doc = '`fun(entity, coords): boolean` -- must return TRUE to keep. It runs once per candidate, per call, under pcall: an error skips that entity and is counted as worldFilterErrors, and a truthy NON-boolean excludes, because a consumer writing `return entity` meant to filter and would otherwise get none at all' }, { name = 'opts', type = 'table', doc = 'reserved; accepted and ignored for this kind' } },
            returns = { { type = 'CisWorldEntry[]|false, string', doc = 'sorted by distance, never nil' } }
        },
        CreatePoint = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.points.add({ coords, distance, onEnter, onExit, nearby })',
            realm = 'client',
            params = { { name = 'data', type = 'CisPointOptions', doc = 'coords and distance are REQUIRED and refused by name when absent; the rest are optional' } },
            returns = { { type = 'integer|false, string|nil', doc = 'the id, which is a number this library allocates and NEVER reuses, so a stale id is a false refusal rather than another point vanishing. Every refusal is false plus a reason' } }
        },
        AnimDict = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.streaming.animDict(name, timeout)',
            realm = 'client',
            params = { { name = 'name', type = 'string', doc = 'the dictionary NAME, not a hash -- RequestAnimDict takes a char*, and a hash is a type error the game answers by never loading' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
            returns = { { type = 'string|nil, string|nil', doc = 'the name, or nil plus a reason. THE ONLY KIND WITH AN EXISTENCE PROBE, so an invalid dictionary is refused immediately rather than after the whole timeout' } }
        },
        AnimSet = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.streaming.animSet(name, timeout)',
            realm = 'client',
            params = { { name = 'name', type = 'string', doc = 'the set name' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
            returns = { { type = 'string|nil, string|nil', doc = 'the name, or nil plus a reason' } }
        },
        RaycastCamera = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.raycast.camera(flags, ignore, distance, timeoutMs)',
            realm = 'client',
            params = { { name = 'flags', type = 'number', doc = 'shape-test flags, default -1 (everything)' }, { name = 'ignore', type = 'number', doc = 'entity to ignore; default the vehicle the player sits in, else the player ped -- a camera ray starts behind the player and would otherwise hit them. Pass 0 to ignore nothing' }, { name = 'distance', type = 'number', optional = true, doc = 'metres, default 10; positive, finite and at most 100000, or the call is refused with a reason before a probe starts' }, { name = 'timeoutMs', type = 'number', optional = true, doc = 'the BOUND, default 2000. An unbounded poll would leave a caller stuck in Wait with no way out' } },
            returns = { { type = 'boolean|nil, integer|nil, vector3|nil, vector3|nil, integer|nil', doc = 'hit, entityHit, endCoords, surfaceNormal and materialHash. A MISS still carries endCoords and normal: the surface the ray stopped at. nil plus a reason on refusal or timeout' } }
        },
        RaycastFromCoords = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.raycast.fromCoords(origin, target, flags, ignore, timeoutMs)',
            realm = 'client',
            params = { { name = 'origin', type = 'vector3|table', doc = 'where the ray starts; x, y and z must be finite, and NaN or infinity is refused by name' }, { name = 'target', type = 'vector3|table', doc = 'where it would end; finite x/y/z, as origin' }, { name = 'flags', type = 'number', optional = true, doc = 'shape-test flags, default -1' }, { name = 'ignore', type = 'number', optional = true, doc = 'entity to ignore; default the vehicle the player sits in, else the player ped -- a camera ray starts behind the player and would otherwise hit them. Pass 0 to ignore nothing' }, { name = 'timeoutMs', type = 'number', optional = true, doc = 'the bound, default 2000; a non-positive, NaN or infinite value falls back to the default' } },
            returns = { { type = 'boolean|nil, integer|nil, vector3|nil, vector3|nil, integer|nil', doc = 'the same five slots as RaycastCamera, so a caller does not have to know which of the two it called' } }
        },
        KeybindAdd = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.keybind.add({ name, description, defaultKey, onPress, onRelease })',
            realm = 'client',
            params = { { name = 'options', type = 'CisKeybindOptions', doc = 'name is REQUIRED and validated, and refused while another resource holds it -- in this library, or as a +name command another resource registered (GetRegisteredCommands, any case); onPress and onRelease are functions, which reach cis_libs as funcrefs and are called there. A stopped owner takes its bindings with it' } },
            returns = { { type = 'table|false, string|nil', doc = 'a handle with id, name and owner, or false plus a reason. Its methods (disable, isPressed, reset, destroy, getCurrentKey) work only inside cis_libs -- across exports the metatable is lost, so keep handle.id and use KeybindDisable, KeybindEnable, KeybindIsPressed and KeybindRemove. THE MAPPING IS WRITTEN INTO THE PLAYER SETTINGS AND SURVIVES THE RESOURCE, so renaming a binding creates a SECOND one rather than renaming the first' } }
        },
        Keybinds = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; every binding this library registered',
            realm = 'client',
            params = {  },
            returns = { { type = 'table[]', doc = 'snapshots { id, name, owner, command, enabled, pressed } sorted by id -- never the live handles and never anyone\'s callbacks' } }
        },
        KeybindDisable = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the id-based form of handle:disable(state)',
            realm = 'client',
            params = { { name = 'id', type = 'integer', doc = 'handle.id from KeybindAdd' }, { name = 'state', type = 'boolean', doc = 'true or nil disables, false enables' } },
            returns = { { type = 'boolean, string|nil', doc = 'false plus a reason for an unknown id or a binding owned by another resource' } }
        },
        KeybindEnable = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; KeybindDisable(id, false)',
            realm = 'client',
            params = { { name = 'id', type = 'integer', doc = 'handle.id from KeybindAdd' } },
            returns = { { type = 'boolean, string|nil', doc = 'false plus a reason for an unknown id or a binding owned by another resource' } }
        },
        KeybindRemove = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the id-based form of handle:destroy()',
            realm = 'client',
            params = { { name = 'id', type = 'integer', doc = 'handle.id from KeybindAdd' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once the binding is inert and its name is free. The +name/-name commands cannot be unregistered, so they stay and do nothing' } }
        },
        KeybindIsPressed = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the id-based form of handle:isPressed()',
            realm = 'client',
            params = { { name = 'id', type = 'integer', doc = 'handle.id from KeybindAdd' } },
            returns = { { type = 'boolean', doc = 'false for an unknown or removed id' } }
        },
        UiNotify = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.ui.notify(message, kind). NOT Cis.framework.notify: that one is player-targeted, rate-limited, and the one a server uses. This is the local toast',
            realm = 'client',
            params = { { name = 'message', type = 'string|table', doc = 'a string, or a table with description, message, or title. Empty is refused by name' }, { name = 'kind', type = 'string', optional = true, doc = 'forwarded to a ui provider as type; the native GTA feed has no type and ignores it' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once shown. Order: a registered ui provider, else the built-in NUI toast (Toast), else the GTA feed' } }
        },
        UiTextUIShow = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.ui.textUI.show(text, opts)',
            realm = 'client',
            params = { { name = 'text', type = 'string', doc = 'non-empty. Empty is refused by name, not drawn as a blank help box' }, { name = 'opts', type = 'table', optional = true, doc = 'forwarded to a ui provider unexamined (position, icon, style). The native help-text fallback cannot express any of them and ignores the table' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once shown. Native fallback is EndTextCommandDisplayHelp with loop=true, which stays until ClearAllHelpMessages -- and that native clears EVERY help message, not just ours. Last show wins' } }
        },
        UiTextUIHide = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.ui.textUI.hide()',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean, string|nil', doc = 'true even if nothing was open -- hide is a no-op, not an error. Does not call ClearAllHelpMessages unless this library currently has native help up, so a hide we never showed does not wipe another resource\'s help' } }
        },
        UiTextUIIsOpen = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.ui.textUI.isOpen()',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'always a boolean, never nil. Tracks THIS library\'s native help, not IsHelpMessageBeingDisplayed -- another script\'s help is not ours' } }
        },
        UiProgress = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.ui.progress(opts). A ui provider if registered, else the built-in ProgressBar/ProgressCircle (opts.type = \'circle\')',
            realm = 'client',
            params = { { name = 'opts', type = 'table', doc = 'ProgressBar options (duration, label, canCancel, anim, prop, disable, type)' } },
            returns = { { type = 'boolean|nil, string|nil', doc = 'true on completion, false on cancel, or false plus a reason. YIELDS until done' } }
        },
        UiConfirm = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.ui.confirm(opts). A ui provider if registered, else the built-in AlertDialog. RETURNS, does not take a callback',
            realm = 'client',
            params = { { name = 'opts', type = 'table', doc = 'header (or title), content (or message), cancel, labels, size, centered' } },
            returns = { { type = 'any, string|nil', why = 'a registered provider chooses its own value', doc = 'built-in: true plus \'confirm\', or false plus \'cancel\'; a provider answers its own value' } }
        },
        UiInput = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.ui.input(opts). A ui provider if registered, else the built-in InputDialog. RETURNS, does not take a callback',
            realm = 'client',
            params = { { name = 'opts', type = 'table', doc = 'heading (or title), rows, options -- the InputDialog shape' } },
            returns = { { type = 'any, string|nil', why = 'a registered provider chooses its own value', doc = 'built-in: the list of values, or nil on cancel; a provider answers its own value' } }
        },
        -- ------------------------------------------------- interface (NUI)
        Toast = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:Toast(data). The library\'s own NUI notification; Cis.ui.notify routes here when no ui provider is registered. Not Notify: that export is the framework notify, a different signature',
            realm = 'client',
            params = { { name = 'data', type = 'table|string', doc = '{ id, title, description, type = inform|success|warning|error, icon, iconColor, duration, position, showDuration, sound = { name, set } }. A string is the description. description renders a safe markdown subset. icon is a built-in or Font Awesome name (\'house\', \'fa-solid fa-gear\', { \'fas\', \'box\' }), an image URL, or an emoji; an unknown name draws nothing and is logged once. Strings are capped in bytes and cut on a character' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once queued for the page (buffered until it loads); false plus a reason when there is no title and no description' } }
        },
        ProgressBar = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:ProgressBar(data)',
            realm = 'client',
            params = { { name = 'data', type = 'table', doc = '{ duration, label, position = bottom|middle, useWhileDead, allowRagdoll, allowCuffed, allowFalling, allowSwimming, canCancel, anim = { dict, clip, flag, blendIn, blendOut, duration, playbackRate, lockX, lockY, lockZ } or { scenario }, prop = one or a list of { model, bone, pos, rot, rotOrder }, disable = { move, car, combat, mouse, sprint } }' } },
            returns = { { type = 'boolean, string|nil', doc = 'YIELDS. true when it ran to completion, false when cancelled (X, CancelProgress), interrupted, refused (one already running) or the caller stopped. Props and the animation are cleaned up on every exit' } }
        },
        ProgressCircle = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:ProgressCircle(data)',
            realm = 'client',
            params = { { name = 'data', type = 'table', doc = 'the ProgressBar options, drawn as a circle with a percentage' } },
            returns = { { type = 'boolean, string|nil', doc = 'YIELDS. true on completion, false otherwise' } }
        },
        ProgressActive = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:ProgressActive()',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'whether a progress bar or circle is running' } }
        },
        CancelProgress = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:CancelProgress()',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'true when one was running and is now cancelled (its caller gets false)' } }
        },
        ShowTextUI = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:ShowTextUI(text, options)',
            realm = 'client',
            params = { { name = 'text', type = 'string', doc = 'non-empty; a safe markdown subset' }, { name = 'options', type = 'table', optional = true, doc = '{ position = right-center|left-center|top-center|bottom-center, icon, iconColor, style = default|minimal|accent|key, key }' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once shown. One text UI at a time; last show wins; hidden when the resource that showed it stops' } }
        },
        HideTextUI = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:HideTextUI()',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'always true; hiding nothing is not an error' } }
        },
        IsTextUIOpen = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:IsTextUIOpen()',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean, string|nil', doc = 'whether it is shown, and its text' } }
        },
        AlertDialog = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:AlertDialog(data)',
            realm = 'client',
            params = { { name = 'data', type = 'table', doc = '{ header, content (safe markdown subset: bold, italic, code, line breaks, http(s) links), centered, cancel, size = xs|sm|md|lg|xl, labels = { confirm, cancel } }' } },
            returns = { { type = 'string|nil, string|nil', doc = 'YIELDS. \'confirm\' or \'cancel\' (Escape is cancel). nil plus a reason when one is already open or the page has not loaded' } }
        },
        CloseAlertDialog = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:CloseAlertDialog()',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'true when one was open; its caller gets \'cancel\'' } }
        },
        InputDialog = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:InputDialog(heading, rows, options)',
            realm = 'client',
            params = { { name = 'heading', type = 'string', doc = 'the dialog title' }, { name = 'rows', type = 'table', doc = 'a list of rows: { type = input|number|checkbox|select|multi-select|slider|color|date|date-range|time|textarea, label, description, placeholder, icon, required, disabled, default, min, max, step, precision, options, maxSelectedValues, password, autosize, minLength, maxLength }, or a plain string for a text input. For input, min/max are its length; for textarea they are ROW counts (as in ox_lib) and minLength/maxLength bound the text, capped at 16384 UTF-16 units. For number and slider they bound the value, for date the day' }, { name = 'options', type = 'table', optional = true, doc = '{ allowCancel = true, size, labels = { confirm, cancel } }' } },
            returns = { { type = 'table|nil, string|nil', doc = 'YIELDS. One value per row (nil for an empty optional field; date is YYYY-MM-DD, date-range a two-string list, time HH:MM, color #rgb or #rrggbb; a select gives the option value exactly as passed, a Steam64 integer included), or nil on cancel. Every rule the page shows is checked again in Lua; an answer that fails keeps the dialog open and marks the field. A disabled row returns its default' } }
        },
        CloseInputDialog = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:CloseInputDialog()',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'true when one was open; its caller gets nil' } }
        },
        RegisterContext = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:RegisterContext(context)',
            realm = 'client',
            params = { { name = 'context', type = 'table', doc = 'one context or a list: { id, title, menu (parent id), canClose, onExit, onBack, options = { { title, description, icon, iconColor, arrow, disabled, readOnly, progress, colorScheme, metadata, image, menu, onSelect, event, serverEvent, args } } }. serverEvent is fired by THIS CLIENT with TriggerServerEvent(name, args): the server handler must validate it like any client event. event is fired from the cis_libs VM, so it must start with the calling resource name as a "<resource>:" prefix, at most 128 bytes; onResourceStart/Stop/Starting, onClientResourceStart/Stop and any cis_libs: or __cfx_ name are refused for every caller. Fire any other event from onSelect' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once registered. Owned by the calling resource and removed when it stops. false plus a reason for a bad option, a refused event, or an id another resource holds ("context <id> is registered by <res>"). A list is all or nothing. Re-registering the menu on screen redraws it under a new token' } }
        },
        ShowContext = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:ShowContext(id)',
            realm = 'client',
            params = { { name = 'id', type = 'string', doc = 'a registered context id' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once shown; false plus a reason for an unknown id or before the page has loaded' } }
        },
        HideContext = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:HideContext(onExit)',
            realm = 'client',
            params = { { name = 'onExit', type = 'boolean', optional = true, doc = 'true runs the menu onExit' } },
            returns = { { type = 'boolean', doc = 'true when one was open' } }
        },
        GetOpenContextMenu = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:GetOpenContextMenu()',
            realm = 'client',
            params = {},
            returns = { { type = 'string|nil', doc = 'the id of the open context menu' } }
        },
        RegisterMenu = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:RegisterMenu(data, cb)',
            realm = 'client',
            params = { { name = 'data', type = 'table', doc = '{ id, title, position = top-left|top-right|bottom-left|bottom-right, options = { { label, description, icon, iconColor, values, defaultIndex, checked, progress, colorScheme, args, close } }, onSelected, onSideScroll, onCheck, onClose, disableInput, canClose }' }, { name = 'cb', type = 'function', optional = true, doc = 'called (selected, scrollIndex, args) when an option is confirmed with Enter' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once registered. Owned by the calling resource and removed when it stops' } }
        },
        ShowMenu = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:ShowMenu(id, startIndex)',
            realm = 'client',
            params = { { name = 'id', type = 'string', doc = 'a registered menu id' }, { name = 'startIndex', type = 'integer', optional = true, doc = 'the option selected first' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once shown. Keyboard-driven (arrows, Enter, Backspace/Escape); the player keeps control unless disableInput' } }
        },
        HideMenu = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:HideMenu(onExit)',
            realm = 'client',
            params = { { name = 'onExit', type = 'boolean', optional = true, doc = 'true runs the menu onClose' } },
            returns = { { type = 'boolean', doc = 'true when one was open' } }
        },
        GetOpenMenu = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:GetOpenMenu()',
            realm = 'client',
            params = {},
            returns = { { type = 'string|nil', doc = 'the id of the open list menu' } }
        },
        SetMenuOptions = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:SetMenuOptions(id, options, index)',
            realm = 'client',
            params = { { name = 'id', type = 'string', doc = 'a registered menu id' }, { name = 'options', type = 'table', doc = 'the full option list, or one option when index is given' }, { name = 'index', type = 'integer', optional = true, doc = 'replace (or append, one past the end) this option only' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once replaced; an open menu is redrawn' } }
        },
        AddRadialItem = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:AddRadialItem(data)',
            realm = 'client',
            params = { { name = 'data', type = 'table', doc = 'one item or a list: { id, label, icon, iconColor, menu (a RegisterRadial id), onSelect, keepOpen }. onSelect is called (menuId, index)' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once added. The radial key (default Z) is registered with the first item. false plus a reason for a bad item, the cap, or an id another resource holds ("radial item <id> is registered by <res>"); a list is all or nothing' } }
        },
        RemoveRadialItem = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:RemoveRadialItem(id)',
            realm = 'client',
            params = { { name = 'id', type = 'string', doc = 'the item id' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once removed; false plus a reason for an unknown id or an item another resource registered (only its owner or cis_libs may remove it)' } }
        },
        ClearRadialItems = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:ClearRadialItems()',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'always true; removes only the global items the calling resource added (every item when cis_libs itself calls)' } }
        },
        RegisterRadial = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:RegisterRadial(radial)',
            realm = 'client',
            params = { { name = 'radial', type = 'table', doc = '{ id, items } -- a submenu opened by an item whose menu is this id' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once registered; false plus a reason for a bad item or a submenu id another resource holds' } }
        },
        HideRadial = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:HideRadial()',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'true when it was open' } }
        },
        DisableRadial = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:DisableRadial(state)',
            realm = 'client',
            params = { { name = 'state', type = 'boolean', doc = 'true (default) stops the key opening the menu and closes it; false allows it again' } },
            returns = { { type = 'boolean', doc = 'always true' } }
        },
        SkillCheck = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:SkillCheck(difficulty, inputs)',
            realm = 'client',
            params = { { name = 'difficulty', type = 'string|table', doc = '\'easy\' | \'medium\' | \'hard\', { areaSize, speedMultiplier }, or a list of those (one round each)' }, { name = 'inputs', type = 'table', optional = true, doc = 'key names to pick from per round (e, q, r, f, g, w, a, s, d, 1-4); default { e }' } },
            returns = { { type = 'boolean, string|nil', doc = 'YIELDS. true when every round was hit; false on a miss, a wrong key, CancelSkillCheck, the caller stopping, or a refusal. Lua places each zone and judges each press against GetGameTimer; the page only draws, and nothing it posts can pass or fail a check. A round with no press fails once the needle passes the zone' } }
        },
        SkillCheckActive = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:SkillCheckActive()',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'whether a skill check is running' } }
        },
        CancelSkillCheck = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:CancelSkillCheck()',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'true when one was running; its caller gets false' } }
        },
        SetUiTheme = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:SetUiTheme(data)',
            realm = 'client',
            params = { { name = 'data', type = 'table', doc = '{ accent, radius (px), fontScale (0.75-1.5), mode = dark|light|auto, reducedMotion, colors = { token = colour }, notifyPosition, textUIPosition, progressPosition, menuPosition, notifyMax }. Merged into the current theme' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once applied; false plus a reason for a value that is not a colour, a number in range or a known position' } }
        },
        SetUiLocale = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:SetUiLocale(strings)',
            realm = 'client',
            params = { { name = 'strings', type = 'table', doc = 'built-in labels by key (confirm, cancel, close, back, required, min, max, ...); unknown keys are ignored. English by default' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once sent' } }
        },
        NotifyPlayer = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports.cis_libs:NotifyPlayer(src, data)',
            realm = 'server',
            params = { { name = 'src', type = 'integer', doc = 'a player server id, or -1 for everyone' }, { name = 'data', type = 'table|string', doc = 'the Notify fields (no sound). A string is the description' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once sent; false plus a reason for an unknown player or an empty notification' } }
        },
        ServerZoneBox = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.server.box(center, size, opts)',
            realm = 'server',
            params = { { name = 'center', type = 'vector3|table', doc = 'the centre' }, { name = 'size', type = 'number|vector3|table', doc = 'full size; stored as half-extents, same as client zones' }, { name = 'opts', type = 'table', optional = true, doc = 'heading, bucket (the routing bucket, default 0; a player in another bucket is never inside), onEnterEvent, onExitEvent. Exits also fire when a player drops and when the zone is removed or its owner stops' } },
            returns = { { type = 'integer|false, string|nil', doc = 'a numeric id, never reused' } }
        },
        ServerZoneSphere = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.server.sphere(center, radius, opts)',
            realm = 'server',
            params = { { name = 'center', type = 'vector3|table', doc = 'the centre' }, { name = 'radius', type = 'number', doc = 'metres' }, { name = 'opts', type = 'table', optional = true, doc = 'bucket (the routing bucket, default 0; a player in another bucket is never inside), onEnterEvent, onExitEvent. Exits also fire when a player drops and when the zone is removed or its owner stops' } },
            returns = { { type = 'integer|false, string|nil', doc = 'a numeric id, never reused' } }
        },
        ServerZonePoly = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.server.poly(points, opts)',
            realm = 'server',
            params = { { name = 'points', type = 'table', doc = 'at least 3 points' }, { name = 'opts', type = 'table', optional = true, doc = 'minZ, maxZ, bucket (the routing bucket, default 0; a player in another bucket is never inside), onEnterEvent, onExitEvent. Exits also fire when a player drops and when the zone is removed or its owner stops' } },
            returns = { { type = 'integer|false, string|nil', doc = 'a numeric id, never reused' } }
        },
        ServerZoneContains = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.server.contains(id, coords)',
            realm = 'server',
            params = { { name = 'id', type = 'integer', doc = 'the id box/sphere/poly returned' }, { name = 'coords', type = 'vector3|table', doc = 'the point to test' } },
            returns = { { type = 'boolean, string|nil', doc = 'true on containment; false plus a reason for a missing zone or bad coords' } }
        },
        ServerZonePlayers = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.server.players(id)',
            realm = 'server',
            params = { { name = 'id', type = 'integer', doc = 'the zone id' } },
            returns = { { type = 'integer[]|false, string|nil', doc = 'server ids currently inside, sorted. From SERVER ped coords, not a client claim' } }
        },
        ServerZoneRemove = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.server.remove(id)',
            realm = 'server',
            params = { { name = 'id', type = 'integer', doc = 'the zone id' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once removed; false if missing or not the owner' } }
        },
        HookOn = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.hooks.on(name, fn, opts)',
            realm = 'both',
            params = { { name = 'name', type = 'string', doc = 'the hook name' }, { name = 'fn', type = 'function|string', doc = 'a function -- including one passed from another resource, which arrives as a callable reference table -- or resource:Export. Owned by the registering resource and removed when it stops' }, { name = 'opts', type = 'table', optional = true, doc = 'priority, higher runs first' } },
            returns = { { type = 'integer|false, string|nil', doc = 'a cookie, or false plus a reason' } }
        },
        HookRun = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.hooks.run(name, payload)',
            realm = 'both',
            params = { { name = 'name', type = 'string', doc = 'the hook name' }, { name = 'payload', type = 'any', optional = true, why = 'opaque to this library; the hook functions interpret it', doc = 'handed to each hook in order' } },
            returns = { { type = 'boolean, string|nil, string|nil', doc = 'true, or false plus reason plus the resource that vetoed. An error is a veto' } }
        },
        HookRemove = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.hooks.remove(id)',
            realm = 'both',
            params = { { name = 'id', type = 'integer', doc = 'the cookie HookOn returned' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once removed. ONLY the resource that registered the hook, or cis_libs, may remove it; anyone else gets false plus a reason naming the owner, because ids count up from 1 and a loop over them stripped the vetoes of every resource' } }
        },
        StatebagOnEntity = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.statebag.onEntity(key, handler, timeoutMs)',
            realm = 'both',
            params = { { name = 'key', type = 'string', doc = 'the state key, or the * wildcard. NOT empty' }, { name = 'handler', type = 'fun(entity: integer, value: any, replicated: boolean, deleted: boolean)', doc = 'a function, or one passed from another resource (it arrives as a callable reference). The entity is RESOLVED from the bag with GetEntityFromStateBagName -- never the netId in its name -- and a PLAYER bag resolves to that player\'s ped. deleted is value == nil, which is the only shape a delete has' }, { name = 'timeoutMs', type = 'number', optional = true, doc = 'how long the CLIENT keeps a change whose entity does not exist yet, default 2000. Waiting changes share one bounded queue and the newest value per bag wins; the server never waits' } },
            returns = { { type = 'integer|nil, string|nil', doc = 'a COOKIE, not a boolean. The watcher belongs to the resource that registered it and is removed when that resource stops' } }
        },
        StatebagOnPlayer = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.statebag.onPlayer(key, handler, timeoutMs)',
            realm = 'both',
            params = { { name = 'key', type = 'string', doc = 'the state key or *' }, { name = 'handler', type = 'fun(player: integer, value: any, replicated: boolean, deleted: boolean)', doc = 'as on the entity watcher, with the player SERVER id on both sides (resolved with GetPlayerFromStateBagName; a client turns the handle it answers back into the server id)' }, { name = 'timeoutMs', type = 'number', optional = true, doc = 'accepted for symmetry and unused: a server id is known from the bag, so nothing waits' } },
            returns = { { type = 'integer|nil, string|nil', doc = 'a cookie, or nil plus a reason' } }
        },
        RemoveStatebagHandler = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.statebag.remove(cookie)',
            realm = 'both',
            params = { { name = 'cookie', type = 'integer', doc = 'the number the watcher returned' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once removed, or false plus a reason: not a number, no such watcher, or a watcher another resource owns' } }
        },
        CommandAdd = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.command.add(name, { params, restricted, help }, handler)',
            realm = 'server',
            params = { { name = 'name', type = 'string', doc = 'letters, digits, underscore or hyphen only' }, { name = 'options', type = 'table', doc = "{ params, restricted, help }. params is an array of names, or of { name, help, type, optional } tables: type is 'string' (default), 'number', 'playerId' (a connected id, or 'me') or 'longString' (the rest of the line; must be last); optional params must come last. A line that does not fit is refused and the usage logged. restricted is true or an ACE principal like 'group.admin'" }, { name = 'handler', type = 'function', doc = 'called as (src, args, raw). src is INJECTED and is not a parameter, so no caller can name anyone. args holds the converted values by position AND by param name. A function passed from another resource is accepted, owned by it, and stops running when it stops' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once registered, or false plus a reason: a name the server already knows (another resource command or a builtin, matched without regard to case) is refused, and so is a re-add that changes the restricted flag. A restricted command is checked by RegisterCommand and again by the handler. When restricted names a group.* principal and cis_libs has been granted command.add_ace, it runs add_ace <group> command.<name> allow itself (never for builtin.*, player.* or identifier.* principals) (and remove_ace on removal); otherwise it prints that exact line. Chat suggestions reach players who join later' } }
        },
        CommandList = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.command.list()',
            realm = 'server',
            params = {  },
            returns = { { type = 'table[]', doc = 'every registered command with its usage line and help' } }
        },
        CommandRemove = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.command.remove(name)',
            realm = 'server',
            params = { { name = 'name', type = 'string', doc = 'the command name' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once removed -- the command then runs nothing and its suggestion is withdrawn -- or false plus a reason when nothing holds that name or the caller is not the resource that added it' } }
        },
        CommandParse = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the argument splitter used by CommandAdd',
            realm = 'server',
            params = { { name = 'raw', type = 'string', doc = 'the command line as typed' } },
            returns = { { type = 'string[]', doc = 'the arguments. Double quotes GROUP, single quotes group without expanding, and there is no backslash escape because the platform has none' } }
        },

        -- ---------------------------------------------------------- inventory
        InventoryCount = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge inventory API',
            realm = 'both',
            params = { server = { { name = 'src', type = 'integer', doc = 'the player id, handed to the provider with no local check' }, { name = 'item', type = 'string', doc = "the provider's item key, passed straight through" } }, client = { { name = 'item', type = 'string', doc = 'the item name. The client count takes NO src, which is the one name in the proxy with a different signature per realm' } } },
            returns = { server = { { type = 'integer', doc = '0 when no inventory provider is registered -- kept a NUMBER, so the `if not n` callers already written still read 0 instead of nil' } }, client = { { type = 'integer', doc = 'the count, or 0 on refusal -- deliberately a number and never nil' } } },
        },
        InventoryHas = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge inventory API',
            realm = 'both',
            params = { server = { { name = 'src', type = 'integer', doc = 'the player id' }, { name = 'item', type = 'string', doc = "the provider's item key" }, { name = 'amount', type = 'integer', doc = 'the quantity' } }, client = { { name = 'item', type = 'string', doc = 'the item name' }, { name = 'amount', type = 'integer', doc = 'the count compared against the snapshot' } } },
            returns = { server = { { type = 'boolean', doc = "false when no provider is registered; the provider's value otherwise" } }, client = { { type = 'boolean', doc = 'whether the amount is held, or false on refusal' } } },
        },
        InventoryAdd = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge inventory API',
            realm = 'server',
            params = { { name = 'src', type = 'integer', doc = 'the player id' }, { name = 'item', type = 'string', doc = "the provider's item key" }, { name = 'amount', type = 'integer', doc = 'the quantity, neither defaulted nor clamped here' }, { name = 'metadata', type = 'table|any', optional = true, why = 'per-item metadata whose shape belongs to the inventory provider, not to this library', doc = 'per-item metadata' } },
            returns = { { type = 'boolean', doc = "false when no inventory provider is registered; the provider's value otherwise" } },
        },
        InventoryRemove = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge inventory API',
            realm = 'server',
            params = { { name = 'src', type = 'integer', doc = 'the player id' }, { name = 'item', type = 'string', doc = "the provider's item key" }, { name = 'amount', type = 'integer', doc = 'the quantity' } },
            returns = { { type = 'boolean', doc = 'false when no provider is registered' } },
        },

        -- -------------------------------------------------------------- zones
        CreateZone = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.box / Cis.zones.poly / Cis.zones.sphere',
            realm = 'client',
            params = { { name = 'kind', type = 'string', doc = "'box', 'poly' or 'sphere'; anything else is refused by name" }, { name = 'name', type = 'string', doc = 'a non-empty name -- the table key, the grid key, and the handle remove(name) takes' }, { name = 'a', type = 'vector3|vector4|table', doc = 'the box or sphere centre, or the poly point list; nil is refused by name and a type outside these three is refused too' }, { name = 'b', type = 'vector3|number|table', doc = 'the box size (required -- nil refuses; every axis positive and finite), the sphere radius (default 1.0; positive and finite), or unused for a poly. A poly needs at least 3 points, and every zone must lie within 100 km of the origin' }, { name = 'options', type = 'table', optional = true, doc = 'the options table, defaulted to {}' } },
            returns = { { type = 'boolean, string', doc = 'true on success; every refusal is false plus a reason. ALWAYS capture the second value -- a bare false tells you nothing you did not already guess' } },
        },
        RemoveZone = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.remove(name)',
            realm = 'client',
            params = { { name = 'name', type = 'string', doc = 'the name. Removing a zone twice, or one that never existed, is a no-op and not an error' } },
            returns = { { type = 'boolean, string|nil', doc = "false when no zone holds that name, true once removed; false plus a reason when another resource owns it (only the owner, or cis_libs, may remove a zone). A player still inside gets its onExit fired first, with the PLAYER's coordinates rather than the zone centre" } },
        },
        ZoneContains = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.contains(name, point)',
            realm = 'client',
            params = { { name = 'name', type = 'string', doc = 'the name; an unknown name is the false case' }, { name = 'point', type = 'vector3|table', optional = true, doc = 'the point to test; a nil answers false rather than raising' } },
            returns = { { type = 'boolean', doc = 'true only on a real containment hit' } },
        },
        GetPointsDebug = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the live debug record for the point pass',
            realm = 'client',
            params = {},
            returns = { { type = 'CisPointsDebug', doc = 'the live record, NOT a copy: lastPassMs, lastPassAt, insideCount and insideIds. Reported because a pass that silently does nothing and a point that was never found look identical from outside' } }
        },
        GetZoneDebug = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the last grid pass cost in milliseconds',
            realm = 'client',
            params = {},
            returns = { { type = 'CisZoneDebug', doc = 'the live debug record, not a copy: lastPassMs, lastPassAt, debugDrawing, insideCount and insideNames' } },
        },

        -- ------------------------------------------------------------- target
        CreateTarget = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge target API',
            realm = 'client',
            params = { { name = 'zoneType', type = 'string', doc = "'box', 'sphere' or 'ped'; anything else is refused by name" }, { name = 'name', type = 'string', doc = 'a non-empty name -- the key, and the handle remove and update take' }, { name = 'coords', type = 'vector3|table', doc = 'the centre; ONLY nil is checked, and the value goes to the provider as spec.coords unexamined' }, { name = 'size', type = 'vector3|number', doc = 'the size; no guard and no default' }, { name = 'options', type = 'table', optional = true, doc = 'the options table, defaulted to {}' } },
            returns = { { type = 'boolean, string', doc = "true on success; every refusal is false plus a reason, the provider's own included" } },
        },
        RemoveTarget = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge target API',
            realm = 'client',
            params = { { name = 'name', type = 'string', doc = 'the name; a miss is refused with the name in the reason' }, { name = 'isPed', type = 'boolean', optional = true, doc = 'asserts the target was created for a LOCAL entity. Its ABSENCE is how a box or sphere target removes' } },
            returns = { { type = 'boolean, string', doc = 'true on success; every refusal is false plus a reason, including a target owned by another resource (only the owner, or cis_libs, may remove it)' } },
        },
        UpdateTarget = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge target API',
            realm = 'client',
            params = { { name = 'name', type = 'string', doc = 'the name; a name that is not live is refused' }, { name = 'newOptions', type = 'table', optional = true, doc = 'the new options, passed straight to a create -- update is a remove and re-create, not a patch on the provider' } },
            returns = { { type = 'boolean, string', doc = 'true once re-created; false plus a reason for an unknown name, one another resource owns, bad options, or no provider (the target is untouched). A create the provider refuses puts the old target back and says so. The target keeps its owner' } },
        },
        TargetExists = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge target API',
            realm = 'client',
            params = { { name = 'name', type = 'string', doc = 'the name' } },
            returns = { { type = 'boolean', doc = 'true only while this library believes it created the target; the provider is never consulted' } },
        },
        TargetAvailable = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge target API',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'false when target support is disabled by config, or when no provider answered available == true' } },
        },

        -- --------------------------------------------------------------- sync
        SyncCreate = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.sync.ped / Cis.sync.prop / Cis.sync.vehicle',
            realm = 'server',
            params = { { name = 'kind', type = 'string', doc = "'prop', 'vehicle' or 'ped' -- never type-guarded, and the branch is on exactly these literals" }, { name = 'data', type = 'table', doc = 'the record. Not type-guarded either: the first hard requirement is data.coords, which raises on a non-table' } },
            returns = { { type = 'string|nil, string|nil', doc = 'the record id, and a reason when a networked record is refused -- a kind with no server-side creation native, an entity the server could not create, or a removal that overtook the creation. EVERY OTHER REFUSAL IS A BARE NIL (and a logged reason), because a nil first value truncates the return list at the exports boundary' } },
            note = 'A caller-managed `data.id` lives in a namespace of its own: two resources can both use "door1" and both get their own record. A numeric id is converted to its string here. Returns the caller\'s own id, never the namespaced key the client receives. `networked = true` asks the SERVER for one entity, created per kind and placed in the record\'s routing bucket; a vehicle also takes `vehicleType` (automobile, bike, boat, heli, plane, submarine, trailer; default automobile). A kind the server has no creation for is refused with a reason rather than downgraded, and so is an entity the server could not create. A networked entity is streamed by OneSync, never over the sync events; its record rides the entity\'s `cis_sync` state bag, an update that names the same coordinates does not move it, and an entity removed behind the library\'s back is re-created unless `respawn = false`. Client-local records are streamed by distance and re-sent only when their revision changes, one batched event per player per pass. Caller data travels to the client ONLY in `data.clientData` (and a vehicle\'s `props`), together capped at 256 entries and 16 KB of strings; any other field on `data` is server-side and is not sent. An upsert that is still creating its entity holds its id: a second upsert of the same id waits for it, and a remove during it wins.',
        },
        SyncRemove = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.sync.remove(id)',
            realm = 'server',
            params = { { name = 'id', type = 'string|integer', optional = true, doc = 'the id; a number is stringified at this boundary. Namespaced by the INVOKING RESOURCE, never by the argument' } },
            returns = { { type = 'boolean, string', doc = "true on success; false always names why -- 'no sync id given', a type message, \"belongs to another resource\", or \"not in this resource's namespace\"" } },
            note = 'Resolves the id in the CALLING resource\'s namespace, so one resource cannot remove another\'s record. A number is accepted and matched against its string. Always answers `false, reason` on a miss, and the reason distinguishes the two misses that mean different things: an id this resource does not hold but another does is refused as another resource\'s, and an id nobody holds names itself.',
        },
        ModuleInfo = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.moduleInfo(name, opts)',
            realm = 'both',
            params = { { name = 'name', type = 'string', doc = 'a module name from the allow-list; a non-string is refused with the type in .why' }, { name = 'opts', type = 'table', optional = true, doc = 'only .load is read, and only as == true; it is the one path here that loads anything' } },
            returns = { { type = 'CisModuleInfo', doc = 'ok, name, path, global, deps and globalPresent, plus functions, loaded and globalPresentAfterLoad under opts.load. A refusal is ok = false with .why, and an unknown name also carries .valid' } },
            note = 'Describes a loadable module without handing it over. `Cis.require` lives in cis_libs\' own Lua state and a consumer is a different one, so a consumer cannot reach it -- and a Lua function cannot cross the exports boundary, so the module table cannot be handed over either. A description can, and it answers the question a consumer actually has: does this name exist, what does it expose, and does it load. `opts.load` is opt-in and is the only path here that loads anything: without it the answer comes from the allow-list alone, so asking costs nothing. An unknown name answers `ok = false` with the reason AND `valid`, the full list of names, so the caller can fix the call rather than guess again.',
        },
        GetSyncedEntities = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the id-to-handle table of everything this client spawned',
            realm = 'client',
            params = {},
            returns = { { type = 'table<string, integer', doc = "a fresh copy keyed by the server's NAMESPACED key -- not the id the caller passed in, and 0 is excluded by construction" } },
        },
        SyncList = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.sync.list()',
            realm = 'server',
            params = {},
            returns = { { type = 'CisSyncSummary[], string|nil', doc = "the CALLING resource's own ids, sorted so an entry can go straight back to SyncRemove, and a reason only on the allow-list refusal" } },
            note = 'The CALLING resource\'s own records and no others -- a list naming another resource\'s records would be a map of every entity on the server. Answers the caller\'s OWN ids rather than the namespaced keys, so an entry can be handed straight back to `Cis.sync.remove(id)`. Sorted by id, so two calls in the same state answer in the same order. Refused with a reason when the resource is not on `Security.AuthorizedResources`. On the client it answers `false, \'server only\'`.',
        },
        SyncClear = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.sync.clear()',
            realm = 'server',
            params = {},
            returns = { { type = 'integer|nil, string|nil', doc = 'how many records it took; 0 is an honest answer for a resource that has synced nothing, and a reason only on the allow-list refusal' } },
            note = 'Takes down every record the CALLING resource owns and answers how many it took; 0 is the honest answer for a resource that has synced nothing, and a reload path calls this unconditionally. Every removal announces itself to each client holding the record, so no client is left holding a prop the server has forgotten. Another resource\'s records are untouched. Refused with a reason when the resource is not on `Security.AuthorizedResources`. On the client it answers `false, \'server only\'`.',
        },
        GetSyncedEntity = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.sync.entity(key)',
            realm = 'client',
            params = { { name = 'key', type = 'string', doc = "the namespaced key. The BARE id resolves to another resource's entity, and the answer carries nothing that would let a caller tell the two apart" } },
            returns = { { type = 'integer|nil', doc = "the handle, or nil for a non-string, an unknown key, a key holding 0, or an entity the game deleted behind the library's back" } },
            note = 'The handle this client is holding for one synced entity, or nil. Takes the namespaced `key`, NOT the caller\'s own id -- two resources can both call a record "door1", and looking one up by the bare id would resolve against a handle belonging to a different resource. A key this client holds nothing for answers nil. On the server it answers `false, \'server only\'`.',
        },
        AddSyncSpawnHandler = {
            since = '1.0.0', ['until'] = false, stable = false, deprecated = false,
            use = 'Cis.sync.onSpawn(fn)',
            realm = 'client',
            params = { { name = 'fn', type = 'function', doc = 'a function, or one passed from another resource (it arrives as a callable reference and is released when that resource stops). Anything that cannot be called is REFUSED rather than stored' } },
            returns = { { type = 'boolean, string', doc = "true alone on success. Never a handle: there is no deregister. The handler is called pcall'd as (key, record, entity), and fires only after the generation check, so an entity created and immediately deleted never announces itself" } },
            note = 'Registers a consumer hook fired with `(key, record, entity)` once a synced entity has actually spawned -- which can be up to five seconds after the request, during a model load. An entity created and then immediately deleted because the player left during the wait does NOT fire. The hook runs under pcall: a consumer hook that raises must not take the spawn, or the despawn that deletes the entity, with it. A raise is logged, never swallowed. Refuses anything that is not a function. On the server it answers `false, \'server only\'`.',
        },
        AddSyncDespawnHandler = {
            since = '1.0.0', ['until'] = false, stable = false, deprecated = false,
            use = 'Cis.sync.onDespawn(fn)',
            realm = 'client',
            params = { { name = 'fn', type = 'function', doc = 'a function or a cross-resource reference, released when its resource stops; anything that cannot be called is refused' } },
            returns = { { type = 'boolean, string', doc = "true alone on success. The handler is called pcall'd as (key) and only when this client actually held something" } },
            note = 'Registers a consumer hook fired with `(key)` when this client drops a synced entity it was actually holding. A remove for a key it never had does not fire -- that is routine, the player walked out of range and came back -- and telling a consumer to clean up an entity it was never given is worse than saying nothing. Runs under pcall for the same reason as onSpawn, and the despawn is the more dangerous of the two: an unprotected raise there strands a client-local prop with nothing left to remove it. Refuses anything that is not a function. On the server it answers `false, \'server only\'`.',
        },

        -- -------------------------------------------------------------- cache
        GetCachedPed = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.ped(), which reads the native directly in a consumer VM',
            realm = 'client',
            params = {},
            returns = { { type = 'integer', doc = 'the ped handle, never nil -- it falls back to PlayerPedId() when the cache is 0' } },
        },
        GetCachedHeading = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.heading(), which reads the native directly in a consumer VM',
            realm = 'client',
            params = {},
            returns = { { type = 'number', doc = 'the heading in degrees, 0.0 before the first watchdog pass' } },
        },
        GetCachedVehicle = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.vehicle()',
            realm = 'client',
            params = {},
            returns = { { type = 'integer|nil, integer|nil', doc = 'slot 1 is NIL and not 0 when on foot -- a consumer that treats 0 as a handle gets a nil-index crash somewhere else. Slot 2 is the seat, -1 for the driver, and may itself be nil' } },
        },
        GetCachedWeapon = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.weapon()',
            realm = 'client',
            params = {},
            returns = { { type = 'CisWeaponData|nil', doc = 'nil when unarmed -- the whole record, not a table of nils' } },
        },
        GetCachedServerId = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.serverId()',
            realm = 'client',
            params = {},
            returns = { { type = 'integer', doc = '0 before the first watchdog pass' } },
        },
        GetCachedPlayerId = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.playerId()',
            realm = 'client',
            params = {},
            returns = { { type = 'integer', doc = 'the local player index. Falls back to PlayerId() when the cache is 0' } },
        },
        FollowCacheHeading = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.on("heading", fn) -- init.lua calls it for the first heading listener',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'true. From then until the caller stops, heading changes are pushed on the cis_libs:cache event; without a follower they are not pushed at all' } },
        },
        GetCacheSnapshot = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.* and Cis.cache(key) -- init.lua takes this once per consumer',
            realm = 'client',
            params = {},
            returns = { { type = 'CisCacheSnapshot', doc = 'every mirrored key in a fresh table; the consumer mirror is then kept current by the cis_libs:cache event' } },
        },
        GetCachedSeat = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.seat()',
            realm = 'client',
            params = {},
            returns = { { type = 'integer|nil', doc = 'nil on foot, never 0: 0 is a passenger seat. -1 is the driver' } },
        },
        OnPlayerCache = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.on(key, cb); stop it with RemovePlayerCacheListener(id)',
            realm = 'client',
            params = { { name = 'key', type = 'string', doc = 'one of aiming, armed, heading, ped, seat, shooting, vehicle, weapon. Anything else is refused with a reason. Coordinates are not a key: Cis.player.coords() is memoised per frame' }, { name = 'cb', type = 'function', doc = '`fun(current, previous)`, called under pcall on every change. A consumer function arrives as a funcref and is accepted; a stopped owner takes its listeners with it' } },
            returns = { { type = 'function|nil, integer|string', doc = 'the in-realm unsubscribe and the listener id, or nil plus a reason. The unsubscribe cannot be called from another resource; feed the id to RemovePlayerCacheListener. Vehicle and seat are both updated before either listener runs' } },
        },
        RemovePlayerCacheListener = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the id OnPlayerCache returns as its second value',
            realm = 'client',
            params = { { name = 'id', type = 'integer', doc = 'the id OnPlayerCache returned in slot two' } },
            returns = { { type = 'boolean, string|nil', doc = 'false plus a reason for an unknown id or a listener owned by another resource' } },
        },
        WatchNear = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.near(coords, distance, onEnter, onExit, onEnterEvent, onExitEvent)',
            realm = 'client',
            params = { { name = 'coords', type = 'vector3|table', doc = 'the point; nil is refused by name because the boundary dropped it' }, { name = 'distance', type = 'number', optional = true, doc = 'the radius, default 2.0' }, { name = 'onEnter', type = 'function', optional = true, doc = "called pcall'd with the distance on the inside edge" }, { name = 'onExit', type = 'function', optional = true, doc = "called pcall'd with the distance on the outside edge" }, { name = 'onEnterEvent', type = 'string', optional = true, doc = 'an event name, used only when onEnter is absent' }, { name = 'onExitEvent', type = 'string', optional = true, doc = 'an event name, used only when onExit is absent' } },
            returns = { { type = 'function, integer', doc = 'the in-realm unsubscribe and the watcher id -- feed slot two to RemoveNearWatcher. Refusal is nil plus a reason: coords that arrived as nil or lack finite numeric x, y and z, a distance that is not a finite number above 0, or an event name that is not a string' } },
        },
        RemoveNearWatcher = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.nearStop(id); the id WatchNear returns as its second value',
            realm = 'client',
            params = { { name = 'id', type = 'integer', doc = 'the id WatchNear returned as its second slot' } },
            returns = { { type = 'boolean, string', doc = 'true on success; false plus a reason for a non-number id, an unknown one, or one another resource owns (only the owner or cis_libs may remove it)' } },
        },

        -- ---------------------------------------------------------- platform
        -- The five exports below are the seam between this library and the
        -- products that plug into it. They are not consumer API -- a consumer
        -- calls `Cis.*` and never these -- but they are stable, they are what
        -- cis_core and cis_bridge call, and they are the reason a consumer's
        -- code does not change when the platform underneath it does.
        SetConfig = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by cis_core at boot with (config, security, discord). First registration wins; a second is refused and named. When the server convar cis_config_supplier names a resource, only that resource may call it. When cis_authorized_resources or cis_allow_any_resource is set, the security posture comes from the convars and the AuthorizedResources / AllowAnyResource passed here are ignored (DOCUMENTATION.md section 3). `security.AllowAnyResource` is the 1.0.0 opt-in escape hatch: with it true an EMPTY AuthorizedResources stops meaning restrictive, and the console warns on every boot',
            realm = 'server',
            params = { { name = 'config', type = 'table', optional = true, doc = 'merged over the defaults and validated on a COPY' }, { name = 'security', type = 'table', optional = true, doc = 'merged over fresh default Security key by key: a key left out keeps its default (DropPlayer stays true), and a second supply replaces the first, it does not add to it' }, { name = 'discord', type = 'table', optional = true, doc = 'sanitised into DiscordConfig' } },
            returns = { { type = 'boolean, string', doc = 'true once applied; false plus a reason naming the current owner, the pinned supplier, or listing the validation problems' } },
        },
        GetDiscordConfig = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The outbound/webhook configuration SetConfig was handed, for the capability that does the sending. Server realm only -- it holds webhook URLs and is deliberately not on the client payload whitelist',
            realm = 'server',
            params = {},
            returns = { { type = 'table', doc = "cis_libs's own webhook table; any other resource always gets {} and never nil" } },
        },
        RegisterCapability = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by cis_core, cis_bridge and cis_keys with (slot, "resource:Export"). Gated on Security.AuthorizedResources on both realms; among allowed callers the first registration wins',
            realm = 'both',
            -- THE THIRD PARAMETER WAS MISSING HERE AND HAS BEEN SINCE THE CONTRACT
            -- CHECK LANDED. The code has taken `contract` since the A1 work --
            -- a product declares `cis_libs_contract '2.1'` in its fxmanifest and
            -- a MAJOR mismatch is refused before anything else happens -- and the
            -- declaration still described two arguments. It passed because the
            -- signature rule compared only the names it was GIVEN, and a shorter
            -- declaration is not a subset check, it is a length check that happens
            -- to be one-directional.
            --
            -- Which is the lesson: a rule that compares declared names against
            -- source names finds a renamed parameter and finds a REMOVED one, but
            -- only because it compares the joined strings. Anything that compared
            -- "is every declared name present in the source" would have passed this
            -- forever.
            params = { server = { { name = 'slot', type = 'string', doc = 'a CisRegistry.SLOTS key; an unknown slot is refused before dispatch' }, { name = 'provider', type = 'string', doc = 'always "resource:Export" -- a function cannot cross the exports boundary and arrives as nil' }, { name = 'contract', type = 'string', optional = true, doc = "the caller's declared contract, normally the engine's own reading of its fxmanifest cis_libs_contract. A MAJOR mismatch is refused before dispatch, because a 3.x product registering into a 2.x cis_libs gets calls that return the wrong value for the right reason" } }, client = { { name = 'slot', type = 'string', doc = 'a CisRegistry.SLOTS key; an unknown slot is refused before dispatch' }, { name = 'provider', type = 'string|table|function', doc = 'a "resource:Export" string, a table carrying .resource, or a bare callable' }, { name = 'contract', type = 'string', optional = true, doc = 'as on the server: a MAJOR mismatch is refused before dispatch' } } },
            returns = { server = { { type = 'boolean, string', doc = 'true on registration; false plus a reason on a major contract mismatch, a caller off Security.AuthorizedResources, or a refusal' } }, client = { { type = 'boolean, string|nil', doc = "true, or false plus a reason naming the slot, the holder, or a caller off the server's allow-list. Before the server's allow-list reaches the client a foreign registration is held: true plus 'held until the server sends the allow-list', then filed or refused (and logged) when it arrives" } } },
        },
        UnregisterCapability = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by a product on shutdown or handover. Only the slot owner may release it',
            realm = 'server',
            params = { { name = 'slot', type = 'string', doc = 'the slot to release; only its current owner may release it' } },
            returns = { { type = 'boolean', doc = 'true released; false with NO reason at all when the caller is not the holder' } },
        },
        -- T9. Exists so START ORDER DOES NOT MATTER: a consumer that starts
        -- before the provider no longer has to poll, retry, or cache a nil it
        -- read during boot.
        WaitCapability = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Waits up to timeoutMs for a capability slot to be filled. Returns true and the owner, or nil and a reason naming the slot. No proxy equivalent -- a consumer waits from its own resource.',
            realm = 'server',
            params = { { name = 'slot', type = 'string', doc = 'the slot to wait on' }, { name = 'timeoutMs', type = 'integer', optional = true, doc = 'the deadline in ms; the registry defaults it to 30000 and nothing here does' } },
            returns = { { type = 'boolean, string', doc = 'true plus the owning resource, or false plus a reason naming the slot and what is still missing' } },
        },
        GetDiagnostics = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Counts, never player data: capability slots and owners, sync records by owner, pending callbacks, net handlers, error and warning counters, memory, uptime, and pass timings. The harness diffs counters and probes only; timings are a sibling so a pass does not fail every case',
            realm = 'both',
            params = { { name = 'opts', type = 'table', optional = true, doc = 'opts.collect = true runs collectgarbage in THIS resource before counting. A collect in the caller VM does not collect cis_libs' } },
            returns = { server = { { type = 'CisDiagnostics', doc = "CisDiagnostics.Collect('server'): counts and counters only, never player data" } }, client = { { type = 'CisDiagnostics', doc = "CisDiagnostics.Collect('client'): counts only. A probe that raises reports itself as <name>Error rather than failing the snapshot" } } },
        },
        GetSelfCheck = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The boot self-check as data: { ok, problems = { { code, message, fix } } }. Each problem names the change that resolves it',
            realm = 'server',
            params = {},
            returns = { { type = 'CisSelfCheck', doc = 'ok, problems and checkedAt. ok = true with checkedAt = nil means the scan has not run yet -- not that the install is clean, and the two look the same to a caller' } },
        },
        GetCapabilities = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The one call that answers "which of my four resources is actually running". Returns { [slot] = { owner, resolved } }',
            realm = 'both',
            params = {},
            returns = { server = { { type = 'table<string, table>', doc = 'every SLOTS key with its owner, its resolved flag and its missing methods' } }, client = { { type = 'table<string, table>', doc = 'every SLOTS key, always present; a slot with no provider is owner = nil and resolved = false, never absent' } } },
        },
        GetKnownTargets = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge detection',
            realm = 'both',
            params = {},
            returns = { server = { { type = 'table', doc = '{ frameworks, databases }, each defaulting to {} so neither is ever nil' } }, client = { { type = 'table', doc = '{ frameworks, databases }, each an array of { name, resource, probe } and both defaulting to {}' } } },
        },
        DetectFramework = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge detection',
            realm = 'both',
            params = { server = { { name = 'configured', type = 'string', optional = true, doc = "the operator's framework preference; nil means AUTO and the callee uppercases it" }, { name = 'custom', type = 'table', optional = true, doc = 'product-supplied detection overrides, handed through untouched' } }, client = { { name = 'configured', type = 'string', optional = true, doc = "the operator's framework preference; nil means AUTO" }, { name = 'custom', type = 'table', optional = true, doc = 'an operator adapter needing .resource, and optionally .getPlayer, .probe and .name' } } },
            returns = { server = { { type = 'CisDetection', doc = 'name, resource, version, how and reason. A refusal is name = "NONE" with the reason in .reason -- never nil, because nil and "not found" would be the same value' } }, client = { { type = 'CisDetection', doc = 'the same shape as the server answer, plus wanted = true on a configured known framework' } } },
        },
        DetectDatabase = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge detection',
            realm = 'both',
            params = { { name = 'configured', type = 'string', optional = true, doc = "the operator's driver preference; nil means AUTO" } },
            returns = { server = { { type = 'CisDetection', doc = 'the same { name, resource, version, how, reason } shape as DetectFramework' } }, client = { { type = 'CisDetection', doc = 'the same shape as the server answer' } } },
        },
        SetDropPlayerHandler = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by whoever ships the config, with "resource:Export". A FUNCTION cannot be sent across the boundary, which is why this exists',
            realm = 'server',
            params = { { name = 'provider', type = 'string', doc = 'a "resource:Export" string in the same form RegisterCapability takes, for the same reason: a function cannot cross the boundary' } },
            returns = { { type = 'boolean, string', doc = 'the raw result of the registry register: true, or false plus a reason. Allow-list gated: a caller off Security.AuthorizedResources is refused before the slot is touched, because the first caller takes it' } },
        },
        PublishJobUpdate = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by cis_core or any bridge target when a player changes job. Fires cis_libs:jobUpdated, so the event name stays owned by this library',
            realm = 'server',
            params = { { name = 'job', type = 'table', doc = 'the job record; a non-table is refused by name' }, { name = 'src', type = 'integer', optional = true, doc = 'the player to tell; nil broadcasts to every client' } },
            returns = { { type = 'boolean, string', doc = "true after the event is fired; false plus 'job must be a table', a reason naming Security.AuthorizedResources, or a reason when src is given but is not a connected player" } },
        },
        PublishPlayerLoaded = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by cis_core or any bridge target when a player object exists. Fires cis_libs:playerLoaded',
            realm = 'server',
            params = { { name = 'job', type = 'table', doc = 'the job record; only a table is remembered, but the value is sent as given' }, { name = 'src', type = 'integer', optional = true, doc = 'the one client to tell; nil means the event is never fired and true is still returned. A src that is not a connected player is refused' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once published; false plus a reason when the caller is not on Security.AuthorizedResources (it writes the same job histogram PublishJobUpdate does) or src is not a connected player' } },
        },
        NotifyClient = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by a product to show a notification to one client, without hardcoding the event name owned by this library. Answers `false, reason` for a src that is not a connected player, truncates a message past 512 characters, and allows 10 a second per (src, calling resource)',
            realm = 'server',
            params = { { name = 'src', type = 'integer', doc = 'a connected player id above 0' }, { name = 'message', type = 'string', doc = 'the text; over 512 characters it is truncated, not refused' }, { name = 'kind', type = 'string', optional = true, doc = 'forwarded to the client event unvalidated' } },
            returns = { { type = 'boolean, string', doc = 'true once fired; false plus a reason for a bad src, a disconnected player, or the rate limit' } },
        },
        RemovePoint = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.points.remove(id)',
            realm = 'client',
            params = { { name = 'id', type = 'integer', doc = 'the id CreatePoint returned' } },
            returns = { { type = 'boolean, string|nil', doc = 'false when no point holds that id, which is a no-op and not an error; false plus a reason when the point belongs to another resource (only the owner, or cis_libs, may remove it). A point the player was inside fires onExit first, with the PLAYER coordinates and not the point coordinates' } }
        },
        AudioBank = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.streaming.audioBank(name, timeout)',
            realm = 'client',
            params = { { name = 'name', type = 'string', doc = 'the bank name' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
            returns = { { type = 'string|nil, string|nil', doc = 'the name once RequestScriptAudioBank answers true. The native is its own poll -- false while the bank loads -- so it is called again until true or the timeout, and a timed-out bank is released by name' } }
        },
        Ptfx = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.streaming.ptfx(name, timeout)',
            realm = 'client',
            params = { { name = 'name', type = 'string', doc = 'the effect name' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
            returns = { { type = 'string|nil, string|nil', doc = 'the name, or nil plus a reason. NO existence probe exists for this kind, so an invalid name costs the whole timeout -- a real asymmetry with AnimDict, documented rather than papered over' } }
        },
        Scaleform = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.streaming.scaleform(name, timeout)',
            realm = 'client',
            params = { { name = 'name', type = 'string', doc = 'the movie name' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
            returns = { { type = 'string|nil, integer|nil, string|nil', doc = 'the name and the movie handle, or nil plus a reason. RequestScaleformMovie ANSWERS the handle and returns 0 when it refuses, which is a real third state between not-yet and loaded' } }
        },
        TextureDict = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.streaming.textureDict(name, timeout)',
            realm = 'client',
            params = { { name = 'name', type = 'string', doc = 'the dictionary name' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
            returns = { { type = 'string|nil, string|nil', doc = 'the name, or nil plus a reason. The request native takes a streamed flag as its second argument and it is always true here' } }
        },
        WeaponAsset = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.streaming.weaponAsset(hash, timeout)',
            realm = 'client',
            params = { { name = 'name', type = 'integer', doc = 'the weapon HASH, passed through the parameter called name so all seven registrations share one shape' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
            returns = { { type = 'integer|nil, string|nil', doc = 'the hash, or nil plus a reason' } }
        },
        RequestInventorySync = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge inventory API',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'true once the server event was fired; false, and nothing sent, when the 15s ready wait fails' } },
        },
        PublishInventory = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge inventory API',
            realm = 'server',
            params = { { name = 'src', type = 'integer', doc = 'a connected player id above 0' } },
            returns = { { type = 'boolean, string|nil', doc = 'true after the snapshot is pushed; false with no reason for a bad src or a failed provider call, a reason naming the allow-list otherwise' } },
        },

        -- ---------------------------------------------------------- framework
        GetNormalizedPlayer = {
            since = '1.0.0', ['until'] = '2.0.0', stable = true, deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge player API',
            realm = 'server',
            params = { { name = 'src', type = 'integer', doc = 'the player id, handed to the provider with no local check' } },
            returns = { { type = 'table|nil', doc = "the provider's record. The reason cannot ride in the return list: a nil FIRST value truncates it at the exports boundary, so a no-provider refusal is structurally incapable of carrying one" } },
        },
        Notify = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.framework.notify(...). With a framework provider registered the call passes through to it untouched; with none, cis_libs delivers it itself through the same guards NotifyClient uses, so a server with no framework does not go mute and does not become the unbounded path. The two-argument client form sends `kind` in the message slot; this is pinned as a known defect in test/contracts.lua and is a MAJOR change to correct',
            realm = 'both',
            params = { server = { { name = 'src', type = 'integer', doc = 'a connected player id above 0; console and broadcast included, anything else refuses' }, { name = 'message', type = 'string', doc = 'the text; over 512 characters it is TRUNCATED, not refused' }, { name = 'kind', type = 'string', optional = true, doc = 'forwarded to the provider and the client event unvalidated' } }, client = { { name = 'message', type = 'any', why = 'stringified on the native-feed path and passed through untouched on the framework path, so the two disagree about what is legal and the union is the honest answer', doc = 'the text, stringified on the native-feed path and passed through on the framework path' }, { name = 'kind', type = 'any', optional = true, why = 'forwarded verbatim to ShowNotification or the provider; this library assigns no vocabulary to it, so anything is a type this code cannot narrow', doc = 'forwarded verbatim as the second argument to ShowNotification' } } },
            returns = { server = { { type = 'boolean, string', doc = 'true, or false plus a reason for a bad src, a disconnected player, or the rate limit' } }, client = { { type = 'any, string|nil', why = "the provider's own value, handed back as it came; there is no registered contract for this slot's result, so narrowing it would be inventing one", doc = 'with a provider, every value it produced; with NO framework registered, nothing is returned at all -- not even nil' } } },
        },
        GetOnlineJobCount = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the callback cis_libs:getOnlineJobCount',
            realm = 'server',
            params = { { name = 'jobs', type = 'string|string[]', doc = 'a bare job name or an array of them; ESX supplies a name and QBCore a table, and both normalise here' } },
            returns = { { type = 'integer', doc = 'never nil: an unknown name, an empty list and a nil are all 0, and none of the three is distinguishable from the others' } },
        },
        -- A read refusal answers nil, because `if not rows` is what callers
        -- write -- and a nil FIRST value truncates the return list at the
        -- exports boundary, so the reason cannot ride along in it. This carries
        -- it out of band instead. Scoped to the calling resource and cleared by
        -- the next successful call.
        GetLastRefusal = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Read after a nil/false answer from a capability export to learn WHY it was refused. Returns a sentence naming the missing or failing capability, or nil when the last call succeeded. Additive: no existing return shape changes',
            realm = 'server',
            params = {},
            returns = { { type = 'string|nil', doc = 'the reason THIS resource last stored on a capability refusal, cleared on success because a stale reason is worse than none' } },
        },
        -- The audit ring is in MEMORY, read through this export or the
        -- restricted `cis_audit [n]` console command. cis_libs writes no files, so
        -- there is nothing on disk to read.
        GetAuditLog = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The capability and configuration change log, newest last. Gated on Security.AuthorizedResources like every other mutating call. Entries carry resource and slot names and never a player name, identifier or IP. Bounded by Config.AuditLines, default 500',
            realm = 'server',
            params = { { name = 'limit', type = 'integer', optional = true, doc = 'how many entries to return; under 1 means every entry the ring holds' } },
            returns = { { type = 'CisAuditEntry[]|boolean, string', doc = 'the entries newest first, or false plus a reason when the caller is off Security.AuthorizedResources' } },
        },

        -- ----------------------------------------------------------- security
        -- `opts` is forwarded, and the registration result is returned.
        -- Both used to be dropped -- so a consumer's rate limit was silently
        -- ignored and a refusal was indistinguishable from a success.
        SecureNetOn = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.net.on(name, fn, opts) -> true when the event was bound',
            realm = 'server',
            params = { { name = 'name', type = 'string', doc = 'the net event name, used verbatim with no prefix added' }, { name = 'fn', type = 'function|string|table', doc = 'a function -- including one passed from another resource, which arrives as a callable reference table and is released when that resource stops -- or a "resource:Export" string; anything else registers nothing' }, { name = 'opts', type = 'table', optional = true, doc = 'windowMs and maxHits default to 1000 and 8. Every payload is size-bounded before the schema and the handler: maxArgs (32), maxStringLen (Config.CallbackLimits.MaxStringLen, 4096; keys and values), maxEntries (256, counted across the whole payload) and maxDepth (8) may each be raised or lowered per handler, and a malformed one refuses the registration. schema, if present, is a map of field -> { type, min, max, maxLen, optional, finite } checked against the FIRST payload table before the handler runs; type is a Lua type name or integer (whole, finite, within +-2^53), and a number is refused when NaN, or infinite unless finite = false. An oversized payload or a schema failure is refused, counted as netSchemaRefused and reported' } },
            returns = { { type = 'boolean', doc = 'true once bound -- and true says nothing about rate limiting, which happens at dispatch. false when the handler cannot be resolved, with a reason naming the resource and export, or when a resource binds another resource export: the owner is always the caller. The rate limit runs first, then the size bound, then the schema. A bad payload is reported once per player and event per run: a run ends after max(5000, 2 * windowMs) ms with no bad payload of that event, so a repeat after a pause is reported again while a flood stays one report' } },
        },
        SecurityReport = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.security.report(src, reason)',
            realm = 'server',
            params = { { name = 'src', type = 'integer', doc = 'the player to act on; a player who already left cannot be dropped and is refused' }, { name = 'reason', type = 'string', doc = 'the operator-facing reason, logged and handed to the security drop capability' } },
            returns = { { type = 'boolean', doc = 'true when a drop capability handled it or DropPlayer was issued; false on a bad src, a disconnected player, or no drop capability and no Security.DropPlayer' } },
        },
        InvokingAllowed = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; ask before mutating. This is the supported way to avoid a refusal',
            realm = 'server',
            params = {},
            returns = { { type = 'boolean', doc = 'true when undecided, or when the caller is cis_libs itself; false is the restrictive refusal and names nothing, which is why SetConfig prints the summary' } },
        },
        RateOk = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; a resource may share the library rate limiter',
            realm = 'server',
            params = { { name = 'src', type = 'integer', doc = 'the bucket owner, and the player id for a public handler' }, { name = 'name', type = 'string', doc = 'the bucket key inside that src; the rate is per (src, name), never shared across names' }, { name = 'windowMs', type = 'integer', optional = true, doc = 'the window in ms, default 1000 -- a fixed window, not a sliding one' }, { name = 'maxHits', type = 'integer', optional = true, doc = 'the hits allowed inside it, default 8' } },
            returns = { { type = 'boolean', doc = 'true on an allowed hit, and true is not free: it consumes a slot in the (src, name) window. false when the hit exceeds maxHits, or, with a second value cap, when the src holds 256 live buckets and this name is new (expired buckets are evicted first). A string src is the same player as its number' } },
        },
        GetLibsPrefix = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the configured Security.EventPrefix',
            realm = 'server',
            params = {},
            returns = { { type = 'string', doc = 'Security.EventPrefix when set, else the literal default "cis_libs"' } },
        },

        -- -------------------------------------------------------- diagnostics
        GetConfigSummary = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the non-secret half of the server config',
            realm = 'server',
            params = {},
            returns = { { type = 'table', doc = 'a summary safe to log: no webhook, no allow-list, no credentials' } },
        },
        GetClientConfig = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; the config the server sent to this client',
            realm = 'client',
            params = {},
            returns = { { type = 'table|nil', doc = 'the whitelisted Config this client was actually given -- no webhooks, no database settings, no allow-list, and no reason the allow-list should ever ship to a client' } },
        },
        IsReady = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.isReady, or Cis.ready(cb)',
            realm = 'client',
            params = {},
            returns = { { type = 'boolean', doc = 'strictly boolean and never blocking. FAILED and NOT-YET both read false, so it is not a failure test' } },
        },
        WaitReady = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.ready(cb, timeout) or Cis.wait(timeout)',
            realm = 'both',
            params = { { name = 'timeout', type = 'integer', optional = true, doc = 'the deadline in ms, default 15000. ONE deadline for the whole call, not one per stage' } },
            returns = { { type = 'boolean', doc = 'true once the gate settled ready, false if it failed or the deadline passed' } },
        },
        ReadyState = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.isReady and Cis.isFailed, which read through to this in a consumer',
            realm = 'both',
            params = {},
            returns = { { type = 'boolean, boolean, string|nil', doc = 'ready, failed, and the failure reason. Never blocks; NOT-YET is false, false' } },
            note = 'The gate as another Lua state can see it. cis_libs writes `Cis.isReady` into its OWN Cis table, which a consumer never sees, so a consumer\'s `Cis.isReady` and `Cis.isFailed` read through to this export (lazily, and only until the gate settles).',
        },
        GetDiscordQueueDepth = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; queued message count and dropped count',
            realm = 'server',
            params = {},
            returns = { { type = 'integer', doc = '0 when no discord provider is registered' } },
        },
        GetLogging = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.debug / info / warn / error',
            realm = 'server',
            params = {},
            returns = { { type = 'table', doc = "the live Logging table, not a copy -- writing to it mutates the library's logger" } },
        },
        GetClientLogging = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.debug / info / warn / error',
            realm = 'client',
            params = {},
            returns = { { type = 'table', doc = 'the shared Logging global, the same table every module in the resource reads' } },
        },
        SendDiscordLog = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.info with a discordType; no proxy equivalent for a raw webhook push',
            realm = 'server',
            params = { { name = 'webhookURL', type = 'string', doc = 'the webhook, posted to the provider; never validated or stored here' }, { name = 'title', type = 'string', doc = 'the title' }, { name = 'message', type = 'string', doc = 'the text -- unlike Notify this is NOT length-capped here' }, { name = 'color', type = 'integer', doc = 'the embed colour' }, { name = 'ping', type = 'string|integer', doc = 'what to ping, forwarded unvalidated' } },
            returns = { { type = 'any', why = "the provider's own value, handed back as it came; there is no registered contract for this slot's result, so narrowing it would be inventing one", doc = "the provider's result; nil when no discord provider is registered, reason via GetLastRefusal" } },
        },

        -- ----------------------------------------------------------- logging
        LogDebug = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.debug(message)',
            realm = 'both',
            params = { server = { { name = 'message', type = 'string', doc = "the text; tostring'd, so any value prints" }, { name = 'discordType', type = 'string', optional = true, doc = "the Discord CHANNEL, not the severity: 'cheating' and 'error' route pinged, anything else the master channel unpinged" } }, client = { { name = 'message', type = 'any', why = 'stringified with tostring before printing, so any value is accepted and the console line is the only observable', doc = 'stringified with tostring before printing' } } },
            returns = { server = { { type = 'nil', doc = 'nothing comes back; the console line and a diagnostics counter are the whole effect, and with Config.Printing.Debug off this prints nothing at all' } }, client = { { type = 'nil', doc = 'nothing comes back; the console line and a diagnostics counter are the whole effect; DEBUG is the one gated level' } } },
        },
        LogInfo = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.info(message)',
            realm = 'both',
            params = { server = { { name = 'message', type = 'string', doc = "the text; tostring'd, so any value prints" }, { name = 'discordType', type = 'string', optional = true, doc = "the Discord CHANNEL, not the severity: 'cheating' and 'error' route pinged, anything else the master channel unpinged" } }, client = { { name = 'message', type = 'any', why = 'stringified with tostring before printing, so any value is accepted and the console line is the only observable', doc = 'stringified with tostring before printing' } } },
            returns = { server = { { type = 'nil', doc = 'nothing comes back; the console line and a diagnostics counter are the whole effect' } }, client = { { type = 'nil', doc = 'nothing comes back; the console line and a diagnostics counter are the whole effect; INFO is never gated' } } },
        },
        LogWarn = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.warn(message)',
            realm = 'both',
            params = { server = { { name = 'message', type = 'string', doc = "the text; tostring'd, so any value prints" }, { name = 'discordType', type = 'string', optional = true, doc = "the Discord CHANNEL, not the severity: 'cheating' and 'error' route pinged, anything else the master channel unpinged" } }, client = { { name = 'message', type = 'any', why = 'stringified with tostring before printing, so any value is accepted and the console line is the only observable', doc = 'stringified with tostring before printing' } } },
            returns = { server = { { type = 'nil', doc = 'nothing comes back; the console line and a diagnostics counter are the whole effect' } }, client = { { type = 'nil', doc = 'nothing comes back; the console line and a diagnostics counter are the whole effect; the warnings counter increments first' } } },
        },
        LogError = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.error(message)',
            realm = 'both',
            params = { server = { { name = 'message', type = 'string', doc = "the text; tostring'd, so any value prints" }, { name = 'discordType', type = 'string', optional = true, doc = 'the Discord channel, as for LogDebug' }, { name = 'errorInfo', type = 'table', optional = true, doc = "the caller's file, line, event and stackTrace; present means a short console line and a full Discord post" } }, client = { { name = 'message', type = 'any', why = 'stringified with tostring before printing, so any value is accepted and the console line is the only observable', doc = 'stringified with tostring before printing' } } },
            returns = { server = { { type = 'nil', doc = 'nothing comes back; the console line and a diagnostics counter are the whole effect' } }, client = { { type = 'nil', doc = 'nothing comes back; the console line and a diagnostics counter are the whole effect; the errors counter increments first' } } },
        },
        AutoLogError = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.error(message) from inside a pcall',
            realm = 'both',
            params = { server = { { name = 'err', type = 'any', why = "the pcall error slot, which is an object rather than a string on some raises; the library tostring's it before logging", doc = "the pcall error slot; traceback wants a string, so hand it the raise's own text" }, { name = 'event', type = 'string', doc = 'the net event name, recorded as errorInfo.event' } }, client = { { name = 'err', type = 'any', why = "the pcall error slot, which is an object rather than a string on some raises; the library tostring's it before logging", doc = 'the pcall error slot' }, { name = 'context', type = 'string', optional = true, doc = 'a label for where it happened; nil falls back to "Unknown"' } } },
            returns = { { type = 'nil', doc = 'nothing comes back; the console line and a diagnostics counter are the whole effect' } },
        },

        -- --------------------------------------------------------- utilities
        Round = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; math round to n places',
            realm = 'client',
            params = { { name = 'num', type = 'number', doc = 'any number string.format accepts' }, { name = 'numDecimalPlaces', type = 'integer', optional = true, doc = 'the decimal places, default 0' } },
            returns = { { type = 'number', doc = 'the rounded value, always a number' } },
        },
        RandomFloat = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent',
            realm = 'client',
            params = { { name = 'lower', type = 'number', doc = 'the lower bound' }, { name = 'greater', type = 'number', doc = 'the upper bound' } },
            returns = { { type = 'number', doc = 'lower + math.random() * (greater - lower)' } },
        },
        GetTableSize = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent',
            realm = 'client',
            params = { { name = 't', type = 'table', doc = 'any table; counted with pairs, so array holes and non-integer keys both count' } },
            returns = { { type = 'integer', doc = 'the key count, 0 for an empty table' } },
        },
        GetDistanceBetweenCoords = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent',
            realm = 'client',
            params = { { name = 'x1', type = 'number', doc = 'first point X' }, { name = 'y1', type = 'number', doc = 'first point Y' }, { name = 'z1', type = 'number', doc = 'first point Z' }, { name = 'x2', type = 'number', doc = 'second point X' }, { name = 'y2', type = 'number', doc = 'second point Y' }, { name = 'z2', type = 'number', doc = 'second point Z' }, { name = 'useZ', type = 'boolean', optional = true, doc = 'false measures on the ground plane, as the native does; omitted is 3D. The Lua global is CisGetDistanceBetweenCoords -- the native keeps its own name' } },
            returns = { { type = 'number', doc = 'the straight-line distance between the two points' } },
        },
        DrawText3D = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent',
            realm = 'client',
            params = { { name = 'x', type = 'number', doc = 'world X' }, { name = 'y', type = 'number', doc = 'world Y' }, { name = 'z', type = 'number', doc = 'world Z' }, { name = 'text', type = 'string', doc = 'the text, measured with string.len' }, { name = 'settings', type = 'table', optional = true, doc = '{ scale, font, color, center }, or a bare colour rewrapped as { color = settings }' } },
            returns = { { type = 'nil', doc = 'nothing comes back, and nothing is drawn off-screen or within 0.01 of the camera' } },
        },
        CreatePed = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; returns 0 on an invalid or unloaded model. The Lua global is CisCreatePed -- the CreatePed native keeps its own name',
            realm = 'client',
            params = { { name = 'model', type = 'integer|string', doc = 'a hash or a model name; a number passes through, anything else goes through joaat' }, { name = 'coords', type = 'vector3|table', doc = 'the placement, read as .x/.y/.z; nil or a table with no numeric x/y/z answers 0 before any model is requested' }, { name = 'heading', type = 'number', optional = true, doc = 'the heading, default 0.0' }, { name = 'options', type = 'table', optional = true, doc = 'the options table, defaulted to {}' } },
            returns = { { type = 'integer', doc = 'the ped handle, or 0 when the model failed to load -- 0 and not nil, so callers test one shape' } },
        },
        DebugLog = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.log.debug(message)',
            realm = 'client',
            params = { { name = 'message', type = 'any', why = 'concatenated through tostring, so any value is safe', doc = 'no type requirement; it is concatenated through tostring' } },
            returns = { { type = 'nil', doc = 'nothing comes back, and nothing prints unless Config.Printing.Debug is set' } },
        },
        GetAllPoints = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.points.getAll()',
            realm = 'client',
            params = {},
            returns = { { type = 'integer[]', doc = 'the ids of the CALLER own points, ascending; cis_libs sees every point' } }
        },
        GetNearbyPoints = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.points.getNearby()',
            realm = 'client',
            params = {},
            returns = { { type = 'integer[]', doc = 'the ids of the CALLER own points the player is inside right now, ascending' } }
        },
        GetCurrentZones = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.getCurrent()',
            realm = 'client',
            params = {},
            returns = { { type = 'string[]', doc = 'the names of the CALLER own zones the player is inside, sorted; cis_libs sees every zone' } }
        },
        GetAllZones = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.getAll()',
            realm = 'client',
            params = {},
            returns = { { type = 'string[]', doc = 'the names of the CALLER own zones, sorted' } }
        },
        GetNearbyZones = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.zones.getNearby(coords, radius)',
            realm = 'client',
            params = { { name = 'coords', type = 'vector3|table', optional = true, doc = 'default the player coords' }, { name = 'radius', type = 'number', optional = true, doc = 'metres on the ground plane, default 50' } },
            returns = { { type = 'string[]', doc = 'the names of the CALLER own zones whose footprint comes within radius, sorted; empty for a bad radius' } }
        },
        GetClosestPoint = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.points.getClosest()',
            realm = 'client',
            params = {},
            returns = { { type = 'integer|nil, number|string|nil', doc = 'the nearest of the CALLER\'S OWN points (cis_libs sees every point) and the distance in metres, or nil plus a reason -- also when the player position has no numeric x/y/z. TWO SHAPES in the second slot, and a caller that only tests the first has to know which one it got' } }
        },
        GetClosestVehicle = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; a 5 unit forward ray, then the nearest vehicle in the CVehicle pool within 5 units. The Lua global is CisGetClosestVehicle; the native GetClosestVehicle is left alone',
            realm = 'client',
            params = {},
            returns = { { type = 'integer', doc = 'the aimed-at vehicle within 5m, else the nearest within 5m, else 0 -- and 0, not nil' } },
        },
        GetVehicleProperties = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.vehicle.getProperties(vehicle) -- the same engine, in the caller VM',
            realm = 'client',
            params = { { name = 'vehicle', type = 'integer', doc = 'the entity handle; a non-existent entity is the nil case' } },
            returns = { { type = 'CisVehicleProps|nil', doc = 'the full property record, or nil when DoesEntityExist fails' } },
        },
        SetVehicleProperties = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'no proxy equivalent; applies every field present, every time (there is no diff)',
            realm = 'client',
            params = { { name = 'vehicle', type = 'integer', doc = 'the entity handle; a non-existent entity refuses' }, { name = 'props', type = 'table', doc = 'a PARTIAL table is safe -- absent keys are left alone rather than zeroed, which is the opposite of most setters and worth knowing' }, { name = 'fixVehicle', type = 'boolean', optional = true, doc = 'truthy calls SetVehicleFixed FIRST, so saved damage in props survives the repair' } },
            returns = { { type = 'boolean, string|nil', doc = 'true once applied; false plus a reason on a dead entity, a non-table props, or a networked vehicle this client does not control -- control is requested and NOTHING is written, so retry' } },
        },
        GetPlayerVehicleSeat = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.vehicle(), second return value',
            realm = 'client',
            params = {},
            returns = { { type = 'integer|nil', doc = 'the seat, -1 for the driver; nil when on foot or the seat cannot be resolved' } },
        },
        GetCurrentWeaponData = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.player.weapon()',
            realm = 'client',
            params = { { name = 'ped', type = 'integer', optional = true, doc = 'the ped; the cache is consulted only when this equals CisCache.ped' } },
            returns = { { type = 'CisWeaponData', doc = 'hash, ammo, ammoType and attachments -- and the LIVE CisCache table itself when served from the cache, so a caller holding it across frames is holding a snapshot' } },
        },
        RequestModelTimeout = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Cis.streaming.model(model, timeout)',
            realm = 'client',
            params = { { name = 'model', type = 'integer|string', doc = 'a hash or a model name' }, { name = 'timeout', type = 'integer', optional = true, doc = 'the deadline in ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
            returns = { { type = 'boolean, integer', doc = 'slot 2 is ALWAYS the hash, including on refusal -- so a caller can release it either way, which is the whole reason the export shape is a pair' } },
        },

        -- ------------------------------------------------------------ version
    },

    -- Every name below is fired or listened for BY THIS RESOURCE. That is the
    -- rule, and it is why the doorlock names and the framework event names are
    -- absent: they belong to the products that own those concerns now
    -- (cis_keys and cis_core respectively). A net event name that moves between
    -- resources is a name a product can rename without anyone noticing until a
    -- consumer silently stops hearing about it.
    --
    -- `cis_libs:jobUpdated` and `cis_libs:playerLoaded` used to be fired by the
    -- framework layer and are now fired HERE, by a product calling
    -- PublishJobUpdate / PublishPlayerLoaded. The name and the payload shape are
    -- unchanged, so a consumer listening for them keeps working across a
    -- framework change -- which is the whole reason they stayed in this file.
    -- =================================================== functions
    --
    -- The `Cis.*` surface -- what a consumer actually calls, from
    --
    --     shared_script '@cis_libs/init.lua'
    --     Cis.db.query('SELECT * FROM players WHERE id = ?', { id })
    --
    -- Every entry here is a hand-written proxy in init.lua that crosses the
    -- exports boundary, and each one is a place a name, an argument or a realm
    -- can drift away from the export behind it. tools/scan-cis.js reads those
    -- proxies and the validator compares them against what is written here, so
    -- editing init.lua without editing this block fails the build rather than
    -- publishing a contract that no longer describes the code.
    --
    -- `realm` is WHERE THE REAL FUNCTION IS DEFINED, not where it is callable.
    --
    -- Eighteen client-only functions are also DEFINED on the server, where each
    -- answers `false, 'client only'` rather than raising: a raise takes the
    -- caller's thread down and names no fix, so the report becomes "cis_libs is
    -- broken" rather than "you called a client function from the server". The
    -- validator checks those stubs exist rather than reporting them as a second
    -- definition, because a refusal stub is not a second implementation.
    --
    -- `forwardsTo` is the export a proxy crosses to, and it is CHECKED: the
    -- export has to exist and it has to be on the same realm. A proxy that
    -- forwards to a server-only export from a client-only function is a build
    -- failure, not a comment.
    --
    -- `runsIn = 'consumer'` (1.1.0) marks a function that, called from a
    -- consumer, does NOT cross: it runs an engine from client/core/*.lua in the
    -- consumer's own VM (DOCUMENTATION.md §5.2). Such a function has no
    -- `forwardsTo`; in cis_libs' own VM the older ones still reach the export
    -- they always did, which is why those exports keep their declarations.
    functions = {
    ['Cis.callback.await'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'AwaitCallback',
        params = { { name = 'name', type = 'string', doc = 'a registered name' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the arguments for the handler' } },
        returns = { { type = 'any', why = "the handler's own result list, whose arity and types the handler alone decides -- the handler is a function in another resource, and its return contract is that resource's, not this library's", doc = "the handler's results, and on the server they survive a nil in the middle. A refusal RAISES rather than returning, so a caller that does not pcall takes the hit -- tryAwait is the non-raising form" } },
    },
    ['Cis.callback.awaitClient'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'AwaitCallbackClient',
        params = { { name = 'src', type = 'integer', doc = 'the target player' }, { name = 'name', type = 'string', doc = 'the callback the CLIENT answers' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the arguments; the client caps them at 32' } },
        returns = { { type = 'boolean, any', why = "the handler's own result list, whose arity and types the handler alone decides -- the handler is a function in another resource, and its return contract is that resource's, not this library's", doc = "true plus the client's results; false plus a reason for a bad target, a disconnect, a timeout or a drop" } },
    },
    ['Cis.callback.call'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'CallCallback',
        params = { { name = 'name', type = 'string', doc = 'a registered name' }, { name = 'cb', type = 'function', optional = true, doc = 'the callback, invoked with the whole reply. It COSTS A COROUTINE PER CALL, which is what the caller was already paying for an await, and it is the only way to give a callback-style API to a consumer that cannot pass a function across' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the arguments for the handler' } },
        returns = { { type = 'nil', doc = 'nothing comes back: the answer only ever arrives as cb(ok, ...). On the client the pending key is discarded' } },
    },
    ['Cis.callback.callClient'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'CallCallbackClient',
        params = { { name = 'src', type = 'integer', doc = 'the target player' }, { name = 'name', type = 'string', doc = 'the callback the CLIENT answers' }, { name = 'cb', type = 'function', optional = true, doc = 'a consumer-side function, consumed on the consumer side, so it does not cross' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the arguments; the client caps them at 32' } },
        returns = { { type = 'string', doc = 'the pending key, an opaque random token. A bad target returns nothing and instead calls cb(false, reason)' } },
    },
    ['Cis.callback.register'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'RegisterCallback',
        params = { { name = 'name', type = 'string', doc = 'a non-empty handler name' }, { name = 'handler', type = 'function|string', doc = "a function (from any resource; it crosses as a callable reference and is released when that resource stops) or a 'resource:Export' string" }, { name = 'opts', type = 'table', optional = true, doc = "server only: { remote, ace, schema, maxStringLen }, as RegisterCallback" } },
        returns = { { type = 'boolean, string|nil', doc = "true once bound; false plus the reason on a refusal. From a consumer it is bound again when cis_libs restarts" } },
    },
    ['Cis.callback.tryAwait'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'TryAwaitCallback',
        params = { { name = 'name', type = 'string', doc = 'a registered name' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the arguments for the handler' } },
        returns = { { type = 'boolean, any', why = "the handler's own result list, whose arity and types the handler alone decides -- the handler is a function in another resource, and its return contract is that resource's, not this library's", doc = 'true plus the whole result list, so a nil in the middle survives; false plus a reason otherwise. Never raises' } },
    },
    ['Cis.callback.tryAwaitWithin'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'TryAwaitCallbackWithin',
        params = { { name = 'name', type = 'string', doc = 'a registered name' }, { name = 'timeoutMs', type = 'number', doc = 'this call own timeout in milliseconds, (0, 300000]' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the arguments for the handler' } },
        returns = { { type = 'boolean, any', why = "the handler's own result list, whose arity and types the handler alone decides", doc = "true plus the whole result list; false plus a reason ('timeout' once the limit passes). Never raises" } },
    },
    ['Cis.callback.awaitWithin'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'TryAwaitCallbackWithin',
        params = { { name = 'name', type = 'string', doc = 'a registered name' }, { name = 'timeoutMs', type = 'number', doc = 'this call own timeout in milliseconds, (0, 300000]' }, { name = '...', type = '...', optional = true, variadic = true, doc = 'the arguments for the handler' } },
        returns = { { type = 'any', why = "the handler's own result list, whose arity and types the handler alone decides", doc = 'the result list; RAISES with the callback name and the reason on a refusal or timeout, as await does' } },
    },
    ['Cis.db.insert'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'DbInsert',
        params = { { name = 'sql', type = 'string', doc = 'the statement' }, { name = 'params', type = 'table|any', optional = true, why = "the driver's own bind-parameter format, passed through unexamined. This is the seam to whatever driver is registered, and a library that typed it would be typing somebody else's API", doc = 'the bind parameters' } },
        returns = { { type = 'integer|nil', doc = 'the insert id, or nil for a timeout' } },
    },
    ['Cis.db.query'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'DbQuery',
        params = { { name = 'sql', type = 'string', doc = 'the statement' }, { name = 'params', type = 'table|any', optional = true, why = "the driver's own bind-parameter format, passed through unexamined. This is the seam to whatever driver is registered, and a library that typed it would be typing somebody else's API", doc = "the driver's bind parameters, passed through unexamined" } },
        returns = { { type = 'table|nil', doc = 'the rows. A nil means TIMED OUT OR NO DRIVER, not "no rows" -- use single or scalar to ask about emptiness. The reason is out of band behind GetLastRefusal' } },
    },
    ['Cis.db.scalar'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'DbScalar',
        params = { { name = 'sql', type = 'string', doc = 'the statement' }, { name = 'params', type = 'table|any', optional = true, why = "the driver's own bind-parameter format, passed through unexamined. This is the seam to whatever driver is registered, and a library that typed it would be typing somebody else's API", doc = 'the bind parameters' } },
        returns = { { type = 'any', why = "the driver's own scalar, which is a number, a string or a boolean depending on the statement -- and which is the one database call where nil is a VALUE rather than a timeout, which is exactly why it exists", doc = 'the first column of the first row. The right primitive for emptiness: a nil here is a value, and a nil from the other two is a timeout' } },
    },
    ['Cis.db.single'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'DbSingle',
        params = { { name = 'sql', type = 'string', doc = 'the statement' }, { name = 'params', type = 'table|any', optional = true, why = "the driver's own bind-parameter format, passed through unexamined. This is the seam to whatever driver is registered, and a library that typed it would be typing somebody else's API", doc = 'the bind parameters' } },
        returns = { { type = 'table|nil', doc = 'the first row, or nil for both "no row" and "timed out" -- which is the ambiguity single exists to avoid' } },
    },
    ['Cis.db.transaction'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'DbTransaction',
        params = { { name = 'queries', type = 'table', doc = 'a LIST of queries, not (sql, params) -- the one deliberate asymmetry in the database block' } },
        returns = { { type = 'boolean, string', doc = 'the ONE database call that refuses loudly rather than yielding: without transaction support a driver would hold the caller for the full timeout and answer nil, indistinguishable from a lost query. false, reason is answerable; nil is not' } },
    },
    ['Cis.db.update'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'DbUpdate',
        params = { { name = 'sql', type = 'string', doc = 'the statement' }, { name = 'params', type = 'table|any', optional = true, why = "the driver's own bind-parameter format, passed through unexamined. This is the seam to whatever driver is registered, and a library that typed it would be typing somebody else's API", doc = 'the bind parameters' } },
        returns = { { type = 'integer|nil', doc = 'the affected count, or nil for a timeout' } },
    },
    ['Cis.doors.add'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'AddDoorToSystem',
        params = { { name = 'data', type = 'table', doc = 'the door record, handed to the doors provider unexamined' } },
        returns = { { type = 'boolean, string', doc = 'true once registered, false plus a reason when it is refused -- on the server because the caller is off Security.AuthorizedResources, and on the client because no provider answered' } },
    },
    ['Cis.doors.get'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'GetDoorState',
        params = { { name = 'id', type = 'string', doc = 'the door id' } },
        returns = { { type = 'boolean|nil, string|nil', doc = 'the CACHED state, and on the client it is a hint rather than authority: the server re-checks job permission and distance before applying anything. nil = no such door, false = unlocked, and the two are kept distinct' } },
    },
    ['Cis.doors.setState'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'LockDoors',
        params = { { name = 'id', type = 'string', doc = 'the group or door identifier' }, { name = 'locked', type = 'boolean', doc = 'true to lock, false to unlock' } },
        returns = { { type = 'boolean, string', doc = 'a REQUEST on the client -- the server re-checks -- and a direct apply on the server. Either way the answer is not the current state; read Cis.doors.get for that' } },
    },
    ['Cis.framework.notify'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'Notify',
        from = { client = 1 },
        rebinds = 'the client form is the source parameter list from index 1 onward, so the message lands in parameter 1 and the kind in parameter 2',
        params = { server = { { name = 'srcOrNil', type = 'integer', doc = 'the player id' }, { name = 'message', type = 'string', doc = 'the message' }, { name = 'kind', type = 'string', optional = true, doc = 'the kind' } }, client = { { name = 'message', type = 'string', doc = 'the message -- on the client the FIRST argument IS the message' }, { name = 'kind', type = 'string', optional = true, doc = 'the kind, forwarded verbatim' } } },
        returns = { { type = 'boolean, string', doc = 'true once sent; false plus a reason for a bad src, a disconnected player, or the rate limit. Over 512 characters the message is TRUNCATED, not refused' } },
    },
    ['Cis.framework.player'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'GetNormalizedPlayer',
        params = { { name = 'src', type = 'integer', doc = 'the player id' } },
        returns = { { type = 'table|nil', doc = "the provider's normalised record, or nil when no framework is registered -- and the reason cannot ride in the return list, because a nil FIRST value truncates it" } },
    },
    ['Cis.inventory.add'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'InventoryAdd',
        params = { { name = 'src', type = 'integer', doc = 'the player id' }, { name = 'item', type = 'string', doc = 'the item name' }, { name = 'amount', type = 'integer', doc = 'the amount' }, { name = 'metadata', type = 'table|any', optional = true, why = 'per-item metadata whose shape belongs to the inventory provider, not to this library', doc = 'per-item metadata' } },
        returns = { { type = 'boolean', doc = 'false when no inventory provider is registered' } },
    },
    ['Cis.inventory.count'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'InventoryCount',
        params = { server = { { name = 'src', type = 'integer', doc = 'the player id' }, { name = 'item', type = 'string', doc = 'the item name' } }, client = { { name = 'item', type = 'string', doc = 'the item name' } } },
        returns = { { type = 'integer', doc = 'the count, and 0 on refusal -- deliberately a number so an `if not n` caller still reads 0 rather than nil' } },
    },
    ['Cis.inventory.has'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'InventoryHas',
        params = { server = { { name = 'src', type = 'integer', doc = 'the player id' }, { name = 'item', type = 'string', doc = 'the item name' }, { name = 'amount', type = 'integer', optional = true, doc = 'the amount, default 1' } }, client = { { name = 'item', type = 'string', doc = 'the item name' }, { name = 'amount', type = 'integer', optional = true, doc = 'the amount, default 1' } } },
        returns = { { type = 'boolean', doc = 'whether the amount is held. Built on count() locally, so it does not cross a second time' } },
    },
    ['Cis.inventory.remove'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'InventoryRemove',
        params = { { name = 'src', type = 'integer', doc = 'the player id' }, { name = 'item', type = 'string', doc = 'the item name' }, { name = 'amount', type = 'integer', doc = 'the amount' } },
        returns = { { type = 'boolean', doc = 'false when no provider is registered' } },
    },
    ['Cis.log.debug'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'LogDebug',
        params = { { name = 'message', type = 'any', why = 'stringified with tostring before printing', doc = 'stringified with tostring, so any value is safe' } },
        returns = { { type = 'nil', doc = 'nothing comes back. On the server this is the one GATED level: with Config.Printing.Debug off it prints nothing at all' } },
    },
    ['Cis.log.error'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'LogError',
        params = { { name = 'message', type = 'any', why = 'stringified with tostring before printing', doc = 'stringified with tostring, so any value is safe' } },
        returns = { { type = 'nil', doc = "nothing comes back. tryExport rather than a hard call, so a resource that stopped first does not take the caller's thread down over a log line" } },
    },
    ['Cis.log.info'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'LogInfo',
        params = { { name = 'message', type = 'any', why = 'stringified with tostring before printing', doc = 'stringified with tostring, so any value is safe' } },
        returns = { { type = 'nil', doc = 'nothing comes back. Never gated' } },
    },
    ['Cis.log.warn'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'LogWarn',
        params = { { name = 'message', type = 'any', why = 'stringified with tostring before printing', doc = 'stringified with tostring, so any value is safe' } },
        returns = { { type = 'nil', doc = 'nothing comes back. Never gated -- a warning suppressed by a debug flag is a warning nobody sees' } },
    },
    ['Cis.moduleInfo'] = {
        since = '1.0.0',
        realm = 'both',
        params = { { name = 'name', type = 'string', doc = 'a module name from the allow-list; a non-string is refused with the type in .why' }, { name = 'opts', type = 'table', optional = true, doc = 'only .load is read, and only as == true. It is opt-in because answering "is this name real" must not be the thing that parses fifteen files' } },
        returns = { { type = 'CisModuleInfo', doc = 'a DESCRIPTION, not the module: ok, name, path, global, deps (a fresh copy) and globalPresent, plus functions, loaded and globalPresentAfterLoad under opts.load. A refusal is ok = false with .why, and an unknown name also carries .valid' } },
    },
    ['Cis.moduleProbe'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'ModuleInfo',
        params = {  },
        returns = { { type = 'table', doc = 'present (the module globals that exist on this realm) and loaded (the names in the require cache), both sorted, plus known. Expected to be an empty `present` on cis_libs own realms' } },
    },
    ['Cis.net.on'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'SecureNetOn',
        params = { { name = 'name', type = 'string', doc = 'the net event name' }, { name = 'fn', type = 'function|string', doc = "a 'resource:Export' string, or a function when cis_libs itself is the caller. A function SENT from a consumer is DROPPED: the event still registers and still gets source and rate-limit checks, and the handler then arrives nil and every invocation raises inside the protected call" }, { name = 'opts', type = 'table', optional = true, doc = "windowMs, maxHits, the payload bounds maxArgs, maxStringLen, maxEntries and maxDepth (32, 4096, 256 and 8 by default), and optional schema. schema is a map of field -> { type, min, max, maxLen, optional, finite } on the first payload table; type may be integer, and infinity is refused unless finite = false. An oversized or bad payload is refused, counted as netSchemaRefused, and reported through Cis.security.report, once per run of them" } },
        returns = { { type = 'boolean, string', doc = 'true once registered, false plus a reason when it is refused -- so a refusal is visible rather than indistinguishable from success' } },
    },
    ['Cis.player.coords'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'GetCachedPed',
        params = {  },
        returns = { { type = 'vector3', doc = 'the local player coordinates. Free, and memoised per FRAME AND PER PED, because a respawn hands out a new ped inside a frame that is still current' } },
    },
    ['Cis.player.heading'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'GetCachedHeading',
        params = {  },
        returns = { { type = 'number', doc = 'the heading in degrees. Free, refreshed on the same watchdog tick as the ped' } },
    },
    ['Cis.player.near'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'WatchNear',
        params = { { name = 'coords', type = 'vector3|table', doc = 'the point to watch. Receives the distance on the server half' }, { name = 'distance', type = 'number', optional = true, doc = 'the radius, default 2.0' }, { name = 'onEnter', type = 'function', optional = true, doc = 'on the client this is a function argument and it is DROPPED across the boundary' }, { name = 'onExit', type = 'function', optional = true, doc = 'on the client this is a function argument and it is DROPPED across the boundary' }, { name = 'onEnterEvent', type = 'string', optional = true, doc = 'an event name, which is a string and does cross -- this is the working form from a consumer' }, { name = 'onExitEvent', type = 'string', optional = true, doc = 'an event name, which is a string and does cross' } },
        returns = { { type = 'function, integer', doc = 'the in-realm unsubscribe (unusable once it has crossed) and the watcher id, for Cis.player.nearStop. The watcher is made again, under the same id, when cis_libs restarts. Refusal is nil plus a reason: coords that arrived as nil or lack finite numeric x, y and z, a distance that is not a finite number above 0, or an event name that is not a string' } },
    },
    ['Cis.player.nearStop'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'RemoveNearWatcher',
        params = { { name = 'id', type = 'integer', doc = 'the id Cis.player.near answered in its second slot; it stays valid across a cis_libs restart, which makes the watcher again' } },
        returns = { { type = 'boolean, string', doc = 'true once removed; false plus a reason for an unknown id or one another resource owns' } },
    },
    ['Cis.player.on'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'key', type = 'string', doc = 'a cache key: aiming, armed, heading, ped, seat, shooting, vehicle or weapon. mount is RedM-only and is not a key here -- this game is gta5' }, { name = 'cb', type = 'function', doc = "the listener, `fun(current, previous)`, called pcall'd on every change. In a consumer it is a plain local function on the cache mirror; playerId and serverId are keys there too" } },
        returns = { { type = 'function|nil, integer|string', doc = 'in a consumer, a REAL unsubscribe function and a local id (nothing crossed to make them); in cis_libs own VM, the unsubscribe and the id for RemovePlayerCacheListener. Nil plus a reason for an unknown key or a non-callable listener' } },
    },
    ['Cis.player.ped'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'GetCachedPed',
        params = {  },
        returns = { { type = 'integer', doc = 'the local ped handle. Free -- no boundary crossing, and memoised to one native per frame' } },
    },
    ['Cis.player.serverId'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = {  },
        returns = { { type = 'integer', doc = 'the local player server id, 0 before the first watchdog pass. Cache it at spawn -- it does not change while the player is connected' } },
    },
    ['Cis.player.playerId'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = {  },
        returns = { { type = 'integer', doc = 'the local player index. Not the server id' } },
    },
    ['Cis.player.seat'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = {  },
        returns = { { type = 'integer|nil', doc = 'nil on foot, never 0: 0 is a passenger seat. -1 is the driver. Also the second return of Cis.player.vehicle()' } },
    },
    ['Cis.player.vehicle'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = {  },
        returns = { { type = 'integer|nil, integer|nil', doc = 'the vehicle and the seat, and NIL -- not 0 -- when on foot: a consumer that treats 0 as a handle gets a nil-index crash somewhere else. FREE in a consumer: read from the local cache mirror (one GetCacheSnapshot on the first read, then the cis_libs:cache pushes), so a Wait(0) loop costs nothing' } },
    },
    ['Cis.player.weapon'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = {  },
        returns = { { type = 'CisWeaponData|nil', doc = 'the weapon record, nil when unarmed. A FRESH table whenever the weapon or its ammo changes, never a mutation of the previous one: a consumer holding a reference across frames is holding a snapshot' } },
    },
    ['Cis.points.add'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'data', type = 'CisPointOptions', doc = 'coords and distance are required; onEnter, onExit, nearby, onEnterEvent, onExitEvent and nearbyEvent are not' } },
        returns = { { type = 'integer|false, string|nil', doc = 'the id, which is a number this library allocates and NEVER reuses -- so a stale id is a false refusal rather than another point vanishing. Every refusal is false plus a reason' } },
    },
    ['Cis.points.remove'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'id', type = 'integer', doc = 'the id add returned' } },
        returns = { { type = 'boolean', doc = 'false when no point holds that id, which is a no-op and not an error. A point the player was inside fires onExit first, with the PLAYER coordinates and not the point coordinates' } },
    },
    ['Cis.points.getAll'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = {},
        returns = { { type = 'integer[]', doc = 'the ids of the CALLER own points, ascending (ox_lib getAllPoints, as ids)' } },
    },
    ['Cis.points.getNearby'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = {},
        returns = { { type = 'integer[]', doc = 'the ids of the CALLER own points the player is inside right now (ox_lib getNearbyPoints, as ids)' } },
    },
    ['Cis.points.getClosest'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = {},
        returns = { { type = 'integer|nil, number|string|nil', doc = 'the nearest of the CALLER own points and the distance in metres, or nil plus a reason. TWO SHAPES, and the second slot is the distance when there is an id and the reason when there is not. FREE in a consumer' } },
    },

    ['Cis.ready'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'WaitReady',
        params = { { name = 'cb', type = 'function|integer', optional = true, doc = 'a callback -- the only form that crosses the boundary -- or a bare timeout when you just want to block' }, { name = 'timeout', type = 'integer', optional = true, doc = 'the deadline in ms, default 15000. ONE deadline for the whole call: it used to be two, so a caller who asked for one second waited two' } },
        returns = { { type = 'boolean|function', doc = 'with a callback, the callback gets true or false and this answers nothing. Without one, the boolean comes back directly' } },
    },
    ['Cis.require'] = {
        since = '1.0.0',
        realm = 'both',
        params = { { name = 'name', type = 'string', doc = 'one of the twenty-four built-in names, OR a module of your own: `folder.file` / `folder/file` / `./file` from the calling resource, `@resource/folder/file` from any resource. A bare name that is not built in RAISES, naming every valid one, because a silent nil is a nil index three frames deeper in the caller. A path that leaves the resource (.., absolute, backslash) raises too' } },
        returns = { { type = 'CisCurve|CisHeap|CisInterp|CisLRU|CisRandom|CisRate|CisRingBuffer|CisSet|CisSparse|CisWindow|CisArray|CisClass|CisCron|CisId|CisJson|CisLocale|CisMathX|CisPrint|CisSemver|CisString|CisTable|CisTime|CisTimer|CisValidate|any', why = 'a module of your own returns whatever its file returns', doc = 'the module, cached per Lua state so two calls in one VM share one instance and its internal state. A file of your own is read once, loaded as TEXT ONLY into its own environment (reads fall through to your globals, writes stay private), called with (name, `@resource/path.lua`), and cached; a file that returns nothing is cached as true. A circular require raises and names the chain. The type is a union because the return is whichever module was named; one ---@overload per built-in narrows it' } },
    },
    ['Cis.requireList'] = {
        since = '1.0.0',
        realm = 'both',
        params = {  },
        returns = { { type = 'string[]', doc = 'every valid module name, sorted. Asking costs nothing, which matters because the alternative is probing with a raised error' } },
    },
    ['Cis.security.report'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'SecurityReport',
        params = { { name = 'src', type = 'integer', doc = 'the player to report; a player who already left cannot be dropped and is refused' }, { name = 'reason', type = 'string', doc = 'the operator-facing reason' } },
        returns = { { type = 'boolean', doc = 'true when a drop capability handled it or DropPlayer was issued; false on a bad src, a disconnected player, or no drop capability and no Security.DropPlayer' } },
    },
    ['Cis.streaming.animDict'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'name', type = 'string', doc = 'the dictionary NAME, not a hash -- a function argument aside, RequestAnimDict takes a char* and a hash is a type error the game answers by never loading' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
        returns = { { type = 'string|nil, string|nil', doc = 'the name, or nil plus a reason. An invalid dictionary is refused in microseconds because this is the only kind with an existence probe' } },
        crossNote = 'Runs in the CALLER VM since 1.1.0: the request is the caller own and the poll yields the caller thread. Give the asset back with Cis.streaming.release(kind, asset) when done',
    },
    ['Cis.streaming.animSet'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'name', type = 'string', doc = 'the set name' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
        returns = { { type = 'string|nil, string|nil', doc = 'the name, or nil plus a reason' } },
        crossNote = 'Runs in the CALLER VM since 1.1.0: the request is the caller own and the poll yields the caller thread. Give the asset back with Cis.streaming.release(kind, asset) when done',
    },
    ['Cis.streaming.ptfx'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'name', type = 'string', doc = 'the effect name' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
        returns = { { type = 'string|nil, string|nil', doc = 'the name, or nil plus a reason. There is NO existence probe for this kind, so an invalid name costs the whole timeout -- a real asymmetry with animDict and documented rather than hidden' } },
        crossNote = 'Runs in the CALLER VM since 1.1.0: the request is the caller own and the poll yields the caller thread. Give the asset back with Cis.streaming.release(kind, asset) when done',
    },
    ['Cis.streaming.textureDict'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'name', type = 'string', doc = 'the dictionary name' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
        returns = { { type = 'string|nil, string|nil', doc = 'the name, or nil plus a reason' } },
        crossNote = 'Runs in the CALLER VM since 1.1.0: the request is the caller own and the poll yields the caller thread. Give the asset back with Cis.streaming.release(kind, asset) when done',
    },
    ['Cis.streaming.weaponAsset'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'hash', type = 'integer', doc = 'the weapon hash' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
        returns = { { type = 'integer|nil, string|nil', doc = 'the hash, or nil plus a reason' } },
        crossNote = 'Runs in the CALLER VM since 1.1.0: the request is the caller own and the poll yields the caller thread. Give the asset back with Cis.streaming.release(kind, asset) when done',
    },
    ['Cis.streaming.scaleform'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'name', type = 'string', doc = 'the movie name' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
        returns = { { type = 'string|nil, integer|nil, string|nil', doc = 'the name and the movie handle, or nil plus a reason. The request native answers the handle and returns 0 when it refuses, which is a real third state between not-yet and loaded' } },
        crossNote = 'Runs in the CALLER VM since 1.1.0: the request is the caller own and the poll yields the caller thread. Give the asset back with Cis.streaming.release(kind, asset) when done',
    },
    ['Cis.streaming.audioBank'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'name', type = 'string', doc = 'the bank name' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
        returns = { { type = 'string|nil, string|nil', doc = 'the name once the engine has ACCEPTED the bank, not once it is resident, and it never waits for either' } },
        crossNote = 'Runs in the CALLER VM since 1.1.0: the request is the caller own and the poll yields the caller thread. Give the asset back with Cis.streaming.release(kind, asset) when done',
    },
    ['Cis.streaming.model'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'model', type = 'integer|string', doc = 'a hash or a model name' }, { name = 'timeout', type = 'integer', optional = true, doc = 'the deadline in ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
        returns = { { type = 'boolean, integer', doc = "slot 2 is ALWAYS the hash, including on refusal, so a caller can release it either way. Releasing is the caller's job: the library does not keep a reference it cannot see" } },
    },
    ['Cis.sync.clear'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'SyncClear',
        params = {  },
        returns = { { type = 'integer|false, string', doc = 'how many records it took. 0 is the honest answer for a resource that has synced nothing, and a reload path calls it unconditionally. On the client this answers false, "server only"' } },
    },
    ['Cis.sync.entity'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'GetSyncedEntity',
        params = { { name = 'key', type = 'string', doc = 'the NAMESPACED key the server sent, which is not the id this resource passed in' } },
        returns = { { type = 'integer|nil', doc = 'the handle. An entity is created on a spawn that can take seconds during a model load, so a consumer that wants to act on one has to be told or poll -- this is the poll. On the server this answers false, "server only"' } },
    },
    ['Cis.sync.list'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'SyncList',
        params = {  },
        returns = { { type = 'CisSyncSummary[]|false, string', doc = "the CALLING resource's own records, so an entry can go straight back to remove. That scoping is the feature: a list naming another resource's records is a map of every entity on the server. On the client this answers false, \"server only\"" } },
    },
    ['Cis.sync.onDespawn'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'AddSyncDespawnHandler',
        params = { { name = 'fn', type = 'function', doc = 'a function or a cross-resource reference, released when its resource stops; anything that cannot be called is refused' } },
        returns = { { type = 'boolean, string', doc = "true on success. Called pcall'd as (key), and only when this client actually held something" } },
    },
    ['Cis.sync.onSpawn'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'AddSyncSpawnHandler',
        params = { { name = 'fn', type = 'function', doc = 'a function or a cross-resource reference, released when its resource stops; anything that cannot be called is refused' } },
        returns = { { type = 'boolean, string', doc = "true on success, and never a handle -- there is no deregister. Called pcall'd as (key, record, entity). From a consumer the hook is added again when cis_libs restarts" } },
    },
    ['Cis.sync.ped'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'SyncCreate',
        params = { { name = 'data', type = 'CisSyncRecord', doc = 'with kind = "ped"' } },
        returns = { { type = 'string|nil, string|nil', doc = "the caller's own id, never the namespaced key the client receives. On the client this answers false, \"server only\"" } },
    },
    ['Cis.sync.prop'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'SyncCreate',
        params = { { name = 'data', type = 'CisSyncRecord', doc = 'with kind = "prop"' } },
        returns = { { type = 'string|nil, string|nil', doc = "the caller's own id. On the client this answers false, \"server only\"" } },
    },
    ['Cis.sync.remove'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'SyncRemove',
        params = { { name = 'id', type = 'string|integer', doc = "the id, in the CALLING resource's namespace. Two resources can both use \"door1\" and both keep their own record" } },
        returns = { { type = 'boolean, string', doc = "false plus a reason, and the reason distinguishes the two misses that mean different things: another resource's id, and an id nobody holds. On the client this answers false, \"server only\"" } },
    },
    ['Cis.sync.vehicle'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'SyncCreate',
        params = { { name = 'data', type = 'CisSyncRecord', doc = 'with kind = "vehicle"; vehicleType defaults to automobile' } },
        returns = { { type = 'string|nil, string|nil', doc = "the caller's own id. On the client this answers false, \"server only\"" } },
    },
    ['Cis.target.add'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'CreateTarget',
        params = { { name = 'zoneType', type = 'string', doc = 'box, sphere or ped' }, { name = 'name', type = 'string', doc = 'the target name' }, { name = 'coords', type = 'vector3|table', doc = 'the centre' }, { name = 'size', type = 'vector3|number', doc = 'the size' }, { name = 'options', type = 'CisTargetOptions', optional = true, doc = 'the options, defaulted to {}' } },
        returns = { { type = 'boolean, string', doc = 'true, or false plus a reason. update is a remove and re-create internally, so treat it as a rebuild rather than a patch on the provider. From a consumer the target (and its last update) is made again when cis_libs restarts' } },
    },
    ['Cis.target.exists'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'TargetExists',
        params = { { name = 'name', type = 'string', doc = 'the target name' } },
        returns = { { type = 'boolean', doc = 'true only while this library believes it created it; the provider is never consulted' } },
    },
    ['Cis.target.remove'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'RemoveTarget',
        params = { { name = 'name', type = 'string', doc = 'the target name' }, { name = 'isPed', type = 'boolean', optional = true, doc = 'asserts the target was created for a LOCAL entity; its absence is how a box or sphere target removes' } },
        returns = { { type = 'boolean, string', doc = 'true, or false plus a reason' } },
    },
    ['Cis.target.update'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'UpdateTarget',
        params = { { name = 'name', type = 'string', doc = 'the target name' }, { name = 'options', type = 'CisTargetOptions', optional = true, doc = 'the new options' } },
        returns = { { type = 'boolean, string', doc = 'true once re-created; false plus a reason for an unknown name, one another resource owns, bad options, or no provider (the target is untouched). A create the provider refuses puts the old target back and says so. The target keeps its owner' } },
    },
    ['Cis.waitFor'] = {
        since = '1.0.0',
        realm = 'both',
        params = { { name = 'fn', type = 'function', doc = 'polled EVERY FRAME until it answers a value; false is treated as "not yet", so a predicate returning false for success has to say so in its return type' }, { name = 'msg', type = 'string', optional = true, doc = 'names WHICH wait timed out, and appears in the reason' }, { name = 'timeoutMs', type = 'number', optional = true, doc = 'default 10000. NaN and infinity are refused -- both would loop forever. 0 means poll once' } },
        returns = { { type = 'any, string|nil', why = 'the value is whatever fn returned, and this function cannot know that type', doc = 'the first value fn answered, or nil plus a reason. PURE: it runs in the consumer own VM with no export and no boundary. Timeout does not raise.' } },
    },
    ['Cis.raycast.camera'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'flags', type = 'number', optional = true, doc = 'shape-test flags, default -1' }, { name = 'ignore', type = 'number', optional = true, doc = 'entity to ignore; default the vehicle the player sits in, else the player ped -- a camera ray starts behind the player and would otherwise hit them' }, { name = 'distance', type = 'number', optional = true, doc = 'metres, default 10; positive, finite and at most 100000, or the call is refused with a reason before a probe starts' }, { name = 'timeoutMs', type = 'number', optional = true, doc = 'the bound, default 2000; a non-positive, NaN or infinite value falls back to the default' } },
        returns = { { type = 'boolean|nil, integer|nil, vector3|nil, vector3|nil, integer|nil', doc = 'hit, entityHit, endCoords, surfaceNormal, materialHash. Probed from the CAMERA, not the ped: "forward" means where the player is LOOKING, and probing from the ped works until they look up and then hits their feet' } },
    },
    ['Cis.raycast.fromCoords'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'origin', type = 'vector3|table', doc = 'where it starts' }, { name = 'target', type = 'vector3|table', doc = 'where it would end' }, { name = 'flags', type = 'number', optional = true, doc = 'default -1' }, { name = 'ignore', type = 'number', optional = true, doc = 'default the player vehicle, else the player ped' }, { name = 'timeoutMs', type = 'number', optional = true, doc = 'default 2000' } },
        returns = { { type = 'boolean|nil, integer|nil, vector3|nil, vector3|nil, integer|nil', doc = 'the same five slots as camera, so a caller does not have to know which it called' } },
    },
    ['Cis.keybind.add'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'options', type = 'CisKeybindOptions', doc = 'name REQUIRED; onPress / onRelease (or ox_lib onPressed / onReleased) are plain local functions, run in the calling resource' } },
        returns = { { type = 'table|false, string|nil', doc = 'the handle, with working methods in a consumer: disable(state), isPressed(), reset(), destroy(), getCurrentKey() (the label of the bound key, as ox_lib getCurrentKey). The commands and the mapping belong to the CALLING resource (since 1.1.0; before, to cis_libs -- a player rebind saved under cis_libs does not carry over). THE MAPPING IS WRITTEN INTO THE PLAYER SETTINGS AND SURVIVES THE RESOURCE, so a renamed binding is a second binding and the first still shows in the menu' } },
    },
    ['Cis.ui.notify'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'UiNotify',
        params = { { name = 'message', type = 'string|table', doc = 'a string, or a table with description/message/title. NOT Cis.framework.notify: that one is player-targeted and the one a server uses' }, { name = 'kind', type = 'string', optional = true, doc = 'forwarded to a ui provider; the native feed ignores it' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once shown, or false plus a reason. A ui provider, else the built-in toast, else the GTA feed' } },
    },
    ['Cis.ui.textUI.show'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'UiTextUIShow',
        params = { { name = 'text', type = 'string', doc = 'non-empty' }, { name = 'opts', type = 'table', optional = true, doc = 'forwarded to a ui provider; the native help-text fallback ignores them' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once shown. Native help is one global slot; last show wins; ClearAllHelpMessages on hide clears every help message on the screen' } },
    },
    ['Cis.ui.textUI.hide'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'UiTextUIHide',
        params = {},
        returns = { { type = 'boolean, string|nil', doc = 'true even if nothing was open' } },
    },
    ['Cis.ui.textUI.isOpen'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'UiTextUIIsOpen',
        params = {},
        returns = { { type = 'boolean', doc = 'always a boolean. Tracks this library\'s native help, not IsHelpMessageBeingDisplayed' } },
    },
    ['Cis.ui.progress'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'UiProgress',
        params = { { name = 'opts', type = 'table', doc = 'ProgressBar options; type = \'circle\' for the circle' } },
        returns = { { type = 'boolean|nil, string|nil', doc = 'true on completion, false on cancel. YIELDS until done' } },
    },
    ['Cis.ui.confirm'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'UiConfirm',
        params = { { name = 'opts', type = 'table', doc = 'header, content, cancel, labels. RETURNS, does not take a callback' } },
        returns = { { type = 'any, string|nil', why = 'a registered provider chooses its own value', doc = 'built-in: true/false plus the raw result' } },
    },
    ['Cis.ui.input'] = {
        since = '1.0.0',
        realm = 'client',
        forwardsTo = 'UiInput',
        params = { { name = 'opts', type = 'table', doc = 'heading, rows, options. RETURNS, does not take a callback' } },
        returns = { { type = 'any, string|nil', why = 'a registered provider chooses its own value', doc = 'built-in: the list of values, or nil on cancel' } },
    },
    ['Cis.ui.context.register'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'RegisterContext',
        params = { { name = 'context', type = 'table', doc = 'one context or a list: { id, title, menu (parent id), canClose, onExit, onBack, options = { { title, description, icon, iconColor, arrow, disabled, readOnly, progress, colorScheme, metadata, image, menu, onSelect, event, serverEvent, args } } }. serverEvent is fired by THIS CLIENT with TriggerServerEvent(name, args): the server handler must validate it like any client event. event is fired from the cis_libs VM, so it must start with the calling resource name as a "<resource>:" prefix, at most 128 bytes; onResourceStart/Stop/Starting, onClientResourceStart/Stop and any cis_libs: or __cfx_ name are refused for every caller. Fire any other event from onSelect' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once registered; made again when cis_libs restarts. Owned by the calling resource and removed when it stops. false plus a reason for a bad option, a refused event, or an id another resource holds ("context <id> is registered by <res>"). A list is all or nothing. Re-registering the menu on screen redraws it under a new token' } }
    },
    ['Cis.ui.context.show'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'ShowContext',
        params = { { name = 'id', type = 'string', doc = 'a registered context id' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once shown; false plus a reason for an unknown id or before the page has loaded' } }
    },
    ['Cis.ui.context.hide'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'HideContext',
        params = { { name = 'onExit', type = 'boolean', optional = true, doc = 'true runs the menu onExit' } },
        returns = { { type = 'boolean', doc = 'true when one was open' } }
    },
    ['Cis.ui.context.getOpen'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'GetOpenContextMenu',
        params = {},
        returns = { { type = 'string|nil', doc = 'the id of the open context menu' } }
    },
    ['Cis.ui.menu.register'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'RegisterMenu',
        params = { { name = 'data', type = 'table', doc = '{ id, title, position = top-left|top-right|bottom-left|bottom-right, options = { { label, description, icon, iconColor, values, defaultIndex, checked, progress, colorScheme, args, close } }, onSelected, onSideScroll, onCheck, onClose, disableInput, canClose }' }, { name = 'cb', type = 'function', optional = true, doc = 'called (selected, scrollIndex, args) when an option is confirmed with Enter' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once registered; made again when cis_libs restarts. Owned by the calling resource and removed when it stops' } }
    },
    ['Cis.ui.menu.show'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'ShowMenu',
        params = { { name = 'id', type = 'string', doc = 'a registered menu id' }, { name = 'startIndex', type = 'integer', optional = true, doc = 'the option selected first' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once shown. Keyboard-driven (arrows, Enter, Backspace/Escape); the player keeps control unless disableInput' } }
    },
    ['Cis.ui.menu.hide'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'HideMenu',
        params = { { name = 'onExit', type = 'boolean', optional = true, doc = 'true runs the menu onClose' } },
        returns = { { type = 'boolean', doc = 'true when one was open' } }
    },
    ['Cis.ui.menu.getOpen'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'GetOpenMenu',
        params = {},
        returns = { { type = 'string|nil', doc = 'the id of the open list menu' } }
    },
    ['Cis.ui.menu.setOptions'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'SetMenuOptions',
        params = { { name = 'id', type = 'string', doc = 'a registered menu id' }, { name = 'options', type = 'table', doc = 'the full option list, or one option when index is given' }, { name = 'index', type = 'integer', optional = true, doc = 'replace (or append, one past the end) this option only' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once replaced; an open menu is redrawn' } }
    },
    ['Cis.ui.radial.add'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'AddRadialItem',
        params = { { name = 'data', type = 'table', doc = 'one item or a list: { id, label, icon, iconColor, menu (a RegisterRadial id), onSelect, keepOpen }. onSelect is called (menuId, index)' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once added; made again when cis_libs restarts. The radial key (default Z) is registered with the first item. false plus a reason for a bad item, the cap, or an id another resource holds; a list is all or nothing' } }
    },
    ['Cis.ui.radial.remove'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'RemoveRadialItem',
        params = { { name = 'id', type = 'string', doc = 'the item id' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once removed; false plus a reason for an unknown id or an item another resource registered (only its owner or cis_libs may remove it)' } }
    },
    ['Cis.ui.radial.clear'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'ClearRadialItems',
        params = {},
        returns = { { type = 'boolean', doc = 'always true; removes only the global items the calling resource added (every item when cis_libs itself calls)' } }
    },
    ['Cis.ui.radial.register'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'RegisterRadial',
        params = { { name = 'radial', type = 'table', doc = '{ id, items } -- a submenu opened by an item whose menu is this id' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once registered; made again when cis_libs restarts. false plus a reason for a bad item or a submenu id another resource holds' } }
    },
    ['Cis.ui.radial.hide'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'HideRadial',
        params = {},
        returns = { { type = 'boolean', doc = 'true when it was open' } }
    },
    ['Cis.ui.radial.disable'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'DisableRadial',
        params = { { name = 'state', type = 'boolean', doc = 'true (default) stops the key opening the menu and closes it; false allows it again' } },
        returns = { { type = 'boolean', doc = 'always true' } }
    },
    ['Cis.ui.skillCheck'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'SkillCheck',
        params = { { name = 'difficulty', type = 'string|table', doc = '\'easy\' | \'medium\' | \'hard\', { areaSize, speedMultiplier }, or a list of those (one round each)' }, { name = 'inputs', type = 'table', optional = true, doc = 'key names to pick from per round (e, q, r, f, g, w, a, s, d, 1-4); default { e }' } },
        returns = { { type = 'boolean, string|nil', doc = 'YIELDS. true when every round was hit; false on a miss, a wrong key, CancelSkillCheck, the caller stopping, or a refusal. Lua places each zone and judges each press against GetGameTimer; the page only draws, and nothing it posts can pass or fail a check. A round with no press fails once the needle passes the zone' } }
    },
    ['Cis.ui.skillCheckActive'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'SkillCheckActive',
        params = {},
        returns = { { type = 'boolean', doc = 'whether a skill check is running' } }
    },
    ['Cis.ui.cancelSkillCheck'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'CancelSkillCheck',
        params = {},
        returns = { { type = 'boolean', doc = 'true when one was running; its caller gets false' } }
    },
    ['Cis.ui.progressActive'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'ProgressActive',
        params = {},
        returns = { { type = 'boolean', doc = 'whether a progress bar or circle is running' } }
    },
    ['Cis.ui.cancelProgress'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'CancelProgress',
        params = {},
        returns = { { type = 'boolean', doc = 'true when one was running and is now cancelled (its caller gets false)' } }
    },
    ['Cis.ui.closeAlert'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'CloseAlertDialog',
        params = {},
        returns = { { type = 'boolean', doc = 'true when one was open; its caller gets \'cancel\'' } }
    },
    ['Cis.ui.closeInput'] = {
        since = '1.1.0',
        realm = 'client',
        forwardsTo = 'CloseInputDialog',
        params = {},
        returns = { { type = 'boolean', doc = 'true when one was open; its caller gets nil' } }
    },
    ['Cis.statebag.onEntity'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'StatebagOnEntity',
        params = { { name = 'key', type = 'string', doc = 'the key or *' }, { name = 'handler', type = 'function', doc = 'called (entity, value, replicated, deleted); crosses the boundary as a callable reference and is released when the calling resource stops' }, { name = 'timeoutMs', type = 'number', optional = true, doc = 'how long the client keeps a change whose entity has not streamed in, default 2000. The server does not wait' } },
        returns = { { type = 'integer|nil, string|nil', doc = 'a cookie for Cis.statebag.remove, or nil plus a reason. From a consumer the watcher is made again, under the same cookie, when cis_libs restarts' } },
    },
    ['Cis.statebag.onPlayer'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'StatebagOnPlayer',
        params = { { name = 'key', type = 'string', doc = 'the key or *' }, { name = 'handler', type = 'function', doc = 'called (serverId, value, replicated, deleted); released when the calling resource stops' }, { name = 'timeoutMs', type = 'number', optional = true, doc = 'unused: a player watcher never waits' } },
        returns = { { type = 'integer|nil, string|nil', doc = 'a cookie for Cis.statebag.remove, or nil plus a reason. From a consumer the watcher is made again, under the same cookie, when cis_libs restarts' } },
    },
    ['Cis.statebag.remove'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'RemoveStatebagHandler',
        params = { { name = 'cookie', type = 'integer', doc = 'the number the watcher returned' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once removed, or false plus a reason' } },
    },
    ['Cis.command.add'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'CommandAdd',
        params = { { name = 'name', type = 'string', doc = 'letters, digits, underscore or hyphen' }, { name = 'options', type = 'table', doc = 'params, restricted and help' }, { name = 'handler', type = 'function', doc = 'called (src, args, raw); REFUSED at registration from a consumer, because a function cannot cross the boundary' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once registered, or false plus a reason: a name the server already knows (another resource command or a builtin, matched without regard to case) is refused, and so is a re-add that changes the restricted flag. A restricted command refuses and prints the exact add_ace line when nobody has granted it; cis_libs never grants ACL itself' } },
    },
    ['Cis.command.list'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'CommandList',
        params = {  },
        returns = { { type = 'table[]', doc = 'every registered command with its usage line' } },
    },
    ['Cis.command.remove'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'CommandRemove',
        params = { { name = 'name', type = 'string', doc = 'the command name' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once removed, or false plus a reason' } },
    },
    ['Cis.wait'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'WaitReady',
        params = { { name = 'timeout', type = 'integer', optional = true, doc = 'the deadline in ms, default 15000' } },
        returns = { { type = 'boolean', doc = 'true once cis_libs is ready, false when the deadline passed -- which is the honest result rather than a silent nil' } },
    },
    ['Cis.zones.server.box'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'ServerZoneBox',
        params = { { name = 'center', type = 'vector3|table', doc = 'the centre' }, { name = 'size', type = 'number|vector3|table', doc = 'full size; every axis must be positive and finite' }, { name = 'opts', type = 'table', optional = true, doc = 'heading, bucket (default 0), onEnterEvent, onExitEvent' } },
        returns = { { type = 'integer|false, string|nil', doc = 'numeric id. Containment uses SERVER ped coords' } },
    },
    ['Cis.zones.server.sphere'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'ServerZoneSphere',
        params = { { name = 'center', type = 'vector3|table', doc = 'the centre' }, { name = 'radius', type = 'number', doc = 'metres' }, { name = 'opts', type = 'table', optional = true, doc = 'bucket (default 0), onEnterEvent, onExitEvent' } },
        returns = { { type = 'integer|false, string|nil', doc = 'numeric id' } },
    },
    ['Cis.zones.server.poly'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'ServerZonePoly',
        params = { { name = 'points', type = 'table', doc = 'at least 3 points' }, { name = 'opts', type = 'table', optional = true, doc = 'minZ maxZ events' } },
        returns = { { type = 'integer|false, string|nil', doc = 'numeric id' } },
    },
    ['Cis.zones.server.contains'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'ServerZoneContains',
        params = { { name = 'id', type = 'integer', doc = 'zone id' }, { name = 'coords', type = 'vector3|table', doc = 'the point' } },
        returns = { { type = 'boolean, string|nil', doc = 'true inside' } },
    },
    ['Cis.zones.server.players'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'ServerZonePlayers',
        params = { { name = 'id', type = 'integer', doc = 'zone id' } },
        returns = { { type = 'integer[]|false, string|nil', doc = 'server ids inside' } },
    },
    ['Cis.zones.server.remove'] = {
        since = '1.0.0',
        realm = 'server',
        forwardsTo = 'ServerZoneRemove',
        params = { { name = 'id', type = 'integer', doc = 'zone id' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once removed' } },
    },
    ['Cis.hooks.on'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'HookOn',
        params = { { name = 'name', type = 'string', doc = 'hook name' }, { name = 'fn', type = 'function|string', doc = 'function in this VM or resource:Export' }, { name = 'opts', type = 'table', optional = true, doc = 'priority' } },
        returns = { { type = 'integer|false, string|nil', doc = 'cookie' } },
    },
    ['Cis.hooks.run'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'HookRun',
        params = { { name = 'name', type = 'string', doc = 'hook name' }, { name = 'payload', type = 'any', optional = true, why = 'opaque to this library', doc = 'handed to each hook' } },
        returns = { { type = 'boolean, string|nil, string|nil', doc = 'allowed, reason, byResource' } },
    },
    ['Cis.hooks.remove'] = {
        since = '1.0.0',
        realm = 'both',
        forwardsTo = 'HookRemove',
        params = { { name = 'id', type = 'integer', doc = 'cookie' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once removed' } },
    },
    ['Cis.zones.box'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'name', type = 'string', doc = 'the zone name' }, { name = 'center', type = 'vector3|table', doc = 'the centre' }, { name = 'size', type = 'vector3|number', doc = 'the size -- nil is refused' }, { name = 'options', type = 'CisZoneOptions', optional = true, doc = 'onEnter / onExit / inside are plain local functions called with (zone, coords) in the calling resource; the event-name twins still fire their events' } },
        returns = { { type = 'boolean, string', doc = 'true, or false plus a reason. The zone lives in the CALLER VM and survives a cis_libs restart' } },
    },
    ['Cis.zones.contains'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'name', type = 'string', doc = 'the zone name' }, { name = 'point', type = 'vector3|table', optional = true, doc = 'the point to test; a nil answers false rather than raising' } },
        returns = { { type = 'boolean', doc = 'true only on a real containment hit. FREE in a consumer: it tests the CALLER own zones, locally' } },
    },
    ['Cis.zones.getCurrent'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = {},
        returns = { { type = 'string[]', doc = 'the names of the CALLER own zones the player is inside, sorted (ox_lib getCurrentZones, as names)' } },
    },
    ['Cis.zones.getAll'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = {},
        returns = { { type = 'string[]', doc = 'the names of the CALLER own zones, sorted (ox_lib getAllZones, as names)' } },
    },
    ['Cis.zones.getNearby'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'coords', type = 'vector3|table', optional = true, doc = 'default the player coords' }, { name = 'radius', type = 'number', optional = true, doc = 'metres on the ground plane, default 50' } },
        returns = { { type = 'string[]', doc = 'the names of the CALLER own zones whose footprint comes within radius, sorted (ox_lib getNearbyZones, as names)' } },
    },
    ['Cis.zones.poly'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'name', type = 'string', doc = 'the zone name' }, { name = 'points', type = 'vector3[]', doc = 'the point list' }, { name = 'options', type = 'CisZoneOptions', optional = true, doc = 'onEnter / onExit / inside are plain local functions called with (zone, coords) in the calling resource; the event-name twins still fire their events' } },
        returns = { { type = 'boolean, string', doc = 'true, or false plus a reason. Always capture the second value: a bare false tells you nothing you did not already guess' } },
    },
    ['Cis.zones.remove'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'name', type = 'string', doc = 'the zone name. Removing a zone twice, or one that never existed, is a no-op and not an error' } },
        returns = { { type = 'boolean, string|nil', doc = "false when no zone holds that name, true once removed; false plus a reason when another resource owns it. A player still inside gets its onExit fired first, with the PLAYER's coordinates and not the zone centre" } },
    },
    ['Cis.zones.sphere'] = {
        since = '1.0.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'name', type = 'string', doc = 'the zone name' }, { name = 'center', type = 'vector3|table', doc = 'the centre' }, { name = 'radius', type = 'number', optional = true, doc = 'the radius, default 1.0' }, { name = 'options', type = 'CisZoneOptions', optional = true, doc = 'onEnter / onExit / inside are plain local functions called with (zone, coords) in the calling resource' } },
        returns = { { type = 'boolean, string', doc = 'true, or false plus a reason. The zone lives in the CALLER VM and survives a cis_libs restart' } },
    },
    -- ------------------------------------------------- 1.1.0: consumer-side
    -- Each of these runs in the CALLER's VM, loaded from client/core/*.lua on
    -- its first call; nothing crosses per call.
    ['Cis.cache'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'key', type = 'string', doc = 'aiming, armed, heading, ped, playerId, seat, serverId, shooting, vehicle or weapon' } },
        returns = { { type = 'any', why = 'the value type is decided by the key: a handle, an id, a boolean, a heading or a CisWeaponData', doc = 'the mirrored value, read locally. One GetCacheSnapshot on the first read of any key, then nothing: cis_libs pushes every change' } },
    },
    ['Cis.onCache'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'key', type = 'string', doc = 'a Cis.cache key' }, { name = 'fn', type = 'fun(value: any, previous: any)', doc = "a plain function, called pcall'd on every change of the key. vehicle and seat land together: a vehicle listener reading Cis.player.seat() sees the new seat" } },
        returns = { { type = 'function|nil, integer|string', doc = 'a real unsubscribe function and the listener id, or nil plus a reason naming the valid keys' } },
    },
    ['Cis.streaming.release'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'kind', type = 'string', doc = 'model, animDict, animSet, ptfx, textureDict, weaponAsset, scaleform or audioBank' }, { name = 'asset', type = 'string|integer', doc = 'what the request loaded: a name, a hash, or for a scaleform the HANDLE' } },
        returns = { { type = 'boolean', doc = 'whether a release native was called' } },
    },
    ['Cis.world.getClosestPed'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'coords', type = 'vector3|table', optional = true, doc = 'the point to measure from; default the player coords' }, { name = 'maxDistance', type = 'number', optional = true, doc = 'metres; nil or non-positive means no limit' }, { name = 'filter', type = 'fun(entity: integer, coords: vector3): boolean', optional = true, doc = 'a plain function that must return TRUE to keep' }, { name = 'opts', type = 'table', optional = true, doc = '{ includeSelf, includePlayers }; both off by default' } },
        returns = { { type = 'integer|false, vector3|string|nil', doc = 'the NPC and its coords, or false plus a reason' } },
    },
    ['Cis.world.getClosestVehicle'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'coords', type = 'vector3|table', optional = true, doc = 'default the player coords' }, { name = 'maxDistance', type = 'number', optional = true, doc = 'metres; nil means no limit' }, { name = 'filter', type = 'fun(entity: integer, coords: vector3): boolean', optional = true, doc = 'a plain function' }, { name = 'opts', type = 'table', optional = true, doc = 'reserved' } },
        returns = { { type = 'integer|false, vector3|string|nil', doc = 'the vehicle and its coords, or false plus a reason' } },
    },
    ['Cis.world.getClosestObject'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'coords', type = 'vector3|table', optional = true, doc = 'default the player coords' }, { name = 'maxDistance', type = 'number', optional = true, doc = 'metres; nil means no limit' }, { name = 'filter', type = 'fun(entity: integer, coords: vector3): boolean', optional = true, doc = 'a plain function' }, { name = 'opts', type = 'table', optional = true, doc = 'reserved' } },
        returns = { { type = 'integer|false, vector3|string|nil', doc = 'the object and its coords, or false plus a reason' } },
    },
    ['Cis.world.getClosestPlayer'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'coords', type = 'vector3|table', optional = true, doc = 'default the player coords' }, { name = 'maxDistance', type = 'number', optional = true, doc = 'metres; nil means no limit' }, { name = 'filter', type = 'fun(entity: integer, coords: vector3): boolean', optional = true, doc = 'a plain function' }, { name = 'opts', type = 'table', optional = true, doc = '{ includeSelf = true } puts the local player back in' } },
        returns = { { type = 'integer|false, vector3|string|nil, integer|nil', doc = 'the player PED, its coords, and the player index in slot 3' } },
    },
    ['Cis.world.getClosestPlayerId'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'coords', type = 'vector3|table', optional = true, doc = 'default the player coords' }, { name = 'maxDistance', type = 'number', optional = true, doc = 'metres; default 2.0, as ox_lib' }, { name = 'includePlayer', type = 'boolean', optional = true, doc = 'true puts the local player in, as ox_lib' } },
        returns = { { type = 'integer|false, integer|string|nil, vector3|nil', doc = 'ox_lib getClosestPlayer order: the player INDEX, its ped and its coords; or false plus a reason' } },
    },
    ['Cis.world.getNearbyPeds'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'coords', type = 'vector3|table', optional = true, doc = 'default the player coords' }, { name = 'maxDistance', type = 'number', optional = true, doc = 'metres; nil means no limit' }, { name = 'filter', type = 'fun(entity: integer, coords: vector3): boolean', optional = true, doc = 'a plain function' }, { name = 'opts', type = 'table', optional = true, doc = '{ includeSelf, includePlayers }' } },
        returns = { { type = 'CisWorldEntry[]|false, string|nil', doc = 'sorted by distance, never nil' } },
    },
    ['Cis.world.getNearbyVehicles'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'coords', type = 'vector3|table', optional = true, doc = 'default the player coords' }, { name = 'maxDistance', type = 'number', optional = true, doc = 'metres; nil means no limit' }, { name = 'filter', type = 'fun(entity: integer, coords: vector3): boolean', optional = true, doc = 'a plain function' }, { name = 'opts', type = 'table', optional = true, doc = 'reserved' } },
        returns = { { type = 'CisWorldEntry[]|false, string|nil', doc = 'sorted by distance, never nil' } },
    },
    ['Cis.world.getNearbyObjects'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'coords', type = 'vector3|table', optional = true, doc = 'default the player coords' }, { name = 'maxDistance', type = 'number', optional = true, doc = 'metres; nil means no limit' }, { name = 'filter', type = 'fun(entity: integer, coords: vector3): boolean', optional = true, doc = 'a plain function' }, { name = 'opts', type = 'table', optional = true, doc = 'reserved' } },
        returns = { { type = 'CisWorldEntry[]|false, string|nil', doc = 'sorted by distance, never nil' } },
    },
    ['Cis.world.getNearbyPlayers'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'coords', type = 'vector3|table', optional = true, doc = 'default the player coords' }, { name = 'maxDistance', type = 'number', optional = true, doc = 'metres; nil means no limit' }, { name = 'filter', type = 'fun(entity: integer, coords: vector3): boolean', optional = true, doc = 'a plain function' }, { name = 'opts', type = 'table', optional = true, doc = '{ includeSelf = true } adds the local player' } },
        returns = { { type = 'CisWorldEntry[]|false, string|nil', doc = 'sorted by distance; each row carries .player' } },
    },
    ['Cis.vehicle.getProperties'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'vehicle', type = 'integer', doc = 'the entity handle' } },
        returns = { { type = 'CisVehicleProps|nil', doc = 'every property, ox_lib field-compatible; nil when the entity does not exist' } },
    },
    ['Cis.vehicle.setProperties'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'vehicle', type = 'integer', doc = 'the entity handle' }, { name = 'props', type = 'CisVehicleProps', doc = 'what to apply; absent keys are left alone' }, { name = 'fixVehicle', type = 'boolean', optional = true, doc = 'repair FIRST, so the saved damage in props survives' } },
        returns = { { type = 'boolean, string|nil', doc = 'true, or false plus a reason -- including when this client does not control the networked vehicle (control was requested; retry)' } },
    },
    ['Cis.marker.add'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'opts', type = 'CisMarkerOptions', doc = 'coords required; everything else defaults' } },
        returns = { { type = 'integer|false, string|nil', doc = 'the marker id, or false plus a reason. The first marker starts the ONE draw thread of the resource; it ends with the last' } },
    },
    ['Cis.marker.remove'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'id', type = 'integer', doc = 'the id add returned' } },
        returns = { { type = 'boolean', doc = 'whether there was such a marker' } },
    },
    ['Cis.marker.clear'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = {},
        returns = { { type = 'integer', doc = 'how many markers were removed' } },
    },
    ['Cis.scaleform.new'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'name', type = 'string', doc = 'the movie name' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms, default 5000; 0 to 600000, and NaN, infinity, a negative or a non-number is refused with a reason before anything is requested' } },
        returns = { { type = 'CisScaleformMovie|nil, string|nil', doc = 'the movie object, or nil plus a reason. Disposed by :dispose() and on the stop of the calling resource' } },
    },
    ['Cis.dui.new'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'opts', type = 'CisDuiOptions', doc = 'url required' } },
        returns = { { type = 'CisDuiPage|nil, string|nil', doc = 'the page object, or nil plus a reason. Destroyed by :destroy() and on the stop of the calling resource' } },
    },
    ['Cis.anim.play'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'ped', type = 'integer', doc = 'the ped handle' }, { name = 'dict', type = 'string', doc = 'the animation dictionary' }, { name = 'clip', type = 'string', doc = 'the clip name' }, { name = 'opts', type = 'CisAnimOptions', optional = true, doc = 'timings, flag and locks' } },
        returns = { { type = 'boolean, string|nil', doc = 'true once TaskPlayAnim was issued -- the dictionary is requested first and RELEASED right after, since the task holds its own reference -- or false plus a reason' } },
    },
    ['Cis.controls.disable'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = '...', type = 'integer|integer[]', doc = 'control indices, as arguments or as one list' } },
        returns = { { type = 'integer|false, string|nil', doc = 'a HOLD id. Each control stays disabled every frame while any hold names it (refcounted); one thread per resource, only while a hold exists' } },
    },
    ['Cis.controls.enable'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'id', type = 'integer', doc = 'the hold id disable returned' } },
        returns = { { type = 'boolean', doc = 'whether the hold existed. Its controls come back only when no other hold names them' } },
    },
    ['Cis.controls.isDisabled'] = {
        since = '1.1.0',
        realm = 'client',
        runsIn = 'consumer',
        params = { { name = 'control', type = 'integer', doc = 'a control index' } },
        returns = { { type = 'boolean', doc = 'whether any hold names it right now' } },
    },
    },

    -- ===================================================== classes
    --
    -- The record and option tables the types above name. A type that names a
    -- class nobody declared is a completion nobody gets, and it is invisible in
    -- review because `CisVehicleProps` reads as a real type -- so the validator
    -- fails on an undeclared reference in BOTH directions.
    --
    -- A field is required unless it is marked `optional`, because a caller is
    -- never obliged to pass one: this library applies a default and hands back
    -- the result. `optional` marks the ones a caller may genuinely leave out.

    classes = {
    CisArray = {
        doc = "The table Cis.require('array') returns. Arrays that carry an explicit length `n`, so holes never shorten them, and map/filter/reduce/slice/splice/flat/sort (stable)/unique/groupBy/chunk/zip/sum/min/max over them. Nothing mutates its input except push and splice. An array's metatable __index is this table, so a:map(fn) works as well as array.map(a, fn).",
        fields = { { name = 'isArrayLike', type = 'function' }, { name = 'new', type = 'function' }, { name = 'from', type = 'function' }, { name = 'isArray', type = 'function' }, { name = 'len', type = 'function' }, { name = 'push', type = 'function' }, { name = 'forEach', type = 'function' }, { name = 'map', type = 'function' }, { name = 'filter', type = 'function' }, { name = 'reduce', type = 'function' }, { name = 'find', type = 'function' }, { name = 'findIndex', type = 'function' }, { name = 'some', type = 'function' }, { name = 'every', type = 'function' }, { name = 'indexOf', type = 'function' }, { name = 'includes', type = 'function' }, { name = 'slice', type = 'function' }, { name = 'splice', type = 'function' }, { name = 'concat', type = 'function' }, { name = 'flat', type = 'function' }, { name = 'reverse', type = 'function' }, { name = 'join', type = 'function' }, { name = 'sort', type = 'function' }, { name = 'unique', type = 'function' }, { name = 'groupBy', type = 'function' }, { name = 'chunk', type = 'function' }, { name = 'zip', type = 'function' }, { name = 'sum', type = 'function' }, { name = 'min', type = 'function' }, { name = 'max', type = 'function' } },
    },
    CisClass = {
        doc = "The table Cis.require('class') returns. Single-inheritance classes: class.new(name, super) returns a class used as Class:new(...) or Class(...), with a constructor method, instanceof, a toString hook for tostring, and class.privates() for private fields in a weak-keyed table. Method calls are table lookups up the chain; no closure is made per call.",
        fields = { { name = 'new', type = 'function' }, { name = 'isClass', type = 'function' }, { name = 'instanceof', type = 'function' }, { name = 'classOf', type = 'function' }, { name = 'nameOf', type = 'function' }, { name = 'privates', type = 'function' } },
    },
    CisCron = {
        doc = "The table Cis.require('cron') returns. Five-field cron expressions and @macros with Vixie day-of-month/day-of-week OR semantics: parse, next, matches, and a scheduler with one thread per Lua state that sleeps until the earliest due job. Server local time by default; { utc = true } for UTC. Job handles have :stop(), :isActive() and :nextRun().",
        fields = { { name = 'parse', type = 'function' }, { name = 'next', type = 'function' }, { name = 'matches', type = 'function' }, { name = 'schedule', type = 'function' }, { name = 'stop', type = 'function' }, { name = 'isActive', type = 'function' }, { name = 'nextRun', type = 'function' }, { name = 'count', type = 'function' } },
    },
    CisCacheSnapshot = {
        doc = 'What GetCacheSnapshot answers: every key the consumer cache mirror follows, in one fresh table. Taken once per consumer and again after a cis_libs restart; every later change arrives as the cis_libs:cache event.',
        fields = { { name = 'ped', type = 'integer', optional = true, doc = 'the player ped, 0 before the first pass' }, { name = 'playerId', type = 'integer', optional = true, doc = 'the local player index' }, { name = 'serverId', type = 'integer', optional = true, doc = 'the server id' }, { name = 'heading', type = 'number', optional = true, doc = 'degrees' }, { name = 'vehicle', type = 'integer', optional = true, doc = '0 on foot' }, { name = 'seat', type = 'integer', optional = true, doc = 'nil on foot; -1 is the driver' }, { name = 'weapon', type = 'CisWeaponData', optional = true, doc = 'nil when unarmed' }, { name = 'armed', type = 'boolean', optional = true, doc = 'IsPedArmed(ped, 7)' }, { name = 'aiming', type = 'boolean', optional = true, doc = 'free-aiming or the config flag' }, { name = 'shooting', type = 'boolean', optional = true, doc = 'IsPedShooting at the last pass' } },
    },
    CisMarkerOptions = {
        doc = 'The table Cis.marker.add takes. Stored as flat numbers once, so the per-frame pass reads fields and calls DrawMarker and allocates nothing.',
        fields = { { name = 'coords', type = 'vector3|table', optional = false, doc = 'where it is drawn' }, { name = 'type', type = 'integer', optional = true, doc = 'the marker type, default 1' }, { name = 'size', type = 'number|vector3|table', optional = true, doc = 'the scale, default 1.0; `scale` is an alias' }, { name = 'color', type = 'table', optional = true, doc = '{ r, g, b, a } or { 1, 2, 3, 4 }, default 255, 255, 255, 180' }, { name = 'distance', type = 'number', optional = true, doc = 'the CULL radius in metres, default 50: further than this from the player it is not drawn, and a frame that draws nothing sleeps 200 ms' }, { name = 'dir', type = 'vector3|table', optional = true, doc = 'the direction vector' }, { name = 'rot', type = 'vector3|table', optional = true, doc = 'the rotation' }, { name = 'bob', type = 'boolean', optional = true, doc = 'bob up and down' }, { name = 'faceCamera', type = 'boolean', optional = true, doc = 'turn to the camera' }, { name = 'rotate', type = 'boolean', optional = true, doc = 'spin' }, { name = 'drawOnEnts', type = 'boolean', optional = true, doc = 'project onto entities' }, { name = 'textureDict', type = 'string', optional = true, doc = 'a texture dictionary' }, { name = 'textureName', type = 'string', optional = true, doc = 'a texture in it' } },
    },
    CisScaleformMovie = {
        doc = 'A scaleform movie object from Cis.scaleform.new. Methods are called with a colon. A disposed movie refuses every further call.',
        fields = { { name = 'name', type = 'string', doc = 'the movie name' }, { name = 'handle', type = 'integer|nil', doc = 'the movie handle; nil once disposed' }, { name = 'call', type = 'fun(self: CisScaleformMovie, method: string, ...): boolean, string|nil', doc = 'call a method. A parameter is typed by its value -- an integer is an int, any other number a float, a boolean a bool, a string a string -- or explicitly as { type = int|float|bool|string|literal|playerName, value = v }. An untypable parameter, including an explicit type outside that list, refuses the whole call with a reason naming it, before anything is sent' }, { name = 'draw', type = 'fun(self: CisScaleformMovie, r?: integer, g?: integer, b?: integer, a?: integer): boolean', doc = 'draw fullscreen for THIS frame' }, { name = 'draw3d', type = 'fun(self: CisScaleformMovie, coords: vector3, rot?: vector3, scale?: vector3): boolean', doc = 'draw in the world for THIS frame' }, { name = 'startDrawing', type = 'fun(self: CisScaleformMovie, r?: integer, g?: integer, b?: integer, a?: integer): boolean', doc = 'draw fullscreen every frame on a thread of its own' }, { name = 'stopDrawing', type = 'fun(self: CisScaleformMovie)', doc = 'end that thread' }, { name = 'dispose', type = 'fun(self: CisScaleformMovie): boolean', doc = 'SetScaleformMovieAsNoLongerNeeded; also run for every movie still held when the calling resource stops' } },
    },
    CisDuiOptions = {
        doc = 'The table Cis.dui.new takes.',
        fields = { { name = 'url', type = 'string', optional = false, doc = 'the page' }, { name = 'width', type = 'integer', optional = true, doc = 'pixels, default 1280' }, { name = 'height', type = 'integer', optional = true, doc = 'pixels, default 720' } },
    },
    CisDuiPage = {
        doc = 'A DUI page object from Cis.dui.new. Draw it with DrawSprite(page.dictName, page.txtName, ...) or AddReplaceTexture.',
        fields = { { name = 'dictName', type = 'string', doc = 'the runtime texture dictionary, unique per page and never reused' }, { name = 'txtName', type = 'string', doc = 'the texture inside it' }, { name = 'url', type = 'string', doc = 'the current url' }, { name = 'width', type = 'integer', doc = 'pixels' }, { name = 'height', type = 'integer', doc = 'pixels' }, { name = 'setUrl', type = 'fun(self: CisDuiPage, url: string): boolean, string|nil', doc = 'navigate' }, { name = 'sendMessage', type = 'fun(self: CisDuiPage, message: table|string): boolean, string|nil', doc = 'post a message; a table is JSON-encoded' }, { name = 'isAvailable', type = 'fun(self: CisDuiPage): boolean', doc = 'whether the browser has started' }, { name = 'destroy', type = 'fun(self: CisDuiPage): boolean', doc = 'DestroyDui; also run for every page still open when the calling resource stops' } },
    },
    CisAnimOptions = {
        doc = 'The options Cis.anim.play takes. Every field is optional and is TaskPlayAnim own parameter of the same name.',
        fields = { { name = 'blendIn', type = 'number', optional = true, doc = 'default 8.0' }, { name = 'blendOut', type = 'number', optional = true, doc = 'default -8.0' }, { name = 'duration', type = 'integer', optional = true, doc = 'ms, default -1 (the clip length)' }, { name = 'flag', type = 'integer', optional = true, doc = 'the animation flags, default 0' }, { name = 'playbackRate', type = 'number', optional = true, doc = 'default 0.0' }, { name = 'lockX', type = 'boolean', optional = true, doc = 'default false' }, { name = 'lockY', type = 'boolean', optional = true, doc = 'default false' }, { name = 'lockZ', type = 'boolean', optional = true, doc = 'default false' }, { name = 'timeout', type = 'integer', optional = true, doc = 'ms for the dictionary request, default 5000' } },
    },
    CisKeybindOptions = {
        doc = 'The table Cis.keybind.add takes. The NAME IS REQUIRED and is validated against letters, digits, underscore and hyphen, because RegisterKeyMapping writes it into the player settings and builds a command from it -- and a malformed one produces a mapping that appears in the menu and does nothing.',
        fields = { { name = 'name', type = 'string', optional = false, doc = 'the command name, and the +name / -name pair behind it' }, { name = 'description', type = 'string', optional = true, doc = 'what shows in the settings menu; defaults to the name' }, { name = 'defaultKey', type = 'string', optional = true, doc = 'a key NAME like F7 or X, not a control index. An empty string means unbound. This is RegisterKeyMapping defaultParameter, the FOURTH argument' }, { name = 'defaultMapper', type = 'string', optional = true, doc = 'RegisterKeyMapping defaultMapper, the THIRD argument, default keyboard. Not a boolean' }, { name = 'onPress', type = 'fun()', optional = true, doc = 'on the +name command, under pcall: a raise cannot end the handler and leave the binding stuck pressed' }, { name = 'onRelease', type = 'fun()', optional = true, doc = 'on the -name command, under pcall' }, { name = 'onPressed', type = 'fun()', optional = true, doc = 'ox_lib spelling of onPress' }, { name = 'onReleased', type = 'fun()', optional = true, doc = 'ox_lib spelling of onRelease' }, { name = 'secondaryKey', type = 'string', optional = true, doc = 'an alternate key NAME for the same command, registered as the ~! alternate mapping' }, { name = 'secondaryMapper', type = 'string', optional = true, doc = 'the mapper of secondaryKey; defaults to defaultMapper' }, { name = 'disabled', type = 'boolean', optional = true, doc = 'true registers the binding switched off; enable it with handle:disable(false)' } },
    },
    CisLocale = {
        doc = "The table Cis.require('locale') returns. Translations from the CALLING resource's locales/<lang>.json, language from the replicated convar cis:locale else en, with en as the fallback file and the fallback per key. t(key, ...) fills ${name} from a table and %s positionally; a % inside a named value prints as it is, and %% prints as one % whenever any argument is given; a missing key answers the key and warns once.",
        fields = { { name = 'load', type = 'function' }, { name = 'set', type = 'function' }, { name = 'getLanguage', type = 'function' }, { name = 'has', type = 'function' }, { name = 't', type = 'function' } },
    },
    CisMathX = {
        doc = "The table Cis.require('mathx') returns. Number helpers: round to decimals, clamp, lerp (numbers or FiveM vectors), inverseLerp, remap, approx, toHex/fromHex exact to 2^53, groupDigits, and a weighted pick that is reproducible with a CisRandom generator.",
        fields = { { name = 'round', type = 'function' }, { name = 'clamp', type = 'function' }, { name = 'lerp', type = 'function' }, { name = 'inverseLerp', type = 'function' }, { name = 'remap', type = 'function' }, { name = 'approx', type = 'function' }, { name = 'toHex', type = 'function', doc = 'toHex(n, opts?) -- a whole number below 2^53 in magnitude; anything else, math.mininteger on Lua 5.4 included, answers nil and a reason' }, { name = 'fromHex', type = 'function' }, { name = 'groupDigits', type = 'function' }, { name = 'weightedPick', type = 'function' } },
    },
    CisPrint = {
        doc = "The table Cis.require('print') returns. Levelled console output (error, warn, info, verbose, debug) with colour prefixes. The level comes from convar cis:printlevel:<resource>, else cis:printlevel, else info; a filtered call costs one comparison and formats nothing.",
        fields = { { name = 'refresh', type = 'function' }, { name = 'setLevel', type = 'function' }, { name = 'getLevel', type = 'function' }, { name = 'isEnabled', type = 'function' }, { name = 'error', type = 'function' }, { name = 'warn', type = 'function' }, { name = 'info', type = 'function' }, { name = 'verbose', type = 'function' }, { name = 'debug', type = 'function' } },
    },
    CisRingBuffer = {
        doc = "The table Cis.require('ringbuffer') returns. A fixed-capacity ring buffer that overwrites its oldest entry once full; index 1 is the oldest. A buffer's metatable __index is this table, so rb:push(v) and ringbuffer.push(rb, v) are the same call.",
        fields = { { name = 'new', type = 'function' }, { name = 'isRingBuffer', type = 'function' }, { name = 'push', type = 'function' }, { name = 'shift', type = 'function' }, { name = 'pop', type = 'function' }, { name = 'get', type = 'function' }, { name = 'peek', type = 'function' }, { name = 'peekLast', type = 'function' }, { name = 'size', type = 'function' }, { name = 'capacity', type = 'function' }, { name = 'isFull', type = 'function' }, { name = 'isEmpty', type = 'function' }, { name = 'clear', type = 'function' }, { name = 'toArray', type = 'function' } },
    },
    CisSet = {
        doc = "The table Cis.require('set') returns. A Set with O(1) membership, insertion-ordered values() and union/intersect/difference returning new sets. A set's metatable __index is this table, so s:add(v) and set.add(s, v) are the same call. nil and NaN are refused as members.",
        fields = { { name = 'new', type = 'function' }, { name = 'isSet', type = 'function' }, { name = 'add', type = 'function' }, { name = 'remove', type = 'function' }, { name = 'has', type = 'function' }, { name = 'size', type = 'function' }, { name = 'values', type = 'function' }, { name = 'clear', type = 'function' }, { name = 'union', type = 'function' }, { name = 'intersect', type = 'function' }, { name = 'difference', type = 'function' }, { name = 'isSubset', type = 'function' }, { name = 'equals', type = 'function' } },
    },
    CisTimer = {
        doc = "The table Cis.require('timer') returns. Pausable countdown timers on GetGameTimer (play, pause, restart, forceEnd, getTimeLeft) that sleep for exactly the time left, and setTimeout/setInterval/clearTimeout with the callback and delay in either order. A timer's metatable __index is this table, so t:pause() and timer.pause(t) are the same call.",
        fields = { { name = 'new', type = 'function' }, { name = 'play', type = 'function' }, { name = 'pause', type = 'function' }, { name = 'restart', type = 'function' }, { name = 'forceEnd', type = 'function' }, { name = 'isPaused', type = 'function' }, { name = 'hasEnded', type = 'function' }, { name = 'getTimeLeft', type = 'function' }, { name = 'setTimeout', type = 'function' }, { name = 'setInterval', type = 'function' }, { name = 'clearTimeout', type = 'function' }, { name = 'clearInterval', type = 'function' } },
    },
    CisWorldEntry = {
        doc = 'One row of a Cis.world.nearby* list, sorted by distance so element 1 is the closest. The player key is present only on the player lists and is nil everywhere else -- the key is always there so a caller can read it without testing the kind first.',
        fields = { { name = 'entity', type = 'integer', optional = false, doc = 'the ped, vehicle, object handle, or the player PED' }, { name = 'coords', type = 'vector3', optional = false, doc = 'where it is now, read at the time of the call' }, { name = 'distance', type = 'number', optional = false, doc = 'metres from the coords you asked about, in 3D' }, { name = 'player', type = 'integer', optional = true, doc = 'the player index, on the player lists only' } },
    },
    CisPointsDebug = {
        doc = 'The live debug record GetPointsDebug answers -- not a copy, and rebuilt on every pass, so it is zeroed the moment the last point is removed rather than going stale.',
        fields = { { name = 'lastPassMs', type = 'number', optional = true, doc = 'how long the last grid pass took' }, { name = 'lastPassAt', type = 'integer', optional = true, doc = 'GetGameTimer at the end of the last pass' }, { name = 'insideCount', type = 'integer', optional = true, doc = 'the points the library believes the player is inside' }, { name = 'insideIds', type = 'integer[]', optional = true, doc = 'their ids, sorted. A COUNT alone cannot tell a point that was found from one that was never registered' } },
    },
    CisPointOptions = {
        doc = 'The table Cis.points.add takes. coords and distance are REQUIRED and are refused by name when absent -- a defaulted radius is a specific number nobody asked for, and a defaulted coordinate is a point at the world origin that fires for a player who spawned there. Every other field is optional. From init.lua (Cis.points.add) the function fields are plain local functions in the calling resource; through the CreatePoint export they arrive as funcrefs. The event-name twins fire either way.',
        fields = { { name = 'coords', type = 'vector3|vector4|table', optional = false, doc = 'the centre; finite, and within 100 km of the origin -- an infinite coordinate used to hang the grid insert' }, { name = 'distance', type = 'number', optional = false, doc = 'the enter radius in metres. Must be finite and greater than zero; NaN and infinity are both refused by name, because NaN makes every containment test false and infinity has no cell to index' }, { name = 'onEnter', type = 'fun(coords: vector3, id: integer)', optional = true, doc = 'called under pcall on arrival' }, { name = 'onExit', type = 'fun(coords: vector3, id: integer)', optional = true, doc = 'called under pcall on departure and on removal' }, { name = 'nearby', type = 'fun(coords: vector3, id: integer)', optional = true, doc = 'called under pcall every nearbyInterval while the player is inside, and ONLY inside' }, { name = 'nearbyInterval', type = 'integer', optional = true, doc = 'ms between nearby calls, default 200. Zero is allowed: a local function asking for every pass is legitimate' }, { name = 'onEnterEvent', type = 'string', optional = true, doc = 'the net event fired on arrival, with (id, x, y, z). The id lets one handler watch several points' }, { name = 'onExitEvent', type = 'string', optional = true, doc = 'the net event fired on departure, with (id, x, y, z)' }, { name = 'nearbyEvent', type = 'string', optional = true, doc = 'the net event fired inside every nearbyInterval, with (id, x, y, z). Aimed at the server, so nearbyInterval is clamped to at least 250 ms when it is set -- the same floor a zone insideEvent has' } },
    },
    CisAuditEntry = {
        doc = 'One ring-buffer entry from GetAuditLog. RESOURCE AND SLOT NAMES ONLY -- never a player identifier, which is why this is in memory at all.',
        fields = { { name = 'event', type = 'string', doc = 'what happened, such as "registered" or "unregistered"' }, { name = 'detail', type = 'string', doc = 'the slot, and the owner where there is one' }, { name = 'line', type = 'string', doc = 'the rendered line' } },
    },
    CisCurve = {
        doc = "The table Cis.require('curve') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'lengthOf', type = 'function' }, { name = 'hermite', type = 'function' }, { name = 'catmullRom', type = 'function' }, { name = 'newPath', type = 'function' }, { name = 'count', type = 'function' }, { name = 'length', type = 'function' }, { name = 'pointAtXYZ', type = 'function' }, { name = 'pointAt', type = 'function' }, { name = 'pointAtT', type = 'function' }, { name = 'tangentAtXYZ', type = 'function' }, { name = 'sample', type = 'function' } },
    },
    CisDetection = {
        doc = 'What DetectFramework and DetectDatabase answer. A REFUSAL IS NOT A NIL: it is name = "NONE" with the reason in .reason, because nil and "not found" would otherwise be the same value to a caller.',
        fields = { { name = 'name', type = 'string', doc = "the framework or driver found, or 'NONE'" }, { name = 'resource', type = 'string', optional = true, doc = 'the resource that provides it' }, { name = 'version', type = 'string', optional = true, doc = 'its version, when the probe could read one' }, { name = 'how', type = 'string', optional = true, doc = 'how it was decided -- probe, configured, or forced' }, { name = 'reason', type = 'string', optional = true, doc = 'why, when the answer is NONE' }, { name = 'wanted', type = 'boolean', optional = true, doc = 'client only: set when a configured known framework was asked for by name' } },
    },
    CisDiagnostics = {
        doc = 'What GetDiagnostics answers on both realms. COUNTS AND COUNTERS ONLY -- never a player name, an identifier or an IP, which is what makes it safe to put in a console command that anyone can run.',
        fields = { { name = 'realm', type = 'string', optional = true, doc = "'server' or 'client', and it selects which probes ran" }, { name = 'uptimeMs', type = 'number', doc = 'GetGameTimer milliseconds, or os.clock()*1000 where shared/** runs with no FiveM' }, { name = 'memoryKb', type = 'number', doc = "collectgarbage('count') -- Lua KILOBYTES, not bytes" }, { name = 'counters', type = 'table<string, number>', doc = 'errors, warnings, rateLimited, netRefused, callbackErrors, providerErrors, zoneErrors, tickErrors' }, { name = 'probes', type = 'table<string, table|number|string>', doc = 'probe name -> payload, or <name>Error -> the raise as a string, so one broken probe cannot fail a snapshot' }, { name = 'timings', type = 'table<string, table>', optional = true, doc = 'CisTiming snapshot: zonePass, serverSyncPass, clientSyncPass, callbackRtt, exportCrossing. Each is n/sum/min/max/last/mean plus le002/le005/le015/le05/gt05 buckets. Not a probe: Diff ignores it' } },
    },
    CisHeap = {
        doc = "The table Cis.require('heap') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'new', type = 'function' }, { name = 'push', type = 'function' }, { name = 'pop', type = 'function' }, { name = 'peek', type = 'function' }, { name = 'replaceTop', type = 'function' }, { name = 'remove', type = 'function' }, { name = 'size', type = 'function' }, { name = 'isEmpty', type = 'function' }, { name = 'clear', type = 'function' }, { name = 'drain', type = 'function' }, { name = 'build', type = 'function' }, { name = 'newQueue', type = 'function' }, { name = 'enqueue', type = 'function' }, { name = 'dequeue', type = 'function' }, { name = 'peekQueue', type = 'function' } },
    },
    CisId = {
        doc = "The table Cis.require('id') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'draw', type = 'function' }, { name = 'short', type = 'function' }, { name = 'uuid', type = 'function' }, { name = 'newCounter', type = 'function' }, { name = 'next', type = 'function' }, { name = 'normaliseName', type = 'function' } },
    },
    CisInterp = {
        doc = "The table Cis.require('interp') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'hasEase', type = 'function' }, { name = 'ease', type = 'function' }, { name = 'clamp', type = 'function' }, { name = 'clamp01', type = 'function' }, { name = 'sign', type = 'function' }, { name = 'lerp', type = 'function' }, { name = 'lerpClamped', type = 'function' }, { name = 'inverseLerp', type = 'function' }, { name = 'remap', type = 'function' }, { name = 'wrap', type = 'function' }, { name = 'smoothstep', type = 'function' }, { name = 'smootherstep', type = 'function' }, { name = 'moveTowards', type = 'function' }, { name = 'damp', type = 'function' }, { name = 'dampAngle', type = 'function' }, { name = 'smoothDamp', type = 'function' }, { name = 'wrapAngle', type = 'function' }, { name = 'wrapAnglePositive', type = 'function' }, { name = 'wrapDegrees', type = 'function' }, { name = 'angleDelta', type = 'function' }, { name = 'headingDelta', type = 'function' }, { name = 'lerpHeading', type = 'function' }, { name = 'headingToVector', type = 'function' }, { name = 'vectorToHeading', type = 'function' }, { name = 'dist2', type = 'function' }, { name = 'dist3', type = 'function' }, { name = 'distance2D', type = 'function' }, { name = 'distance3D', type = 'function' }, { name = 'moveTowardsVec3', type = 'function' }, { name = 'lerpVec3', type = 'function' }, { name = 'dampVec3', type = 'function' }, { name = 'clampLength', type = 'function' }, { name = 'normalize', type = 'function' } },
    },
    CisJson = {
        doc = "The table Cis.require('json') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'check', type = 'function' }, { name = 'bind', type = 'function' }, { name = 'checkEncodable', type = 'function' }, { name = 'encode', type = 'function' }, { name = 'scanDepth', type = 'function' }, { name = 'decode', type = 'function' }, { name = 'tryDecode', type = 'function' }, { name = 'roundTrip', type = 'function' } },
    },
    CisLRU = {
        doc = "The table Cis.require('lru') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'new', type = 'function' }, { name = 'get', type = 'function' }, { name = 'peek', type = 'function' }, { name = 'has', type = 'function' }, { name = 'put', type = 'function' }, { name = 'popOldest', type = 'function' }, { name = 'remove', type = 'function' }, { name = 'removeWhere', type = 'function' }, { name = 'count', type = 'function' }, { name = 'clear', type = 'function' }, { name = 'keys', type = 'function' }, { name = 'each', type = 'function' } },
    },
    CisModuleInfo = {
        doc = "A DESCRIPTION of a module, which is what a consumer can actually be told. A function cannot cross the exports boundary, so the module table cannot be handed over either -- and cis_libs's own Cis.require is in a different Lua state from a consumer's, so it cannot be reached at all.",
        fields = { { name = 'ok', type = 'boolean', doc = 'false for an unknown name or a non-string, with the reason in .why' }, { name = 'name', type = 'string', doc = 'the module name asked for' }, { name = 'path', type = 'string', optional = true, doc = 'the file inside cis_libs that would be read' }, { name = 'global', type = 'string', optional = true, doc = 'the legacy global the file installs on a plain include' }, { name = 'deps', type = 'string[]', optional = true, doc = 'the modules required FIRST and placed in the sandbox under their own names' }, { name = 'globalPresent', type = 'boolean', doc = 'whether that legacy global exists on this realm. It must NOT -- and a plain include is exactly what makes it' }, { name = 'functions', type = 'string[]', optional = true, doc = "only under opts.load: the module's function names, sorted, so two calls in the same state answer in the same order" }, { name = 'loaded', type = 'boolean', optional = true, doc = 'only under opts.load: that the load succeeded' }, { name = 'globalPresentAfterLoad', type = 'boolean', optional = true, doc = 'only under opts.load, and THE assertion that matters: loading must still not have installed the global' }, { name = 'why', type = 'string', optional = true, doc = 'the refusal reason' }, { name = 'valid', type = 'string[]', optional = true, doc = 'on an unknown name, every name that would have worked' } },
    },
    CisRandom = {
        doc = "The table Cis.require('random') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'newGenerator', type = 'function', doc = 'newGenerator(seed?) -- MRG32k3a. Different seeds give unrelated streams; the sequence for a given seed changed in this release' }, { name = 'integer', type = 'function', doc = 'integer(lo, hi, rng?) -- inclusive and uniform. With no rng it is math.random over the whole integer range; with a generator or a function, a range of more than 2^53 values raises rather than answering' }, { name = 'float', type = 'function' }, { name = 'shuffle', type = 'function' }, { name = 'pick', type = 'function' }, { name = 'sample', type = 'function' }, { name = 'weighted', type = 'function' }, { name = 'weightedIndex', type = 'function' }, { name = 'gaussian', type = 'function' } },
    },
    CisRate = {
        doc = "The table Cis.require('rate') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'newFixed', type = 'function' }, { name = 'newSliding', type = 'function' }, { name = 'newTokenBucket', type = 'function' }, { name = 'allow', type = 'function' }, { name = 'peek', type = 'function' }, { name = 'reset', type = 'function' }, { name = 'clear', type = 'function' }, { name = 'prune', type = 'function' }, { name = 'count', type = 'function' } },
    },
    CisSelfCheck = {
        doc = 'What GetSelfCheck answers. ok = true WITH checkedAt = nil means the scan has not run yet -- not that the install is clean, and the two look identical to a caller. Every problem carries the fix.',
        fields = { { name = 'ok', type = 'boolean', doc = 'whether the install is clean' }, { name = 'checkedAt', type = 'integer', optional = true, doc = 'GetGameTimer of the scan, and nil until one has run' }, { name = 'problems', type = 'table[]', doc = 'an array of { code, message, fix }' } },
    },
    CisSemver = {
        doc = "The table Cis.require('semver') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'parse', type = 'function' }, { name = 'compare', type = 'function' }, { name = 'gte', type = 'function' }, { name = 'lt', type = 'function' }, { name = 'eq', type = 'function' }, { name = 'satisfies', type = 'function' }, { name = 'best', type = 'function' } },
    },
    CisSparse = {
        doc = "The table Cis.require('sparse') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'new', type = 'function' }, { name = 'add', type = 'function' }, { name = 'has', type = 'function' }, { name = 'remove', type = 'function' }, { name = 'at', type = 'function' }, { name = 'each', type = 'function' }, { name = 'toArray', type = 'function' }, { name = 'clear', type = 'function' }, { name = 'count', type = 'function' }, { name = 'isEmpty', type = 'function' }, { name = 'staleCount', type = 'function' } },
    },
    CisString = {
        doc = "The table Cis.require('string') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'words', type = 'function' }, { name = 'camel', type = 'function' }, { name = 'pascal', type = 'function' }, { name = 'snake', type = 'function' }, { name = 'kebab', type = 'function' }, { name = 'split', type = 'function' }, { name = 'truncate', type = 'function' }, { name = 'hasUtf8', type = 'function' }, { name = 'collapse', type = 'function' }, { name = 'contains', type = 'function' }, { name = 'startsWith', type = 'function' }, { name = 'endsWith', type = 'function' }, { name = 'padStart', type = 'function' }, { name = 'padEnd', type = 'function' }, { name = 'levenshtein', type = 'function' }, { name = 'suggest', type = 'function' }, { name = 'random', type = 'function' } },
    },
    CisSyncRecord = {
        doc = 'The record Cis.sync.ped / prop / vehicle accept. `kind` leads and is the discriminator, so the three collapse into one export with no ambiguity. Calling again with the same id MOVES the entity rather than respawning it, as long as the model and kind are unchanged.',
        fields = { { name = 'id', type = 'string|integer', doc = "the caller's own id, namespaced internally by the calling resource. A number is stringified at the boundary" }, { name = 'kind', type = 'string', doc = "'prop', 'vehicle' or 'ped'" }, { name = 'model', type = 'integer|string', doc = 'a hash or a model name' }, { name = 'coords', type = 'vector3|vector4|table', doc = 'a vector3, a vector4, or an { x, y, z } table. A non-finite number is refused with a reason' }, { name = 'heading', type = 'number', optional = true, doc = 'from w when the coords are a vector4, or from this key' }, { name = 'networked', type = 'boolean', optional = true, doc = 'asks the SERVER to create one entity (orphan mode KeepEntity, in the record\'s bucket) that OneSync streams. It never travels over the sync events and clients never move it; its metadata rides the entity\'s `cis_sync` state bag and is applied by the OWNING client. Refused with a reason when the kind has no server creation native or the server could not create it -- never stored without an entity, never downgraded' }, { name = 'respawn', type = 'boolean', optional = true, doc = 'networked only, default true: an entity removed behind the library\'s back (entityRemoved) is re-created, at most 3 times a minute; false drops the record with it' }, { name = 'scope', type = 'number', optional = true, doc = 'the streaming radius in metres, (0, 10000], default 80. Anything else is refused. On a networked record it is the entity\'s OneSync culling radius' }, { name = 'dynamic', type = 'boolean', optional = true, doc = 'the entity is placed at request time and does not need to persist. Counted in diagnostics; it does NOT make the record re-send: every record is sent when its revision changes, and only then' }, { name = 'bucket', type = 'integer', optional = true, doc = 'the routing bucket, applied on the server' }, { name = 'vehicleType', type = 'string', optional = true, doc = "only for kind = 'vehicle': automobile, bike, boat, heli, plane, submarine or trailer. Default automobile" }, { name = 'props', type = 'table', optional = true, doc = 'vehicle properties, applied with SetVehicleProperties. Shares the clientData cap' }, { name = 'freeze', type = 'boolean', optional = true, doc = 'a prop is frozen unless this is false; anything else only when true. Applied by the server for a networked record' }, { name = 'invincible', type = 'boolean', optional = true, doc = 'applied by the client that spawns it, or by the owner of a networked entity' }, { name = 'blockEvents', type = 'boolean', optional = true, doc = 'peds only; as invincible' }, { name = 'scenario', type = 'string', optional = true, doc = 'peds only; a scenario name, started in place' }, { name = 'clientData', type = 'table', optional = true, doc = 'caller data that reaches the client. clientData and props together are capped at 256 entries and 16 KB of strings at every depth. Anything else on the record is server-side' } },
    },
    CisSyncSummary = {
        doc = 'One row of Cis.sync.list(). A summary, not the record: the clientData is left out and model and scope are not defaulted, so either can be nil.',
        fields = { { name = 'id', type = 'string', doc = "the caller's own id, NOT the namespaced key the client sees" }, { name = 'kind', type = 'string', doc = "'prop', 'vehicle' or 'ped'" }, { name = 'model', type = 'integer|string', optional = true, doc = 'not defaulted, and therefore possibly nil' }, { name = 'coords', type = 'vector3|table', doc = 'the placement' }, { name = 'heading', type = 'number', optional = true, doc = 'the heading' }, { name = 'networked', type = 'boolean', doc = 'whether the caller asked for a server-created entity' }, { name = 'scope', type = 'string', optional = true, doc = 'not defaulted here either; DEFAULT_SCOPE is applied at the read sites, not at build time' }, { name = 'bucket', type = 'integer', optional = true, doc = 'the routing bucket' }, { name = 'dynamic', type = 'boolean', doc = 'whether the record is transient' } },
    },
    CisTable = {
        doc = "The table Cis.require('table') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'compareKeys', type = 'function' }, { name = 'isArray', type = 'function' }, { name = 'isMap', type = 'function' }, { name = 'isEmpty', type = 'function' }, { name = 'shallowCopy', type = 'function' }, { name = 'deepCopy', type = 'function' }, { name = 'depth', type = 'function' }, { name = 'deepCopyStrict', type = 'function' }, { name = 'findCycle', type = 'function' }, { name = 'count', type = 'function' }, { name = 'deepSize', type = 'function' }, { name = 'keys', type = 'function' }, { name = 'values', type = 'function' }, { name = 'each', type = 'function' }, { name = 'find', type = 'function' }, { name = 'filter', type = 'function' }, { name = 'map', type = 'function' }, { name = 'reduce', type = 'function' }, { name = 'sortBy', type = 'function' }, { name = 'join', type = 'function' }, { name = 'deepMerge', type = 'function' }, { name = 'deepMergeInto', type = 'function' } },
    },
    CisTargetOptions = {
        doc = 'The options table for Cis.target.add. Kept separate from CisZoneOptions because the two are read by different code and a shared class would claim fields that only one of them honours.',
        fields = { { name = 'icon', type = 'string', optional = true, doc = 'the provider icon name' }, { name = 'label', type = 'string', optional = true, doc = 'the provider label' }, { name = 'distance', type = 'number', optional = true, doc = 'the interaction distance, default 2.0' }, { name = 'options', type = 'table', optional = true, doc = 'a nested per-target table handed to the provider unexamined' }, { name = 'entity', type = 'table', optional = true, doc = 'required when remove is called with isPed, because that is how the local entity is found' } },
    },
    CisTime = {
        doc = "The table Cis.require('time') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'now', type = 'function' }, { name = 'parts', type = 'function' }, { name = 'formatDuration', type = 'function' }, { name = 'parseDuration', type = 'function' }, { name = 'relative', type = 'function' }, { name = 'elapsed', type = 'function' }, { name = 'roundTo', type = 'function' } },
    },
    CisValidate = {
        doc = "The table Cis.require('validate') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'isInteger', type = 'function' }, { name = 'isFinite', type = 'function' }, { name = 'number', type = 'function' }, { name = 'integer', type = 'function' }, { name = 'string', type = 'function' }, { name = 'boolean', type = 'function' }, { name = 'tableValue', type = 'function' }, { name = 'field', type = 'function' }, { name = 'schema', type = 'function' }, { name = 'defaults', type = 'function' }, { name = 'clamp', type = 'function' } },
    },
    CisVehicleProps = {
        doc = 'GetVehicleProperties and SetVehicleProperties, field-compatible with ox_lib getVehicleProperties (same names and meanings), plus lockState and livery. A PARTIAL table is safe to set: absent keys are left alone rather than zeroed. The mod slots (modSpoilers 0 through modLightbar 49, including modDoorR 47) are integers as GetVehicleMod answers them.',
        fields = { { name = 'model', type = 'integer', optional = true, doc = 'written by get, never read by set -- passing it is a no-op' }, { name = 'plate', type = 'string', optional = true, doc = 'the number plate text' }, { name = 'plateIndex', type = 'integer', optional = true, doc = 'the plate index' }, { name = 'lockState', type = 'integer', optional = true, doc = 'GetVehicleDoorLockStatus / SetVehicleDoorsLocked. 0 is unlocked and is a real state, not "absent"' }, { name = 'livery', type = 'integer', optional = true, doc = 'GetVehicleLivery; not the same as modLivery (mod 48) on every vehicle' }, { name = 'bodyHealth', type = 'number', optional = true, doc = 'floored on read' }, { name = 'engineHealth', type = 'number', optional = true, doc = 'the engine health' }, { name = 'tankHealth', type = 'number', optional = true, doc = 'the tank health' }, { name = 'fuelLevel', type = 'number', optional = true, doc = '0.0 to 1.0' }, { name = 'oilLevel', type = 'number', optional = true, doc = '0.0 to 1.0' }, { name = 'dirtLevel', type = 'number', optional = true, doc = '0.0 to 15.0' }, { name = 'paintType1', type = 'integer', optional = true, doc = 'the primary finish (0 normal, 1 metallic, 2 pearl, 3 matte, 4 metal, 5 chrome); applied before the colour on both the palette and the custom-RGB path' }, { name = 'paintType2', type = 'integer', optional = true, doc = 'the secondary finish; applied before the colour on both paths' }, { name = 'color1', type = 'integer|integer[]', optional = true, doc = 'a palette number, or { r, g, b } when custom' }, { name = 'color2', type = 'integer|integer[]', optional = true, doc = 'a palette number, or { r, g, b } when custom' }, { name = 'pearlescentColor', type = 'integer', optional = true, doc = 'the pearlescent finish' }, { name = 'wheelColor', type = 'integer', optional = true, doc = 'the wheel finish' }, { name = 'wheels', type = 'integer', optional = true, doc = 'the wheel type' }, { name = 'windowTint', type = 'integer', optional = true, doc = 'the window tint' }, { name = 'neonEnabled', type = 'boolean[]', optional = true, doc = 'four booleans, read up to #neonEnabled' }, { name = 'neonColor', type = 'integer[]', optional = true, doc = '{ r, g, b }' }, { name = 'extras', type = 'table<integer, integer>', optional = true, doc = 'keyed by extra id; 0 = on and 1 = off, and set sends `disable == 1 and 1 or 0`' }, { name = 'tyreSmokeColor', type = 'integer[]', optional = true, doc = '{ r, g, b }' }, { name = 'windows', type = 'integer[]', optional = true, doc = 'an index array of broken window ids 0-7' }, { name = 'doors', type = 'integer[]', optional = true, doc = 'an index array of broken door ids 0-5' }, { name = 'tyres', type = 'table<integer, integer>', optional = true, doc = 'tyre index (0-7, and 45 / 47 for a six-wheeled trailer) -> 1 burst, 2 burst to the rim' }, { name = 'modTurbo', type = 'boolean', optional = true, doc = 'toggle mod 18' }, { name = 'modSmokeEnabled', type = 'boolean', optional = true, doc = 'toggle mod 20' }, { name = 'modHydraulics', type = 'boolean', optional = true, doc = 'toggle mod 21' }, { name = 'modXenon', type = 'boolean', optional = true, doc = 'toggle mod 22' }, { name = 'modLivery', type = 'integer', optional = true, doc = 'mod 48 plus SetVehicleLivery' }, { name = 'modRoofLivery', type = 'integer', optional = true, doc = 'a second livery' }, { name = 'bulletProofTyres', type = 'boolean', optional = true, doc = 'true when the tyres CANNOT burst -- `not GetVehicleTyresCanBurst`, as ox_lib and qb store it' }, { name = 'driftTyres', type = 'boolean', optional = true, doc = 'applied only when the game build is 2372 or later, and the gate is in the code rather than in the type' }, { name = 'interiorColor', type = 'integer', optional = true, doc = 'GetVehicleInteriorColor / SetVehicleInteriorColor' }, { name = 'dashboardColor', type = 'integer', optional = true, doc = 'GetVehicleDashboardColour / SetVehicleDashboardColor' }, { name = 'wheelWidth', type = 'number', optional = true, doc = 'applied after the wheel mods: the native only takes on non-default rims' }, { name = 'wheelSize', type = 'number', optional = true, doc = 'applied after the wheel mods: the native only takes on non-default rims' }, { name = 'xenonColor', type = 'integer', optional = true, doc = 'GetVehicleXenonLightsColor / SetVehicleXenonLightsColor' } },
    },
    CisWeaponData = {
        doc = 'The record Cis.player.weapon and GetCurrentWeaponData answer. NIL as a whole when unarmed -- not a table of nils. GetCurrentWeaponData can hand back the LIVE cache table, so a caller holding it across frames is holding a snapshot that stops updating.',
        fields = { { name = 'hash', type = 'integer', optional = true, doc = 'the weapon hash; 0 or UNARMED means the record is nil' }, { name = 'ammo', type = 'integer', optional = true, doc = 'the rounds in the magazine' }, { name = 'ammoType', type = 'integer', optional = true, doc = 'the ped ammo type index' }, { name = 'attachments', type = 'integer[]', optional = true, doc = 'a dense array of component hashes' } },
    },
    CisWindow = {
        doc = "The table Cis.require('window') returns. It installs no global inside a sandbox, so a consumer reaches it through the require call and nowhere else.",
        fields = { { name = 'new', type = 'function' }, { name = 'push', type = 'function' }, { name = 'pop', type = 'function' }, { name = 'newest', type = 'function' }, { name = 'oldest', type = 'function' }, { name = 'each', type = 'function' }, { name = 'clear', type = 'function' }, { name = 'newDedupe', type = 'function' }, { name = 'seen', type = 'function' }, { name = 'isSeen', type = 'function' }, { name = 'reset', type = 'function' }, { name = 'prune', type = 'function' }, { name = 'dedupeCount', type = 'function' }, { name = 'newStats', type = 'function' }, { name = 'record', type = 'function' }, { name = 'read', type = 'function' }, { name = 'samples', type = 'function' }, { name = 'count', type = 'function' }, { name = 'extreme', type = 'function' }, { name = 'pruneStats', type = 'function' } },
    },
    CisZone = {
        doc = 'A zone as this library holds it, after defaults are applied. A caller never constructs one; it is what CreateZone made out of a name, a shape and CisZoneOptions.',
        fields = { { name = 'name', type = 'string', doc = 'the name the caller gave it, and the handle remove takes' }, { name = 'kind', type = 'string', doc = "'box', 'poly' or 'sphere'" }, { name = 'owner', type = 'string', doc = 'the resource that created it. Taken from the invoking resource, never from an argument, so two resources can both use "door1"' }, { name = 'debug', type = 'boolean', doc = 'whether a draw thread is running for it' } },
    },
    CisZoneDebug = {
        doc = 'The live debug record GetZoneDebug answers -- not a copy. insideCount and insideNames are rebuilt on every pass and zeroed when the last zone goes.',
        fields = { { name = 'lastPassMs', type = 'number', optional = true, doc = 'how long the last grid pass took' }, { name = 'lastPassAt', type = 'integer', optional = true, doc = 'GetGameTimer at the end of the last pass' }, { name = 'debugDrawing', type = 'boolean', optional = true, doc = 'whether a draw thread is running right now' }, { name = 'insideCount', type = 'integer', optional = true, doc = 'the zones the library believes the player is in' }, { name = 'insideNames', type = 'string[]', optional = true, doc = 'their names, sorted' } },
    },
    CisZoneOptions = {
        doc = 'The options table for Cis.zones.* and Cis.target.add. Every field is optional; a zone is created with defaults when one is absent. From init.lua (Cis.zones.*) the function fields are plain local functions run in the calling resource; through the CreateZone export they arrive as funcrefs. The event-name twins fire either way.',
        fields = { { name = 'onEnter', type = 'fun(zone: CisZone, coords: vector3)', optional = true, doc = "called pcall'd on the inside edge, with the ZONE and the player's own coordinates" }, { name = 'onExit', type = 'fun(zone: CisZone, coords: vector3)', optional = true, doc = "called pcall'd on the outside edge and on removal" }, { name = 'inside', type = 'fun(zone: CisZone)', optional = true, doc = 'called every insideInterval while the player is inside' }, { name = 'insideInterval', type = 'integer', optional = true, doc = 'ms between inside calls, default 500. Clamped up to 250 whenever insideEvent is set, so a networked event cannot be asked for faster than a quarter second' }, { name = 'debug', type = 'boolean', optional = true, doc = 'truthy starts the draw thread once registration succeeds' }, { name = 'onEnterEvent', type = 'string', optional = true, doc = 'fires with (zoneName, x, y, z). Falls back to TriggerServerEvent when onEnter is absent. Every event name is a string of 1 to 128 bytes; anything else refuses the zone by name' }, { name = 'onExitEvent', type = 'string', optional = true, doc = 'fires with (zoneName, x, y, z). The only way a consumer outside this VM learns the player left' }, { name = 'insideEvent', type = 'string', optional = true, doc = 'its presence is what forces the 250ms clamp' }, { name = 'local', type = 'boolean', optional = true, doc = 'exactly true switches ALL THREE events (onEnterEvent, onExitEvent, insideEvent) to client-local TriggerEvent instead of TriggerServerEvent. A local event from a resource other than cis_libs must be named <resource>:... -- the creating resource -- so it cannot fire cis_libs:cache, onResourceStop or the events of another resource with cis_libs as the invoker' }, { name = 'minZ', type = 'number', optional = true, doc = 'the floor, default -1000.0, and the fallback Z for any poly point with no z. Must be finite and no higher than maxZ' }, { name = 'maxZ', type = 'number', optional = true, doc = 'the ceiling, default 10000.0' }, { name = 'thickness', type = 'number', optional = true, doc = 'poly only: a slab this many metres tall around the average z of the points, as ox_lib; ignored when minZ or maxZ is given' }, { name = 'heading', type = 'number', optional = true, doc = 'the box heading; a finite number' }, { name = 'rotation', type = 'number', optional = true, doc = 'an alias for the box heading' } },
    },
    },

    events = {
        -- 1.1.0. The cache mirror's feed: cis_libs' client/cache.lua fires it
        -- (LOCAL, never to the server) once per changed key per pass, and the
        -- consumer mirror (client/core/mirror.lua) applies it only when the
        -- invoking resource is cis_libs.
        ['cis_libs:cache'] = {
            since = '1.1.0',
            payload = 'client, local: (key, value, seat, silent) -- seat rides on a vehicle push; silent marks a refresh with no change to announce',
        },
        -- T9. Fired by cis_libs at the ONE place a slot changes hands, so a
        -- consumer can stop polling. Announced on register AND on release: a
        -- waiter that only heard about registration would wait out its full
        -- timeout after a provider restarted.
        ['cis_libs:capabilityChanged'] = {
            since = '1.0.0',
            payload = 'both realms: ({ slot, action, owner, previousOwner, resolved })',
        },
        ['cis_libs:cb'] = {
            since = '1.0.0',
            payload = 'client to server and server to client: (name, key, ...). `key` is the caller\'s opaque pending token, echoed back unchanged. The client handler ignores a local TriggerEvent (`source` is empty): only the server can ask a client callback.',
        },
        ['cis_libs:cb:res'] = {
            since = '1.0.0',
            payload = 'client: (key, ok, ...) resolving an outstanding callback. Only a reply from the server counts; a local TriggerEvent (`source` is empty) is ignored.',
        },
        ['cis_libs:cb:serverRes'] = {
            since = '1.0.0',
            payload = 'server: (key, ok, ...) resolving an outstanding client callback',
        },
        ['cis_libs:client:getData'] = {
            since = '1.0.0',
            payload = 'server to client: ({ Config, EventPrefix, Providers }) on join, and to every client after SetConfig. Providers is "any" or the CisConfigUtil.digest of each Security.AuthorizedResources name (never the names), and gates client RegisterCapability. A local TriggerEvent is ignored. DoorData was not shipped in 1.0.0',
        },
        ['cis_libs:server:getData'] = {
            since = '1.0.0',
            payload = 'client to server: no arguments, requests the config payload',
        },
        ['cis_libs:client:showNotification'] = {
            since = '1.0.0',
            payload = 'server to client: (message, kind)',
        },
        ['cis_libs:client:inventory'] = {
            since = '1.0.0',
            payload = 'server to client: ({ [itemName] = count }), pushed by PublishInventory',
            ['until'] = '2.0.0',
            deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge inventory API',
        },
        ['cis_libs:server:inventorySync'] = {
            since = '1.0.0',
            payload = 'client to server: no arguments, requests an inventory snapshot',
            ['until'] = '2.0.0',
            deprecated = true,
            use = 'deprecated since 1.1.0; use the cis_bridge inventory API',
        },
        ['cis_libs:client:syncBatch'] = {
            since = '1.0.0',
            payload = 'server to client: (n, upserts, removes). ONE event per player per pass, latent when it carries 32 entries or more. `n` numbers the batches sent to that player, and a client applies an entry only if no later batch has touched that key, so a reliable batch overtaking a latent one is safe. `upserts` are CLIENT-LOCAL records (identity `record.key`, the caller\'s id namespaced by its owning resource; `record.rev` is its revision); a networked record is never on this wire. `removes` are keys to despawn. The client applies a batch only from the server (a local TriggerEvent is ignored) and only when `n` is an integer in 1..2^31-1.',
        },
        ['cis_libs:server:syncSnapshot'] = {
            since = '1.0.0',
            payload = 'client to server: (held) sent when the client\'s sync scripts load, `held` being { [key] = rev } of what it still holds (nothing, on a fresh start). The server reconciles what it believed this player held against the claim, answers with one capped batch and lets the pass deliver the rest. Honoured once per 10 s per player.',
        },
        ['cis_libs:server:syncGaveUp'] = {
            since = '1.0.0',
            payload = 'client to server: (key) the client could not load that record\'s model after its retries. The server stops believing the client holds it and holds back that revision for 30 s.',
        },
        ['cis_libs:jobUpdated'] = {
            since = '1.0.0',
            payload = 'server to client: ({ name, grade }), fired by PublishJobUpdate',
        },
        ['cis_libs:playerLoaded'] = {
            since = '1.0.0',
            payload = 'server to client: (job), fired by PublishPlayerLoaded',
        },
        ['cis_libs:client:uiNotify'] = {
            since = '1.1.0',
            payload = 'server to client: (data) a Notify table, sent by NotifyPlayer. Accepted only from the network: a local TriggerEvent of it is ignored',
        },
        ['chat:addSuggestion'] = {
            since = '1.0.0',
            payload = 'server to client, (name, help, params) while the chat resource is started. The one new standard-resource integration allowed, used only by Cis.command.add. Sent to -1 on add and when chat starts, and to each player as they join',
        },
        ['chat:removeSuggestion'] = {
            since = '1.0.0',
            payload = 'server to client, (name) while the chat resource is started: the same seam, taking a suggestion back when its command is removed or its resource stops',
        },
    },
}

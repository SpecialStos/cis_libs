// Stage 1.6: the consumer compatibility test.
//
// cis_libs is a library, so the only thing that matters about its public
// surface is what the sibling resources actually call. This reads the fixture
// tools/scan-consumers.js produced and checks every name they use still exists.
//
// The asymmetry between the two kinds of name is the point:
//
//   Cis.<ns>.<fn>   is defined by init.lua, which the manifest loads as a
//                   SHARED script. Every one of those exists on both realms, so
//                   the check is simply "is it still defined".
//   exports.<Name>  is registered per realm, and api.lua records which. A name
//                   used from a client file has to exist on the client, one used
//                   from a server file on the server, and neither may be marked
//                   deprecated-with-a-removal-date without that being a
//                   deliberate, recorded decision.
//
// WHY IT IS PART OF `npm test` AND NOT ONLY `npm run test:api`. The requirement
// is that renaming any name a sibling uses turns the test suite red. A check
// that only runs in a separate script is a check somebody skips.

const fs = require('fs')
const path = require('path')
const fengari = require('fengari')
const lua = fengari.lua
const lauxlib = fengari.lauxlib
const lualib = fengari.lualib
const toLua = fengari.to_luastring
const { scanResource, stripComments } = require('./lua-exports.js')

const root = path.join(__dirname, '..')
const FIXTURE = path.join(root, 'test', 'fixtures', 'consumers.json')

// ---------------------------------------------------------- reading api.lua
// api.lua is pure data, so it loads in a bare Lua state with nothing else in
// it -- which is also the proof it needs no provider to be read.
function readValue(L, idx = -1) {
  const t = lua.lua_type(L, idx)
  if (t === lua.LUA_TTABLE) {
    const o = {}
    lua.lua_pushnil(L)
    while (lua.lua_next(L, idx === -1 ? idx - 1 : idx) !== 0) {
      o[lua.lua_tojsstring(L, -2)] = readValue(L)
      lua.lua_pop(L, 1)
    }
    return o
  }
  if (t === lua.LUA_TBOOLEAN) return lua.lua_toboolean(L, idx) === 1
  if (t === lua.LUA_TNUMBER) return lua.lua_tonumber(L, idx)
  if (t === lua.LUA_TSTRING) return lua.lua_tojsstring(L, idx)
  return null
}

function loadApi(file) {
  const L = lauxlib.luaL_newstate()
  lualib.luaL_openlibs(L)
  const src = fs.readFileSync(file, 'utf8')
  const chunk = toLua(src)
  if (lauxlib.luaL_loadbuffer(L, chunk, null, toLua(path.basename(file))) !== lua.LUA_OK) {
    throw new Error('api.lua did not load: ' + lua.lua_tojsstring(L, -1))
  }
  lua.lua_call(L, 0, 1)
  return readValue(L)
}

// ------------------------------------------------------- reading init.lua
// The Cis namespace is built by init.lua, so it has to be read out of init.lua
// rather than out of api.lua: api.lua documents the exports, and the exports
// and the namespace are two surfaces that happen to belong to one library.
function cisNamespaces(file) {
  const code = stripComments(fs.readFileSync(file, 'utf8'))
  const out = new Set()
  const add = m => { if (m) out.add(m[1] + '.' + m[2]) }
  // function Cis.net.on(...)   and   Cis.net.on = function(...)
  let m
  const fn = /(?:\bfunction\s+Cis\.([A-Za-z_]\w*)\.([A-Za-z_]\w*)\s*[(=])/g
  while ((m = fn.exec(code)) !== null) add(m)
  const asg = /(?:\bCis\.([A-Za-z_]\w*)\.([A-Za-z_]\w*)\s*=\s*function\s*\()/g
  while ((m = asg.exec(code)) !== null) add(m)
  return out
}

function main() {
  if (!fs.existsSync(FIXTURE)) {
    console.error(`consumer fixture missing: ${path.relative(root, FIXTURE)}`)
    console.error('Regenerate it with: npm run scan:consumers')
    process.exit(2)
  }
  const consumers = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'))
  const api = loadApi(path.join(root, 'api.lua'))
  const surface = scanResource(root)
  const cis = cisNamespaces(path.join(root, 'init.lua'))

  // What each realm actually registers.
  const registered = { server: new Set(), client: new Set() }
  for (const e of surface.exports) {
    if (e.realm === 'server' || e.realm === 'both') registered.server.add(e.name)
    if (e.realm === 'client' || e.realm === 'both') registered.client.add(e.name)
  }

  const problems = []
  const seen = new Set()

  for (const r of consumers.resources) {
    for (const realm of ['client', 'server', 'shared']) {
      for (const c of r.cisCalls[realm] || []) {
        const key = `cis|${c.key}|shared`
        if (seen.has(key)) continue
        seen.add(key)
        if (!cis.has(c.key)) {
          problems.push(`${r.name}: Cis.${c.key} (used from ${realm}) is no longer defined in init.lua`)
        }
      }
      for (const c of r.exportCalls[realm] || []) {
        const key = `exp|${c.key}|${realm}`
        if (seen.has(key)) continue
        seen.add(key)
        const meta = (api.exports || {})[c.key]
        if (!meta) {
          problems.push(`${r.name}: exports.cis_libs:${c.key} (used from ${realm}) is not declared in api.lua`)
          continue
        }
        // A shared file runs on BOTH VMs, but a given call inside it does not
        // necessarily run on both: cis_business calls DbQuery from a shared file
        // inside an IsDuplicityVersion() branch, so that call is server-only.
        // Demanding both realms here produced twelve false failures on the
        // first run and taught us nothing. The rule that is both true and
        // useful: a client file needs the client realm, a server file the server
        // realm, and a shared file needs the name to exist on at least one --
        // which still catches a rename, which is what this check is for.
        const realms = realm === 'shared' ? ['client', 'server'] : [realm]
        if (!realms.some(need => registered[need].has(c.key))) {
          problems.push(`${r.name}: exports.cis_libs:${c.key} is used from ${realm} ` +
            `but is registered on neither realm`)
        }
        // Deprecated is allowed -- that is the contract. Deprecated AND dated for
        // removal is a decision someone has to make on purpose, so it is
        // reported here and the deprecation record is the place to argue about it.
        if (meta.deprecated && meta.until && meta.until !== false) {
          problems.push(`${r.name}: exports.cis_libs:${c.key} is deprecated and due for removal in ${meta.until}`)
        }
      }
    }
  }

  const usedExports = consumers.summary.exportCalls.length
  const usedCis = consumers.summary.cisCalls.length
  console.log(`consumer compatibility: ${consumers.resourceCount} resources, ` +
    `${usedCis} Cis.* names, ${usedExports} exports`)

  if (problems.length) {
    console.error(`FAIL ${problems.length} consumer names would break:`)
    for (const p of problems) console.error('  ' + p)
    process.exitCode = 1
    return
  }
  console.log(`  every name the siblings use still exists on the realm they call it from`)
}

main()
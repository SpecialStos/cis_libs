#!/usr/bin/env node
'use strict'

// Validates a resource's api.lua against what the resource actually registers.
//
// The declaration is not the truth. The truth is the source. This reads both
// and fails on the difference, so a manifest cannot drift away from the code
// without CI going red.
//
//   node tools/validate-api.js --api api.lua --resource .
//   node tools/validate-api.js --selftest
//
// Exit codes: 0 clean, 1 findings, 2 usage error.
//
// `--selftest` is the part that makes the checker trustworthy. A validator that
// has only ever been seen to pass has not been tested. It asserts three things
// about itself: the real manifest is clean, and each deliberately broken
// fixture fails with the diagnostic it was built to trigger.

const fs = require('fs')
const path = require('path')
const { scanResource, PREFIX, stripComments } = require('./lua-exports.js')

const fengari = require('fengari')
const lua = fengari.lua
const lauxlib = fengari.lauxlib
const lualib = fengari.lualib
const toLua = fengari.to_luastring

const SEMVER = /^\d+\.\d+\.\d+$/
const SIGNATURE_RE = /^\(([^)]*)\)$/

// ------------------------------------------------------------------ findings

class Report {
  constructor() {
    this.findings = []
  }
  add(code, where, message) {
    this.findings.push({ code, where, message })
  }
  get ok() {
    return this.findings.length === 0
  }
  render(label) {
    if (this.ok) {
      process.stdout.write(`  PASS  ${label}\n`)
      return true
    }
    for (const f of this.findings) {
      process.stdout.write(`  FAIL  ${label} [${f.code}] ${f.where}: ${f.message}\n`)
    }
    return false
  }
}

// ------------------------------------------------------------- loading lua

// api.lua is pure data, so it loads in a bare Lua state with nothing but the
// standard library. That is also the proof it needs no provider to be read.
function loadManifest(file, realFile) {
  const L = lauxlib.luaL_newstate()
  lualib.luaL_openlibs(L)
  // A broken fixture is allowed to start from the real manifest and change one
  // thing about it, so that the only thing wrong with it is the thing it is
  // named for. The path arrives as a global because a fixture has no other way
  // to find the repo root.
  if (realFile) {
    lua.lua_pushstring(L, toLua(realFile))
    lua.lua_setglobal(L, toLua('CIS_API_REAL'))
  }
  const src = fs.readFileSync(file, 'utf8')
  const chunk = toLua(src)
  const status = lauxlib.luaL_loadbuffer(L, chunk, null, toLua(path.basename(file)))
  if (status !== lua.LUA_OK) {
    return { error: lua.lua_tojsstring(L, -1) }
  }
  lua.lua_call(L, 0, 1)
  return { table: readValue(L) }
}

// Walk the Lua value at the top of the stack into JS. Always leaves the stack
// exactly as it found it.
function readValue(L) {
  const t = lua.lua_type(L, -1)
  switch (t) {
    case lua.LUA_TNIL:
    case lua.LUA_TNONE:
      lua.lua_pop(L, 1)
      return null
    case lua.LUA_TBOOLEAN: {
      const b = lua.lua_toboolean(L, -1) === 1
      lua.lua_pop(L, 1)
      return b
    }
    case lua.LUA_TNUMBER: {
      const n = lua.lua_tonumber(L, -1)
      lua.lua_pop(L, 1)
      return n
    }
    case lua.LUA_TSTRING: {
      const s = lua.lua_tojsstring(L, -1)
      lua.lua_pop(L, 1)
      return s
    }
    case lua.LUA_TTABLE:
      return readTable(L)
    default: {
      // Anything executable is disqualifying: a manifest must be data.
      lua.lua_getglobal(L, toLua('tostring'))
      lua.lua_pushvalue(L, -2)
      lua.lua_call(L, 1, 1)
      const s = lua.lua_tojsstring(L, -1)
      lua.lua_settop(L, -3)
      return { __opaque: s }
    }
  }
}

function readTable(L) {
  const out = {}
  const n = lua.lua_rawlen(L, -1)
  for (let i = 1; i <= n; i++) {
    lua.lua_rawgeti(L, -1, i)
    out.push(readValue(L))
  }
  lua.lua_pushnil(L)
  while (lua.lua_next(L, -2) !== 0) {
    // lua_next leaves [table, key, value] and readValue is balanced, so this
    // is [table, key] -- exactly what lua_next needs to advance. Re-seeding
    // with nil here would restart the iteration and never terminate.
    const key = lua.lua_tojsstring(L, -2)
    out[key] = readValue(L)
  }
  lua.lua_pop(L, 1)
  return out
}

// ---------------------------------------------------------------- validation

function validate(manifest, surface, opts = {}) {
  const r = new Report()
  const strict = opts.strict !== false

  if (!manifest || typeof manifest !== 'object') {
    r.add('E000', 'api.lua', 'did not return a table')
    return r
  }
  if (manifest.__opaque) {
    r.add('E000', 'api.lua', `contains an executable value (${manifest.__opaque}); a manifest must be pure data`)
    return r
  }

  // ---- top level
  if (typeof manifest.name !== 'string' || manifest.name === '') {
    r.add('E001', 'name', 'must be a non-empty string')
  }
  if (typeof manifest.version !== 'string' || !SEMVER.test(manifest.version)) {
    r.add('E001', 'version', `must be a MAJOR.MINOR.PATCH string (got ${JSON.stringify(manifest.version)})`)
  } else {
    // The product version is stated in three places, and they are not
    // interchangeable: fxmanifest.lua is what the SERVER reports through
    // GetResourceMetadata and therefore what server/version.lua compares an
    // operator's update endpoint against, package.json is what a tool reads,
    // and this field is the contract's own copy. They drifted apart here
    // (2.0.0 against 1.0.0) and nothing noticed, which means every operator who
    // turned on the update check was told their 2.0.0 install was out of date
    // against a 1.0.0 endpoint, forever.
    //
    // So they are compared, and a disagreement is a failure. A version bump is
    // three edits; finding out three weeks later that the updater is lying to
    // every customer is not a cheap mistake.
    const fromManifest = readManifestVersion(opts.resourceDir)
    if (fromManifest && fromManifest !== manifest.version) {
      r.add('E001', 'version',
        `is ${manifest.version} here but ${fromManifest} in fxmanifest.lua; the server reports the manifest's value, ` +
        'so the update check compares against the wrong number')
    }
    const pkg = readPackageVersion(REPO_ROOT)
    if (pkg && pkg !== manifest.version) {
      r.add('E001', 'version', `is ${manifest.version} here but ${pkg} in package.json`)
    }
  }
  if (!Number.isInteger(manifest.api)) {
    r.add('E001', 'api', `contract major must be an integer (got ${JSON.stringify(manifest.api)})`)
  }

  // ---- exports
  const declared = manifest.exports
  if (!declared || typeof declared !== 'object') {
    r.add('E002', 'exports', 'must be a table')
    return r
  }

  const registered = new Map() // realm -> Map(name -> {params, file})
  for (const realm of ['server', 'client']) {
    const m = new Map()
    for (const e of surface.exports.filter((x) => x.realm === realm)) {
      m.set(e.name, e)
    }
    registered.set(realm, m)
  }

  const declaredNames = new Set()
  for (const name of Object.keys(declared)) {
    const meta = declared[name]
    const where = `exports.${name}`
    declaredNames.add(name)

    if (!meta || typeof meta !== 'object') {
      r.add('E010', where, 'must be a table')
      continue
    }

    // `since` is the one field a declaration cannot do without. Without it
    // there is no way to say when a consumer may start relying on the entry.
    if (typeof meta.since !== 'string' || !SEMVER.test(meta.since)) {
      r.add('E010', `${where}.since`, `is required and must be MAJOR.MINOR.PATCH (got ${JSON.stringify(meta.since)})`)
    }
    if (meta.until !== false && meta.until !== undefined) {
      if (typeof meta.until !== 'string' || !SEMVER.test(meta.until)) {
        r.add('E011', `${where}.until`, `must be false or a MAJOR.MINOR.PATCH string (got ${JSON.stringify(meta.until)})`)
      } else if (SEMVER.test(meta.since || '') && meta.until < meta.since) {
        r.add('E011', `${where}.until`, `(${meta.until}) is before since (${meta.since})`)
      }
    }
    if (typeof meta.stable !== 'boolean') {
      r.add('E012', `${where}.stable`, `must be a boolean (got ${JSON.stringify(meta.stable)})`)
    }
    if (typeof meta.deprecated !== 'boolean') {
      r.add('E012', `${where}.deprecated`, `must be a boolean (got ${JSON.stringify(meta.deprecated)})`)
    }
    if (typeof meta.use !== 'string' || meta.use === '') {
      r.add('E013', `${where}.use`, 'must be a non-empty string naming the supported path')
    }
    if (meta.deprecated === true && meta.use === undefined) {
      r.add('E013', `${where}.use`, 'a deprecated entry must say what to use instead')
    }
    if (meta.deprecated === true && meta.until === false) {
      r.add('E011', `${where}.until`, 'a deprecated entry needs a removal major in `until`')
    }

    const realm = meta.realm === undefined ? 'both' : meta.realm
    if (!['server', 'client', 'both'].includes(realm)) {
      r.add('E020', `${where}.realm`, `must be 'server', 'client' or 'both' (got ${JSON.stringify(meta.realm)})`)
      continue
    }
    const realms = realm === 'both' ? ['server', 'client'] : [realm]

    // ---- drift: declared but not registered
    for (const rm of realms) {
      const actual = registered.get(rm)
      if (!actual.has(name)) {
        r.add('E030', where, `declared for realm '${rm}' but the resource never registers it there`)
      }
    }

    // ---- drift: signature
    const sigs = typeof meta.signature === 'string' ? null : meta.signature
    if (sigs !== null && (typeof sigs !== 'object' || sigs === null)) {
      r.add('E014', `${where}.signature`, 'must be a string or a { server = ..., client = ... } table')
      continue
    }
    for (const rm of realms) {
      const actual = registered.get(rm).get(name)
      if (!actual) continue
      let declaredSig
      if (sigs === null) {
        declaredSig = meta.signature
      } else {
        declaredSig = sigs[rm]
        if (declaredSig === undefined) {
          r.add('E014', `${where}.signature`, `has no '${rm}' entry for a realm-specific signature`)
          continue
        }
      }
      if (typeof declaredSig !== 'string') {
        r.add('E014', `${where}.signature[${rm}]`, 'must be a string')
        continue
      }
      const m = declaredSig.trim().match(SIGNATURE_RE)
      if (!m) {
        r.add('E014', `${where}.signature[${rm}]`, `must be a parenthesised parameter list, got ${JSON.stringify(declaredSig)}`)
        continue
      }
      const declaredParams = m[1]
        .split(',')
        .map((p) => p.trim())
        .filter((p) => p.length > 0)
      if (!actual.resolved) {
        // A hole we can see. Failing here is the point: a signature nobody
        // checked is a signature nobody should trust.
        r.add('E033', `${where}.signature[${rm}]`, `cannot be verified against the source (${actual.via}: ${actual.why})`)
        continue
      }
      if (declaredParams.join(', ') !== actual.params.join(', ')) {
        r.add(
          'E032',
          `${where}.signature[${rm}]`,
          `declares (${declaredParams.join(', ')}) but ${actual.file} registers (${actual.params.join(', ')})`,
        )
      }
    }
  }

  // ---- drift: registered but not declared
  for (const realm of ['server', 'client']) {
    for (const [name, e] of registered.get(realm)) {
      if (!declaredNames.has(name)) {
        r.add('E031', `exports.${name}`, `registered in ${e.file} (${realm}) but not declared in api.lua`)
      }
    }
  }

  // ---- events
  const declaredEvents = manifest.events
  if (declaredEvents !== undefined && (typeof declaredEvents !== 'object' || declaredEvents === null)) {
    r.add('E040', 'events', 'must be a table when present')
  } else if (declaredEvents !== undefined) {
    const scanned = new Set(surface.events)
    for (const name of Object.keys(declaredEvents)) {
      const meta = declaredEvents[name]
      const where = `events['${name}']`
      if (typeof meta.since !== 'string' || !SEMVER.test(meta.since)) {
        r.add('E040', `${where}.since`, `is required and must be MAJOR.MINOR.PATCH (got ${JSON.stringify(meta.since)})`)
      }
      if (typeof meta.payload !== 'string' || meta.payload === '') {
        r.add('E040', `${where}.payload`, 'must be a non-empty string describing the arguments')
      }
      if (!scanned.has(name)) {
        r.add('E041', where, 'declared but no source file references this event name')
      }
    }
    for (const name of scanned) {
      if (!Object.prototype.hasOwnProperty.call(declaredEvents, name)) {
        r.add('E042', `events['${name}']`, 'used in the source but not declared in api.lua')
      }
    }
  }

  if (strict) {
    for (const u of surface.unresolved) {
      r.add('E033', `exports.${u.name}`, `signature cannot be read from ${u.file} (${u.why})`)
    }
  }
  for (const w of surface.warnings) {
    r.add('E050', 'fxmanifest.lua', w)
  }
  return r
}

// ------------------------------------------------------------------ fixtures

const REPO_ROOT = path.join(__dirname, '..')

// The `version` directive out of fxmanifest.lua, which is the number the FiveM
// server actually reports. Null when there is no manifest, so a resource checked
// without one is not failed for something it does not claim.
function readManifestVersion(resourceDir) {
  if (!resourceDir) return null
  const file = path.join(resourceDir, 'fxmanifest.lua')
  if (!fs.existsSync(file)) return null
  const clean = stripComments(fs.readFileSync(file, 'utf8'))
  const m = clean.match(/^\s*version\s+["']([^"']+)["']/m)
  return m ? m[1] : null
}

function readPackageVersion(dir) {
  const file = path.join(dir, 'package.json')
  if (!fs.existsSync(file)) return null
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8')).version || null
  } catch (e) {
    return null
  }
}

function runOne(apiFile, resourceDir, label, opts) {
  const surface = scanResource(resourceDir)
  const loaded = loadManifest(apiFile, path.join(REPO_ROOT, 'api.lua'))
  if (loaded.error) {
    const r = new Report()
    r.add('E000', path.relative(process.cwd(), apiFile), `did not load: ${loaded.error}`)
    return r.render(label)
  }
  return validate(loaded.table, surface, { ...opts, resourceDir }).render(label)
}

function selftest(root) {
  const brokenDir = path.join(root, 'test', 'api', 'broken')
  const fixtures = fs.existsSync(brokenDir)
    ? fs
        .readdirSync(brokenDir)
        .filter((d) => fs.existsSync(path.join(brokenDir, d, 'api.lua')))
        .sort()
    : []

  process.stdout.write('api.lua self-test\n')

  // 1. the real thing must be clean
  const real = runOne(path.join(root, 'api.lua'), root, 'real api.lua matches the real surface')
  let allGood = real

  // 2. each broken fixture must fail, and fail for its own reason
  for (const name of fixtures) {
    const apiFile = path.join(brokenDir, name, 'api.lua')
    const expectFile = path.join(brokenDir, name, 'expect.txt')
    if (!fs.existsSync(expectFile)) {
      process.stdout.write(`  FAIL  broken/${name} has no expect.txt, so it is an unverified fixture\n`)
      allGood = false
      continue
    }
    const expected = fs.readFileSync(expectFile, 'utf8').trim().split('\n').map((s) => s.trim()).filter(Boolean)
    const surface = scanResource(root)
    const loaded = loadManifest(apiFile, path.join(REPO_ROOT, 'api.lua'))
    const report = loaded.error
      ? Object.assign(new Report(), { findings: [{ code: 'E000', where: name, message: loaded.error }] })
      : validate(loaded.table, surface, { strict: true, resourceDir: root })
    if (report.ok) {
      process.stdout.write(`  FAIL  broken/${name} validated clean; a broken fixture that passes proves nothing\n`)
      allGood = false
      continue
    }
    const got = report.findings.map((f) => f.code)
    const missing = expected.filter((code) => !got.includes(code))
    if (missing.length > 0) {
      process.stdout.write(
        `  FAIL  broken/${name} did not raise ${missing.join(', ')}; got ${[...new Set(got)].join(', ') || 'nothing'}\n`,
      )
      allGood = false
      continue
    }
    process.stdout.write(`  PASS  broken/${name} fails with ${[...new Set(got)].join(', ')}\n`)
  }

  if (fixtures.length === 0) {
    process.stdout.write('  FAIL  no broken fixtures found; the self-test would be vacuous\n')
    allGood = false
  }
  return allGood
}

// ---------------------------------------------------------------------- main

function main(argv) {
  const root = REPO_ROOT
  const args = parseArgs(argv)

  if (args.help) {
    process.stdout.write(
      [
        'usage:',
        '  node tools/validate-api.js --api <api.lua> --resource <dir> [--no-strict]',
        '  node tools/validate-api.js --selftest',
        '',
        `--api       path to the manifest (default: <resource>/api.lua)`,
        '--resource  the resource directory whose source is the truth (default: repo root)',
        '--selftest  assert the validator passes the real manifest and rejects the',
        '            deliberately broken fixtures in test/api/broken/',
        '',
        `events whose names are computed from Security.EventPrefix are written as`,
        `${PREFIX}:doorlock:... in a manifest, because a consumer cannot hardcode them.`,
        '',
      ].join('\n'),
    )
    return 0
  }

  if (args.selftest) {
    return selftest(root) ? 0 : 1
  }

  const resourceDir = path.resolve(root, args.resource || '.')
  const apiFile = path.resolve(root, args.api || path.join(resourceDir, 'api.lua'))
  if (!fs.existsSync(apiFile)) {
    process.stderr.write(`no api.lua at ${path.relative(root, apiFile)}\n`)
    return 2
  }

  const surface = scanResource(resourceDir)
  const loaded = loadManifest(apiFile, path.join(REPO_ROOT, 'api.lua'))
  if (loaded.error) {
    process.stderr.write(`${path.relative(root, apiFile)} did not load: ${loaded.error}\n`)
    return 1
  }
  const report = validate(loaded.table, surface, { strict: args.strict, resourceDir })

  const label = `${path.relative(root, apiFile)} vs ${path.relative(root, resourceDir) || '.'}`
  const ok = report.render(label)
  process.stdout.write(
    `        surface: ${surface.counts.server} server exports, ${surface.counts.client} client exports, ` +
      `${surface.events.length} net events\n`,
  )
  if (loaded.table && loaded.table.api !== undefined) {
    process.stdout.write(`        contract major: ${loaded.table.api}, product version: ${loaded.table.version}\n`)
  }
  return ok ? 0 : 1
}

function parseArgs(argv) {
  const out = { strict: true }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--selftest') out.selftest = true
    else if (a === '--help' || a === '-h') out.help = true
    else if (a === '--no-strict') out.strict = false
    else if (a === '--api') out.api = argv[++i]
    else if (a === '--resource') out.resource = argv[++i]
  }
  return out
}

process.exit(main(process.argv.slice(2)))

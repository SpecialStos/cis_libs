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
const typed = require('./validate-types.js')

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
  // A table with a non-empty ARRAY part is an array, and it has to be read
  // into one. The typed schema added `params = { { name = ... }, ... }` to
  // every export, and that is the first array in this manifest -- so the
  // `out.push` below had never once run, and a defect that had been sitting in
  // the validator since it was written surfaced the moment the data shape
  // changed. Reading it into `{}` and calling push on it is a TypeError that
  // says nothing about which entry caused it.
  const n = lua.lua_rawlen(L, -1)
  const out = n > 0 ? [] : {}
  for (let i = 1; i <= n; i++) {
    lua.lua_rawgeti(L, -1, i)
    out.push(readValue(L))
  }
  lua.lua_pushnil(L)
  while (lua.lua_next(L, -2) !== 0) {
    // lua_next leaves [table, key, value] and readValue is balanced, so this
    // is [table, key] -- exactly what lua_next needs to advance. Re-seeding
    // with nil here would restart the iteration and never terminate.
    //
    // THE KEY MUST NOT BE READ AS A STRING, and that is not a style note.
    // fengari's `lua_tojsstring` converts the stack slot IN PLACE: asked for a
    // number key it turns the 2 into the string "2" and hands the string back.
    // The next `lua_next` is then given "2" as the key for a table whose keys
    // are numbers, and Lua answers "invalid key to 'next'" -- a panic with no
    // mention of the manifest, the export, or the line that caused it.
    //
    // It never showed before the typed schema because every table in api.lua
    // had string keys; the first `params = { { name = ... } }` array in the
    // file turned a defect that had been sitting in this reader since it was
    // written into a crash on every run.
    const keyType = lua.lua_type(L, -2)
    const isIndex = keyType === lua.LUA_TNUMBER
    const key = isIndex ? lua.lua_tonumber(L, -2) : lua.lua_tojsstring(L, -2)
    const value = readValue(L)
    // THE ARRAY PART IS ALREADY READ, and reading it twice is not a harmless
    // repeat. Lua's keys are 1-based and a JS array's are 0-based, so the
    // second pass wrote key 1 over slot 1 -- which held key 2 -- and turned
    // (name, handler) into (name, name, handler). It is a shift, not a
    // duplicate, so the array stayed the right LENGTH and the corruption was
    // invisible to every count and to a length check. Only comparing the
    // names against the source caught it.
    if (isIndex && Number.isInteger(key) && key <= n) {
      // The key STAYS. lua_next consumes the key it is handed and leaves the
      // next one behind; popping it here ends the walk early, and the table
      // argument it is given on the way out is the key rather than the table.
      continue
    }
    out[key] = value
  }
  lua.lua_pop(L, 1)
  return out
}

// ---------------------------------------------------------------- validation

function validate(manifest, surface, opts = {}) {
  const resourceDir = opts.resourceDir
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
    //
    // GONE, and the replacement is a TYPED parameter list rather than a
    // parenthesised string. The old rule read `signature = '(src, message)'`
    // and compared the names; that is the same check the typed one does, and
    // carrying both would be two answers to "what are the parameters" -- which
    // is the failure this project keeps meeting. The typed rule additionally
    // pins the realm, because a name list cannot say which realm it belongs to
    // and sixteen exports differ between them.
    const hasTyped = meta.params !== undefined
    if (meta.signature !== undefined && hasTyped) {
      r.add('E016', `${where}.signature`,
        'is still declared alongside `params`. Two answers to "what are the parameters" is a second source nobody checks; `params` is the one.')
    }
    if (hasTyped) {
      typed.checkExports({ add: (c, w, m) => r.add(c, w, m) }, { [name]: meta }, surface, new Set())
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

  // ---- modules: one list, three places --------------------------------
  //
  // `Cis.require(name)` reads a file from inside this resource, so the set of
  // names that means anything is a security boundary rather than a
  // convenience. It is written down in THREE places -- the allow-list in
  // init.lua, the declaration in api.lua, and the `files {}` block in
  // fxmanifest.lua -- and they have to agree exactly.
  //
  // BOTH DRIFT DIRECTIONS, because each is a different bug:
  //
  //   * loadable but undeclared: nobody reading the documentation can find the
  //     module, and it is in the boot path of nobody and the call path of
  //     somebody;
  //   * declared but not loadable: a name that raises for every caller, which is
  //     the shape of a support ticket with no reproduction.
  //
  // The three lists are PARSED, not pattern-matched against prose. A check that
  // silently finds nothing looks exactly like a check that passed, so the count
  // is asserted: a parse that returns zero modules is itself a failure, which is
  // what stops a renamed table or a stray apostrophe in a comment from turning
  // this into a rule that agrees with itself.
  {
    const initSrc = fs.readFileSync(path.join(resourceDir, 'init.lua'), 'utf8')
    const fromInit = parseRequireModules(initSrc)
    if (fromInit.length === 0) {
      r.add('E043', 'REQUIRE_MODULES',
        'no modules could be read out of init.lua. The allow-list is parsed by a '
        + 'pattern, and a pattern that matches nothing is indistinguishable from a '
        + 'set that is genuinely empty -- so an empty parse fails rather than passing.')
    }

    const declaredModules = manifest.modules
    if (declaredModules !== undefined
        && (typeof declaredModules !== 'object' || declaredModules === null || Array.isArray(declaredModules))) {
      r.add('E043', 'modules', 'must be a table keyed by module name when present')
    } else if (declaredModules !== undefined && Object.keys(declaredModules).length === 0) {
      r.add('E043', 'modules', 'is present but empty, while init.lua declares a module list')
    } else {
      // Keyed by name, so the two lists are compared BY NAME. Comparing as sets
      // of paths would accept a module declared under the wrong name, and the
      // name is what a caller actually types.
      for (const [name, meta] of Object.entries(declaredModules || {})) {
        const spec = fromInit.find((x) => x.name === name)
        if (!spec) {
          r.add('E043', `modules.${name}`,
            'is declared in api.lua but is not in REQUIRE_MODULES, so it cannot load')
          continue
        }
        if (!meta || typeof meta.path !== 'string') {
          r.add('E043', `modules.${name}`, 'has no string `path`')
        } else if (meta.path !== spec.path) {
          r.add('E043', `modules.${name}`,
            `is declared in api.lua as ${meta.path} but the allow-list loads ${spec.path}`)
        }
      }
      for (const m of fromInit) {
        if (!Object.prototype.hasOwnProperty.call(declaredModules || {}, m.name)) {
          r.add('E043', `modules.${m.name}`,
            'is loadable through REQUIRE_MODULES but not declared in api.lua')
        }
      }
    }

    // And the manifest: every allow-listed path must be declared in `files {}`,
    // because a path the resource does not declare is a path LoadResourceFile
    // will not serve -- the failure the loader's own message names.
    const declaredFiles = parseManifestFiles(
      fs.readFileSync(path.join(resourceDir, 'fxmanifest.lua'), 'utf8'))
    if (declaredFiles === null) {
      r.add('E043', 'fxmanifest.lua files {}', 'no `files {` block could be read, while init.lua declares loadable modules')
    } else {
      for (const m of fromInit) {
        if (!declaredFiles.has(m.path)) {
          r.add('E043', `modules.${m.name}`,
            `is loadable by name but ${m.path} is not listed in fxmanifest.lua files {}`)
        }
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

  // ---- Stage 6: the typed contract, over the exports, the `Cis.*` proxies
  // and the classes, all from the same api.lua.
  if (resourceDir) {
    const classNames = new Set()
    typed.collectTypes(manifest.exports, classNames)
    typed.checkExports(r, manifest.exports || {}, surface, classNames)
    typed.checkFunctions(r, manifest, resourceDir, manifest.exports || {}, classNames)
    typed.checkClasses(r, manifest, classNames)
  }
  return r
}

// ------------------------------------------------------------------ fixtures

const REPO_ROOT = path.join(__dirname, '..')

// The allow-list out of init.lua's REQUIRE_MODULES.
//
// An ANCHORED pattern rather than a loose one: the block is opened by its own
// declaration and each entry must carry a quoted `path =`, so a `path =` in a
// comment elsewhere in the file cannot be mistaken for an entry. Comments are
// stripped first for the same reason.
//
// Returns [] when the block is absent or unparseable, and the CALLER treats an
// empty result as a failure. That asymmetry is the whole point: a pattern that
// matches nothing and a set that is genuinely empty look identical, and only one
// of them is a defect.
function parseRequireModules(src) {
  const clean = stripComments(src)
  const start = clean.indexOf('local REQUIRE_MODULES = {')
  if (start === -1) return []
  // Brace-matching, so a second table elsewhere in the file cannot contribute.
  let depth = 0
  let end = -1
  for (let i = clean.indexOf('{', start); i < clean.length; i += 1) {
    const ch = clean[i]
    if (ch === '{') depth += 1
    else if (ch === '}') {
      depth -= 1
      if (depth === 0) { end = i; break }
    }
  }
  if (end === -1) return []
  const body = clean.slice(start, end)
  const out = []
  const entry = /([A-Za-z_]\w*)\s*=\s*\{\s*path\s*=\s*'([^']+\.lua)'/g
  let m
  while ((m = entry.exec(body)) !== null) {
    out.push({ name: m[1], path: m[2] })
  }
  return out
}

// The paths in fxmanifest.lua's `files { }` block.
//
// Same discipline: comments stripped, the block located by its own opening, and
// brace-matched. Splitting the whole manifest on quotes or on commas would pick
// up `shared_scripts` and inline notes, and would produce a plausible wrong list
// that passes the check it was written for.
function parseManifestFiles(src) {
  const clean = stripComments(src)
  const m = /^\s*files\s*\{/m.exec(clean)
  if (!m) return null
  const start = m.index + m[0].length - 1
  let depth = 0
  let end = -1
  for (let i = start; i < clean.length; i += 1) {
    const ch = clean[i]
    if (ch === '{') depth += 1
    else if (ch === '}') {
      depth -= 1
      if (depth === 0) { end = i; break }
    }
  }
  if (end === -1) return null
  const body = clean.slice(start, end)
  const out = new Set()
  for (const q of body.matchAll(/'([^']+\.lua)'/g)) out.add(q[1])
  return out
}

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

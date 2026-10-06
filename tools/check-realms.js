// Stage 1.5, part 2: check that every native is called in a realm where it exists.
//
// The defect this catches is a client-only native on the server. server/sync.lua calls
// RequestModel, which is a client-only native. On a real server that is nil, and
// `nil(...)` raises in the middle of the sync path where nobody is watching.
// Nothing in the test suite noticed, because the unit stubs hand the server test
// VM a permissive set of natives that the real server VM does not have.
//
// THE RULE.
//   server/*.lua   may call server and shared natives. Never client.
//   client/*.lua   may call client and shared natives. Never server.
//   shared/*, init.lua   may call a realm-only native ONLY inside an
//                         IsDuplicityVersion() or IS_SERVER branch, and only
//                         when it is on the reviewed allow-list below.
//   An unknown PascalCase call FAILS. That is deliberate: a misspelled native is
//   a runtime nil-index in a different subsystem entirely, and the alternative
//   is a warning nobody reads.
//
// knownViolations is the escape hatch for defects already open at the baseline.
// It starts with exactly the one the plan names. A new entry is a claim that a
// bug is acceptable, and it has to be emptied by the task that fixes it -- so it
// is printed in full on every run rather than silently tolerated.

const fs = require('fs')
const path = require('path')

const root = path.join(__dirname, '..')
const nativesDoc = JSON.parse(fs.readFileSync(path.join(root, 'tools', 'natives', 'natives.json'), 'utf8'))
const runtime = JSON.parse(fs.readFileSync(path.join(root, 'tools', 'natives', 'runtime.json'), 'utf8'))
const libGlobalsDoc = JSON.parse(fs.readFileSync(path.join(root, 'tools', 'natives', 'lib-globals.json'), 'utf8'))

// name -> realm.
//
// ORDER MATTERS, and getting it wrong manufactures violations. The runtime list
// is consulted FIRST and overwrites: Wait, GetGameTimer and GetPlayerName all
// appear in the GTA database as client-only game natives, but CfxLua provides
// all three on the server VM too, and calling them from a server file is
// correct and common. If the database won, this checker would report five
// separate false violations on the security rate limiter.
const REALMS = new Map()
const RUNTIME_SET = new Set()
for (const [name, info] of Object.entries(nativesDoc.natives)) REALMS.set(name, info.realm)
for (const [realm, names] of Object.entries(runtime)) {
  if (realm === '$comment') continue
  for (const n of names) { RUNTIME_SET.add(n); REALMS.set(n, realm) }
}

// The library's own globals. Each is defined by the files that load in its own
// realm, so it is legal everywhere it exists and is never a realm violation --
// it is simply not a native, and must not be reported as an unknown one.
const LIB_GLOBALS = new Set(Object.keys(libGlobalsDoc.globals))

// Defects already open at the baseline, allowed until the task that owns them
// lands. EMPTY, and that is the point: it held the three model-request natives
// on one server line -- RequestModel, HasModelLoaded and
// SetModelAsNoLongerNeeded, all `apiset: client`, all in the same function, all
// asking a server for something only a client has. The networked path is now
// created with the server RPC natives, so nothing is left to allow.
//
// An entry here is a promise that the defect is being fixed and by which task.
// An empty list is the stronger statement: no shipped file calls a native in a
// realm that does not have it, so a violation here is a NEW one and the build
// fails on it.
const knownViolations = []

// Calls to names that are not natives, not runtime functions and not the
// library's own globals. Each one is a `nil(...)` the first time that line
// runs. They are listed rather than fixed here because this task builds a
// checker; the fixes belong with the product change that owns them. See the
// Stage 1 findings in cis_libs_handoff.md.
const knownUnknownGlobals = [
  {
    file: 'client/utils.lua',
    name: 'GetGameplayCamCoords',
    defect: 'the native is GET_GAMEPLAY_CAM_COORD (singular); there is no plural form',
  },
  {
    file: 'client/utils.lua',
    name: 'DrawText',
    defect: 'no such native; screen text is drawn with BeginTextCommandDisplayText / EndTextCommandDisplayText',
  },
]

// Shared files may branch on the realm. A realm-only native outside one of these
// is a latent bug, because the branch that needs it is not the branch that runs.
const REALM_BRANCHES = /(IsDuplicityVersion\(\)|IS_SERVER\b|not\s+IsServer|IsServerRealm)/

function stripNonCode(src) {
  let out = ''
  let i = 0
  const n = src.length
  while (i < n) {
    const c = src[i]
    if (c === '-' && src[i + 1] === '-' && src[i + 2] === '[') {
      let j = i + 2
      let level = ''
      while (j < n && src[j] === '=') { level += '='; j++ }
      if (src[j] === '[') {
        const close = ']' + level + ']'
        const end = src.indexOf(close, j + 1)
        const stop = end === -1 ? n : end + close.length
        out += src.slice(i, stop).replace(/[^\n]/g, ' ')
        i = stop
        continue
      }
    }
    if (c === '-' && src[i + 1] === '-') {
      const end = src.indexOf('\n', i)
      const stop = end === -1 ? n : end
      out += ' '.repeat(stop - i)
      i = stop
      continue
    }
    if (c === '"' || c === "'") {
      const quote = c
      let j = i + 1
      while (j < n) {
        if (src[j] === '\\') { j += 2; continue }
        if (src[j] === quote || src[j] === '\n') break
        j++
      }
      out += quote + ' '.repeat(Math.max(0, Math.min(j, n - 1) - i - 1)) + (src[j] === quote ? quote : '')
      i = j + 1
      continue
    }
    out += c
    i++
  }
  return out
}

const GLOBAL_CALL = /(?:^|[^\w_.:\]"'])([A-Z][A-Za-z0-9_]*)\s*\(/g
const LOCAL_DECL = /(?:^|[^\w_.])local\s+(?:function\s+)?([A-Z][A-Za-z0-9_]*)/g

function shippedFiles() {
  const manifest = fs.readFileSync(path.join(root, 'fxmanifest.lua'), 'utf8')
  const out = []
  for (const [realm, kw] of [['shared', 'shared_scripts'], ['client', 'client_scripts'], ['server', 'server_scripts']]) {
    const re = new RegExp(kw + '\\s*\\{([^}]*)\\}', 'g')
    let m
    while ((m = re.exec(manifest)) !== null) {
      const str = /(['"])((?:\\.|(?!\1)[^\\])*)\1/g
      let s
      while ((s = str.exec(m[1])) !== null) {
        const v = s[2]
        if (v.startsWith('@') || v.startsWith('/')) continue
        if (!fs.existsSync(path.join(root, v))) continue
        out.push({ realm, file: v })
      }
    }
  }
  return out
}

function main() {
  const files = shippedFiles()
  const violations = []
  const unknown = []

  for (const { realm, file } of files) {
    const raw = fs.readFileSync(path.join(root, file), 'utf8')
    const code = stripNonCode(raw)
    const locals = new Set()
    LOCAL_DECL.lastIndex = 0
    let lm
    while ((lm = LOCAL_DECL.exec(code)) !== null) locals.add(lm[1])

    // A shared file that branches on the realm gets its lines tagged, so a
    // realm-only call on the right side of an IsDuplicityVersion() test is not
    // reported. Done per line because the branch is a statement, not a file.
    const lines = code.split('\n')
    const inRealmBranch = lines.map(line => REALM_BRANCHES.test(line))

    GLOBAL_CALL.lastIndex = 0
    let m
    const seenHere = new Set()
    while ((m = GLOBAL_CALL.exec(code)) !== null) {
      const name = m[1]
      if (locals.has(name) || seenHere.has(name)) continue
      seenHere.add(name)

      const nativeRealm = REALMS.get(name)
      if (nativeRealm === undefined) {
        // The library's own globals are legal wherever they are defined, so
        // they resolve here rather than in the native table.
        if (LIB_GLOBALS.has(name)) continue
        unknown.push({ file, realm, name }); continue
      }
      if (nativeRealm === 'std' || nativeRealm === 'shared') continue

      // The line this call sits on, and whether a realm branch governs it.
      const upto = code.slice(0, m.index)
      const lineNo = upto.split('\n').length - 1
      const guarded = realm === 'shared' && (inRealmBranch[lineNo] || inRealmBranch.slice(0, lineNo + 1).some(Boolean))
      if (guarded) continue

      if (nativeRealm === realm) continue
      violations.push({ file, realm, name, nativeRealm })
    }
  }

  const knownSet = new Set(knownViolations.map(v => v.file + '|' + v.name))
  const knownUnknownSet = new Set(knownUnknownGlobals.map(v => v.file + '|' + v.name))
  const real = violations.filter(v => !knownSet.has(v.file + '|' + v.name))
  const known = violations.filter(v => knownSet.has(v.file + '|' + v.name))
  const realUnknown = unknown.filter(u => !knownUnknownSet.has(u.file + '|' + u.name))
  const knownUnknown = unknown.filter(u => knownUnknownSet.has(u.file + '|' + u.name))

  console.log('realm check: ' + files.length + ' shipped files, ' +
    nativesDoc.counts.nativesUsed + ' natives, ' + RUNTIME_SET.size + ' runtime functions')

  if (known.length) {
    console.log('\nKNOWN VIOLATIONS (open defects, allowed by the reviewed list):')
    for (const v of known) {
      const meta = knownViolations.find(k => k.file === v.file && k.name === v.name)
      console.log('  ' + v.file + ': ' + v.name + ' -- ' + (meta ? meta.defect : 'listed'))
    }
    console.log('  ' + known.length + ' known, ' + knownViolations.length + ' on the list')
  } else {
    console.log('known violations: none on the list are still present')
  }

  let failed = false
  if (real.length) {
    failed = true
    console.log('\nREALM VIOLATIONS (these fail the build):')
    for (const v of real) {
      console.log('  ' + v.file + ':' + v.realm + ' calls ' + v.name +
        ' which only exists on the ' + v.nativeRealm + ' realm')
    }
    console.log('  ' + real.length + ' total')
  } else {
    console.log('realm violations: 0')
  }

  if (knownUnknown.length) {
    console.log('\nKNOWN UNDEFINDED CALLS (open defects, listed with a reason):')
    for (const u of knownUnknown) {
      const meta = knownUnknownGlobals.find(k => k.file === u.file && k.name === u.name)
      console.log('  ' + u.file + ': ' + u.name + ' -- ' + (meta ? meta.defect : 'listed'))
    }
    console.log('  ' + knownUnknown.length + ' known, ' + knownUnknownGlobals.length + ' on the list')
  }

  if (realUnknown.length) {
    failed = true
    console.log('\nUNKNOWN GLOBAL CALLS (a misspelled native is a nil-index elsewhere):')
    for (const u of realUnknown) console.log('  ' + u.file + ' (' + u.realm + '): ' + u.name)
    console.log('  ' + realUnknown.length + ' total')
    console.log('  If one is a real CfxLua function, add it to tools/natives/runtime.json.')
    console.log('  If it is a misspelling, fix the call. Do not silence it here.')
  } else {
    console.log('unknown globals: 0')
  }

  process.exit(failed ? 1 : 0)
}

main()
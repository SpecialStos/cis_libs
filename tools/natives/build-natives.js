// Stage 1.5, part 1: build tools/natives/natives.json from the official
// CitizenFX definitions.
//
// WHY A GENERATED FILE AND NOT A LOOKUP AT CI TIME. Realm checking is a
// correctness gate: it has to fail the build when a server file calls a
// client-only native. A gate that needs the network to answer is a gate that
// is silently skipped on an offline runner and a gate that changes verdict
// when FiveM ships a new native. So the sources are downloaded once, by hand,
// and the answer this repository actually needs is committed.
//
// WHY THE LIST IS CURATED TO WHAT THE CODE CALLS. The GTA database is 6416
// natives and the CFX one is 943. Committing either whole would add two
// megabytes of machine-readable noise that goes stale the moment FiveM
// updates. What matters is the intersection: the natives cis_libs actually
// calls, each with the realm it is legal in.
//
// THE REALM RULE, AND ITS ONE EXCEPTION.
//   - A native in natives_cfx.json carries `apiset`: client, server or shared.
//     That is authoritative and it is what makes DELETE_ENTITY usable on a
//     server even though it also exists client-side.
//   - Anything only in the GTA database is client-only. The GTA set is served
//     to the client natives browser and carries no realm metadata at all.
//   - So the classification is: CFX entry -> use its apiset. GTA-only -> client.
//     A name in NEITHER database is not a native; it is either a CfxLua runtime
//     function (CreateThread, Wait, exports, vector3) or a typo, and the
//     checker treats it as an unknown call rather than guessing.

const fs = require('fs')
const path = require('path')

const DIR = __dirname
const OUT = path.join(DIR, 'natives.json')
const SRC_CFX = 'https://runtime.fivem.net/doc/natives_cfx.json'
const SRC_GTA = 'https://runtime.fivem.net/doc/natives.json'

// UPPER_SNAKE_CASE native name -> the PascalCase form CfxLua exposes.
//
// Two cases a naive split gets wrong, both of which silently drop a native
// from the index and turn a real call into an "unknown global" the next
// developer has to suppress by hand:
//   GET_VEHICLE_MOD_COLOR_1 is GetVehicleModColor_1, NOT GetVehicleModColor1.
//   _GET_NUMBER_OF_PLAYERS_IN_TEAM is _GetNumberOfPlayersInTeAm-shaped with a
//     leading underscore that the split eats.
const toLuaName = snake => {
  const body = snake.replace(/^_/, '')
  const parts = body
    .split('_')
    .map(w => (w.length === 0 ? w : w.charAt(0) + w.slice(1).toLowerCase()))
    // A trailing numeric segment keeps its separator: Color_1, not Color1.
    .map((w, i) => (/^\d+$/.test(w) && i > 0 ? '_' + w : w))
  return parts.join('')
}

// Six independent natives in this repository confirm the convention: the
// database spells them _GET_VEHICLE_NEON_LIGHTS_COLOUR, _SET_DRIFT_TYRES_ENABLED,
// _IS_VEHICLE_NEON_LIGHT_ENABLED, _GET_VEHICLE_ROOF_LIVERY,
// _SET_VEHICLE_INTERIOR_COLOR and _GET_VEHICLE_MOD_COLOR_1, and CfxLua exposes
// every one of them with the leading underscore gone. Both spellings are
// registered so either resolves and neither becomes an "unknown global" that
// somebody has to suppress by hand on the next regeneration.
//
// AND THE SPELLING DOES NOT ALWAYS MATCH. FiveM's vehicle natives are renamed
// on the way to Lua: the database says GET_VEHICLE_DASHBOARD_COLOR and CfxLua
// exposes GetVehicleDashboardColour. Registering both spellings for every
// native is cheaper than a lookup table of exceptions that has to be edited
// every time a new vehicle property is touched.
const luaNamesFor = snake => {
  const base = toLuaName(snake)
  const out = new Set([base])
  if (snake.startsWith('_')) out.add('_' + base)
  // COLOR <-> COLOUR, applied to whole words only so "ColorRamp" is untouched.
  for (const [from, to] of [['Color', 'Colour'], ['Tyre', 'Tyres'], ['Neon', 'Neon']]) {
    if (!base.includes(from)) continue
    const swapped = base.split(from).join(to)
    out.add(swapped)
    out.add(swapped.split(to).join(from))
  }
  return [...out]
}

function loadIndex() {
  const cfx = JSON.parse(fs.readFileSync(path.join(DIR, 'natives_cfx.json'), 'utf8'))
  const gta = JSON.parse(fs.readFileSync(path.join(DIR, 'natives_gta.json'), 'utf8'))
  const byLua = new Map()

  // Realm is the UNION of the evidence, not the last writer. Both mistakes here
  // are real and both were made while building this:
  //   "last writer wins" classifies DELETE_ENTITY as server-only, because CFX
  //     lists it in the server apiset and the GTA set lists it as client -- and
  //     then every client delete in the sync path reads as a realm bug.
  //   "client wins" classifies it client-only, and every server delete does.
  // A native FiveM exposes on both VMs is `shared`, whatever order the two
  // databases are read in.
  const add = (luaName, realm, source, ns) => {
    let cur = byLua.get(luaName)
    if (!cur) { cur = { evidence: new Set(), sources: [], namespaces: [] }; byLua.set(luaName, cur) }
    cur.evidence.add(realm)
    if (!cur.sources.includes(source)) cur.sources.push(source)
    if (ns && !cur.namespaces.includes(ns)) cur.namespaces.push(ns)
  }

  for (const [ns, entries] of Object.entries(gta)) {
    for (const entry of Object.values(entries)) {
      if (!entry || !entry.name) continue
      for (const lua of luaNamesFor(entry.name)) add(lua, 'client', 'gta', ns)
      // Some natives are reachable under a legacy PascalCase alias. Record the
      // alias too, so a call the linter cannot classify still resolves.
      if (Array.isArray(entry.aliases)) {
        for (const alias of entry.aliases) {
          if (typeof alias === 'string' && /^[A-Za-z][A-Za-z0-9]*$/.test(alias)) add(alias, 'client', 'gta-alias', ns)
        }
      }
    }
  }

  for (const entries of Object.values(cfx)) {
    for (const entry of Object.values(entries)) {
      if (!entry || !entry.name) continue
      const set = Array.isArray(entry.apiset) ? entry.apiset : [entry.apiset]
      const realm = set.includes('server') ? 'server' : set.includes('shared') ? 'shared' : 'client'
      for (const lua of luaNamesFor(entry.name)) add(lua, realm, 'cfx')
    }
  }

  return byLua
}

// Collapse the evidence set into the one realm a caller may use.
function realmOf(evidence) {
  if (evidence.has('shared')) return 'shared'
  const client = evidence.has('client')
  const server = evidence.has('server')
  if (client && server) return 'shared'
  if (server) return 'server'
  return 'client'
}

// Every Lua file the manifest loads, with the realm that loads it.
function shippedFiles(root) {
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

// Strip comments and strings so a call inside documentation is not a call.
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

// A PascalCase identifier that is CALLED, and is not a local and not a field.
//
// The call shape is the one that matters and the looser shapes are all noise:
// `{ DEBUG = true }` and `local CELL = 32` both look like a global name to a
// naive scan, and together they add two hundred phantom entries that then have
// to be hand-pruned on every regeneration. A native is either called or handed
// to something as a function value, and every one in this repository is called.
// `:` and `]` are excluded as well as `.` so that `exports['cis_libs']:GetZoneDebug()`
// is read as a method call on an export and not as a call to a global named
// GetZoneDebug. cis_libs calls a few of its own exports that way internally.
const GLOBAL_CALL = /(?:^|[^\w_.:\]"'])([A-Z][A-Za-z0-9_]*)\s*\(/g
const LOCAL_DECL = /(?:^|[^\w_.])local\s+([A-Z][A-Za-z0-9_]*)\s*[=,)]/g

function main() {
  const root = path.join(__dirname, '..', '..')
  const index = loadIndex()
  const files = shippedFiles(root)

  const used = new Map()
  for (const { realm, file } of files) {
    const code = stripNonCode(fs.readFileSync(path.join(root, file), 'utf8'))
    // Locals declared here are not globals even though they are spelled like
    // one. Collect them first, then subtract.
    const locals = new Set()
    LOCAL_DECL.lastIndex = 0
    let lm
    while ((lm = LOCAL_DECL.exec(code)) !== null) locals.add(lm[1])

    GLOBAL_CALL.lastIndex = 0
    let m
    while ((m = GLOBAL_CALL.exec(code)) !== null) {
      const name = m[1]
      if (locals.has(name)) continue
      if (!used.has(name)) used.set(name, { realms: new Set(), files: new Set() })
      used.get(name).realms.add(realm)
      used.get(name).files.add(file)
    }
  }

  const natives = {}
  const unknown = []
  for (const name of [...used.keys()].sort()) {
    const hit = index.get(name)
    if (!hit) { unknown.push(name); continue }
    natives[name] = {
      realm: realmOf(hit.evidence),
      evidence: [...hit.evidence].sort(),
      sources: hit.sources,
      namespaces: hit.namespaces,
      usedIn: [...used.get(name).realms].sort(),
      files: [...used.get(name).files].sort(),
    }
  }

  const doc = {
    $comment: 'Generated by tools/natives/build-natives.js. Do not hand-edit. Realm is the CitizenFX `apiset` when the native is a CFX native, and `client` when the native exists only in the GTA database, which is client-only. The raw sources are natives_cfx.json and natives_gta.json in this directory.',
    sources: { cfx: SRC_CFX, gta: SRC_GTA },
    counts: {
      shippedFiles: files.length,
      nativesUsed: Object.keys(natives).length,
      byRealm: {
        client: Object.values(natives).filter(n => n.realm === 'client').length,
        server: Object.values(natives).filter(n => n.realm === 'server').length,
        shared: Object.values(natives).filter(n => n.realm === 'shared').length,
      },
      unresolvedPascalCaseGlobals: unknown.length,
    },
    natives,
    unresolvedGlobals: unknown.sort(),
  }

  fs.writeFileSync(OUT, JSON.stringify(doc, null, 2) + '\n', 'utf8')
  console.log('shipped files:', files.length)
  console.log('natives classified:', Object.keys(natives).length, JSON.stringify(doc.counts.byRealm))
  console.log('unresolved PascalCase globals:', unknown.length)
  console.log(unknown.join(', '))
  console.log('written: tools/natives/natives.json')
}

main()
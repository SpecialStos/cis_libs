// Stage 0.4. The consumer inventory.
//
// cis_libs is a library, so the only thing that matters about its public surface
// is what OTHER resources actually call. A name nobody uses can be deprecated
// freely; a name one sibling uses is a promise that needs a test behind it.
// This tool turns "the siblings" from an assumption into a fixture.
//
// The result is test/fixtures/consumers.json, and task 1.6 turns that fixture
// into a compatibility test: rename a used name and `npm test` goes red.
//
// THREE THINGS THIS FILE GETS RIGHT THAT A GREP DOES NOT:
//
// 1. COMMENTS AND STRINGS ARE STRIPPED. The sibling manifests are heavily
//    commented and they quote cis_libs calls in those comments. A grep counts
//    the documentation as usage, so every number is inflated and the "top
//    calls" list is really "most-documented calls".
//
// 2. THE REALM COMES FROM THE MANIFEST, NOT THE FILENAME. A file in `shared/`
//    is not necessarily loaded as shared: a resource may load part of its
//    shared directory from a client_script entry. Only the section that loads a
//    file decides which VM it runs in, and the compatibility test needs the real
//    answer to check that an export exists on that realm.
//
// 3. ONLY FILES THE MANIFEST LOADS ARE SCANNED. A repo holds scripts that are
//    dead, commented out or loaded conditionally. Counting them would invent
//    callers that do not exist and freeze names nobody can reach.

const fs = require('fs')
const path = require('path')

const SCAN_ROOT = process.env.CIS_SCAN_ROOT || 'C:\\Users\\CB\\Desktop\\ZCode'
const OUT = path.join(__dirname, '..', 'test', 'fixtures', 'consumers.json')
const SELF = 'cis_libs'

// Sentinel used while rewriting a manifest glob into a regular expression.
// `**/` and `**` have to be replaced before the single `*` pass, so they are
// parked under names that cannot occur in a path.
const PARK_GLOBALSTAR_SLASH = '@@cis_globstar_slash@@'
const PARK_GLOBALSTAR = '@@cis_globstar@@'

// ---------------------------------------------------------------- Lua lexing

// Strip comments and string bodies so a match can only come from real code.
// Strings collapse to quotes around spaces and comments collapse to spaces, so
// line numbers survive and nothing downstream depends on columns.
function stripNonCode(src) {
  let out = ''
  let i = 0
  const n = src.length
  while (i < n) {
    const c = src[i]
    // long comment  --[==[ ... ]==]   (also matches the bare [==[ ... ]==] form)
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
    // line comment
    if (c === '-' && src[i + 1] === '-') {
      const end = src.indexOf('\n', i)
      const stop = end === -1 ? n : end
      out += ' '.repeat(stop - i)
      i = stop
      continue
    }
    // string literal
    if (c === '"' || c === "'") {
      const quote = c
      let j = i + 1
      while (j < n) {
        if (src[j] === '\\') { j += 2; continue }
        if (src[j] === quote || src[j] === '\n') break
        j++
      }
      const closed = src[j] === quote
      const bodyEnd = Math.min(j, n)
      out += quote + ' '.repeat(Math.max(0, bodyEnd - i - 1)) + (closed ? quote : '')
      i = bodyEnd + (closed ? 1 : 0)
      continue
    }
    out += c
    i++
  }
  return out
}

// Same pass, but strings are PRESERVED. A manifest is almost entirely strings:
// the script entries and the dependency names ARE string bodies. Blanking them
// yields a manifest whose every entry is whitespace, which silently matches no
// file and reports no dependency at all. Comments are still removed, because a
// commented-out `dependency 'cis_libs'` is not a dependency.
function stripComments(src) {
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
      out += src.slice(i, j + 1)
      i = j + 1
      continue
    }
    out += c
    i++
  }
  return out
}

// ------------------------------------------------------------- manifest read

// Every quoted string inside a balanced `keyword { ... }` block.
function blockStrings(src, keyword) {
  const found = []
  const re = new RegExp('(^|[\\s,{])' + keyword + '\\s*\\{', 'g')
  let m
  while ((m = re.exec(src)) !== null) {
    const open = src.indexOf('{', m.index)
    let depth = 0
    let i = open
    for (; i < src.length; i++) {
      if (src[i] === '{') depth++
      else if (src[i] === '}') { depth--; if (depth === 0) break }
    }
    const body = src.slice(open, i)
    const str = /(['"])((?:\\.|(?!\1)[^\\])*)\1/g
    let s
    while ((s = str.exec(body)) !== null) found.push(s[2])
    re.lastIndex = i
  }
  return found
}

// Every quoted string after a `keyword 'x'` directive.
function directiveStrings(src, keyword) {
  const found = []
  const re = new RegExp('(^|[\\s,{])' + keyword + '\\s+([\'"])((?:\\\\.|(?!\\2)[^\\\\])*)\\2', 'g')
  let m
  while ((m = re.exec(src)) !== null) found.push(m[3])
  return found
}

function parseManifest(file) {
  const raw = fs.readFileSync(file, 'utf8')
  // Comments go, strings stay: the entries this reads are string bodies.
  const code = stripComments(raw)
  const scripts = {}
  const push = (realm, v) => { (scripts[realm] = scripts[realm] || []).push(v) }
  for (const v of [...blockStrings(code, 'shared_scripts'), ...directiveStrings(code, 'shared_script')]) push('shared', v)
  for (const v of [...blockStrings(code, 'client_scripts'), ...directiveStrings(code, 'client_script')]) push('client', v)
  for (const v of [...blockStrings(code, 'server_scripts'), ...directiveStrings(code, 'server_script')]) push('server', v)
  const dependencies = [
    ...blockStrings(code, 'dependencies'),
    ...directiveStrings(code, 'dependency'),
  ]
  return { raw, scripts, dependencies }
}

// -------------------------------------------------------------- file matching

function globToRe(pat) {
  const esc = pat.replace(/[.+^${}()|[\]\\]/g, '\\$&')
  const body = esc
    .replace(/\*\*\//g, PARK_GLOBALSTAR_SLASH)
    .replace(/\*\*/g, PARK_GLOBALSTAR)
    .replace(/\*/g, '[^/]*')
    .replace(/\?/g, '[^/]')
    .split(PARK_GLOBALSTAR_SLASH).join('(?:.*/)?')
    .split(PARK_GLOBALSTAR).join('.*')
  return new RegExp('^' + body + '$')
}

// A manifest entry may be '@cis_libs/init.lua' (another resource), an absolute
// path, a plain relative path or a glob. Only relative paths are files of this
// resource, and only those can be evidence of a realm.
function entriesForRealm(manifest, realm) {
  const out = []
  for (const e of manifest.scripts[realm] || []) {
    const v = String(e).trim()
    if (!v || v.startsWith('@') || v.startsWith('/') || v.startsWith('\\')) continue
    out.push(v)
  }
  return out
}

// `root` and `dir` are separate on purpose: paths must be relative to the
// resource root, not to the directory currently being read, or every entry
// collapses to its basename and matches no manifest pattern.
function walkLua(root, dir, acc = []) {
  let ents
  try { ents = fs.readdirSync(dir, { withFileTypes: true }) } catch { return acc }
  for (const e of ents) {
    if (e.name === 'node_modules' || e.name === '.git') continue
    const full = path.join(dir, e.name)
    if (e.isDirectory()) walkLua(root, full, acc)
    else if (e.isFile() && e.name.endsWith('.lua')) acc.push(path.relative(root, full))
  }
  return acc
}

// relative path (posix) -> realm. The first section that claims a file wins,
// because FiveM loads in manifest order and a file listed twice runs in the
// earlier realm.
function buildRealmIndex(resDir, manifest) {
  const map = new Map()
  const all = walkLua(resDir, resDir)
  for (const realm of ['shared', 'client', 'server']) {
    for (const entry of entriesForRealm(manifest, realm)) {
      let re
      try { re = globToRe(entry.replace(/\\/g, '/')) } catch { continue }
      for (const rel of all) {
        const norm = rel.replace(/\\/g, '/')
        if (!map.has(norm) && re.test(norm)) map.set(norm, realm)
      }
    }
  }
  return map
}

function findManifests(root) {
  const out = []
  const walk = d => {
    let ents
    try { ents = fs.readdirSync(d, { withFileTypes: true }) } catch { return }
    for (const e of ents) {
      if (e.name === 'node_modules' || e.name === '.git') continue
      const full = path.join(d, e.name)
      if (e.isDirectory()) walk(full)
      else if (e.isFile() && e.name === 'fxmanifest.lua') out.push(full)
    }
  }
  walk(root)
  return out.sort()
}

// ------------------------------------------------------------------ the scan

const CIS_CALL = /(?:^|[^\w_.:])Cis\.([\w_]+)\.([\w_]+)/g
const EXPORT_DOT = /exports\.cis_libs\.([\w_]+)/g
const EXPORT_COLON = /exports\.cis_libs:([\w_]+)/g
const EXPORT_BRACKET = /exports\[['"`]cis_libs['"`]\]\[['"]?([\w_]+)['"`]?\]/g
// The form the siblings actually use: exports['cis_libs']:SetConfig(...)
const EXPORT_BRACKET_COLON = /exports\[['"`]cis_libs['"`]\]:([\w_]+)/g
// The bare resource:export sugar, cis_libs:SetConfig(...)
const RESOURCE_COLON = /(?:^|[^\w_.:'\"])cis_libs:([A-Z]\w*)\s*\(/g

function tally(list, key, count = 1) {
  const cur = list.find(x => x.key === key)
  if (cur) cur.count += count
  else list.push({ key, count })
}

function scanResource(resDir, manifest, manifestRel) {
  const realmIndex = buildRealmIndex(resDir, manifest)
  const cisCalls = { client: [], server: [], shared: [] }
  const exportCalls = { client: [], server: [], shared: [] }
  const files = []

  for (const [rel, realm] of realmIndex) {
    let raw
    try { raw = fs.readFileSync(path.join(resDir, rel), 'utf8') } catch { continue }
    // Two views of the same file, because the two kinds of call need opposite
    // treatment. A `Cis.ns.fn` name lives in code, so the pass that blanks
    // strings is what counts it. An export name is INSIDE a string literal
    // (`exports['cis_libs']:SetConfig`), so blanking strings would erase the
    // very token being looked for; that pass keeps strings and drops comments.
    const code = stripNonCode(raw)
    const codeWithStrings = stripComments(raw)
    let hits = 0
    let m
    CIS_CALL.lastIndex = 0
    while ((m = CIS_CALL.exec(code)) !== null) { tally(cisCalls[realm], m[1] + '.' + m[2]); hits++ }
    EXPORT_DOT.lastIndex = 0
    while ((m = EXPORT_DOT.exec(codeWithStrings)) !== null) { tally(exportCalls[realm], m[1]); hits++ }
    EXPORT_COLON.lastIndex = 0
    while ((m = EXPORT_COLON.exec(codeWithStrings)) !== null) { tally(exportCalls[realm], m[1]); hits++ }
    EXPORT_BRACKET.lastIndex = 0
    while ((m = EXPORT_BRACKET.exec(codeWithStrings)) !== null) { tally(exportCalls[realm], m[1]); hits++ }
    EXPORT_BRACKET_COLON.lastIndex = 0
    while ((m = EXPORT_BRACKET_COLON.exec(codeWithStrings)) !== null) { tally(exportCalls[realm], m[1]); hits++ }
    RESOURCE_COLON.lastIndex = 0
    while ((m = RESOURCE_COLON.exec(codeWithStrings)) !== null) { tally(exportCalls[realm], m[1]); hits++ }
    if (hits) files.push({ file: rel, realm, hits })
  }

  for (const set of [cisCalls, exportCalls]) {
    for (const k of Object.keys(set)) set[k].sort((a, b) => b.count - a.count || a.key.localeCompare(b.key))
  }

  const sizeOf = o => Object.keys(o).reduce((n, k) => n + o[k].length, 0)
  const hitsOf = o => ['client', 'server', 'shared'].reduce((n, k) => n + o[k].reduce((s, x) => s + x.count, 0), 0)

  return {
    name: path.basename(resDir),
    manifest: manifestRel.split(path.sep).join('/'),
    includesInit: /@cis_libs\//.test(manifest.raw),
    declaresDependency: manifest.dependencies.some(d => String(d).trim() === SELF),
    declaredDependencies: manifest.dependencies.map(d => String(d).trim()),
    cisCalls,
    exportCalls,
    totals: {
      cisCallNames: sizeOf(cisCalls),
      exportCallNames: sizeOf(exportCalls),
      cisCalls: hitsOf(cisCalls),
      exportCalls: hitsOf(exportCalls),
      scannedFiles: files.length,
    },
    files: files.sort((a, b) => a.file.localeCompare(b.file)),
  }
}

function main() {
  if (!fs.existsSync(SCAN_ROOT)) {
    console.error('scan root does not exist: ' + SCAN_ROOT)
    process.exit(2)
  }
  const manifests = findManifests(SCAN_ROOT)
  const resources = []
  for (const m of manifests) {
    const resDir = path.dirname(m)
    if (path.basename(resDir) === SELF) continue
    const manifest = parseManifest(m)
    const rel = path.relative(SCAN_ROOT, m)
    if (!/@cis_libs\//.test(manifest.raw) && !manifest.dependencies.some(d => String(d).trim() === SELF)) continue
    resources.push(scanResource(resDir, manifest, rel))
  }
  resources.sort((a, b) => a.name.localeCompare(b.name))

  const sumCis = []
  const sumExp = []
  const byRealm = { client: [], server: [], shared: [] }
  for (const r of resources) {
    for (const realm of ['client', 'server', 'shared']) {
      for (const c of r.cisCalls[realm]) { tally(sumCis, c.key, c.count); tally(byRealm[realm], c.key, c.count) }
      for (const c of r.exportCalls[realm]) tally(sumExp, c.key, c.count)
    }
  }
  const top = o => Object.values(o).sort((a, b) => b.count - a.count || a.key.localeCompare(b.key))
  const names = f => resources.filter(f).map(r => r.name).sort()

  const doc = {
    $comment: 'Generated by tools/scan-consumers.js. Comments and strings are stripped before matching, the realm comes from the manifest section that loads the file, and only files the manifest loads are scanned. Regenerate with `npm run scan:consumers`.',
    scannedRoot: SCAN_ROOT,
    resourceCount: resources.length,
    resources,
    summary: {
      cisCalls: top(sumCis),
      exportCalls: top(sumExp),
      cisCallsByRealm: { client: top(byRealm.client), server: top(byRealm.server), shared: top(byRealm.shared) },
      resourcesIncludingInit: names(r => r.includesInit),
      resourcesDeclaringDependency: names(r => r.declaresDependency),
      resourcesWithOnlyInclude: names(r => r.includesInit && !r.declaresDependency),
      resourcesWithOnlyDependency: names(r => !r.includesInit && r.declaresDependency),
    },
  }

  fs.mkdirSync(path.dirname(OUT), { recursive: true })
  fs.writeFileSync(OUT, JSON.stringify(doc, null, 2) + '\n', 'utf8')

  console.log('scan root: ' + SCAN_ROOT)
  console.log('manifests scanned: ' + manifests.length + ', consumers: ' + resources.length)
  console.log('include @cis_libs/: ' + doc.summary.resourcesIncludingInit.length +
              ', declare dependency: ' + doc.summary.resourcesDeclaringDependency.length)
  console.log('distinct Cis.<ns>.<fn>: ' + doc.summary.cisCalls.length +
              ', distinct exports: ' + doc.summary.exportCalls.length)
  console.log('top Cis calls:')
  for (const c of doc.summary.cisCalls.slice(0, 22)) console.log('  ' + String(c.count).padStart(4) + '  Cis.' + c.key)
  console.log('top exports:')
  for (const c of doc.summary.exportCalls.slice(0, 15)) console.log('  ' + String(c.count).padStart(4) + '  exports.cis_libs:' + c.key)
  console.log('written: test/fixtures/consumers.json')
}

main()
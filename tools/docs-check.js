// Stage 10.1: every doc claim that can be checked, is checked.
//
//   node tools/docs-check.js
//
// Relative links and anchors resolve. Every `npm run X` named in a doc exists.
// Every Cis.* / export named in a doc exists in api.lua, and every public
// api.lua entry is named in DOCUMENTATION.md. Versions match. Generated
// blocks are current (gen-types --check).

const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')
const fengari = require('fengari')
const lua = fengari.lua
const lauxlib = fengari.lauxlib
const lualib = fengari.lualib
const toLua = fengari.to_luastring

const root = path.join(__dirname, '..')
// Documents held to every rule: links, `npm run` names, Cis.* names, exports.
const DOC_FILES = [
  'README.md',
  'DOCUMENTATION.md',
  'CHANGELOG.md',
  'LICENSE.md',
  'test/LIVE.md',
  'test/live/RUNBOOK.md',
  'test/live/UNRUN.md',
]

// Every other markdown file in the repo (docs/archive, docs/handoff, ...) is
// held to the link and anchor rules only. An archived document describes an old
// API and a handoff note describes a moment, so neither is checked against
// today's api.lua, but a link in them that goes nowhere is still a broken link.
const SKIP_DIRS = new Set(['node_modules', '.git', '.claude', '.zcode', 'dist', 'cache', 'reports'])
function linkOnlyFiles(dir = root, rel = '', out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP_DIRS.has(e.name)) continue
    const r = rel ? rel + '/' + e.name : e.name
    if (e.isDirectory()) linkOnlyFiles(path.join(dir, e.name), r, out)
    else if (e.name.endsWith('.md') && !DOC_FILES.includes(r)) out.push(r)
  }
  return out.sort()
}

// The cis_libs exports a document calls, in both spellings the docs use:
// exports['cis_libs']:Name(...) and exports.cis_libs:Name(...). Other
// resources' exports are not api.lua's business.
function exportNames(md) {
  const names = new Set()
  const re = /\bexports(?:\[\s*(['"])cis_libs\1\s*\]|\.cis_libs):([A-Za-z_][A-Za-z0-9_]*)/g
  let m
  while ((m = re.exec(md))) names.add(m[2])
  return names
}

function loadApi() {
  const L = lauxlib.luaL_newstate()
  lualib.luaL_openlibs(L)
  lua.lua_pushstring(L, toLua('api.lua'))
  lua.lua_setglobal(L, toLua('CIS_DUMP_TARGET'))
  const src = fs.readFileSync(path.join(root, 'tools', 'lua-dump.lua'), 'utf8')
  if (lauxlib.luaL_loadstring(L, toLua(src)) !== lua.LUA_OK ||
      lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
    throw new Error('lua-dump.lua: ' + lua.lua_tojsstring(L, -1))
  }
  return JSON.parse(lua.lua_tojsstring(L, -1))
}

// GitHub's rule: drop punctuation, then turn EACH space into a hyphen. A dash
// removed from the middle of a heading leaves two spaces and so two hyphens, and
// an underscore is kept.
function slug(heading) {
  return heading
    .replace(/^#+\s+/, '')
    .toLowerCase()
    .replace(/[`*]/g, '')
    .replace(/[^\w\s-]/g, '')
    .trim()
    .replace(/\s/g, '-')
}

function headings(md) {
  const set = new Set()
  for (const line of md.split(/\r?\n/)) {
    if (/^#{1,6}\s+/.test(line)) set.add(slug(line))
  }
  return set
}

function pkg() {
  return JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'))
}

function fxVersion() {
  const m = fs.readFileSync(path.join(root, 'fxmanifest.lua'), 'utf8').match(/version\s+"([^"]+)"/)
  return m && m[1]
}

function fail(failures, msg) {
  failures.push(msg)
}

function main() {
  const failures = []
  const api = loadApi()
  const pack = pkg()
  const exports = new Set(Object.keys(api.exports || {}))
  const functions = new Set(Object.keys(api.functions || {}))
  const events = new Set(Object.keys(api.events || {}))
  const scripts = new Set(Object.keys(pack.scripts || {}))

  if (pack.version !== api.version) {
    fail(failures, `package.json version ${pack.version} != api.lua ${api.version}`)
  }
  const fxv = fxVersion()
  if (fxv !== pack.version) {
    fail(failures, `fxmanifest.lua version ${fxv} != package.json ${pack.version}`)
  }
  if (api.api !== 1) {
    fail(failures, `api.lua contract major is ${api.api}, expected 1`)
  }

  const knownCis = new Set(functions)
  const blob = JSON.stringify(api)
  for (const m of blob.matchAll(/Cis\.[A-Za-z_][A-Za-z0-9_.]*/g)) knownCis.add(m[0])
  const namedInDocs = new Set()
  const linkOnly = linkOnlyFiles()
  for (const rel of [...DOC_FILES, ...linkOnly]) {
    const abs = path.join(root, rel)
    if (!fs.existsSync(abs)) {
      fail(failures, `missing doc ${rel}`)
      continue
    }
    const md = fs.readFileSync(abs, 'utf8')
    const hs = headings(md)

    const linkRe = /\[[^\]]*\]\(([^)]+)\)/g
    let m
    while ((m = linkRe.exec(md))) {
      let href = m[1].trim()
      if (/^(https?:|mailto:|discord:)/i.test(href)) continue
      if (/[,'"]/.test(href) || /\s/.test(href) || /^\.+$/.test(href)) continue
      if (href.startsWith('#')) {
        const a = href.slice(1).toLowerCase()
        if (a && !hs.has(a)) fail(failures, `${rel}: missing anchor ${href}`)
        continue
      }
      const [filePart, hash] = href.split('#')
      const target = path.normalize(path.join(path.dirname(abs), filePart))
      if (!fs.existsSync(target)) {
        fail(failures, `${rel}: broken link ${href}`)
      } else if (hash) {
        const th = headings(fs.readFileSync(target, 'utf8'))
        if (!th.has(hash.toLowerCase())) fail(failures, `${rel}: missing anchor ${href}`)
      }
    }

    if (linkOnly.includes(rel)) continue

    const runRe = /npm run ([a-zA-Z0-9:_-]+)/g
    while ((m = runRe.exec(md))) {
      if (!scripts.has(m[1]) && m[1] !== 'test') {
        fail(failures, `${rel}: npm run ${m[1]} is not a package.json script`)
      }
    }
    if (/\bnpm test\b/.test(md) && !scripts.has('test')) {
      fail(failures, `${rel}: npm test is not a package.json script`)
    }

    const cisRe = /\bCis\.[A-Za-z_][A-Za-z0-9_.]*/g
    while ((m = cisRe.exec(md))) namedInDocs.add(m[0].replace(/\.+$/, ''))

    for (const name of exportNames(md)) namedInDocs.add('export:' + name)
  }

  for (const name of namedInDocs) {
    if (name.startsWith('export:')) {
      const exp = name.slice(7)
      if (!exports.has(exp)) fail(failures, `doc names export ${exp} which is not in api.lua`)
      continue
    }
    let known = knownCis.has(name)
    if (!known) {
      for (const f of knownCis) {
        if (f.startsWith(name + '.') || name.startsWith(f + '.')) { known = true; break }
      }
    }
    if (!known) {
      fail(failures, `doc names ${name} which is not in api.lua`)
    }
  }

  const docBody = fs.readFileSync(path.join(root, 'DOCUMENTATION.md'), 'utf8')
  for (const name of [...exports].sort()) {
    if (!docBody.includes('`' + name + '`')) {
      fail(failures, `api.lua export ${name} is not named in DOCUMENTATION.md`)
    }
  }
  for (const name of [...functions].sort()) {
    if (!docBody.includes('`' + name + '`') && !docBody.includes(name)) {
      fail(failures, `api.lua function ${name} is not named in DOCUMENTATION.md`)
    }
  }
  for (const name of [...events].sort()) {
    if (!docBody.includes('`' + name + '`')) {
      fail(failures, `api.lua event ${name} is not named in DOCUMENTATION.md`)
    }
  }

  const gen = spawnSync(process.execPath, [path.join('tools', 'gen-types.js'), '--check'], {
    cwd: root,
    encoding: 'utf8',
  })
  if (gen.status !== 0) {
    fail(failures, 'generated blocks stale: ' + (gen.stderr || gen.stdout || '').trim())
  }

  if (failures.length) {
    console.error(`docs-check: ${failures.length} failure(s)`)
    for (const f of failures) console.error('  ' + f)
    process.exit(1)
  }
  console.log(`docs-check: ${DOC_FILES.length + linkOnly.length} files (${linkOnly.length} link-only), versions ${pack.version}, api=${api.api}`)
}

if (require.main === module) main()

module.exports = { DOC_FILES, linkOnlyFiles, exportNames }

// Map who references each of the 15 algo/util globals, and from where.
//
// Stage 5.1 converts each of those modules from "assign a global, return
// nothing" to "build a local table, return it, and set the legacy global only
// when it was NOT loaded by Cis.require". Before that change is worth doing,
// the question is what the change actually costs: how many references each
// module carries, and how many of them cross a module boundary.
//
// A cross-module reference is the expensive kind. `local M = {}` makes the
// module's OWN references free, but a reference from a DIFFERENT file to
// `CisLRU` was resolving through a global that a sandboxed load would no
// longer set -- so every one of those has to become an explicit dependency.
//
// The output is a table, not a decision. The point is to know the size before
// starting, and to be able to tell afterwards whether the number moved.

const fs = require('fs')
const path = require('path')

const root = path.join(__dirname, '..')
const MODULE_DIRS = ['shared/algo', 'shared/util']

const modules = []
for (const dir of MODULE_DIRS) {
  const full = path.join(root, dir)
  for (const name of fs.readdirSync(full).sort()) {
    if (!name.endsWith('.lua')) continue
    const rel = `${dir}/${name}`
    const src = fs.readFileSync(path.join(root, rel), 'utf8')
    // The legacy global is declared in the module TAIL now, not at the top:
// 5.1 turned `CisXxx = {}` into `local M = {}` and moved the assignment into
// `if ... ~= 'cis_require' then CisXxx = M end`. Matching `^CisXxx =` therefore
// finds nothing after the conversion and every module reported as having no
// global -- which is the tool answering a question about the wrong line.
const def = src.match(/^\s{4}(Cis[A-Za-z_]+)\s*=\s*M\s*$/m)
    modules.push({ rel, global: def ? def[1] : null, src })
  }
}

const byGlobal = new Map(modules.filter(m => m.global).map(m => [m.global, m]))
// The set of module FILES, keyed by path. The first version classified with
// `byGlobal.has(f.rel)`, which compares a filename against a list of global
// NAMES -- so it always said "not a module" and put every cross-module
// reference under "other". A misclassification that hides the exact number
// this tool exists to produce.
const modulePaths = new Set(modules.map(m => m.rel))

// Every .lua file in the resource, module files included, so cross-module
// references are counted rather than discovered later.
const all = []
function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === 'node_modules' || e.name === '.git') continue
    const p = path.join(dir, e.name)
    // Recurse at EVERY depth, not just the first. The first version of this
    // walked one level, which silently dropped `shared/algo/*` and reported
    // every module as having zero references -- including itself.
    if (e.isDirectory()) { walk(p); continue }
    if (!e.name.endsWith('.lua')) continue
    const rel = path.relative(root, p).replace(/\\/g, '/')
    if (rel.startsWith('test/')) continue
    all.push({ rel, src: codeOnly(fs.readFileSync(p, 'utf8')) })
  }
}
walk(root)


// STRIP COMMENTS AND STRINGS FIRST, or this reports documentation as
// dependencies.
//
// The first version counted bare matches over the raw source and reported 14
// cross-module references across 6 edges. Every one of them was a mention
// inside a COMMENT -- '--- Same rule and the same reasoning as CisLRU.each',
// '--- CisSparse.count, CisLRU.count, ...' -- which is cross-referencing prose,
// not a call. A dependency graph built from that is fiction, and it produced a
// deps declaration the modules do not need and a test that claimed to exercise
// them.
function codeOnly(src) {
  let out = ''
  let i = 0
  const n = src.length
  while (i < n) {
    const two = src.slice(i, i + 2)
    if (two === '--') {
      const isLong = src.slice(i, i + 4) === '--[['
      const end = isLong ? src.indexOf(']]', i + 4) : src.indexOf('\n', i)
      i = end === -1 ? n : (isLong ? end + 2 : end)
      continue
    }
    if (two === '[[') {
      const end = src.indexOf(']]', i + 2)
      i = end === -1 ? n : end + 2
      continue
    }
    if (src[i] === '\"' || src[i] === "'") {
      const q = src[i]
      let j = i + 1
      while (j < n) {
        if (src[j] === '\\') { j += 2; continue }
        if (src[j] === q) { j += 1; break }
        if (src[j] === '\n') break
        j += 1
      }
      i = j
      continue
    }
    out += src[i]
    i += 1
  }
  return out
}

const rows = []
for (const m of modules) {
  m.src = codeOnly(m.src)
  if (!m.global) { rows.push({ rel: m.rel, global: '(none)', self: 0, cross: [], other: [] }); continue }
  const re = new RegExp(`\\b${m.global}\\b`, 'g')
  const cross = []
  const other = []
  let self = 0
  for (const f of all) {
    const hits = (f.src.match(re) || []).length
    if (!hits) continue
    if (f.rel === m.rel) { self = hits; continue }
    if (modulePaths.has(f.rel)) cross.push(`${f.rel}(${hits})`)
    else other.push(`${f.rel}(${hits})`)
  }
  rows.push({ rel: m.rel, global: m.global, self, cross, other })
}

console.log('module'.padEnd(24), 'global'.padEnd(13), 'self', ' cross', ' other')
let crossTotal = 0
let otherTotal = 0
for (const r of rows) {
  const c = r.cross.reduce((n, s) => n + Number(/\((\d+)\)$/.exec(s)[1]), 0)
  const o = r.other.reduce((n, s) => n + Number(/\((\d+)\)$/.exec(s)[1]), 0)
  crossTotal += c
  otherTotal += o
  console.log(r.rel.padEnd(24), String(r.global).padEnd(13),
    String(r.self).padStart(4), String(c).padStart(6), String(o).padStart(6),
    o ? '  ' + r.other.join(' ') : '')
}
console.log(`\ncross-module references: ${crossTotal}   references from non-module files: ${otherTotal}`)
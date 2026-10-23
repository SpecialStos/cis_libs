// Per-suite assertion counts, shared between the two Lua runners.
//
// test/run.js (fengari) saves its counts; tools/run-lua54.js compares the real
// Lua 5.4 counts with them. An assertion that runs under one interpreter only
// switches off silently otherwise: both runs stay green with one fewer check.
//
// The saved counts are keyed by a hash of every Lua source, so counts from an
// older tree are never compared with a newer one.

const crypto = require('crypto')
const fs = require('fs')
const os = require('os')
const path = require('path')

const root = path.join(__dirname, '..')

// lua54 minus fengari, per suite, where the difference is deliberate.
const KNOWN_DELTA = {
  // Two weak-table collection checks: fengari has no weak tables.
  'test/modules.lua': 2,
}

function luaFiles(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === 'node_modules' || e.name.startsWith('.')) continue
    const p = path.join(dir, e.name)
    if (e.isDirectory()) luaFiles(p, out)
    else if (e.name.endsWith('.lua')) out.push(p)
  }
  return out
}

function sourceHash() {
  const h = crypto.createHash('sha256')
  for (const f of luaFiles(root, []).sort()) {
    h.update(path.relative(root, f).replace(/\\/g, '/'))
    h.update('\0')
    h.update(fs.readFileSync(f))
    h.update('\0')
  }
  return h.digest('hex')
}

function countsPath() {
  const id = crypto.createHash('sha256').update(root).digest('hex').slice(0, 12)
  return path.join(os.tmpdir(), `cis_libs-test-counts-${id}.json`)
}

function save(counts) {
  try {
    fs.writeFileSync(countsPath(), JSON.stringify({ hash: sourceHash(), counts }))
  } catch (e) {
    console.error(`test-counts: could not save the fengari counts (${e.message})`)
  }
}

// The fengari counts for THIS tree, or null when there are none.
function load() {
  let saved
  try {
    saved = JSON.parse(fs.readFileSync(countsPath(), 'utf8'))
  } catch {
    return null
  }
  return saved && saved.hash === sourceHash() ? saved.counts : null
}

// Lines describing every suite whose counts differ by more than KNOWN_DELTA.
function compare(fengari, lua54) {
  const bad = []
  for (const file of new Set([...Object.keys(fengari), ...Object.keys(lua54)])) {
    const want = (fengari[file] ?? 0) + (KNOWN_DELTA[file] ?? 0)
    const got = lua54[file] ?? 0
    if (got !== want) {
      bad.push(`${file}: lua54 ran ${got}, fengari ${fengari[file] ?? 0}` +
        (KNOWN_DELTA[file] ? ` (+${KNOWN_DELTA[file]} expected)` : ''))
    }
  }
  return bad
}

module.exports = { KNOWN_DELTA, sourceHash, save, load, compare }

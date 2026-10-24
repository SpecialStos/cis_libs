'use strict'

// Self-tests for the repository's own tools: lint.js, syntax-check.js,
// docs-check.js and mutate.js.
//
// A tool that has only ever been seen to pass has not been tested. Each case
// here pins a defect the tool once had, so the tool cannot quietly go back to it:
//
//   lint.js          left a cis-luacheck-* copy of the tree in the temp folder on
//                    every run, because process.exit sat inside the try
//   syntax-check.js  skipped a WHOLE file at its first backtick, so a real syntax
//                    error after it in client/cache.lua was never found
//   docs-check.js    read five files and missed the exports.cis_libs:Name form
//   mutate.js        counted a spawn error or a crash as a killed mutation, and
//                    accepted two rows with the same id
//
//   node test/tools-selftest.js
//
// Exit 0 clean, 1 on failure.

const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawnSync } = require('child_process')

const root = path.join(__dirname, '..')
let pass = 0
let fail = 0

function check(name, fn) {
  try {
    fn()
    pass += 1
    process.stdout.write(`  ok   ${name}\n`)
  } catch (e) {
    fail += 1
    process.stdout.write(`  FAIL ${name}\n       ${e.message}\n`)
  }
}

// ---------------------------------------------------------------- lint.js
// Run it against a temp folder of its own and count what it leaves behind. Both
// exits that used to skip the cleanup are taken: luacheck present but failing,
// and luacheck not found at all.
function lintLeftovers(luacheck) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'cis-tools-selftest-'))
  try {
    const res = spawnSync(process.execPath, [path.join(root, 'tools', 'lint.js')], {
      encoding: 'utf8',
      env: { ...process.env, TMP: tmp, TEMP: tmp, TMPDIR: tmp, LUACHECK: luacheck },
      maxBuffer: 32 * 1024 * 1024,
    })
    const left = fs.readdirSync(tmp).filter(n => n.startsWith('cis-luacheck-'))
    return { status: res.status, left }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true })
  }
}

check('lint.js removes its temp copy when luacheck fails', () => {
  // node is not luacheck: it is asked to run a .lua file and exits non-zero.
  const r = lintLeftovers(process.execPath)
  assert.notStrictEqual(r.status, 0, 'expected a non-zero exit')
  assert.deepStrictEqual(r.left, [], 'left behind: ' + r.left.join(', '))
})

check('lint.js removes its temp copy when luacheck cannot be found', () => {
  const r = lintLeftovers(path.join(os.tmpdir(), 'no-such-luacheck-binary'))
  assert.strictEqual(r.status, 2, 'a missing luacheck is exit 2')
  assert.deepStrictEqual(r.left, [], 'left behind: ' + r.left.join(', '))
})

// ------------------------------------------------------- syntax-check.js
const { checkSource } = require('../tools/syntax-check.js')

check('syntax-check parses a file with a hash literal', () => {
  const r = checkSource('local hash = `WEAPON_UNARMED`\nreturn hash\n', 'ok.lua')
  assert.strictEqual(r.error, null)
  assert.strictEqual(r.neutralised, true)
})

check('syntax-check still finds a real error AFTER a hash literal', () => {
  const r = checkSource('local hash = `WEAPON_UNARMED`\nlocal x = = 1\n', 'bad.lua')
  assert.ok(r.error, 'the second line is a syntax error and must be reported')
  assert.ok(/bad\.lua:2:/.test(r.error), 'reported on its real line: ' + r.error)
})

check('syntax-check finds a real error BEFORE a hash literal', () => {
  const r = checkSource('local x = = 1\nlocal hash = `WEAPON_UNARMED`\n', 'bad.lua')
  assert.ok(r.error && /bad\.lua:1:/.test(r.error), String(r.error))
})

check('syntax-check accepts 5.4 attributes and still catches an error beside one', () => {
  assert.strictEqual(checkSource('local x <const> = 1\nreturn x\n', 'a.lua').error, null)
  const r = checkSource('local x <const> = 1\nlocal y = = 2\n', 'a.lua')
  assert.ok(r.error && /a\.lua:2:/.test(r.error), String(r.error))
})

check('syntax-check reports an ordinary error with no special syntax', () => {
  assert.ok(checkSource('local x = = 1\n', 'a.lua').error)
})

check('syntax-check really parses client/cache.lua', () => {
  const src = fs.readFileSync(path.join(root, 'client', 'cache.lua'), 'utf8')
  assert.ok(src.includes('`'), 'the file is expected to hold a hash literal')
  const r = checkSource(src, 'client/cache.lua')
  assert.strictEqual(r.error, null, String(r.error))
  assert.strictEqual(r.neutralised, true, 'parsed after blanking the hash literals, not skipped')
})

// --------------------------------------------------------- docs-check.js
const docs = require('../tools/docs-check.js')

check('docs-check reads more than five documents', () => {
  const all = [...docs.DOC_FILES, ...docs.linkOnlyFiles()]
  assert.ok(all.length > 5, `reads ${all.length}`)
  assert.ok(all.includes('test/live/RUNBOOK.md'), 'the runbook is checked')
  assert.ok(all.some(f => f.startsWith('docs/archive/')), 'the archive is checked for broken links')
})

check('docs-check sees exports in both spellings', () => {
  const md = [
    "exports['cis_libs']:GetCapabilities()",
    'exports["cis_libs"]:AddDoorGroup(data)',
    'exports.cis_libs:AlertDialog(data)',
    "exports['ox_inventory']:Search('count', 'bread')",
    'exports.ox_lib:notify({})',
  ].join('\n')
  assert.deepStrictEqual([...docs.exportNames(md)].sort(), ['AddDoorGroup', 'AlertDialog', 'GetCapabilities'])
})

// ---------------------------------------------------------------- mutate.js
const mutate = require('../tools/mutate.js')

check('mutate: a spawn error is not a kill', () => {
  const bad = spawnSync(path.join(os.tmpdir(), 'no-such-binary-for-mutate'), [], { encoding: 'utf8' })
  assert.ok(bad.error, 'the spawn is expected to fail')
  const g = mutate.classify({ code: bad.status, signal: bad.signal, error: bad.error, out: '' })
  assert.strictEqual(g.state, 'error')
})

check('mutate: a signal or timeout is not a kill', () => {
  assert.strictEqual(mutate.classify({ code: null, signal: 'SIGTERM', out: '' }).state, 'error')
})

check('mutate: a crash before any test ran is not a kill', () => {
  const g = mutate.classify({ code: 1, out: "Error: Cannot find module 'fengari'\n" })
  assert.strictEqual(g.state, 'error')
})

check('mutate: a test failure is a kill, whichever runner reported it', () => {
  for (const out of [
    'FAIL(server): the check\n',
    'suite server failed=2\n',
    '[E070] client-only stub missing\n',
    'not ok 3 - the page\n',
    '# fail 1\n',
    '✖ a message from another frame is dropped (28.29ms)\nℹ fail 2\n',
    'FAIL the Lua 5.4 driver passed a broken suite\n',
  ]) {
    assert.strictEqual(mutate.classify({ code: 1, out }).state, 'failed', out)
  }
})

check('mutate: a clean exit is a survivor candidate', () => {
  assert.strictEqual(mutate.classify({ code: 0, out: 'suite server failed=0\n' }).state, 'passed')
})

check('mutate: duplicate ids are found', () => {
  assert.deepStrictEqual(mutate.duplicateIds([{ id: 'M1' }, { id: 'M2' }, { id: 'M1' }]), ['M1'])
  assert.deepStrictEqual(mutate.duplicateIds([{ id: 'M1' }, { id: 'M2' }]), [])
})

check('mutate: test/mutations.json has no duplicate id', () => {
  const spec = JSON.parse(fs.readFileSync(path.join(root, 'test', 'mutations.json'), 'utf8'))
  assert.deepStrictEqual(mutate.duplicateIds(spec.mutations), [])
})

process.stdout.write(`\ntools-selftest: ${pass} passed, ${fail} failed\n`)
process.exit(fail ? 1 : 0)

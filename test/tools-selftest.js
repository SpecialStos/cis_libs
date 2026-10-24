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

check('mutate: a gate that could not find its interpreter is not a kill', () => {
  // tools/run-lua54.js under CI with no Lua 5.4 installed. The line starts with
  // FAIL, so without its own rule it reads as a caught defect, and every
  // `check: lua54` row would be killed whatever the mutation did.
  const out = 'FAIL no Lua 5.4 interpreter found (set LUAC_LUA54, or install lua5.4). CI is set, so the Lua 5.4 suites are required, not optional.\n'
  assert.strictEqual(mutate.classify({ code: 1, out }).state, 'error')
  // A suite failure that merely mentions Lua 5.4 stays a kill.
  assert.strictEqual(mutate.classify({ code: 1, out: 'FAIL(server): the Lua 5.4 driver passed a broken suite\n' }).state, 'failed')
})

check('mutate: every check name a row uses is known', () => {
  const spec = JSON.parse(fs.readFileSync(path.join(root, 'test', 'mutations.json'), 'utf8'))
  const names = new Set(spec.mutations.map(m => m.check).filter(Boolean))
  assert.deepStrictEqual([...names].filter(n => !mutate.CHECKS[n]), [])
})

check('mutate: duplicate ids are found', () => {
  assert.deepStrictEqual(mutate.duplicateIds([{ id: 'M1' }, { id: 'M2' }, { id: 'M1' }]), ['M1'])
  assert.deepStrictEqual(mutate.duplicateIds([{ id: 'M1' }, { id: 'M2' }]), [])
})

check('mutate: test/mutations.json has no duplicate id', () => {
  const spec = JSON.parse(fs.readFileSync(path.join(root, 'test', 'mutations.json'), 'utf8'))
  assert.deepStrictEqual(mutate.duplicateIds(spec.mutations), [])
})

check('mutate: a row whose find matches 0 or 2 times, or whose file is gone, is stale', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cis-stale-'))
  try {
    fs.writeFileSync(path.join(dir, 'a.lua'), 'local x = 1\nlocal x = 1\nlocal y = 2\r\nreturn y\r\n')
    const rows = [
      { id: 'M1', file: 'a.lua', find: 'local y = 2\nreturn y' },
      { id: 'M2', file: 'a.lua', find: 'local x = 1' },
      { id: 'M3', file: 'a.lua', find: 'local z' },
      { id: 'M4', file: 'gone.lua', find: 'x' },
      { id: 'M5', file: 'a.lua', find: '' },
    ]
    assert.deepStrictEqual(mutate.staleRows(rows, dir).map(r => r.id), ['M2', 'M3', 'M4', 'M5'])
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

check('mutate: a tree that fails unmutated is refused before any row runs', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cis-baseline-'))
  try {
    fs.mkdirSync(path.join(dir, 'test'))
    fs.writeFileSync(path.join(dir, 'test', 'run.js'), "console.log('FAIL(server): broken before any mutation'); process.exit(1)\n")
    assert.match(mutate.baselineFailure(dir, [{ id: 'M1' }]), /test\/run\.js/)
    fs.writeFileSync(path.join(dir, 'test', 'run.js'), "console.log('suite server failed=0')\n")
    assert.strictEqual(mutate.baselineFailure(dir, [{ id: 'M1' }]), null)
    assert.match(mutate.baselineFailure(dir, [{ id: 'M1', check: 'nope' }]), /unknown check/)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

// The cheap half of the mutation gate. Stale rows otherwise surface only inside
// the hours-long sharded CI run, which is how three merges in a row broke rows
// unnoticed.
check('mutate: no row in test/mutations.json is stale', () => {
  const spec = JSON.parse(fs.readFileSync(path.join(root, 'test', 'mutations.json'), 'utf8'))
  assert.deepStrictEqual(mutate.staleRows(spec.mutations, root), [])
})

// The matrix list and the `/N` in the command are kept by hand in two
// workflows. A list of 1..19 with `/20` drops every twentieth row and nothing
// fails, so both are read and compared here.
check('mutate: each workflow shards over 1..N with the same N in its command', () => {
  for (const wf of ['tests.yml', 'release.yml']) {
    const text = fs.readFileSync(path.join(root, '.github', 'workflows', wf), 'utf8')
    const list = /shard:\s*\[([\d,\s]+)\]/.exec(text)
    const cmd = /--shard=\$\{\{\s*matrix\.shard\s*\}\}\/(\d+)/.exec(text)
    assert.ok(list && cmd, `${wf}: no shard matrix or no --shard command`)
    const shards = list[1].split(',').map(s => Number(s.trim()))
    const n = Number(cmd[1])
    assert.deepStrictEqual(shards, Array.from({ length: n }, (_, i) => i + 1), `${wf}: matrix is not 1..${n}`)
  }
})

check('mutate: --shard=K/N is parsed, and a malformed shard is refused', () => {
  assert.strictEqual(mutate.parseShard(['M1', '--no-copy-modules']), null)
  assert.deepStrictEqual(mutate.parseShard(['--shard=3/16']), { k: 3, n: 16 })
  assert.deepStrictEqual(mutate.parseShard(['--shard=1/1']), { k: 1, n: 1 })
  for (const bad of ['--shard', '--shard=', '--shard=0/4', '--shard=5/4', '--shard=1/0', '--shard=a/4',
    '--shard=1/4x', '--shard=1-4', '--shard=1/2/3', '--shard=-1/4']) {
    assert.throws(() => mutate.parseShard([bad]), /shard/, bad)
  }
  assert.throws(() => mutate.parseShard(['--shard=1/2', '--shard=2/2']), /more than once/)
})

check('mutate: the shards partition the rows, each row in exactly one', () => {
  const rows = Array.from({ length: 53 }, (_, i) => ({ id: 'M' + i }))
  for (const n of [1, 2, 7, 16, 53, 80]) {
    const seen = new Map()
    for (let k = 1; k <= n; k++) {
      for (const r of mutate.selectShard(rows, { k, n })) seen.set(r.id, (seen.get(r.id) || 0) + 1)
    }
    assert.strictEqual(seen.size, rows.length, `n=${n}: a row lands in no shard`)
    assert.ok([...seen.values()].every(c => c === 1), `n=${n}: a row lands in more than one shard`)
  }
  // No shard asked for: every row, untouched.
  assert.strictEqual(mutate.selectShard(rows, null), rows)
  // Shards are by index after the filter, so they stay within one row of equal.
  const sizes = [1, 2, 3].map(k => mutate.selectShard(rows, { k, n: 3 }).length)
  assert.deepStrictEqual(sizes, [18, 18, 17])
})

check('mutate: the real table is split into N shards that together hold every row', () => {
  const spec = JSON.parse(fs.readFileSync(path.join(root, 'test', 'mutations.json'), 'utf8'))
  const got = []
  for (let k = 1; k <= 20; k++) got.push(...mutate.selectShard(spec.mutations, { k, n: 20 }).map(r => r.id))
  assert.deepStrictEqual(got.slice().sort(), spec.mutations.map(r => r.id).sort())
})

check('mutate: a bad --shard exits 2 before any row runs', () => {
  const r = require('child_process').spawnSync(process.execPath, [path.join(root, 'tools', 'mutate.js'), '--shard=0/16'],
    { encoding: 'utf8' })
  assert.strictEqual(r.status, 2)
  assert.match(r.stderr, /malformed shard/)
})

// ---------------------------------------------------------- suite-verdict.js
const { judge } = require('../test/suite-verdict.js')

check('verdict: a clean suite passes', () => {
  const v = judge('module tests: passed=326 failed=0\n', 0)
  assert.strictEqual(v.ok, true)
  assert.strictEqual(v.count, 326)
})

check('verdict: a suite that ran no assertion is not a pass', () => {
  // The fengari driver used to accept this: exit 0, a summary, passed=0.
  const v = judge('module tests: passed=0 failed=0\n', 0)
  assert.strictEqual(v.ok, false)
  assert.strictEqual(v.count, 0)
})

check('verdict: no summary, a crash, a reported failure, or a late FAIL line is not a pass', () => {
  assert.strictEqual(judge('', 0).ok, false)
  assert.strictEqual(judge('module tests: passed=10 failed=0\n', 1).ok, false)
  assert.strictEqual(judge('module tests: passed=10 failed=2\n', 0).ok, false)
  assert.strictEqual(judge('module tests: passed=10 failed=0\nFAIL after the summary\n', 0).ok, false)
})

process.stdout.write(`\ntools-selftest: ${pass} passed, ${fail} failed\n`)
process.exit(fail ? 1 : 0)

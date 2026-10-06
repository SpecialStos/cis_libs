'use strict'

// The scanner's own tests.
//
// tools/scan-cis.js decides which realm every `Cis.*` function belongs to by
// WALKING THE BLOCK STRUCTURE of init.lua. A scanner with a hole in it is worse
// than no scanner, because it reports coverage it does not have -- and the
// failure mode is indistinguishable from a clean run: a mis-parse produces a
// surface of zero names, and zero names looks exactly like a file with no
// surface.
//
// So the shape of the walk is pinned here, and so is the trap that produced the
// first two bugs in it: a nested anonymous function overwrote the single
// pending-definition slot, and the scanner reported a surface of zero while
// exiting cleanly.
//
//   node test/api/scanner-selftest.js
//
// Exit 0 clean, 1 on failure. Nothing here reads the real init.lua: each case
// builds a small source, so a failure names the shape that broke rather than
// whichever line of a 988-line file happens to move.

const assert = require('assert')
const { scanCisSurface, surface, splitParams, paramName } = require('../../tools/scan-cis.js')

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

function byName(src) {
  const r = scanCisSurface(src)
  const map = new Map()
  for (const d of r.defs) {
    if (!map.has(d.name)) map.set(d.name, [])
    map.get(d.name).push(d)
  }
  return { r, map }
}

process.stdout.write('scan-cis.js self-test\n')

// ---------------------------------------------------------------- the realms

check('a top-level function is on both realms', () => {
  const { map } = byName('function Cis.db.query(sql)\n    return 1\nend\n')
  assert.deepStrictEqual(map.get('Cis.db.query').map((d) => d.realm), ['both'])
})

check('inside `if not IS_SERVER` is client', () => {
  const { map } = byName('if not IS_SERVER then\nfunction Cis.player.ped()\nend\nelse\nfunction Cis.db.q(a)\nend\nend\n')
  assert.deepStrictEqual(map.get('Cis.player.ped').map((d) => d.realm), ['client'])
  assert.deepStrictEqual(map.get('Cis.db.q').map((d) => d.realm), ['server'])
})

check('the else half flips the realm, it does not clear it', () => {
  // The bug this catches: an `else` that RESETS the realm to "unknown" rather
  // than inverting it, which would report the server half as `both` -- and a
  // `both` function is not a wrong-realm refusal, so the check passes.
  const { map } = byName('if not IS_SERVER then\nfunction Cis.a()\nend\nelse\nfunction Cis.b()\nend\nend\n')
  assert.strictEqual(map.get('Cis.b')[0].realm, 'server')
})

check('`if IS_SERVER` is server, and `elseif` re-evaluates', () => {
  const { map } = byName('if IS_SERVER then\nfunction Cis.a()\nend\nelseif not IS_SERVER then\nfunction Cis.b()\nend\nend\n')
  assert.strictEqual(map.get('Cis.a')[0].realm, 'server')
  assert.strictEqual(map.get('Cis.b')[0].realm, 'client')
})

check('a nested block inherits, and does not decide', () => {
  const { map } = byName('if not IS_SERVER then\nfor i = 1, 3 do\nfunction Cis.a()\nend\nend\nend\n')
  assert.strictEqual(map.get('Cis.a')[0].realm, 'client')
})

// ------------------------------------------------------- the for/while trap

check('`for ... do` opens ONE block, and `while` likewise', () => {
  // The depth counter is the whole mechanism, and this is the shape that
  // breaks it. Counting `for` AND `do` as two openers leaves the depth wrong
  // from the first loop onward, so every realm after it is wrong while nothing
  // looks broken.
  const src = [
    'for i = 1, 3 do',
    '  for j = 1, 3 do',
    '  end',
    'end',
    'if not IS_SERVER then',
    'function Cis.a()',
    'end',
    'end',
  ].join('\n')
  const { map } = byName(src)
  assert.strictEqual(map.get('Cis.a')[0].realm, 'client', 'the function after two nested loops')
  assert.strictEqual(scanCisSurface(src).unclosed, 0, 'every block is closed')
})

check('`while ... do` and a bare `do` block', () => {
  const src = 'while true do\nend\ndo\nfunction Cis.a()\nend\nend\n'
  assert.strictEqual(scanCisSurface(src).unclosed, 0)
  assert.strictEqual(byName(src).map.get('Cis.a')[0].realm, 'both')
})

// ----------------------------------------------------- the nested function

check('a nested anonymous function does not clobber its parent', () => {
  // The bug the scanner was born with. `Cis.callback.call` contains a
  // `CreateThread(function() ... end)`, and a single module-level pending slot
  // meant the inner definition overwrote the outer: the surface came out EMPTY
  // and the scanner exited 0. A scanner that finds nothing must never look like
  // a scanner that passed, so `lost` and `unclosed` are both reported.
  const src = [
    'function Cis.callback.call(name, cb, ...)',
    '  CreateThread(function()',
    '    local x = 1',
    '    if x then',
    '      return 1',
    '    end',
    '  end)',
    'end',
  ].join('\n')
  const r = scanCisSurface(src)
  assert.strictEqual(r.unclosed, 0, 'no unclosed blocks')
  assert.strictEqual(r.lost.length, 0, 'no lost definitions')
  const defs = r.defs.filter((d) => d.name === 'Cis.callback.call')
  assert.strictEqual(defs.length, 1, 'the outer definition is found once')
  assert.deepStrictEqual(defs[0].params, ['name', 'cb', '...'])
})

// -------------------------------------------------------------- the refusals

check('a refusal stub is recognised, and it is not a second implementation', () => {
  const { map } = byName([
    'if not IS_SERVER then',
    'function Cis.player.ped()',
    '  return 1',
    'end',
    'else',
    'function Cis.player.ped()',
    "  return false, 'client only'",
    'end',
    'end',
  ].join('\n'))
  const defs = map.get('Cis.player.ped')
  assert.strictEqual(defs.length, 2, 'the name is defined twice, and that is the correct file')
  assert.strictEqual(defs[0].refusal, null)
  assert.strictEqual(defs[1].refusal, 'client')
})

check('a body that merely RETURNS false is not a refusal', () => {
  // The matcher is anchored to the WHOLE body, so a real implementation that
  // happens to end in `return false, 'client only'` for another reason is not
  // silently reclassified as a stub. An over-eager matcher here would mark a
  // working function as a refusal and hide the fact that the real definition is
  // missing.
  const { map } = byName("function Cis.a()\n  local x = 1\n  return false, 'client only'\nend\n")
  assert.strictEqual(map.get('Cis.a')[0].refusal, null)
})

// ---------------------------------------------------------------- the params

check('parameters split on top-level commas only', () => {
  assert.deepStrictEqual(splitParams('opts = { a = 1, b = 2 }, other'), ['opts = { a = 1, b = 2 }', 'other'])
  assert.deepStrictEqual(splitParams(''), [])
  assert.deepStrictEqual(splitParams('a, b, c'), ['a', 'b', 'c'])
})

check('a vararg is a position, not a typo', () => {
  // Dropping `...` would let a declaration answer `(name)` for a function that
  // forwards an unbounded tail.
  assert.strictEqual(paramName('...'), '...')
  assert.strictEqual(paramName('name'), 'name')
  assert.strictEqual(paramName('timeout = 5000'), 'timeout')
  assert.strictEqual(paramName('opts = {}'), 'opts')
})

// --------------------------------------------------------- the source traps

check('a comment cannot move the block depth', () => {
  const { map } = byName('-- function Cis.ghost() end\nif not IS_SERVER then\nfunction Cis.real()\nend\nend\n')
  assert.ok(!map.has('Cis.ghost'), 'a commented-out definition is not a definition')
  assert.strictEqual(map.get('Cis.real')[0].realm, 'client')
})

check('a long comment cannot move the block depth', () => {
  const { map } = byName('--[[ function Cis.ghost()\nif not IS_SERVER then\nend ]]\nfunction Cis.real()\nend\n')
  assert.ok(!map.has('Cis.ghost'))
  assert.strictEqual(map.get('Cis.real')[0].realm, 'both')
})

check('a string literal containing `end` cannot move the block depth', () => {
  const { map } = byName("if not IS_SERVER then\nfunction Cis.a()\n  local q = 'SELECT end FROM t'\nend\nend\n")
  assert.strictEqual(map.get('Cis.a')[0].realm, 'client')
})

check('an escaped quote inside a string does not end it', () => {
  const { map } = byName("if not IS_SERVER then\nfunction Cis.a()\n  local q = 'it\\'s end'\nend\nend\n")
  assert.strictEqual(map.get('Cis.a')[0].realm, 'client')
})

// ------------------------------------------------------------- the forwards

check('the forwarded export is read out of the body', () => {
  const { map } = byName("function Cis.db.query(sql)\n  return exportCall('DbQuery', sql)\nend\n")
  assert.deepStrictEqual(map.get('Cis.db.query')[0].forwards, ['DbQuery'])
})

check('tryExport counts, because it crosses the same boundary', () => {
  const { map } = byName("function Cis.log.debug(m)\n  tryExport('LogDebug', m)\nend\n")
  assert.deepStrictEqual(map.get('Cis.log.debug')[0].forwards, ['LogDebug'])
})

check('a call to another resource is not a forward', () => {
  // `exports.other:query(` has no quotes and no bare name after them, and a
  // pattern loose enough to catch it would report every third-party call as a
  // forwarding target and fail the realm check against a name that is not ours.
  const { map } = byName("function Cis.a()\n  exports.other:addEntity({})\nend\n")
  assert.deepStrictEqual(map.get('Cis.a')[0].forwards, [])
})

// ---------------------------------------------------------------- the merge

check('the merged surface names both realms for a two-halves function', () => {
  const { entries } = surfaceFrom([
    'if not IS_SERVER then',
    'function Cis.inventory.count(item)',
    'end',
    'else',
    'function Cis.inventory.count(src, item)',
    'end',
    'end',
  ].join('\n'))
  const e = entries.find((x) => x.name === 'Cis.inventory.count')
  assert.deepStrictEqual(e.realms, ['client', 'server'])
  assert.deepStrictEqual(e.variants.map((v) => v.names[0]), ['item', 'src'])
})

// A temp file, because `surface()` reads from disk and the merge is the part
// worth testing against the same code path the validator uses.
function surfaceFrom(src) {
  const fs = require('fs')
  const os = require('os')
  const path = require('path')
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cis-scan-'))
  const file = path.join(dir, 'init.lua')
  fs.writeFileSync(file, src, 'utf8')
  try {
    return surface(file)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

check('an empty source is an empty surface, and the caller is told', () => {
  const r = scanCisSurface('-- nothing here\n')
  assert.strictEqual(r.defs.length, 0)
  assert.strictEqual(r.unclosed, 0)
  assert.strictEqual(r.lost.length, 0)
  // A surface of zero is a VALID answer for this input and an alarming one for
  // the real file. The validator treats the second case as a failure; what this
  // test pins is that the two are distinguishable, which is the property the
  // validator's E059 depends on.
})

process.stdout.write(`\n${pass} passed, ${fail} failed\n`)
process.exit(fail ? 1 : 0)

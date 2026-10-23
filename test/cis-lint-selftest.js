'use strict'

// cis-lint's own tests.
//
// A lint rule that never fires reads exactly like a clean codebase, so every
// rule is pinned to a fixture that must turn it red, line for line, and the
// passing fixture pins the shapes it must NOT flag (an answer in both
// branches, cb answered from a thread, a `function UI.onBuy` handler, a
// dispatcher that reads `source` one call down, `source` as an argument of
// the yielding call itself, a `.state` field that is not a state bag).
//
//   node test/cis-lint-selftest.js
//
// Exit 0 clean, 1 on failure. Fixtures: test/fixtures/cis-lint/.

const assert = require('assert')
const path = require('path')
const { lintResource, tokenize, parse } = require('../tools/cis-lint.js')

const fixtures = path.join(__dirname, 'fixtures', 'cis-lint')
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

const found = (dir) => {
  const r = lintResource(path.join(fixtures, dir))
  assert.deepStrictEqual(r.errors, [], `${dir}: parse errors`)
  return r
}
const keys = (list) => list.map(v => `${v.file}:${v.line} ${v.rule}`)

// Exactly these, no more and no fewer: an extra one is a false positive a
// product would have to suppress, a missing one is a hole.
const EXPECTED = {
  'bad-l001': [
    'client.lua:4 L001',  // falls off the end; `cb ~= nil` is not an answer
    'client.lua:8 L001',  // cb parameter named _ and never called
    'client.lua:12 L001', // bare return before cb
    'client.lua:21 L001', // if without else
    'client.lua:27 L001', // cb only inside a loop that may not run
    'client.lua:32 L001', // handler with no cb parameter
    'client.lua:34 L001', // handler this file does not define
    'client.lua:39 L001', // return inside a loop
    'client.lua:48 L001', // RegisterNuiCallback, the alias
    'client.lua:53 L001', // RegisterNuiCallbackType + '__cfx_nui:' handler
  ],
  'bad-l002': [
    'server.lua:2 L002',  // identity from the payload
    'server.lua:8 L002',  // source after an exports call
    'server.lua:14 L002', // source after Wait
    'server.lua:19 L002', // source after .await
    'server.lua:22 L002', // a parameter named source
    'server.lua:26 L002', // source read only in a later thread
    'server.lua:33 L002', // RegisterServerEvent + AddEventHandler, no source
    'server.lua:37 L002', // handler this file does not define
    'server.lua:39 L000', // allow without a reason
    'server.lua:40 L002', // ... so the violation stands
    'server.lua:47 L002', // read in time, then read AGAIN after Wait
    'server.lua:53 L002', // yield through a file-level alias of exports
    'server.lua:58 L002', // lib.waitFor
    'server2.lua:2 L002', // net name declared in server.lua, handler in server2.lua
  ],
  'bad-l003': [
    'web/App.tsx:2 L003',    // Tailwind backdrop-blur
    'web/App.tsx:4 L003',    // backdropFilter style object
    'web/index.html:4 L003', // inline style
    'web/style.css:3 L003',
    'web/style.css:5 L003',  // -webkit- prefix
  ],
  'bad-l004': [
    'web/dist/index.html:4 L004', // built script
    'web/dist/index.html:5 L004', // built stylesheet
    'web/dist/index.html:7 L004', // query string after the extension
    'web/src/icons.ts:1 L004',
    'web/src/icons.ts:2 L004',    // template literal
    'web/src/style.css:1 L004',   // quoted url()
    'web/src/style.css:2 L004',   // bare url()
    'web/vite.config.ts:1 L004',  // no base: './'
  ],
  'bad-l005': ['fxmanifest.lua:4 L005'],
  'bad-l006': ['fxmanifest.lua:5 L006'], // GetPlayerPed on the server; report.state is not a state bag
}

for (const [dir, want] of Object.entries(EXPECTED)) {
  check(`${dir} flags exactly its cases`, () => {
    assert.deepStrictEqual(keys(found(dir).violations), want)
  })
}

check('good passes, with its two reasoned allows printed', () => {
  const r = found('good')
  assert.deepStrictEqual(keys(r.violations), [])
  assert.deepStrictEqual(keys(r.allowed), ['server/main.lua:39 L002', 'web/style.css:4 L003'])
  assert.ok(r.allowed.every(a => a.reason.length > 10), 'every allow carries its reason')
})

check('L006 names the line that needs OneSync', () => {
  const [v] = found('bad-l006').violations
  assert.match(v.message, /server\.lua:7 calls GetPlayerPed on the server/)
})

check('strings and comments never reach the parser', () => {
  const src = "local a = 'end' local b = [==[ end ]] ]==] --[[ end ]] -- end\nlocal c = `end`"
  const names = tokenize(src).toks.filter(t => t.t === 'kw' && t.v === 'end')
  assert.strictEqual(names.length, 0)
})

check('an unbalanced function is a parse error, not a pass', () => {
  assert.throws(() => parse(tokenize('RegisterNUICallback("x", function(d, cb) if d then cb() end').toks), /without end|expected end/)
})

process.stdout.write(`\ncis-lint selftest: ${pass} passed, ${fail} failed\n`)
process.exit(fail ? 1 : 0)

// `npm run test:ci`: the decisions tools/ci-live.js makes about a real server's
// console and results file, pinned without a server. Run under node --test.

'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')

const lib = require('../../tools/ci-live-lib')
const liveEnv = require('../../tools/live-env')
const { parseArgs } = require('../../tools/ci-live')

// Verbatim from FXServer build 35245 on Linux with no sv_licenseKey, ANSI and
// all (captured 2026-10-22 by tools/ci-fxserver.sh probe).
const UNLICENSED = '\x1b[38;5;83m[           resources] \x1b[0m\x1b[0m\x1b[32mScanning resources.\x1b[0m\n' +
  '\x1b[38;5;83m[           resources] \x1b[0m\x1b[0m\x1b[32mFound 10 resources.\x1b[0m\n' +
  'This server does not have a license key specified. Please set the sv_licenseKey console variable to a key ' +
  'from https://portal.cfx.re/servers/registration-keys. (for example, `set sv_licenseKey "key"` in the config, ' +
  'or `+set sv_licenseKey key` on the command line)\x1b[38;5;66m[          svadhesive] \x1b[0m\x1b[0mError: This ' +
  'server does not have a license key specified. Please set the sv_licenseKey console variable to a key from ' +
  'https://portal.cfx.re/servers/registration-keys.'

// ------------------------------------------------------------------ console

test('stripAnsi removes terminal escapes and FiveM ^n colour codes', () => {
  assert.equal(lib.stripAnsi('\x1b[38;5;83m[ a] \x1b[0m^1SCRIPT ERROR^7: x'), '[ a] SCRIPT ERROR: x')
})

test('a clean boot has no console errors', () => {
  const log = [
    '[           resources] Found 10 resources.',
    '[ script:cis_test_providers] [cis_test_providers] config supplied: cis_test, cis_test_providers, cis_test_c authorized; DropPlayer off',
    '[ resources:cis_test] Started resource cis_test',
  ].join('\n')
  assert.deepEqual(lib.scanConsole(log), [])
})

test('SCRIPT ERROR is found, with the resource it came from', () => {
  const log = 'ok\n\x1b[31m[    script:cis_libs] ^1SCRIPT ERROR: @cis_libs/server/sync.lua:12: attempt to index a nil value\n'
  const found = lib.scanConsole(log)
  assert.equal(found.length, 1)
  assert.equal(found[0].kind, 'script-error')
  assert.equal(found[0].resource, 'cis_libs')
  assert.equal(found[0].lineNo, 2)
  assert.equal(found[0].ignored, false)
})

test('could not find and Error loading script are boot errors', () => {
  const log = [
    "[ resources:cis_libs] Warning: could not find client_script 'client/inventory.lua' (defined in fxmanifest.lua:86)",
    'Error loading script server/x.lua in resource cis_test: @cis_test/server/x.lua:3: unexpected symbol',
    "Couldn't start resource cis_test_c.",
  ].join('\n')
  const found = lib.scanConsole(log)
  assert.deepEqual(found.map(f => f.kind), ['could-not-find', 'load-error', 'start-failed'])
  assert.deepEqual(found.map(f => f.resource), ['cis_libs', 'cis_test', 'cis_test_c'])
})

test('errors from a deliberately broken fixture are reported but ignored', () => {
  const log = '[ script:cis_test_badmeta] SCRIPT ERROR: @cis_test_badmeta/server/claim.lua:20: boom'
  const found = lib.scanConsole(log, { ignoreResources: ['cis_test_badmeta'] })
  assert.equal(found.length, 1)
  assert.equal(found[0].ignored, true)
})

test('an allow pattern excuses one line and no other', () => {
  const log = 'SCRIPT ERROR: known noise 42\nSCRIPT ERROR: real fault'
  const found = lib.scanConsole(log, { allowPatterns: [/known noise/] })
  assert.deepEqual(found.map(f => f.ignored), [true, false])
})

test('lineOffset numbers lines from where the scan started', () => {
  const found = lib.scanConsole('x\nSCRIPT ERROR: y', { lineOffset: 100 })
  assert.equal(found[0].lineNo, 102)
})

test('the unlicensed boot is recognised, and reported once', () => {
  const why = lib.licenceProblem(UNLICENSED)
  assert.ok(why.startsWith('This server does not have a license key specified.'))
  assert.ok(!why.includes('svadhesive'))
  assert.equal(lib.licenceProblem('[ resources] Found 10 resources.\nServer license key authentication succeeded'), null)
  assert.ok(lib.licenceProblem('[ citizen-server-impl] Server license key authentication failed. Please check your key.'))
})

test('the unlicensed svadhesive line is also a boot error', () => {
  assert.ok(lib.scanConsole(UNLICENSED).some(f => f.kind === 'svadhesive'))
})

test('cis_test refusals end the wait instead of a timeout', () => {
  assert.match(lib.harnessRefusal('[ script:cis_test] [cis_test] PREFLIGHT REFUSED: slots held by something other than the fakes: db held by oxmysql'),
    /PREFLIGHT REFUSED/)
  assert.match(lib.harnessRefusal('[cis_test] "nope" selected 0 suites; nothing will run'), /selected 0 suites/)
  assert.equal(lib.harnessRefusal('[cis_test] results: results_run-1.json + results_latest.json'), null)
})

// ------------------------------------------------------------------- report

const PASSING = {
  run: 'run-20261022-101500',
  commit: 'abc1234',
  players: 0,
  tally: { pass: 2, fail: 0, skip: 0, manual: 0, error: 0, ms: 40 },
  cases: [
    { suite: 'registry', case: 'a', status: 'PASS' },
    { suite: 'notify', case: 'b', status: 'PASS' },
  ],
}

test('an all-PASS report passes', () => {
  const v = lib.judgeReport(JSON.stringify(PASSING))
  assert.equal(v.ok, true)
  assert.equal(v.counts.pass, 2)
  assert.equal(v.run, 'run-20261022-101500')
})

test('one FAIL or ERROR fails the report', () => {
  for (const status of ['FAIL', 'ERROR']) {
    const r = structuredClone(PASSING)
    r.cases[1].status = status
    const v = lib.judgeReport(r)
    assert.equal(v.ok, false, status)
    assert.equal(v.failing.length, 1)
  }
})

test('SKIP and MANUAL are listed but neither pass nor fail', () => {
  const r = structuredClone(PASSING)
  r.cases.push({ suite: 'player', case: '<whole suite>', status: 'SKIP', skipReason: 'no player connected' })
  r.cases.push({ suite: 'draw', case: 'look', status: 'MANUAL', manual: 'look at it' })
  const v = lib.judgeReport(r)
  assert.equal(v.ok, true)
  assert.equal(v.skipped.length, 2)
  assert.equal(v.counts.skip, 1)
  assert.equal(v.counts.manual, 1)
})

test('a run with zero cases fails, whichever way the encoder wrote the empty table', () => {
  for (const cases of [[], {}]) {
    const v = lib.judgeReport({ ...PASSING, cases })
    assert.equal(v.ok, false)
    assert.ok(v.problems.some(p => /zero cases/.test(p)))
  }
})

test('not JSON, no run id, no cases, unknown status and a disagreeing tally all fail', () => {
  assert.equal(lib.judgeReport('{"run": ').ok, false)
  assert.equal(lib.judgeReport({ ...PASSING, run: '' }).ok, false)
  assert.equal(lib.judgeReport({ run: 'r' }).ok, false)
  const odd = structuredClone(PASSING)
  odd.cases[0].status = 'MAYBE'
  assert.equal(lib.judgeReport(odd).ok, false)
  assert.equal(lib.judgeReport({ ...PASSING, tally: { ...PASSING.tally, fail: 1 } }).ok, false)
})

// --------------------------------------------------------------- server.cfg

test('server.cfg: loopback, OneSync, two slots, unlisted, harness order, no key', () => {
  const cfg = lib.buildServerCfg({ secretsFile: 'secrets.cfg' })
  assert.match(cfg, /^endpoint_add_tcp "127\.0\.0\.1:30120"$/m)
  assert.match(cfg, /^endpoint_add_udp "127\.0\.0\.1:30120"$/m)
  assert.match(cfg, /^set onesync on$/m)
  assert.match(cfg, /^sv_maxclients 2$/m)
  assert.match(cfg, /^sv_master1 ""$/m)
  assert.match(cfg, /^set cis_authorized_resources "cis_test,cis_test_providers,cis_test_c"$/m)
  assert.match(cfg, /^set cis_config_supplier "cis_test_providers"$/m)
  assert.match(cfg, /^exec "secrets\.cfg"$/m)
  assert.doesNotMatch(cfg, /sv_licenseKey "/)
  assert.doesNotMatch(cfg, /sv_enforceGameBuild/)
  assert.doesNotMatch(cfg, /ensure cis_test_badmeta/)
  const ensures = cfg.split('\n').filter(l => l.startsWith('ensure ')).map(l => l.slice(7))
  assert.deepEqual(ensures, ['cis_libs', 'cis_test_providers', 'cis_test_b', 'cis_test_c', 'cis_test'])
  for (const ace of lib.HARNESS_ACES) assert.ok(cfg.includes(`add_ace resource.cis_test ${ace} allow`), ace)
  // Every ACE line comes before the ensure that needs it.
  assert.ok(cfg.lastIndexOf('add_ace') < cfg.indexOf('ensure cis_libs'))
})

test('server.cfg: game build and extra convars only when asked, values cannot break a line', () => {
  const cfg = lib.buildServerCfg({ gameBuild: '3095', convars: { x: 'a"b\nc' } })
  assert.match(cfg, /^set sv_enforceGameBuild 3095$/m)
  assert.match(cfg, /^set x "abc"$/m)
  assert.doesNotMatch(cfg, /^exec /m)
})

test('the secrets file holds the key and refuses anything that is not key-shaped', () => {
  assert.equal(lib.buildSecretsCfg(' cfxk_abc123_DEF \n'), 'sv_licenseKey "cfxk_abc123_DEF"\n')
  assert.throws(() => lib.buildSecretsCfg(''))
  assert.throws(() => lib.buildSecretsCfg('abc"\nquit'))
})

test('redact removes the key and key-shaped values, and leaves prose alone', () => {
  const key = 'cfxk_1a2b3c4d5e6f7g8h_XyZ'
  assert.equal(lib.redact(`boot with ${key} ok`, key), 'boot with *** ok')
  assert.equal(lib.redact('sv_licenseKey "abcd1234efgh5678ijkl"', ''), 'sv_licenseKey "***"')
  const prose = 'Please set the sv_licenseKey console variable'
  assert.equal(lib.redact(prose, ''), prose)
})

// ----------------------------------------------------------------- live-env

function tmpFile(body) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cis-live-env-'))
  const f = path.join(dir, 'live-env.json')
  if (body !== undefined) fs.writeFileSync(f, body)
  return f
}

test('live-env: the file alone is returned unchanged (the VPS flow)', () => {
  const f = tmpFile(JSON.stringify({ mode: 'local', resourcesDir: 'C:\\srv\\resources\\[standalone]', libDir: 'C:\\x' }))
  const r = liveEnv.load({ file: f, environ: {} })
  assert.equal(r.error, null)
  assert.equal(r.env.resourcesDir, 'C:\\srv\\resources\\[standalone]')
  assert.deepEqual(r.overridden, [])
})

test('live-env: CIS_LIVE_* variables win field by field, and need no file', () => {
  const f = tmpFile(JSON.stringify({ resourcesDir: '/a', libDir: '/a/cis_libs', client: { mode: 'off' } }))
  const r = liveEnv.load({ file: f, environ: { CIS_LIVE_RESOURCES_DIR: '/ci/resources', CIS_LIVE_LIB_DIR: ' ' } })
  assert.equal(r.env.resourcesDir, '/ci/resources')
  assert.equal(r.env.libDir, '/a/cis_libs', 'a blank variable is not an override')
  assert.deepEqual(r.env.client, { mode: 'off' })
  const none = liveEnv.load({ file: tmpFile(), environ: { CIS_LIVE_RESOURCES_DIR: '/ci' } })
  assert.equal(none.fromFile, false)
  assert.equal(none.env.resourcesDir, '/ci')
})

test('live-env: nothing described is null, a broken file is an error', () => {
  assert.equal(liveEnv.load({ file: tmpFile(), environ: {} }).env, null)
  assert.match(liveEnv.load({ file: tmpFile('{nope'), environ: {} }).error, /not valid JSON/)
})

test('live-env: CIS_LIVE_ENV moves the file', () => {
  assert.equal(liveEnv.envFile({ CIS_LIVE_ENV: '/tmp/x.json' }), path.resolve('/tmp/x.json'))
  assert.ok(liveEnv.envFile({}).endsWith('.live-env.json'))
})

test('fxserverCommand: FXServer.exe on Windows, the musl loader on Linux', () => {
  assert.ok(liveEnv.fxserverCommand('C:\\art', 'win32').cmd.endsWith('FXServer.exe'))
  const l = liveEnv.fxserverCommand('/opt/fx', 'linux')
  assert.equal(l.cmd, path.join('/opt/fx', 'alpine', 'opt', 'cfx-server', 'ld-musl-x86_64.so.1'))
  assert.deepEqual(l.args.slice(-3), ['+set', 'citizen_dir', path.join('/opt/fx', 'alpine', 'opt', 'cfx-server', 'citizen') + '/'])
  assert.ok(l.args.includes(path.join('/opt/fx', 'alpine', 'opt', 'cfx-server', 'FXServer')))
})

// ----------------------------------------------------------------- options

test('ci-live options: defaults, and a tier name cannot smuggle a command', () => {
  const o = parseArgs(['node', 'ci-live.js', '--fxserver', '/fx'])
  assert.deepEqual(o.tiers, ['server', 'lifecycle'])
  assert.ok(o.ignoreResources.includes('cis_test_badmeta'))
  assert.deepEqual(parseArgs(['n', 's', '--fxserver', '/fx', '--tiers', 'server']).tiers, ['server'])
  assert.throws(() => parseArgs(['n', 's', '--fxserver', '/fx', '--tiers', 'server;quit']), /not allowed/)
  assert.throws(() => parseArgs(['n', 's', '--fxserver', '/fx', '--tiers', 'server run']), /not allowed/)
  assert.throws(() => parseArgs(['n', 's', '--bogus']), /unknown option/)
  assert.ok(parseArgs(['n', 's', '--fxserver', '/fx', '--allow-line', 'x+']).allowPatterns[0].test('xx'))
})

// A stand-in for FXServer, for test/ci/ci-live.test.js. NOT a FiveM server.
//
// It does the handful of things tools/ci-live.js watches a real server do, and
// nothing else: prints a boot, writes cis_test's status.json the way status.lua
// does, prints the providers' config line, and answers `cis_test status`,
// `cis_test run <tier>` and `quit` on stdin by writing the files report.lua
// writes. What it proves is the ORCHESTRATION -- boot detection, the commit
// check, waiting for a new run id, judging, shutdown, redaction -- so that the
// first run against a real licensed server is not also the first run of the
// runner. What the harness finds on a real server is the job's business.
//
// FAKE_SCENARIO picks the behaviour:
//   pass          every tier passes
//   fail          the lifecycle tier records one FAIL case
//   script-error  a SCRIPT ERROR at boot
//   preflight     cis_test refuses every run
//   unlicensed    the real build's no-key message, then SIGTERM to itself
//   echo-key      prints the licence key it was given (redaction must catch it)

'use strict'

const fs = require('fs')
const path = require('path')
const readline = require('readline')

const scenario = process.env.FAKE_SCENARIO || 'pass'
const data = process.cwd()
const resources = path.join(data, 'resources')
const cisTest = path.join(resources, 'cis_test')

const out = (line) => process.stdout.write(line + '\n')

const cfg = fs.readFileSync(path.join(data, 'server.cfg'), 'utf8')
const ensured = [...cfg.matchAll(/^ensure (\S+)$/gm)].map(m => m[1])
const secrets = fs.existsSync(path.join(data, 'secrets.cfg'))
  ? fs.readFileSync(path.join(data, 'secrets.cfg'), 'utf8') : ''
const key = (secrets.match(/sv_licenseKey "([^"]*)"/) || [])[1] || ''

out('\x1b[38;5;83m[           resources] \x1b[0mScanning resources.')
out(`\x1b[38;5;83m[           resources] \x1b[0mFound ${fs.readdirSync(resources).length + 3} resources.`)

if (scenario === 'unlicensed' || !key) {
  process.stdout.write('This server does not have a license key specified. Please set the sv_licenseKey console ' +
    'variable to a key from https://portal.cfx.re/servers/registration-keys.[          svadhesive] Error: This ' +
    'server does not have a license key specified.')
  setTimeout(() => process.kill(process.pid, 'SIGTERM'), 100)
  setInterval(() => {}, 1000)
} else {
  boot()
}

function commit() {
  try {
    return JSON.parse(fs.readFileSync(path.join(cisTest, 'deploy.json'), 'utf8')).commit
  } catch {
    return 'unknown'
  }
}

function writeStatus() {
  const res = {}
  for (const r of ['cis_libs', 'cis_test_providers', 'cis_test_b', 'cis_test_c', 'cis_test_badmeta', 'cis_ctl']) {
    res[r] = ensured.includes(r) ? 'started' : 'stopped'
  }
  fs.writeFileSync(path.join(cisTest, 'status.json'), JSON.stringify({
    cisLibsVersion: '1.0.0',
    commit: commit(),
    playerConnected: false,
    playerCount: 0,
    resources: res,
    suites: [
      { suite: 'registry', tier: 'server', needsPlayer: false },
      { suite: 'lifecycle', tier: 'lifecycle', needsPlayer: false },
      { suite: 'player', tier: 'player', needsPlayer: true },
    ],
  }))
}

function boot() {
  out('Authenticating server license key...')
  if (scenario === 'echo-key') out(`debug: using sv_licenseKey ${key}`)
  out('Server license key authentication succeeded. Welcome!')
  for (const r of ensured) out(`[ resources:${r}] Started resource ${r}`)
  if (scenario === 'script-error') {
    out('\x1b[31m[    script:cis_test_c] ^1SCRIPT ERROR: @cis_test_c/server/own.lua:10: attempt to call a nil value')
  }
  writeStatus()
  out('[ script:cis_test_providers] [cis_test_providers] config supplied: cis_test, cis_test_providers, cis_test_c authorized; DropPlayer off')

  const rl = readline.createInterface({ input: process.stdin })
  rl.on('line', (line) => {
    const cmd = line.trim()
    if (cmd === 'quit') {
      out('[    citizen-server-impl] server shutting down')
      process.exit(0)
    }
    if (cmd === 'cis_test status') {
      writeStatus()
      out('[ script:cis_test] [cis_test] status.json written')
      return
    }
    const run = cmd.match(/^cis_test run (\S+)$/)
    if (run) setTimeout(() => runTier(run[1]), 200)
  })
  rl.on('close', () => process.exit(0))
}

function runTier(tier) {
  if (scenario === 'preflight') {
    out('[ script:cis_test] [cis_test] PREFLIGHT REFUSED: slots held by something other than the fakes: db held by oxmysql')
    return
  }
  const d = new Date()
  const pad = (n) => String(n).padStart(2, '0')
  const id = `run-${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}-` +
    `${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}`
  const cases = [{ ev: 'case', run: id, tier, suite: tier, case: 'it works', status: 'PASS', ms: 1, checks: 2 }]
  if (scenario === 'fail' && tier === 'lifecycle') {
    cases.push({ ev: 'case', run: id, tier, suite: tier, case: 'it leaks', status: 'FAIL', ms: 1, checks: 1, msg: 'a counter moved' })
  }
  const tally = { pass: 0, fail: 0, skip: 0, manual: 0, error: 0, ms: 5 }
  for (const c of cases) tally[c.status.toLowerCase()]++
  const body = JSON.stringify({ run: id, commit: commit(), server: 'cis_libs CI', players: 0, tally, cases })
  fs.writeFileSync(path.join(cisTest, `results_${id}.json`), body)
  fs.writeFileSync(path.join(cisTest, 'results_latest.json'), body)
  out(`[ script:cis_test] [cis_test] results: results_${id}.json + results_latest.json`)
}

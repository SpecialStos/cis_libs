// tools/ci-live.js end to end against test/ci/fake-fxserver.js: the deploy, the
// boot wait, the commit check, the tiers, the verdict, the shutdown and the
// redaction, with a fake in FXServer's place. Run under node --test.
//
// The fake stands where the Linux artifact's loader would be
// (alpine/opt/cfx-server/ld-musl-x86_64.so.1), so ci-live.js runs exactly the
// code path it runs in CI. That path does not exist on Windows, so neither
// does this test there.

'use strict'

const { describe, it, after } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawn } = require('child_process')

const root = path.join(__dirname, '..', '..')
// Obviously not a licence key; only the fake ever reads it.
const FAKE_KEY = 'fake0key0for0the0fake0server1'
// Every temp folder a run made, removed when the file is done.
const made = []

function fakeArtifact() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cis-fake-fx-'))
  made.push(dir)
  const srv = path.join(dir, 'alpine', 'opt', 'cfx-server')
  fs.mkdirSync(srv, { recursive: true })
  const loader = path.join(srv, 'ld-musl-x86_64.so.1')
  fs.writeFileSync(loader,
    `#!/bin/sh\nexec "${process.execPath}" "${path.join(__dirname, 'fake-fxserver.js')}" "$@"\n`, { mode: 0o755 })
  return dir
}

function run(scenario, extra) {
  const art = fakeArtifact()
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'cis-ci-work-'))
  made.push(work)
  const env = { ...process.env, FAKE_SCENARIO: scenario, FIVEM_LICENSE_KEY: FAKE_KEY }
  delete env.GITHUB_STEP_SUMMARY
  delete env.CIS_CI_OUT
  if (extra && extra.noKey) delete env.FIVEM_LICENSE_KEY
  const args = [path.join(root, 'tools', 'ci-live.js'), '--fxserver', art, '--work', work, '--quiet',
    '--boot-timeout', '20', '--tier-timeout', '20', '--timeout', '90', ...((extra && extra.args) || [])]
  return new Promise((resolve) => {
    const child = spawn(process.execPath, args, { cwd: root, env })
    let stdout = ''
    child.stdout.on('data', (d) => { stdout += d })
    child.stderr.on('data', (d) => { stdout += d })
    child.on('exit', (code) => {
      const outDir = path.join(work, 'out')
      const read = (f) => { try { return fs.readFileSync(path.join(outDir, f), 'utf8') } catch { return null } }
      resolve({
        code,
        stdout,
        work,
        summary: JSON.parse(read('summary.json') || 'null'),
        consoleLog: read('console.log'),
        outFiles: fs.existsSync(outDir) ? fs.readdirSync(outDir) : [],
      })
    })
  })
}

function noKeyAnywhere(r) {
  assert.ok(!r.stdout.includes(FAKE_KEY), 'the key is not in the job output')
  for (const f of r.outFiles) {
    assert.ok(!fs.readFileSync(path.join(r.work, 'out', f), 'utf8').includes(FAKE_KEY), `the key is not in out/${f}`)
  }
  assert.ok(!fs.existsSync(path.join(r.work, 'data', 'secrets.cfg')), 'secrets.cfg is gone after the run')
}

after(() => {
  for (const d of made) fs.rmSync(d, { recursive: true, force: true })
})

describe('ci-live against a fake FXServer', { concurrency: true, skip: process.platform === 'win32' }, () => {
  it('every tier passes: exit 0, two results files, the server quit on its own', async () => {
    const r = await run('pass')
    assert.equal(r.code, 0, r.stdout)
    assert.deepEqual(r.summary.tiers.map(t => [t.tier, t.ok]), [['server', true], ['lifecycle', true]])
    assert.equal(r.outFiles.filter(f => /^results_(server|lifecycle)_run-/.test(f)).length, 2)
    assert.match(r.stdout, /server stopped \(code 0/)
    assert.match(r.stdout, /RESULT: OK/)
    noKeyAnywhere(r)
  })

  it('a FAIL case fails the job with exit 1 and names the case', async () => {
    const r = await run('fail')
    assert.equal(r.code, 1, r.stdout)
    const life = r.summary.tiers.find(t => t.tier === 'lifecycle')
    assert.equal(life.ok, false)
    assert.deepEqual(life.failing.map(f => f.case), ['it leaks'])
    assert.match(r.stdout, /\[FAIL\] lifecycle :: it leaks/)
  })

  it('a SCRIPT ERROR at boot fails before any tier runs', async () => {
    const r = await run('script-error')
    assert.equal(r.code, 1, r.stdout)
    assert.equal(r.summary.tiers.length, 0)
    assert.match(r.stdout, /BOOT ERROR \(script-error\)/)
  })

  it('a preflight refusal fails the tier at once, not after the timeout', async () => {
    const started = Date.now()
    const r = await run('preflight', { args: ['--tiers', 'server'] })
    assert.equal(r.code, 1, r.stdout)
    assert.ok(r.summary.tiers[0].problems.some(p => /PREFLIGHT REFUSED/.test(p)))
    assert.ok(Date.now() - started < 18000, 'did not wait out the 20 s tier timeout')
  })

  it('an unlicensed boot is exit 3 with the server\'s own reason', async () => {
    const r = await run('unlicensed', { noKey: true, args: ['--probe'] })
    assert.equal(r.code, 3, r.stdout)
    assert.match(r.stdout, /does not have a license key specified/)
  })

  it('no key and no --probe: nothing is started, exit 3', async () => {
    const r = await run('pass', { noKey: true })
    assert.equal(r.code, 3)
    assert.match(r.stdout, /FIVEM_LICENSE_KEY is not set/)
  })

  it('a key the server prints is redacted from the uploaded log', async () => {
    const r = await run('echo-key', { args: ['--tiers', 'server'] })
    assert.equal(r.code, 0, r.stdout)
    assert.match(r.consoleLog, /using sv_licenseKey \*\*\*/)
    noKeyAnywhere(r)
  })
})

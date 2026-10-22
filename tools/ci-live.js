// The live harness on a real headless FXServer, in CI. No game client.
//
//   node tools/ci-live.js --fxserver <artifact dir> [options]
//
// Normally reached through tools/ci-fxserver.sh, which downloads, verifies and
// caches the artifact and then runs this. The licence key comes from the
// FIVEM_LICENSE_KEY environment variable and nowhere else.
//
// WHAT IT DOES, IN ORDER.
//   1. a fresh server data folder under --work (default: the OS temp dir)
//   2. deploy cis_libs and every harness resource into it with the SAME tool
//      the VPS uses (tools/live-deploy.js), pointed there by CIS_LIVE_ENV
//   3. write server.cfg (tools/ci-live-lib.js buildServerCfg) and, beside it,
//      a secrets.cfg holding only the licence key, mode 0600, never uploaded
//   4. start FXServer with stdin as its console and the log going to a file
//   5. wait for the boot: status.json written by cis_test, the providers'
//      config line, no licence error, no boot error in the console
//   6. the commit check from live-run: status.json must report the commit the
//      deploy wrote, and every ensured resource must be started
//   7. for each tier (default: server, lifecycle): `cis_test run <tier>` on
//      stdin, wait for a results_latest.json with a NEW run id, judge it
//   8. `quit`, then SIGTERM, then SIGKILL: the server is always shut down
//
// The console stands in for cis_ctl here. cis_ctl exists because the VPS
// console belongs to txAdmin; this process owns the server's stdin outright,
// which is the same source-0 console cis_ctl drives, with nothing in between.
//
// EXIT CODES. 0 every tier ran and nothing FAILed; 1 a case FAILed or ERRORed,
// a tier produced no usable results, or the console shows a script error;
// 2 the server did not boot, or the harness never came up, or a timeout;
// 3 no licence key, or the key was refused.
//
// OUTPUT, in --out: console.log (ANSI stripped, key redacted), one
// results_<tier>_<run>.json per tier, server.cfg, and summary.json. With
// GITHUB_STEP_SUMMARY set, a markdown summary is appended there as well.

'use strict'

const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawn, spawnSync } = require('child_process')

const lib = require('./ci-live-lib')
const liveEnv = require('./live-env')
const liveRun = require('./live-run')

const root = path.join(__dirname, '..')

// ------------------------------------------------------------------ options

function parseArgs(argv) {
  const o = {
    fxserver: process.env.CIS_FXSERVER_DIR || '',
    work: process.env.CIS_CI_WORK || path.join(os.tmpdir(), 'cis-ci-live'),
    out: process.env.CIS_CI_OUT || '',
    tiers: ['server', 'lifecycle'],
    port: 30120,
    bootTimeoutS: 180,
    tierTimeoutS: 300,
    totalTimeoutS: 780,
    gameBuild: process.env.CIS_CI_GAME_BUILD || '',
    ignoreResources: ['cis_test_badmeta'],
    allowPatterns: [],
    quiet: false,
    probe: false,
  }
  const a = argv.slice(2)
  const need = (i, flag) => {
    if (i + 1 >= a.length) throw new Error(`${flag} needs a value`)
    return a[i + 1]
  }
  for (let i = 0; i < a.length; i++) {
    const f = a[i]
    if (f === '--fxserver') o.fxserver = need(i, f), i++
    else if (f === '--work') o.work = need(i, f), i++
    else if (f === '--out') o.out = need(i, f), i++
    else if (f === '--tiers') o.tiers = need(i, f).split(',').map(s => s.trim()).filter(Boolean), i++
    else if (f === '--port') o.port = Number(need(i, f)), i++
    else if (f === '--boot-timeout') o.bootTimeoutS = Number(need(i, f)), i++
    else if (f === '--tier-timeout') o.tierTimeoutS = Number(need(i, f)), i++
    else if (f === '--timeout') o.totalTimeoutS = Number(need(i, f)), i++
    else if (f === '--game-build') o.gameBuild = need(i, f), i++
    else if (f === '--ignore-resource') o.ignoreResources.push(need(i, f)), i++
    else if (f === '--allow-line') o.allowPatterns.push(new RegExp(need(i, f))), i++
    else if (f === '--quiet') o.quiet = true
    else if (f === '--probe') o.probe = true
    else throw new Error(`unknown option ${f}`)
  }
  if (!o.fxserver) throw new Error('--fxserver <artifact dir> is required (or CIS_FXSERVER_DIR)')
  for (const t of o.tiers) {
    // The same character set cis_ctl allows, and for the same reason: this line
    // goes into a console.
    if (!/^[A-Za-z0-9_.:-]+$/.test(t)) throw new Error(`tier name ${JSON.stringify(t)} is not allowed`)
  }
  o.work = path.resolve(o.work)
  o.out = path.resolve(o.out || path.join(o.work, 'out'))
  o.fxserver = path.resolve(o.fxserver)
  return o
}

// ------------------------------------------------------------------ helpers

const sleep = (ms) => new Promise(r => setTimeout(r, ms))

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    return null
  }
}

class InfraError extends Error {
  constructor(msg, code) {
    super(msg)
    this.code = code || 2
  }
}

// The console log, read as it grows. FXServer writes it directly (the file is
// its stdout), so nothing in this process can stall the server by being slow
// to drain a pipe -- this only reads behind it.
class LogTail {
  constructor(file, onLine) {
    this.file = file
    this.offset = 0
    this.partial = ''
    this.lines = []
    this.onLine = onLine
  }

  poll() {
    let size
    try { size = fs.statSync(this.file).size } catch { return [] }
    if (size <= this.offset) return []
    const fd = fs.openSync(this.file, 'r')
    const buf = Buffer.alloc(size - this.offset)
    fs.readSync(fd, buf, 0, buf.length, this.offset)
    fs.closeSync(fd)
    this.offset = size
    const text = this.partial + buf.toString('utf8')
    const parts = text.split(/\r?\n/)
    this.partial = parts.pop()
    const fresh = parts.map(l => lib.stripAnsi(l))
    for (const l of fresh) {
      this.lines.push(l)
      if (this.onLine) this.onLine(l)
    }
    return fresh
  }

  since(index) {
    return this.lines.slice(index).join('\n')
  }

  all() {
    return this.lines.concat(this.partial ? [lib.stripAnsi(this.partial)] : []).join('\n')
  }
}

// ------------------------------------------------------------------ the run

async function main() {
  let opts
  try {
    opts = parseArgs(process.argv)
  } catch (e) {
    console.error('ci-live: ' + e.message)
    return 2
  }

  const key = (process.env.FIVEM_LICENSE_KEY || '').trim()
  if (!key && !opts.probe) {
    console.error('ci-live: FIVEM_LICENSE_KEY is not set. FXServer will not start without a')
    console.error('  licence key from https://portal.cfx.re. Nothing was run. (--probe starts')
    console.error('  the server anyway, to show how far an unlicensed boot gets.)')
    return 3
  }

  const fx = liveEnv.fxserverCommand(opts.fxserver)
  if (!fs.existsSync(fx.cmd)) {
    console.error(`ci-live: no FXServer in ${opts.fxserver} (looked for ${fx.cmd})`)
    return 2
  }

  const data = path.join(opts.work, 'data')
  const resourcesDir = path.join(data, 'resources')
  const rawLog = path.join(opts.work, 'console.raw.log')
  const summary = { tiers: [], consoleErrors: [], problems: [], exit: null }

  // ------------------------------------------------------------ 1. folders
  console.log(`[1/8] fresh server data folder: ${data}`)
  fs.rmSync(data, { recursive: true, force: true })
  fs.mkdirSync(resourcesDir, { recursive: true })
  fs.mkdirSync(opts.out, { recursive: true })
  fs.rmSync(rawLog, { force: true })

  // A server description for every live tool, so fx.js --log and friends work
  // against this server too. No secret in it, and the VPS's own .live-env.json
  // is not read: CIS_LIVE_ENV points the tools here instead.
  const envFile = path.join(opts.work, 'live-env.json')
  const env = {
    mode: 'local',
    resourcesDir,
    libDir: path.join(resourcesDir, 'cis_libs'),
    serverCfgPath: path.join(data, 'server.cfg'),
    serverLogPath: rawLog,
    artifactsDir: opts.fxserver,
    client: { mode: 'off' },
  }
  fs.writeFileSync(envFile, JSON.stringify(env, null, 2) + '\n')
  const toolEnv = { ...process.env, CIS_LIVE_ENV: envFile }
  for (const name of Object.values(liveEnv.OVERRIDES)) delete toolEnv[name]
  delete toolEnv.FIVEM_LICENSE_KEY

  // ------------------------------------------------------------- 2. deploy
  console.log('[2/8] deploy (tools/live-deploy.js)')
  const dep = spawnSync(process.execPath, [path.join(__dirname, 'live-deploy.js')], {
    cwd: root, encoding: 'utf8', env: toolEnv,
  })
  process.stdout.write(indent(dep.stdout || ''))
  if (dep.stderr) process.stderr.write(indent(dep.stderr))
  if (dep.status !== 0) {
    console.error(`ci-live: the deploy failed (exit ${dep.status}). Nothing was started.`)
    return 2
  }

  // --------------------------------------------------------- 3. server.cfg
  console.log('[3/8] server.cfg')
  const secretsFile = path.join(data, 'secrets.cfg')
  if (key) {
    try {
      fs.writeFileSync(secretsFile, lib.buildSecretsCfg(key), { mode: 0o600 })
    } catch (e) {
      console.error('ci-live: ' + e.message)
      return 3
    }
  }
  const cfg = lib.buildServerCfg({
    port: opts.port,
    gameBuild: opts.gameBuild,
    secretsFile: key ? 'secrets.cfg' : null,
  })
  fs.writeFileSync(path.join(data, 'server.cfg'), cfg)
  fs.writeFileSync(path.join(opts.out, 'server.cfg'), cfg)
  console.log(indent(cfg.split('\n').filter(l => l && !l.startsWith('#')).join('\n')))

  // -------------------------------------------------------------- 4. start
  console.log(`[4/8] start FXServer (${path.relative(opts.fxserver, fx.cmd) || fx.cmd})`)
  const logFd = fs.openSync(rawLog, 'a')
  const child = spawn(fx.cmd, [...fx.args, '+exec', 'server.cfg'], {
    cwd: data,
    stdio: ['pipe', logFd, logFd],
    env: { ...toolEnv },
  })
  fs.closeSync(logFd)
  let exited = null
  child.on('exit', (code, signal) => { exited = { code, signal } })
  child.on('error', (e) => { exited = { code: null, signal: null, error: e.message } })
  // EOF on stdin is "shut down" to FXServer, so the pipe stays open for the
  // whole run; a write after the server died is not worth a crash.
  child.stdin.on('error', () => {})
  // A cancelled job (or ^C) must not leave a server running behind it. The
  // finally block below does not run on a signal, so this does its job.
  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.once(sig, () => {
      console.error(`ci-live: ${sig}; killing the server`)
      try { child.kill('SIGKILL') } catch { /* already gone */ }
      try { fs.rmSync(secretsFile, { force: true }) } catch { /* best effort */ }
      process.exit(2)
    })
  }

  const send = (cmd) => {
    console.log(`  > ${cmd}`)
    child.stdin.write(cmd + '\n')
  }

  const tail = new LogTail(rawLog, opts.quiet ? null : (l) => console.log('  fx| ' + lib.redact(l, key)))

  const deadline = Date.now() + opts.totalTimeoutS * 1000
  // The licence check comes BEFORE the exit check. An unlicensed FXServer
  // prints its reason and then SIGTERMs itself within half a second (measured on
  // build 35245); reporting that as "exited during boot" would hide the one
  // line that says what to fix.
  const checkAlive = (where) => {
    tail.poll()
    // all(), not since(0): the last line may have no newline yet, and an
    // unlicensed server's last line is exactly the one that matters.
    const licence = lib.licenceProblem(tail.all())
    if (licence) throw new InfraError('the licence key was refused or is missing: ' + licence, 3)
    if (exited) {
      throw new InfraError(`FXServer exited during ${where} (code ${exited.code}, signal ${exited.signal}` +
        (exited.error ? `, ${exited.error}` : '') + ')')
    }
    if (Date.now() > deadline) throw new InfraError(`the whole run exceeded ${opts.totalTimeoutS}s`)
  }

  let code = 0
  try {
    // --------------------------------------------------------- 5. boot
    console.log(`[5/8] wait for the boot (up to ${opts.bootTimeoutS}s)`)
    const statusFile = path.join(resourcesDir, 'cis_test', 'status.json')
    const bootDeadline = Date.now() + opts.bootTimeoutS * 1000
    let configLine = null
    while (true) {
      checkAlive('boot')
      if (!configLine) {
        configLine = tail.lines.find(l => /\[cis_test_providers\] (config supplied|CONFIG REFUSED|cis_libs never started)/.test(l)) || null
      }
      if (configLine && fs.existsSync(statusFile)) break
      if (Date.now() > bootDeadline) {
        throw new InfraError(`no boot after ${opts.bootTimeoutS}s: ` +
          (fs.existsSync(statusFile) ? 'cis_test is up but the providers never reported their config'
            : 'cis_test never wrote status.json'))
      }
      await sleep(500)
    }
    if (!/config supplied/.test(configLine)) {
      throw new InfraError('the harness config was not applied: ' + configLine.trim())
    }
    // A moment for the last ensure's output and any late SCRIPT ERROR.
    await sleep(3000)
    checkAlive('boot')
    const bootErrors = lib.scanConsole(tail.since(0), scanOpts(opts))
    summary.consoleErrors.push(...bootErrors.map(e => ({ ...e, phase: 'boot' })))
    const fatalBoot = bootErrors.filter(e => !e.ignored)
    if (fatalBoot.length) {
      for (const e of fatalBoot) console.error(`  BOOT ERROR (${e.kind}) line ${e.lineNo}: ${lib.redact(e.line, key)}`)
      throw new InfraError(`${fatalBoot.length} error line(s) in the console during boot`, 1)
    }
    console.log('  booted: status.json written, config supplied, no boot errors')

    // --------------------------------------------------- 6. commit check
    console.log('[6/8] the running build is the one just deployed')
    send('cis_test status')
    await sleep(1500)
    checkAlive('the commit check')
    const want = liveRun.deployedCommit(env)
    const status = liveRun.readStatus(env)
    if (!want || !status) throw new InfraError('deploy.json or status.json is missing from cis_test')
    if (status.commit !== want.commit) {
      throw new InfraError(`the running harness reports commit ${status.commit}, the deploy wrote ${want.commit}`)
    }
    // cis_test is not in its own resources map; it wrote the file, so it runs.
    const notStarted = lib.ENSURE_ORDER.filter(r => r !== 'cis_test' && (status.resources || {})[r] !== 'started')
    if (notStarted.length) {
      throw new InfraError('not started: ' + notStarted.map(r => `${r}=${(status.resources || {})[r]}`).join(', '))
    }
    console.log(`  commit ${status.commit}, cis_libs ${status.cisLibsVersion}, ` +
      `${(status.suites || []).length} suite(s) registered, players ${status.playerCount}`)

    // ---------------------------------------------------------- 7. tiers
    for (const tier of opts.tiers) {
      console.log(`[7/8] cis_test run ${tier}`)
      const result = await runTier(tier, { send, tail, checkAlive, env, opts, key })
      summary.tiers.push(result.summary)
      if (!result.summary.ok) code = Math.max(code, 1)
    }
  } catch (e) {
    if (e instanceof InfraError) {
      console.error('ci-live: ' + lib.redact(e.message, key))
      summary.problems.push(lib.redact(e.message, key))
      code = Math.max(code, e.code)
    } else {
      console.error('ci-live: unexpected failure: ' + (e && e.stack ? e.stack : e))
      summary.problems.push(String(e && e.message ? e.message : e))
      code = Math.max(code, 2)
    }
  } finally {
    // ---------------------------------------------------------- 8. stop
    console.log('[8/8] shut the server down')
    await shutdown(child, () => exited, send)
    tail.poll()
    const cleaned = lib.redact(tail.all(), key)
    fs.writeFileSync(path.join(opts.out, 'console.log'), cleaned + '\n')
    try { fs.rmSync(secretsFile, { force: true }) } catch { /* best effort */ }
  }

  summary.exit = code
  fs.writeFileSync(path.join(opts.out, 'summary.json'), JSON.stringify(summary, null, 2) + '\n')
  printSummary(summary)
  writeStepSummary(summary)
  return code
}

// One tier: send, wait for a NEW run id, judge.
async function runTier(tier, ctx) {
  const { send, tail, checkAlive, env, opts, key } = ctx
  const latest = path.join(liveRun.cisTestDir(env), 'results_latest.json')
  const before = readJson(latest)
  const previousId = before && before.run

  // Run ids have one-second resolution (run-YYYYMMDD-HHMMSS). A tier started
  // in the same second the previous one finished would reuse its id, and the
  // wait below would never see a NEW one. A second and a bit rules that out.
  await sleep(1100)
  const fromLine = tail.lines.length
  send(`cis_test run ${tier}`)

  const s = { tier, ok: false, run: null, counts: {}, failing: [], skipped: [], problems: [], consoleErrors: [] }
  const tierDeadline = Date.now() + opts.tierTimeoutS * 1000
  let report = null
  while (true) {
    checkAlive(`the ${tier} tier`)
    const r = readJson(latest)
    if (r && r.run && r.run !== previousId) { report = r; break }
    const refusal = lib.harnessRefusal(tail.since(fromLine))
    if (refusal) { s.problems.push('cis_test refused the run: ' + refusal); break }
    if (Date.now() > tierDeadline) {
      s.problems.push(`no results after ${opts.tierTimeoutS}s`)
      break
    }
    await sleep(500)
  }
  // Late output from the run's own cleanups lands just after the file.
  await sleep(1000)
  tail.poll()

  const errs = lib.scanConsole(tail.since(fromLine), { ...scanOpts(opts), lineOffset: fromLine })
  s.consoleErrors = errs.map(e => ({ ...e, line: lib.redact(e.line, key) }))
  const fatal = errs.filter(e => !e.ignored)
  for (const e of fatal) s.problems.push(`console ${e.kind} at line ${e.lineNo}: ${lib.redact(e.line, key)}`)

  if (report) {
    const keep = path.join(opts.out, `results_${tier}_${report.run}.json`)
    fs.writeFileSync(keep, JSON.stringify(report, null, 2) + '\n')
    const v = lib.judgeReport(report)
    s.run = v.run
    s.counts = v.counts
    s.failing = v.failing.map(c => ({ suite: c.suite, case: c.case, status: c.status, msg: c.msg }))
    s.skipped = v.skipped.map(c => ({ suite: c.suite, case: c.case, status: c.status, why: c.skipReason || c.manual }))
    s.problems.push(...v.problems)
    console.log('')
    liveRun.summarise(report)
    if (s.skipped.length) {
      console.log(`  ${s.skipped.length} SKIP/MANUAL case(s) -- not a pass:`)
      for (const c of s.skipped) console.log(`    [${c.status}] ${c.suite} :: ${c.case}${c.why ? '  (' + c.why + ')' : ''}`)
    }
    console.log(`  results kept: ${keep}`)
  }
  s.ok = Boolean(report) && s.problems.length === 0 && s.failing.length === 0
  return { summary: s }
}

// `quit` first, because that is the server's own orderly shutdown; then the
// signals, because a server that is wedged (an unlicensed one is) ignores its
// console entirely.
async function shutdown(child, exitedFn, send) {
  if (exitedFn()) {
    const e = exitedFn()
    console.log(`  the server had already exited (code ${e.code}, signal ${e.signal})`)
    return
  }
  try { send('quit') } catch { /* the pipe may be gone */ }
  for (let i = 0; i < 30 && !exitedFn(); i++) await sleep(500)
  if (!exitedFn()) {
    console.log('  no exit after quit; SIGTERM')
    try { child.kill('SIGTERM') } catch { /* already gone */ }
    for (let i = 0; i < 10 && !exitedFn(); i++) await sleep(500)
  }
  if (!exitedFn()) {
    console.log('  no exit after SIGTERM; SIGKILL')
    try { child.kill('SIGKILL') } catch { /* already gone */ }
    for (let i = 0; i < 10 && !exitedFn(); i++) await sleep(500)
  }
  try { child.stdin.end() } catch { /* already gone */ }
  const e = exitedFn()
  console.log(`  server stopped (code ${e ? e.code : '?'}, signal ${e ? e.signal : '?'})`)
}

// What counts as an error line. --ignore-resource names a fixture that is broken
// on purpose; --allow-line is a regex for a line a real server prints that is
// not a fault (none known yet: add one here only with the line it excuses).
function scanOpts(opts) {
  return { ignoreResources: opts.ignoreResources, allowPatterns: opts.allowPatterns }
}

function indent(s) {
  return String(s).split('\n').map(l => (l ? '    ' + l : l)).join('\n')
}

function printSummary(summary) {
  console.log('')
  console.log('==================== live server tier (CI) ====================')
  for (const t of summary.tiers) {
    const c = t.counts || {}
    console.log(`${t.ok ? 'OK  ' : 'FAIL'} ${t.tier.padEnd(10)} run ${t.run || '-'}  ` +
      `pass ${c.pass || 0} fail ${c.fail || 0} error ${c.error || 0} skip ${c.skip || 0} manual ${c.manual || 0}`)
    for (const f of t.failing) console.log(`       [${f.status}] ${f.suite} :: ${f.case}${f.msg ? ' -- ' + f.msg : ''}`)
    for (const p of t.problems) console.log(`       ! ${p}`)
  }
  for (const p of summary.problems) console.log(`FAIL ${p}`)
  const ignored = summary.consoleErrors.filter(e => e.ignored)
    .concat(...summary.tiers.map(t => (t.consoleErrors || []).filter(e => e.ignored)))
  if (ignored.length) console.log(`(${ignored.length} console error line(s) from deliberately broken fixtures, not counted)`)
  console.log(summary.exit === 0 ? 'RESULT: OK, nothing failed.' : `RESULT: FAILED (exit ${summary.exit}).`)
}

function writeStepSummary(summary) {
  const file = process.env.GITHUB_STEP_SUMMARY
  if (!file) return
  const rows = ['### Live server tier (real FXServer, no client)', '',
    '| tier | result | run | pass | fail | error | skip | manual |', '|---|---|---|---|---|---|---|---|']
  for (const t of summary.tiers) {
    const c = t.counts || {}
    rows.push(`| ${t.tier} | ${t.ok ? 'OK' : '**FAIL**'} | ${t.run || '-'} | ${c.pass || 0} | ${c.fail || 0} | ` +
      `${c.error || 0} | ${c.skip || 0} | ${c.manual || 0} |`)
  }
  const lines = []
  for (const t of summary.tiers) {
    for (const f of t.failing) lines.push(`- **${t.tier}** [${f.status}] ${f.suite} :: ${f.case}`)
    for (const p of t.problems) lines.push(`- **${t.tier}** ${p}`)
  }
  for (const p of summary.problems) lines.push(`- ${p}`)
  try {
    fs.appendFileSync(file, rows.join('\n') + '\n\n' + (lines.length ? lines.join('\n') + '\n' : 'Nothing failed.\n'))
  } catch { /* a summary is a convenience */ }
}

if (require.main === module) {
  main().then(code => process.exit(code), (e) => {
    console.error('ci-live: ' + (e && e.stack ? e.stack : e))
    process.exit(2)
  })
}

module.exports = { parseArgs, LogTail }

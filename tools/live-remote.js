// The CisFiveM transport for the live harness: `.live-env.json` mode "cisfivem".
//
// CisFiveM is an Ubuntu box run by txAdmin, one server at a time, controlled
// through the root `fivem-*` commands over `ssh <host>` (vps-ops.md). Nothing
// here needs cis_ctl or a shared folder: every step is one SSH call.
//
//   deploy       a tar written by tools/tar.js, piped into
//                `fivem-deploy <server> <resource> <sha>`
//   console      `fivem-console <cmd>`, rcon on the box's own loopback
//   read         `cat` of a file in the deployed cis_test folder
//
// Framework-neutral on purpose: `server` names any of the four servers, so
// cis_bridge drives esx, qbcore and qbox with the same code.
//
// TWO REFUSALS BEFORE ANYTHING IS SENT.
//   * The agent lock (/tmp/cis-agent-vps.lock) must exist and name this run's
//     `lockOwner`. A lock held by `owner` means the owner is on the box.
//   * `fivem-active` must already be `server`. Switching restarts the box's
//     only running server, so it stays a separate, deliberate step.
//
// It never edits server.cfg. The harness ACE grants below go over rcon and
// are gone at the next restart.

const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')
const { tarBuffer } = require('./tar')

const root = path.join(__dirname, '..')

const SERVERS = ['cis_core', 'qbox', 'qbcore', 'esx']
const LOCK = '/tmp/cis-agent-vps.lock'

// cis_ctl is the Windows file-command bridge; over rcon it has no job.
const HARNESS = ['cis_test', 'cis_test_providers', 'cis_test_b', 'cis_test_c', 'cis_test_badmeta']

// What cis_test itself runs through ExecuteCommand (RUNBOOK.md, the ACE list),
// granted for this server process only.
const HARNESS_ACES = [
  'add_ace resource.cis_test command.ensure allow',
  'add_ace resource.cis_test command.stop allow',
  'add_ace resource.cis_test command.start allow',
  'add_ace resource.cis_test command.restart allow',
  'add_ace resource.cis_test command.refresh allow',
  'add_ace resource.cis_test command.cis_force_unregister allow',
  'add_ace resource.cis_test command.cis_audit allow',
]

// The convars the CI server.cfg sets (RUNBOOK.md, CI step 3; ci-live-lib.js).
// The VPS servers' own server.cfg has none of them, so they are set for this
// server process only, before cis_libs is ensured: without the supplier the
// fake providers claim no slot and the registry and lifecycle suites fail.
const HARNESS_CONVARS = [
  'set cis_config_supplier cis_test_providers',
  'set cis_authorized_resources cis_test,cis_test_providers,cis_test_c',
  'set cis_check_version false',
]

const DEFAULT_PLAYER_WAIT_MS = 5 * 60 * 1000

// Reads the remote fields from the loaded live env. Throws with a reason.
function remoteConfig(env) {
  const host = env.host || 'CisFiveM'
  const server = env.server || 'cis_core'
  if (!SERVERS.includes(server)) {
    throw new Error(`server must be one of ${SERVERS.join(', ')}; got "${server}"`)
  }
  if (!/^[A-Za-z0-9_.@-]+$/.test(host)) throw new Error(`host is not an ssh alias: "${host}"`)
  const lockOwner = env.lockOwner
  if (typeof lockOwner !== 'string' || !/^[a-z0-9_-]+$/.test(lockOwner) || lockOwner === 'owner') {
    throw new Error('lockOwner must name this agent (for example "libs"); "owner" is the owner\'s own lock')
  }
  const waitMin = Number(env.playerWaitMinutes)
  const playerWaitMs = Number.isFinite(waitMin) && waitMin > 0 ? Math.min(waitMin, 45) * 60000 : DEFAULT_PLAYER_WAIT_MS
  return { host, server, lockOwner, playerWaitMs }
}

function resourceDir(cfg, res) {
  return `/home/fivem/${cfg.server}/server/resources/[cis]/${res}`
}

function shq(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`
}

// A console command crosses a remote shell, so it is held to the characters
// the harness's own commands use. A comma separates the authorized list and is
// not special to the remote shell.
function safeCommand(cmd) {
  if (!/^[A-Za-z0-9_ .:,-]+$/.test(cmd)) throw new Error(`refusing console command with shell characters: ${cmd}`)
  return cmd
}

// run(argv, opts) -> { status, stdout, stderr }; injectable for tests.
function transport(cfg, run) {
  const exec = run || ((args, opts) => spawnSync('ssh', args, Object.assign({ encoding: 'utf8', maxBuffer: 64 << 20 }, opts)))
  function ssh(remote, input) {
    const r = exec(['-o', 'BatchMode=yes', cfg.host, remote], input !== undefined ? { input } : {})
    return { ok: r.status === 0, code: r.status, out: `${r.stdout || ''}${r.stderr || ''}`.trim() }
  }
  return {
    cfg,
    ssh,
    // null when free, else the owner file's text.
    lockOwner() {
      const r = ssh(`cat ${LOCK}/owner 2>/dev/null || { test -d ${LOCK} && echo '?'; }`)
      return r.out ? r.out.split('\n')[0].trim() : null
    },
    active() {
      const r = ssh('fivem-active')
      return r.ok ? r.out.split('\n')[0].trim() : null
    },
    console(cmd) {
      return ssh(`fivem-console ${safeCommand(cmd)}`)
    },
    readJson(res, file) {
      if (!/^[A-Za-z0-9_.-]+$/.test(file)) return null
      const r = ssh(`cat ${shq(`${resourceDir(cfg, res)}/${file}`)}`)
      if (!r.ok) return null
      try { return JSON.parse(r.out) } catch { return null }
    },
    // Every folder named cis_libs under the server's resources tree.
    libFolders() {
      const r = ssh(`find ${shq(`/home/fivem/${cfg.server}/server/resources`)} -maxdepth 4 -type d -name cis_libs`)
      return r.ok ? r.out.split('\n').map(s => s.trim()).filter(Boolean) : null
    },
    deploy(res, sha, entries) {
      if (!/^[a-z0-9_-]+$/.test(res) || !/^[A-Za-z0-9_.-]+$/.test(sha)) throw new Error('bad resource or sha')
      return ssh(`fivem-deploy ${cfg.server} ${res} ${sha}`, tarBuffer(entries))
    },
  }
}

// Both refusals, as one reason string, or null when clear to go.
function preflight(t) {
  const held = t.lockOwner()
  if (held === null) {
    return `the VPS lock is not held. Take it first:\n    ssh ${t.cfg.host} 'mkdir ${LOCK} && echo ${t.cfg.lockOwner} > ${LOCK}/owner'`
  }
  if (held !== t.cfg.lockOwner) {
    return `the VPS lock is held by "${held}", not "${t.cfg.lockOwner}". Leave the box alone.`
  }
  const active = t.active()
  if (active !== t.cfg.server) {
    return `the running server is "${active || 'none'}", not "${t.cfg.server}". Switch first (it restarts the box's server):\n` +
      `    ssh ${t.cfg.host} 'fivem-switch ${t.cfg.server}'`
  }
  return null
}

function walk(dir, acc = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name)
    if (e.isDirectory()) walk(full, acc)
    else acc.push(full)
  }
  return acc
}

function stamp(info, extra) {
  return { name: 'deploy.json', data: JSON.stringify(Object.assign({}, info, extra), null, 2) + '\n' }
}

// The entries for cis_libs and each harness resource, built locally. Same file
// set as live-deploy.js: the release set from fxmanifest, the harness folders
// whole, a deploy.json in each.
function buildEntries(info, timestamp) {
  const { releaseFileSet } = require('./release-files')
  const { files, missing } = releaseFileSet(root)
  if (missing.length) throw new Error('the manifest names files that are not on disk: ' + missing.join(', '))
  const out = [{
    res: 'cis_libs',
    entries: files.map(rel => ({ name: rel.replace(/\\/g, '/'), data: fs.readFileSync(path.join(root, rel)) }))
      .concat([stamp(info, { timestamp, files: files.length })]),
  }]
  for (const res of HARNESS) {
    const src = path.join(root, 'test', 'live', res)
    if (!fs.existsSync(src)) continue
    out.push({
      res,
      entries: walk(src).map(f => ({ name: path.relative(src, f).replace(/\\/g, '/'), data: fs.readFileSync(f) }))
        .concat([stamp(info, { timestamp })]),
    })
  }
  return out
}

// Deploys everything; returns lines to print. Throws on the first refusal.
function deployAll(t, info, timestamp) {
  const folders = t.libFolders()
  if (folders === null) throw new Error('could not list the server resources tree')
  const ours = resourceDir(t.cfg, 'cis_libs')
  const foreign = folders.filter(f => f !== ours)
  if (foreign.length) {
    throw new Error(`another cis_libs folder is in the resources tree; FiveM would load one of them:\n    ${foreign.join('\n    ')}`)
  }
  const lines = []
  const sha = info.dirty ? `${info.commit}-dirty` : info.commit
  for (const { res, entries } of buildEntries(info, timestamp)) {
    const r = t.deploy(res, sha, entries)
    if (!r.ok) throw new Error(`fivem-deploy ${res} failed (exit ${r.code}): ${r.out}`)
    lines.push(`  ${res}: ${entries.length} files`)
  }
  return lines
}

// fivem-console speaks UDP rcon and exits 0 with "(no reply)" when nothing
// came back, so a datagram that never arrived reads as success.
// run-20261024-112628 lost `ensure cis_test_b` exactly that way: the server
// logged no "Rcon from" for it, the resource never started, and a suite ERRORed
// on a missing export three minutes later. So a stop is resent while nothing
// answers, and an ensure must answer "Started resource <name>" -- which also
// catches a lost stop, since ensuring a resource still running prints nothing.
const CONSOLE_ATTEMPTS = 3

function consoleChecked(t, cmd, sleep) {
  const m = /^(stop|ensure) ([A-Za-z0-9_-]+)$/.exec(cmd)
  let r
  for (let attempt = 1; attempt <= CONSOLE_ATTEMPTS; attempt++) {
    r = t.console(cmd)
    if (!r.ok) return Object.assign({ attempts: attempt }, r)
    const silent = r.out === '' || r.out === '(no reply)'
    if (!m) return Object.assign({ attempts: attempt }, r)
    if (m[1] === 'stop' && !silent) return Object.assign({ attempts: attempt }, r)
    if (m[1] === 'ensure' && new RegExp(`Started resource ${m[2]}(?![A-Za-z0-9_-])`).test(r.out)) return Object.assign({ attempts: attempt }, r)
    if (attempt < CONSOLE_ATTEMPTS && sleep) sleep(1000)
  }
  if (m[1] === 'stop') return Object.assign({ attempts: CONSOLE_ATTEMPTS }, r)
  return {
    ok: false, code: r.code, attempts: CONSOLE_ATTEMPTS,
    out: `${r.out}\n  "${cmd}" never answered "Started resource ${m[2]}" in ${CONSOLE_ATTEMPTS} attempts`,
  }
}

module.exports = {
  SERVERS, HARNESS, HARNESS_ACES, HARNESS_CONVARS, LOCK,
  remoteConfig, resourceDir, transport, preflight, buildEntries, deployAll, safeCommand, shq,
  consoleChecked, CONSOLE_ATTEMPTS,
}

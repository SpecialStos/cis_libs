// Starting and stopping the FiveM client. W5.
//
//   node tools/client.js start
//   node tools/client.js stop
//
// Three modes, read from .live-env.json's `client` block, and the difference
// between them is the difference between "the player tier ran" and "the player
// tier SKIPped":
//
//   local  the client is on this machine. Only possible with a real GPU --
//          GTA V will not run on software rendering, which is why the VPS (a
//          Microsoft Remote Display Adapter, no GPU) cannot do this.
//   ssh    the client is on another machine, reached over Tailscale, controlled
//          through two scheduled tasks. An SSH session cannot open a window on
//          someone's desktop, so this runs scheduled tasks set to "run only
//          when user is logged on" rather than the commands themselves.
//   off    no client at all. Every tier that needs a player SKIPs with a reason.
//          This is a real state, not an error: it is what the box looks like
//          before a client machine exists, and the run must report the SKIP
//          honestly rather than quietly omitting the tier.
//
// The client is the one part of the harness that touches a real person's
// session, so nothing here ever kills anything by pattern unless that pattern
// is FiveM's own process name, and nothing here restarts the server.

const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')

const root = path.join(__dirname, '..')
const ENV = path.join(root, '.live-env.json')

// The process name FiveM runs under. Stopping is scoped to this and nothing
// else -- a Stop-Process with a wider pattern is how a test harness takes a
// desktop with it.
const FIVEM_PROCESS = 'FiveM*'

function loadClientConfig(envPath) {
  const p = envPath || ENV
  if (!fs.existsSync(p)) {
    return { mode: 'off', _why: '.live-env.json is missing, so no client mode is known' }
  }
  let env
  try {
    env = JSON.parse(fs.readFileSync(p, 'utf8'))
  } catch (e) {
    return { mode: 'off', _why: '.live-env.json is not valid JSON: ' + e.message }
  }
  const c = env.client || {}
  return Object.assign({ mode: 'off' }, c)
}

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
}

// Both modes are one-shot and give no useful output; this waits long enough for
// a slow ssh handshake and short enough that live:run does not feel broken.
const RUN_TIMEOUT_MS = 60000

function run(cmd, args) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', timeout: RUN_TIMEOUT_MS, windowsHide: true })
  return {
    ok: !r.error && r.status === 0,
    code: r.status,
    stdout: (r.stdout || '').trim(),
    stderr: (r.stderr || '').trim(),
    error: r.error ? r.error.message : null,
  }
}

function start(cfg) {
  if (cfg.mode === 'off') {
    return { ok: true, skipped: true, why: 'client.mode is "off": no client is configured' }
  }

  if (cfg.mode === 'local') {
    const target = cfg.connect || '127.0.0.1:30120'
    const r = run('powershell.exe', [
      '-NoProfile', '-Command', `Start-Process 'fivem://connect/${target}'`,
    ])
    return {
      ok: r.ok,
      mode: 'local',
      detail: r.ok ? `launching the client onto ${target}` : (r.stderr || r.error || `exit ${r.code}`),
    }
  }

  if (cfg.mode === 'ssh') {
    if (!cfg.host || !cfg.user || !cfg.key) {
      return {
        ok: false, mode: 'ssh',
        detail: 'client.mode is "ssh" but host/user/key are not all set in .live-env.json',
      }
    }
    // The remote command stays inside ONE quoted string. Broken across quotes,
    // the local shell eats it and the scheduled task runs against nothing.
    const task = 'CisFiveMStart'
    const r = run('ssh', [
      '-i', cfg.key,
      '-o', 'BatchMode=yes',
      `${cfg.user}@${cfg.host}`,
      `schtasks /run /tn ${task}`,
    ])
    return {
      ok: r.ok,
      mode: 'ssh',
      detail: r.ok ? `ran ${task} on ${cfg.user}@${cfg.host}` : (r.stderr || r.error || `exit ${r.code}`),
    }
  }

  return {
    ok: false,
    detail: `client.mode is "${cfg.mode}", which is not one of local, ssh, off`,
  }
}

function stop(cfg) {
  if (cfg.mode === 'off') return { ok: true, skipped: true }

  if (cfg.mode === 'local') {
    const r = run('powershell.exe', [
      '-NoProfile', '-Command',
      `Get-Process ${FIVEM_PROCESS} -ErrorAction SilentlyContinue | Stop-Process -Force`,
    ])
    // Nothing running is the desired end state, and PowerShell says so with a
    // non-zero exit when Get-Process matches nothing. That is not a failure.
    const alreadyGone = /cannot find|No process|not found/i.test(r.stderr || '')
    return {
      ok: r.ok || alreadyGone,
      mode: 'local',
      detail: r.ok ? 'client stopped' : (alreadyGone ? 'no client was running' : (r.stderr || `exit ${r.code}`)),
    }
  }

  if (cfg.mode === 'ssh') {
    if (!cfg.host || !cfg.user || !cfg.key) {
      return { ok: false, mode: 'ssh', detail: 'ssh mode needs host/user/key in .live-env.json' }
    }
    const r = run('ssh', [
      '-i', cfg.key,
      '-o', 'BatchMode=yes',
      `${cfg.user}@${cfg.host}`,
      'schtasks /run /tn CisFiveMStop',
    ])
    return {
      ok: r.ok,
      mode: 'ssh',
      detail: r.ok ? 'ran CisFiveMStop' : (r.stderr || r.error || `exit ${r.code}`),
    }
  }

  return { ok: false, detail: `client.mode is "${cfg.mode}", which is not one of local, ssh, off` }
}

// Waits for a client to actually appear. FiveM takes tens of seconds to get
// from a double-click to a connected player, so "the process started" is not
// the same answer as "a player is connected" -- which is why the caller polls
// status.json and this only reports whether the launch was issued.
function startAndSettle(cfg, seconds) {
  const r = start(cfg)
  if (!r.ok || r.skipped) return r
  sleep(Math.max(0, seconds || 0) * 1000)
  return r
}

module.exports = { loadClientConfig, start, stop, startAndSettle, run, sleep }

if (require.main === module) {
  const action = process.argv[2]
  if (action !== 'start' && action !== 'stop') {
    console.error('usage: node tools/client.js start|stop')
    process.exit(2)
  }
  const cfg = loadClientConfig()
  if (cfg._why) console.error('client: ' + cfg._why)
  const res = action === 'start' ? start(cfg) : stop(cfg)
  const verb = res.skipped ? 'SKIP' : res.ok ? 'OK  ' : 'FAIL'
  console.log(`${verb} client ${action} [${cfg.mode}] ${res.detail || ''}`)
  process.exit(res.ok ? 0 : 1)
}
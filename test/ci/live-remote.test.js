// `npm run test:ci`: the CisFiveM transport (tools/live-remote.js), the tar it
// pipes into fivem-deploy (tools/tar.js) and live:run's argument parsing,
// pinned with a fake ssh. No network, no VPS. Run under node --test.

'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')

const remote = require('../../tools/live-remote')
const { tarBuffer, untar } = require('../../tools/tar')
const { parseArgs } = require('../../tools/live-run')

// A fake ssh: `answer(remoteCmd, input)` returns { status, stdout }. Every call
// is recorded as { argv, remote, input }.
function fakeSsh(answer) {
  const calls = []
  const run = (argv, opts) => {
    const cmd = argv[argv.length - 1]
    calls.push({ argv, remote: cmd, input: opts && opts.input })
    const r = answer(cmd, opts && opts.input) || {}
    return { status: r.status === undefined ? 0 : r.status, stdout: r.stdout || '', stderr: r.stderr || '' }
  }
  return { run, calls }
}

const CFG = remote.remoteConfig({ lockOwner: 'libs' })

// ---------------------------------------------------------------------- tar

test('tar round-trips names, bytes and long paths', () => {
  const long = 'a/'.repeat(60) + 'file.lua'
  const entries = [
    { name: 'fxmanifest.lua', data: "fx_version 'cerulean'\n" },
    { name: 'web/x.bin', data: Buffer.from([0, 1, 2, 255]) },
    { name: long, data: 'x'.repeat(1025) },
    { name: 'empty.txt', data: '' },
  ]
  const buf = tarBuffer(entries, 1700000000)
  assert.equal(buf.length % 512, 0)
  const back = untar(buf)
  assert.deepEqual(back.map(e => e.name), entries.map(e => e.name))
  assert.deepEqual(back[1].data, Buffer.from([0, 1, 2, 255]))
  assert.equal(back[2].data.toString(), 'x'.repeat(1025))
  assert.equal(back[3].data.length, 0)
})

test('tar is byte-identical for the same input and mtime', () => {
  const e = [{ name: 'a.lua', data: 'return 1' }]
  assert.deepEqual(tarBuffer(e, 1), tarBuffer(e, 1))
})

test('tar refuses a path that could leave the folder it is unpacked into', () => {
  for (const name of ['/etc/passwd', '../x.lua', 'a/../../x', 'a\\..\\x', '']) {
    assert.throws(() => tarBuffer([{ name, data: 'x' }], 1), /unsafe path/, name)
  }
})

test('tar refuses a name ustar cannot hold', () => {
  assert.throws(() => tarBuffer([{ name: 'x'.repeat(101), data: '' }], 1), /too long/)
})

test('untar notices a corrupted header', () => {
  const buf = tarBuffer([{ name: 'a.lua', data: 'x' }], 1)
  buf[0] = 'b'.charCodeAt(0)
  assert.throws(() => untar(buf), /bad checksum/)
})

// ------------------------------------------------------------------- config

test('remoteConfig defaults to cis_core on CisFiveM with a 5 minute wait', () => {
  assert.deepEqual(CFG, { host: 'CisFiveM', server: 'cis_core', lockOwner: 'libs', playerWaitMs: 300000 })
})

test('remoteConfig takes every framework server, so the bridge drives the same code', () => {
  for (const server of ['cis_core', 'esx', 'qbcore', 'qbox']) {
    assert.equal(remote.remoteConfig({ server, lockOwner: 'bridge' }).server, server)
  }
})

test('remoteConfig refuses an unknown server, a missing owner and the owner\'s own lock', () => {
  assert.throws(() => remote.remoteConfig({ server: 'prod', lockOwner: 'libs' }), /server must be one of/)
  assert.throws(() => remote.remoteConfig({}), /lockOwner/)
  assert.throws(() => remote.remoteConfig({ lockOwner: 'owner' }), /lockOwner/)
  assert.throws(() => remote.remoteConfig({ lockOwner: 'libs; rm -rf /' }), /lockOwner/)
  assert.throws(() => remote.remoteConfig({ lockOwner: 'libs', host: 'a b' }), /ssh alias/)
})

test('the player wait is capped at the 45 minute lock budget', () => {
  assert.equal(remote.remoteConfig({ lockOwner: 'libs', playerWaitMinutes: '45' }).playerWaitMs, 45 * 60000)
  assert.equal(remote.remoteConfig({ lockOwner: 'libs', playerWaitMinutes: 600 }).playerWaitMs, 45 * 60000)
  assert.equal(remote.remoteConfig({ lockOwner: 'libs', playerWaitMinutes: 'x' }).playerWaitMs, 300000)
  assert.equal(remote.remoteConfig({ lockOwner: 'libs', playerWaitMinutes: -1 }).playerWaitMs, 300000)
})

// ------------------------------------------------------------------ console

test('console commands with shell characters never reach ssh', () => {
  const ssh = fakeSsh(() => ({}))
  const t = remote.transport(CFG, ssh.run)
  for (const cmd of ['stop x; reboot', 'a && b', 'a $(id)', 'a`id`', "a'b", 'a|b', 'a\nb']) {
    assert.throws(() => t.console(cmd), /shell characters/, JSON.stringify(cmd))
  }
  assert.equal(ssh.calls.length, 0)
  t.console('cis_test run all')
  t.console('add_ace resource.cis_test command.cis_force_unregister allow')
  assert.deepEqual(ssh.calls.map(c => c.remote), [
    'fivem-console cis_test run all',
    'fivem-console add_ace resource.cis_test command.cis_force_unregister allow',
  ])
})

test('every ssh call is non-interactive and goes to the configured host', () => {
  const ssh = fakeSsh(() => ({}))
  remote.transport(CFG, ssh.run).active()
  assert.deepEqual(ssh.calls[0].argv.slice(0, 3), ['-o', 'BatchMode=yes', 'CisFiveM'])
})

test('the harness ACE and sequence lines all pass the console filter', () => {
  for (const cmd of remote.HARNESS_ACES.concat(remote.HARNESS_CONVARS)) assert.equal(remote.safeCommand(cmd), cmd)
  assert.ok(!remote.HARNESS.includes('cis_ctl'), 'cis_ctl is the Windows bridge; rcon replaces it')
})

test('the harness convars match the CI server.cfg', () => {
  const cfg = require('../../tools/ci-live-lib.js').buildServerCfg({})
  const ciSets = cfg.split('\n').filter((l) => /^set cis_/.test(l)).map((l) => l.replace(/"/g, ''))
  assert.deepEqual(remote.HARNESS_CONVARS, ciSets)
})

test('a semicolon, quote or substitution is still refused after commas were allowed', () => {
  for (const bad of ['set a b;rm', 'set a "b"', 'set a $(id)', 'set a `id`', 'set a b|c', 'set a b&c']) {
    assert.throws(() => remote.safeCommand(bad))
  }
})

// --------------------------------------------------------------- preflight

function box({ lock, active }) {
  return fakeSsh(cmd => {
    if (cmd.startsWith('cat /tmp/cis-agent-vps.lock/owner')) return { stdout: lock === null ? '' : lock + '\n' }
    if (cmd === 'fivem-active') return { stdout: active + '\n' }
    return {}
  })
}

test('preflight refuses when nobody holds the lock, and prints the take command', () => {
  const why = remote.preflight(remote.transport(CFG, box({ lock: null, active: 'cis_core' }).run))
  assert.match(why, /not held/)
  assert.match(why, /mkdir \/tmp\/cis-agent-vps\.lock && echo libs/)
})

test('preflight refuses a lock held by someone else, the owner above all', () => {
  for (const lock of ['owner', 'bridge', '?']) {
    const ssh = box({ lock, active: 'cis_core' })
    assert.match(remote.preflight(remote.transport(CFG, ssh.run)), new RegExp(`held by "\\${lock[0]}`))
    assert.ok(!ssh.calls.some(c => c.remote === 'fivem-active'), 'a foreign lock stops before anything else is asked')
  }
})

test('preflight refuses the wrong running server and never switches it', () => {
  const ssh = box({ lock: 'libs', active: 'esx' })
  const why = remote.preflight(remote.transport(CFG, ssh.run))
  assert.match(why, /running server is "esx", not "cis_core"/)
  assert.match(why, /fivem-switch cis_core/)
  assert.ok(!ssh.calls.some(c => /fivem-switch/.test(c.remote)))
})

test('preflight clears with our lock on the right server', () => {
  assert.equal(remote.preflight(remote.transport(CFG, box({ lock: 'libs', active: 'cis_core' }).run)), null)
})

// ------------------------------------------------------------- read, deploy

test('readJson reads from the deployed resource folder, quoted, and parses', () => {
  const ssh = fakeSsh(() => ({ stdout: '{"playerConnected":true}' }))
  const t = remote.transport(CFG, ssh.run)
  assert.deepEqual(t.readJson('cis_test', 'status.json'), { playerConnected: true })
  assert.equal(ssh.calls[0].remote, "cat '/home/fivem/cis_core/server/resources/[cis]/cis_test/status.json'")
})

test('readJson is null on a missing file, bad JSON or a path-like name', () => {
  const t1 = remote.transport(CFG, fakeSsh(() => ({ status: 1 })).run)
  assert.equal(t1.readJson('cis_test', 'status.json'), null)
  const t2 = remote.transport(CFG, fakeSsh(() => ({ stdout: '{half' })).run)
  assert.equal(t2.readJson('cis_test', 'status.json'), null)
  const ssh = fakeSsh(() => ({ stdout: '{}' }))
  assert.equal(remote.transport(CFG, ssh.run).readJson('cis_test', '../../etc/x'), null)
  assert.equal(ssh.calls.length, 0)
})

test('deploy pipes a tar into fivem-deploy <server> <resource> <sha>', () => {
  const ssh = fakeSsh(() => ({}))
  const t = remote.transport(CFG, ssh.run)
  t.deploy('cis_libs', 'abc1234-dirty', [{ name: 'fxmanifest.lua', data: 'x' }])
  assert.equal(ssh.calls[0].remote, 'fivem-deploy cis_core cis_libs abc1234-dirty')
  assert.deepEqual(untar(ssh.calls[0].input).map(e => e.name), ['fxmanifest.lua'])
  assert.throws(() => t.deploy('cis libs', 'a', []), /bad resource/)
  assert.throws(() => t.deploy('cis_libs', 'a;b', []), /bad resource or sha/)
})

test('buildEntries ships fxmanifest at the root of cis_libs and every harness folder', () => {
  const info = { commit: 'abc1234', branch: 'b', dirty: false }
  const sets = remote.buildEntries(info, 'T')
  assert.equal(sets[0].res, 'cis_libs')
  for (const s of sets) {
    const names = s.entries.map(e => e.name)
    assert.ok(names.includes('fxmanifest.lua'), `${s.res} has fxmanifest.lua at its root`)
    assert.ok(names.includes('deploy.json'), `${s.res} has deploy.json`)
    assert.ok(names.every(n => !n.includes('\\')), `${s.res} uses / only`)
    assert.equal(JSON.parse(s.entries.find(e => e.name === 'deploy.json').data).commit, 'abc1234')
  }
  assert.ok(sets.some(s => s.res === 'cis_test'))
  assert.ok(!sets.some(s => s.res === 'cis_ctl'))
})

test('deployAll refuses a second cis_libs folder before sending anything', () => {
  const ssh = fakeSsh(cmd => cmd.startsWith('find ')
    ? { stdout: '/home/fivem/cis_core/server/resources/[cis]/cis_libs\n/home/fivem/cis_core/server/resources/[old]/cis_libs\n' }
    : {})
  const t = remote.transport(CFG, ssh.run)
  assert.throws(() => remote.deployAll(t, { commit: 'a', dirty: false }, 'T'), /another cis_libs folder/)
  assert.ok(!ssh.calls.some(c => c.remote.startsWith('fivem-deploy')))
})

test('deployAll marks a dirty tree in the sha and stops at the first refusal', () => {
  const ssh = fakeSsh(cmd => {
    if (cmd.startsWith('find ')) return { stdout: '' }
    if (cmd.includes(' cis_test_providers ')) return { status: 3, stdout: 'no' }
    return {}
  })
  const t = remote.transport(CFG, ssh.run)
  assert.throws(() => remote.deployAll(t, { commit: 'abc', dirty: true }, 'T'), /fivem-deploy cis_test_providers failed \(exit 3\)/)
  const deploys = ssh.calls.filter(c => c.remote.startsWith('fivem-deploy')).map(c => c.remote)
  assert.equal(deploys[0], 'fivem-deploy cis_core cis_libs abc-dirty')
  assert.equal(deploys[deploys.length - 1], 'fivem-deploy cis_core cis_test_providers abc-dirty')
})

// ------------------------------------------------------------------ live:run

test('live:run takes one tier and the two flags, and refuses anything else', () => {
  assert.deepEqual(parseArgs([]), { tier: 'all', deployOnly: false, noDeploy: false })
  assert.deepEqual(parseArgs(['player', '--no-deploy']), { tier: 'player', deployOnly: false, noDeploy: true })
  assert.deepEqual(parseArgs(['--deploy-only']), { tier: 'all', deployOnly: true, noDeploy: false })
  assert.throws(() => parseArgs(['--force']), /unknown flag/)
  assert.throws(() => parseArgs(['--deploy-only', '--no-deploy']), /together/)
})

#!/usr/bin/env node
'use strict';

// A console the agent can drive without the txAdmin web UI.
//
// The txAdmin console needs a password the agent does not have and must not
// read. FXServer reads commands from its own stdin and runs them with source
// 0, which is exactly what the txAdmin console does -- so this attaches to
// stdin instead of to a browser.
//
// It changes nothing that belongs to the owner: no server.cfg, no txAdmin
// setting, no registry, no firewall. It only supplies a stdin to a process this
// script starts itself.
//
//   node tools/console-bridge.js serve            # start the server, stay up
//   node tools/console-bridge.js send "refresh"   # run one console command
//   node tools/console-bridge.js status           # is the server up?
//   node tools/console-bridge.js log [n]          # tail the console output

const fs = require('fs');
const path = require('path');
const net = require('net');
const { spawn } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const ENV_PATH = path.join(ROOT, '.live-env.json');
const DIR = path.join(ROOT, 'test', 'live', '.console');

const INBOX = path.join(DIR, 'inbox.txt');
const HISTORY = path.join(DIR, 'history.txt');
const LOG = path.join(DIR, 'console.log');

function env() {
  try {
    return JSON.parse(fs.readFileSync(ENV_PATH, 'utf8'));
  } catch (e) {
    return {};
  }
}

function artifactsDir() {
  const e = env();
  if (e.artifactsDir) return e.artifactsDir;
  // resourcesDir is .../FiveMBasicServerCFXDefault_XXX.base/resources/[standalone]
  // so the artifacts folder sits beside the profile base, four levels up.
  const rd = e.resourcesDir;
  if (!rd) throw new Error('no artifactsDir or resourcesDir in .live-env.json');
  return path.resolve(rd, '..', '..', '..', '..', 'artifacts');
}

// The folder holding server.cfg. txAdmin normally spawns the game server from
// here; running it from here directly is what puts this script's stdin on the
// server console instead of on txAdmin's parent process.
function baseDir() {
  const e = env();
  if (e.serverCfgPath) return path.dirname(e.serverCfgPath);
  throw new Error('no serverCfgPath in .live-env.json');
}

function stamp() {
  return new Date().toISOString().replace('T', ' ').slice(0, 19);
}

function ensureDir() {
  fs.mkdirSync(DIR, { recursive: true });
  for (const f of [INBOX, HISTORY, LOG]) if (!fs.existsSync(f)) fs.writeFileSync(f, '');
}

function record(line) {
  fs.appendFileSync(HISTORY, `${stamp()}  ${line}\n`);
}

function waitForPort(port, ms) {
  const deadline = Date.now() + ms;
  return new Promise((resolve, reject) => {
    const tick = () => {
      const s = net.connect({ port, host: '127.0.0.1' }, () => {
        s.destroy();
        resolve(true);
      });
      s.on('error', () => {
        s.destroy();
        if (Date.now() > deadline) reject(new Error(`port ${port} never opened`));
        else setTimeout(tick, 500);
      });
    };
    tick();
  });
}

// ---------------------------------------------------------------- serve

async function serve() {
  ensureDir();
  const art = artifactsDir();
  const base = baseDir();
  const exe = path.join(art, 'FXServer.exe');
  if (!fs.existsSync(exe)) throw new Error(`no FXServer.exe in ${art}`);
  if (!fs.existsSync(path.join(base, 'server.cfg'))) {
    throw new Error(`no server.cfg in ${base}`);
  }

  const out = fs.createWriteStream(LOG, { flags: 'a' });
  // The owner's own server.cfg, executed as-is. Nothing is appended to it and
  // nothing is written into it.
  const child = spawn(exe, ['+exec', 'server.cfg'], {
    cwd: base,
    stdio: ['pipe', 'pipe', 'pipe'],
    windowsHide: true,
  });
  fs.writeFileSync(path.join(DIR, 'pid'), String(child.pid));

  const pipe = (chunk) => {
    const text = chunk.toString();
    out.write(text);
    process.stdout.write(text);
  };
  child.stdout.on('data', pipe);
  child.stderr.on('data', pipe);

  // Keep stdin open for the life of the server. FXServer treats stdin EOF as
  // "shut down", so the pipe is never ended.
  child.stdin.on('error', () => {});

  child.on('exit', (code) => {
    record(`server exited with ${code}`);
    process.exit(code === null ? 1 : code);
  });

  // Anything appended to the inbox is a console command. An empty line is
  // ignored; a line starting with # is a comment, so a half-written file can
  // never become a command.
  let offset = fs.statSync(INBOX).size;
  record('bridge up');
  setInterval(() => {
    let size;
    try {
      size = fs.statSync(INBOX).size;
    } catch (e) {
      return;
    }
    if (size <= offset) return;
    const fd = fs.openSync(INBOX, 'r');
    const buf = Buffer.alloc(size - offset);
    fs.readSync(fd, buf, 0, buf.length, offset);
    fs.closeSync(fd);
    offset = size;
for (const raw of buf.toString().split('\n')) {
      const line = raw.trim();
      if (!line || line.startsWith('#')) continue;
      // The leading [tag] is the acknowledgement handle, not part of the
      // command. FiveM would otherwise read "[cmut...]" as the command name.
      const cmd = line.replace(/^\[[^\]]+\]\s*/, '');
      if (!cmd) continue;
      try {
        child.stdin.write(`${cmd}\n`);
        record(`> ${line}`);
      } catch (e) {
        record(`! refused ${cmd}: ${e.message}`);
      }
    }
  }, 400);

  process.on('SIGINT', () => child.kill());
  process.on('SIGTERM', () => child.kill());
}

// ---------------------------------------------------------------- send

function send(cmd) {
  ensureDir();
  if (!cmd || !cmd.trim()) throw new Error('empty command');
  const line = cmd.trim();
  const id = `c${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
  const tag = `[${id}]`;
  fs.appendFileSync(INBOX, `${tag} ${line}\n`);
  record(`${tag} ${line}`);

  // The bridge appends `> <tag> <line>` to the history once it has written the
  // command into the server's stdin. That echo is the acknowledgement: it is
  // written only after the write succeeded.
  const started = Date.now();
  return new Promise((resolve) => {
    const poll = setInterval(() => {
      let seen = false;
      try {
        const h = fs.readFileSync(HISTORY, 'utf8');
        const lines = h.split('\n').filter((l) => l.includes(tag));
        seen = lines.some((l) => l.includes(`> ${tag}`));
      } catch (e) {
        /* bridge still coming up */
      }
      if (seen) {
        clearInterval(poll);
        resolve(0);
      } else if (Date.now() - started > 20000) {
        clearInterval(poll);
        console.error(`bridge did not answer for ${tag} in 20s`);
        process.exit(2);
      }
    }, 200);
  });
}

// ---------------------------------------------------------------- status / log

async function status() {
  let pid = 0;
  try {
    pid = parseInt(fs.readFileSync(path.join(DIR, 'pid'), 'utf8').trim(), 10) || 0;
  } catch (e) {
    /* never started */
  }
  let alive = false;
  if (pid) {
    try {
      process.kill(pid, 0);
      alive = true;
    } catch (e) {
      alive = false;
    }
  }
  // The game's own port is the honest test: it is up only when the profile is.
  let gamePort = false;
  try {
    await waitForPort(30120, 1500);
    gamePort = true;
  } catch (e) {
    gamePort = false;
  }
  console.log(
    `bridge ${alive ? 'up' : 'DOWN'}  pid ${pid || '?'}  game port ${gamePort ? 'open' : 'closed'}`
  );
  process.exit(alive && gamePort ? 0 : 2);
}

function log(n) {
  ensureDir();
  const lines = fs.readFileSync(LOG, 'utf8').split('\n');
  console.log(lines.slice(-(parseInt(n, 10) || 40)).join('\n'));
}

const [, , cmd, ...rest] = process.argv;
(async () => {
  if (cmd === 'serve') return serve();
  if (cmd === 'send') return send(rest.join(' '));
  if (cmd === 'status') return status();
  if (cmd === 'log') return log(rest[0]);
  console.error('usage: console-bridge.js serve | send "<command>" | status | log [n]');
  process.exit(1);
})().catch((e) => {
  console.error(`console-bridge: ${e.message}`);
  process.exit(1);
});
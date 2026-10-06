// Stage 9.1: prove a comment-only commit changed no Lua tokens.
//
//   node tools/strip-compare.js
//
// Compares git HEAD vs the working tree for every .lua path the fxmanifest
// names (plus init.lua). Comments and whitespace are stripped; what remains
// must be identical. A mismatch is a code change hiding in a "comment" commit.
//
// FiveM backtick hashes are treated as quoted strings so a `--` inside one
// cannot start a comment. Long comments (--[[ ]] / --[=[ ]=]) and long strings
// are handled the same way as test/contracts.lua.

const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')

const root = path.join(__dirname, '..')

function shippedLua() {
  const manifest = fs.readFileSync(path.join(root, 'fxmanifest.lua'), 'utf8')
  const files = new Set(['init.lua'])
  for (const m of manifest.matchAll(/'([^']+\.lua)'/g)) files.add(m[1])
  return [...files].filter((rel) => fs.existsSync(path.join(root, rel)))
}

function stripComments(source) {
  let out = ''
  let i = 0
  const n = source.length
  const peek = (k) => source.slice(i, i + k)
  while (i < n) {
    const two = peek(2)
    if (two === '--') {
      const long = source.slice(i).match(/^--\[(=*)\[/)
      if (long) {
        const close = ']' + long[1] + ']'
        const stop = source.indexOf(close, i + long[0].length)
        i = stop === -1 ? n : stop + close.length
      } else {
        const stop = source.indexOf('\n', i)
        i = stop === -1 ? n : stop
      }
      continue
    }
    if (two === '[[' || source.slice(i, i + 2) === '[=') {
      const long = source.slice(i).match(/^\[(=*)\[/)
      if (long) {
        const close = ']' + long[1] + ']'
        const stop = source.indexOf(close, i + long[0].length)
        const end = stop === -1 ? n : stop + close.length
        out += source.slice(i, end)
        i = end
        continue
      }
    }
    const q = source[i]
    if (q === "'" || q === '"' || q === '`') {
      let j = i + 1
      while (j < n) {
        if (source[j] === '\\') {
          j += 2
          continue
        }
        if (source[j] === q) {
          j += 1
          break
        }
        j += 1
      }
      out += source.slice(i, j)
      i = j
      continue
    }
    out += source[i]
    i += 1
  }
  return out
}

function tokens(source) {
  const body = stripComments(source)
  const out = []
  const re = /[A-Za-z_][A-Za-z0-9_]*|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`(?:\\.|[^`\\])*`|\[=*\[(?:[\s\S]*?)\]=*\]|\S/g
  let m
  while ((m = re.exec(body))) out.push(m[0])
  return out
}

function gitShow(rel) {
  const r = spawnSync('git', ['show', 'HEAD:' + rel.replace(/\\/g, '/')], {
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
  })
  if (r.status !== 0) return null
  return r.stdout
}

function main() {
  const files = shippedLua()
  const changed = []
  const missingHead = []
  let compared = 0
  for (const rel of files) {
    const now = fs.readFileSync(path.join(root, rel), 'utf8')
    const then = gitShow(rel)
    if (then === null) {
      missingHead.push(rel)
      continue
    }
    compared += 1
    const a = tokens(then)
    const b = tokens(now)
    if (a.length !== b.length) {
      changed.push(`${rel}: token count ${a.length} -> ${b.length}`)
      continue
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        changed.push(`${rel}: first mismatch at token ${i + 1}: ${JSON.stringify(a[i])} -> ${JSON.stringify(b[i])}`)
        break
      }
    }
  }
  console.log(`strip-compare: ${compared} shipped lua files vs HEAD`)
  if (missingHead.length) {
    console.log(`  not in HEAD (new files, skipped): ${missingHead.join(', ')}`)
  }
  if (changed.length) {
    console.error('CODE CHANGED (not comment-only):')
    for (const line of changed) console.error('  ' + line)
    process.exit(1)
  }
  console.log('token streams identical: comment/whitespace only')
}

main()

// Find locals that are WRITTEN but never READ.
//
// 4.11 of the plan asks for "state that is written but never read". Counting a
// name's occurrences is the wrong way to ask that, and getting it wrong is how
// this scan would delete something load-bearing: a name that appears once is a
// write with no read, but a name that appears twice may be write-then-read in
// the same statement, or a read inside a string, and a name that appears once
// may be dead while appearing three times is certainly alive.
//
// So each occurrence is classified by what the surrounding text DOES with it:
//
//   * the token is followed by `=` (not `==`, `~=`, `<=`, `>=`)  -> a WRITE
//   * the token is followed by anything else, or precedes one    -> a READ
//   * the token is inside a `--` comment or a quoted string      -> NOT CODE
//
// A name with writes and no reads is the thing 4.11 is asking about. A name
// with neither is a different finding: a declaration that nothing refers to,
// which the linter already catches, so it is reported separately rather than
// counted twice.
//
// Deliberately NOT a general dead-code detector. It reads one file, it only
// understands `local name =` at the top level, and it says what it found
// rather than deleting anything.

const fs = require('fs')
const path = require('path')

const root = path.join(__dirname, '..')

// Strip comments and string literals so a name mentioned in prose is not a
// read. Order matters: long strings first so a `"` inside a `[[ ]]` block does
// not start a short string.
function codeOnly(src) {
  let out = ''
  let i = 0
  const n = src.length
  while (i < n) {
    const two = src.slice(i, i + 2)
    if (two === '--') {
      // A long comment `--[[ ... ]]` is a comment; a line comment runs to EOL.
      if (src.slice(i, i + 4) === '--[[') {
        const end = src.indexOf(']]', i + 4)
        i = end === -1 ? n : end + 2
      } else {
        const end = src.indexOf('\n', i)
        i = end === -1 ? n : end
      }
      continue
    }
    if (two === '[[') {
      const end = src.indexOf(']]', i + 2)
      i = end === -1 ? n : end + 2
      out += ' '
      continue
    }
    if (src[i] === '"' || src[i] === "'") {
      const quote = src[i]
      let j = i + 1
      while (j < n) {
        if (src[j] === '\\') { j += 2; continue }
        if (src[j] === quote) { j += 1; break }
        j += 1
      }
      i = j
      out += ' '
      continue
    }
    out += src[i]
    i += 1
  }
  return out
}

// `name =` is a write. `name ==`, `name ~=`, `name <=`, `name >=` are
// comparisons, and `name` used anywhere else is a read. A bare `=` immediately
// after the name, not followed by `=`, is the only assignment form here.
function classify(code, name) {
  const re = new RegExp('\\b' + name + '\\b', 'g')
  let writes = 0
  let reads = 0
  let m
  while ((m = re.exec(code)) !== null) {
    const before = code.slice(Math.max(0, m.index - 1), m.index)
    const after = code.slice(m.index + name.length, m.index + name.length + 2)
    if (after[0] === '=' && after[1] !== '=' && before !== '=' && before !== '~'
        && before !== '<' && before !== '>') {
      writes += 1
    } else {
      reads += 1
    }
  }
  return { writes, reads }
}

const targets = process.argv.slice(2)
const files = targets.length ? targets : [
  'server/sync.lua', 'client/sync.lua',
]

let findings = 0
for (const rel of files) {
  const full = path.join(root, rel)
  const code = codeOnly(fs.readFileSync(full, 'utf8'))
  const declared = new Set()
  // Indented `local` too, not just top level: a table written and never read
  // inside one function is exactly as dead as one at file scope, and the plan
  // asks for "any other state" without qualifying where it lives.
  const declRe = /^[ \t]*local\s+([a-zA-Z_]\w*)\s*=/gm
  let m
  while ((m = declRe.exec(code)) !== null) declared.add(m[1])

  const dead = []
  const unused = []
  for (const name of declared) {
    const { writes, reads } = classify(code, name)
    // The declaration itself is one write, so subtract it.
    if (reads === 0 && writes > 1) dead.push(`${name} (${writes} writes, 0 reads)`)
    else if (writes <= 1 && reads === 0) unused.push(name)
  }

  console.log(`${rel}: ${declared.size} top-level locals`)
  if (dead.length) {
    console.log(`  WRITTEN BUT NEVER READ: ${dead.join(' | ')}`)
    findings += dead.length
  } else {
    console.log('  written but never read: none')
  }
  if (unused.length) console.log(`  declared and never mentioned: ${unused.join(' | ')}`)
}

console.log(`\n${findings} written-but-never-read`)
process.exitCode = findings > 0 ? 1 : 0
// Stage 1.5, part 3: the library's OWN globals, read out of the source.
//
// Every module in cis_libs defines exactly one `Cis*` global and hands state to
// the next file through it. That is the design, not an accident: a shared script
// loaded into two resources' VMs has no other way to talk to its neighbour.
//
// It is also why `.luacheckrc` claimed a `Cis.*` wildcard would work. It cannot.
// This file produces the real list, so the config stops being a guess.
//
// The output is lib-globals.json: name -> the files that define it and the
// realms that load them. check-realms needs it (a library global is not an
// unknown native), and gen-luacheck.js needs it (that is the `globals` block).

const fs = require('fs')
const path = require('path')

const root = path.join(__dirname, '..', '..')
const OUT = path.join(root, 'tools', 'natives', 'lib-globals.json')

function stripNonCode(src) {
  let out = ''
  let i = 0
  const n = src.length
  while (i < n) {
    const c = src[i]
    if (c === '-' && src[i + 1] === '-' && src[i + 2] === '[') {
      let j = i + 2
      let level = ''
      while (j < n && src[j] === '=') { level += '='; j++ }
      if (src[j] === '[') {
        const close = ']' + level + ']'
        const end = src.indexOf(close, j + 1)
        const stop = end === -1 ? n : end + close.length
        out += src.slice(i, stop).replace(/[^\n]/g, ' ')
        i = stop
        continue
      }
    }
    if (c === '-' && src[i + 1] === '-') {
      const end = src.indexOf('\n', i)
      const stop = end === -1 ? n : end
      out += ' '.repeat(stop - i)
      i = stop
      continue
    }
    if (c === '"' || c === "'") {
      const quote = c
      let j = i + 1
      while (j < n) {
        if (src[j] === '\\') { j += 2; continue }
        if (src[j] === quote || src[j] === '\n') break
        j++
      }
      out += quote + ' '.repeat(Math.max(0, Math.min(j, n - 1) - i - 1)) + (src[j] === quote ? quote : '')
      i = j + 1
      continue
    }
    out += c
    i++
  }
  return out
}

function shippedFiles() {
  const manifest = fs.readFileSync(path.join(root, 'fxmanifest.lua'), 'utf8')
  const out = []
  for (const [realm, kw] of [['shared', 'shared_scripts'], ['client', 'client_scripts'], ['server', 'server_scripts']]) {
    const re = new RegExp(kw + '\\s*\\{([^}]*)\\}', 'g')
    let m
    while ((m = re.exec(manifest)) !== null) {
      const str = /(['"])((?:\\.|(?!\1)[^\\])*)\1/g
      let s
      while ((s = str.exec(m[1])) !== null) {
        const v = s[2]
        if (v.startsWith('@') || v.startsWith('/')) continue
        if (!fs.existsSync(path.join(root, v))) continue
        out.push({ realm, file: v })
      }
    }
  }
  return out
}

// A global definition is one of:
//   function CisFoo()      function CisFoo.bar()      CisFoo = {}
//   function Cis.foo()     CisFoo.bar = ...
//
// Indentation cannot decide this. `CisRegistry = {}` sits at column 0, but
// `DiscordConfig = CisDefaults.sanitize(discord)` sits eight columns in because
// it is inside the `if type(discord) == 'table'` branch of SetConfig, and a
// scanner that only accepts column 0 misses it and then reports every later
// READ of it as an undefined global.
//
// Nor can the name shape. Every table constructor key in this repository is
// PascalCase too -- CisDefaults is full of `Debug = true`, `ALPHABET = 'ABC'` --
// so accepting "any PascalCase assignment" produced 116 globals of which 53
// were table keys.
//
// What separates them is brace depth. A key sits inside `{ ... }` and is at
// depth 1; a global assignment sits in statement position at depth 0, however
// deeply it is indented. That is the rule.
//
// The second clause keeps ordinary function-locals out: a name declared
// `local` anywhere in the tree is not a global, whatever else looks like an
// assignment to it.
const DEF_FUNCTION = /^\s*function\s+([A-Z][A-Za-z0-9_]*)\s*[.=(:]/
const DEF_ASSIGN = /^\s*([A-Z][A-Za-z0-9_]*)\s*=(?!=)/
const LOCAL_ANYWHERE = /\blocal\s+(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)/g

function main() {
  const files = shippedFiles()
  const sources = files.map(f => ({ ...f, code: stripNonCode(fs.readFileSync(path.join(root, f.file), 'utf8')) }))

  const localNames = new Set()
  for (const f of sources) {
    LOCAL_ANYWHERE.lastIndex = 0
    let m
    while ((m = LOCAL_ANYWHERE.exec(f.code)) !== null) localNames.add(m[1])
  }

  const globals = {}
  const note = (name, realm, file) => {
    if (!globals[name]) globals[name] = { realms: new Set(), files: new Set() }
    globals[name].realms.add(realm)
    globals[name].files.add(file)
  }

  for (const f of sources) {
    let depth = 0
    for (const line of f.code.split('\n')) {
      if (depth === 0) {
        let m = DEF_FUNCTION.exec(line)
        if (!m) m = DEF_ASSIGN.exec(line)
        if (m && !localNames.has(m[1])) note(m[1], f.realm, f.file)
      }
      // The comment and string bodies are already blank, so a brace counted
      // here is structural.
      for (const ch of line) {
        if (ch === '{') depth++
        else if (ch === '}') depth--
      }
    }
  }

  const doc = {
    $comment: 'Generated by tools/natives/build-libglobals.js. The globals cis_libs defines at file scope and hands between its own files. This is the list that replaces the non-functional "Cis.*" wildcard in .luacheckrc.',
    count: Object.keys(globals).length,
    globals: Object.fromEntries(Object.keys(globals).sort().map(k => [k, {
      realms: [...globals[k].realms].sort(),
      files: [...globals[k].files].sort(),
    }])),
  }
  fs.writeFileSync(OUT, JSON.stringify(doc, null, 2) + '\n', 'utf8')
  console.log('library globals:', doc.count)
  console.log(Object.keys(doc.globals).join(', '))
  console.log('written: tools/natives/lib-globals.json')
}

main()
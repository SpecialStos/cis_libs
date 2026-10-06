'use strict'

// The OTHER half of the public surface.
//
// tools/lua-exports.js reads the `exports('Name', ...)` registrations out of
// server/ and client/. This reads the `Cis.*` proxies out of init.lua, and it
// exists because init.lua is what a consumer actually calls:
//
//     shared_script '@cis_libs/init.lua'
//     Cis.db.query('SELECT * FROM x')
//
// Every one of those is a hand-written proxy that crosses the exports boundary,
// and every one of them is a place a name, an argument, a realm or a forwarding
// target can drift away from the export behind it. Until now nothing compared
// the two, so "declared in api.lua" covered the exports and left the surface a
// consumer touches completely unchecked -- which is the half that matters.
//
// WHAT IS HARD HERE, and why this is a walker and not a regex: a `Cis.*`
// function's realm is decided by WHICH BLOCK it is written in. `Cis.player.ped`
// is a real function in the `if not IS_SERVER` half and a
// `return false, 'client only'` stub in the `if IS_SERVER` half, and the same
// name in both is the CORRECT shape. A line-based regex cannot tell those
// apart, and a scanner that guessed would report coverage it does not have --
// so the block structure is walked for real and every answer is pinned.

const fs = require('fs')
const path = require('path')

// --------------------------------------------------------------- blanking
//
// Comments out, string CONTENTS out, long strings out -- leaving every byte
// position intact, so a line number still means what it said.
//
// A keyword scan over raw text is the classic way to invent a finding: a
// `-- ... end ...` comment or a `'SELECT end FROM t'` literal moves the block
// depth, and every realm after it is wrong while nothing looks broken. Blanking
// rather than deleting is what keeps a diagnostic pointing at a line instead of
// a column.

// Long bracket openers: `[[`, `[=[`, and the comment forms `--[[`, `--[==[`.
const LONG_OPEN = /^(?:-{2,})?\[(=*)\[/

function blank(src) {
  const out = src.split('')
  let i = 0
  const n = out.length
  while (i < n) {
    const c = out[i]
    const rest = src.slice(i, i + 12)
    const lb = LONG_OPEN.exec(rest)
    if (lb && (rest.startsWith('--') || c === '[')) {
      const eq = lb[1].length
      const close = `]${'='.repeat(eq)}]`
      const found = src.indexOf(close, i + rest.length)
      const stop = found === -1 ? n : found + close.length
      for (let k = i; k < stop; k++) if (out[k] !== '\n') out[k] = ' '
      i = stop
      continue
    }
    if (c === '-' && src[i + 1] === '-') {
      const end = src.indexOf('\n', i)
      const stop = end === -1 ? n : end
      for (let k = i; k < stop; k++) out[k] = ' '
      i = stop
      continue
    }
    if (c === '"' || c === "'") {
      const quote = c
      let k = i + 1
      while (k < n) {
        if (src[k] === '\\') {
          out[k] = ' '
          if (k + 1 < n && src[k + 1] !== '\n') out[k + 1] = ' '
          k += 2
          continue
        }
        if (src[k] === quote) break
        if (src[k] !== '\n') out[k] = ' '
        k += 1
      }
      i = k + 1
      continue
    }
    i += 1
  }
  return out.join('')
}

const IDENT_SRC = '[A-Za-z_][A-Za-z0-9_]*'
const DOTTED_RE = new RegExp(`^${IDENT_SRC}(?:\\s*\\.\\s*${IDENT_SRC})*`)

// ----------------------------------------------------------------- walking

// A block open, carrying the realm it imposes on anything defined inside it --
// or null, meaning it imposes nothing.
//
// `expectDo` is why this is a stack and not a counter: `for ... do` and
// `while ... do` open ONE block across two keywords. Counting both as openers
// leaves the depth permanently wrong from the first loop onward, and the depth
// is what decides every realm after it.
//
// `fn` is the pending function definition. It lives ON THE FRAME rather than in
// a single module-level slot, because function bodies nest -- and a slot was
// exactly the first version's bug: `Cis.callback.call` contains a
// `CreateThread(function() ... end)`, the inner one overwrote the outer, and the
// scanner reported a surface of ZERO names while exiting cleanly. A check that
// finds nothing must never look like a check that passed, so the walker
// reports `unclosed` and `lost` and the caller treats a lost definition as a
// failure.
function pushFrame(stack, kind, realm) {
  const frame = { kind, realm: realm === undefined ? null : realm, expectDo: false, fn: null }
  stack.push(frame)
  return frame
}

const CLIENT_ONLY_RE = /\bnot\s+IS_SERVER\b/
const SERVER_ONLY_RE = /\bIS_SERVER\b/

// The realm a condition imposes, read from the condition TEXT rather than by
// evaluating it.
//
// An unrecognised condition imposes NOTHING, and that is the conservative
// answer in both directions: a block whose purpose this scanner cannot name
// must never be the reason a function is declared client-only, and must never
// hide one that is.
function realmOfCondition(tokens) {
  const text = tokens.join(' ')
  if (!SERVER_ONLY_RE.test(text)) return null
  return CLIENT_ONLY_RE.test(text) ? 'client' : 'server'
}

// The refusal bodies. `Cis.player.ped` on the server is not a second
// implementation, it is the answer this library gives for calling a client
// function from the server -- and the project has already decided twice that
// the answer must be a value the caller can test, never a raise.
//
// Matched against the RAW slice, not the blanked one. The string IS the
// evidence here, and blanking it is precisely what would let a wrong answer
// look right.
const REFUSAL_RE = /^\s*return\s+false\s*,\s*'(client|server)\s+only'\s*;?\s*$/

// Every `exportCall('Name'` a body makes. This is the link between the proxy a
// consumer calls and the export that does the work, and it is the whole reason
// a `forwardsTo` can be CHECKED rather than asserted in a comment.
const FORWARDS_RE = /\bexportCall\s*\(\s*'([^']+)'/g
const TRY_FORWARDS_RE = /\btryExport\s*\(\s*'([^']+)'/g

function scanCisSurface(src) {
  const flat = blank(src)
  const stack = []
  const defs = []
  const lost = []
  const lineOf = pos => src.slice(0, pos).split('\n').length

  let i = 0
  const n = flat.length
  const cond = []
  let collecting = false
  let elseIfTarget = null

  const balancedEnd = (openIdx) => {
    let depth = 0
    let k = openIdx
    for (; k < n; k++) {
      const ch = flat[k]
      if (ch === '(' || ch === '{' || ch === '[') depth += 1
      else if (ch === ')' || ch === '}' || ch === ']') {
        depth -= 1
        if (depth === 0) break
      }
    }
    return k
  }

  while (i < n) {
    const c = flat[i]
    if (c === '\n' || c === ' ' || c === '\t' || c === '\r') { i += 1; continue }

    // A string literal's delimiters are still present (only the interior was
    // blanked) so they must be stepped over or a quote reads as punctuation.
    if (c === '"' || c === "'") {
      i += 1
      while (i < n && flat[i] !== c) i += flat[i] === '\\' ? 2 : 1
      i += 1
      continue
    }

    if (c === '(' || c === '{' || c === '[') { i += 1; continue }
    if (c === ')' || c === ']' || c === '}') { i += 1; continue }

    // The word's own start offset, kept because the body of a definition ends
    // at the `end` that closes it and the slice must stop BEFORE those three
    // letters. Taking the offset after the increment instead puts `end` inside
    // the body, and a body-anchored match then never succeeds -- which is how a
    // refusal stub can look like a real definition while the file is correct.
    const at = i
    const m = DOTTED_RE.exec(flat.slice(i))
    if (!m) { i += 1; continue }
    const word = m[0]
    // A dotted expression is not a keyword: step over it whole so `exports.foo`
    // cannot be read as the keyword `exports` followed by garbage.
    if (word.includes('.')) { i += word.length; continue }
    i += word.length

    if (collecting) {
      if (word === 'then') {
        collecting = false
        if (elseIfTarget) {
          elseIfTarget.realm = realmOfCondition(cond)
          elseIfTarget = null
        } else {
          const top = stack[stack.length - 1]
          if (top) top.realm = realmOfCondition(cond)
        }
      } else {
        cond.push(word)
      }
      continue
    }

    switch (word) {
      case 'function': {
        let j = i
        while (j < n && /[ \t\r\n]/.test(flat[j])) j += 1
        const frame = pushFrame(stack, 'function')
        const dotted = DOTTED_RE.exec(flat.slice(j))
        if (dotted && flat[j + dotted[0].length] === '(') {
          const open = j + dotted[0].length
          const end = balancedEnd(open)
          frame.fn = {
            name: dotted[0].replace(/\s+/g, ''),
            rawParams: src.slice(open + 1, end),
            bodyStart: end + 1,
            at: i,
          }
          i = end + 1
        } else {
          // anonymous: `function(`, or `local function name(`
          i = j
        }
        continue
      }
      case 'if': {
        collecting = true
        cond.length = 0
        elseIfTarget = null
        pushFrame(stack, 'if', null)
        continue
      }
      case 'elseif': {
        collecting = true
        cond.length = 0
        elseIfTarget = stack[stack.length - 1] && stack[stack.length - 1].kind === 'if'
          ? stack[stack.length - 1]
          : null
        continue
      }
      case 'else': {
        const top = stack[stack.length - 1]
        if (top && top.kind === 'if' && top.realm) {
          top.realm = top.realm === 'client' ? 'server' : 'client'
        }
        continue
      }
      case 'for':
      case 'while': {
        pushFrame(stack, word, null).expectDo = true
        continue
      }
      case 'do': {
        const top = stack[stack.length - 1]
        if (top && top.expectDo) { top.expectDo = false; continue }
        pushFrame(stack, 'do', null)
        continue
      }
      case 'repeat': {
        pushFrame(stack, 'repeat', null)
        continue
      }
      case 'until': {
        stack.pop()
        continue
      }
      case 'end': {
        const frame = stack.pop()
        if (!frame || !frame.fn) continue
        const fn = frame.fn
        // `at`, not `i`: the slice has to stop before the `end` itself.
        const body = src.slice(fn.bodyStart, at)
        // The realm of a definition is the nearest enclosing block that NAMES
        // one. A block that names none imposes nothing, so a top-level
        // function is 'both' -- which is the honest answer for a proxy that
        // branches on IS_SERVER inside its own body.
        let realm = 'both'
        for (let f = stack.length - 1; f >= 0; f -= 1) {
          if (stack[f].realm) { realm = stack[f].realm; break }
        }
        const forwards = []
        for (const re of [FORWARDS_RE, TRY_FORWARDS_RE]) {
          re.lastIndex = 0
          let hit
          while ((hit = re.exec(body)) !== null) {
            if (!forwards.includes(hit[1])) forwards.push(hit[1])
          }
        }
        defs.push({
          name: fn.name,
          params: splitParams(fn.rawParams),
          line: lineOf(fn.at),
          realm,
          refusal: (REFUSAL_RE.exec(body) || [])[1] || null,
          forwards,
        })
        continue
      }
      default:
        continue
    }
  }

  // A definition still on the stack when the source ran out was mis-parsed, and
  // reporting it is the whole point: a silent zero here is indistinguishable
  // from a file with no Cis surface.
  for (const frame of stack) {
    if (frame.fn) lost.push({ name: frame.fn.name, line: lineOf(frame.fn.at) })
  }
  return { defs, unclosed: stack.length, lost }
}

// A parameter list split on TOP-LEVEL commas only. Splitting on every comma
// turns `opts = { a = 1, b = 2 }` into two parameters, and a validator that then
// compares names reports a difference that is not there.
function splitParams(text) {
  const s = String(text || '').trim()
  if (s === '') return []
  const out = []
  let depth = 0
  let cur = ''
  for (const ch of s) {
    if (ch === '(' || ch === '{' || ch === '[') depth += 1
    else if (ch === ')' || ch === '}' || ch === ']') depth -= 1
    if (ch === ',' && depth === 0) { out.push(cur.trim()); cur = ''; continue }
    cur += ch
  }
  if (cur.trim() !== '') out.push(cur.trim())
  return out
}

// A parameter's NAME: everything before the first `=` or `:`. A declaration is
// a bare name, and a default written in the source is not part of what a
// consumer types.
//
// A vararg is a position, not a typo: `Cis.callback.await(name, ...)` forwards
// an unbounded tail, and dropping it would let a declaration answer `(name)`
// while the code takes a tail. Kept as the literal `...` so a name comparison
// can see it.
function paramName(decl) {
  const s = String(decl).trim()
  if (s === '...') return '...'
  const cut = s.search(/[=:]/)
  const head = (cut === -1 ? s : s.slice(0, cut)).trim()
  return new RegExp(`^${IDENT_SRC}$`).test(head) ? head : null
}

function isCisName(name) {
  return typeof name === 'string' && new RegExp(`^Cis(\\.[A-Za-z_][A-Za-z0-9_]*)+$`).test(name)
}

// The public shape: one entry per `Cis.*` name, merged across the realms it is
// defined in.
//
// The merge is where the two-halves shape becomes visible. A real body in one
// realm and a refusal in the other is `Cis.player.ped` -- the correct file, and
// something that called it a duplicate would reject.
function surface(initPath) {
  const src = fs.readFileSync(initPath, 'utf8')
  const { defs, unclosed, lost } = scanCisSurface(src)
  const byName = new Map()
  for (const d of defs) {
    if (!isCisName(d.name)) continue
    let e = byName.get(d.name)
    if (!e) {
      e = { name: d.name, variants: [], lines: [] }
      byName.set(d.name, e)
    }
    e.variants.push({
      realm: d.realm,
      params: d.params,
      names: d.params.map(paramName),
      refusal: d.refusal,
      forwards: d.forwards,
      line: d.line,
    })
    e.lines.push(d.line)
  }
  const entries = [...byName.values()]
    .map((e) => {
      // A real (non-refusal) definition in a hard realm is what the name
      // exists FOR. A definition in the 'both' scope governs both realms by
      // branching internally, so it is not a second realm.
      const hard = [...new Set(e.variants.filter((v) => v.realm !== 'both' && !v.refusal).map((v) => v.realm))].sort()
      const refusals = [...new Set(e.variants.filter((v) => v.refusal).map((v) => v.realm))].sort()
      return {
        ...e,
        realms: hard.length > 0 ? hard : ['both'],
        refusals,
        forwards: [...new Set(e.variants.flatMap((v) => v.forwards))].sort(),
      }
    })
    .sort((a, b) => a.name.localeCompare(b.name))
  return { entries, defs, unclosed, lost, count: entries.length }
}

function scanResourceDir(resourceDir) {
  return surface(path.join(resourceDir, 'init.lua'))
}

module.exports = {
  scanCisSurface, surface, scanResourceDir, splitParams, paramName, blank, isCisName,
}

if (require.main === module) {
  const root = path.join(__dirname, '..')
  const s = scanResourceDir(root)
  process.stdout.write(`Cis.* surface: ${s.count} names, ${s.defs.length} definitions\n`)
  process.stdout.write(`unclosed blocks: ${s.unclosed}, lost definitions: ${s.lost.length}\n\n`)
  for (const e of s.entries) {
    const shape = e.variants
      .map((v) => `${v.realm}(${v.names.join(', ')}${v.refusal ? `=refuse:${v.refusal}` : ''})`)
      .join(' | ')
    process.stdout.write(`${e.name.padEnd(32)} ${e.realms.join(',').padEnd(14)} ${shape}\n`)
  }
}

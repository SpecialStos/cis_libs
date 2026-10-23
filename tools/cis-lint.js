'use strict'

// cis-lint: the Cisoko invariants that a parser can prove, checked before a
// human or a judge ever reads the code.
//
//   node tools/cis-lint.js [resourceDir ...]      default: this repository
//   node tools/cis-lint.js --json                  one JSON report on stdout
//
// Exit 0 clean, 1 on any violation, 2 on a usage error.
//
// THE RULES (cis-fivem SKILL.md § 4 numbers the invariants):
//   L001  every RegisterNUICallback handler calls cb on every path   (inv. 3)
//         A path that returns, or falls off the end, without calling cb
//         hangs the page's fetch forever, with no error anywhere.
//   L002  a server net-event handler reads `source` before it yields  (inv. 2)
//         `source` is a global the runtime rewrites per event: read after an
//         exports call, a Wait or an await, it names whichever player's
//         event ran in between. A handler that never reads it trusts the
//         payload for identity.
//   L003  no backdrop-filter in the NUI                               (inv. 5)
//         CEF composites it over the game every frame.
//   L004  no root-absolute asset path in the NUI                      (inv. 5)
//         The page loads from https://cfx-nui-<resource>/, so /assets/x.png
//         resolves against the resource root and 404s. A Vite config must set
//         base: './'.
//   L005  fxmanifest declares its server build floor '/server:<n>'  (inv. 6)
//   L006  fxmanifest declares '/onesync' when the code uses state bags or
//         server-side entities                                        (inv. 6)
//
// THE ESCAPE HATCH. A comment `cis-lint: allow L00x <reason>` on the line or
// the line above silences that rule there. The reason is required -- an allow
// without one is itself a violation (L000) -- and every allow is printed on
// every run, so an exception is a visible decision, not a quiet one.
//
// WHAT IT CANNOT SEE. L001 follows if/else, loops, do-blocks and returns. A
// nested function that calls cb, or cb handed to another function, counts as
// answering: the check cannot follow the call, so it trusts it. A handler
// passed by name is followed when this file defines it; otherwise it is
// reported, because an unchecked handler is not a passing one.
//
// The tool is self-contained (no dependency beyond node) so a product repo
// copies this one file (build-recipe.md step 0).

const fs = require('fs')
const path = require('path')

// ------------------------------------------------------------------ tokenizer

const KEYWORDS = new Set(['and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto', 'if',
  'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until', 'while'])
const OPS = ['...', '..', '==', '~=', '<=', '>=', '::', '//', '<<', '>>']

// Lua source -> tokens { t: 'name'|'kw'|'str'|'num'|'op', v, line }, plus the
// allow comments found on the way. Strings and comments are consumed whole,
// so a `--` or an `end` inside either never reaches the parser.
function tokenize(src) {
  const toks = []
  const comments = []
  let i = 0
  let line = 1
  const n = src.length
  const longClose = (at) => {
    // At a '[': returns the closing ']=*]' for a long bracket, or null.
    const m = /^\[(=*)\[/.exec(src.slice(at, at + 64))
    return m ? { open: m[0].length, close: `]${m[1]}]` } : null
  }
  const advance = (text) => { for (const c of text) if (c === '\n') line += 1 }
  while (i < n) {
    const c = src[i]
    if (c === '\n') { line += 1; i += 1; continue }
    if (c === ' ' || c === '\t' || c === '\r') { i += 1; continue }
    if (c === '-' && src[i + 1] === '-') {
      const start = line
      const lb = src[i + 2] === '[' ? longClose(i + 2) : null
      let end
      if (lb) {
        end = src.indexOf(lb.close, i + 2 + lb.open)
        end = end === -1 ? n : end + lb.close.length
      } else {
        end = src.indexOf('\n', i)
        if (end === -1) end = n
      }
      const text = src.slice(i, end)
      comments.push({ line: start, text })
      advance(text)
      i = end
      continue
    }
    if (c === '[') {
      const lb = longClose(i)
      if (lb) {
        let end = src.indexOf(lb.close, i + lb.open)
        end = end === -1 ? n : end + lb.close.length
        const text = src.slice(i, end)
        toks.push({ t: 'str', v: text, line })
        advance(text)
        i = end
        continue
      }
    }
    // Backtick hash literals are CfxLua's compile-time joaat: a string to us.
    if (c === '"' || c === "'" || c === '`') {
      const start = line
      let j = i + 1
      while (j < n && src[j] !== c && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1
      toks.push({ t: 'str', v: src.slice(i, j + 1), line: start })
      i = j + 1
      continue
    }
    if (/[A-Za-z_]/.test(c)) {
      const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(src.slice(i, i + 256))
      toks.push({ t: KEYWORDS.has(m[0]) ? 'kw' : 'name', v: m[0], line })
      i += m[0].length
      continue
    }
    if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(src[i + 1] || ''))) {
      const m = /^(0[xX][0-9a-fA-F.]+([pP][+-]?[0-9]+)?|[0-9.]+([eE][+-]?[0-9]+)?)/.exec(src.slice(i, i + 128))
      toks.push({ t: 'num', v: m[0], line })
      i += m[0].length
      continue
    }
    const op = OPS.find(o => src.startsWith(o, i)) || c
    toks.push({ t: 'op', v: op, line })
    i += op.length
  }
  return { toks, comments }
}

// -------------------------------------------------------------------- parser

// Just enough structure for control flow. A block is a list of nodes:
//   { k: 'tok', tok }                       any token outside the shapes below
//   { k: 'fn', params, body, line, endLine } function ... end, named or not
//   { k: 'if', cond, branches, hasElse, line }
//   { k: 'loop', head, body, line, kind }   while, for, repeat
//   { k: 'do', body, line }
//   { k: 'return', expr, line }
// cond, head and expr are node lists too, so a function literal inside an
// argument or a condition is still a fn node.
function parse(toks) {
  let i = 0
  const peek = () => toks[i]
  const isKw = (t, v) => t && t.t === 'kw' && t.v === v
  const fail = (msg) => { throw new Error(`${msg} at line ${peek() ? peek().line : 'EOF'}`) }

  // Collect expression-ish nodes until one of the stop keywords, parsing any
  // nested function literal (the only keyword an expression can open).
  function exprUntil(stops) {
    const out = []
    while (i < toks.length) {
      const t = peek()
      if (t.t === 'kw' && stops.includes(t.v)) break
      if (isKw(t, 'function')) { out.push(fnNode()); continue }
      out.push({ k: 'tok', tok: t })
      i += 1
    }
    return out
  }

  function fnNode() {
    const line = peek().line
    i += 1 // function
    // `function a.b:c(` keeps its name; an anonymous function has none.
    let name = ''
    while (i < toks.length && !(peek().t === 'op' && peek().v === '(')) { name += peek().v; i += 1 }
    i += 1 // (
    const params = []
    while (i < toks.length && !(peek().t === 'op' && peek().v === ')')) {
      if (peek().t === 'name' || peek().v === '...') params.push(peek().v)
      i += 1
    }
    i += 1 // )
    const body = block(['end'])
    const endLine = peek() ? peek().line : line
    if (!isKw(peek(), 'end')) fail('function without end')
    i += 1
    return { k: 'fn', name: name || null, params, body, line, endLine }
  }

  function block(terms) {
    const nodes = []
    while (i < toks.length) {
      const t = peek()
      if (t.t === 'kw' && terms.includes(t.v)) return nodes
      if (t.t !== 'kw') { nodes.push({ k: 'tok', tok: t }); i += 1; continue }
      switch (t.v) {
        case 'function':
          nodes.push(fnNode())
          break
        case 'if': {
          i += 1
          const node = { k: 'if', cond: exprUntil(['then']), branches: [], hasElse: false, line: t.line }
          i += 1 // then
          for (;;) {
            node.branches.push(block(['elseif', 'else', 'end']))
            const term = peek()
            if (!term) fail('if without end')
            i += 1
            if (term.v === 'end') break
            if (term.v === 'elseif') { node.cond = node.cond.concat(exprUntil(['then'])); i += 1; continue }
            node.hasElse = true
            node.branches.push(block(['end']))
            i += 1
            break
          }
          nodes.push(node)
          break
        }
        case 'while':
        case 'for': {
          i += 1
          const head = exprUntil(['do'])
          i += 1
          const body = block(['end'])
          i += 1
          nodes.push({ k: 'loop', kind: t.v, head, body, line: t.line })
          break
        }
        case 'repeat': {
          i += 1
          const body = block(['until'])
          i += 1
          nodes.push({ k: 'loop', kind: 'repeat', head: [], body, line: t.line })
          break
        }
        case 'do': {
          i += 1
          const body = block(['end'])
          i += 1
          nodes.push({ k: 'do', body, line: t.line })
          break
        }
        case 'return': {
          i += 1
          nodes.push({ k: 'return', expr: exprUntil(['end', 'else', 'elseif', 'until']), line: t.line })
          break
        }
        default:
          nodes.push({ k: 'tok', tok: t })
          i += 1
      }
    }
    if (terms.length) fail(`expected ${terms.join('/')}`)
    return nodes
  }

  return block([])
}

// Every node list in the tree, each visited once: blocks, conditions,
// loop heads, return expressions, function bodies.
function eachList(list, visit) {
  visit(list)
  for (const node of list) {
    if (node.k === 'fn') eachList(node.body, visit)
    else if (node.k === 'if') { eachList(node.cond, visit); node.branches.forEach(b => eachList(b, visit)) }
    else if (node.k === 'loop') { eachList(node.head, visit); eachList(node.body, visit) }
    else if (node.k === 'do') eachList(node.body, visit)
    else if (node.k === 'return') eachList(node.expr, visit)
  }
}

const isTok = (node, v) => node && node.k === 'tok' && node.tok.v === v
// A bare reference to a name: not a field (`x.cb`, `x:cb`).
function bareRef(list, idx, name) {
  const node = list[idx]
  if (!node || node.k !== 'tok' || node.tok.t !== 'name' || node.tok.v !== name) return false
  const prev = list[idx - 1]
  return !(isTok(prev, '.') || isTok(prev, ':'))
}

// The calls `NAME(arg, arg, ...)` in one node list: [{ name, line, args }],
// each arg a node list.
function callsIn(list, names) {
  const out = []
  for (let idx = 0; idx < list.length; idx += 1) {
    const node = list[idx]
    if (node.k !== 'tok' || node.tok.t !== 'name' || !names.has(node.tok.v)) continue
    if (!bareRef(list, idx, node.tok.v) || !isTok(list[idx + 1], '(')) continue
    const args = [[]]
    let depth = 0
    let j = idx + 1
    for (; j < list.length; j += 1) {
      const a = list[j]
      if (a.k === 'tok' && a.tok.t === 'op') {
        if ('({['.includes(a.tok.v)) { depth += 1; if (depth === 1) continue }
        else if (')}]'.includes(a.tok.v)) { depth -= 1; if (depth === 0) break }
        else if (a.tok.v === ',' && depth === 1) { args.push([]); continue }
      }
      args[args.length - 1].push(a)
    }
    out.push({ name: node.tok.v, line: node.tok.line, args, end: j })
  }
  return out
}

// Does this token answer through cb? A call (`cb(...)`, `cb{...}`, `cb'x'`),
// or cb handed on whole: an argument, an assignment, a return value. A test
// such as `cb ~= nil` mentions it and answers nothing.
function answers(list, idx, cb) {
  if (!bareRef(list, idx, cb)) return false
  const next = list[idx + 1]
  if (isTok(next, '(') || isTok(next, '{') || (next && next.k === 'tok' && next.tok.t === 'str')) return true
  const prev = list[idx - 1]
  const handedOn = isTok(prev, '(') || isTok(prev, ',') || isTok(prev, '=') || isTok(prev, 'return') || isTok(prev, '{')
  return handedOn && (!next || isTok(next, ',') || isTok(next, ')') || isTok(next, '}') || next.k !== 'tok' || next.tok.t !== 'op')
}

// Does cb answer anywhere under this node list, nested functions included
// unless they shadow it with a parameter?
function answersIn(list, cb) {
  for (let idx = 0; idx < list.length; idx += 1) {
    const node = list[idx]
    if (answers(list, idx, cb)) return true
    if (node.k === 'fn' && !node.params.includes(cb) && answersIn(node.body, cb)) return true
    if (node.k === 'if' && (answersIn(node.cond, cb) || node.branches.some(b => answersIn(b, cb)))) return true
    if (node.k === 'loop' && (answersIn(node.head, cb) || answersIn(node.body, cb))) return true
    if (node.k === 'do' && answersIn(node.body, cb)) return true
    if (node.k === 'return' && answersIn(node.expr, cb)) return true
  }
  return false
}


// A handler argument: a function literal, or a name this file defines with
// `local function name(...)`, `function name(...)` or `name = function(...)`.
function resolveHandler(arg, defs) {
  const parts = arg.filter(n => !(n.k === 'tok' && n.tok.t === 'op' && (n.tok.v === '(' || n.tok.v === ')')))
  if (parts.length === 1 && parts[0].k === 'fn') return parts[0]
  if (parts.length === 1 && parts[0].k === 'tok' && parts[0].tok.t === 'name') return defs.get(parts[0].tok.v) || null
  return null
}

function functionDefs(tree) {
  const defs = new Map()
  eachList(tree, (list) => {
    for (let idx = 0; idx < list.length; idx += 1) {
      const node = list[idx]
      if (node.k !== 'fn') continue
      // `local function NAME` and `function NAME` carry their name;
      // `NAME = function` has it in the two tokens before the fn node.
      if (node.name) {
        defs.set(node.name, node)
      } else if (isTok(list[idx - 1], '=') && list[idx - 2] && list[idx - 2].k === 'tok' && list[idx - 2].tok.t === 'name') {
        defs.set(list[idx - 2].tok.v, node)
      }
    }
  })
  return defs
}

// ------------------------------------------------------------ L001: NUI cb

// Walk a block in order. Returns { called, terminates }: called means every
// path that reaches the end of the block has answered the page; terminates
// means no path reaches it (every path returned).
function walkCb(list, cb, called, report) {
  for (let idx = 0; idx < list.length; idx += 1) {
    const node = list[idx]
    if (node.k === 'tok') {
      if (answers(list, idx, cb)) called = true
    } else if (node.k === 'fn') {
      if (!node.params.includes(cb) && answersIn(node.body, cb)) called = true
    } else if (node.k === 'if') {
      if (answersIn(node.cond, cb)) called = true
      const results = node.branches.map(b => walkCb(b, cb, called, report))
      const continuing = results.filter(r => !r.terminates)
      if (node.hasElse && continuing.length === 0) return { called: true, terminates: true }
      called = called || (node.hasElse && continuing.every(r => r.called))
    } else if (node.k === 'loop') {
      if (answersIn(node.head, cb)) called = true
      const r = walkCb(node.body, cb, called, report)
      // A repeat body runs at least once; while and for bodies may not run.
      if (node.kind === 'repeat') called = called || r.called
    } else if (node.k === 'do') {
      const r = walkCb(node.body, cb, called, report)
      if (r.terminates) return r
      called = r.called
    } else if (node.k === 'return') {
      if (!called && !answersIn(node.expr, cb)) {
        report(node.line, `returns without calling ${cb}: the page's fetch never resolves`)
      }
      return { called: true, terminates: true }
    }
  }
  return { called, terminates: false }
}

function checkNuiCallbacks(tree, defs, report) {
  eachList(tree, (list) => {
    for (const call of callsIn(list, new Set(['RegisterNUICallback']))) {
      const handler = call.args[1] && resolveHandler(call.args[1], defs)
      if (!handler) {
        report('L001', call.line, 'handler is not a function literal or a function defined in this file; cis-lint cannot check that it calls cb')
        continue
      }
      const cb = handler.params[1]
      if (!cb || cb === '...') {
        report('L001', call.line, 'handler takes no cb parameter, so it can never answer the page')
        continue
      }
      const r = walkCb(handler.body, cb, false, (line, msg) => report('L001', line, msg))
      if (!r.terminates && !r.called) {
        report('L001', handler.endLine, `can reach the end of the handler without calling ${cb}`)
      }
    }
  })
}

// --------------------------------------------------- L002: net-event source

// Calls that can yield, after which `source` belongs to another event.
const YIELDS = new Set(['Wait', 'exports', 'MySQL', 'Citizen', 'PerformHttpRequestAwait'])

// The handler's own tokens in order, nested function bodies excluded: those
// run later, when `source` is no longer this event's.
function ownTokens(list, out = []) {
  for (let idx = 0; idx < list.length; idx += 1) {
    const node = list[idx]
    if (node.k === 'tok') out.push({ node, list, idx })
    else if (node.k === 'if') { ownTokens(node.cond, out); node.branches.forEach(b => ownTokens(b, out)) }
    else if (node.k === 'loop') { ownTokens(node.head, out); ownTokens(node.body, out) }
    else if (node.k === 'do') ownTokens(node.body, out)
    else if (node.k === 'return') ownTokens(node.expr, out)
  }
  return out
}

function isYield(x) {
  const tok = x.node.tok
  if (tok.t !== 'name') return false
  if (YIELDS.has(tok.v) && bareRef(x.list, x.idx, tok.v)) return true
  // `x.await(...)`, `x:await(...)`, `Citizen.Await(...)`
  const prev = x.list[x.idx - 1]
  return /^[aA]wait$/.test(tok.v) && (isTok(prev, '.') || isTok(prev, ':'))
}

// Which comes first in a handler: a read of `source`, or a yield? A call to a
// function this file defines runs synchronously, so a dispatcher that hands
// `...` to `local function dispatch` reading `source` on its first line is
// followed into it (three levels deep at most).
function sourceOrder(body, defs, depth = 0) {
  for (const x of ownTokens(body)) {
    const tok = x.node.tok
    if (bareRef(x.list, x.idx, 'source')) return { read: tok.line }
    if (isYield(x)) return { yieldLine: tok.line }
    if (depth < 3 && tok.t === 'name' && defs.has(tok.v) && bareRef(x.list, x.idx, tok.v) && isTok(x.list[x.idx + 1], '(')) {
      // Arguments are evaluated before the call: `openFor(source)` has read it.
      const [call] = callsIn(x.list.slice(x.idx), new Set([tok.v]))
      if (call && call.args.some(a => a.some((_, k) => bareRef(a, k, 'source')))) return { read: tok.line }
      const inner = sourceOrder(defs.get(tok.v).body, defs, depth + 1)
      if (inner.read) return { read: tok.line }
      if (inner.yieldLine) return { yieldLine: tok.line }
    }
  }
  return {}
}

function checkNetHandlers(tree, defs, report) {
  // Names declared as net events by the one-argument form, for the
  // RegisterNetEvent('x') + AddEventHandler('x', fn) pattern.
  const netNames = new Set()
  const handlers = []
  const REG = new Set(['RegisterNetEvent', 'RegisterServerEvent', 'AddEventHandler'])
  eachList(tree, (list) => {
    for (const call of callsIn(list, REG)) {
      const nameArg = call.args[0] || []
      const literal = nameArg.length === 1 && nameArg[0].k === 'tok' && nameArg[0].tok.t === 'str' ? nameArg[0].tok.v.slice(1, -1) : null
      if (call.name !== 'AddEventHandler' && call.args.length === 1 && call.args[0].length) {
        if (literal) netNames.add(literal)
        continue
      }
      if (call.args.length < 2) continue
      handlers.push({ call, literal })
    }
  })
  for (const { call, literal } of handlers) {
    if (call.name === 'AddEventHandler' && !(literal && netNames.has(literal))) continue
    const handler = resolveHandler(call.args[1], defs)
    if (!handler) {
      report('L002', call.line, 'net handler is not a function literal or a function defined in this file; cis-lint cannot check its use of source')
      continue
    }
    if (handler.params.includes('source')) {
      report('L002', handler.line, 'a parameter named source shadows the runtime global: the payload now decides identity')
      continue
    }
    const order = sourceOrder(handler.body, defs)
    if (order.read) continue
    const label = literal ? `'${literal}'` : 'net handler'
    const late = ownTokens(handler.body).find(x => bareRef(x.list, x.idx, 'source'))
    if (late) {
      report('L002', late.node.tok.line, `${label} reads source after a call that can yield (line ${order.yieldLine}); read it into a local first`)
    } else {
      report('L002', call.line, `${label} never reads source: identity must come from source, not the payload`)
    }
  }
}

// ------------------------------------------------------------------ manifest

// Paths the manifest lists, by block. Accepts `key { 'a', 'b' }`, `key 'a'`
// and the plural/singular pairs; keeps globs as written.
function readManifest(dir) {
  const file = path.join(dir, 'fxmanifest.lua')
  if (!fs.existsSync(file)) return null
  const src = fs.readFileSync(file, 'utf8')
  const toks = tokenize(src).toks // comments dropped, strings whole
  const blocks = {}
  for (let idx = 0; idx < toks.length; idx += 1) {
    const t = toks[idx]
    if (t.t !== 'name') continue
    const key = t.v.replace(/s$/, '')
    const next = toks[idx + 1]
    if (!next) continue
    const values = []
    if (next.t === 'str') {
      values.push({ v: next.v.slice(1, -1), line: next.line })
    } else if (next.t === 'op' && next.v === '{') {
      for (let j = idx + 2; j < toks.length && !(toks[j].t === 'op' && toks[j].v === '}'); j += 1) {
        if (toks[j].t === 'str') values.push({ v: toks[j].v.slice(1, -1), line: toks[j].line })
      }
    } else continue
    blocks[key] = (blocks[key] || []).concat(values.map(x => ({ ...x, keyLine: t.line })))
  }
  return { file, src, blocks }
}

function globToRegExp(glob) {
  let re = ''
  for (let i = 0; i < glob.length; i += 1) {
    const c = glob[i]
    if (c === '*' && glob[i + 1] === '*') { re += '.*'; i += 1; if (glob[i + 1] === '/') i += 1 }
    else if (c === '*') re += '[^/]*'
    else re += c.replace(/[.+?^${}()|[\]\\]/g, '\\$&')
  }
  return new RegExp(`^${re}$`)
}

function listFiles(dir, rel = '', out = []) {
  let ents
  try { ents = fs.readdirSync(path.join(dir, rel), { withFileTypes: true }) } catch { return out }
  for (const e of ents) {
    if (e.name === 'node_modules' || e.name === '.git') continue
    const r = rel ? `${rel}/${e.name}` : e.name
    if (e.isDirectory()) listFiles(dir, r, out)
    else out.push(r)
  }
  return out
}

function expand(dir, all, entries) {
  const out = new Set()
  for (const { v } of entries || []) {
    if (v.startsWith('@')) continue
    const re = globToRegExp(v)
    for (const f of all) if (re.test(f)) out.add(f)
  }
  return [...out]
}

// ----------------------------------------------------------------- NUI files

const NUI_EXT = /\.(html?|css|scss|sass|less|js|mjs|jsx|ts|tsx|vue|svelte)$/i
const ASSET_EXT = 'png|jpe?g|gif|svg|webp|avif|ico|woff2?|ttf|otf|mp3|ogg|wav|mp4|webm|css|js'

// The NUI tree: the ui_page's top folder, everything `files` lists in it, and
// the usual source folders, so a Vite source tree is checked before it is
// built and the built page after.
function nuiFiles(dir, all, manifest) {
  const roots = new Set(['web', 'html', 'ui', 'nui'])
  for (const { v } of (manifest && manifest.blocks.ui_page) || []) roots.add(v.split('/')[0])
  return all.filter(f => roots.has(f.split('/')[0]) && NUI_EXT.test(f) && !/(^|\/)(test|tests|__tests__)\//.test(f))
}

function checkNui(dir, files, report) {
  for (const rel of files) {
    const text = fs.readFileSync(path.join(dir, rel), 'utf8')
    const lines = text.split('\n')
    const isConfig = /(^|\/)vite\.config\.(js|mjs|cjs|ts|mts)$/.test(rel)
    lines.forEach((ln, k) => {
      const line = k + 1
      if (/backdrop-filter\s*:|backdropFilter\s*:|\bbackdrop-(blur|brightness|contrast|grayscale|hue-rotate|invert|opacity|saturate|sepia)\b/.test(ln)) {
        report(rel, 'L003', line, 'backdrop-filter is composited over the game every frame; use a solid rgba background')
      }
      const abs = new RegExp(`(?:\\b(?:src|href)\\s*=\\s*["']|url\\(\\s*["']?|["'\`])(/(?!/)[^"'\`)\\s]*\\.(?:${ASSET_EXT}))(?=[?#"'\`)\\s])`, 'i')
      const m = abs.exec(ln)
      if (m && !isConfig) {
        report(rel, 'L004', line, `root-absolute asset ${m[1]} resolves against the resource root under cfx-nui and 404s; use a relative path`)
      }
    })
    if (isConfig && !/\bbase\s*:\s*['"]\.\/['"]/.test(text)) {
      report(rel, 'L004', 1, "Vite config does not set base: './'; the built page will reference /assets/... and 404 under cfx-nui")
    }
  }
}

// ------------------------------------------------------ L005 / L006 manifest

// Code that needs OneSync: state bags anywhere, entity work on the server.
const STATEBAG = new Set(['GlobalState', 'AddStateBagChangeHandler'])
const SERVER_ENTITY = new Set(['NetworkGetEntityFromNetworkId', 'NetworkGetNetworkIdFromEntity', 'CreateVehicle',
  'CreateVehicleServerSetter', 'CreatePed', 'CreateObject', 'CreateObjectNoOffset', 'GetPlayerPed', 'GetEntityCoords',
  'SetEntityCoords', 'DeleteEntity', 'SetEntityRoutingBucket', 'SetPlayerRoutingBucket', 'DoesEntityExist'])

// The token before `.state`: LocalPlayer, or the `)` of Entity(...)/Player(...).
function stateBagOwner(toks, at) {
  const t = toks[at]
  if (!t) return null
  if (t.t === 'name' && t.v === 'LocalPlayer') return 'LocalPlayer'
  if (!(t.t === 'op' && t.v === ')')) return null
  let depth = 0
  for (let j = at; j >= 0; j -= 1) {
    if (toks[j].t !== 'op') continue
    if (toks[j].v === ')') depth += 1
    else if (toks[j].v === '(' && --depth === 0) {
      const callee = toks[j - 1]
      return callee && callee.t === 'name' && (callee.v === 'Entity' || callee.v === 'Player') ? callee.v : null
    }
  }
  return null
}

function needsOneSync(rel, toks, isServer) {
  for (let idx = 0; idx < toks.length; idx += 1) {
    const t = toks[idx]
    if (t.t !== 'name') continue
    const prev = toks[idx - 1]
    if (prev && prev.t === 'op' && (prev.v === '.' || prev.v === ':')) {
      // `LocalPlayer.state`, `Entity(x).state`, `Player(x).state`; any other
      // table's `.state` field is just a field.
      if (t.v === 'state' && stateBagOwner(toks, idx - 2)) return `${rel}:${t.line} uses a state bag (${stateBagOwner(toks, idx - 2)}.state)`
      continue
    }
    if (STATEBAG.has(t.v)) return `${rel}:${t.line} uses ${t.v}`
    if (isServer && SERVER_ENTITY.has(t.v)) return `${rel}:${t.line} calls ${t.v} on the server`
  }
  return null
}

function checkManifest(manifest, usage, report) {
  const deps = [...(manifest.blocks.dependencie || []), ...(manifest.blocks.dependency || [])]
  const line = deps.length ? deps[0].keyLine : 1
  if (!deps.some(d => /^\/server:\d+$/.test(d.v))) {
    report('fxmanifest.lua', 'L005', line, "dependencies do not declare the server build floor '/server:<build>'")
  }
  if (usage && !deps.some(d => d.v === '/onesync')) {
    report('fxmanifest.lua', 'L006', line, `dependencies do not declare '/onesync', but ${usage}`)
  }
}

// ---------------------------------------------------------------------- run

const ALLOW_RE = /cis-lint:\s*allow\s+(L\d{3})\b[ \t]*(.*)/

function lintResource(dir) {
  const violations = []
  const allowed = []
  const errors = []
  const manifest = readManifest(dir)
  if (!manifest) return { dir, violations, allowed, errors: [`no fxmanifest.lua in ${dir}`] }
  const all = listFiles(dir)
  const allowsByFile = new Map()

  // Allow comments, read from the raw text so CSS, HTML and JS comments count.
  const allowsFor = (rel) => {
    if (allowsByFile.has(rel)) return allowsByFile.get(rel)
    const map = new Map()
    fs.readFileSync(path.join(dir, rel), 'utf8').split('\n').forEach((ln, k) => {
      const m = ALLOW_RE.exec(ln)
      if (!m) return
      const reason = m[2].replace(/\s*(\*\/|-->|\]\])\s*$/, '').trim()
      if (!reason) violations.push({ file: rel, rule: 'L000', line: k + 1, message: `allow ${m[1]} without a reason` })
      for (const at of [k + 1, k + 2]) map.set(`${at}:${m[1]}`, reason)
    })
    allowsByFile.set(rel, map)
    return map
  }
  const report = (file, rule, line, message) => {
    const reason = allowsFor(file).get(`${line}:${rule}`)
    if (reason) allowed.push({ file, rule, line, reason })
    else violations.push({ file, rule, line, message })
  }

  const server = new Set(expand(dir, all, manifest.blocks.server_script))
  const client = new Set(expand(dir, all, manifest.blocks.client_script))
  const shared = new Set(expand(dir, all, manifest.blocks.shared_script))
  const files = new Set(expand(dir, all, manifest.blocks.file))
  const luaFiles = [...new Set([...server, ...client, ...shared, ...files])].filter(f => f.endsWith('.lua')).sort()

  let oneSyncUsage = null
  for (const rel of luaFiles) {
    const src = fs.readFileSync(path.join(dir, rel), 'utf8')
    let toks, tree
    try {
      toks = tokenize(src).toks
      tree = parse(toks)
    } catch (e) {
      errors.push(`${rel}: cannot parse (${e.message})`)
      continue
    }
    const defs = functionDefs(tree)
    const fileReport = (rule, line, message) => report(rel, rule, line, message)
    checkNuiCallbacks(tree, defs, fileReport)
    if (server.has(rel)) checkNetHandlers(tree, defs, fileReport)
    if (!oneSyncUsage) oneSyncUsage = needsOneSync(rel, toks, server.has(rel))
  }

  checkNui(dir, nuiFiles(dir, all, manifest), report)
  checkManifest(manifest, oneSyncUsage, report)

  violations.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.rule.localeCompare(b.rule))
  return { dir, violations, allowed, errors }
}

module.exports = { lintResource, tokenize, parse }

if (require.main === module) {
  const args = process.argv.slice(2)
  const json = args.includes('--json')
  const dirs = args.filter(a => !a.startsWith('--'))
  if (args.some(a => a.startsWith('--') && a !== '--json')) {
    console.error('usage: node tools/cis-lint.js [--json] [resourceDir ...]')
    process.exit(2)
  }
  const results = (dirs.length ? dirs : [path.join(__dirname, '..')]).map(d => lintResource(path.resolve(d)))
  const bad = results.reduce((n, r) => n + r.violations.length + r.errors.length, 0)
  if (json) {
    process.stdout.write(`${JSON.stringify(results, null, 2)}\n`)
  } else {
    for (const r of results) {
      const name = path.basename(r.dir)
      for (const e of r.errors) console.log(`${name}: ERROR ${e}`)
      for (const v of r.violations) console.log(`${name}/${v.file}:${v.line} ${v.rule} ${v.message}`)
      for (const a of r.allowed) console.log(`${name}/${a.file}:${a.line} ${a.rule} allowed: ${a.reason}`)
      console.log(`cis-lint ${name}: ${r.violations.length} violation(s), ${r.errors.length} error(s), ${r.allowed.length} allowed`)
    }
  }
  process.exit(bad ? 1 : 0)
}

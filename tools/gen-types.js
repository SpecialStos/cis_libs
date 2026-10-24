// T6 + T7. One tool, two outputs, from one source of truth.
//
//   types/cis_libs.lua        a ---@meta stub describing every export
//   DOCUMENTATION.md §5 and §6, between the generated markers
//
// The fifteen MODULES are typed from their own source: every `function M.x`
// carries ---@param / ---@return annotations in shared/algo and shared/util,
// and this tool turns them into `---@field x fun(a: T): R` on the module's
// class (it used to emit a bare `function` for every one), plus the
// per-module function reference in DOCUMENTATION.md §5.1. A module function
// with a parameter or return the annotations do not type is a FAILURE here,
// as is a function the module defines and api.lua does not list, or the
// reverse -- so the types and the reference cannot quietly fall behind.
//
// BOTH ARE COMMITTED AND CI FAILS IF EITHER IS STALE. That is the whole point.
// A generated file refreshed on demand is documentation nobody reads, because
// the reader has no way to tell it from the file it drifted away from.
//
// WHY THE DUMPER IS A SEPARATE LUA FILE. The first attempt walked api.lua's
// table off the fengari C-API stack from JavaScript and got the stack discipline
// wrong several frames from the mistake -- "table expected", with no reference
// to the table being walked. Every level of that recursion is an index into a
// stack whose shape depends on the values above it. Lua can dump itself with no
// C API at all, so tools/lua-dump.lua does that, and JSON.parse handles the
// result on this side, where a malformed document is an ordinary error message.
const fs = require('fs')
const path = require('path')
const fengari = require('fengari')
const lua = fengari.lua
const lauxlib = fengari.lauxlib
const lualib = fengari.lualib
const toLua = fengari.to_luastring
const { scanResource } = require('./lua-exports')

const root = path.join(__dirname, '..')
const read = p => fs.readFileSync(path.join(root, p), 'utf8')

const OUT_TYPES = 'types/cis_libs.lua'
const OUT_DOC = 'DOCUMENTATION.md'
const BEGIN = '<!-- generated:begin -->'
const END = '<!-- generated:end -->'
const MOD_BEGIN = '<!-- generated:modules:begin -->'
const MOD_END = '<!-- generated:modules:end -->'
const OUT_V1 = 'docs/V1.md'
const V1_BEGIN = '<!-- generated:v1:begin -->'
const V1_END = '<!-- generated:v1:end -->'

function loadApi() {
  const L = lauxlib.luaL_newstate()
  lualib.luaL_openlibs(L)
  lua.lua_pushstring(L, toLua('api.lua'))
  lua.lua_setglobal(L, toLua('CIS_DUMP_TARGET'))
  const src = read('tools/lua-dump.lua')
  // Loaded and called with ONE result asked for, because the dumper RETURNS the
  // document rather than printing it: fengari's node stdout does not pass
  // through process.stdout.write, so capturing output catches nothing. A value
  // on the stack is unambiguous.
  if (lauxlib.luaL_loadstring(L, toLua(src)) !== lua.LUA_OK ||
      lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
    throw new Error('lua-dump.lua: ' + lua.lua_tojsstring(L, -1))
  }
  return JSON.parse(lua.lua_tojsstring(L, -1))
}

function paramsToSig(params) {
  if (!Array.isArray(params) || params.length === 0) return '()'
  const inner = params.map((p) => {
    if (!p || typeof p.name !== 'string') return '?'
    if (p.variadic) return '...'
    return p.optional ? `${p.name}?` : p.name
  }).join(', ')
  return `(${inner})`
}

// A realm-keyed list ({ server = {...}, client = {...} }) or a plain one.
function forRealm(list, realm) {
  if (Array.isArray(list)) return list
  if (list && typeof list === 'object') return list[realm] || list.server || list.client || []
  return []
}

function sigFor(d, realm) {
  const s = d.signature
  if (s && typeof s === 'object') {
    return s[realm] || s.client || s.server || paramsToSig(forRealm(d.params, realm))
  }
  if (typeof s === 'string' && s.length) return s
  return paramsToSig(forRealm(d.params, realm))
}

function retsFor(d, realm) {
  const list = forRealm(d.returns, realm)
  return list.length ? list.map((r) => (r && r.type) || 'any').join(', ') : '—'
}

// ONE CELL FOR BOTH REALMS: the shared value when the realms agree, and each
// realm's own when they do not, so a two-realm export is never shown as ().
function bothRealms(d, realm, fn) {
  if (realm !== 'both') return fn(d, realm)
  const sv = fn(d, 'server')
  const cl = fn(d, 'client')
  return sv === cl ? sv : `server ${sv}; client ${cl}`
}

const cell = (v) => String(v).replace(/\|/g, '\\|')

// Argument NAMES, filtered to things that are valid Lua parameter names.
//
// api.lua writes '(name, ...)' for a variadic signature, and 'any ...' is not
// a parameter list -- the generated stub has to PARSE, not merely look right.
// The syntax checker caught that one, which is the argument for running a
// syntax check over generated output at all: the file looked correct and did
// not load. A signature that reduces to nothing yields no parameters, which is
// the honest rendering of an argument list we cannot read.
function argNames(sig) {
  // Sliced, not regexed. The earlier version used a regex and the shell ate
  // its backslashes twice on the way in, which is a silly way to lose an hour.
  const text = String(sig)
  const open = text.indexOf(String.fromCharCode(40))
  const close = text.lastIndexOf(String.fromCharCode(41))
  if (open < 0 || close < open) return []
  return text.slice(open + 1, close).split(',')
    .map(x => x.trim())
    .filter(x => /^[A-Za-z_][A-Za-z0-9_]*$/.test(x))
}

function oneLine(s) {
  return String(s || '').replace(/\s+/g, ' ').replace(/\|/g, '\\|').trim()
}

// A doc string, wrapped so a long line stays readable and so a doc containing
// a newline cannot break the annotation. `---@param` takes the first line and
// treats the rest as description, so newlines are legal -- but an UNESCAPED
// newline in a generated file is a line the reader cannot predict, and this
// generator writes a committed artefact.
function doc(s) {
  return oneLine(s)
}

// --- the LuaLS rendering, from the typed schema ---------------------------
//
// The old generator read `signature = '(a, b)'`, split it on commas and
// emitted `---@param a any`. That is 258 `any`s in the committed stub, which is
// the whole of the complaint Stage 6 exists to answer: completions that
// are all `any` are not a contract.
//
// So the annotations come from the typed block instead, and the shape is the
// one LuaLS actually understands:
//
//   ---@param name type       a required parameter
//   ---@param name? type      an optional one
//   ---@param ... type        a vararg, and its NAME is the literal `...`
//   ---@return type           one slot; several return entries, one per slot
//   ---@deprecated            on the deprecated ones
//
// The realm goes in the DESCRIPTION rather than in an annotation, because
// LuaLS has no realm concept and a reader absolutely needs to know it.

function paramAnnotations(params, indent) {
  const out = []
  for (const p of params || []) {
    if (!p || typeof p.name !== 'string') continue
    const name = p.variadic ? '...' : (p.optional ? `${p.name}?` : p.name)
    const bits = [`---@param ${name} ${p.type || 'any'}`]
    if (p.doc) bits.push(`#${p.doc}`)
    if (p.why) bits.push(`\n-- Why \`any\`: ${p.why}`)
    out.push(indent + bits.join(' '))
  }
  return out
}

function returnAnnotations(returns, indent) {
  const out = []
  const list = returns || []
  // ONE ANNOTATION PER SLOT. A single `---@return boolean, string` is not
  // LuaLS: the comma is part of the type, so the editor would offer one value
  // of a type nobody can construct, and a caller would unpack one and be wrong.
  for (const r of list) {
    if (!r || typeof r.type !== 'string') continue
    const bits = [`---@return ${r.type}`]
    if (r.doc) bits.push(`#${r.doc}`)
    if (r.why) bits.push(`\n-- Why \`any\`: ${r.why}`)
    out.push(indent + bits.join(' '))
  }
  return out
}

// ---------------------------------------------------------------------------
// MODULE SIGNATURES, read from the module source.
//
// A LuaLS type can contain spaces (`fun(a: any): boolean`, `table<string, T>`),
// so a type is read up to the first space at bracket depth 0 -- except a space
// right after the `:` that introduces a fun() return type.
function readType(text) {
  let depth = 0
  let i = 0
  for (; i < text.length; i++) {
    const c = text[i]
    if ('(<{['.includes(c)) depth++
    else if (')>}]'.includes(c)) depth--
    else if (c === ' ' && depth === 0) {
      const before = text.slice(0, i).trimEnd()
      if (before.endsWith(':') || before.endsWith('|') || before.endsWith(',')) continue
      if (/^\s*[|,]/.test(text.slice(i))) continue
      break
    }
  }
  return [text.slice(0, i).trim(), text.slice(i).trim()]
}

// What counts as a type here: names, unions, arrays, generics and fun(...).
// Deliberately narrower than LuaLS -- prose in the type slot ("the id, or nil")
// is the mistake this rejects.
const TYPE_RE = /^(?:[A-Za-z_][\w.]*(?:<[^>]*>)?(?:\[\])*|fun\(.*\)(?::\s*.+)?)(?:\|(?:[A-Za-z_][\w.]*(?:<[^>]*>)?(?:\[\])*|fun\(.*\)(?::\s*.+)?))*$/

function moduleGlobal(source) {
  const m = /^\s+(Cis\w+) = M\s*$/m.exec(source)
  return m && m[1]
}

function parseModule(rel) {
  const source = read(rel)
  const lines = source.split('\n')
  const fns = new Map()
  const aliases = []
  const problems = []
  lines.forEach((line, i) => {
    const alias = /^M\.(\w+)\s*=\s*M\.(\w+)\s*$/.exec(line)
    if (alias) { aliases.push([alias[1], alias[2]]); return }
    const m = /^function M\.(\w+)\(([^)]*)\)/.exec(line)
    if (!m) return
    const name = m[1]
    const args = m[2].split(',').map((a) => a.trim()).filter(Boolean)
    const block = []
    for (let j = i - 1; j >= 0 && lines[j].startsWith('---'); j--) block.unshift(lines[j])
    const summary = []
    const params = new Map()
    const returns = []
    for (const b of block) {
      const pm = /^---\s*@param\s+(\.\.\.|[A-Za-z_]\w*\??)\s*(.*)$/.exec(b)
      const rm = /^---\s*@return\s*(.*)$/.exec(b)
      if (pm) {
        const [type, doc] = readType(pm[2])
        const optional = pm[1].endsWith('?')
        params.set(pm[1].replace(/\?$/, ''), { type, doc, optional })
      } else if (rm) {
        const [type, rest] = readType(rm[1])
        returns.push({ type, doc: rest })
      } else if (!/^---\s*@/.test(b)) {
        summary.push(b.replace(/^---\s?/, ''))
      }
    }
    const typed = []
    for (const a of args) {
      const p = params.get(a)
      if (!p || !TYPE_RE.test(p.type)) {
        problems.push(`${rel}: M.${name}: parameter ${a} has no ---@param type`)
        continue
      }
      typed.push({ name: a, ...p })
    }
    for (const r of returns) {
      if (!TYPE_RE.test(r.type)) problems.push(`${rel}: M.${name}: ---@return ${JSON.stringify(r.type)} is not a type`)
    }
    fns.set(name, { name, params: typed, returns, summary: summary.join(' ').trim() })
  })
  for (const [name, target] of aliases) {
    const t = fns.get(target)
    if (!t) { problems.push(`${rel}: M.${name} aliases M.${target}, which is not a function`); continue }
    fns.set(name, { ...t, name, alias: target })
  }
  return { global: moduleGlobal(source), fns, problems }
}

function funType(fn) {
  const params = fn.params.map((p) => `${p.name}${p.optional ? '?' : ''}: ${p.type}`).join(', ')
  const rets = fn.returns.map((r) => r.type).filter((t) => t !== 'nil')
  return `fun(${params})${rets.length ? ': ' + rets.join(', ') : ''}`
}

// First sentence of a summary, for one table cell.
function firstSentence(text) {
  const m = /^(.*?[.!?])(\s|$)/.exec(text)
  return (m ? m[1] : text).trim()
}

// Every module: its class name and parsed functions. Fails loudly on drift.
function loadModules(api) {
  const modules = api.modules || {}
  const out = []
  const problems = []
  for (const name of Object.keys(modules).sort()) {
    const parsed = parseModule(modules[name].path)
    problems.push(...parsed.problems)
    if (!parsed.global) {
      problems.push(`${modules[name].path}: no \`CisXxx = M\` tail, so the module class cannot be named`)
      continue
    }
    const cls = (api.classes || {})[parsed.global]
    if (!cls) {
      problems.push(`api.lua classes has no ${parsed.global} for module ${name}`)
      continue
    }
    const declared = new Set((cls.fields || []).filter((f) => f.type === 'function').map((f) => f.name))
    for (const f of parsed.fns.keys()) {
      if (!declared.has(f)) problems.push(`${parsed.global}.${f} is defined in ${modules[name].path} but not listed in api.lua classes.${parsed.global}`)
    }
    for (const f of declared) {
      if (!parsed.fns.has(f)) problems.push(`api.lua classes.${parsed.global} lists ${f}, which ${modules[name].path} does not define`)
    }
    out.push({ name, path: modules[name].path, global: parsed.global, fns: parsed.fns })
  }
  if (problems.length) {
    throw new Error('module annotations:\n  ' + problems.join('\n  '))
  }
  return out
}

// ---------------------------------------------------------------------------
// The classes, first: an annotation that names a class defined further down the
// file works, and the reverse reads as a dangling reference until you scroll.
function buildClasses(api, modules) {
  const moduleFns = new Map((modules || []).map((m) => [m.global, m.fns]))
  const L = []
  const classes = api.classes || {}
  const names = Object.keys(classes).sort()
  L.push('-- ================================================================ classes')
  L.push('')
  for (const name of names) {
    const c = classes[name] || {}
    L.push(`---@class ${name}`)
    // A COMMENT, and the syntax checker is what said so. Pushing the class doc
    // as a bare line puts English in the middle of a Lua chunk, and the file
    // stops being loadable -- which is a much bigger problem than a doc that
    // does not render. LuaLS reads the text after a `---@class` either way.
    if (c.doc) L.push(`-- ${oneLine(c.doc)}`)
    const fns = moduleFns.get(name)
    for (const f of c.fields || []) {
      if (!f || typeof f.name !== 'string') continue
      const fn = fns && f.type === 'function' && fns.get(f.name)
      if (fn) {
        // The module's own annotations, as a callable type the editor can check.
        const doc = firstSentence(fn.summary)
        // ` # ` delimits the description: a fun() type has spaces of its own.
        L.push(`---@field ${f.name} ${funType(fn)}${doc ? ` # ${oneLine(doc)}` : ''}`)
        continue
      }
      L.push(`---@field ${f.name}${f.optional ? '?' : ''} ${f.type || 'any'}${f.doc ? ` ${oneLine(f.doc)}` : ''}`)
    }
    L.push(`local ${name} = {}`)
    L.push('')
  }
  return L
}

// ---------------------------------------------------------------------------
// The two surfaces: the raw exports and the `Cis.*` proxies.
function buildSurface(api, block, title, kind) {
  const L = []
  const table = api[block] || {}
  const names = Object.keys(table).sort()
  L.push(`-- ================================================= ${title} (${names.length})`)
  L.push('')
  for (const name of names) {
    const d = table[name] || {}
    const realms = ['server', 'client'].filter((r) => (d.params && d.params[r]) || (d.returns && d.returns[r]))
    const listFor = (r) => (d.params && d.params[r]) || (Array.isArray(d.params) ? d.params : [])
    const retFor = (r) => (d.returns && d.returns[r]) || (Array.isArray(d.returns) ? d.returns : [])

    if (realms.length === 2) {
      // ONE OVERLOAD PER REALM, because a realm-specific signature is the only
      // way LuaLS can offer both. A single declaration with the server's names
      // would be wrong for every client caller, and a single one with the
      // client's would be wrong for every server caller.
      L.push(...deprecatedLines(api, d, kind))
      L.push('---@overload fun(...)')
      for (const r of realms) {
        L.push(...paramAnnotations(listFor(r), '  '))
        L.push(...returnAnnotations(retFor(r), '  '))
        L.push(`---@overload`)
      }
      for (const r of realms) {
        const names2 = listFor(r).map((p) => (p.variadic ? '...' : p.name)).filter(Boolean)
        L.push(`function ${name}.${r}(${names2.join(', ')}) end`)
      }
      L.push('')
      continue
    }
    const r = realms[0] || (d.realm === 'client' ? 'client' : 'server')
    const params = listFor(r)
    const returns = retFor(r)
    // BARE NAMES in the declaration. `cb?` is correct on a ---@param line and
    // a syntax error in a parameter list -- Lua has no optional parameters, and
    // the editor gets optionality from the annotation rather than from the
    // declaration. The earlier version of this generator emitted the `?` in
    // both places and the file did not load.
    const argNames = params.map((p) => (p.variadic ? '...' : p.name)).filter(Boolean)
    if (kind === 'fn') {
      L.push(`---@class ${name}`)
      if (d.since) L.push(`---@field since string ${d.since}`)
      L.push(`---@field realm "${d.realm || r}"`)
      if (d.forwardsTo) L.push(`---@field forwardsTo string ${d.forwardsTo}`)
      L.push(...deprecatedLines(api, d, kind))
    } else if (d.deprecated) {
      L.push(...deprecatedLines(api, d, kind))
    } else if (d.use) {
      L.push(`--- ${oneLine(d.use)}`)
    }
    L.push(...paramAnnotations(params, ''))
    L.push(...returnAnnotations(returns, ''))
    if (kind !== 'fn') L.push(`--- realm: ${d.realm || r}`)
    L.push(`function ${name}(${argNames.join(', ')}) end`)
    L.push('')
  }
  return L
}

// THE DEPRECATION LINES for one export or one Cis.* function. A proxy is
// exactly as deprecated as the export it forwards to, and a two-realm export
// is as deprecated as a one-realm one: the editor must strike both.
function deprecatedLines(api, d, kind) {
  const src = kind === 'fn' ? d.forwardsTo && (api.exports || {})[d.forwardsTo] : d
  if (!src || !src.deprecated) return []
  return src.use ? ['---@deprecated', `--- ${oneLine(src.use)}`] : ['---@deprecated']
}

// ---------------------------------------------------------------------------
// The module overloads, so `Cis.require('lru')` is typed as `CisLRU` rather
// than as a union of all fifteen. The union is the honest base case; these are
// what narrow it, and they come from the SAME `modules` block the loader's
// allow-list is checked against -- so a module that exists but has no overload
// is a gap the reader can see rather than a silent `table`.
function buildModuleOverloads(api, parsedModules) {
  const L = []
  const modules = api.modules || {}
  const names = Object.keys(modules).sort()
  // The class name comes from the module's own `CisXxx = M` tail. Deriving it
  // by capitalising the module name made 'lru' CisLru, which is not a class,
  // so Cis.require('lru') was typed as a bare table.
  const globals = new Map((parsedModules || []).map((m) => [m.name, m.global]))
  L.push('---@class CisRequire')
  L.push('--- `Cis.require(name)` RAISES on an unknown name rather than answering nil:')
  L.push('--- every other `Cis.*` call answers `false, reason` because the caller may')
  L.push('--- legitimately be probing, and a silent nil here is a nil index three frames')
  L.push('--- deeper in the caller, with no name in it.')
  L.push('---@param name string')
  L.push('---@return table')
  L.push('function CisRequire(name) end')
  L.push('')
  for (const n of names) {
    const g = globals.get(n) || `Cis${n.charAt(0).toUpperCase()}${n.slice(1)}`
    const declared = api.classes && api.classes[g]
    L.push('---@overload fun(name: "' + n + '"): ' + (declared ? g : 'table'))
  }
  L.push('')
  return L
}

// ---------------------------------------------------------------------------
function buildTypes(api, surface, modules) {
  const L = []
  L.push('---@meta')
  L.push('')
  L.push('-- GENERATED by tools/gen-types.js from api.lua and the source. DO NOT EDIT.')
  L.push('--')
  L.push('-- `npm run gen-types` regenerates this; `npm run gen-types:check` fails')
  L.push('-- if the committed copy is stale. Editing it by hand produces a stub that')
  L.push('-- lies to every consumer who trusts it, which is worse than no stub.')
  L.push('--')
  L.push('-- Every parameter carries a type read out of api.lua, and api.lua is itself')
  L.push('-- checked against the code by tools/validate-api.js. The chain is short on')
  L.push('-- purpose: a type nobody verifies is a promise nobody keeps.')
  L.push('')
  L.push('--- The library')
  L.push('local cis_libs = {}')
  L.push('')
  L.push(...buildClasses(api, modules))
  L.push(...buildSurface(api, 'exports', 'RAW EXPORTS', 'export'))
  L.push(...buildSurface(api, 'functions', 'Cis.* PROXIES', 'fn'))
  L.push(...buildModuleOverloads(api, modules))
  L.push('--- The consumer-facing proxy table, declared rather than aliased so the')
  L.push('--- completions carry the annotations above.')
  const fnNames = Object.keys(api.functions || {}).sort()
  for (const full of fnNames) {
    const short = full.replace(/^Cis\./, '')
    const src = full.replace(/\./g, '_')
    L.push(`cis_libs.${short.replace(/\./g, '_')} = ${src}`)
  }
  L.push('')
  L.push('return cis_libs')
  return L.join('\n') + '\n'
}

// ---------------------------------------------------------------------------
function buildDocTables(api) {
  const L = []
  const exports = api.exports || {}
  L.push('| Export | Realm | Signature | Returns | Since | Notes |')
  L.push('|---|---|---|---|---|---|')
  for (const name of Object.keys(exports).sort()) {
    const d = exports[name] || {}
    const realm = d.realm || 'both'
    const notes = [
      d.deprecated ? '**deprecated**' : '',
      oneLine(d.use),
      d.stable === false ? 'unstable' : '',
    ].filter(Boolean).join(' ')
    L.push(`| \`${name}\` | ${realm} | \`${cell(bothRealms(d, realm, sigFor))}\` | ${cell(bothRealms(d, realm, retsFor))} | ${d.since || '—'} | ${cell(notes)} |`)
  }
  L.push('')
  if (api.events) {
    L.push('| Event | Since | Payload | Notes |')
    L.push('|---|---|---|---|')
    for (const name of Object.keys(api.events).sort()) {
      const e = api.events[name] || {}
      const notes = [e.deprecated ? '**deprecated**' : '', e.deprecated ? oneLine(e.use) : ''].filter(Boolean).join(' ')
      L.push(`| \`${name}\` | ${e.since || '—'} | ${cell(oneLine(e.payload))} | ${cell(notes)} |`)
    }
    L.push('')
  }
  const functions = api.functions || {}
  L.push('| `Cis.*` | Realm | Signature | Returns | Since | Notes |')
  L.push('|---|---|---|---|---|---|')
  for (const name of Object.keys(functions).sort()) {
    const d = functions[name] || {}
    const realm = d.realm || 'both'
    // A proxy is exactly as deprecated as the export it forwards to.
    const target = d.forwardsTo && exports[d.forwardsTo]
    const notes = [
      d.deprecated || (target && target.deprecated) ? '**deprecated**' : '',
      oneLine(d.use),
    ].filter(Boolean).join(' ')
    L.push(`| \`${name}\` | ${realm} | \`${cell(bothRealms(d, realm, sigFor))}\` | ${cell(bothRealms(d, realm, retsFor))} | ${d.since || '—'} | ${cell(notes)} |`)
  }
  L.push('')
  return L.join('\n')
}

// ---------------------------------------------------------------------------
// DOCUMENTATION.md §5.1: one table per module, generated from the same parse
// that types the editor stub, so the reference and the types cannot disagree.
function buildModuleDocs(modules) {
  const L = []
  for (const m of modules) {
    L.push(`#### \`${m.name}\` — \`Cis.require('${m.name}')\``)
    L.push('')
    L.push(`Source: \`${m.path}\`.`)
    L.push('')
    L.push('| Function | Signature | Summary |')
    L.push('|---|---|---|')
    for (const name of [...m.fns.keys()].sort()) {
      const fn = m.fns.get(name)
      const params = fn.params.map((p) => `${p.name}${p.optional ? '?' : ''}: ${p.type}`).join(', ')
      const rets = fn.returns.map((r) => r.type)
      const sig = `(${params})${rets.length ? ' → ' + rets.join(', ') : ''}`
      let summary = firstSentence(fn.summary)
      if (fn.alias) summary = `Alias of \`${fn.alias}\`.` + (summary ? ' ' + summary : '')
      if (!summary && fn.returns[0] && fn.returns[0].doc) summary = `Returns ${fn.returns[0].doc}.`
      L.push(`| \`${name}\` | \`${sig.replace(/\|/g, '\\|')}\` | ${oneLine(summary)} |`)
    }
    L.push('')
  }
  return L.join('\n').trimEnd()
}

// ---------------------------------------------------------------------------
// Refuses to guess where to write. A generated block with no marker is a
// hand-maintained block that LOOKS generated, which is the worst of both.
function replaceBetween(text, generated, label, open = BEGIN, close = END) {
  const begin = text.indexOf(open)
  const endIdx = text.indexOf(close)
  if (begin < 0 || endIdx < 0 || endIdx < begin) {
    throw new Error(`${label} has no ${open} / ${close} markers`)
  }
  return text.slice(0, begin + open.length) + '\n\n' + generated + '\n\n' + text.slice(endIdx)
}

// Compare and write in one line ending, always LF.
//
// Git may hand this file CRLF (core.autocrlf on a Windows checkout) while the
// generated string is LF. A raw byte compare then reports a phantom difference
// on a tree where nothing changed -- which trains everyone to ignore the
// staleness check, and an ignored staleness check catches no drift at all.
const nl = s => s.replace(/\r\n/g, '\n')

function main() {
  const check = process.argv.includes('--check')
  const api = loadApi()
  const surface = scanResource(root)
  let stale = false

  let modules
  try {
    modules = loadModules(api)
  } catch (e) {
    console.error(`FAIL ${e.message}`)
    process.exitCode = 1
    return
  }

  const types = buildTypes(api, surface, modules)
  const typesPath = path.join(root, OUT_TYPES)
  const existing = fs.existsSync(typesPath) ? nl(fs.readFileSync(typesPath, 'utf8')) : null
  if (existing !== nl(types)) {
    if (check) { console.error(`FAIL ${OUT_TYPES} is stale. Run: npm run gen-types`); stale = true } else {
      fs.mkdirSync(path.dirname(typesPath), { recursive: true })
      fs.writeFileSync(typesPath, nl(types))
      console.log(`wrote ${OUT_TYPES}`)
    }
  } else {
    console.log(`${OUT_TYPES} up to date`)
  }

  const docPath = path.join(root, OUT_DOC)
  const doc = nl(fs.readFileSync(docPath, 'utf8'))
  let nextDoc
  try {
    nextDoc = replaceBetween(doc, buildDocTables(api), OUT_DOC)
    nextDoc = replaceBetween(nextDoc, buildModuleDocs(modules), OUT_DOC, MOD_BEGIN, MOD_END)
  } catch (e) {
    console.error(String(e.message))
    process.exitCode = 1
    return
  }
  if (nextDoc !== doc) {
    if (check) { console.error(`FAIL ${OUT_DOC} is stale. Run: npm run gen-types`); stale = true } else {
      fs.writeFileSync(docPath, nl(nextDoc))
      console.log(`wrote ${OUT_DOC}`)
    }
  } else {
    console.log(`${OUT_DOC} up to date`)
  }

  // docs/V1.md §9: the frozen surface, from the same tables, so the spec the
  // owner signs off cannot list a name the code does not have.
  const v1Path = path.join(root, OUT_V1)
  if (fs.existsSync(v1Path)) {
    const v1 = nl(fs.readFileSync(v1Path, 'utf8'))
    let nextV1
    try {
      nextV1 = replaceBetween(v1, buildDocTables(api), OUT_V1, V1_BEGIN, V1_END)
    } catch (e) {
      console.error(String(e.message))
      process.exitCode = 1
      return
    }
    if (nextV1 !== v1) {
      if (check) { console.error(`FAIL ${OUT_V1} is stale. Run: npm run gen-types`); stale = true } else {
        fs.writeFileSync(v1Path, nl(nextV1))
        console.log(`wrote ${OUT_V1}`)
      }
    } else {
      console.log(`${OUT_V1} up to date`)
    }
  }

  if (stale) process.exitCode = 1
}

main()
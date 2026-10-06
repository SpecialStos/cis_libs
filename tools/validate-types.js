'use strict'

// The Stage 6 rules, split out of validate-api.js so the file that grew to a
// thousand lines is not also the file that grew by six hundred.
//
// Every rule here answers ONE question, and every one of them is a question
// that was unanswerable before 6.1:
//
//   E060  a `Cis.*` defined in init.lua that api.lua does not declare
//   E061  a `Cis.*` declared in api.lua that init.lua does not define
//   E062  a declared parameter name that is not the name in the code
//   E063  a `forwardsTo` that points nowhere, or at the wrong realm
//   E064  a type that names a class nobody declared
//   E065  an `any` with no recorded reason
//   E066  a class nothing references
//   E070  a client-only function with no refusal stub on the server
//
// WHY EACH ONE IS SEPARATE rather than one "the contract is stale" finding.
//
// A caller has one question per code and fixes one thing. Reporting all of it
// as one finding means the first fix reveals the second, and the person
// reruns to discover whether there was anything else -- which is the loop this
// project has been in repeatedly. Six findings means six fixes, and the last
// rerun is silent.

const { scanResourceDir } = require('./scan-cis.js')

// A type mentioning `any`, as a whole, as one arm of a union, or as one slot
// of a multi-slot return list. Splitting on all three separators is what makes
// "boolean, any" count: a return LIST is not a union, and a check that only
// looked for `|` waves the same defect through on the other side of a comma.
function mentionsAny(type) {
  return String(type).split(/[,|]/).some((s) => s.trim() === 'any')
}

const LUA_KEYWORDS = new Set([
  'any', 'boolean', 'function', 'integer', 'nil', 'number', 'string', 'table',
  'thread', 'userdata', 'self', 'true', 'false', 'unknown', 'void',
])

// Every identifier a type may name that is not a class: the LuaLS primitives,
// the FiveM ones, and the generics notation.
// `fun` IS TYPE SYNTAX, NOT A CLASS. Leaving it out of this list reported a
// class named `fun` for every callback signature in the manifest, which is a
// check firing on correct input -- the fastest way to make a rule be ignored.
const BUILTIN = /^(string|number|integer|boolean|table|thread|userdata|function|fun|vector2|vector3|vector4|quaternion|self|nil|any|unknown|void|true|false|keyof|typeof|unpack|select|assert)$/

// Split a type into its identifier tokens, so a reference to a class can be
// found wherever it appears: alone, in a union, in `CisFoo[]`, or in
// `table<string, CisFoo>`.
function typeTokens(type) {
  const out = []
  // A `fun(...)` ARGUMENT LIST IS REMOVED FIRST, and that is not tidiness. In
  // `fun(zone: CisZone, coords: vector3)` the tokens are `fun`, `zone`,
  // `CisZone`, `coords` and `vector3` -- and `zone` and `coords` are
  // PARAMETER NAMES, not types. Left in they look like classes nobody declared,
  // and the rule reports two classes that do not exist, on a type that is
  // correct. A check that fires on correct input teaches people to ignore it.
  //
  // And it must keep the TYPES inside. Dropping the whole argument list removed
  // `CisZone` along with the name `zone`, so the class CisZoneOptions names
  // for its callback parameters read as unreferenced -- and the rule then
  // reported a class a consumer's editor was about to use for every zone
  // completion as dead. Take what is AFTER each colon and throw the name away.
  const s = String(type || '').replace(/funs*(([^)]*))/g, (_, args) => 'fun'
    + args.split(',').map((a) => {
      const i = a.indexOf(':')
      return i === -1 ? '' : ' ' + a.slice(i + 1)
    }).join(''))
  const re = /[A-Za-z_][A-Za-z0-9_]*/g
  let m
  while ((m = re.exec(s)) !== null) {
    if (LUA_KEYWORDS.has(m[0])) continue
    if (BUILTIN.test(m[0])) continue
    out.push(m[0])
  }
  return out
}

// A params / returns block is EITHER a flat list or `{ server = ..., client = ... }`.
// Which one it is decides how many parameters it must carry, so a flat list
// where a pair belongs would be read as a one-realm declaration and pass.
function isRealmPair(block) {
  return !!(block && typeof block === 'object' && !Array.isArray(block)
    && (block.server !== undefined || block.client !== undefined))
}

// The list for ONE realm, or null when the shape is not a list at all.
//
// `{}` COUNTS AS AN EMPTY LIST. A zero-parameter export is written `params = {}`
// in Lua, and an empty Lua table comes back from the reader as an empty OBJECT
// -- there is no array part to make it an array, and `Array.isArray` on it is
// false. So a function that takes nothing was being reported as malformed, and
// the fix is to read the empty table as the empty list it is rather than to
// teach the writer to emit a shape Lua cannot produce.
function listFor(block, realm) {
  if (isRealmPair(block)) return Array.isArray(block[realm]) ? block[realm] : null
  if (Array.isArray(block)) return block
  if (block && typeof block === 'object' && Object.keys(block).length === 0) return []
  return null
}

function realmsOf(block, realms) {
  return isRealmPair(block) ? realms : [realms.length === 1 ? realms[0] : 'both']
}

function asList(block) {
  if (Array.isArray(block)) return block
  if (block === undefined || block === null) return null
  return null
}

// The parameter NAMES a realm block declares, or null when it is malformed.
function paramNames(block, realm) {
  const list = listFor(block, realm)
  if (list === null) return null
  return list.map((p) => (p && typeof p === 'object' ? p.name : undefined))
}

function checkParams(r, where, block, codeNames, realm) {
  if (block === undefined) {
    r.add('E014', `${where}.params[${realm}]`, 'is required: every parameter must declare a name, a type and a doc')
    return
  }
  const list = listFor(block, realm)
  if (list === null) {
    r.add('E014', `${where}.params[${realm}]`, 'must be a list of { name, type, ... } or a { server = ..., client = ... } pair')
    return
  }
  if (false) {
    r.add('E014', `${where}.params[${realm}]`, `has no entry, while the function exists on realm '${realm}'`)
    return
  }
  list.forEach((p, i) => {
    const at = `${where}.params[${realm}][${i}]`
    if (!p || typeof p !== 'object' || Array.isArray(p)) {
      r.add('E014', at, 'must be a table with at least `name` and `type`')
      return
    }
    if (typeof p.name !== 'string' || p.name === '') {
      r.add('E014', `${at}.name`, 'is required, and it must be the name the code registers')
    }
    if (typeof p.type !== 'string' || p.type.trim() === '') {
      r.add('E014', `${at}.type`, 'is required: an untyped parameter is a promise nobody kept')
    }
    if (typeof p.doc !== 'string' || p.doc.trim() === '') {
      r.add('E014', `${at}.doc`, 'is required: a name a consumer cannot act on is not documentation')
    }
    // THE `any` RULE. The one type this library cannot avoid, because a
    // provider's value is the provider's to describe. It is not banned, because
    // a ban would be met by a confident wrong type. It is required to say why,
    // and the reason is what a future reader weighs when the seam changes.
    if (typeof p.type === 'string' && mentionsAny(p.type) && !p.why) {
      r.add('E065', at, `is typed \`${p.type}\` with no \`why\`. The gate is zero UNDOCUMENTED any: a reason nobody wrote is a promise nobody checked.`)
    }
  })

  if (Array.isArray(codeNames)) {
    const declared = paramNames(block, realm)
    if (declared && declared.join(', ') !== codeNames.join(', ')) {
      r.add('E062', `${where}.params[${realm}]`,
        `declares (${declared.join(', ')}) but the code defines (${codeNames.join(', ')})`)
    }
  }
}

function checkReturns(r, where, block, realm) {
  if (block === undefined) {
    r.add('E015', `${where}.returns[${realm}]`, 'is required: a function with no declared return is a function with no contract')
    return
  }
  const list = listFor(block, realm)
  if (list === null) {
    r.add('E015', `${where}.returns[${realm}]`, 'must be a list of { type, ... } or a { server = ..., client = ... } pair')
    return
  }
  if (false) {
    r.add('E015', `${where}.returns[${realm}]`, `has no entry, while the function exists on realm '${realm}'`)
    return
  }
  list.forEach((ret, i) => {
    const at = `${where}.returns[${realm}][${i}]`
    if (!ret || typeof ret !== 'object' || Array.isArray(ret)) {
      r.add('E015', at, 'must be a table with at least `type`')
      return
    }
    if (typeof ret.type !== 'string' || ret.type.trim() === '') {
      r.add('E015', `${at}.type`, 'is required')
    }
    if (typeof ret.doc !== 'string' || ret.doc.trim() === '') {
      r.add('E015', `${at}.doc`, 'is required, and it is where the refusal shape is written down')
    }
    if (typeof ret.type === 'string' && mentionsAny(ret.type) && !ret.why) {
      r.add('E065', at, `is typed \`${ret.type}\` with no \`why\``)
    }
  })
}

// ------------------------------------------------------------------ exports

function checkExports(r, declared, surface, classNames) {
  const registered = { server: new Map(), client: new Map() }
  for (const e of surface.exports) registered[e.realm].set(e.name, e)

  for (const [name, meta] of Object.entries(declared)) {
    const where = `exports.${name}`
    const realm = meta.realm === undefined ? 'both' : meta.realm
    const realms = realm === 'both' ? ['server', 'client'] : [realm]

    for (const rm of realms) {
      const actual = registered[rm].get(name)
      if (!actual) {
        r.add('E030', where, `declared for realm '${rm}' but the resource never registers it there`)
        continue
      }
      if (!actual.resolved) {
        r.add('E033', `${where}.params[${rm}]`, `cannot be verified against the source (${actual.via}: ${actual.why})`)
        continue
      }
      checkParams(r, where, meta.params, actual.params, rm)
    }
    if (meta.params !== undefined) {
      for (const rm of realms) checkReturns(r, where, meta.returns, rm)
    }
    collectTypes(meta.params, classNames)
    collectTypes(meta.returns, classNames)
  }
}

function collectTypes(block, into) {
  if (!block || typeof block !== 'object') return
  const lists = isRealmPair(block) ? [block.server, block.client] : [block]
  for (const list of lists) {
    if (!Array.isArray(list)) continue
    for (const item of list) {
      if (!item || typeof item !== 'object') continue
      if (typeof item.type === 'string') for (const t of typeTokens(item.type)) into.add(t)
    }
  }
}

// ------------------------------------------------------- the Cis.* functions

function checkFunctions(r, manifest, resourceDir, declaredExports, classNames) {
  const surface = scanResourceDir(resourceDir)

  // A scanner that did not read the file cleanly is not a clean surface. Zero
  // names is the exact output of a mis-parse, and treating it as "nothing to
  // check" is how a validator passes by finding nothing.
  if (surface.unclosed !== 0 || surface.lost.length !== 0) {
    r.add('E059', 'init.lua',
      `tools/scan-cis.js could not read the file cleanly: ${surface.unclosed} unclosed block(s) and `
      + `${surface.lost.length} lost definition(s). Every Cis.* check below is SKIPPED, because a check `
      + 'that ran against a half-read file would report coverage it does not have.')
    return { checked: 0, skipped: true }
  }
  if (surface.count === 0) {
    r.add('E059', 'init.lua', 'no `Cis.*` definitions were read. A surface of zero is what a mis-parse produces, and it is indistinguishable from a file with no surface, so it fails rather than passes.')
    return { checked: 0, skipped: true }
  }

  const declared = manifest.functions
  if (declared === undefined) {
    r.add('E059', 'functions', 'is required: the `Cis.*` surface is what a consumer calls, and it is not declared anywhere else')
    return { checked: 0, skipped: true }
  }
  if (typeof declared !== 'object' || Array.isArray(declared)) {
    r.add('E059', 'functions', 'must be a table keyed by `Cis.<ns>.<fn>`')
    return { checked: 0, skipped: true }
  }

  const inCode = new Map(surface.entries.map((e) => [e.name, e]))

  // --- declared but not in the code
  for (const [name, meta] of Object.entries(declared)) {
    const where = `functions['${name}']`
    const code = inCode.get(name)
    if (!code) {
      r.add('E061', where, 'is declared in api.lua but init.lua does not define it. A consumer with this in their completions calls nothing.')
      continue
    }
    if (!meta || typeof meta !== 'object') {
      r.add('E010', where, 'must be a table')
      continue
    }
    if (typeof meta.since !== 'string' || !/^\d+\.\d+\.\d+$/.test(meta.since)) {
      r.add('E010', `${where}.since`, `is required and must be MAJOR.MINOR.PATCH (got ${JSON.stringify(meta.since)})`)
    }
    const realm = meta.realm
    if (!['server', 'client', 'both'].includes(realm)) {
      r.add('E020', `${where}.realm`, `must be 'server', 'client' or 'both' (got ${JSON.stringify(realm)})`)
      continue
    }
    const codeRealms = code.realms
    const agrees = realm === 'both'
      ? (codeRealms.length === 1 && codeRealms[0] === 'both')
        || (codeRealms.includes('client') && codeRealms.includes('server'))
      : codeRealms.includes(realm)
    if (!agrees) {
      r.add('E020', `${where}.realm`,
        `is '${realm}' but init.lua defines the real function on ${codeRealms.join(' and ')}`)
    }

    // PARAMETER NAMES, per realm, allowing a declared re-binding offset.
    const declaredRealms = ['server', 'client'].filter((rm) => isRealmPair(meta.params) && meta.params[rm])
    const useRealms = declaredRealms.length > 0 ? declaredRealms : [realm === 'both' ? 'both' : realm]
    for (const rm of useRealms) {
      const offset = (meta.from && meta.from[rm]) || 0
      const variant = code.variants.find((v) => !v.refusal && (v.realm === rm || rm === 'both'))
        || code.variants.find((v) => !v.refusal)
      if (!variant) continue
      const codeNames = offset > 0 ? variant.names.slice(offset) : variant.names
      checkParams(r, where, meta.params, codeNames, rm)
    }
    for (const rm of isRealmPair(meta.returns) ? ['server', 'client'] : [realm]) {
      checkReturns(r, where, meta.returns, rm)
    }
    collectTypes(meta.params, classNames)
    collectTypes(meta.returns, classNames)

    // --- forwardsTo
    if (meta.forwardsTo !== undefined) {
      const target = declaredExports[meta.forwardsTo]
      if (!target) {
        r.add('E063', `${where}.forwardsTo`,
          `is '${meta.forwardsTo}', which api.lua does not declare as an export. A proxy that crosses to nothing answers nothing.`)
      } else {
        const tRealm = target.realm === undefined ? 'both' : target.realm
        const tRealms = tRealm === 'both' ? ['server', 'client'] : [tRealm]
        if (realm !== 'both' && !tRealms.includes(realm)) {
          r.add('E063', `${where}.forwardsTo`,
            `is '${meta.forwardsTo}', which is registered on ${tRealms.join(' and ')} -- and this function is on '${realm}'. `
            + 'A client proxy cannot reach a server-only export; the call crosses into a Lua state that does not have it.')
        }
      }
    }

    // --- the refusal stub
    if (realm === 'client') {
      const stub = code.variants.find((v) => v.refusal === 'client' && v.realm === 'server')
      if (!stub) {
        r.add('E070', where,
          'is a client-only function, but init.lua has no `return false, \'client only\'` stub for it on the server. '
          + 'Without the stub the call is "attempt to call a nil value" in the CALLER\'s thread, which names neither the cause nor the fix.')
      }
    }
  }

  // --- in the code but not declared
  for (const e of surface.entries) {
    if (!Object.prototype.hasOwnProperty.call(declared, e.name)) {
      r.add('E060', `functions['${e.name}']`,
        `is defined in init.lua (line ${e.lines[0]}) but not declared in api.lua. This is the surface a consumer calls, so an undeclared one is a function with no completions, no types and no contract.`)
    }
  }

  return { checked: surface.count, skipped: false }
}

// ------------------------------------------------------------------ classes

function checkClasses(r, manifest, classNames) {
  // A CLASS FIELD'S TYPE IS A REFERENCE. CisZone is named from exactly one
  // place in the whole manifest -- a callback signature inside
  // CisZoneOptions -- and a scanner that looked only at parameters and returns
  // would report a class nobody uses that a consumer's editor is about to use
  // for the completion of every zone callback.
  for (const c of Object.values(manifest.classes || {})) {
    if (c && Array.isArray(c.fields)) {
      for (const f of c.fields) {
        if (f && typeof f.type === 'string') for (const t of typeTokens(f.type)) classNames.add(t)
      }
    }
  }
  const classes = manifest.classes
  if (classes === undefined) {
    r.add('E064', 'classes', 'is required: types name classes, and a class nobody declared is a completion nobody gets')
    return
  }
  if (typeof classes !== 'object' || Array.isArray(classes)) {
    r.add('E064', 'classes', 'must be a table keyed by class name')
    return
  }
  const declared = new Set(Object.keys(classes))
  for (const [name, c] of Object.entries(classes)) {
    const where = `classes.${name}`
    if (!c || typeof c !== 'object') {
      r.add('E064', where, 'must be a table with a doc and a fields list')
      continue
    }
    if (typeof c.doc !== 'string' || c.doc.trim() === '') {
      r.add('E064', `${where}.doc`, 'is required')
    }
    if (!Array.isArray(c.fields) || c.fields.length === 0) {
      r.add('E064', `${where}.fields`, 'must be a non-empty list, or the class describes nothing')
      continue
    }
    c.fields.forEach((f, i) => {
      if (!f || typeof f !== 'object' || typeof f.name !== 'string' || typeof f.type !== 'string') {
        r.add('E064', `${where}.fields[${i}]`, 'must be a table with at least `name` and `type`')
      }
    })
  }
  // Every class a type names must exist. The other direction too: a class
  // nothing references is dead weight that reads as coverage.
  for (const ref of classNames) {
    if (!declared.has(ref)) {
      r.add('E064', `classes.${ref}`,
        `is referenced by a declared type but is not declared. A type that names a class nobody wrote is a completion nobody gets, and it is invisible in review because it reads as a real type.`)
    }
  }
  for (const name of declared) {
    if (!classNames.has(name)) {
      r.add('E066', `classes.${name}`,
        'is declared but no type in api.lua references it. A class nothing names is a second answer to a question nobody asked, and it will drift.')
    }
  }
}

module.exports = {
  checkExports, checkFunctions, checkClasses, collectTypes, mentionsAny, typeTokens, isRealmPair,
}

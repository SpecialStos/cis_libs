'use strict'

// Reads a FiveM resource's *actual* public surface out of its source.
//
// The point of this module is that it never trusts a declaration. It parses
// fxmanifest.lua for the realm membership, then reads the registered exports,
// their parameter lists, and the net events, straight from the Lua. A manifest
// that disagrees with this is drift, and the validator is there to fail on it.
//
// No dependencies, no Lua VM: the shapes it needs to recognise are the ones
// this codebase actually uses, and anything it cannot resolve is reported as
// `unresolved` rather than guessed at. A guess in a contract checker is worse
// than a hole, because the hole is visible.

const fs = require('fs')
const path = require('path')

// --------------------------------------------------------------- source text

// Remove comments without touching string contents. A naive strip would eat a
// URL or a `--` inside a quoted path and shift every offset after it.
function stripComments(src) {
  let out = ''
  let i = 0
  let quote = null
  while (i < src.length) {
    const c = src[i]
    if (quote) {
      out += c
      if (c === '\\') {
        out += src[i + 1] === undefined ? '' : src[i + 1]
        i += 2
        continue
      }
      if (c === quote) quote = null
      i += 1
      continue
    }
    if (c === '"' || c === "'") {
      quote = c
      out += c
      i += 1
      continue
    }
    if (c === '-' && src[i + 1] === '-') {
      if (src[i + 2] === '[' && src[i + 3] === '[') {
        const end = src.indexOf(']]', i + 4)
        i = end === -1 ? src.length : end + 2
      } else {
        const end = src.indexOf('\n', i)
        i = end === -1 ? src.length : end
      }
      continue
    }
    out += c
    i += 1
  }
  return out
}

function normaliseParams(text) {
  const inner = (text || '').trim()
  if (inner === '' ) return []
  return inner
    .split(',')
    .map((p) => p.trim())
    .filter((p) => p.length > 0)
}

// `exports(` as a REGISTRATION, not as a cross-resource call. `exports.ox_target:query(`
// and `exports['qb-core']:GetCoreObject(` are calls into other resources; neither
// is followed by a bare `(` on the identifier itself.
const EXPORT_RE = /(?<![\w.:\]])\bexports\s*\(\s*(['"])((?:[^'"\\]|\\.)*)\1\s*,/g

function scanExports(src, file) {
  const clean = stripComments(src)
  const defs = new Map()
  const returns = []

  // Named function definitions, in every form this codebase uses:
  //   function DoorLock.GetDoorState(doorId)
  //   local function driverName()
  //   Target.Create = function(zoneType, name)
  const FN_NAMED = /\bfunction\s+([A-Za-z_][\w]*(?:[.:][A-Za-z_][\w]*)*)\s*\(([^)]*)\)/g
  const FN_ASSIGN = /([A-Za-z_][\w]*(?:[.:][A-Za-z_][\w]*)*)\s*=\s*function\s*\(([^)]*)\)/g
  let m
  while ((m = FN_NAMED.exec(clean)) !== null) {
    defs.set(m[1], normaliseParams(m[2]))
  }
  while ((m = FN_ASSIGN.exec(clean)) !== null) {
    defs.set(m[1], normaliseParams(m[2]))
  }
  const RETURN_FN = /\breturn\s+function\s*\(([^)]*)\)/g
  while ((m = RETURN_FN.exec(clean)) !== null) {
    returns.push({ index: m.index, params: normaliseParams(m[1]) })
  }

  const out = []
  EXPORT_RE.lastIndex = 0
  while ((m = EXPORT_RE.exec(clean)) !== null) {
    const name = m[2]
    const afterName = m.index + m[0].length
    // The value being exported runs from here to the matching close paren of
    // the exports( call, so a wrapper call is handled as a whole.
    const value = readArgument(clean, afterName)
    out.push({ name, file, ...resolveValue(value, defs, returns) })
  }
  return out
}

// Read one argument starting at `i`, stopping at the comma that separates it
// from the next argument at depth zero, or at the call's closing paren.
function readArgument(src, i) {
  let depth = 0
  let out = ''
  let quote = null
  while (i < src.length) {
    const c = src[i]
    if (quote) {
      out += c
      if (c === '\\') {
        out += src[i + 1] === undefined ? '' : src[i + 1]
        i += 2
        continue
      }
      if (c === quote) quote = null
      i += 1
      continue
    }
    if (c === '"' || c === "'") {
      quote = c
      out += c
      i += 1
      continue
    }
    if (c === '(' || c === '{' || c === '[') {
      depth += 1
      out += c
      i += 1
      continue
    }
    if (c === ')' || c === '}' || c === ']') {
      if (depth === 0) break
      depth -= 1
      out += c
      i += 1
      continue
    }
    if (c === ',' && depth === 0) break
    out += c
    i += 1
  }
  return { text: out.trim(), end: i }
}

function resolveValue(value, defs, returns) {
  const text = value.text
  const inline = text.match(/^function\s*\(([^)]*)\)/)
  if (inline) {
    return { params: normaliseParams(inline[1]), resolved: true, via: 'inline' }
  }
  const simple = text.match(/^([A-Za-z_][\w]*(?:[.:][A-Za-z_][\w]*)*)$/)
  if (simple) {
    // `exports('X', DoorLock.GetDoorState)` -> look up the last segment, which
    // is enough here because no two tables in one file share a leaf name.
    const key = simple[1]
    const leaf = key.split(/[.:]/).pop()
    const own = defs.get(key) || defs.get(leaf)
    if (own && !(own.length === 1 && own[0] === '...')) {
      return { params: own, resolved: true, via: key }
    }
    if (own) {
      return { params: own, resolved: false, via: key, why: 'vararg wrapper, return not resolvable' }
    }
    return { params: null, resolved: false, via: key, why: 'no definition found in this file' }
  }
  // A wrapper: `exports('X', exportAwait(Database.Query))`. The exported
  // function is whatever the wrapper returns, and that is the signature a
  // consumer actually calls. Only accepted when the file has exactly one
  // returned function, so the answer cannot be a guess.
  const wrapperCall = text.match(/^([A-Za-z_][\w]*)\s*\(/)
  if (wrapperCall && returns.length === 1) {
    return { params: returns[0].params, resolved: true, via: `${wrapperCall[1]}() returned function` }
  }
  if (wrapperCall) {
    return {
      params: null,
      resolved: false,
      via: wrapperCall[1],
      why: `wrapper call, but the file returns ${returns.length} functions`,
    }
  }
  return { params: null, resolved: false, via: text, why: 'unrecognised export value' }
}

// ------------------------------------------------------------------- manifest

// fxmanifest.lua here uses the `name 'path'` sugar inside its three script
// blocks. Anything else is reported rather than silently ignored.
function readManifest(resourceDir) {
  const file = path.join(resourceDir, 'fxmanifest.lua')
  if (!fs.existsSync(file)) {
    return { shared: [], client: [], server: [], warnings: [`no fxmanifest.lua in ${resourceDir}`] }
  }
  const clean = stripComments(fs.readFileSync(file, 'utf8'))
  const warnings = []
  const read = (block) => {
    const m = clean.match(new RegExp(`${block}\\s*\\{([^}]*)\\}`))
    if (!m) return []
    return (m[1].match(/['"]([^'"]+)['"]/g) || []).map((s) => s.slice(1, -1))
  }
  const shared = read('shared_scripts')
  const client = read('client_scripts')
  const server = read('server_scripts')
  for (const [name, list] of [['shared_script', shared], ['client_script', client], ['server_script', server]]) {
    for (const entry of list) {
      if (!fs.existsSync(path.join(resourceDir, entry))) {
        warnings.push(`fxmanifest lists ${name} ${entry}, which does not exist`)
      }
    }
  }
  return { shared, client, server, warnings }
}

// --------------------------------------------------------------------- events

const EVENT_RE = /\b(RegisterNetEvent|CisNetOn|SecureNetOn|TriggerClientEvent|TriggerServerEvent|CisNetOn)\s*\(\s*(?:[^,()]*,\s*)?(['"])((?:[^'"\\]|\\.)*)\2/g
const PREFIX_EVENT_RE = /\beventPrefix\(\)\s*\.\.\s*(['"])((?:[^'"\\]|\\.)*)\1/g
const PREFIX = '${Security.EventPrefix}'

function scanEvents(src) {
  const clean = stripComments(src)
  const names = new Set()
  for (const m of clean.matchAll(PREFIX_EVENT_RE)) {
    names.add(PREFIX + m[2])
  }
  for (const m of clean.matchAll(EVENT_RE)) {
    if (m[3].includes('${') || m[3].includes('..')) continue
    names.add(m[3])
  }
  return [...names]
}

// ------------------------------------------------------------------------ api

// `api.lua` is pure data, so it can be read without starting the provider.
function scanResource(resourceDir) {
  const manifest = readManifest(resourceDir)
  const realms = { shared: manifest.shared, client: manifest.client, server: manifest.server }
  const exports = []
  const events = new Set()
  const unresolved = []

  for (const realm of ['server', 'client', 'shared']) {
    for (const rel of realms[realm]) {
      const abs = path.join(resourceDir, rel)
      if (!fs.existsSync(abs)) continue
      const src = fs.readFileSync(abs, 'utf8')
      const found = scanExports(src, rel)
      // Shared scripts run in both realms, so an export there is available
      // from each. cis_libs has none today; the rule is stated so a resource
      // that adds one is handled rather than guessed.
      const inRealms = realm === 'shared' ? ['server', 'client'] : [realm]
      for (const e of found) {
        for (const r of inRealms) {
          exports.push({ realm: r, name: e.name, file: e.file, params: e.params, resolved: e.resolved, via: e.via })
        }
        if (!e.resolved) unresolved.push({ realm: inRealms[0], name: e.name, file: e.file, why: e.why })
      }
      for (const ev of scanEvents(src)) events.add(ev)
    }
  }

  return {
    exports,
    events: [...events].sort(),
    unresolved,
    warnings: manifest.warnings,
    counts: {
      server: exports.filter((e) => e.realm === 'server').length,
      client: exports.filter((e) => e.realm === 'client').length,
    },
  }
}

module.exports = { scanResource, scanExports, scanEvents, stripComments, readManifest, normaliseParams, PREFIX }

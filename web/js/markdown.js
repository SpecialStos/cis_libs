// Safe markdown subset: **bold**, *italic* / _italic_, `code`, [text](https://url),
// newline -> <br>, blank line -> paragraph. Input is untrusted: it becomes a
// node tree whose text is only ever written as text nodes, through a fixed set
// of tags (buildDom). There is no markup path at all. Pure, no imports.

const MAX_SOURCE = 8000
const MAX_DEPTH = 4
const SAFE_URL = /^(?:https?:\/\/|nui:\/\/)[^\s<>"'`\\]+$/i

export function safeUrl(value) {
  const url = String(value ?? '').trim()
  return SAFE_URL.test(url) ? url : null
}

const isWord = (c) => c !== undefined && /[\p{L}\p{N}]/u.test(c)

// Closing `*`/`_`: not after a space; `_` not before a word char (snake_case).
function findClose(src, ch, from) {
  for (let j = from; j < src.length; j++) {
    if (src[j] === '\n' && src[j + 1] === '\n') return -1
    if (src[j] !== ch || src[j - 1] === ' ' || src[j - 1] === '\\') continue
    if (ch === '*' && src[j + 1] === '*') { j++; continue }
    if (ch === '_' && isWord(src[j + 1])) continue
    return j
  }
  return -1
}

export function parseInline(src, depth = 0) {
  const out = []
  let buf = ''
  const flush = () => { if (buf) { out.push({ t: 'text', v: buf }); buf = '' } }
  const nested = depth < MAX_DEPTH
  let i = 0
  while (i < src.length) {
    const c = src[i]
    const next = src[i + 1]
    if (c === '\\' && next !== undefined && '\\`*_[]()'.includes(next)) { buf += next; i += 2; continue }
    if (c === '\n') { flush(); out.push({ t: 'br' }); i++; continue }
    if (c === '`') {
      const end = src.indexOf('`', i + 1)
      if (end > i + 1) { flush(); out.push({ t: 'code', v: src.slice(i + 1, end) }); i = end + 1; continue }
    }
    if (nested && c === '*' && next === '*') {
      let end = src.indexOf('**', i + 2)
      if (src[end + 2] === '*') end++ // `***` closes an inner *italic* first
      if (end > i + 2) { flush(); out.push({ t: 'b', c: parseInline(src.slice(i + 2, end), depth + 1) }); i = end + 2; continue }
    }
    if (nested && (c === '*' || c === '_') && next !== undefined && next !== ' ' && next !== c
      && !(c === '_' && isWord(src[i - 1]))) {
      const end = findClose(src, c, i + 1)
      if (end > i + 1) { flush(); out.push({ t: 'i', c: parseInline(src.slice(i + 1, end), depth + 1) }); i = end + 1; continue }
    }
    if (nested && c === '[') {
      const m = /^\[([^\]\n]+)\]\(((?:[^()\s]|\([^()\s]*\))+)\)/.exec(src.slice(i, i + 2100))
      if (m) {
        flush()
        const href = safeUrl(m[2])
        const kids = parseInline(m[1], depth + 1)
        if (href) out.push({ t: 'a', href, c: kids })
        else out.push(...kids)
        i += m[0].length
        continue
      }
    }
    buf += c
    i++
  }
  flush()
  return out
}

export function parseMarkdown(source) {
  const src = String(source ?? '').replace(/\r\n?/g, '\n').slice(0, MAX_SOURCE)
  return src.split(/\n[ \t]*\n+/).map((p) => p.replace(/^\n+|\n+$/g, ''))
    .filter((p) => p.length > 0)
    .map((p) => ({ t: 'p', c: parseInline(p) }))
}

const TAGS = { p: 'p', b: 'strong', i: 'em', code: 'code', a: 'a' }

export function buildDom(nodes, doc, parent) {
  for (const n of nodes) {
    if (n.t === 'text') { parent.appendChild(doc.createTextNode(n.v)); continue }
    if (n.t === 'br') { parent.appendChild(doc.createElement('br')); continue }
    const tag = TAGS[n.t]
    if (!tag) continue
    const el = doc.createElement(tag)
    if (n.t === 'code') el.appendChild(doc.createTextNode(n.v))
    else buildDom(n.c, doc, el)
    if (n.t === 'a') {
      el.setAttribute('href', n.href)
      el.setAttribute('rel', 'noopener noreferrer')
    }
    parent.appendChild(el)
  }
  return parent
}

// One block, no paragraphs (labels, text UI).
export function parseLine(source) {
  return parseInline(String(source ?? '').replace(/\r\n?/g, '\n').slice(0, MAX_SOURCE))
}

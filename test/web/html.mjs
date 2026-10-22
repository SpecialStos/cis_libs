// A string serialiser for the shipped markdown tree, used by the tests only.
// It escapes every text value, so asserting on its output proves the parser
// never lets input become structure: anything that is not one of the tags
// below came out of the tree as text.
import { parseMarkdown } from '../../web/js/markdown.js'

export function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"'`=/]/g, (c) => '&#' + c.charCodeAt(0) + ';')
}

const TAGS = { p: 'p', b: 'strong', i: 'em' }

export function toHtml(nodes) {
  let s = ''
  for (const n of nodes) {
    if (n.t === 'text') s += escapeHtml(n.v)
    else if (n.t === 'br') s += '<br>'
    else if (n.t === 'code') s += '<code>' + escapeHtml(n.v) + '</code>'
    else if (n.t === 'a') s += '<a href="' + escapeHtml(n.href) + '" rel="noopener noreferrer">' + toHtml(n.c) + '</a>'
    else if (TAGS[n.t]) s += '<' + TAGS[n.t] + '>' + toHtml(n.c) + '</' + TAGS[n.t] + '>'
    else throw new Error('unknown node type ' + n.t)
  }
  return s
}

export const renderHtml = (source) => toHtml(parseMarkdown(source))

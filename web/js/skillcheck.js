import { h, svg, on, post, t, layer } from './core.js'
import { resolveDifficulty, makeRound, angleAt, judge, expired } from './skill.js'

// Keys arrive from Lua (the game keeps focus); this owns clock and verdict.
let s = null

function finish(success) {
  if (!s) return
  const { id, el, raf } = s
  cancelAnimationFrame(raf)
  s = null
  el.remove()
  if (success !== undefined) post('skill', { id, success })
}

function startRound() {
  const round = makeRound(s.diffs[s.index], s.keys)
  Object.assign(s, { round, t0: performance.now() })
  s.zone.setAttribute('stroke-dasharray', `${round.size} ${360 - round.size}`)
  s.zone.setAttribute('stroke-dashoffset', String(-round.start))
  s.key.textContent = round.key.toUpperCase()
  s.el.setAttribute('aria-label', t('pressKey', { key: round.key.toUpperCase() }))
  s.raf = requestAnimationFrame(frame)
}

function frame() {
  if (!s) return
  const a = angleAt(s.round, performance.now() - s.t0)
  s.needle.setAttribute('transform', `rotate(${Math.min(a, 360)} 50 50)`)
  if (expired(s.round, a)) finish(false)
  else s.raf = requestAnimationFrame(frame)
}

on('skill:start', (d) => {
  finish(s ? false : undefined)
  const diffs = (Array.isArray(d.rounds) ? d.rounds : [d.rounds]).map(resolveDifficulty).filter(Boolean)
  if (!diffs.length) return post('skill', { id: d.id, success: false })
  const keys = (Array.isArray(d.keys) ? d.keys : []).filter((k) => typeof k === 'string' && k.length <= 2)
  const ring = svg('svg', { viewBox: '0 0 100 100', 'aria-hidden': 'true' })
  const g = svg('g', { transform: 'rotate(-90 50 50)' })
  const zone = svg('circle', { cx: 50, cy: 50, r: 40, pathLength: 360, class: 'cis-zone' })
  g.append(svg('circle', { cx: 50, cy: 50, r: 40 }), zone)
  const needle = svg('line', { x1: 50, y1: 4, x2: 50, y2: 18 })
  ring.append(g, needle)
  const key = h('kbd', { class: 'cis-key' })
  const el = h('div', { class: 'cis-skill cis-anim', role: 'img' }, ring, key)
  layer('cis-skill').replaceChildren(el)
  s = { id: d.id, diffs, keys: keys.length ? keys : ['e'], index: 0, el, zone, needle, key, raf: 0 }
  startRound()
})

on('skill:key', (d) => {
  if (!s || typeof d.key !== 'string') return
  cancelAnimationFrame(s.raf)
  if (judge(s.round, angleAt(s.round, performance.now() - s.t0), d.key) !== 'hit') return finish(false)
  s.index += 1
  if (s.index >= s.diffs.length) finish(true)
  else startRound()
})

on('skill:stop', () => finish())

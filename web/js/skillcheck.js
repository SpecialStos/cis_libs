import { h, svg, on, t, layer } from './core.js'
import { angleAt } from './skill.js'

// Draws the round Lua sends. Lua owns the keys, the clock and the verdict, so
// nothing here reports a result: the page cannot pass or fail a check.
let s = null

function finish() {
  if (!s) return
  cancelAnimationFrame(s.raf)
  s.el.remove()
  s = null
}

function build(id) {
  const ring = svg('svg', { viewBox: '0 0 100 100', 'aria-hidden': 'true' })
  const g = svg('g', { transform: 'rotate(-90 50 50)' })
  const zone = svg('circle', { cx: 50, cy: 50, r: 40, pathLength: 360, class: 'cis-zone' })
  g.append(svg('circle', { cx: 50, cy: 50, r: 40 }), zone)
  const needle = svg('line', { x1: 50, y1: 4, x2: 50, y2: 18 })
  ring.append(g, needle)
  const key = h('kbd', { class: 'cis-key' })
  const el = h('div', { class: 'cis-skill cis-anim', role: 'img' }, ring, key)
  layer('cis-skill').replaceChildren(el)
  return { id, el, zone, needle, key, raf: 0 }
}

function frame() {
  if (!s) return
  const a = angleAt(s.round, performance.now() - s.t0)
  s.needle.setAttribute('transform', `rotate(${Math.min(a, 360)} 50 50)`)
  if (a < 360) s.raf = requestAnimationFrame(frame)
}

on('skill:round', (d) => {
  const num = (v, lo, hi) => (typeof v === 'number' && Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : null)
  const round = { start: num(d.start, 0, 360), size: num(d.size, 1, 360), degPerMs: num(d.degPerMs, 0.001, 10), key: String(d.key ?? '').slice(0, 2) }
  if (round.start === null || round.size === null || round.degPerMs === null) return
  if (!s || s.id !== d.id) { finish(); s = build(d.id) }
  cancelAnimationFrame(s.raf)
  Object.assign(s, { round, t0: performance.now() })
  s.zone.setAttribute('stroke-dasharray', `${round.size} ${360 - round.size}`)
  s.zone.setAttribute('stroke-dashoffset', String(-round.start))
  s.key.textContent = round.key.toUpperCase()
  s.el.setAttribute('aria-label', t('pressKey', { key: round.key.toUpperCase() }))
  s.raf = requestAnimationFrame(frame)
})

on('skill:stop', (d) => { if (s && (!d || d.id === undefined || d.id === s.id)) finish() })

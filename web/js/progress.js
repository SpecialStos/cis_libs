import { h, svg, on, setting, t, leave, layer, reducedMotion } from './core.js'

// The fill is a CSS animation. The circle's % follows it each frame; the bar,
// or anything under reduced motion, updates aria-valuenow four times a second,
// so a screen reader is not stuck at 0 for the whole action.
let current = null

function stop() {
  if (!current) return
  cancelAnimationFrame(current.raf)
  clearTimeout(current.timer)
  leave(current.el)
  current = null
}

on('progress:start', (d) => {
  stop()
  const duration = Math.max(0, Number(d.duration) || 0)
  const label = typeof d.label === 'string' ? d.label : ''
  let text = null
  let body
  if (d.kind === 'circle') {
    text = h('span', { class: 'cis-shadowtext', text: '0%' })
    const ring = svg('svg', { viewBox: '0 0 100 100', 'aria-hidden': 'true' })
    ring.append(svg('circle', { cx: 50, cy: 50, r: 44, pathLength: 100 }), svg('circle', { cx: 50, cy: 50, r: 44, pathLength: 100, class: 'cis-fill' }))
    body = h('div', { class: 'cis-ring' }, ring, text)
  } else {
    body = h('div', { class: 'cis-track' }, h('div', { class: 'cis-fill' }))
  }
  const el = h('div', {
    class: 'cis-progress cis-anim', 'data-pos': d.position || setting('progressPosition'),
    style: { '--cis-duration': `${duration}ms` }, role: 'progressbar', 'aria-label': label || 'progress', 'aria-valuemin': 0, 'aria-valuemax': 100,
  }, label && h('div', { class: 'cis-shadowtext', text: label }), body, d.canCancel && h('div', { class: 'cis-hint cis-shadowtext', text: t('progressCancel') }))
  layer('cis-progress').appendChild(el)
  const self = { el, raf: 0, timer: 0 }
  current = self
  const started = performance.now()
  const tick = () => {
    if (current !== self) return
    const p = duration ? Math.min(100, Math.floor(((performance.now() - started) / duration) * 100)) : 100
    el.setAttribute('aria-valuenow', String(p))
    if (text) text.textContent = `${p}%`
    if (p >= 100) return
    if (text && !reducedMotion()) self.raf = requestAnimationFrame(tick)
    else self.timer = setTimeout(tick, 250)
  }
  tick()
})

on('progress:stop', stop)

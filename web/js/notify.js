import { h, icon, markdown, on, setting, t, leave, layer } from './core.js'
import { createQueue } from './queue.js'

// One setTimeout per visible toast; nothing runs when none are shown.
const TYPE_ICON = { inform: 'info', success: 'check', warning: 'warning', error: 'error' }
const queue = createQueue({ max: setting('notifyMax') })
const live = new Map() // key -> { el, timer }

function lane(pos) {
  const parent = layer('cis-notify')
  let el = [...parent.childNodes].find((c) => c.dataset?.pos === pos)
  if (!el) {
    el = h('section', { class: 'cis-toasts', 'data-pos': pos, 'aria-label': t('notifications') })
    el.dataset.pos = pos
    parent.appendChild(el)
  }
  return el
}

function fill(el, n) {
  const error = n.type === 'error'
  el.className = `cis-toast cis-anim cis-type-${n.type}`
  el.setAttribute('role', error ? 'alert' : 'status')
  el.setAttribute('aria-live', error ? 'assertive' : 'polite')
  el.replaceChildren(...[
    icon(n.icon || TYPE_ICON[n.type], n.iconColor),
    h('div', null, n.title && h('b', { text: n.title }), n.description && markdown(h('div', { class: 'cis-md' }), n.description)),
    n.showDuration && h('div', { class: 'cis-toast-bar', style: { 'animation-duration': `${n.duration}ms` } }),
  ].filter(Boolean))
}

function show(n) {
  const el = h('div')
  fill(el, n)
  live.set(n.key, { el, timer: 0 })
  const container = lane(n.position)
  if (n.position.startsWith('bottom')) container.prepend(el)
  else container.appendChild(el)
  arm(n.key, n.duration)
}

function arm(key, duration) {
  const entry = live.get(key)
  clearTimeout(entry.timer)
  entry.timer = setTimeout(() => dismiss(key), duration)
}

function dismiss(key) {
  const entry = live.get(key)
  if (!entry) return
  live.delete(key)
  leave(entry.el)
  const { promoted } = queue.remove(key)
  if (promoted) show(promoted)
}

on('notify', (d) => {
  const n = {
    id: typeof d.id === 'string' || typeof d.id === 'number' ? String(d.id) : undefined,
    title: typeof d.title === 'string' ? d.title : '',
    description: typeof d.description === 'string' ? d.description : '',
    type: TYPE_ICON[d.type] ? d.type : 'inform',
    icon: d.icon,
    iconColor: d.iconColor,
    duration: Math.min(60000, Math.max(500, Number(d.duration) || 3000)),
    position: String(d.position || setting('notifyPosition')),
    showDuration: d.showDuration !== false,
  }
  if (!n.title && !n.description) return
  const r = queue.add(n)
  if (r.action === 'show') show(r.item)
  else if (r.action === 'update' && live.has(r.item.key)) {
    fill(live.get(r.item.key).el, r.item)
    arm(r.item.key, r.item.duration)
  }
})

export const applySettings = () => queue.setMax(setting('notifyMax')).forEach(show)

import { h, icon, on, post, t, layer } from './core.js'
import { angleToIndex, pointToAngle, paginate, step, keyIntent } from './nav.js'

let r = null
const send = (action, index) => post('radial', index ? { token: r.token, action, index } : { token: r.token, action })

function render() {
  const pg = paginate(r.items.length, 8, r.page)
  r.slots = r.items.slice(pg.start, pg.end).map((it, k) => ({ it, index: pg.start + k + 1 }))
  if (pg.more) r.slots.push({ more: true })
  const n = r.slots.length
  r.active = Math.min(r.active, n - 1)
  r.buttons = r.slots.map((s, k) => h('button', {
    class: 'cis-slot', type: 'button', role: 'menuitem', tabindex: -1, style: { '--a': `${(360 / n) * k}deg` },
    'aria-haspopup': s.it?.hasMenu && 'menu', onclick: () => activate(k), onmouseenter: () => highlight(k),
  }, s.more ? [icon('chevron-right'), h('span', { text: t('more') })] : [icon(s.it.icon, s.it.iconColor), h('span', { text: s.it.label ?? '' })]))
  const ring = h('div', {
    class: 'cis-ringmenu cis-anim', role: 'menu', 'aria-label': r.title || 'radial',
    onmousemove: (e) => {
      const box = ring.getBoundingClientRect()
      const dx = e.clientX - box.left - box.width / 2
      const dy = e.clientY - box.top - box.height / 2
      if (Math.hypot(dx, dy) > box.width * 0.18) highlight(angleToIndex(pointToAngle(dx, dy), n))
    },
  }, r.buttons, h('button', {
    class: 'cis-center', type: 'button', 'aria-label': t(r.hasBack ? 'back' : 'close'), onclick: () => send(r.hasBack ? 'back' : 'close'),
  }, icon(r.hasBack ? 'chevron-left' : 'x')))
  r.el.replaceChildren(ring)
  const k = r.active
  r.active = -1
  highlight(k)
}

function highlight(k) {
  if (k < 0 || k === r.active || !r.buttons[k]) return
  const prev = r.buttons[r.active]
  prev?.classList.remove('cis-active')
  prev?.setAttribute('tabindex', '-1')
  r.active = k
  r.buttons[k].classList.add('cis-active')
  r.buttons[k].setAttribute('tabindex', '0')
  r.buttons[k].focus()
}

function activate(k) {
  const s = r.slots[k]
  if (s?.more) { r.page += 1; r.active = 0; render() } else if (s) send('select', s.index)
}

on('radial:open', (d) => {
  if (!r) {
    r = {
      el: h('div', {
        class: 'cis-radial',
        onkeydown: (e) => {
          const intent = keyIntent(e.key, 'horizontal') || { ArrowDown: 'next', ArrowUp: 'prev' }[e.key]
          if (intent === 'next' || intent === 'prev') highlight(step(r.slots.length, r.active, intent === 'next' ? 1 : -1))
          else if (intent === 'activate') activate(r.active)
          else if (intent === 'back') send(r.hasBack ? 'back' : 'close')
          else return
          e.preventDefault()
        },
      }),
    }
    layer('cis-radial').appendChild(r.el)
  }
  Object.assign(r, { token: d.token, items: Array.isArray(d.items) ? d.items : [], hasBack: !!d.hasBack, title: String(d.title ?? ''), page: 0, active: 0 })
  render()
})

on('radial:close', () => {
  r?.el.remove()
  r = null
})

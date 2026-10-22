import { h, icon, inline, on, setting, leave, layer } from './core.js'

const STYLES = ['default', 'minimal', 'accent', 'key']
let current = null

on('textui:show', (d) => {
  const key = typeof d.key === 'string' ? d.key : null
  const style = STYLES.includes(d.style) ? d.style : key ? 'key' : 'default'
  const el = h('div', {
    class: `cis-textui cis-anim cis-textui-${style}${style === 'minimal' ? ' cis-shadowtext' : ''}`,
    'data-pos': d.position || setting('textUIPosition'), role: 'status', 'aria-live': 'polite',
  }, key ? h('kbd', { class: 'cis-key', text: key }) : icon(d.icon, d.iconColor), inline(h('span', { class: 'cis-md' }), d.text))
  if (current) current.replaceWith(el)
  else layer('cis-textui').appendChild(el)
  current = el
})

on('textui:hide', () => {
  leave(current)
  current = null
})

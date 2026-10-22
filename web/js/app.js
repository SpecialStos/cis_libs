// Entry: load the components (each registers its handlers), report Escape
// to Lua's focus stack, and tell Lua the page is ready.
import { on, post, setLocale, setTheme } from './core.js'
import { applySettings } from './notify.js'
import './progress.js'
import './textui.js'
import './dialog.js'
import './context.js'
import './menu.js'
import './radial.js'
import './skillcheck.js'

on('init', (d) => {
  setLocale(d.locale)
  setTheme(d.theme)
  applySettings()
})
on('theme', (d) => { setTheme(d); applySettings() })
on('locale', (d) => setLocale(d))

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    e.preventDefault()
    post('escape', {})
  }
})

post('ready', {})

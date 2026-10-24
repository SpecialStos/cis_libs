// Entry: load the components (each registers its handlers), report Escape
// to Lua's focus stack, and tell Lua the page is ready.
import { on, post, setLocale, setSession, setTheme } from './core.js'
import { applySettings } from './notify.js'
import './progress.js'
import './textui.js'
import './dialog.js'
import './context.js'
import './menu.js'
import './radial.js'
import './skillcheck.js'

// THE PAGE SESSION (client/interface/nui.lua, I.acceptReady). Lua answers a
// tokenless ready with a hello only this page receives; echoing its token is
// the ready Lua acts on, and every Escape carries it. Once init has arrived a
// later hello is ignored: it came from a ready this page did not send.
let session = null
let live = false
on('hello', (d) => {
  if (live || typeof d.token !== 'string') return
  session = d.token
  post('ready', { token: session })
})

on('init', (d) => {
  live = true
  setSession(session)
  setLocale(d.locale)
  setTheme(d.theme)
  applySettings()
})
on('theme', (d) => { setTheme(d); applySettings() })
on('locale', (d) => setLocale(d))

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    e.preventDefault()
    // A held key repeats: one press must close one layer, not the whole stack.
    if (!e.repeat) post('escape', { token: session })
  }
})

post('ready', {})

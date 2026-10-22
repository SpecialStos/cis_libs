// Notification queue. Per position, up to `max` visible and the rest waiting
// in order. Same `id` as a visible one: update it in place (and restart its
// timer); as a waiting one: replace it. Pure, no imports.

export function createQueue(opts = {}) {
  let max = clampMax(opts.max ?? 5)
  let seq = 0
  const lanes = new Map() // position -> { visible: [], waiting: [] }

  const lane = (pos) => {
    let l = lanes.get(pos)
    if (!l) { l = { visible: [], waiting: [] }; lanes.set(pos, l) }
    return l
  }

  function findById(id) {
    if (id === undefined || id === null || id === '') return null
    for (const [pos, l] of lanes) {
      for (const where of ['visible', 'waiting']) {
        const i = l[where].findIndex((n) => n.id === id)
        if (i >= 0) return { pos, where, i, lane: l }
      }
    }
    return null
  }

  return {
    add(data) {
      const hit = findById(data.id)
      if (hit) {
        const old = hit.lane[hit.where][hit.i]
        const item = { ...data, key: old.key, position: old.position }
        hit.lane[hit.where][hit.i] = item
        return { action: hit.where === 'visible' ? 'update' : 'queued', item }
      }
      const item = { ...data, key: ++seq }
      const l = lane(item.position)
      if (l.visible.length < max) { l.visible.push(item); return { action: 'show', item } }
      l.waiting.push(item)
      return { action: 'queued', item }
    },
    remove(key) {
      for (const l of lanes.values()) {
        let i = l.visible.findIndex((n) => n.key === key)
        if (i >= 0) {
          l.visible.splice(i, 1)
          const promoted = l.visible.length < max ? l.waiting.shift() || null : null
          if (promoted) l.visible.push(promoted)
          return { removed: true, promoted }
        }
        i = l.waiting.findIndex((n) => n.key === key)
        if (i >= 0) { l.waiting.splice(i, 1); return { removed: true, promoted: null } }
      }
      return { removed: false, promoted: null }
    },
    setMax(m) {
      max = clampMax(m)
      const promoted = []
      for (const l of lanes.values()) {
        while (l.visible.length < max && l.waiting.length) {
          const n = l.waiting.shift()
          l.visible.push(n)
          promoted.push(n)
        }
      }
      return promoted
    },
    clear() { lanes.clear() },
    visible(pos) { return lanes.get(pos)?.visible.slice() ?? [] },
    waiting(pos) { return lanes.get(pos)?.waiting.slice() ?? [] },
    get max() { return max },
  }
}

function clampMax(m) {
  const n = Math.floor(Number(m))
  return Number.isFinite(n) ? Math.min(10, Math.max(1, n)) : 5
}

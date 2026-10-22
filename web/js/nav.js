// Keyboard / focus navigation model. Pure, no imports.

// Next index in `dir` (+1/-1) not skipped; -1 when nothing is selectable.
export function step(count, from, dir, skip = () => false, wrap = true) {
  if (count <= 0) return -1
  let i = from
  for (let n = 0; n < count; n++) {
    i += dir
    if (i >= count) { if (!wrap) return from; i = 0 }
    if (i < 0) { if (!wrap) return from; i = count - 1 }
    if (!skip(i)) return i
  }
  return skip(from) ? -1 : from
}

export function first(count, skip = () => false) {
  for (let i = 0; i < count; i++) if (!skip(i)) return i
  return -1
}

export function last(count, skip = () => false) {
  for (let i = count - 1; i >= 0; i--) if (!skip(i)) return i
  return -1
}

export function keyIntent(key, orientation = 'vertical') {
  switch (key) {
    case 'ArrowDown': return orientation === 'vertical' ? 'next' : null
    case 'ArrowUp': return orientation === 'vertical' ? 'prev' : null
    case 'ArrowRight': return orientation === 'vertical' ? 'right' : 'next'
    case 'ArrowLeft': return orientation === 'vertical' ? 'left' : 'prev'
    case 'Home': return 'first'
    case 'End': return 'last'
    case 'Enter': case ' ': return 'activate'
    case 'Escape': return 'cancel'
    case 'Backspace': return 'back'
    default: return null
  }
}

// Focus trap: where Tab / Shift+Tab goes among `count` stops.
export function trapTab(count, current, shift) {
  if (count <= 0) return -1
  if (current < 0) return shift ? count - 1 : 0
  return (current + (shift ? -1 : 1) + count) % count
}

// Radial: 0deg at 12 o'clock, clockwise; slice i centred on i * 360 / count.
export function angleToIndex(deg, count) {
  if (count <= 0) return -1
  const slice = 360 / count
  const a = ((deg % 360) + 360 + slice / 2) % 360
  return Math.floor(a / slice) % count
}

export function pointToAngle(dx, dy) {
  return ((Math.atan2(dx, -dy) * 180) / Math.PI + 360) % 360
}

// Pages of `size`, the last slot of a full page being "more".
export function paginate(total, size, page) {
  if (total <= size) return { start: 0, end: total, more: false, pages: 1 }
  const per = size - 1
  const pages = Math.ceil(total / per)
  const p = ((page % pages) + pages) % pages
  return { start: p * per, end: Math.min(total, p * per + per), more: true, pages, page: p }
}

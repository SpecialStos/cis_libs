// Skill check model. Pure, no imports. The needle sweeps clockwise from 0deg,
// one turn per BASE_TURN_MS at speed 1; the zone is `areaSize` degrees and
// never starts in the first quarter turn. Passing it or a wrong key fails.

export const BASE_TURN_MS = 2000
export const PRESETS = { easy: { areaSize: 50, speedMultiplier: 1 }, medium: { areaSize: 40, speedMultiplier: 1.5 }, hard: { areaSize: 25, speedMultiplier: 1.75 } }

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v))

export function resolveDifficulty(d) {
  if (typeof d === 'string') return PRESETS[d] ? { ...PRESETS[d] } : null
  if (d && typeof d === 'object' && typeof d.areaSize === 'number' && typeof d.speedMultiplier === 'number') {
    return { areaSize: clamp(d.areaSize, 5, 180), speedMultiplier: clamp(d.speedMultiplier, 0.25, 5) }
  }
  return null
}

export function makeRound(diff, keys, rand = Math.random) {
  const size = diff.areaSize
  const lo = 90
  const hi = Math.max(lo, 360 - size - 10)
  const start = Math.round(lo + rand() * (hi - lo))
  const list = Array.isArray(keys) && keys.length ? keys : ['e']
  const key = list[Math.floor(rand() * list.length) % list.length]
  return { start, size, key, degPerMs: (360 / BASE_TURN_MS) * diff.speedMultiplier }
}

export function angleAt(round, elapsedMs) {
  return Math.max(0, elapsedMs) * round.degPerMs
}

export function judge(round, angle, key) {
  if (key !== undefined && key !== round.key) return 'fail'
  if (angle >= round.start && angle <= round.start + round.size) return 'hit'
  return 'fail'
}

export function expired(round, angle) {
  return angle > round.start + round.size
}

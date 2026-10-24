// A minimal ustar writer, for tools/live-remote.js.
//
// Why not the `tar` binary: on Windows two different ones are on PATH (bsdtar in
// System32 and GNU tar from Git), and GNU tar reads `-C C:\...` as a remote
// host. Writing the archive here gives the same bytes on every platform and
// lets the deploy pipe it straight into `ssh ... fivem-deploy`.
//
// Regular files only, mode 0644, mtime fixed by the caller. Enough for a
// resource folder; it is not a general tar library.

const BLOCK = 512

function octal(n, width) {
  // width includes the trailing NUL.
  return n.toString(8).padStart(width - 1, '0') + '\0'
}

// ustar splits a long name at a '/' into prefix (155) and name (100).
function splitName(name) {
  if (Buffer.byteLength(name) <= 100) return { prefix: '', name }
  for (let i = name.length - 1; i > 0; i--) {
    if (name[i] !== '/') continue
    const prefix = name.slice(0, i)
    const rest = name.slice(i + 1)
    if (Buffer.byteLength(prefix) <= 155 && Buffer.byteLength(rest) <= 100 && rest.length > 0) {
      return { prefix, name: rest }
    }
  }
  throw new Error(`tar: path too long for ustar: ${name}`)
}

function header(name, size, mtime) {
  const h = Buffer.alloc(BLOCK, 0)
  const parts = splitName(name)
  h.write(parts.name, 0, 100, 'utf8')
  h.write(octal(0o644, 8), 100, 8, 'ascii')
  h.write(octal(0, 8), 108, 8, 'ascii')
  h.write(octal(0, 8), 116, 8, 'ascii')
  h.write(octal(size, 12), 124, 12, 'ascii')
  h.write(octal(mtime, 12), 136, 12, 'ascii')
  h.write('        ', 148, 8, 'ascii') // checksum is computed with spaces here
  h.write('0', 156, 1, 'ascii')
  h.write('ustar\0', 257, 6, 'ascii')
  h.write('00', 263, 2, 'ascii')
  h.write(parts.prefix, 345, 155, 'utf8')
  let sum = 0
  for (let i = 0; i < BLOCK; i++) sum += h[i]
  h.write(octal(sum, 7) + ' ', 148, 8, 'ascii')
  return h
}

// entries: [{ name: 'a/b.lua', data: Buffer|string }]. Names use '/', never
// start with '/' and never contain '..', so the archive cannot write outside
// the folder it is unpacked into.
function tarBuffer(entries, mtime) {
  const t = Math.floor(typeof mtime === 'number' ? mtime : Date.now() / 1000)
  const out = []
  for (const e of entries) {
    const name = String(e.name).replace(/\\/g, '/')
    if (!name || name.startsWith('/') || name.split('/').includes('..')) {
      throw new Error(`tar: refusing unsafe path: ${e.name}`)
    }
    const data = Buffer.isBuffer(e.data) ? e.data : Buffer.from(String(e.data), 'utf8')
    out.push(header(name, data.length, t), data)
    const pad = (BLOCK - (data.length % BLOCK)) % BLOCK
    if (pad) out.push(Buffer.alloc(pad, 0))
  }
  out.push(Buffer.alloc(BLOCK * 2, 0))
  return Buffer.concat(out)
}

// The reverse, for tests: [{ name, data }].
function untar(buf) {
  const out = []
  let off = 0
  while (off + BLOCK <= buf.length) {
    const h = buf.subarray(off, off + BLOCK)
    if (h.every(b => b === 0)) break
    const str = (s, l) => h.toString('utf8', s, s + l).replace(/\0.*$/s, '')
    const size = parseInt(str(124, 12), 8)
    const prefix = str(345, 155)
    const name = prefix ? `${prefix}/${str(0, 100)}` : str(0, 100)
    const stored = parseInt(str(148, 8), 8)
    let sum = 0
    for (let i = 0; i < BLOCK; i++) sum += (i >= 148 && i < 156) ? 32 : h[i]
    if (sum !== stored) throw new Error(`tar: bad checksum on ${name}`)
    off += BLOCK
    out.push({ name, data: buf.subarray(off, off + size) })
    off += Math.ceil(size / BLOCK) * BLOCK
  }
  return out
}

module.exports = { tarBuffer, untar }

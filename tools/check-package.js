// Stage 10.7: build dist/cis_libs-<version>.zip and prove it matches the
// manifest file set plus types/.

const fs = require('fs')
const path = require('path')
const { releaseFileSet, typesFiles } = require('./release-files')

const root = path.join(__dirname, '..')

function crc32(buf) {
  let c = ~0
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i]
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1))
  }
  return ~c >>> 0
}

function dosDate(d) {
  return ((d.getSeconds() / 2) | 0) | (d.getMinutes() << 5) | (d.getHours() << 11)
}

function dosDay(d) {
  return d.getDate() | ((d.getMonth() + 1) << 5) | ((d.getFullYear() - 1980) << 9)
}

function zipStore(entries) {
  // Stored (no compression) so the check can round-trip without extra deps.
  const now = new Date()
  const time = dosDate(now)
  const date = dosDay(now)
  const locals = []
  const centrals = []
  let offset = 0
  for (const e of entries) {
    const name = Buffer.from(e.name, 'utf8')
    const data = e.data
    const crc = crc32(data)
    const local = Buffer.alloc(30)
    local.writeUInt32LE(0x04034b50, 0)
    local.writeUInt16LE(20, 4)
    local.writeUInt16LE(0, 6)
    local.writeUInt16LE(0, 8)
    local.writeUInt16LE(time, 10)
    local.writeUInt16LE(date, 12)
    local.writeUInt32LE(crc, 14)
    local.writeUInt32LE(data.length, 18)
    local.writeUInt32LE(data.length, 22)
    local.writeUInt16LE(name.length, 26)
    local.writeUInt16LE(0, 28)
    const localFull = Buffer.concat([local, name, data])
    locals.push(localFull)
    const central = Buffer.alloc(46)
    central.writeUInt32LE(0x02014b50, 0)
    central.writeUInt16LE(20, 4)
    central.writeUInt16LE(20, 6)
    central.writeUInt16LE(0, 8)
    central.writeUInt16LE(0, 10)
    central.writeUInt16LE(time, 12)
    central.writeUInt16LE(date, 14)
    central.writeUInt32LE(crc, 16)
    central.writeUInt32LE(data.length, 20)
    central.writeUInt32LE(data.length, 24)
    central.writeUInt16LE(name.length, 28)
    central.writeUInt16LE(0, 30)
    central.writeUInt16LE(0, 32)
    central.writeUInt16LE(0, 34)
    central.writeUInt16LE(0, 36)
    central.writeUInt32LE(0, 38)
    central.writeUInt32LE(offset, 42)
    centrals.push(Buffer.concat([central, name]))
    offset += localFull.length
  }
  const centralDir = Buffer.concat(centrals)
  const end = Buffer.alloc(22)
  end.writeUInt32LE(0x06054b50, 0)
  end.writeUInt16LE(0, 4)
  end.writeUInt16LE(0, 6)
  end.writeUInt16LE(entries.length, 8)
  end.writeUInt16LE(entries.length, 10)
  end.writeUInt32LE(centralDir.length, 12)
  end.writeUInt32LE(offset, 16)
  end.writeUInt16LE(0, 20)
  return Buffer.concat([...locals, centralDir, end])
}

function listZipNames(buf) {
  const names = []
  let i = 0
  while (i + 30 <= buf.length) {
    const sig = buf.readUInt32LE(i)
    if (sig !== 0x04034b50) break
    const nameLen = buf.readUInt16LE(i + 26)
    const extraLen = buf.readUInt16LE(i + 28)
    const comp = buf.readUInt16LE(i + 8)
    const size = buf.readUInt32LE(i + 22)
    const name = buf.slice(i + 30, i + 30 + nameLen).toString('utf8')
    names.push(name)
    if (comp !== 0) throw new Error('zip entry ' + name + ' is compressed; check-package writes store-only')
    i += 30 + nameLen + extraLen + size
  }
  return names.sort()
}

function main() {
  const pack = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'))
  const { files, missing } = releaseFileSet(root)
  if (missing.length) {
    console.error('check-package: manifest names missing files: ' + missing.join(', '))
    process.exit(1)
  }
  const types = typesFiles(root)
  if (!types.length) {
    console.error('check-package: types/ is empty; the zip must ship LuaLS stubs')
    process.exit(1)
  }
  const want = [...files, ...types].map((r) => r.replace(/\\/g, '/')).sort()
  const entries = want.map((rel) => ({
    name: 'cis_libs/' + rel,
    data: fs.readFileSync(path.join(root, rel)),
  }))
  const buf = zipStore(entries)
  const dist = path.join(root, 'dist')
  fs.mkdirSync(dist, { recursive: true })
  const zipName = `cis_libs-${pack.version}.zip`
  const zipPath = path.join(dist, zipName)
  fs.writeFileSync(zipPath, buf)

  const got = listZipNames(buf).map((n) => n.replace(/^cis_libs\//, '')).sort()
  const a = want.join('\n')
  const b = got.join('\n')
  if (a !== b) {
    console.error('check-package: zip contents != manifest file set + types/')
    console.error('want ' + want.length + ' got ' + got.length)
    process.exit(1)
  }
  const banned = got.filter((n) =>
    n.startsWith('test/') || n.startsWith('tools/') || n.startsWith('bench/') ||
    n.startsWith('.github/') || n.startsWith('docs/archive/'))
  if (banned.length) {
    console.error('check-package: zip contains export-ignore paths: ' + banned.join(', '))
    process.exit(1)
  }
  console.log(`check-package: ${zipName} ${got.length} files, ${buf.length} bytes`)
}

main()

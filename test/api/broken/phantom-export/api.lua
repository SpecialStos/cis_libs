-- Broken on purpose: an export is declared that the resource never registers.
--
-- The other direction of drift, and the one that bites at runtime rather than
-- at review: a consumer reads the manifest, calls the entry, and gets a nil
-- function across the exports boundary.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.TeleportPlayer = {
    since = '1.0.0',
    ['until'] = false,
    stable = true,
    deprecated = false,
    use = 'Cis.player.teleport(x, y, z)',
    realm = 'server',
    signature = '(x, y, z)',
}
return real

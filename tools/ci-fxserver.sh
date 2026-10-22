#!/usr/bin/env bash
# The live harness on a real headless Linux FXServer. CI's entry point.
#
#   tools/ci-fxserver.sh fetch            download + verify + unpack, print the dir
#   tools/ci-fxserver.sh run [options]    fetch, then node tools/ci-live.js
#   tools/ci-fxserver.sh probe            fetch, then boot with NO licence key and
#                                         report how far it gets (exit 3)
#
# Options after `run` go to tools/ci-live.js (--tiers server,lifecycle,
# --timeout 780, --quiet, ...). The licence key is read from FIVEM_LICENSE_KEY
# by ci-live.js and never by this script.
#
# THE BUILD IS PINNED. A floating "recommended" would make the same commit pass
# on Monday and fail on Tuesday with nothing in the diff to explain it. To move
# it: take `recommended` and `recommended_download` from
#   https://changelogs-live.fivem.net/api/changelog/versions/linux/server
# download that fx.tar.xz once, `sha256sum` it, and change all three values
# below in one commit. 35245 is the build the Windows VPS runs (test/LIVE.md).
#
# THE DOWNLOAD IS VERIFIED against FXSERVER_SHA256 before anything in it is
# unpacked or run. Cfx.re publishes no checksum, so the pinned hash is the one
# recorded when the build was pinned; a mismatch means the file changed under
# the same URL, and that is a reason to stop, not to retry.
#
# THE CACHE is a directory per build (CIS_FXSERVER_CACHE, default
# ~/.cache/cis-fxserver). CI restores it with actions/cache keyed on the build,
# so the 70 MB download happens once per pin. A cached unpack is trusted only if
# it carries the .verified stamp this script writes after the hash check.
#
# Proxies: curl honours HTTPS_PROXY / https_proxy on its own.

set -euo pipefail

FXSERVER_BUILD="${FXSERVER_BUILD:-35245}"
FXSERVER_REV="${FXSERVER_REV:-6efb47dff473c0e2a12fb50b08d74c0eb24a50d5}"
FXSERVER_SHA256="${FXSERVER_SHA256:-16fcffd53a30a3909cbb2cfd26f89f950a59452792cafd0eda2174bdfeef9b2f}"
FXSERVER_URL="https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/${FXSERVER_BUILD}-${FXSERVER_REV}/fx.tar.xz"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${CIS_FXSERVER_CACHE:-${HOME}/.cache/cis-fxserver}"
DIR="${CACHE}/${FXSERVER_BUILD}"

log() { printf '%s\n' "$*" >&2; }

fetch() {
  if [[ -f "${DIR}/.verified" && -x "${DIR}/alpine/opt/cfx-server/FXServer" ]]; then
    log "fxserver: build ${FXSERVER_BUILD} cached at ${DIR}"
    printf '%s\n' "${DIR}"
    return 0
  fi
  command -v curl >/dev/null || { log 'fxserver: curl is required'; exit 2; }
  command -v sha256sum >/dev/null || { log 'fxserver: sha256sum is required'; exit 2; }
  command -v xz >/dev/null || { log 'fxserver: xz is required to unpack fx.tar.xz'; exit 2; }

  mkdir -p "${CACHE}"
  local tmp
  tmp="$(mktemp -d "${CACHE}/.dl-XXXXXX")"
  # EXIT, not RETURN: a failed check `exit`s, and RETURN would not fire then.
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT

  log "fxserver: downloading build ${FXSERVER_BUILD}"
  log "  ${FXSERVER_URL}"
  curl --fail --location --silent --show-error --retry 3 --retry-delay 5 \
    --max-time 600 -o "${tmp}/fx.tar.xz" "${FXSERVER_URL}"

  local got
  got="$(sha256sum "${tmp}/fx.tar.xz" | cut -d' ' -f1)"
  if [[ "${got}" != "${FXSERVER_SHA256}" ]]; then
    log "fxserver: CHECKSUM MISMATCH for build ${FXSERVER_BUILD}"
    log "  expected ${FXSERVER_SHA256}"
    log "  got      ${got}"
    log '  Nothing was unpacked. If the pin was moved on purpose, update FXSERVER_SHA256.'
    exit 2
  fi
  log "fxserver: sha256 ${got} OK"

  # Unpacked beside the cache entry and renamed into place, so an interrupted
  # unpack can never be mistaken for a complete one.
  mkdir -p "${tmp}/x"
  tar -xJf "${tmp}/fx.tar.xz" -C "${tmp}/x"
  [[ -x "${tmp}/x/alpine/opt/cfx-server/FXServer" ]] || {
    log 'fxserver: the archive has no alpine/opt/cfx-server/FXServer'; exit 2; }
  printf '%s %s\n' "${FXSERVER_BUILD}" "${got}" > "${tmp}/x/.verified"
  rm -rf "${DIR}"
  mv "${tmp}/x" "${DIR}"
  log "fxserver: build ${FXSERVER_BUILD} unpacked to ${DIR}"
  printf '%s\n' "${DIR}"
}

cmd="${1:-run}"
[[ $# -gt 0 ]] && shift
case "${cmd}" in
  fetch)
    fetch
    ;;
  run)
    dir="$(fetch)"
    exec node "${ROOT}/tools/ci-live.js" --fxserver "${dir}" "$@"
    ;;
  probe)
    dir="$(fetch)"
    # No key, on purpose: this shows how far an unlicensed boot gets and
    # nothing more. It is not a way round the licence and does not run a test.
    FIVEM_LICENSE_KEY='' exec node "${ROOT}/tools/ci-live.js" --fxserver "${dir}" --probe \
      --boot-timeout 60 "$@"
    ;;
  *)
    log 'usage: tools/ci-fxserver.sh fetch | run [ci-live options] | probe'
    exit 2
    ;;
esac

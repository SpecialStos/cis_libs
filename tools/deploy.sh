#!/usr/bin/env bash
#
# deploy.sh -- mirror this working tree into the running txAdmin server.
#
# The server keeps its resources in
#   <FiveM>/txData/<profile>/resources/[standalone]/
# and `server.cfg` does `ensure [standalone]`, so anything dropped in there is
# started on the next `refresh`. This script puts cis_libs and cis_libstest
# there from the working tree, which is the only place edits are made.
#
# What it will NOT do:
#   * touch .git in the destination (the deployed copy is a real clone, and
#     mirroring over it would leave it permanently dirty)
#   * touch node_modules
#   * start or stop anything. Starting is the console's job, and doing it from
#     here would race a connected player.
#
# Usage:  tools/deploy.sh [--no-backup] [--test-instance]
#
# --test-instance applies the two changes a TEST server needs and a production
# server must not have:
#   * adds "cis_libstest" to Security.AuthorizedResources, so the harness may
#     exercise the mutating tier. The library's shipped default stays
#     restrictive; this is an instance-level overlay applied only to the
#     deployed copy, which is what COMPATIBILITY.md section 7.3 asks for.
#   * sets RunMutating = true in the harness config.
#
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_DIR="${CIS_PROFILE_DIR:-/c/Users/CB/Desktop/FiveM/txData/Qbox_A15D5A.base}"
DST_ROOT="$PROFILE_DIR/resources/[standalone]"
BACKUP_ROOT="/c/Users/CB/Desktop/FiveM/_deploy-backup"

# Never copy these into the destination. .git is excluded so the deployed
# clone stays a clone; the rest are not part of the resource.
EXCLUDES=(".git" "node_modules" ".zcode" ".zcodeignore" ".github")

BACKUP=1
TEST_INSTANCE=0
for arg in "$@"; do
    case "$arg" in
        --no-backup)      BACKUP=0 ;;
        --test-instance)  TEST_INSTANCE=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

if [[ ! -d "$DST_ROOT" ]]; then
    echo "FATAL: destination not found: $DST_ROOT" >&2
    echo "Set CIS_PROFILE_DIR to the txAdmin profile directory." >&2
    exit 1
fi

# ---------------------------------------------------------------- backup
# Outside the resources tree on purpose: a backup left inside [standalone]
# would be started by `ensure [standalone]` as if it were a live resource.
if [[ $BACKUP -eq 1 ]]; then
    STAMP="$(date +%Y%m%d-%H%M%S)"
    BAK="$BACKUP_ROOT/$STAMP"
    mkdir -p "$BAK"
    for r in cis_libs cis_libstest; do
        [[ -d "$DST_ROOT/$r" ]] && cp -r "$DST_ROOT/$r" "$BAK/"
    done
    echo "backed up to $BAK"
    printf '%s\n' "$BAK" > /tmp/cis_last_backup.txt
else
    echo "backup skipped (--no-backup)"
fi

# ---------------------------------------------------------------- mirror
# robocopy runs under PowerShell, which does not understand Git Bash paths, so
# every path is converted to C:/... form first. Without this it resolves
# /c/... as C:\c\... and fails with "cannot find the path specified".
winpath() { cygpath -m "$1"; }

mirror() {
    local name="$1" from="$2" to="$3"
    if [[ ! -d "$from" ]]; then
        echo "SKIP  $name -- not present at $from" >&2
        return 0
    fi
    mkdir -p "$to"

    # robocopy is the only mirror on this box that handles deletions and is
    # not fooled by the [standalone] brackets in the path. Exit codes 0-7 are
    # success (1 = files copied, 3 = copied+extras); >=8 is a real failure.
    local args=()
    for e in "${EXCLUDES[@]}"; do args+=("/XD" "$e"); done

    local from_w to_w rc
    from_w="$(winpath "$from")"
    to_w="$(winpath "$to")"

    set +e
    powershell -NoProfile -Command "robocopy '$from_w' '$to_w' /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 ${args[*]} | Out-Null; exit \$LASTEXITCODE"
    rc=$?
    set -e

    if [[ $rc -ge 8 ]]; then
        echo "FATAL: robocopy failed for $name (exit $rc)" >&2
        exit $rc
    fi
    echo "synced $name"
}

mirror cis_libs     "$SRC_ROOT"          "$DST_ROOT/cis_libs"
mirror cis_libstest "$SRC_ROOT/cis_libstest" "$DST_ROOT/cis_libstest"

# ---------------------------------------------------------------- overlay
# Applied AFTER the mirror, so it survives. /MIR would otherwise undo it on the
# next deploy, which is exactly the kind of change that silently reverts and
# then gets blamed for something else.
if [[ $TEST_INSTANCE -eq 1 ]]; then
    SEC="$DST_ROOT/cis_libs/configs/security_config.lua"
    if grep -q '^Security.AuthorizedResources = {' "$SEC"; then
        if ! grep -q '"cis_libstest"' "$SEC"; then
            sed -i '0,/^Security.AuthorizedResources = {/s//Security.AuthorizedResources = {\n    "cis_libstest",/' "$SEC"
            echo "overlay: added cis_libstest to Security.AuthorizedResources"
        else
            echo "overlay: cis_libstest already on the allow-list"
        fi
    fi

    CFG="$DST_ROOT/cis_libstest/config.lua"
    if grep -q '^    RunMutating = false,' "$CFG"; then
        sed -i 's/^    RunMutating = false,/    RunMutating = true,/' "$CFG"
        echo "overlay: RunMutating = true"
    fi

    # This server runs qbx_core, while the library's shipped default names
    # QBCORE. Left alone, cis_libs falls back to standalone mode and every
    # player lookup returns nil -- which reads as a library bug and is not one.
    MCFG="$DST_ROOT/cis_libs/configs/master_config.lua"
    if grep -q 'Type = "QBCORE"' "$MCFG"; then
        sed -i 's/Type = "QBCORE"/Type = "QBOX"/' "$MCFG"
        echo "overlay: Framework.Type = QBOX (this server runs qbx_core)"
    fi
fi

# ---------------------------------------------------------------- verify
# Compare the Lua that actually runs. A doc difference does not matter to the
# server; a Lua difference is the whole ballgame.
echo
echo "verifying runtime parity..."
status=0
for r in cis_libs cis_libstest; do
    # The overlay intentionally leaves the deployed copy differing from source,
    # so those files are excluded from the parity check when it is on.
    # diff's --exclude matches the BASENAME, not the path.
    OVERRIDE=()
    if [[ $TEST_INSTANCE -eq 1 ]]; then
        if [[ "$r" == "cis_libs" ]]; then
            OVERRIDE=(--exclude=security_config.lua --exclude=master_config.lua)
        else
            OVERRIDE=(--exclude=config.lua)
        fi
    fi
    if diff -r -q \
        --exclude=.git --exclude=node_modules --exclude=.zcode \
        --exclude=.zcodeignore --exclude=.github "${OVERRIDE[@]}" \
        "$DST_ROOT/$r" "$([ "$r" = cis_libs ] && echo "$SRC_ROOT" || echo "$SRC_ROOT/cis_libstest")" \
        > /tmp/cis_diff_$r.txt 2>&1
    then
        echo "  OK   $r -- identical"
    else
        echo "  DIFF $r --"
        sed 's/^/       /' /tmp/cis_diff_$r.txt
        status=1
    fi
done

echo
if [[ $status -eq 0 ]]; then
    echo "deploy complete -- destination matches source."
    echo "Next: in the txAdmin console, run  refresh  then  ensure cis_libs  then  ensure cis_libstest"
else
    echo "deploy complete WITH DIFFERENCES -- see above."
fi
exit $status

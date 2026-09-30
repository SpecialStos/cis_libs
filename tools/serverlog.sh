#!/usr/bin/env bash
#
# serverlog.sh -- read the FXServer console log incrementally.
#
# The console output we care about (resource errors, cistest progress, Lua
# stack traces) all lands in fxserver.log. Scraping it out of the txAdmin page
# is slow and loses history, so the browser is used only to *send* commands and
# this script is used to *read* the result.
#
# fxserver.log is ~70MB, so it is never read whole. This marks a byte offset
# and returns only what was appended after it, which makes "what happened
# since I sent this command" a cheap and exact question.
#
# Usage:
#   serverlog.sh mark                  # remember the current end of file
#   serverlog.sh since [pattern]       # print everything appended since the mark
#   serverlog.sh watch <secs>          # poll for N seconds, printing new lines
#
set -euo pipefail

LOG="${CIS_FXLOG:-/c/Users/CB/Desktop/FiveM/txData/default/logs/fxserver.log}"
MARK="${CIS_LOGMARK:-/tmp/cis_fxlog_mark}"

# PowerShell does not understand Git Bash paths -- it resolves /c/... as
# C:\c\... and reports a file that does not exist. Convert once, up front.
LOG_W="$(cygpath -m "$LOG")"

size() {
    # Windows stat, because the file is being appended to by a running process
    # and GNU stat's size can lag on this mount.
    powershell -NoProfile -Command "(Get-Item '$LOG_W').Length" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' || echo 0
}

case "${1:-since}" in
    mark)
        s=$(size)
        echo "$s" > "$MARK"
        echo "marked at byte $s"
        ;;

    since)
        s=$(size)
        m=$(cat "$MARK" 2>/dev/null || echo 0)
        # A restart truncates or rotates the log; if the mark is now past the
        # end, start from the beginning rather than printing nothing.
        [[ "$m" -gt "$s" ]] && m=0
        powershell -NoProfile -Command "
            \$fs = [System.IO.File]::Open('$LOG_W','Open','Read','ReadWrite')
            \$fs.Seek($m, 'Begin') | Out-Null
            \$sr = New-Object System.IO.StreamReader(\$fs)
            \$sr.ReadToEnd()
            \$sr.Close(); \$fs.Close()
        " 2>/dev/null | tr -d '\r'
        # Advance the mark so successive `since` calls do not repeat lines.
        echo "$s" > "$MARK"
        ;;

    watch)
        secs="${2:-20}"
        end=$(( $(date +%s) + secs ))
        while [[ $(date +%s) -lt $end ]]; do
            bash "$(dirname "${BASH_SOURCE[0]}")/serverlog.sh" since
            sleep 2
        done
        ;;

    *)
        echo "usage: serverlog.sh {mark|since|watch <secs>}" >&2
        exit 1
        ;;
esac

#!/usr/bin/env bash
#
# scripts/test-spill-probe-first-test.sh
#
# Offline fixtures for spill-probe-first-test.sh: a repo whose first test
# starts passes (and is stopped, not waited for); one that exits early, hangs
# before its first test, or only mentions the marker on stderr-less silence fails.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spill-probe-first-test.sh"
FAILS=0
expect() { # <want-rc> <desc> <max-seconds> args...
    local want="$1" desc="$2" max="$3"; shift 3
    local t0=$SECONDS rc
    "$H" "$@" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq "$want" ] && [ $((SECONDS - t0)) -le "$max" ]; then echo "ok   $desc"
    else echo "FAIL $desc (rc=$rc want=$want, $((SECONDS - t0))s)"; FAILS=1; fi
}

expect 0 "first test starts: probe passes and does not wait for the run" 5 \
    fx 20 '^==> Run unit tests' -- bash -c 'echo "==> Install"; echo "==> Run unit tests"; sleep 60'
expect 1 "setup passes but the first test never starts: probe fails at the timeout" 8 \
    fx 3 '^==> Run unit tests' -- bash -c 'echo "==> Install"; sleep 60'
expect 1 "command exits 0 without ever starting a test: probe fails" 5 \
    fx 20 '^==> Run unit tests' -- bash -c 'echo "==> Install"'
expect 1 "command fails in setup: probe fails" 5 \
    fx 20 '^==> Run unit tests' -- bash -c 'echo boom; exit 3'
expect 2 "empty marker is refused" 5 fx 5 '' -- true
exit "$FAILS"

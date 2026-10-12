#!/usr/bin/env bash
#
# scripts/spill-probe-first-test.sh
#
# usage: spill-probe-first-test.sh <name> <timeout-seconds> <marker-regex> -- <command...>
#
# Runs <command> and succeeds the moment the command's OWN output matches
# <marker-regex> (grep -E, one line), then kills the command: the spill probe
# needs a repo's first real test to have STARTED on the spilled runner, not to
# finish. Fails if the command exits first, or the timeout passes, without the
# marker. "Started" is read from the repo's output, never inferred from the
# command having stayed alive.
set -uo pipefail

if [ "$#" -lt 5 ] || [ "$4" != "--" ]; then
    echo "usage: $0 <name> <timeout-seconds> <marker-regex> -- <command...>" >&2
    exit 2
fi
name="$1" limit="$2" marker="$3"
shift 4
[ -n "$marker" ] || { echo "ERROR: $name: empty started-marker" >&2; exit 2; }
case "$limit" in ''|*[!0-9]*) echo "ERROR: $name: timeout '$limit' is not seconds" >&2; exit 2;; esac

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

setsid "$@" >"$log" 2>&1 &
pid=$!

stop() { kill -TERM -- "-$pid" 2>/dev/null; sleep 1; kill -KILL -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }

deadline=$(( $(date +%s) + limit ))
while :; do
    if grep -E -- "$marker" "$log" >/dev/null; then
        echo "STARTED: $name — first test began ($(grep -E -m1 -- "$marker" "$log"))"
        stop
        exit 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid"; rc=$?
        echo "FAIL: $name exited ($rc) before its first test started" >&2
        tail -40 "$log" >&2
        exit 1
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "FAIL: $name: first test did not start within ${limit}s (marker: $marker)" >&2
        tail -40 "$log" >&2
        stop
        exit 1
    fi
    sleep 1
done

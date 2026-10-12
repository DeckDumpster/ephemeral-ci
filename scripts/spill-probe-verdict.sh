#!/usr/bin/env bash
#
# scripts/spill-probe-verdict.sh [--what <step>] repo=outcome...
#
# One verdict over the per-repo steps (runner-deps by default, or --what), which run with
# continue-on-error so a failure in one cannot hide the others. Names every
# repo that did not succeed and exits non-zero if any did not.
set -uo pipefail

what="runner-deps"
if [ "${1:-}" = "--what" ]; then
    what="${2:?--what needs a step name}"
    shift 2
fi

bad=()
for arg in "$@"; do
    repo="${arg%%=*}"
    outcome="${arg#*=}"
    echo "$what ($repo): $outcome"
    [ "$outcome" = success ] || bad+=("$repo ($outcome)")
done
[ "$#" -gt 0 ] || { echo "::error::no $what outcomes given"; exit 2; }
if [ "${#bad[@]}" -gt 0 ]; then
    echo "::error::$what failed for: ${bad[*]}"
    exit 1
fi
echo "$what passed for every consumer"

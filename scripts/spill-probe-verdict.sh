#!/usr/bin/env bash
#
# scripts/spill-probe-verdict.sh repo=outcome...
#
# One verdict over the per-repo runner-deps steps, which run with
# continue-on-error so a failure in one cannot hide the others. Names every
# repo that did not succeed and exits non-zero if any did not.
set -uo pipefail

bad=()
for arg in "$@"; do
    repo="${arg%%=*}"
    outcome="${arg#*=}"
    echo "runner-deps ($repo): $outcome"
    [ "$outcome" = success ] || bad+=("$repo ($outcome)")
done
[ "$#" -gt 0 ] || { echo "::error::no runner-deps outcomes given"; exit 2; }
if [ "${#bad[@]}" -gt 0 ]; then
    echo "::error::runner-deps failed for: ${bad[*]}"
    exit 1
fi
echo "runner-deps passed for every consumer"

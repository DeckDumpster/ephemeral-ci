#!/usr/bin/env bash
#
# Remove a stale org runner registration -- and never a busy one.
#
# Usage: deregister-runner.sh <org> <runner-name>     (GH_TOKEN must be set)
#
# Deleting a runner that is executing a job cancels that job
# ("##[error]The operation was canceled."). This script runs in teardown, under
# if: always(), by name; a teardown that fires while the runner it names is still
# working -- an overlapping teardown, a re-run, a name that outlived its VM --
# would otherwise kill someone's gate mid-run with no trace in the cancelled
# job's own log (sp-o6zz16). So the registration is deleted only when the
# runner is not busy. A busy runner is left alone: an ephemeral runner removes
# itself when its job ends, and the reaper collects the rest.
#
# Always exits zero for "nothing to do" and "left alone"; non-zero only when the
# runner list cannot be read or a delete the script decided on fails.
set -euo pipefail

[ $# -eq 2 ] || { echo "Usage: deregister-runner.sh <org> <runner-name>" >&2; exit 2; }
ORG="$1"
NAME="$2"

row=$(gh api "orgs/${ORG}/actions/runners" --paginate \
        --jq ".runners[] | select(.name == \"${NAME}\") | \"\(.id) \(.busy)\"" | head -1)

if [ -z "$row" ]; then
    echo "no runner registration named $NAME -- it deregistered itself"
    exit 0
fi

id="${row%% *}"
busy="${row##* }"

if [ "$busy" != "false" ]; then
    echo "runner $NAME (id $id) is busy (busy=$busy) -- NOT removing its registration; deleting it would cancel its job"
    exit 0
fi

gh api -X DELETE "orgs/${ORG}/actions/runners/${id}"
echo "removed stale runner registration $NAME (id $id)"

#!/usr/bin/env bash
#
# ec2-diag.sh <instance-id>
#
# Prints the state of a spilled EC2 runner over SSM: the runner path/service
# units and their journal, the runner's _diag log tail, the route to GitHub and
# tailscale status. The EC2 counterpart of guest-diag.sh. Run when a runner
# fails to register, BEFORE teardown terminates the instance; the instance's
# console is not readable once it is gone.
#
# Reads only. Never returns non-zero: the caller is already failing and this
# must not mask the original error.
set -uo pipefail

IID="${1:-}"
[ -n "$IID" ] || { echo "ec2-diag.sh: no instance id given" >&2; exit 0; }
REGION="${SPILL_REGION:-us-west-2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=spill-params.sh
. "$SCRIPT_DIR/spill-params.sh"

printf 'ec2-diag: instance %s\n' "$IID"

doc=""
if spill_params_load "$REGION"; then
    doc="$(spill_param DiagnoseDocumentName)"
else
    printf '(%s)\n' "$SPILL_PARAMS_ERR"
fi

if [ -n "$doc" ] && [ "$doc" != "None" ]; then
    cmd="$(aws ssm send-command --region "$REGION" --instance-ids "$IID" \
            --document-name "$doc" --query 'Command.CommandId' --output text 2>&1)" \
        || { printf '(send-command failed: %s)\n' "$cmd"; cmd=""; }
    if [ -n "$cmd" ]; then
        for _ in $(seq 1 24); do
            st="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd" \
                    --instance-id "$IID" --query 'Status' --output text 2>/dev/null || echo Pending)"
            case "$st" in Pending|InProgress|Delayed) sleep 5 ;; *) break ;; esac
        done
        printf '(diagnose command status: %s)\n' "$st"
        aws ssm get-command-invocation --region "$REGION" --command-id "$cmd" \
            --instance-id "$IID" --query '[StandardOutputContent,StandardErrorContent]' \
            --output text 2>&1
    fi
else
    printf '(no DiagnoseDocumentName parameter under %s; apply infra/terraform)\n' "$SPILL_PARAMS_PATH"
fi

printf '\n===== console output =====\n'
aws ec2 get-console-output --region "$REGION" --instance-id "$IID" --latest \
    --query Output --output text 2>&1 | tail -n 60
exit 0

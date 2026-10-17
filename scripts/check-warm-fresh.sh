#!/usr/bin/env bash
# covers: scripts/warm-cache.sh
#
# scripts/check-warm-fresh.sh
#
# Is the newest runner AMI's baked warm cache still the one the consumers' lockfiles
# describe? Compares the warm-lock-sha tag of the newest ephemeral-ci-runner AMI with
# `warm-cache.sh lock-sha` now. Exit 0: fresh. Exit 10: stale (rebuild). Exit 1: could not
# tell -- never reported as fresh (sp-tu41vm).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-us-west-2}"

want="$(bash "${SCRIPT_DIR}/warm-cache.sh" lock-sha)" || { echo "check-warm-fresh: cannot compute current lock-sha" >&2; exit 1; }
have="$(aws ec2 describe-images --owners self \
    --filters 'Name=tag:spill:owner,Values=ephemeral-ci' 'Name=name,Values=ephemeral-ci-runner-*' \
    --query 'sort_by(Images, &CreationDate)[-1].Tags[?Key==`warm-lock-sha`]|[0].Value' \
    --output text --region "$REGION")" || { echo "check-warm-fresh: describe-images failed" >&2; exit 1; }

if [ "$have" = "$want" ]; then
    echo "check-warm-fresh: fresh (warm-lock-sha=$want)"
    exit 0
fi
echo "check-warm-fresh: stale: newest AMI has warm-lock-sha=${have:-none}, lockfiles now give $want"
exit 10

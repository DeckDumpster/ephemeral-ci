#!/usr/bin/env bash
# check-ami-for-ref.sh <git-ref> [repo-dir]
#
# Exits 0 only when an available EC2 spill AMI tagged with this ref's AMI-input
# hash (substrate-sha, the hash provision.sh recomputes at the consumer's ref)
# AND spill:probe=passed exists. Otherwise refuses, naming the missing hash.
# advance-v1.yml runs it before moving a consumer tag: a ref whose AMI was never
# built (or never probed green) makes every spill fail as stale (sp-l38h8w:
# #149 and #153 both advanced on unit CI and broke every spill).
# Needs AWS credentials able to ec2:DescribeImages; AWS_REGION defaults to us-west-2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF="${1:?usage: check-ami-for-ref.sh <git-ref> [repo-dir]}"
REPO="${2:-$SCRIPT_DIR/..}"
REGION="${AWS_REGION:-us-west-2}"

# shellcheck source=ami-wait.sh
. "$SCRIPT_DIR/ami-wait.sh"

want="$(ami_inputs_sha_at_ref "$REF" "$REPO")" || {
    printf '::error::check-ami-for-ref.sh: %s does not resolve in %s\n' "$REF" "$REPO" >&2
    exit 2
}

out="$(aws ec2 describe-images --region "$REGION" \
        --filters 'Name=tag:spill:owner,Values=ephemeral-ci' \
                  'Name=tag:spill:probe,Values=passed' \
                  'Name=state,Values=available' \
                  "Name=tag:substrate-sha,Values=${want}" \
        --query 'Images[].ImageId' --output text 2>&1)" || {
    printf '::error::check-ami-for-ref.sh: aws ec2 describe-images failed: %s\n' "$out" >&2
    exit 2
}

if [ -z "$out" ] || [ "$out" = "None" ]; then
    printf '::error::no built, probe-passed spill AMI has substrate-sha=%s (AMI inputs at %s); run the Build spill AMI workflow and let the spill probe promote it before advancing\n' \
        "$want" "$REF" >&2
    exit 1
fi
printf 'spill AMI for inputs %s at %s: %s\n' "$want" "$REF" "$out"

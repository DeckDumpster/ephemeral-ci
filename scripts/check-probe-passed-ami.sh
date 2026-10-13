#!/usr/bin/env bash
# check-probe-passed-ami.sh
#
# Exits 0 when at least one available spill AMI carries spill:probe=passed;
# exits 1 (naming the consequence) when none does, 2 when AWS cannot be asked.
# With zero such images provision.sh fails every EC2 spill for every repo
# (sp-g681nm). spill-ami-health.yml runs it hourly; a red run is the page.
# It also exits 1 when a published major tag (PUBLISHED_TAGS, default "v1 v2",
# those that exist in the repo) has no probe-passed AMI matching ITS recipe:
# consumers pin the tag and provision.sh there refuses every other image as
# stale (sp-h8p1u2). The checkout must carry tags (fetch-depth: 0).
# AWS_REGION defaults to us-west-2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_DIR:-$SCRIPT_DIR/..}"
REGION="${AWS_REGION:-us-west-2}"

# shellcheck source=ami-wait.sh
. "$SCRIPT_DIR/ami-wait.sh"

out="$(aws ec2 describe-images --region "$REGION" --owners self \
        --filters 'Name=tag:spill:owner,Values=ephemeral-ci' \
                  'Name=tag:spill:probe,Values=passed' \
                  'Name=state,Values=available' \
        --query 'length(Images)' --output text 2>&1)" || {
    printf '::error::check-probe-passed-ami.sh: aws ec2 describe-images failed: %s\n' "$out" >&2
    exit 2
}

if [ "$out" = "0" ] || [ -z "$out" ] || [ "$out" = "None" ]; then
    printf '::error::no probe-passed spill AMI (spill:owner=ephemeral-ci, spill:probe=passed) in %s: every EC2 spill fails at provision; run the ami-build workflow and let the spill probe promote it\n' \
        "$REGION" >&2
    exit 1
fi
printf 'probe-passed spill AMIs in %s: %s\n' "$REGION" "$out"

rc=0
for t in ${PUBLISHED_TAGS:-v1 v2}; do
    want="$(ami_inputs_sha_at_ref "refs/tags/$t" "$REPO")" || continue
    n="$(aws ec2 describe-images --region "$REGION" --owners self \
            --filters 'Name=tag:spill:owner,Values=ephemeral-ci' \
                      'Name=tag:spill:probe,Values=passed' \
                      'Name=state,Values=available' \
                      "Name=tag:substrate-sha,Values=${want}" \
            --query 'length(Images)' --output text 2>&1)" || {
        printf '::error::check-probe-passed-ami.sh: aws ec2 describe-images failed: %s\n' "$n" >&2
        exit 2
    }
    if [ "$n" = "0" ] || [ -z "$n" ] || [ "$n" = "None" ]; then
        printf '::error::no probe-passed spill AMI has substrate-sha=%s, the recipe at published tag %s: provision.sh at %s refuses every other image as stale, so EC2 spill is down for every consumer\n' \
            "$want" "$t" "$t" >&2
        rc=1
    else
        printf 'probe-passed spill AMI for published tag %s (%s): %s\n' "$t" "$want" "$n"
    fi
done
exit "$rc"

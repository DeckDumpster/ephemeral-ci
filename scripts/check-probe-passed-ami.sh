#!/usr/bin/env bash
# check-probe-passed-ami.sh
#
# Exits 0 when at least one available spill AMI carries spill:probe=passed;
# exits 1 (naming the consequence) when none does, 2 when AWS cannot be asked.
# With zero such images provision.sh fails every EC2 spill for every repo
# (sp-g681nm). spill-ami-health.yml runs it hourly; a red run is the page.
# AWS_REGION defaults to us-west-2.

set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"

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

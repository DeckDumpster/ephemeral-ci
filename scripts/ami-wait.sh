#!/usr/bin/env bash
# ami-wait.sh -- sourced by ami-build.sh. wait_for_ami polls an image until it
# is available or failed. The guard is a hang guard, not a budget: AWS image
# availability is routinely near 10 minutes, so the guard sits far beyond it.
# Expects note() and REGION from the caller.

# Hang guard for the AMI to become available (seconds).
AMI_WAIT_SECONDS="${AMI_WAIT_SECONDS:-2700}"
AMI_POLL_SECONDS="${AMI_POLL_SECONDS:-15}"

# wait_for_ami <ami-id>: returns 0 when available, 1 on failed or guard expiry.
# Records the latency in the job summary.
wait_for_ami() {
    local ami_id="$1"
    local start state="unknown" elapsed
    start="$(date +%s)"
    while true; do
        state="$(aws ec2 describe-images \
            --image-ids "$ami_id" \
            --query 'Images[0].State' \
            --output text --region "$REGION" 2>/dev/null)" || state="pending"
        elapsed=$(( $(date +%s) - start ))
        case "$state" in
            available)
                note "AMI $ami_id is available (${elapsed}s)"
                if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
                    printf 'AMI %s availability latency: %ss (hang guard %ss)\n' \
                        "$ami_id" "$elapsed" "$AMI_WAIT_SECONDS" >> "$GITHUB_STEP_SUMMARY" || true
                fi
                return 0
                ;;
            failed)
                printf 'ami-build.sh: AMI %s reached state "failed" after %ss\n' \
                    "$ami_id" "$elapsed" >&2
                return 1
                ;;
        esac
        if [ "$elapsed" -gt "$AMI_WAIT_SECONDS" ]; then
            printf 'ami-build.sh: AMI %s still "%s" after %ss (hang guard %ss)\n' \
                "$ami_id" "$state" "$elapsed" "$AMI_WAIT_SECONDS" >&2
            return 1
        fi
        sleep "$AMI_POLL_SECONDS"
    done
}

# sha256 over every file whose content shapes the AMI: the substrate and the
# builder that wraps it. Tagged on the AMI as substrate-sha and recomputed by
# provision.sh, so an AMI built before either changed is refused as stale.
# (A change to ami-build.sh alone, sp-oauh2n, left the old hash valid and the
# old image in service.)
ami_inputs_sha() {
    local d="$1"
    cat "$d/template-substrate.sh" "$d/ami-build.sh" "$d/runner-env.sh" "$d/../nix/flake.nix" | sha256sum | cut -d' ' -f1
}

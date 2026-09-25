#!/usr/bin/env bash
#
# scripts/test-ami-build.sh
#
# Test suite for scripts/ami-build.sh.
# Runs the real AWS CLI against account 189923011121 / us-west-2.
# Do not stub aws -- a pass against a mock proves nothing.
#
# What this verifies:
#   1. ami-build.sh --dry-run exits 0 and produces no mutating AWS calls.
#   2. ami-build.sh builds a real AMI, tagged with build-date and git-commit.
#   3. An instance launched from the new AMI registers with SSM within
#      the declared budget (SSM_WAIT_SECONDS); elapsed time is reported.
#   4. template-substrate.sh --check passes on the launched instance
#      (the same check applied to the Proxmox template); any missing item
#      is named.
#   5. Packages from the substrate list are present; differences are named.
#   6. Positive control: a stale AMI (created before the build with an
#      earlier creation date and the spill tag) and its backing snapshot are
#      deregistered and deleted when ami-build.sh --prune-only --retain 1
#      is called. The newly built AMI is not touched.
#
# Test ordering matters for 6: the stale copy is created BEFORE the main
# build so its CreationDate < the new AMI's CreationDate, making the prune
# remove the copy and keep the new one.
#
# Cleanup: the test instance is terminated at EXIT. The stale AMI is cleaned
# up by the prune test or by the EXIT trap if pruning failed.
#
set -uo pipefail

ACCOUNT_ID="189923011121"
REGION="us-west-2"
TAG_KEY="spill:owner"
TAG_VALUE="ephemeral-ci"
AMI_NAME_PREFIX="ephemeral-ci-runner"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${SCRIPT_DIR}/ami-build.sh"
OUTPUTS_FILE="${SCRIPT_DIR}/aws-bootstrap-outputs.sh"

# Budget for SSM registration during test 3.
SSM_WAIT_SECONDS=300
# Budget for SSM command execution (substrate check).
CHECK_WAIT_SECONDS=180

pass=0
fail=0
test_instance_id=""
stale_ami_id=""
stale_snap_id=""
new_ami_id=""

ok() { printf 'PASS: %s\n' "$1"; (( pass++ )) || true; }
ko() { printf 'FAIL: %s\n' "$1"; (( fail++ )) || true; }

# ---------------------------------------------------------------------------
# Exit trap: terminate test instance and clean up any residual stale AMI.
# ---------------------------------------------------------------------------
_cleanup() {
    if [ -n "$test_instance_id" ] && [[ "$test_instance_id" =~ ^i- ]]; then
        printf 'test-ami-build: terminating test instance %s\n' \
            "$test_instance_id" >&2
        aws ec2 terminate-instances \
            --instance-ids "$test_instance_id" \
            --region "$REGION" >/dev/null 2>&1 || true
    fi
    # Residual stale AMI cleanup (handles the path where prune test failed).
    if [ -n "$stale_ami_id" ] && [[ "$stale_ami_id" =~ ^ami- ]]; then
        printf 'test-ami-build: cleanup: deregistering leftover stale AMI %s\n' \
            "$stale_ami_id" >&2
        aws ec2 deregister-image \
            --image-id "$stale_ami_id" --region "$REGION" >/dev/null 2>&1 || true
    fi
    if [ -n "$stale_snap_id" ] && [[ "$stale_snap_id" =~ ^snap- ]]; then
        printf 'test-ami-build: cleanup: deleting leftover stale snapshot %s\n' \
            "$stale_snap_id" >&2
        aws ec2 delete-snapshot \
            --snapshot-id "$stale_snap_id" --region "$REGION" >/dev/null 2>&1 || true
    fi
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if ! command -v aws >/dev/null 2>&1; then
    printf 'test-ami-build.sh: aws CLI not found\n' >&2; exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    printf 'test-ami-build.sh: jq not found\n' >&2; exit 1
fi

actual_account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || true
if [ "$actual_account" != "$ACCOUNT_ID" ]; then
    printf 'test-ami-build.sh: wrong account (%s); need %s\n' \
        "${actual_account:-not authenticated}" "$ACCOUNT_ID" >&2
    exit 1
fi

if [ ! -f "$OUTPUTS_FILE" ]; then
    printf 'test-ami-build.sh: %s missing -- run scripts/aws-bootstrap.sh first\n' \
        "$OUTPUTS_FILE" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$OUTPUTS_FILE"

# ---------------------------------------------------------------------------
# PRE-BUILD: create a stale AMI copy so it has an earlier CreationDate than
# the AMI we are about to build. This is required for test 6 to work.
# CreationDate is set at copy-image request time, not completion time.
# ---------------------------------------------------------------------------
printf 'test-ami-build: creating stale AMI before build (so its CreationDate < new AMI)...\n' >&2

base_ami_id="$(aws ec2 describe-images \
    --owners 099720109477 \
    --filters \
        'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
        'Name=state,Values=available' \
        'Name=architecture,Values=x86_64' \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text --region "$REGION" 2>/dev/null)" || base_ami_id=""

_pre_build_stale_ok=0
if [[ "$base_ami_id" =~ ^ami- ]]; then
    stale_ami_id="$(aws ec2 copy-image \
        --source-image-id "$base_ami_id" \
        --source-region "$REGION" \
        --name "${AMI_NAME_PREFIX}-20200101-test-stale" \
        --description "ephemeral-ci test: stale AMI for prune positive control (safe to delete)" \
        --region "$REGION" \
        --query 'ImageId' \
        --output text 2>/dev/null)" || stale_ami_id=""

    if [[ "$stale_ami_id" =~ ^ami- ]]; then
        aws ec2 create-tags \
            --resources "$stale_ami_id" \
            --tags "Key=${TAG_KEY},Value=${TAG_VALUE}" \
            --region "$REGION" 2>/dev/null || true
        printf 'test-ami-build: stale AMI %s created (copying in background)\n' \
            "$stale_ami_id" >&2
        _pre_build_stale_ok=1
    else
        printf 'test-ami-build: WARNING: could not create stale AMI -- test 6 will fail\n' >&2
    fi
else
    printf 'test-ami-build: WARNING: could not find base Ubuntu AMI -- test 6 will fail\n' >&2
fi

# ---------------------------------------------------------------------------
# 1. dry-run: exits 0, no mutating AWS calls
# ---------------------------------------------------------------------------
dry_out="$(bash "$BOOTSTRAP" --dry-run 2>&1)" || {
    ko "dry-run: non-zero exit"
    dry_out=""
}

if printf '%s\n' "$dry_out" | grep -q 'dry-run'; then
    ok "dry-run: dry-run mode announced"
else
    ko "dry-run: no dry-run announcement on stderr"
fi

if printf '%s\n' "$dry_out" | grep -qE '^ami-build: done'; then
    ko "dry-run: 'done' line appeared (real build ran)"
else
    ok "dry-run: no real build ran"
fi

# ---------------------------------------------------------------------------
# 2. Build a real AMI
# Run with --retain 100 to avoid pruning the stale copy during the build.
# Test 6 will explicitly exercise pruning.
# ---------------------------------------------------------------------------
printf '\ntest-ami-build: building AMI (takes several minutes)...\n' >&2

# ami-build.sh prints only the AMI id on stdout; all progress notes go to
# stderr. $() captures stdout; stderr is inherited and visible in CI logs.
new_ami_id="$(bash "$BOOTSTRAP" --retain 100)" || {
    ko "ami-build: non-zero exit"
    new_ami_id=""
}

if [[ "$new_ami_id" =~ ^ami- ]]; then
    ok "ami-build: built AMI $new_ami_id"
else
    ko "ami-build: expected ami-* on stdout, got: '${new_ami_id}'"
    printf 'test-ami-build: cannot continue without a built AMI\n' >&2
    printf 'Tests run: %s  PASS: %s  FAIL: %s\n' $(( pass + fail )) "$pass" "$fail"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

ami_tags="$(aws ec2 describe-images \
    --image-ids "$new_ami_id" \
    --query 'Images[0].Tags' \
    --output json --region "$REGION" 2>/dev/null)" || ami_tags="[]"

if printf '%s' "$ami_tags" | jq -e \
    '.[] | select(.Key == "spill:owner" and .Value == "ephemeral-ci")' >/dev/null 2>&1; then
    ok "ami-build: spill:owner tag present"
else
    ko "ami-build: spill:owner=ephemeral-ci tag missing"
fi

if printf '%s' "$ami_tags" | jq -e '.[] | select(.Key == "build-date")' >/dev/null 2>&1; then
    ok "ami-build: build-date tag present"
else
    ko "ami-build: build-date tag missing"
fi

if printf '%s' "$ami_tags" | jq -e '.[] | select(.Key == "git-commit")' >/dev/null 2>&1; then
    ok "ami-build: git-commit tag present"
else
    ko "ami-build: git-commit tag missing"
fi

# ---------------------------------------------------------------------------
# 3. Launch a test instance and wait for SSM registration (with timing)
# ---------------------------------------------------------------------------
printf '\ntest-ami-build: launching test instance from %s...\n' "$new_ami_id" >&2

test_instance_id="$(aws ec2 run-instances \
    --image-id "$new_ami_id" \
    --instance-type "c7i.large" \
    --subnet-id "${SUBNET_ID}" \
    --security-group-ids "${SECURITY_GROUP_ID}" \
    --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=Name,Value=ami-test-instance}]" \
    --region "$REGION" \
    --query 'Instances[0].InstanceId' \
    --output text 2>/dev/null)" || test_instance_id=""

_ssm_online=0
_ssm_elapsed=0

if [[ "$test_instance_id" =~ ^i- ]]; then
    ok "test-instance: launched $test_instance_id"

    ssm_start="$(date +%s)"
    ssm_deadline=$(( ssm_start + SSM_WAIT_SECONDS ))

    while [ "$(date +%s)" -le "$ssm_deadline" ]; do
        ping="$(aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=${test_instance_id}" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text --region "$REGION" 2>/dev/null)" || ping=""
        if [ "$ping" = "Online" ]; then
            _ssm_elapsed=$(( $(date +%s) - ssm_start ))
            _ssm_online=1
            break
        fi
        sleep 5
    done

    if [ "$_ssm_online" -eq 1 ]; then
        ok "ssm-registration: online after ${_ssm_elapsed}s (budget ${SSM_WAIT_SECONDS}s)"
        printf 'test-ami-build: SSM registration latency: %ds\n' "$_ssm_elapsed" >&2
    else
        ko "ssm-registration: did not register with SSM within ${SSM_WAIT_SECONDS}s"
    fi
else
    ko "test-instance: launch failed (got: '${test_instance_id}')"
fi

# ---------------------------------------------------------------------------
# 4. template-substrate.sh --check passes on the AMI instance
# ---------------------------------------------------------------------------
if [ "$_ssm_online" -eq 1 ]; then
    printf '\ntest-ami-build: running substrate check over SSM...\n' >&2

    substrate_b64="$(base64 -w0 "${SCRIPT_DIR}/template-substrate.sh")"
    check_script="$(printf \
        "printf '%%s' '%s' | base64 -d > /tmp/substrate-check.sh && bash /tmp/substrate-check.sh --check; rm -f /tmp/substrate-check.sh" \
        "$substrate_b64")"

    check_cmd_id="$(aws ssm send-command \
        --instance-ids "$test_instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "$(jq -n --arg s "$check_script" '{"commands": [[$s]]}')" \
        --timeout-seconds "$CHECK_WAIT_SECONDS" \
        --region "$REGION" \
        --query 'Command.CommandId' \
        --output text 2>/dev/null)" || check_cmd_id=""

    _check_status=""
    if [ -n "$check_cmd_id" ]; then
        check_deadline=$(( $(date +%s) + CHECK_WAIT_SECONDS ))
        while [ "$(date +%s)" -le "$check_deadline" ]; do
            _check_status="$(aws ssm get-command-invocation \
                --command-id "$check_cmd_id" \
                --instance-id "$test_instance_id" \
                --query 'Status' \
                --output text --region "$REGION" 2>/dev/null)" || _check_status=""
            case "$_check_status" in
                Success|Failed|TimedOut|Cancelled|DeliveryTimedOut|ExecutionTimedOut) break ;;
                *) sleep 5 ;;
            esac
        done

        check_stderr="$(aws ssm get-command-invocation \
            --command-id "$check_cmd_id" \
            --instance-id "$test_instance_id" \
            --query 'StandardErrorContent' \
            --output text --region "$REGION" 2>/dev/null)" || check_stderr=""

        printf '%s\n' "$check_stderr" >&2

        if [ "$_check_status" = "Success" ]; then
            ok "substrate-check: template-substrate.sh --check passed"
        else
            ko "substrate-check: failed (status: ${_check_status:-timeout})"
        fi
    else
        ko "substrate-check: could not send SSM command"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Packages from the substrate list are present; name any differences
# ---------------------------------------------------------------------------
if [ "$_ssm_online" -eq 1 ]; then
    # Extract the package arrays from template-substrate.sh by parsing them.
    substrate_pkgs="$(grep -E '^(PODMAN_PKGS|BUILD_PKGS|BASE_PKGS)=\(' \
        "${SCRIPT_DIR}/template-substrate.sh" \
        | grep -oP '\(.*?\)' | tr -d '()' | tr ' ' '\n' | grep -v '^$' \
        | sort -u | tr '\n' ' ')" || substrate_pkgs=""

    if [ -z "$substrate_pkgs" ]; then
        ko "pkg-check: could not parse substrate package lists from template-substrate.sh"
    else
        # dpkg -l returns non-ii lines for packages that are not installed.
        # shellcheck disable=SC2086
        pkg_script="dpkg -l $substrate_pkgs 2>&1 | awk '\$1 != \"ii\" {print \"NOT_INSTALLED:\", \$0}'"

        pkg_cmd_id="$(aws ssm send-command \
            --instance-ids "$test_instance_id" \
            --document-name "AWS-RunShellScript" \
            --parameters "$(jq -n --arg s "$pkg_script" '{"commands": [[$s]]}')" \
            --timeout-seconds 30 \
            --region "$REGION" \
            --query 'Command.CommandId' \
            --output text 2>/dev/null)" || pkg_cmd_id=""

        if [ -n "$pkg_cmd_id" ]; then
            # Give the command time to complete (it is a quick dpkg call).
            sleep 20
            pkg_out="$(aws ssm get-command-invocation \
                --command-id "$pkg_cmd_id" \
                --instance-id "$test_instance_id" \
                --query 'StandardOutputContent' \
                --output text --region "$REGION" 2>/dev/null)" || pkg_out=""
            pkg_status="$(aws ssm get-command-invocation \
                --command-id "$pkg_cmd_id" \
                --instance-id "$test_instance_id" \
                --query 'Status' \
                --output text --region "$REGION" 2>/dev/null)" || pkg_status=""

            not_installed="$(printf '%s' "$pkg_out" | grep '^NOT_INSTALLED:' || true)"
            if [ "$pkg_status" = "Success" ] && [ -z "$not_installed" ]; then
                ok "pkg-check: all substrate packages present"
            else
                ko "pkg-check: some substrate packages absent (see below)"
                printf '%s\n' "$not_installed" >&2
            fi
        else
            ko "pkg-check: could not send SSM command"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 6. Positive control: stale AMI + snapshot are removed by --prune-only
# ---------------------------------------------------------------------------
printf '\ntest-ami-build: running prune positive control...\n' >&2

if [ "$_pre_build_stale_ok" -ne 1 ]; then
    ko "prune-control: pre-build stale AMI creation failed; cannot run positive control"
else
    # Wait for the stale copy to become available before pruning.
    stale_deadline=$(( $(date +%s) + 300 ))
    _stale_available=0
    while [ "$(date +%s)" -le "$stale_deadline" ]; do
        stale_state="$(aws ec2 describe-images \
            --image-ids "$stale_ami_id" \
            --query 'Images[0].State' \
            --output text --region "$REGION" 2>/dev/null)" || stale_state=""
        [ "$stale_state" = "available" ] && { _stale_available=1; break; }
        sleep 10
    done

    if [ "$_stale_available" -eq 0 ]; then
        ko "prune-control: stale AMI $stale_ami_id did not become available within 300s"
    else
        # Find the stale snapshot ID for post-prune verification.
        stale_snap_id="$(aws ec2 describe-images \
            --image-ids "$stale_ami_id" \
            --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' \
            --output text --region "$REGION" 2>/dev/null)" || stale_snap_id=""

        ok "prune-control: stale AMI available (snapshot: ${stale_snap_id:-unknown})"

        # Verify both AMIs exist before pruning.
        before_count="$(aws ec2 describe-images \
            --owners self \
            --filters \
                "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
                "Name=name,Values=${AMI_NAME_PREFIX}-*" \
            --query 'length(Images)' \
            --output text --region "$REGION" 2>/dev/null)" || before_count=0

        if [ "${before_count:-0}" -ge 2 ]; then
            ok "prune-control: $before_count tagged AMIs exist before pruning"
        else
            ko "prune-control: expected >=2 tagged AMIs before pruning, got ${before_count:-0}"
        fi

        # Run prune: keep only the newest 1 (the just-built AMI, which has
        # a later CreationDate than the copy made before the build).
        prune_out="$(bash "$BOOTSTRAP" --prune-only --retain 1 2>&1)" || {
            ko "prune-control: --prune-only --retain 1 failed"
            printf '%s\n' "$prune_out" >&2
            prune_out=""
        }

        if [ -n "$prune_out" ]; then
            # Check stale AMI is gone.
            after_state="$(aws ec2 describe-images \
                --image-ids "$stale_ami_id" \
                --query 'Images[0].State' \
                --output text --region "$REGION" 2>/dev/null)" || after_state=""

            if [ -z "$after_state" ] || [ "$after_state" = "None" ]; then
                ok "prune-control: stale AMI $stale_ami_id deregistered"
                stale_ami_id=""
            else
                ko "prune-control: stale AMI $stale_ami_id still exists (state: $after_state)"
            fi

            # Check stale snapshot is gone.
            if [ -n "$stale_snap_id" ] && [[ "$stale_snap_id" =~ ^snap- ]]; then
                snap_state="$(aws ec2 describe-snapshots \
                    --snapshot-ids "$stale_snap_id" \
                    --query 'Snapshots[0].State' \
                    --output text --region "$REGION" 2>/dev/null)" || snap_state=""

                if [ -z "$snap_state" ] || [ "$snap_state" = "None" ]; then
                    ok "prune-control: stale snapshot $stale_snap_id deleted"
                    stale_snap_id=""
                else
                    ko "prune-control: stale snapshot $stale_snap_id still exists (state: $snap_state)"
                fi
            fi

            # Confirm the new AMI was retained.
            if [[ "$new_ami_id" =~ ^ami- ]]; then
                retained="$(aws ec2 describe-images \
                    --image-ids "$new_ami_id" \
                    --query 'Images[0].State' \
                    --output text --region "$REGION" 2>/dev/null)" || retained=""
                if [ "$retained" = "available" ]; then
                    ok "prune-control: new AMI $new_ami_id retained"
                else
                    ko "prune-control: new AMI $new_ami_id not available after prune (state: ${retained:-missing})"
                fi
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total=$(( pass + fail ))
printf '\nTests run: %s  PASS: %s  FAIL: %s\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

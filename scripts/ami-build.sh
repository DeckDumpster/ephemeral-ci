#!/usr/bin/env bash
#
# scripts/ami-build.sh [--retain N] [--dry-run] [--prune-only]
#
# Builds the ephemeral-ci runner AMI from Ubuntu 24.04, applying
# template-substrate.sh's guest steps over SSM. Creates an AMI named and
# tagged with the build date and the current git commit, then deregisters
# older AMIs (with their backing snapshots) keeping the newest N.
#
# DISK SIZE: 32 GiB. Measured gate runs need approximately 24 GiB:
#   OS 5, runner 1, substrate packages 2, consumer tools ~5, data ~1,
#   plus the mandatory 10 GiB deploy/diskcheck.sh floor. 32 GiB is 33%
#   headroom over the measured minimum. The Proxmox template uses 40 GiB,
#   but that was not derived from measurement.
#
# INSTANCE TYPE: c7i.large (2 vCPU, 4 GiB). AMI builds are serial work
# (apt install, runner unpack). A small builder keeps build cost low.
#
# DELIVERY: template-substrate.sh is sent to the build instance via SSM
# RunShellScript as base64. No credential or secret ever appears in
# user-data; the runner registration token is not involved in the build.
#
# AMI naming: ephemeral-ci-runner-YYYYMMDD-COMMIT
# AMI tags:
#   spill:owner=ephemeral-ci  (required for the budget filter and the reaper)
#   build-date=YYYYMMDD
#   git-commit=SHORT_SHA
#   Name=ephemeral-ci-runner
#
# --retain N (default 3): keep the N newest ephemeral-ci-runner AMIs;
#   deregister older ones together with their backing snapshots. Only AMIs
#   tagged spill:owner=ephemeral-ci are considered.
#
# --prune-only: skip the build and only run the retention step. Useful for
#   the positive-control test (create a stale AMI, run --prune-only, verify
#   removal) and for manual housekeeping.
#
# Prerequisites: scripts/aws-bootstrap.sh must have been run once against
#   account 189923011121 / us-west-2 so that scripts/aws-bootstrap-outputs.sh
#   exists. ami-build.sh reads SUBNET_ID and SECURITY_GROUP_ID from there.
#
# Permissions required beyond the spill role:
#   ec2:CreateImage, ec2:DeregisterImage, ec2:DeleteSnapshot,
#   ec2:DescribeSnapshots, ec2:StopInstances
# These are build-time operations; run with operator credentials (same
# session used for aws-bootstrap.sh).
#
set -euo pipefail

REGION="us-west-2"
ACCOUNT_ID="189923011121"
TAG_KEY="spill:owner"
TAG_VALUE="ephemeral-ci"
AMI_NAME_PREFIX="ephemeral-ci-runner"
BUILDER_TYPE="c7i.large"
ROOT_DISK_GIB=32
RETAIN_COUNT=3
# Budget for build instance to register with SSM after launch.
SSM_WAIT_SECONDS=300
# Budget for template-substrate.sh + runner install to complete.
BUILD_WAIT_SECONDS=600
# Budget for AMI snapshot to become available.
AMI_WAIT_SECONDS=600

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUTS_FILE="${SCRIPT_DIR}/aws-bootstrap-outputs.sh"

DRY_RUN=0
PRUNE_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --retain)   RETAIN_COUNT="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --prune-only) PRUNE_ONLY=1; shift ;;
        *) printf 'usage: ami-build.sh [--retain N] [--dry-run] [--prune-only]\n' >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

note() { printf 'ami-build: %s\n' "$*" >&2; }

# aws_w: mutating aws call -- skipped in dry-run; returns a placeholder string
aws_w() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] aws %s\n' "$*" >&2
        printf 'dry-run-placeholder'
        return 0
    fi
    aws "$@"
}

# ---------------------------------------------------------------------------
# verify_account
# ---------------------------------------------------------------------------
verify_account() {
    local actual
    actual="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || true
    if [ "$actual" != "$ACCOUNT_ID" ]; then
        printf 'ami-build.sh: wrong account: got %s, expected %s\n' \
            "${actual:-not authenticated}" "$ACCOUNT_ID" >&2
        return 1
    fi
    note "account: $ACCOUNT_ID (correct)"
}

# ---------------------------------------------------------------------------
# load_outputs: read subnet and security group from the bootstrap output file
# ---------------------------------------------------------------------------
load_outputs() {
    if [ ! -f "$OUTPUTS_FILE" ]; then
        printf 'ami-build.sh: %s not found -- run scripts/aws-bootstrap.sh first\n' \
            "$OUTPUTS_FILE" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    . "$OUTPUTS_FILE"
    : "${SUBNET_ID:?SUBNET_ID missing from $OUTPUTS_FILE}"
    : "${SECURITY_GROUP_ID:?SECURITY_GROUP_ID missing from $OUTPUTS_FILE}"
    : "${INSTANCE_PROFILE_NAME:?INSTANCE_PROFILE_NAME missing from $OUTPUTS_FILE}"
    note "outputs: subnet=$SUBNET_ID sg=$SECURITY_GROUP_ID profile=$INSTANCE_PROFILE_NAME"
}

# ---------------------------------------------------------------------------
# find_base_ami: latest Ubuntu 24.04 LTS (Noble) amd64 AMI from Canonical
# ---------------------------------------------------------------------------
find_base_ami() {
    note "finding latest Ubuntu 24.04 LTS AMI"
    local ami_id
    ami_id="$(aws ec2 describe-images \
        --owners 099720109477 \
        --filters \
            'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
            'Name=state,Values=available' \
            'Name=architecture,Values=x86_64' \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text \
        --region "$REGION" 2>/dev/null)"
    if [ -z "$ami_id" ] || [ "$ami_id" = "None" ]; then
        printf 'ami-build.sh: no Ubuntu 24.04 AMI found in %s\n' "$REGION" >&2
        return 1
    fi
    note "base AMI: $ami_id"
    printf '%s' "$ami_id"
}

# ---------------------------------------------------------------------------
# launch_builder: launch a build instance; return instance-id on stdout
# ---------------------------------------------------------------------------
launch_builder() {
    local base_ami_id="$1" build_date="$2" git_commit="$3"
    note "launching build instance ($BUILDER_TYPE, ${ROOT_DISK_GIB} GiB root, $base_ami_id)"

    local tag_spec_instance
    tag_spec_instance="$(jq -n --arg type instance \
        --arg tk "$TAG_KEY" --arg tv "$TAG_VALUE" \
        --arg name "$AMI_NAME_PREFIX" \
        --arg bd "$build_date" --arg gc "$git_commit" \
        '{ResourceType: $type, Tags: [
            {Key: $tk, Value: $tv},
            {Key: "Name", Value: $name},
            {Key: "build-date", Value: $bd},
            {Key: "git-commit", Value: $gc}
        ]}')"
    local tag_spec_volume
    tag_spec_volume="$(jq -n --arg type volume \
        --arg tk "$TAG_KEY" --arg tv "$TAG_VALUE" \
        --arg bd "$build_date" --arg gc "$git_commit" \
        '{ResourceType: $type, Tags: [
            {Key: $tk, Value: $tv},
            {Key: "build-date", Value: $bd},
            {Key: "git-commit", Value: $gc}
        ]}')"

    local instance_id
    instance_id="$(aws_w ec2 run-instances \
        --image-id "$base_ami_id" \
        --instance-type "$BUILDER_TYPE" \
        --subnet-id "$SUBNET_ID" \
        --security-group-ids "$SECURITY_GROUP_ID" \
        --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
        --block-device-mappings \
            "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${ROOT_DISK_GIB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true,\"Encrypted\":true}}]" \
        --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
        --tag-specifications \
            "$(printf '%s' "$tag_spec_instance")" \
            "$(printf '%s' "$tag_spec_volume")" \
        --region "$REGION" \
        --query 'Instances[0].InstanceId' \
        --output text)"

    note "launched: $instance_id"
    printf '%s' "$instance_id"
}

# ---------------------------------------------------------------------------
# wait_ssm: wait for instance to show Online in SSM; print elapsed seconds
# ---------------------------------------------------------------------------
wait_ssm() {
    local instance_id="$1"
    note "waiting for $instance_id to register with SSM (budget ${SSM_WAIT_SECONDS}s)"
    local start
    start="$(date +%s)"
    local deadline=$(( start + SSM_WAIT_SECONDS ))

    while true; do
        local now
        now="$(date +%s)"
        if [ "$now" -gt "$deadline" ]; then
            printf 'ami-build.sh: %s did not register with SSM within %ss\n' \
                "$instance_id" "$SSM_WAIT_SECONDS" >&2
            return 1
        fi
        local ping
        ping="$(aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=${instance_id}" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text --region "$REGION" 2>/dev/null)" || ping=""
        if [ "$ping" = "Online" ]; then
            local elapsed=$(( now - start ))
            note "SSM online after ${elapsed}s"
            printf '%d' "$elapsed"
            return 0
        fi
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# apply_substrate: send template-substrate.sh + runner setup over SSM;
# return SSM command-id on stdout
#
# Everything is delivered as base64 blobs in the SSM document -- no S3,
# no Parameter Store, no user-data, no stored credentials.
# ---------------------------------------------------------------------------
apply_substrate() {
    local instance_id="$1"

    # Fetch the latest Actions runner release tag.
    local runner_version
    runner_version="$(curl -sf \
        'https://api.github.com/repos/actions/runner/releases/latest' \
        | jq -r '.tag_name | ltrimstr("v")')" || runner_version=""
    if [ -z "$runner_version" ]; then
        printf 'ami-build.sh: could not fetch latest actions/runner version\n' >&2
        return 1
    fi
    note "runner version: $runner_version"

    # Encode scripts as base64 (single line, no wrapping).
    local substrate_b64 start_runner_b64
    substrate_b64="$(base64 -w0 "${SCRIPT_DIR}/template-substrate.sh")"
    start_runner_b64="$(base64 -w0 "${SCRIPT_DIR}/guest/start-runner.sh")"

    # Build the single shell script that runs on the instance. jq handles
    # the string-quoting for JSON so we do not need to escape manually.
    local script
    script="$(cat <<SCRIPT
#!/bin/bash
set -euo pipefail

# ---- substrate ----
printf '%s' "${substrate_b64}" | base64 -d > /tmp/template-substrate.sh
sudo bash /tmp/template-substrate.sh
rm -f /tmp/template-substrate.sh

# ---- runner user (Ubuntu cloud images have no 'runner' user by default) ----
id runner 2>/dev/null || sudo useradd --system --create-home --shell /bin/bash runner
sudo loginctl enable-linger runner || true

# ---- GitHub Actions runner tarball ----
RUNNER_DIR=/home/runner/actions-runner
sudo -u runner mkdir -p "\$RUNNER_DIR"
sudo -u runner curl -fsSL \
    "https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-linux-x64-${runner_version}.tar.gz" \
    -o "/tmp/actions-runner.tar.gz"
sudo -u runner tar -xzf "/tmp/actions-runner.tar.gz" -C "\$RUNNER_DIR"
rm -f "/tmp/actions-runner.tar.gz"

# ---- start-runner.sh: baked into the EC2 AMI (SSM delivers /run/gh-runner-init at boot) ----
printf '%s' "${start_runner_b64}" | base64 -d | sudo tee /home/runner/start-runner.sh >/dev/null
sudo chown runner:runner /home/runner/start-runner.sh
sudo chmod 755 /home/runner/start-runner.sh

# ---- path unit: fires when SSM writes /run/gh-runner-init after boot ----
sudo tee /etc/systemd/system/ephemeral-runner.path >/dev/null <<'UNIT'
[Unit]
Description=Watch for ephemeral runner init (written by SSM at boot)

[Path]
PathExists=/run/gh-runner-init

[Install]
WantedBy=multi-user.target
UNIT

sudo tee /etc/systemd/system/ephemeral-runner.service >/dev/null <<'UNIT'
[Unit]
Description=GitHub Actions ephemeral runner (EC2 spill)
After=network-online.target
Requires=network-online.target

[Service]
User=runner
ExecStart=/home/runner/start-runner.sh
Restart=no
StandardOutput=journal
StandardError=journal
UNIT

sudo systemctl daemon-reload
sudo systemctl enable ephemeral-runner.path

echo "ami-build: substrate applied, runner unpacked, path unit enabled"
SCRIPT
)"

    # Build the SSM parameters document using jq. Pass the entire script as
    # ONE array element so SSM runs it as a single shell invocation -- splitting
    # on newlines would break the inner heredocs that write the systemd units.
    local ssm_params
    ssm_params="$(jq -n --arg script "$script" '{"commands": [$script]}')"

    note "sending build script over SSM to $instance_id ($(printf '%s' "$script" | wc -c) bytes)"

    local cmd_id
    cmd_id="$(aws_w ssm send-command \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "$ssm_params" \
        --timeout-seconds "$BUILD_WAIT_SECONDS" \
        --region "$REGION" \
        --query 'Command.CommandId' \
        --output text)"

    note "SSM command: $cmd_id"
    printf '%s' "$cmd_id"
}

# ---------------------------------------------------------------------------
# wait_command: poll SSM command until completion; print stdout on success
# ---------------------------------------------------------------------------
wait_command() {
    local instance_id="$1" cmd_id="$2" budget="$3"
    note "waiting for SSM command $cmd_id (budget ${budget}s)"

    local deadline=$(( $(date +%s) + budget ))
    while true; do
        local now
        now="$(date +%s)"
        if [ "$now" -gt "$deadline" ]; then
            printf 'ami-build.sh: SSM command %s timed out after %ss\n' \
                "$cmd_id" "$budget" >&2
            return 1
        fi
        local status
        status="$(aws ssm get-command-invocation \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --query 'Status' \
            --output text --region "$REGION" 2>/dev/null)" || status="Pending"
        case "$status" in
            Success)
                note "SSM command succeeded"
                # Print the command stdout for the build log.
                aws ssm get-command-invocation \
                    --command-id "$cmd_id" \
                    --instance-id "$instance_id" \
                    --query 'StandardOutputContent' \
                    --output text --region "$REGION" 2>/dev/null >&2 || true
                return 0
                ;;
            Failed|TimedOut|Cancelled|Cancelling|DeliveryTimedOut|ExecutionTimedOut)
                printf 'ami-build.sh: SSM command %s: %s\n' "$cmd_id" "$status" >&2
                aws ssm get-command-invocation \
                    --command-id "$cmd_id" \
                    --instance-id "$instance_id" \
                    --query 'StandardErrorContent' \
                    --output text --region "$REGION" 2>/dev/null >&2 || true
                return 1
                ;;
        esac
        sleep 10
    done
}

# ---------------------------------------------------------------------------
# create_ami: stop instance, snapshot it, return ami-id
# ---------------------------------------------------------------------------
create_ami() {
    local instance_id="$1" ami_name="$2" build_date="$3" git_commit="$4"
    note "stopping $instance_id before snapshot"

    aws_w ec2 stop-instances --instance-ids "$instance_id" --region "$REGION" >/dev/null
    if [ "$DRY_RUN" -eq 0 ]; then
        note "waiting for instance-stopped..."
        aws ec2 wait instance-stopped --instance-ids "$instance_id" --region "$REGION"
    fi

    local tag_spec_image
    tag_spec_image="$(jq -n --arg type image \
        --arg tk "$TAG_KEY" --arg tv "$TAG_VALUE" \
        --arg name "$AMI_NAME_PREFIX" \
        --arg bd "$build_date" --arg gc "$git_commit" \
        '{ResourceType: $type, Tags: [
            {Key: $tk, Value: $tv},
            {Key: "Name", Value: $name},
            {Key: "build-date", Value: $bd},
            {Key: "git-commit", Value: $gc}
        ]}')"
    local tag_spec_snap
    tag_spec_snap="$(jq -n --arg type snapshot \
        --arg tk "$TAG_KEY" --arg tv "$TAG_VALUE" \
        --arg bd "$build_date" --arg gc "$git_commit" \
        '{ResourceType: $type, Tags: [
            {Key: $tk, Value: $tv},
            {Key: "build-date", Value: $bd},
            {Key: "git-commit", Value: $gc}
        ]}')"

    local ami_id
    ami_id="$(aws_w ec2 create-image \
        --instance-id "$instance_id" \
        --name "$ami_name" \
        --description "ephemeral-ci runner ${build_date} ${git_commit}" \
        --no-reboot \
        --tag-specifications \
            "$(printf '%s' "$tag_spec_image")" \
            "$(printf '%s' "$tag_spec_snap")" \
        --region "$REGION" \
        --query 'ImageId' \
        --output text)"

    note "AMI: $ami_id (waiting up to ${AMI_WAIT_SECONDS}s)"

    if [ "$DRY_RUN" -eq 0 ]; then
        local deadline=$(( $(date +%s) + AMI_WAIT_SECONDS ))
        while true; do
            local state
            state="$(aws ec2 describe-images \
                --image-ids "$ami_id" \
                --query 'Images[0].State' \
                --output text --region "$REGION" 2>/dev/null)" || state="pending"
            [ "$state" = "available" ] && break
            if [ "$state" = "failed" ]; then
                printf 'ami-build.sh: AMI %s failed\n' "$ami_id" >&2; return 1
            fi
            if [ "$(date +%s)" -gt "$deadline" ]; then
                printf 'ami-build.sh: AMI %s not available within %ss\n' \
                    "$ami_id" "$AMI_WAIT_SECONDS" >&2
                return 1
            fi
            sleep 15
        done
        note "AMI $ami_id is available"
    fi

    printf '%s' "$ami_id"
}

# ---------------------------------------------------------------------------
# prune_amis: keep newest RETAIN_COUNT; deregister older ones + their snapshots
#
# Only touches AMIs tagged spill:owner=ephemeral-ci and named
# ephemeral-ci-runner-*. AMIs lacking that tag are never touched.
# ---------------------------------------------------------------------------
prune_amis() {
    note "pruning old AMIs (keeping newest ${RETAIN_COUNT})"

    local amis_json
    amis_json="$(aws ec2 describe-images \
        --owners self \
        --filters \
            "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
            "Name=name,Values=${AMI_NAME_PREFIX}-*" \
        --query 'sort_by(Images, &CreationDate)[*].{id:ImageId,snaps:BlockDeviceMappings[].Ebs.SnapshotId}' \
        --output json \
        --region "$REGION" 2>/dev/null)"

    local total
    total="$(printf '%s' "$amis_json" | jq 'length')"
    note "found $total tagged AMI(s)"

    if [ "$total" -le "$RETAIN_COUNT" ]; then
        note "no pruning needed ($total <= retain $RETAIN_COUNT)"
        return 0
    fi

    local to_remove=$(( total - RETAIN_COUNT ))
    note "deregistering $to_remove stale AMI(s)"

    # Extract AMI IDs and snapshot IDs to remove, oldest first.
    # Filter out null snapshot IDs (block devices that are not EBS).
    local remove_list
    remove_list="$(printf '%s' "$amis_json" \
        | jq -r --argjson n "$to_remove" \
            '.[:$n] | .[] | .id, (.snaps // [] | .[] | select(. != null) | "snap:\(.)")')"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ "$line" == snap:* ]]; then
            snap_id="${line#snap:}"
            note "deleting snapshot $snap_id"
            aws_w ec2 delete-snapshot \
                --snapshot-id "$snap_id" \
                --region "$REGION" >/dev/null
        else
            note "deregistering AMI $line"
            aws_w ec2 deregister-image \
                --image-id "$line" \
                --region "$REGION" >/dev/null
        fi
    done <<<"$remove_list"
}

# ---------------------------------------------------------------------------
# terminate_builder
# ---------------------------------------------------------------------------
terminate_builder() {
    local instance_id="$1"
    note "terminating build instance $instance_id"
    aws_w ec2 terminate-instances \
        --instance-ids "$instance_id" \
        --region "$REGION" >/dev/null || true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

[ "$DRY_RUN" -eq 1 ] && note "dry-run mode -- no resources will be created or modified"

verify_account

if [ "$PRUNE_ONLY" -eq 1 ]; then
    prune_amis
    note "prune-only done"
    exit 0
fi

load_outputs

build_date="$(date -u +%Y%m%d)"
git_commit="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null)" || git_commit="unknown"
ami_name="${AMI_NAME_PREFIX}-${build_date}-${git_commit}"
note "building: $ami_name"

base_ami="$(find_base_ami)"
instance_id="$(launch_builder "$base_ami" "$build_date" "$git_commit")"

# On failure after launch, terminate the build instance so it does not linger.
_instance_id="$instance_id"
cleanup_on_failure() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ -n "${_instance_id:-}" ] && [ "$DRY_RUN" -eq 0 ]; then
        note "build failed -- terminating build instance $_instance_id"
        aws ec2 terminate-instances \
            --instance-ids "$_instance_id" \
            --region "$REGION" >/dev/null 2>&1 || true
    fi
}
trap cleanup_on_failure EXIT

ssm_elapsed="$(wait_ssm "$instance_id")"

cmd_id="$(apply_substrate "$instance_id")"
wait_command "$instance_id" "$cmd_id" "$BUILD_WAIT_SECONDS"

new_ami="$(create_ami "$instance_id" "$ami_name" "$build_date" "$git_commit")"

terminate_builder "$instance_id"
# Disable the failure-cleanup trap now that we have terminated successfully.
trap - EXIT

prune_amis

note "done -- $new_ami ($ami_name)"
printf '%s\n' "$new_ami"

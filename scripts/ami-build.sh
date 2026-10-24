#!/usr/bin/env bash
#
# scripts/ami-build.sh [--retain N] [--dry-run] [--prune-only]
#
# Builds the ephemeral-ci runner AMI from Ubuntu 26.04, applying
# template-substrate.sh's guest steps over SSM. Creates an AMI named and
# tagged with the build date and the current git commit, then deregisters
# older AMIs (with their backing snapshots) keeping the newest N.
#
# DISK SIZE: 64 GiB. Measured gate runs need approximately 24 GiB:
#   OS 5, runner 1, substrate packages 2, consumer tools ~5, data ~1,
#   plus the mandatory 10 GiB deploy/diskcheck.sh floor. The warm caches
#   (warm/consumers.json: cargo registry, deps-only target dirs, builder image
#   layers, node_modules, for each consumer) are added on top. Their size is
#   NOT yet measured: 64 GiB is a ceiling chosen to make the first bake fit, and
#   the bake prints `df` so the real figure can replace this guess (sp-tu41vm).
#   The Proxmox template uses 40 GiB, but that was not derived from measurement.
#
# INSTANCE TYPE: c7i.2xlarge (8 vCPU, 16 GiB). Must match the spill runner
# type so that template-substrate.sh's memory contract is validated on the
# machine that will actually run CI, not on a smaller builder that passes the
# build and fails the check on first use.
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
#   warm-lock-sha=<warm-cache.sh lock-sha: manifest + consumer lockfiles baked in>
#   substrate-sha=<sha256 of template-substrate.sh and ami-build.sh, see
#     ami_inputs_sha in ami-wait.sh>  (provision.sh refuses an AMI whose tag
#     differs from the inputs at its own ref, so a change to either one is
#     never served by an AMI built before it)
#   Name=ephemeral-ci-runner
#
# --retain N (default 2: current + rollback): keep the N newest AMIs;
#   deregister older ones together with their backing snapshots. Only AMIs
#   tagged spill:owner=ephemeral-ci are considered.
#
# --prune-only: skip the build and only run the retention step. Useful for
#   the positive-control test (create a stale AMI, run --prune-only, verify
#   removal) and for manual housekeeping.
#
# Prerequisites: infra/terraform must be applied. ami-build.sh reads SubnetIds,
#   SecurityGroupId and InstanceProfileName from the SSM parameters under
#   /ephemeral-ci/spill/ (aws ssm get-parameters-by-path).
#
# Permissions required beyond the spill role:
#   ec2:CreateImage, ec2:DeregisterImage, ec2:DeleteSnapshot,
#   ec2:DescribeSnapshots, ec2:StopInstances
# These are build-time operations; run with operator credentials.
#
set -euo pipefail

REGION="us-west-2"
ACCOUNT_ID="189923011121"
TAG_KEY="spill:owner"
TAG_VALUE="ephemeral-ci"
AMI_NAME_PREFIX="ephemeral-ci-runner"
BUILDER_TYPE="c7i.2xlarge"
ROOT_DISK_GIB=64
RETAIN_COUNT=2
# Budget for build instance to register with SSM after launch.
SSM_WAIT_SECONDS=300
# Budget for template-substrate.sh + runner install to complete.
BUILD_WAIT_SECONDS=600
# Budget for scripts/warm-cache.sh: a cold release compile alone is ~9.5 min (run 420).
WARM_WAIT_SECONDS=3600

# GitHub Actions runner, pinned. The build downloads exactly this release and refuses a
# tarball whose sha256 differs (sp-rvbce3): a "latest" lookup from the build instance hit
# GitHub's unauthenticated 60/hour per-IP limit and failed the build. The sha256 is the
# digest GitHub publishes for the linux-x64 asset. Bump both together, deliberately; a
# change here also changes the AMI inputs hash, so no older AMI is served for it.
RUNNER_VERSION="2.338.1"
RUNNER_SHA256="08e9ccb3604d2462c24b5e33604dc30810296ca15cc65f23cffd4317eb144c37"

# verify_runner_tarball <file> <sha256>: succeed only if the file hashes to the pin.
# Shipped verbatim to the build instance (declare -f), so the test exercises the same code.
verify_runner_tarball() {
    local file="$1" want="$2" got
    got="$(sha256sum "$file" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
        printf 'ami-build.sh: runner tarball sha256 %s does not match pin %s\n' "$got" "$want" >&2
        return 1
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
PRUNE_ONLY=0
KEEP_ON_FAILURE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --retain)          RETAIN_COUNT="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --prune-only)      PRUNE_ONLY=1; shift ;;
        --keep-on-failure) KEEP_ON_FAILURE=1; shift ;;
        *) printf 'usage: ami-build.sh [--retain N] [--dry-run] [--prune-only] [--keep-on-failure]\n' >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

note() { printf 'ami-build: %s\n' "$*" >&2; }

# shellcheck source=ami-wait.sh
. "${SCRIPT_DIR}/ami-wait.sh"
# shellcheck source=spill-params.sh
. "${SCRIPT_DIR}/spill-params.sh"

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
# load_stack_outputs: read subnet, sg, and instance profile from the CDK stack
# ---------------------------------------------------------------------------
load_stack_outputs() {
    local ids
    spill_params_load "$REGION" || {
        printf 'ami-build.sh: %s -- run terraform apply in infra/terraform\n' "$SPILL_PARAMS_ERR" >&2
        return 1
    }
    # SubnetIds is a comma-separated list; use the first entry for the build instance.
    ids="$(spill_param SubnetIds)"
    SUBNET_ID="${ids%%,*}"
    SECURITY_GROUP_ID="$(spill_param SecurityGroupId)"
    INSTANCE_PROFILE_NAME="$(spill_param InstanceProfileName)"
    : "${SUBNET_ID:?SubnetIds missing from ${SPILL_PARAMS_PATH}}"
    : "${SECURITY_GROUP_ID:?SecurityGroupId missing from ${SPILL_PARAMS_PATH}}"
    : "${INSTANCE_PROFILE_NAME:?InstanceProfileName missing from ${SPILL_PARAMS_PATH}}"
    note "parameters: subnet=$SUBNET_ID sg=$SECURITY_GROUP_ID profile=$INSTANCE_PROFILE_NAME"
}

# ---------------------------------------------------------------------------
# find_base_ami: the Ubuntu 26.04 LTS (Resolute) amd64 AMI pinned in
# scripts/base-ami.env, never "latest" at build time (sp-3qmmqp). Bump it
# deliberately: a latest lookup changes the image underneath an unchanged recipe.
# 26.04, not 24.04: noble ships podman 4.9.3 and the Proxmox template runs 5.7,
# so a spilled job failed tests (the rootless-netns split) a template job passes
# (sp-2h5q0k). The series both must run is PODMAN_SERIES in template-substrate.sh.
# ---------------------------------------------------------------------------
find_base_ami() {
    local BASE_AMI_ID=""
    # shellcheck source=base-ami.env
    . "${SCRIPT_DIR}/base-ami.env" 2>/dev/null || true
    if ! [[ "$BASE_AMI_ID" =~ ^ami-[0-9a-f]+$ ]]; then
        printf 'ami-build.sh: scripts/base-ami.env has no BASE_AMI_ID; refusing to look up a latest base\n' >&2
        return 1
    fi
    note "base AMI (pinned in base-ami.env): $BASE_AMI_ID"
    printf '%s' "$BASE_AMI_ID"
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

    if [ -z "$instance_id" ] || [ "$instance_id" = "None" ]; then
        printf 'ami-build.sh: run-instances returned no instance id\n' >&2
        return 1
    fi

    note "launched: $instance_id"
    printf '%s' "$instance_id"
}

# ---------------------------------------------------------------------------
# wait_ssm: wait for instance to show Online in SSM; print elapsed seconds
# ---------------------------------------------------------------------------
wait_ssm() {
    local instance_id="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        note "dry-run: skipping SSM wait (would wait up to ${SSM_WAIT_SECONDS}s for ${instance_id} to register)"
        printf '0'
        return 0
    fi
    note "waiting for $instance_id to register with SSM (budget ${SSM_WAIT_SECONDS}s)"
    local start
    start="$(date +%s)"
    local deadline=$(( start + SSM_WAIT_SECONDS ))
    local _api_errs=0

    while true; do
        local now
        now="$(date +%s)"
        if [ "$now" -gt "$deadline" ]; then
            printf 'ami-build.sh: %s did not register with SSM within %ss\n' \
                "$instance_id" "$SSM_WAIT_SECONDS" >&2
            return 1
        fi
        local ping
        if ! ping="$(aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=${instance_id}" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text --region "$REGION")"; then
            (( _api_errs++ )) || true
            if [ "$_api_errs" -ge 3 ]; then
                printf 'ami-build.sh: describe-instance-information failed %d consecutive times -- check credentials and permissions\n' \
                    "$_api_errs" >&2
                return 1
            fi
            sleep 5
            continue
        fi
        _api_errs=0
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

    # APT_PROXY_URL is optional: unset builds from the public mirrors.

    local runner_version="$RUNNER_VERSION"
    note "runner version: $runner_version (pinned)"
    local verify_fn
    verify_fn="$(declare -f verify_runner_tarball)"

    # Encode scripts as base64 (single line, no wrapping).
    local substrate_b64 start_runner_b64 runner_env_b64 flake_b64
    substrate_b64="$(base64 -w0 "${SCRIPT_DIR}/template-substrate.sh")"
    runner_env_b64="$(base64 -w0 "${SCRIPT_DIR}/runner-env.sh")"
    flake_b64="$(base64 -w0 "${SCRIPT_DIR}/../nix/flake.nix")"
    quadlet_fixture_b64="$(base64 -w0 "${SCRIPT_DIR}/fixtures/quadlet/ephemeral-ci-quadlet-probe.container")"
    start_runner_b64="$(base64 -w0 "${SCRIPT_DIR}/guest/start-runner.sh")"

    # Build the single shell script that runs on the instance. jq handles
    # the string-quoting for JSON so we do not need to escape manually.
    local script
    script="$(cat <<SCRIPT
#!/bin/bash
set -euo pipefail

# SSM keeps only the first 24 KB of stdout, and the Nix installer fills that before the
# failing line, so the failure is invisible (sp-6jft56). Everything goes to a log; on exit
# the tail of the log reaches the controller on stderr with the exit code, and on success
# the tail reaches stdout.
BUILD_LOG=/var/log/ami-build.log
exec 3>&1 4>&2
exec >"\$BUILD_LOG" 2>&1
finish() {
    local rc=\$?
    if [ "\$rc" -ne 0 ]; then
        { echo "ami-build: remote script exited \$rc; last 4000 bytes of \$BUILD_LOG:"; tail -c 4000 "\$BUILD_LOG"; } >&4
    else
        tail -c 4000 "\$BUILD_LOG" >&3
    fi
}
trap finish EXIT

# ---- runner user (Ubuntu cloud images have no 'runner' user by default) ----
# A REGULAR user, like the Proxmox template's: a --system user (uid < 1000) is not
# given a logind user manager, so /run/user/<uid> and rootless podman's runroot
# behave differently and the repo's netns store-isolation checks fail.
id runner 2>/dev/null || sudo useradd --create-home --shell /bin/bash runner

# ---- substrate ----
# The substrate builds the pinned runner env (nix/flake.nix) via runner-env.sh, which it
# finds beside itself and which finds the flake at ../nix, so the tree is recreated here.
CI_SRC=/tmp/ci-src
mkdir -p \$CI_SRC/scripts/fixtures/quadlet \$CI_SRC/nix
printf '%s' "${quadlet_fixture_b64}" | base64 -d > \$CI_SRC/scripts/fixtures/quadlet/ephemeral-ci-quadlet-probe.container
printf '%s' "${substrate_b64}" | base64 -d > \$CI_SRC/scripts/template-substrate.sh
printf '%s' "${runner_env_b64}" | base64 -d > \$CI_SRC/scripts/runner-env.sh
printf '%s' "${flake_b64}" | base64 -d > \$CI_SRC/nix/flake.nix
sudo env SUBSTRATE_MEM_DECLARED=0 SUBSTRATE_USER=runner SUBSTRATE_APT_PROXY='${APT_PROXY_URL:-}' bash \$CI_SRC/scripts/template-substrate.sh
rm -rf \$CI_SRC

# ---- GitHub Actions runner tarball ----
RUNNER_DIR=/home/runner/actions-runner
sudo -u runner mkdir -p "\$RUNNER_DIR"
${verify_fn}
sudo -u runner curl -fsSL \
    "https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-linux-x64-${runner_version}.tar.gz" \
    -o "/tmp/actions-runner.tar.gz"
verify_runner_tarball /tmp/actions-runner.tar.gz "${RUNNER_SHA256}"
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

# The unit is a SYSTEM unit, so %U expands to 0 (the manager's uid), not the User=
# uid: XDG_RUNTIME_DIR=/run/user/%U pointed at /run/user/0 and podman failed inside
# every job while the build-time check (which hardcoded the right uid) passed
# (sp-nyeqqi). The real uid is written into a session env file instead, and both
# the service and the build-time check read that one file.
RUNNER_UID="\$(id -u runner)"
sudo mkdir -p /etc/ephemeral-runner
printf 'XDG_RUNTIME_DIR=/run/user/%s\nDBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%s/bus\nHOME=/home/runner\nPATH=/opt/ephemeral-ci/runner-env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' \
    "\$RUNNER_UID" "\$RUNNER_UID" | sudo tee /etc/ephemeral-runner/session.env >/dev/null
# The user manager (podman's systemd user units) does not read session.env: give it the
# runner env's bin directory too (sp-2lzkvo).
sudo mkdir -p /etc/environment.d
printf 'PATH=/opt/ephemeral-ci/runner-env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' \
    | sudo tee /etc/environment.d/50-runner-env.conf >/dev/null
# environment.d only reaches the manager's own environment, not the units it starts, so a
# systemd-run --user unit (pokedumpster's backup-check) got the default PATH and "podman:
# command not found" (sp-5nl8jo). DefaultEnvironment is what every user unit starts with.
sudo mkdir -p /etc/systemd/user.conf.d
printf '[Manager]\nDefaultEnvironment=PATH=/opt/ephemeral-ci/runner-env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' \
    | sudo tee /etc/systemd/user.conf.d/50-runner-env.conf >/dev/null
# Ubuntu's PAM (pam_env, /etc/environment) hands user@.service its own PATH ending in /snap/bin,
# and that manager environment beats both drop-ins above, so units still lacked podman
# (sp-of73ze). Environment= on the unit itself outranks the manager's environment; a
# type-level service.d drop-in reaches every user service, transient systemd-run units too.
sudo mkdir -p /etc/systemd/user/service.d
printf '[Service]\nEnvironment=PATH=/opt/ephemeral-ci/runner-env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' \
    | sudo tee /etc/systemd/user/service.d/50-runner-env.conf >/dev/null
# linger: the user manager (and /run/user/<uid>) exists from boot, not only
# while a login session does.
sudo loginctl enable-linger runner

sudo tee /etc/systemd/system/ephemeral-runner.service >/dev/null <<UNIT
[Unit]
Description=GitHub Actions ephemeral runner (EC2 spill)
After=network-online.target user@\${RUNNER_UID}.service
Requires=network-online.target
Wants=user@\${RUNNER_UID}.service

[Service]
User=runner
EnvironmentFile=/etc/ephemeral-runner/session.env
ExecStart=/home/runner/start-runner.sh
Restart=no
StandardOutput=journal
StandardError=journal
UNIT

sudo systemctl daemon-reload
sudo systemctl enable ephemeral-runner.path

# ---- prove rootless podman starts for the runner BEFORE the image is cut ----
# A broken AMI otherwise ships and every suites job fails in runner-deps with
# "podman info fails" (sp-rgylcb). The check runs as a transient service with the
# unit's own User= and EnvironmentFile=, not an sudo-env approximation of them. The command
# goes through /usr/bin/env so podman is found on the UNIT's PATH: systemd-run itself
# resolves a bare name on sudo's PATH and fails "Failed to find executable podman" (sp-2lzkvo).
sudo systemctl start "user@\${RUNNER_UID}.service"
for _ in \$(seq 1 30); do [ -d "/run/user/\${RUNNER_UID}" ] && break; sleep 1; done
[ -d "/run/user/\${RUNNER_UID}" ] || { echo "ami-build: /run/user/\${RUNNER_UID} never appeared" >&2; exit 1; }
as_service() {
    sudo systemd-run --wait --pipe --collect -p User=runner \
        -p EnvironmentFile=/etc/ephemeral-runner/session.env /usr/bin/env "\$@"
}
as_service podman info >/dev/null \
    || { echo "ami-build: podman info fails under the runner service's environment" >&2; \
         as_service podman info >&2 || true; exit 1; }
as_service podman info --format '{{.Store.GraphDriverName}}' >&2
# A transient --user unit, the way the consumers' systemd --user units run, must find podman.
# A RESTART, not daemon-reexec: reexec serialises the running manager's environment and restores
# it, so the PATH the manager started with (before the drop-ins above existed) survives it
# (sp-vn3w0k). A restarted user@ manager re-reads user.conf.d and environment.d from scratch.
sudo systemctl restart "user@\${RUNNER_UID}.service"
for _ in \$(seq 1 30); do [ -S "/run/user/\${RUNNER_UID}/bus" ] && break; sleep 1; done
as_user() { sudo -u runner env XDG_RUNTIME_DIR="/run/user/\${RUNNER_UID}" "\$@"; }
as_user systemd-run --user --wait --pipe --collect /usr/bin/env podman --version >&2 \
    || { echo "ami-build: a systemd --user unit cannot find podman" >&2; \
         as_user systemctl --user show-environment >&2 || true; \
         as_user systemd-run --user --wait --pipe --collect /usr/bin/env >&2 || true; \
         cat /etc/systemd/user/service.d/50-runner-env.conf /etc/systemd/user.conf.d/50-runner-env.conf /etc/environment.d/50-runner-env.conf >&2 || true; exit 1; }

echo "ami-build: substrate applied, runner unpacked, path unit enabled, podman info passes"
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
# apply_warm: bake each consumer's warm caches (warm/consumers.json) as the
# runner user, after the substrate and the runner are in place. A separate SSM
# command with its own budget: the compile outlasts BUILD_WAIT_SECONDS. Returns
# the command id on stdout.
# ---------------------------------------------------------------------------
apply_warm() {
    local instance_id="$1"
    local warm_b64 manifest_b64 script ssm_params cmd_id
    warm_b64="$(base64 -w0 "${SCRIPT_DIR}/warm-cache.sh")"
    manifest_b64="$(base64 -w0 "${SCRIPT_DIR}/../warm/consumers.json")"
    script="$(cat <<SCRIPT
#!/bin/bash
set -euo pipefail
BUILD_LOG=/var/log/ami-warm.log
exec 3>&1 4>&2
exec >"\$BUILD_LOG" 2>&1
finish() {
    local rc=\$?
    if [ "\$rc" -ne 0 ]; then
        { echo "ami-build: warm bake exited \$rc; last 4000 bytes of \$BUILD_LOG:"; tail -c 4000 "\$BUILD_LOG"; } >&4
    else
        tail -c 4000 "\$BUILD_LOG" >&3
    fi
}
trap finish EXIT
command -v jq >/dev/null || sudo apt-get install -y -o DPkg::Lock::Timeout=300 jq
W=/tmp/ci-warm
mkdir -p \$W/scripts \$W/warm
printf '%s' "${warm_b64}" | base64 -d > \$W/scripts/warm-cache.sh
printf '%s' "${manifest_b64}" | base64 -d > \$W/warm/consumers.json
chmod -R a+rX \$W
# As the runner, with its login HOME: the caches belong under its \$HOME.
sudo -u runner -H bash \$W/scripts/warm-cache.sh bake
rm -rf \$W
df -h / >&2
echo "ami-build: warm caches baked: \$(cat /opt/ephemeral-ci/warm/BAKED | tr '\\n' ';')"
SCRIPT
)"
    ssm_params="$(jq -n --arg script "$script" '{"commands": [$script]}')"
    note "sending warm bake over SSM to $instance_id (budget ${WARM_WAIT_SECONDS}s)"
    cmd_id="$(aws_w ssm send-command \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "$ssm_params" \
        --timeout-seconds "$WARM_WAIT_SECONDS" \
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
    if [ "$DRY_RUN" -eq 1 ]; then
        note "dry-run: skipping build wait (would wait up to ${budget}s for command ${cmd_id})"
        return 0
    fi
    note "waiting for SSM command $cmd_id (budget ${budget}s)"

    local deadline=$(( $(date +%s) + budget ))
    local _api_errs=0
    while true; do
        local now
        now="$(date +%s)"
        if [ "$now" -gt "$deadline" ]; then
            printf 'ami-build.sh: SSM command %s timed out after %ss\n' \
                "$cmd_id" "$budget" >&2
            return 1
        fi
        local status
        if ! status="$(aws ssm get-command-invocation \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --query 'Status' \
            --output text --region "$REGION")"; then
            (( _api_errs++ )) || true
            if [ "$_api_errs" -ge 3 ]; then
                printf 'ami-build.sh: get-command-invocation failed %d consecutive times -- check credentials and permissions\n' \
                    "$_api_errs" >&2
                return 1
            fi
            sleep 10
            continue
        fi
        _api_errs=0
        case "$status" in
            Success)
                note "SSM command succeeded"
                # Print the command stdout for the build log.
                aws ssm get-command-invocation \
                    --command-id "$cmd_id" \
                    --instance-id "$instance_id" \
                    --query 'StandardOutputContent' \
                    --output text --region "$REGION" >&2 || true
                return 0
                ;;
            Failed|TimedOut|Cancelled|Cancelling|DeliveryTimedOut|ExecutionTimedOut)
                printf 'ami-build.sh: SSM command %s: %s\n' "$cmd_id" "$status" >&2
                local field
                for field in ResponseCode StandardOutputContent StandardErrorContent; do
                    printf 'ami-build.sh: --- %s (tail) ---\n' "$field" >&2
                    aws ssm get-command-invocation \
                        --command-id "$cmd_id" \
                        --instance-id "$instance_id" \
                        --query "$field" \
                        --output text --region "$REGION" 2>&1 | tail -c 4000 >&2 \
                        || note "could not retrieve $field for $cmd_id"
                    printf '\n' >&2
                done
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
    local substrate_sha
    substrate_sha="$(ami_inputs_sha "$SCRIPT_DIR")"
    local warm_lock_sha
    warm_lock_sha="$(bash "${SCRIPT_DIR}/warm-cache.sh" lock-sha)" \
        || { printf 'ami-build.sh: cannot compute warm-lock-sha; refusing to tag an image as warm\n' >&2; return 1; }
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
        --arg ss "$substrate_sha" --arg wl "$warm_lock_sha" \
        '{ResourceType: $type, Tags: [
            {Key: $tk, Value: $tv},
            {Key: "Name", Value: $name},
            {Key: "build-date", Value: $bd},
            {Key: "git-commit", Value: $gc},
            {Key: "substrate-sha", Value: $ss},
            {Key: "warm-lock-sha", Value: $wl}
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

    note "AMI: $ami_id (hang guard ${AMI_WAIT_SECONDS}s)"

    if [ "$DRY_RUN" -eq 0 ]; then
        wait_for_ami "$ami_id"
    fi

    printf '%s' "$ami_id"
}

# ---------------------------------------------------------------------------
# prune_amis: delegates to ami-prune.sh (keeps newest RETAIN_COUNT, the newest
# probe-passed, published-tag and in-use AMIs; removes the rest + snapshots)
#
# Only touches AMIs tagged spill:owner=ephemeral-ci and named
# ephemeral-ci-runner-*. AMIs lacking that tag are never touched.
# ---------------------------------------------------------------------------
prune_amis() {
    local args=(--keep "$RETAIN_COUNT")
    if [ "$DRY_RUN" -eq 1 ]; then
        # A dry run may have no credentials; the preview must not fail the build.
        bash "${SCRIPT_DIR}/ami-prune.sh" "${args[@]}" --dry-run || note "prune preview unavailable (dry-run)"
        return 0
    fi
    bash "${SCRIPT_DIR}/ami-prune.sh" "${args[@]}"
}

# The AMI is the build's deliverable; pruning is housekeeping. A prune failure
# after a successful build is named loudly but never fails the build (sp-mlqbqr).
prune_after_build() {
    if ! prune_amis; then
        note "WARNING: ami-prune failed; the new AMI is published, nothing was pruned"
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            printf 'AMI prune FAILED (build succeeded; new AMI is available): see the ami-prune log lines\n' \
                >> "$GITHUB_STEP_SUMMARY" || true
        fi
        printf '::warning::ami-prune failed; the AMI build itself succeeded\n'
    fi
    return 0
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

# Sourced (by tests) for its functions only.
[ "${BASH_SOURCE[0]}" != "$0" ] && return 0

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

load_stack_outputs

build_date="$(date -u +%Y%m%d)"
git_commit="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null)" || git_commit="unknown"
ami_name="${AMI_NAME_PREFIX}-${build_date}-${git_commit}"
note "building: $ami_name"

base_ami="$(find_base_ami)"
instance_id="$(launch_builder "$base_ami" "$build_date" "$git_commit")" || exit 1
[ -n "$instance_id" ] || { printf 'ami-build.sh: no build instance id; stopping\n' >&2; exit 1; }

# On failure after launch, terminate the build instance so it does not linger.
_instance_id="$instance_id"
cleanup_on_failure() {
    local exit_code=$?
    [ $exit_code -ne 0 ] || return 0
    [ -n "${_instance_id:-}" ] || return 0
    [ "$DRY_RUN" -eq 0 ] || return 0
    if [ "$KEEP_ON_FAILURE" -eq 1 ]; then
        local private_ip
        private_ip="$(aws ec2 describe-instances \
            --instance-ids "$_instance_id" \
            --query 'Reservations[0].Instances[0].PrivateIpAddress' \
            --output text --region "$REGION" 2>/dev/null)" || private_ip="unknown"
        note "build failed -- keeping instance $_instance_id (${private_ip}); to inspect: aws ssm start-session --target $_instance_id --region $REGION"
    else
        note "build failed -- terminating build instance $_instance_id (use --keep-on-failure to preserve it for inspection)"
        aws ec2 terminate-instances \
            --instance-ids "$_instance_id" \
            --region "$REGION" >/dev/null 2>&1 || true
    fi
}
trap cleanup_on_failure EXIT

ssm_elapsed="$(wait_ssm "$instance_id")"

cmd_id="$(apply_substrate "$instance_id")"
wait_command "$instance_id" "$cmd_id" "$BUILD_WAIT_SECONDS"

warm_cmd_id="$(apply_warm "$instance_id")"
wait_command "$instance_id" "$warm_cmd_id" "$WARM_WAIT_SECONDS"

new_ami="$(create_ami "$instance_id" "$ami_name" "$build_date" "$git_commit")"

terminate_builder "$instance_id"
# Disable the failure-cleanup trap now that we have terminated successfully.
trap - EXIT

prune_after_build

note "done -- $new_ami ($ami_name)"
printf '%s\n' "$new_ami"

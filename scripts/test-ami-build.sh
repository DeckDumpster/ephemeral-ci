#!/usr/bin/env bash
#
# scripts/test-ami-build.sh
#
# Test suite for scripts/ami-build.sh.
#
# Section 0 (offline): stubs aws (and curl) to verify offline behaviours.
# These tests run in CI without AWS credentials.
#
# Sections 1-6 (online, account 189923011121 / us-west-2, skipped otherwise):
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

# Populated from the /ephemeral-ci/spill/ SSM parameters for online tests (section 3).
SUBNET_ID=""
SECURITY_GROUP_ID=""
INSTANCE_PROFILE_NAME=""

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

# ---------------------------------------------------------------------------
# 0. Offline: spill-parameters path with an ssm get-parameters-by-path stub
# These run without AWS credentials and exercise the load_stack_outputs
# changes introduced in db-n1gi.
# ---------------------------------------------------------------------------

# Creates a temp dir with aws + curl stubs that handle all pre-launch calls.
# Caller owns cleanup (rm -rf).
_make_full_stub() {
    local d
    d="$(mktemp -d)"
    cat > "${d}/aws" << 'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "sts get-caller-identity")
        printf '189923011121'
        ;;
    "ssm get-parameters-by-path")
        printf '/ephemeral-ci/spill/SubnetIds	subnet-stub00000001,subnet-stub00000002,subnet-stub00000003
/ephemeral-ci/spill/SecurityGroupId	sg-stub000000001
/ephemeral-ci/spill/InstanceProfileName	ephemeral-ci-spill-instance
'
        ;;
    "ec2 describe-images")
        case "$*" in
            *--output\ json*) printf '[]' ;;
            *)                printf 'ami-0stub000000001' ;;
        esac
        ;;
    "ec2 run-instances")
        printf 'i-0fake123456789ab'
        ;;
    "ec2 terminate-instances"|"ec2 stop-instances")
        exit 0
        ;;
    "ssm describe-instance-information"|"ssm get-command-invocation"|"ssm send-command")
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
STUB
    chmod +x "${d}/aws"
    cat > "${d}/curl" << 'STUB'
#!/usr/bin/env bash
printf '{"tag_name":"v2.317.0"}'
STUB
    chmod +x "${d}/curl"
    printf '%s' "$d"
}

# Creates a temp dir with aws + curl stubs where SSM calls always fail.
# Use for testing that API failures are named rather than treated as Pending.
# Caller owns cleanup (rm -rf).
_make_ssm_fail_stub() {
    local d
    d="$(mktemp -d)"
    cat > "${d}/aws" << 'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "sts get-caller-identity")
        printf '189923011121'
        ;;
    "ssm get-parameters-by-path")
        printf '/ephemeral-ci/spill/SubnetIds	subnet-stub00000001,subnet-stub00000002,subnet-stub00000003
/ephemeral-ci/spill/SecurityGroupId	sg-stub000000001
/ephemeral-ci/spill/InstanceProfileName	ephemeral-ci-spill-instance
'
        ;;
    "ec2 describe-images")
        case "$*" in
            *--output\ json*) printf '[]' ;;
            *)                printf 'ami-0stub000000001' ;;
        esac
        ;;
    "ec2 run-instances")
        printf 'i-0fake123456789ab'
        ;;
    "ec2 terminate-instances"|"ec2 stop-instances")
        exit 0
        ;;
    "ssm describe-instance-information")
        printf 'An error occurred (AccessDeniedException) when calling the DescribeInstanceInformation operation: User is not authorized\n' >&2
        exit 255
        ;;
    "ssm get-command-invocation")
        printf 'An error occurred (AccessDeniedException) when calling the GetCommandInvocation operation: User is not authorized\n' >&2
        exit 255
        ;;
    "ssm send-command")
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
STUB
    chmod +x "${d}/aws"
    cat > "${d}/curl" << 'STUB'
#!/usr/bin/env bash
printf '{"tag_name":"v2.317.0"}'
STUB
    chmod +x "${d}/curl"
    printf '%s' "$d"
}

# Creates a temp dir with a fake aws binary; caller owns cleanup (rm -rf).
# Reads STUB_CF_MODE: ok | absent | empty. Every call is appended to
# $STUB_ARGV_FILE when set; describe-stacks is a test failure of its own.
_make_cf_stub() {
    local d
    d="$(mktemp -d)"
    cat > "${d}/aws" << 'STUB'
#!/usr/bin/env bash
_mode="${STUB_CF_MODE:-ok}"
[ -z "${STUB_ARGV_FILE:-}" ] || printf '%s\n' "$*" >> "$STUB_ARGV_FILE"
case "$1 $2" in
    "sts get-caller-identity")
        printf '189923011121'
        ;;
    "ssm get-parameters-by-path")
        case "$_mode" in
            absent)
                printf 'An error occurred (AccessDeniedException) when calling the GetParametersByPath operation: not authorized\n' >&2
                exit 255
                ;;
            empty)
                ;;
            *)
                printf '/ephemeral-ci/spill/SubnetIds\tsubnet-stub00000001,subnet-stub00000002,subnet-stub00000003\n/ephemeral-ci/spill/SecurityGroupId\tsg-stub000000001\n/ephemeral-ci/spill/InstanceProfileName\tephemeral-ci-spill-instance\n'
                ;;
        esac
        ;;
    "cloudformation describe-stacks")
        printf 'describe-stacks must not be called\n' >&2
        exit 99
        ;;
    *)
        exit 0
        ;;
esac
STUB
    chmod +x "${d}/aws"
    printf '%s' "$d"
}

# 0a. unreadable parameters: ami-build.sh must name the path and terraform apply
_sd="$(_make_cf_stub)"
_out="$(STUB_CF_MODE=absent PATH="${_sd}:${PATH}" bash "$BOOTSTRAP" --dry-run 2>&1)" || true
rm -rf "$_sd"
if grep -q '/ephemeral-ci/spill/' <<<"$_out"; then
    ok "spill parameters unreadable: error names the parameter path"
else
    ko "spill parameters unreadable: error does not name /ephemeral-ci/spill/ (got: $_out)"
fi
if grep -q 'terraform apply' <<<"$_out"; then
    ok "spill parameters unreadable: error names terraform apply"
else
    ko "spill parameters unreadable: error does not name terraform apply (got: $_out)"
fi

# 0b. no parameters under the path: same, and says there are none
_sd="$(_make_cf_stub)"
_out="$(STUB_CF_MODE=empty PATH="${_sd}:${PATH}" bash "$BOOTSTRAP" --dry-run 2>&1)" || true
rm -rf "$_sd"
if grep -q 'no SSM parameters under /ephemeral-ci/spill/' <<<"$_out"; then
    ok "spill parameters empty: error says there are none"
else
    ko "spill parameters empty: error does not say so (got: $_out)"
fi
if grep -q 'terraform apply' <<<"$_out"; then
    ok "spill parameters empty: error names terraform apply"
else
    ko "spill parameters empty: error does not name terraform apply (got: $_out)"
fi

# 0c. success path: all three ids are read from the parameters and logged,
# and the stack is never described
_sd="$(_make_cf_stub)"
_argv="$_sd/argv"
_out="$(STUB_ARGV_FILE="$_argv" STUB_CF_MODE=ok PATH="${_sd}:${PATH}" bash "$BOOTSTRAP" --dry-run 2>&1)" || true
_calls="$(cat "$_argv" 2>/dev/null || true)"
rm -rf "$_sd"
if grep -q 'subnet=subnet-stub00000001' <<<"$_out"; then
    ok "spill parameters ok: SubnetIds loaded"
else
    ko "spill parameters ok: SubnetIds not found in output (got: $_out)"
fi
if grep -q 'sg=sg-stub000000001' <<<"$_out"; then
    ok "spill parameters ok: SecurityGroupId loaded"
else
    ko "spill parameters ok: SecurityGroupId not found in output"
fi
if grep -q 'profile=ephemeral-ci-spill-instance' <<<"$_out"; then
    ok "spill parameters ok: InstanceProfileName loaded"
else
    ko "spill parameters ok: InstanceProfileName not found in output"
fi
if grep -q 'ssm get-parameters-by-path .*--path /ephemeral-ci/spill/' <<<"$_calls" \
   && ! grep -q 'describe-stacks' <<<"$_calls"; then
    ok "spill parameters ok: read by path, describe-stacks never called"
else
    ko "spill parameters ok: wrong aws calls (got: $_calls)"
fi

# 0d. dry-run completes without polling SSM, announces what it would have waited for
_sd="$(_make_full_stub)"
_out=""
_rc=0
_out="$(PATH="${_sd}:${PATH}" bash "$BOOTSTRAP" --dry-run 2>&1)" || _rc=$?
rm -rf "$_sd"
if [ "$_rc" -eq 0 ]; then
    ok "dry-run-fast: exits 0"
else
    ko "dry-run-fast: non-zero exit $_rc (output: $_out)"
fi
if grep -q 'dry-run: skipping SSM wait' <<<"$_out"; then
    ok "dry-run-fast: announces skipped SSM wait with budget"
else
    ko "dry-run-fast: no SSM wait skip announcement in dry-run output (got: $_out)"
fi
if grep -q 'dry-run: skipping build wait' <<<"$_out"; then
    ok "dry-run-fast: announces skipped build wait with budget"
else
    ko "dry-run-fast: no build wait skip announcement in dry-run output (got: $_out)"
fi

# 0e. persistent SSM API failures exit non-zero naming the error, not treated as Pending
_sd="$(_make_ssm_fail_stub)"
_out=""
_rc=0
_out="$(PATH="${_sd}:${PATH}" bash "$BOOTSTRAP" 2>&1)" || _rc=$?
rm -rf "$_sd"
if [ "$_rc" -ne 0 ]; then
    ok "ssm-api-fail: exits non-zero on persistent SSM API failure"
else
    ko "ssm-api-fail: exited 0 (expected non-zero)"
fi
if ! grep -qE '^(Pending|InProgress)$' <<<"$_out"; then
    ok "ssm-api-fail: API failure not misreported as Pending/InProgress"
else
    ko "ssm-api-fail: API failure was reported as Pending or InProgress (got: $_out)"
fi
if grep -q 'AccessDeniedException\|failed.*consecutive' <<<"$_out"; then
    ok "ssm-api-fail: output names the API error or consecutive failure count"
else
    ko "ssm-api-fail: output does not name the API error (got: $_out)"
fi

# ---------------------------------------------------------------------------
# 0d-0e. Offline: SSM failure path -- StandardErrorContent visible, --keep-on-failure
#
# Creates a stub environment that simulates a successful launch followed by
# an SSM command that returns Failed. Uses this to verify:
#   0d: default path terminates the instance and mentions --keep-on-failure
#   0e: --keep-on-failure preserves the instance and prints start-session
# ---------------------------------------------------------------------------

# 0c2. run-instances failing/empty must stop the build, not continue with an empty id.
_rd="$(mktemp -d)"
cat > "${_rd}/aws" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "sts get-caller-identity") printf '189923011121' ;;
    "ssm get-parameters-by-path")
        printf '/ephemeral-ci/spill/SubnetIds\tsubnet-s1\n/ephemeral-ci/spill/SecurityGroupId\tsg-s1\n/ephemeral-ci/spill/InstanceProfileName\tprof-s1\n' ;;
    "ec2 describe-images") printf 'ami-stubbase001' ;;
    "ec2 run-instances") printf 'None' ;;
    "ssm describe-instance-information") printf 'ssm-called-with-empty-id\n' >&2 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "${_rd}/aws"
_out_rd="$(PATH="${_rd}:${PATH}" bash "$BOOTSTRAP" 2>&1)" && _rc_rd=0 || _rc_rd=$?
rm -rf "$_rd"
if [ "$_rc_rd" -ne 0 ] && grep -q 'no instance id' <<<"$_out_rd" && ! grep -q 'Waiting for' <<<"$_out_rd"; then
    ok "run-instances empty id: build stops before the SSM wait"
else
    ko "run-instances empty id: build did not stop (rc=$_rc_rd, got: $(printf '%s' "$_out_rd" | tail -3))"
fi

# Helper: write aws + curl stubs into a tempdir.
# The aws stub bakes $term_file into the terminate-instances arm at write time
# so the stub can record calls without needing environment variables at runtime.
_make_ssm_fail_stub() {
    local d term_file="$1" big="${2:-}"
    d="$(mktemp -d)"
    # Unquoted heredoc: $term_file expands now; \$... vars expand in the stub at runtime.
    cat > "${d}/aws" <<STUB
#!/usr/bin/env bash
_sub="\$1 \$2"
_all="\$*"
case "\$_sub" in
    "sts get-caller-identity")
        printf '189923011121' ;;
    "ssm get-parameters-by-path")
        printf '/ephemeral-ci/spill/SubnetIds\tsubnet-stub0001,subnet-stub0002,subnet-stub0003\n/ephemeral-ci/spill/SecurityGroupId\tsg-stub0001\n/ephemeral-ci/spill/InstanceProfileName\tprof-stub0001\n' ;;
    "ec2 describe-images")
        printf 'ami-stubbase001' ;;
    "ec2 run-instances")
        printf 'i-stubinstance001' ;;
    "ec2 describe-instances")
        printf '10.0.1.100' ;;
    "ec2 terminate-instances")
        printf 'called\n' >> "${term_file}" ;;
    "ssm describe-instance-information")
        printf 'Online' ;;
    "ssm send-command")
        printf 'stub-cmd-id-001' ;;
    "ssm get-command-invocation")
        case "\$_all" in
            *StandardErrorContent*)  printf 'E: stub-apt-error: universe list fetch failed' ;;
            *StandardOutputContent*) if [ -n "${big}" ]; then head -c 30000 /dev/zero | tr '\\0' 'x'; printf '\\nstub-stdout-tail'; fi ;;
            *ResponseCode*)          printf '7' ;;
            *)                       printf 'Failed' ;;
        esac
        ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "${d}/aws"
    cat > "${d}/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"tag_name":"v2.322.0"}'
STUB
    chmod +x "${d}/curl"
    printf '%s' "$d"
}

# 0d. Default path: terminates instance, mentions --keep-on-failure, shows error content
_term_d="$(mktemp)"
_sd="$(_make_ssm_fail_stub "$_term_d")"
_out_d="$(PATH="${_sd}:${PATH}" bash "$BOOTSTRAP" 2>&1)" || true
rm -rf "$_sd"

if grep -q 'keep-on-failure' <<<"$_out_d"; then
    ok "ssm-fail default: failure message mentions --keep-on-failure"
else
    ko "ssm-fail default: failure message does not mention --keep-on-failure (got: $(printf '%s' "$_out_d" | tail -3))"
fi
if grep -q 'stub-apt-error' <<<"$_out_d"; then
    ok "ssm-fail default: StandardErrorContent appears in output"
else
    ko "ssm-fail default: StandardErrorContent not visible (got: $(printf '%s' "$_out_d" | tail -5))"
fi
if [ -s "$_term_d" ]; then
    ok "ssm-fail default: terminate-instances called"
else
    ko "ssm-fail default: terminate-instances was not called"
fi
rm -f "$_term_d"

# 0d2. >24 KB stdout (SSM truncates it before the failing line): the error line, the exit
# code and a bounded stdout tail still reach the log (sp-6jft56)
_term_b="$(mktemp)"
_sd="$(_make_ssm_fail_stub "$_term_b" big)"
_out_b="$(PATH="${_sd}:${PATH}" bash "$BOOTSTRAP" 2>&1)" || true
rm -rf "$_sd" "$_term_b"
if grep -q 'stub-apt-error' <<<"$_out_b" && grep -q 'stub-stdout-tail' <<<"$_out_b" \
    && grep -A1 'ResponseCode' <<<"$_out_b" | grep -qx '7' \
    && [ "$(printf '%s' "$_out_b" | wc -c)" -lt 20000 ]; then
    ok "ssm-fail big-stdout: error line, exit code and stdout tail printed, output bounded"
else
    ko "ssm-fail big-stdout: failure not fully surfaced (got: $(printf '%s' "$_out_b" | tail -c 600))"
fi

# 0e. --keep-on-failure: no termination, prints instance id and start-session command
_term_e="$(mktemp)"
_sd="$(_make_ssm_fail_stub "$_term_e")"
_out_e="$(PATH="${_sd}:${PATH}" bash "$BOOTSTRAP" --keep-on-failure 2>&1)" || true
rm -rf "$_sd"

if grep -q 'i-stubinstance001' <<<"$_out_e" && grep -q 'start-session' <<<"$_out_e"; then
    ok "ssm-fail keep-on-failure: output contains instance id and start-session command"
else
    ko "ssm-fail keep-on-failure: output missing instance id or start-session (got: $(printf '%s' "$_out_e" | tail -5))"
fi
if [ ! -s "$_term_e" ]; then
    ok "ssm-fail keep-on-failure: terminate-instances not called"
else
    ko "ssm-fail keep-on-failure: terminate-instances was called but should not have been"
fi
if grep -q 'stub-apt-error' <<<"$_out_e"; then
    ok "ssm-fail keep-on-failure: StandardErrorContent appears in output"
else
    ko "ssm-fail keep-on-failure: StandardErrorContent not visible (got: $(printf '%s' "$_out_e" | tail -5))"
fi
rm -f "$_term_e"

# 0f. retention counts probe-passed and unproven AMIs separately: 1 passed (oldest)
# + 3 newer unproven, --retain 1 must keep the passed one (sp-g681nm)
_sd="$(mktemp -d)"
_calls="$(mktemp)"
cat > "${_sd}/aws" << 'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "sts get-caller-identity") printf '189923011121' ;;
    "ec2 describe-images")
        printf '%s' '{"Images":[{"ImageId":"ami-passed","CreationDate":"2026-01-01T00:00:00Z","Tags":[{"Key":"spill:probe","Value":"passed"}],"BlockDeviceMappings":[{"Ebs":{"SnapshotId":"snap-passed","VolumeSize":64}}]},{"ImageId":"ami-u1","CreationDate":"2026-01-02T00:00:00Z","BlockDeviceMappings":[{"Ebs":{"SnapshotId":"snap-u1","VolumeSize":64}}]},{"ImageId":"ami-u2","CreationDate":"2026-01-03T00:00:00Z","BlockDeviceMappings":[{"Ebs":{"SnapshotId":"snap-u2","VolumeSize":64}}]},{"ImageId":"ami-u3","CreationDate":"2026-01-04T00:00:00Z","BlockDeviceMappings":[{"Ebs":{"SnapshotId":"snap-u3","VolumeSize":64}}]}]}' ;;
    "ec2 describe-instances") printf '{"Reservations":[]}' ;;
    "ec2 describe-launch-templates") printf '{"LaunchTemplates":[]}' ;;
    "ec2 deregister-image"|"ec2 delete-snapshot") printf '%s\n' "$*" >> "$STUB_CALLS" ;;
esac
exit 0
STUB
chmod +x "${_sd}/aws"
_out="$(STUB_CALLS="$_calls" PATH="${_sd}:${PATH}" bash "$BOOTSTRAP" --prune-only --retain 1 2>&1)" || true
if ! grep -q 'passed' "$_calls" \
    && grep -q -- '--image-id ami-u1' "$_calls" && grep -q -- '--image-id ami-u2' "$_calls" \
    && ! grep -q 'ami-u3' "$_calls"; then
    ok "retention: probe-passed AMI kept under 3 newer unproven builds; older unproven pruned"
else
    ko "retention: wrong prune set (calls: $(tr '\n' ';' < "$_calls"); output: $_out)"
fi
rm -rf "$_sd" "$_calls"

# 0g. health check: zero probe-passed AMIs is red, one is green (sp-g681nm)
_sd="$(mktemp -d)"
printf '#!/usr/bin/env bash\nprintf "%%s" "$STUB_N"\n' > "${_sd}/aws"
chmod +x "${_sd}/aws"
if STUB_N=0 PATH="${_sd}:${PATH}" bash "${SCRIPT_DIR}/check-probe-passed-ami.sh" >/dev/null 2>&1; then
    ko "health: zero probe-passed AMIs did not fail"
else
    ok "health: zero probe-passed AMIs fails"
fi
if STUB_N=1 PATH="${_sd}:${PATH}" bash "${SCRIPT_DIR}/check-probe-passed-ami.sh" >/dev/null 2>&1; then
    ok "health: one probe-passed AMI passes"
else
    ko "health: one probe-passed AMI failed"
fi
rm -rf "$_sd"

# 0h. retention keeps the AMI matching the published v-tag's recipe even when it
# is older than N newer probe-passed main AMIs (sp-h8p1u2). The fixture is a git
# repo whose v1 tag holds recipe A; ami-v1 carries A's hash, the rest carry others.
_repo="$(mktemp -d)"
git -C "$_repo" init -q
mkdir -p "$_repo/scripts" "$_repo/nix"
for f in scripts/template-substrate.sh scripts/ami-build.sh scripts/runner-env.sh nix/flake.nix; do
    echo "recipe-v1 $f" > "$_repo/$f"
done
git -C "$_repo" add -A
git -C "$_repo" -c user.email=t@t -c user.name=t commit -q -m v1
git -C "$_repo" tag v1
. "${SCRIPT_DIR}/ami-wait.sh"
_v1sha="$(ami_inputs_sha_at_ref refs/tags/v1 "$_repo")"
_sd="$(mktemp -d)"
_calls="$(mktemp)"
cat > "${_sd}/aws" << STUB
#!/usr/bin/env bash
case "\$1 \$2" in
    "sts get-caller-identity") printf '189923011121' ;;
    "ec2 describe-images")
        printf '%s' '{"Images":[{"ImageId":"ami-v1","CreationDate":"2026-01-01","Tags":[{"Key":"substrate-sha","Value":"${_v1sha}"},{"Key":"spill:probe","Value":"passed"}],"BlockDeviceMappings":[{"Ebs":{"SnapshotId":"snap-v1","VolumeSize":64}}]},{"ImageId":"ami-m1","CreationDate":"2026-01-02","Tags":[{"Key":"substrate-sha","Value":"m1"},{"Key":"spill:probe","Value":"passed"}],"BlockDeviceMappings":[{"Ebs":{"SnapshotId":"snap-m1","VolumeSize":64}}]},{"ImageId":"ami-m2","CreationDate":"2026-01-03","Tags":[{"Key":"substrate-sha","Value":"m2"},{"Key":"spill:probe","Value":"passed"}],"BlockDeviceMappings":[{"Ebs":{"SnapshotId":"snap-m2","VolumeSize":64}}]},{"ImageId":"ami-m3","CreationDate":"2026-01-04","Tags":[{"Key":"substrate-sha","Value":"m3"},{"Key":"spill:probe","Value":"passed"}],"BlockDeviceMappings":[{"Ebs":{"SnapshotId":"snap-m3","VolumeSize":64}}]}]}' ;;
    "ec2 describe-instances") printf '{"Reservations":[]}' ;;
    "ec2 describe-launch-templates") printf '{"LaunchTemplates":[]}' ;;
    "ec2 deregister-image"|"ec2 delete-snapshot") printf '%s\n' "\$*" >> "\$STUB_CALLS" ;;
esac
exit 0
STUB
chmod +x "${_sd}/aws"
_out="$(STUB_CALLS="$_calls" PATH="${_sd}:${PATH}" PUBLISHED_TAGS=v1 AMI_BUILD_REPO="$_repo" bash "$BOOTSTRAP" --prune-only --retain 2 2>&1)" || true
if ! grep -q 'ami-v1\|snap-v1' "$_calls" && grep -q -- '--image-id ami-m1' "$_calls" \
    && ! grep -q 'ami-m2\|ami-m3' "$_calls"; then
    ok "retention: published v1 recipe's AMI kept under newer probe-passed main AMIs"
else
    ko "retention: v1 AMI not protected (calls: $(tr '\n' ';' < "$_calls"); output: $_out)"
fi

# 0i. health: red when probe-passed AMIs exist but none matches the v1 recipe
printf '#!/usr/bin/env bash\ncase "$*" in *substrate-sha*) printf "%%s" "$STUB_TAGGED" ;; *) printf 1 ;; esac\n' > "${_sd}/aws"
if STUB_TAGGED=0 PATH="${_sd}:${PATH}" PUBLISHED_TAGS=v1 REPO_DIR="$_repo" bash "${SCRIPT_DIR}/check-probe-passed-ami.sh" >/dev/null 2>&1; then
    ko "health: no AMI for the v1 recipe did not fail"
else
    ok "health: no probe-passed AMI for the v1 recipe fails"
fi
if STUB_TAGGED=1 PATH="${_sd}:${PATH}" PUBLISHED_TAGS=v1 REPO_DIR="$_repo" bash "${SCRIPT_DIR}/check-probe-passed-ami.sh" >/dev/null 2>&1; then
    ok "health: probe-passed AMI for the v1 recipe passes"
else
    ko "health: AMI for the v1 recipe failed"
fi
rm -rf "$_sd" "$_calls" "$_repo"

# 0i2. the base AMI is pinned in base-ami.env, never looked up as latest (sp-3qmmqp), and the
# warm bake puts the pinned runner-env podman on PATH so runner-deps never apt-installs one.
if (BASE_AMI_ID=""; . "${SCRIPT_DIR}/base-ami.env"; [[ "$BASE_AMI_ID" =~ ^ami-[0-9a-f]+$ ]]); then
    ok "base-ami.env pins a base AMI id"
else
    ko "base-ami.env has no valid BASE_AMI_ID"
fi
if grep -q 'ubuntu-resolute-26.04-amd64-server-\*' "$BOOTSTRAP"; then
    ko "ami-build.sh still resolves the latest base AMI"
else
    ok "ami-build.sh has no latest-base lookup"
fi
if grep -q 'PATH="/opt/ephemeral-ci/runner-env/bin:' "${SCRIPT_DIR}/warm-cache.sh"; then
    ok "warm-cache.sh puts the runner-env podman first on PATH"
else
    ko "warm-cache.sh bake PATH lacks the runner-env bin"
fi
# a bump of the pin must rebuild the AMI, so the build workflow triggers on base-ami.env.
if grep -q '^      - scripts/base-ami.env$' "${SCRIPT_DIR}/../.github/workflows/ami-build.yml"; then
    ok "ami-build.yml triggers on a base-ami.env change"
else
    ko "ami-build.yml does not trigger on base-ami.env"
fi

# 0j. the runner is pinned and its tarball checksum-verified (sp-rvbce3): no "latest" lookup,
# and a tarball whose sha256 differs from the pin is refused.
(. "$BOOTSTRAP"; true)
if grep -q 'releases/latest' "$BOOTSTRAP"; then
    ko "ami-build.sh still looks up the latest actions/runner release"
else
    ok "ami-build.sh has no latest-runner lookup"
fi
_rd="$(mktemp -d)"
printf 'runner tarball' > "${_rd}/t.tgz"
_good="$(sha256sum "${_rd}/t.tgz" | cut -d' ' -f1)"
if (. "$BOOTSTRAP"; verify_runner_tarball "${_rd}/t.tgz" "$_good") 2>/dev/null; then
    ok "verify_runner_tarball: accepts a tarball matching the pin"
else
    ko "verify_runner_tarball: rejected a matching tarball"
fi
if (. "$BOOTSTRAP"; verify_runner_tarball "${_rd}/t.tgz" "$(printf '0%.0s' {1..64})") 2>/dev/null; then
    ko "verify_runner_tarball: accepted a tarball differing from the pin"
else
    ok "verify_runner_tarball: refuses a tarball differing from the pin"
fi
if (. "$BOOTSTRAP"; [[ "$RUNNER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$RUNNER_SHA256" =~ ^[0-9a-f]{64}$ ]]); then
    ok "runner pin is a version plus a 64-hex sha256"
else
    ko "runner pin malformed"
fi
rm -rf "$_rd"

# ---------------------------------------------------------------------------
# Online tests (sections 1-6): skip when not authenticated to account 189923011121
# ---------------------------------------------------------------------------
actual_account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || true
if [ "$actual_account" != "$ACCOUNT_ID" ]; then
    printf 'test-ami-build: skipping online tests (need account %s; authenticated: %s)\n' \
        "$ACCOUNT_ID" "${actual_account:-none}" >&2
    printf 'Tests run: %s  PASS: %s  FAIL: %s\n' $(( pass + fail )) "$pass" "$fail"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

# Read the spill ids from the SSM parameters under /ephemeral-ci/spill/ for use in test 3.
SUBNET_ID=""; SECURITY_GROUP_ID=""; INSTANCE_PROFILE_NAME=""
# shellcheck source=spill-params.sh
. "$(dirname "${BASH_SOURCE[0]}")/spill-params.sh"
if spill_params_load "$REGION"; then
    SUBNET_ID="$(spill_param SubnetIds)"; SUBNET_ID="${SUBNET_ID%%,*}"
    SECURITY_GROUP_ID="$(spill_param SecurityGroupId)"
    INSTANCE_PROFILE_NAME="$(spill_param InstanceProfileName)"
fi

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

if grep -q 'dry-run' <<<"$dry_out"; then
    ok "dry-run: dry-run mode announced"
else
    ko "dry-run: no dry-run announcement on stderr"
fi

if grep -qE '^ami-build: done' <<<"$dry_out"; then
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

_want_sha="$(cat "${SCRIPT_DIR}/template-substrate.sh" "${SCRIPT_DIR}/ami-build.sh" "${SCRIPT_DIR}/runner-env.sh" "${SCRIPT_DIR}/../nix/flake.nix" | sha256sum | cut -d' ' -f1)"
if printf '%s' "$ami_tags" | jq -e --arg v "$_want_sha" '.[] | select(.Key == "substrate-sha" and .Value == $v)' >/dev/null 2>&1; then
    ok "ami-build: substrate-sha tag equals sha256 of template-substrate.sh + ami-build.sh"
else
    ko "ami-build: substrate-sha tag missing or differs from template-substrate.sh"
fi

# ---------------------------------------------------------------------------
# 3. Launch a test instance and wait for SSM registration (with timing)
# ---------------------------------------------------------------------------
printf '\ntest-ami-build: launching test instance from %s...\n' "$new_ami_id" >&2

test_instance_id="$(aws ec2 run-instances \
    --image-id "$new_ami_id" \
    --instance-type "c7i.2xlarge" \
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

            not_installed="$(grep '^NOT_INSTALLED:' <<<"$pkg_out" || true)"
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
# wait_for_ami: pending N times then available passes; failed fails at once
# ---------------------------------------------------------------------------
_wd="$(mktemp -d)"
cat > "${_wd}/aws" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STUB_COUNT"
if [ "$n" -le "${STUB_PENDING:-0}" ]; then printf 'pending'; else printf '%s' "$STUB_FINAL"; fi
STUB
chmod +x "${_wd}/aws"
_run_wait() {  # <pending> <final> [guard]
    : > "${_wd}/count"
    PATH="${_wd}:${PATH}" STUB_COUNT="${_wd}/count" STUB_PENDING="$1" STUB_FINAL="$2"         AMI_POLL_SECONDS=0 AMI_WAIT_SECONDS="${3:-2700}" REGION=us-east-1         GITHUB_STEP_SUMMARY="${_wd}/summary"         bash -c '. "$1"; note() { echo "$*" >&2; }; wait_for_ami ami-x' _ "${SCRIPT_DIR}/ami-wait.sh" 2>&1
}
if _run_wait 4 available >/dev/null && [ "$(cat "${_wd}/count")" = 5 ] && grep -q 'ami-x availability latency' "${_wd}/summary"; then
    ok "wait_for_ami: pending x4 then available passes; latency in job summary"
else
    ko "wait_for_ami: pending then available did not pass"
fi
_wout="$(_run_wait 2 failed)" && _wrc=0 || _wrc=$?
if [ "$_wrc" -ne 0 ] && [ "$(cat "${_wd}/count")" = 3 ] && grep -q 'failed' <<<"$_wout"; then
    ok "wait_for_ami: failed state fails immediately"
else
    ko "wait_for_ami: failed state did not fail at once (rc=$_wrc)"
fi
_wout="$(_run_wait 99999 available -1)" && _wrc=0 || _wrc=$?
if [ "$_wrc" -ne 0 ] && grep -q 'still "pending"' <<<"$_wout"; then
    ok "wait_for_ami: hang guard names the image and last state"
else
    ko "wait_for_ami: hang guard message wrong (rc=$_wrc): $_wout"
fi
rm -rf "$_wd"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total=$(( pass + fail ))
printf '\nTests run: %s  PASS: %s  FAIL: %s\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

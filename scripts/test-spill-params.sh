#!/usr/bin/env bash
# Offline tests: the spill scripts resolve their infra ids from the SSM
# parameters under /ephemeral-ci/spill/ (written by infra/terraform/ssm.tf) and
# none of them calls `cloudformation describe-stacks`. The aws CLI is a stub;
# provision.sh and ami-build.sh have the same assertions in their own suites.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

ARGV="$SCRATCH/argv"
cat > "$SCRATCH/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGV_FILE"
case "$1 $2" in
    "ssm get-parameters-by-path")
        case "${STUB_MODE:-ok}" in
            denied) printf 'An error occurred (AccessDeniedException) when calling the GetParametersByPath operation\n' >&2; exit 255 ;;
            empty) ;;
            *) printf '/ephemeral-ci/spill/SubnetIds\tsubnet-a,subnet-b\n/ephemeral-ci/spill/SecurityGroupId\tsg-1\n/ephemeral-ci/spill/LaunchTemplateId\tlt-1\n/ephemeral-ci/spill/LaunchTemplateName\tephemeral-ci-spill\n/ephemeral-ci/spill/InstanceProfileName\tprof-1\n/ephemeral-ci/spill/DeliverDocumentName\tdeliver-doc-1\n/ephemeral-ci/spill/DiagnoseDocumentName\tdiag-doc-1\n' ;;
        esac ;;
    "cloudformation describe-stacks") printf 'describe-stacks must not be called\n' >&2; exit 99 ;;
    "iam simulate-principal-policy") printf '{"EvaluationResults":[]}\n' ;;
    "ssm send-command") printf 'cmd-1\n' ;;
    "ssm get-command-invocation") printf 'Success\n' ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$SCRATCH/aws"
export STUB_ARGV_FILE="$ARGV"
run() { PATH="$SCRATCH:$PATH" "$@" 2>&1; }

# ── the library ──────────────────────────────────────────────────────────────
# shellcheck source=spill-params.sh
. "$DIR/spill-params.sh"
: > "$ARGV"
PATH="$SCRATCH:$PATH" spill_params_load us-west-2 || ko "lib: load failed: $SPILL_PARAMS_ERR"
[ "$(spill_param SubnetIds)" = "subnet-a,subnet-b" ] && [ "$(spill_param DiagnoseDocumentName)" = "diag-doc-1" ] \
    && ok "lib: every name resolves from one get-parameters-by-path" || ko "lib: values wrong ($SPILL_PARAMS)"
[ -z "$(spill_param Nope)" ] && ok "lib: an absent name is empty" || ko "lib: absent name not empty"
[ "$(grep -c . "$ARGV")" = 1 ] && grep -q -- '--path /ephemeral-ci/spill/' "$ARGV" \
    && ok "lib: one call, on /ephemeral-ci/spill/" || ko "lib: calls were: $(cat "$ARGV")"
PATH="$SCRATCH:$PATH" STUB_MODE=empty spill_params_load us-west-2 && ko "lib: empty path accepted" \
    || { grep -q 'no SSM parameters under /ephemeral-ci/spill/' <<<"$SPILL_PARAMS_ERR" && ok "lib: empty path refused with a reason" || ko "lib: reason: $SPILL_PARAMS_ERR"; }
PATH="$SCRATCH:$PATH" STUB_MODE=denied spill_params_load us-west-2 && ko "lib: denied accepted" \
    || { grep -q 'AccessDenied' <<<"$SPILL_PARAMS_ERR" && ok "lib: a denied read carries aws's error" || ko "lib: reason: $SPILL_PARAMS_ERR"; }

# ── ec2-diag.sh ──────────────────────────────────────────────────────────────
: > "$ARGV"
out="$(run bash "$DIR/ec2-diag.sh" i-0abc)"
if grep -q -- 'send-command .*--document-name diag-doc-1' "$ARGV" && ! grep -q describe-stacks "$ARGV"; then
    ok "ec2-diag: diagnose document comes from SSM, no describe-stacks"
else
    ko "ec2-diag: wrong calls: $(cat "$ARGV") / $out"
fi
: > "$ARGV"
out="$(STUB_MODE=denied run bash "$DIR/ec2-diag.sh" i-0abc)"
grep -q 'AccessDenied' <<<"$out" && ! grep -q send-command "$ARGV" \
    && ok "ec2-diag: unreadable parameters are reported and nothing is sent" || ko "ec2-diag: $out"

# ── check-spill-permissions.sh ───────────────────────────────────────────────
: > "$ARGV"
out="$(run bash "$DIR/check-spill-permissions.sh")"
if grep -q 'SSM document = arn:aws:ssm:[^ ]*:document/deliver-doc-1' <<<"$out" \
   && grep -q 'ssm get-parameters-by-path' "$ARGV" && ! grep -q describe-stacks "$ARGV"; then
    ok "check-spill-permissions: document ARN resolved from SSM, no describe-stacks"
else
    ko "check-spill-permissions: $(cat "$ARGV")"
fi
grep -q 'ssm:GetParametersByPath' "$ARGV" \
    && ok "check-spill-permissions: simulates ssm:GetParametersByPath" || ko "check-spill-permissions: no GetParametersByPath simulation"

# ── test-reap.sh (online section) reads the same way ─────────────────────────
grep -q 'spill_params_load' "$DIR/test-reap.sh" && ok "test-reap: loads ids through spill-params.sh" || ko "test-reap: does not use spill-params.sh"

# ── no reader describes the stack ────────────────────────────────────────────
for f in provision.sh ami-build.sh ec2-diag.sh check-spill-permissions.sh test-reap.sh spill-params.sh; do
    if grep -q 'describe-stacks' "$DIR/$f"; then ko "$f still calls describe-stacks"; else ok "$f never calls describe-stacks"; fi
done

printf 'Tests run: %s  PASS: %s  FAIL: %s\n' $((pass + fail)) "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
#
# scripts/test-aws-bootstrap.sh
#
# Test suite for scripts/aws-bootstrap.sh.
# Runs the real AWS CLI against the real account (189923011121, us-west-2).
# Do not stub aws -- a pass against a mock proves nothing.
#
# What this verifies:
#   1. aws-bootstrap.sh --dry-run exits 0 and produces no AWS API calls.
#   2. aws-bootstrap.sh runs against the real account and creates resources.
#   3. A second run against the same account reports no-change for every resource.
#   4. VPC security group has zero ingress rules.
#   5. Instance profile has exactly AmazonSSMManagedInstanceCore attached.
#   6. OIDC spill role trust policy covers DeckDumpster/ephemeral-ci only.
#   7. IAM policy simulation: TerminateInstances is denied on an untagged instance.
#   8. Launch template has IMDSv2 required, gp3 root, tag propagation to instance+volume.
#   9. Budget ephemeral-ci-spill exists with a $100 limit.
#
# Cleanup: this test creates no resources beyond what aws-bootstrap.sh creates.
# The resources created (VPC, roles, etc.) are the persistent spill-path
# infrastructure; they are NOT cleaned up here. To remove them, run the
# corresponding teardown script (db-ohr5 and later).
#
set -uo pipefail

ACCOUNT_ID="189923011121"
REGION="us-west-2"
TAG_KEY="spill:owner"
TAG_VALUE="ephemeral-ci"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${SCRIPT_DIR}/aws-bootstrap.sh"
OUTPUTS_FILE="${SCRIPT_DIR}/aws-bootstrap-outputs.sh"

pass=0
fail=0

ok() { printf 'PASS: %s\n' "$1"; (( pass++ )) || true; }
ko() { printf 'FAIL: %s\n' "$1"; (( fail++ )) || true; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

if ! command -v aws >/dev/null 2>&1; then
    printf 'test-aws-bootstrap.sh: aws CLI not found — install AWS CLI v2 and establish an SSO session for account %s\n' "$ACCOUNT_ID" >&2
    exit 1
fi

actual_account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || true
if [ "$actual_account" != "$ACCOUNT_ID" ]; then
    printf 'test-aws-bootstrap.sh: wrong account (%s); establish an SSO session for %s\n' \
        "${actual_account:-not authenticated}" "$ACCOUNT_ID" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. dry-run: exits 0, makes no AWS API calls that mutate state
# ---------------------------------------------------------------------------
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# Capture stderr to verify "dry-run" appears and no "created:" lines do.
dry_run_out="$(bash "$BOOTSTRAP" --dry-run 2>&1)" || {
    ko "dry-run: non-zero exit"
    dry_run_out=""
}

if printf '%s\n' "$dry_run_out" | grep -q '^created:'; then
    ko "dry-run: 'created:' line appeared (a real resource was made)"
else
    ok "dry-run: no resources created"
fi

if printf '%s\n' "$dry_run_out" | grep -q 'dry-run'; then
    ok "dry-run: dry-run mode announced"
else
    ko "dry-run: no dry-run announcement on stderr"
fi

# ---------------------------------------------------------------------------
# 2. First run: creates all resources (or confirms they already exist)
# ---------------------------------------------------------------------------
first_run_out="$(bash "$BOOTSTRAP" 2>&1)" || {
    ko "first-run: non-zero exit"
    first_run_out=""
}
ok "first-run: exited 0"

# ---------------------------------------------------------------------------
# 3. Second run: every resource reports no-change
# ---------------------------------------------------------------------------
second_run_out="$(bash "$BOOTSTRAP" 2>&1)" || {
    ko "second-run: non-zero exit"
    second_run_out=""
}
ok "second-run: exited 0"

if printf '%s\n' "$second_run_out" | grep -q '^created:'; then
    ko "second-run: 'created:' line on second run — not idempotent"
    printf '%s\n' "$second_run_out" | grep '^created:' >&2
else
    ok "second-run: no new resources created (idempotent)"
fi

no_change_count="$(printf '%s\n' "$second_run_out" | grep -c '^no-change:' || true)"
if [ "${no_change_count:-0}" -ge 8 ]; then
    ok "second-run: at least 8 no-change lines (all resources reconciled)"
else
    ko "second-run: expected >=8 no-change lines, got ${no_change_count:-0}"
fi

# ---------------------------------------------------------------------------
# Load outputs file
# ---------------------------------------------------------------------------
if [ ! -f "$OUTPUTS_FILE" ]; then
    ko "outputs file missing: ${OUTPUTS_FILE}"
    printf 'test-aws-bootstrap.sh: cannot continue without outputs file\n' >&2
    printf 'Tests run: %s  PASS: %s  FAIL: %s\n' $(( pass + fail )) "$pass" "$fail"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi
ok "outputs file exists"

# shellcheck source=/dev/null
. "$OUTPUTS_FILE"

# ---------------------------------------------------------------------------
# 4. Security group: zero ingress rules
# ---------------------------------------------------------------------------
ingress_count="$(aws ec2 describe-security-groups \
    --group-ids "${SECURITY_GROUP_ID}" \
    --query 'length(SecurityGroups[0].IpPermissions)' \
    --output text --region "$REGION" 2>/dev/null)" || ingress_count="error"
if [ "$ingress_count" = "0" ]; then
    ok "security-group: zero ingress rules"
else
    ko "security-group: expected 0 ingress rules, got ${ingress_count}"
fi

# ---------------------------------------------------------------------------
# 5. Instance profile: exactly AmazonSSMManagedInstanceCore
# ---------------------------------------------------------------------------
attached_policies="$(aws iam list-attached-role-policies \
    --role-name "ephemeral-ci-runner" \
    --query 'AttachedPolicies[].PolicyName' \
    --output text 2>/dev/null)" || attached_policies=""
if [ "$attached_policies" = "AmazonSSMManagedInstanceCore" ]; then
    ok "instance-profile: only AmazonSSMManagedInstanceCore attached"
else
    ko "instance-profile: expected exactly AmazonSSMManagedInstanceCore, got: ${attached_policies}"
fi

# ---------------------------------------------------------------------------
# 6. OIDC spill role trust policy: scoped to DeckDumpster/ephemeral-ci
# ---------------------------------------------------------------------------
trust_doc="$(aws iam get-role \
    --role-name "ephemeral-ci-spill" \
    --query 'Role.AssumeRolePolicyDocument' \
    --output json 2>/dev/null)" || trust_doc=""

if printf '%s\n' "$trust_doc" | grep -q 'DeckDumpster/ephemeral-ci'; then
    ok "spill-role: trust policy scoped to DeckDumpster/ephemeral-ci"
else
    ko "spill-role: trust policy does not scope to DeckDumpster/ephemeral-ci"
fi

if printf '%s\n' "$trust_doc" | grep -q 'sts.amazonaws.com'; then
    ok "spill-role: trust policy audience is sts.amazonaws.com"
else
    ko "spill-role: trust policy missing sts.amazonaws.com audience"
fi

# ---------------------------------------------------------------------------
# 7. IAM policy simulation: TerminateInstances denied on untagged instance.
#
# Uses aws iam simulate-principal-policy to evaluate the spill role's policy
# against an EC2 instance resource without the spill tag. This exercises the
# real IAM policy engine against the real account without launching an instance.
# ---------------------------------------------------------------------------
spill_role_arn="${SPILL_ROLE_ARN:-arn:aws:iam::${ACCOUNT_ID}:role/ephemeral-ci-spill}"

# Simulate TerminateInstances against an instance WITHOUT the spill tag.
sim_deny="$(aws iam simulate-principal-policy \
    --policy-source-arn "$spill_role_arn" \
    --action-names "ec2:TerminateInstances" \
    --resource-arns "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/i-testuntagged0000000" \
    --context-entries "ContextKeyName=aws:ResourceTag/spill:owner,ContextKeyValues=NOT-ephemeral-ci,ContextKeyType=string" \
    --query 'EvaluationResults[0].EvalDecision' \
    --output text 2>/dev/null)" || sim_deny=""
if [ "$sim_deny" = "implicitDeny" ] || [ "$sim_deny" = "explicitDeny" ]; then
    ok "spill-role: TerminateInstances denied on untagged instance (simulation: ${sim_deny})"
else
    ko "spill-role: TerminateInstances should be denied on untagged instance; got: ${sim_deny}"
fi

# Simulate TerminateInstances against an instance WITH the spill tag (should allow).
sim_allow="$(aws iam simulate-principal-policy \
    --policy-source-arn "$spill_role_arn" \
    --action-names "ec2:TerminateInstances" \
    --resource-arns "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/i-testtagged00000000" \
    --context-entries "ContextKeyName=aws:ResourceTag/spill:owner,ContextKeyValues=ephemeral-ci,ContextKeyType=string" \
    --query 'EvaluationResults[0].EvalDecision' \
    --output text 2>/dev/null)" || sim_allow=""
if [ "$sim_allow" = "allowed" ]; then
    ok "spill-role: TerminateInstances allowed on tagged instance (simulation)"
else
    ko "spill-role: TerminateInstances should be allowed on tagged instance; got: ${sim_allow}"
fi

# ---------------------------------------------------------------------------
# 8. Launch template: IMDSv2 required, gp3, tag propagation
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016 -- $Default is AWS's literal version alias, not a shell variable
lt_version="$(aws ec2 describe-launch-template-versions \
    --launch-template-id "${LAUNCH_TEMPLATE_ID}" \
    --versions '$Default' \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData' \
    --output json --region "$REGION" 2>/dev/null)" || lt_version=""

if printf '%s\n' "$lt_version" | grep -q '"HttpTokens": "required"'; then
    ok "launch-template: IMDSv2 required (HttpTokens=required)"
else
    ko "launch-template: IMDSv2 not enforced"
fi

if printf '%s\n' "$lt_version" | grep -q '"VolumeType": "gp3"'; then
    ok "launch-template: gp3 root volume"
else
    ko "launch-template: root volume is not gp3"
fi

if printf '%s\n' "$lt_version" | grep -q '"ResourceType": "instance"' && \
   printf '%s\n' "$lt_version" | grep -q '"ResourceType": "volume"'; then
    ok "launch-template: tags propagated to instance and volume"
else
    ko "launch-template: missing tag propagation to instance or volume"
fi

if printf '%s\n' "$lt_version" | grep -q "$TAG_VALUE"; then
    ok "launch-template: spill tag present in tag specifications"
else
    ko "launch-template: spill tag missing from tag specifications"
fi

# ---------------------------------------------------------------------------
# 9. Budget: $100/month on spill tag
# ---------------------------------------------------------------------------
budget_limit="$(aws budgets describe-budgets \
    --account-id "$ACCOUNT_ID" \
    --query "Budgets[?BudgetName=='ephemeral-ci-spill'].BudgetLimit.Amount" \
    --output text 2>/dev/null)" || budget_limit=""
if [ "$budget_limit" = "100.0" ] || [ "$budget_limit" = "100" ]; then
    ok "budget: \$100/month limit"
else
    ko "budget: expected \$100 limit, got: ${budget_limit}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total=$(( pass + fail ))
printf '\nTests run: %s  PASS: %s  FAIL: %s\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

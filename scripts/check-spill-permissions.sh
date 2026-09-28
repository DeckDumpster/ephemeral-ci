#!/usr/bin/env bash
#
# check-spill-permissions.sh
#
# Simulates the full EC2 spill action set against the deployed
# ephemeral-ci-spill IAM role using iam:SimulatePrincipalPolicy.
# Reports EVERY action that is not allowed in one pass. Exits non-zero
# if any action is denied so the caller can treat a green result as
# actionable and a red result as a repair list.
#
# Run this as (or after assuming) the ephemeral-ci-ci-test role, which
# carries iam:SimulatePrincipalPolicy for exactly this purpose.
#
# WHAT SIMULATION CANNOT VERIFY — printed on every run so a green result
# is never read as "the spill path works":
#
#   (1) Trust policy / OIDC subject — SimulatePrincipalPolicy evaluates
#       the role's identity policies (inline and attached), not its trust
#       policy. A role whose trust policy blocks assumption appears green
#       here but fails at sts:AssumeRoleWithWebIdentity. db-lx30 was this
#       shape: the OIDC subject pattern was wrong and the identity policy
#       was fine throughout.
#
#   (2) Launch template $Latest version — simulation does not call
#       DescribeLaunchTemplates. Whether $Latest resolves to a valid,
#       complete template version is not observable here. db-hq79 was
#       this shape.
#
#   (3) Malformed API requests — IAM evaluation happens after EC2 parses
#       the request. A missing required parameter or malformed body causes
#       a client error before IAM runs. db-t226 (block device mapping
#       mismatch) was this shape.
#
#   (4) SCPs / permission boundaries — not evaluated in the default mode
#       of SimulatePrincipalPolicy. This account has no organization SCPs
#       but that could change.
#
#   (5) Resource-tag conditions — simulation accepts whatever context entries
#       it is given; it does not inspect whether the real resource carries the
#       tag.  A green result for a statement conditioned on ec2:ResourceTag/*
#       or aws:ResourceTag/* asserts only "would be allowed IF the resource
#       were tagged so" — not that the resource actually is tagged.
#       For RunInstances on the launch template this is no longer an issue:
#       db-p5cj scoped that statement to the specific template ID with no
#       condition.  For TerminateInstances and SendCommand on instances the
#       tag is applied at launch time via LaunchTemplateData.TagSpecifications;
#       see the tag-verification step below.
#
#
# Usage:
#   bash scripts/check-spill-permissions.sh
#
# Environment (all optional, defaults match the deployed stack):
#   SPILL_ROLE_ARN    — ARN of the spill role (default: arn:aws:iam::189923011121:role/ephemeral-ci-spill)
#   SPILL_REGION      — AWS region (default: us-west-2)
#   SPILL_ACCOUNT     — AWS account number (default: 189923011121)
#   SPILL_STACK_NAME  — CloudFormation stack name (default: EphemeralCiSpill)

set -euo pipefail

REGION="${SPILL_REGION:-us-west-2}"
ACCOUNT="${SPILL_ACCOUNT:-189923011121}"
SPILL_ROLE_ARN="${SPILL_ROLE_ARN:-arn:aws:iam::${ACCOUNT}:role/ephemeral-ci-spill}"
STACK_NAME="${SPILL_STACK_NAME:-EphemeralCiSpill}"
INSTANCE_PROFILE_NAME="ephemeral-ci-spill-instance"

# ── Print limitations ────────────────────────────────────────────────────────
cat <<'LIMITS'
check-spill-permissions: simulation evaluates identity policies only.
  The following defect classes are NOT detectable here:
    (1) Trust policy / OIDC subject — whether the role can be assumed
        (db-lx30 was this shape; the identity policy was fine throughout)
    (2) Launch template $Latest version resolution (db-hq79)
    (3) Malformed API requests — missing params cause client errors before
        IAM runs (db-t226 was this shape)
    (4) SCPs or permission boundaries
    (5) Resource-tag conditions — simulation supplies the tag context itself;
        it does not verify the real resource carries the tag. A green result
        for a statement conditioned on a resource tag means "would be allowed
        IF tagged so" — not that the resource is actually tagged. RunInstances
        on the launch template is no longer in this category (db-p5cj scoped
        it by template ID with no condition). For TerminateInstances and
        SendCommand on instances the tag is verified via the launch template
        TagSpecifications check below.

  A green result means the identity policy allows every action listed.
  It does not mean the spill path works end-to-end.

LIMITS

printf 'check-spill-permissions: role   = %s\n' "$SPILL_ROLE_ARN"
printf 'check-spill-permissions: region = %s\n\n' "$REGION"

# ── Discover instance role ARN from instance profile ─────────────────────────
#
# The spill role must pass this role to EC2 (iam:PassRole). The instance
# profile name is hardcoded in the stack; the role name inside it is
# CDK-generated and only discoverable at runtime.
INSTANCE_ROLE_ARN=""
if _ip_raw="$(aws iam get-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --output json 2>&1)"; then
    INSTANCE_ROLE_ARN="$(printf '%s' "$_ip_raw" | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["InstanceProfile"]["Roles"][0]["Arn"])')" \
        || true
fi
if [ -z "$INSTANCE_ROLE_ARN" ]; then
    INSTANCE_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/SpillStack-InstanceRole-PLACEHOLDER"
    printf 'check-spill-permissions: WARNING: cannot read instance profile %s; using placeholder for iam:PassRole\n\n' \
        "$INSTANCE_PROFILE_NAME"
else
    printf 'check-spill-permissions: instance role = %s\n\n' "$INSTANCE_ROLE_ARN"
fi

# ── Discover launch template ID ──────────────────────────────────────────────
#
# The RunInstances statement for the launch template is now scoped to the
# specific template ID (db-p5cj).  A placeholder ID would produce a denied
# result, so we read the real ID from AWS.  If describe-launch-templates fails
# (no credentials, wrong role), step 6 is skipped with a warning rather than
# reporting a false denial.
_LT=""
if _lt_raw="$(aws ec2 describe-launch-templates \
        --filters "Name=launch-template-name,Values=ephemeral-ci-spill" \
        --region "$REGION" \
        --output json 2>&1)"; then
    _lt_id="$(printf '%s' "$_lt_raw" | python3 -c \
        'import json,sys; lts=json.load(sys.stdin)["LaunchTemplates"]; print(lts[0]["LaunchTemplateId"]) if lts else print("")')" \
        || true
    if [ -n "$_lt_id" ]; then
        _LT="arn:aws:ec2:${REGION}:${ACCOUNT}:launch-template/${_lt_id}"
        printf 'check-spill-permissions: launch template = %s\n' "$_LT"
    fi
fi
if [ -z "$_LT" ]; then
    printf 'check-spill-permissions: WARNING: cannot read launch template ephemeral-ci-spill; step 6 will be skipped\n'
fi
printf '\n'

# ── Placeholder resource ARNs ────────────────────────────────────────────────
#
# Policy statements use wildcards (e.g. arn:aws:ec2:...:instance/*). Any
# specific ARN that matches the wildcard evaluates the correct statement.
# Using obviously-fake IDs makes it clear these are simulation placeholders.
_INSTANCE="arn:aws:ec2:${REGION}:${ACCOUNT}:instance/i-00000000000000000"
# _LT is set above from the real launch template ID; placeholder not used.
_VOLUME="arn:aws:ec2:${REGION}:${ACCOUNT}:volume/vol-00000000000000000"
_NIC="arn:aws:ec2:${REGION}:${ACCOUNT}:network-interface/eni-00000000000000000"
_SG="arn:aws:ec2:${REGION}:${ACCOUNT}:security-group/sg-00000000000000000"
_SUBNET="arn:aws:ec2:${REGION}:${ACCOUNT}:subnet/subnet-00000000000000000"
_AMI="arn:aws:ec2:${REGION}::image/ami-00000000000000000"
_PARAM="arn:aws:ssm:${REGION}:${ACCOUNT}:parameter/ephemeral-ci/runner-token/testtoken"
_CF_STACK="arn:aws:cloudformation:${REGION}:${ACCOUNT}:stack/${STACK_NAME}/*"
_SSM_DOC="arn:aws:ssm:${REGION}::document/ephemeral-ci-deliver-runner-token"

# ── Simulation engine ────────────────────────────────────────────────────────
#
# FAILED_ACTIONS, INCONCLUSIVE_ACTIONS, and ERRORED_GROUPS are populated by
# run_sim calls below.
# - FAILED_ACTIONS: explicit implicitDeny or explicitDeny with no missing context
# - INCONCLUSIVE_ACTIONS: policy condition key not provided in context entries
#   (a bug in this script — not a real denial)
# - ERRORED_GROUPS: simulate-principal-policy call returned non-zero; the group
#   did not execute and its actions were never evaluated
FAILED_ACTIONS=()
INCONCLUSIVE_ACTIONS=()
ERRORED_GROUPS=()

run_sim() {
    local label="$1" input_json="$2"
    printf 'check-spill-permissions: [%s]\n' "$label"

    local result
    if ! result="$(aws iam simulate-principal-policy \
            --cli-input-json "$input_json" \
            --output json 2>&1)"; then
        printf '  ERROR: simulate-principal-policy call failed:\n  %s\n\n' "$result"
        ERRORED_GROUPS+=("$label")
        return 0
    fi

    local parsed
    parsed="$(printf '%s' "$result" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data.get("EvaluationResults", []):
    action   = r["EvalActionName"]
    decision = r["EvalDecision"]
    missing  = ",".join(r.get("MissingContextValues", []))
    print(decision + "|" + action + "|" + missing)
')"

    while IFS='|' read -r _decision _action _missing; do
        [ -n "$_decision" ] || continue
        if [ "$_decision" = "allowed" ]; then
            printf '  %-14s %s\n' "ALLOWED" "$_action"
        elif [ -n "$_missing" ]; then
            printf '  %-14s %s  [missing context: %s]\n' "INCONCLUSIVE" "$_action" "$_missing"
            INCONCLUSIVE_ACTIONS+=("$_action")
        else
            printf '  %-14s %s\n' "DENIED" "$_action"
            FAILED_ACTIONS+=("$_action")
        fi
    done <<< "$parsed"

    printf '\n'
}

# Helper: build simulation JSON using Python to avoid quoting hazards.
# env vars are passed explicitly so the Python here-doc stays single-quoted.
#
# Context entries use the format "key|type|value" — pipe-delimited so that
# colons in condition key names (e.g. ec2:ResourceTag/spill:owner) are
# preserved verbatim and do not split the key prematurely.
_sim_json() {
    POLICY_SOURCE_ARN="$SPILL_ROLE_ARN" python3 - "$@" <<'PYEOF'
import json, os, sys

policy_arn = os.environ["POLICY_SOURCE_ARN"]
args = sys.argv[1:]

# Partition args: ActionNames -- ResourceArns [-- ContextEntries key|type|value ...]
sep1 = args.index("--")
actions = args[:sep1]
rest = args[sep1+1:]

try:
    sep2 = rest.index("--")
    resources = rest[:sep2]
    ctx_raw = rest[sep2+1:]
except ValueError:
    resources = rest
    ctx_raw = []

ctx = []
for item in ctx_raw:
    parts = item.split("|", 2)
    ctx.append({
        "ContextKeyName":   parts[0],
        "ContextKeyType":   parts[1],
        "ContextKeyValues": [parts[2]],
    })

d = {
    "PolicySourceArn": policy_arn,
    "ActionNames":     actions,
    "ResourceArns":    resources,
}
if ctx:
    d["ContextEntries"] = ctx

print(json.dumps(d))
PYEOF
}

# ── Self-test: verify the denial-detection path ──────────────────────────────
#
# Simulate an action the spill role certainly does not have (iam:CreateUser).
# If the script cannot correctly report this as denied, the failure-detection
# logic itself is broken and real results cannot be trusted.
printf 'check-spill-permissions: [self-test: iam:CreateUser must be DENIED]\n'
_st_json="$(_sim_json iam:CreateUser -- '*')"
_st_out="$(aws iam simulate-principal-policy --cli-input-json "$_st_json" --output json 2>&1)" || {
    printf '  ERROR: self-test simulation call failed:\n  %s\n\n' "$_st_out"
    exit 2
}
_st_decision="$(printf '%s' "$_st_out" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["EvaluationResults"][0]["EvalDecision"])')"
case "$_st_decision" in
    implicitDeny|explicitDeny)
        printf '  PASS: iam:CreateUser → %s\n\n' "$_st_decision"
        ;;
    *)
        printf '  FAIL: expected implicitDeny or explicitDeny for iam:CreateUser, got %s\n' "$_st_decision"
        printf '  The spill role has unexpected iam:CreateUser access or the simulation is broken.\n\n'
        exit 2
        ;;
esac

# ── Simulation calls ─────────────────────────────────────────────────────────
#
# Each call groups actions that share the same resource scope and condition
# context. Context entries are provided for every condition key referenced in
# the policy so the simulation does not return MissingContextValues (which
# produces an implicitDeny that looks like a real denial but is not).
#
# Context entry format: "key|type|value"  (pipe-delimited so colons in key
# names are preserved — e.g. ec2:ResourceTag/spill:owner is the full key).

# 1. Describe and read-only actions — resource: *, no conditions
run_sim "describe / read-only (resource: *)" "$(_sim_json \
    ec2:DescribeInstances \
    ec2:DescribeImages \
    ssm:GetCommandInvocation \
    ssm:DescribeInstanceInformation \
    -- \
    '*')"

# 2. cloudformation:DescribeStacks — scoped to the EphemeralCiSpill stack
run_sim "cloudformation:DescribeStacks" "$(_sim_json \
    cloudformation:DescribeStacks \
    -- \
    "$_CF_STACK")"

# 3. SSM Parameter Store actions — scoped to the runner-token prefix.
#    PutParameter, DeleteParameter, GetParameter, GetParameters are all
#    granted; both singular and plural are required because they are distinct
#    IAM actions (neither implies the other), and SSM uses GetParameters
#    (plural) when expanding {{ssm-secure:}} references in send-command.
run_sim "ssm:PutParameter / DeleteParameter / GetParameter / GetParameters" "$(_sim_json \
    ssm:PutParameter \
    ssm:DeleteParameter \
    ssm:GetParameter \
    ssm:GetParameters \
    -- \
    "$_PARAM")"

# 4. ssm:SendCommand on SSM document — no conditions
run_sim "ssm:SendCommand on document" "$(_sim_json \
    ssm:SendCommand \
    -- \
    "$_SSM_DOC")"

# 5. ssm:SendCommand on EC2 instance — condition: aws:ResourceTag/spill:owner
#    aws:ResourceTag is the global key; ec2:ResourceTag is NOT populated for
#    SSM-authorized actions and must not be used here (db-6zny).
#    Context entry simulates the tag that provision.sh applies at launch time.
run_sim "ssm:SendCommand on instance (spill:owner tag)" "$(_sim_json \
    ssm:SendCommand \
    -- \
    "$_INSTANCE" \
    -- \
    "aws:ResourceTag/spill:owner|string|ephemeral-ci")"

# 6. ec2:RunInstances on launch template — scoped to the specific template ID,
#    no condition (db-p5cj).  Requires the real template ID from AWS; skipped
#    if the ID was not available above.
if [ -n "$_LT" ]; then
    run_sim "ec2:RunInstances on launch template (scoped by ID)" "$(_sim_json \
        ec2:RunInstances \
        -- \
        "$_LT")"
else
    printf 'check-spill-permissions: [6: ec2:RunInstances on launch template — skipped (template ID not available)]\n\n'
fi

# 7. ec2:RunInstances and ec2:CreateTags on instance resource.
#    RunInstances conditions: spill:owner tag requested, vmtoken tag present,
#    instance type in c7i/c8i families.
#    CreateTags is the IAM action EC2 evaluates when --tag-specifications is
#    passed to RunInstances; it is a separate action from RunInstances and
#    requires its own grant. db-h8ni identified this as missing.
#    ec2:CreateAction context is required for the CreateTags condition that
#    restricts tagging to resources created via RunInstances.
run_sim "ec2:RunInstances + ec2:CreateTags on instance (request tags + type)" "$(_sim_json \
    ec2:RunInstances \
    ec2:CreateTags \
    -- \
    "$_INSTANCE" \
    -- \
    "aws:RequestTag/spill:owner|string|ephemeral-ci" \
    "aws:RequestTag/ephemeral-ci:vmtoken|string|testtoken" \
    "ec2:InstanceType|string|c7i.xlarge" \
    "ec2:CreateAction|string|RunInstances")"

# 8. ec2:RunInstances on supporting resources (volume, NIC, SG, subnet, AMI).
#    These statements carry no conditions, so no context entries are needed.
run_sim "ec2:RunInstances on volume / NIC / SG / subnet / AMI" "$(_sim_json \
    ec2:RunInstances \
    -- \
    "$_VOLUME" \
    "$_NIC" \
    "$_SG" \
    "$_SUBNET" \
    "$_AMI")"

# 9. ec2:TerminateInstances — condition: ec2:ResourceTag/spill:owner
#    Context entry simulates the tag on the existing instance.
run_sim "ec2:TerminateInstances (spill:owner resource tag)" "$(_sim_json \
    ec2:TerminateInstances \
    -- \
    "$_INSTANCE" \
    -- \
    "ec2:ResourceTag/spill:owner|string|ephemeral-ci")"

# 10. iam:PassRole — the spill role must pass the instance profile's IAM role
#     to EC2 when launching instances. The iam:PassedToService context key is
#     required to evaluate the condition restricting pass to EC2 only.
#     db-h8ni identified this grant as missing.
run_sim "iam:PassRole (instance role)" "$(_sim_json \
    iam:PassRole \
    -- \
    "$INSTANCE_ROLE_ARN" \
    -- \
    "iam:PassedToService|string|ec2.amazonaws.com")"

# ── Resource-tag verification ────────────────────────────────────────────────
#
# The TerminateInstances and SendCommand policies are conditioned on
# ec2:ResourceTag/spill:owner and aws:ResourceTag/spill:owner respectively.
# Simulation cannot verify the tag exists on real instances (they are
# ephemeral); instead, verify that the launch template's TagSpecifications
# apply spill:owner=ephemeral-ci to instances at launch time.
# If describe-launch-templates is not available, skip with a warning.
printf 'check-spill-permissions: [resource-tag verification: launch template TagSpecifications]\n'
if [ -n "$_LT" ] && _lt_tags_raw="$(aws ec2 describe-launch-template-versions \
        --launch-template-id "${_LT##*/launch-template/}" \
        --versions '$Latest' \
        --region "$REGION" \
        --output json 2>&1)"; then
    _instance_tag_ok="$(printf '%s' "$_lt_tags_raw" | python3 -c '
import json, sys
data = json.load(sys.stdin)
versions = data.get("LaunchTemplateVersions", [])
if not versions:
    print("NO_VERSIONS")
    sys.exit(0)
ltd = versions[0].get("LaunchTemplateData", {})
tag_specs = ltd.get("TagSpecifications", [])
for spec in tag_specs:
    if spec.get("ResourceType") == "instance":
        for tag in spec.get("Tags", []):
            if tag.get("Key") == "spill:owner" and tag.get("Value") == "ephemeral-ci":
                print("OK")
                sys.exit(0)
print("MISSING")
')"
    case "$_instance_tag_ok" in
        OK)
            printf '  PASS: launch template applies spill:owner=ephemeral-ci to instances\n'
            ;;
        NO_VERSIONS)
            printf '  WARNING: no launch template versions found; cannot verify instance tags\n'
            INCONCLUSIVE_ACTIONS+=("ec2:ResourceTag/spill:owner (no launch template versions to verify TagSpecifications)")
            ;;
        *)
            printf '  FAIL: launch template does NOT apply spill:owner=ephemeral-ci to instances\n'
            printf '        TerminateInstances and SendCommand conditions will not match launched instances.\n'
            FAILED_ACTIONS+=("ec2:ResourceTag/spill:owner (launch template TagSpecifications missing)")
            ;;
    esac
else
    printf '  SKIPPED: launch template ID not available or describe-launch-template-versions failed\n'
fi
printf '\n'

# ── Summary ──────────────────────────────────────────────────────────────────

_exit=0

if [ "${#ERRORED_GROUPS[@]}" -gt 0 ]; then
    printf 'check-spill-permissions: %d group(s) did not execute (API call failed):\n' \
        "${#ERRORED_GROUPS[@]}"
    for _g in "${ERRORED_GROUPS[@]}"; do
        printf '  %s\n' "$_g"
    done
    printf '\n'
    _exit=1
fi

if [ "${#INCONCLUSIVE_ACTIONS[@]}" -gt 0 ]; then
    printf 'check-spill-permissions: INCONCLUSIVE (missing context keys in simulation call):\n'
    for _a in "${INCONCLUSIVE_ACTIONS[@]}"; do
        printf '  %s\n' "$_a"
    done
    printf '  Fix: add the missing context entries to this script and re-run.\n\n'
    _exit=1
fi

if [ "${#FAILED_ACTIONS[@]}" -gt 0 ]; then
    printf 'check-spill-permissions: DENIED (%d action(s)):\n' "${#FAILED_ACTIONS[@]}"
    for _a in "${FAILED_ACTIONS[@]}"; do
        printf '  %s\n' "$_a"
    done
    printf '\n'
    printf 'check-spill-permissions: Add the missing grants to infra/lib/spill-stack.ts\n'
    printf 'and run `cdk deploy EphemeralCiSpill` before retrying the spill probe.\n'
    _exit=1
fi

if [ "$_exit" -eq 0 ]; then
    printf 'check-spill-permissions: ALL ACTIONS ALLOWED\n'
fi

exit "$_exit"

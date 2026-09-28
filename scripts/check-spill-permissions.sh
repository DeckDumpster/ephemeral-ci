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

# ── Placeholder resource ARNs ────────────────────────────────────────────────
#
# Policy statements use wildcards (e.g. arn:aws:ec2:...:instance/*). Any
# specific ARN that matches the wildcard evaluates the correct statement.
# Using obviously-fake IDs makes it clear these are simulation placeholders.
_INSTANCE="arn:aws:ec2:${REGION}:${ACCOUNT}:instance/i-00000000000000000"
_LT="arn:aws:ec2:${REGION}:${ACCOUNT}:launch-template/lt-00000000000000000"
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
# FAILED_ACTIONS and INCONCLUSIVE_ACTIONS are populated by run_sim calls
# below. Inconclusive means the simulation returned MissingContextValues:
# the policy condition references a key that was not provided, so the result
# is implicitDeny for the wrong reason. That is a bug in this script's
# context entries, not a denied permission.
FAILED_ACTIONS=()
INCONCLUSIVE_ACTIONS=()

run_sim() {
    local label="$1" input_json="$2"
    printf 'check-spill-permissions: [%s]\n' "$label"

    local result
    if ! result="$(aws iam simulate-principal-policy \
            --cli-input-json "$input_json" \
            --output json 2>&1)"; then
        printf '  ERROR: simulate-principal-policy call failed:\n  %s\n\n' "$result"
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
_sim_json() {
    POLICY_SOURCE_ARN="$SPILL_ROLE_ARN" python3 - "$@" <<'PYEOF'
import json, os, sys

policy_arn = os.environ["POLICY_SOURCE_ARN"]
args = sys.argv[1:]

# Partition args: ActionNames -- ResourceArns [-- ContextEntries key:type:value ...]
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
    parts = item.split(":", 2)
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

# ── Simulation calls ─────────────────────────────────────────────────────────
#
# Each call groups actions that share the same resource scope and condition
# context. Context entries are provided for every condition key referenced in
# the policy so the simulation does not return MissingContextValues (which
# produces an implicitDeny that looks like a real denial but is not).

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

# 5. ssm:SendCommand on EC2 instance — condition: ec2:ResourceTag/spill:owner
#    Context entry simulates the tag that provision.sh applies at launch time.
run_sim "ssm:SendCommand on instance (spill:owner tag)" "$(_sim_json \
    ssm:SendCommand \
    -- \
    "$_INSTANCE" \
    -- \
    "ec2:ResourceTag/spill:owner:string:ephemeral-ci")"

# 6. ec2:RunInstances on launch template — condition: ec2:ResourceTag/aws:cloudformation:stack-name
#    The policy requires the launch template to carry the stack-name tag so
#    no other launch template in the account can be used to launch spill instances.
run_sim "ec2:RunInstances on launch template (stack-name tag)" "$(_sim_json \
    ec2:RunInstances \
    -- \
    "$_LT" \
    -- \
    "ec2:ResourceTag/aws:cloudformation:stack-name:string:EphemeralCiSpill")"

# 7. ec2:RunInstances and ec2:CreateTags on instance resource.
#    RunInstances conditions: spill:owner tag requested, vmtoken tag present,
#    instance type in c7i/c8i families.
#    CreateTags is the IAM action EC2 evaluates when --tag-specifications is
#    passed to RunInstances; it is a separate action from RunInstances and
#    requires its own grant. db-h8ni identified this as missing.
run_sim "ec2:RunInstances + ec2:CreateTags on instance (request tags + type)" "$(_sim_json \
    ec2:RunInstances \
    ec2:CreateTags \
    -- \
    "$_INSTANCE" \
    -- \
    "aws:RequestTag/spill:owner:string:ephemeral-ci" \
    "aws:RequestTag/ephemeral-ci:vmtoken:string:testtoken" \
    "ec2:InstanceType:string:c7i.xlarge")"

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
    "ec2:ResourceTag/spill:owner:string:ephemeral-ci")"

# 10. iam:PassRole — the spill role must pass the instance profile's IAM role
#     to EC2 when launching instances. No conditions in the policy statement
#     (the grant either exists or it does not). db-h8ni identified this as
#     missing.
run_sim "iam:PassRole (instance role)" "$(_sim_json \
    iam:PassRole \
    -- \
    "$INSTANCE_ROLE_ARN")"

# ── Summary ──────────────────────────────────────────────────────────────────

if [ "${#INCONCLUSIVE_ACTIONS[@]}" -gt 0 ]; then
    printf 'check-spill-permissions: INCONCLUSIVE (missing context keys in simulation call):\n'
    for _a in "${INCONCLUSIVE_ACTIONS[@]}"; do
        printf '  %s\n' "$_a"
    done
    printf '  Fix: add the missing context entries to this script and re-run.\n\n'
fi

if [ "${#FAILED_ACTIONS[@]}" -eq 0 ]; then
    printf 'check-spill-permissions: ALL ACTIONS ALLOWED\n'
    exit 0
fi

printf 'check-spill-permissions: DENIED (%d action(s)):\n' "${#FAILED_ACTIONS[@]}"
for _a in "${FAILED_ACTIONS[@]}"; do
    printf '  %s\n' "$_a"
done
printf '\n'
printf 'check-spill-permissions: Add the missing grants to infra/lib/spill-stack.ts\n'
printf 'and run `cdk deploy EphemeralCiSpill` before retrying the spill probe.\n'
exit 1

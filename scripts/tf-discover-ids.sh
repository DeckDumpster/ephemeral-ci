#!/usr/bin/env bash
#
# Read the physical ids that the retired CDK stacks gave their resources and
# write what infra/terraform needs to adopt them:
#
#   infra/terraform/physical_ids.auto.tfvars.json   deploy_role_arn, physical_ids
#   infra/terraform/backend.hcl                     S3 state bucket and role
#
# Run it with credentials for terraform-deploy (an MFA session of
# spira-concierge, then assume-role), from the repository root:
#
#   scripts/tf-discover-ids.sh
#
# Both files are read-only products of describe calls; neither is committed.
# The generated names (instance role, buckets, documents, ...) cannot be
# computed, which is why they are discovered rather than written in the .tf.

set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
OUT_DIR="${TF_OUT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/infra/terraform}"

SPILL=EphemeralCiSpill
BACKUP=EphemeralCiBackup
BOOTSTRAP=TerraformBootstrap

die() { printf 'tf-discover-ids: %s\n' "$*" >&2; exit 1; }

# stack_resources <stack> -> {"LogicalId": "physical-id", ...}
stack_resources() {
    aws cloudformation describe-stack-resources --region "$REGION" --stack-name "$1" \
        --query 'StackResources[].[LogicalResourceId,PhysicalResourceId]' --output json \
        | jq 'map({(.[0]): .[1]}) | add'
}

stack_output() {
    aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
        --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text
}

SPILL_RES="$(stack_resources "$SPILL")" || die "cannot read stack $SPILL"
BACKUP_RES="$(stack_resources "$BACKUP")" || die "cannot read stack $BACKUP"

# need <json> <logical id>: the physical id, or a refusal. A missing id would
# become an empty import id, and an empty id is an import of the wrong thing.
need() {
    local v
    v="$(jq -r --arg k "$2" '.[$k] // empty' <<<"$1")"
    [ -n "$v" ] || die "stack has no resource $2"
    printf '%s' "$v"
}

# Lifecycle rules were written without an Id, so S3 invented one; Terraform's
# rule id must be that one or the plan renames the rule.
lifecycle_rule_id() {
    local id
    id="$(aws s3api get-bucket-lifecycle-configuration --bucket "$1" \
        --query 'Rules[0].ID' --output text)" || die "cannot read lifecycle of $1"
    [ -n "$id" ] && [ "$id" != None ] || die "bucket $1 has no lifecycle rule id"
    printf '%s' "$id"
}

snapshot_bucket="$(need "$BACKUP_RES" SnapshotBucketB2BF31D3)"
staging_bucket="$(need "$SPILL_RES" RoundAmiStagingF2C9ECD5)"
secret_arn="$(need "$BACKUP_RES" WriterKeySecret7FE05A53)"
secret_name="$(aws secretsmanager describe-secret --region "$REGION" --secret-id "$secret_arn" \
    --query Name --output text)" || die "cannot describe $secret_arn"

state_bucket="$(stack_output "$BOOTSTRAP" StateBucketName)"
deploy_role_arn="$(stack_output "$BOOTSTRAP" DeployRoleArn)"
[ -n "$state_bucket" ] && [ "$state_bucket" != None ] || die "$BOOTSTRAP has no StateBucketName output"
[ -n "$deploy_role_arn" ] && [ "$deploy_role_arn" != None ] || die "$BOOTSTRAP has no DeployRoleArn output"

jq -n \
    --arg deploy_role_arn "$deploy_role_arn" \
    --arg vpc "$(need "$SPILL_RES" Vpc)" \
    --arg subnet_a "$(need "$SPILL_RES" PublicSubnet)" \
    --arg subnet_b "$(need "$SPILL_RES" PublicSubnetB)" \
    --arg subnet_c "$(need "$SPILL_RES" PublicSubnetC)" \
    --arg igw "$(need "$SPILL_RES" Igw)" \
    --arg route_table "$(need "$SPILL_RES" RouteTable)" \
    --arg security_group "$(need "$SPILL_RES" SecurityGroup)" \
    --arg launch_template "$(need "$SPILL_RES" LaunchTemplate)" \
    --arg instance_role_name "$(need "$SPILL_RES" InstanceRole3CCE2F1D)" \
    --arg deliver_document_name "$(need "$SPILL_RES" DeliverRunnerTokenDocument)" \
    --arg diagnose_document_name "$(need "$SPILL_RES" DiagnoseRunnerDocument)" \
    --arg staging_bucket_name "$staging_bucket" \
    --arg staging_lifecycle_rule_id "$(lifecycle_rule_id "$staging_bucket")" \
    --arg round_spill_user_policy_arn "$(need "$SPILL_RES" RoundSpillPolicyD259D208)" \
    --arg budget_name "$(need "$SPILL_RES" MonthlyBudget)" \
    --arg snapshot_bucket_name "$snapshot_bucket" \
    --arg snapshot_lifecycle_rule_id "$(lifecycle_rule_id "$snapshot_bucket")" \
    --arg backup_writer_user_name "$(need "$BACKUP_RES" Writer3ED51D24)" \
    --arg backup_secret_arn "$secret_arn" \
    --arg backup_secret_name "$secret_name" \
    '{deploy_role_arn: $deploy_role_arn,
      physical_ids: ($ARGS.named | del(.deploy_role_arn))}' \
    >"$OUT_DIR/physical_ids.auto.tfvars.json"

cat >"$OUT_DIR/backend.hcl" <<HCL
bucket = "$state_bucket"
assume_role = {
  role_arn = "$deploy_role_arn"
}
HCL

printf 'wrote %s/physical_ids.auto.tfvars.json and backend.hcl\n' "$OUT_DIR"

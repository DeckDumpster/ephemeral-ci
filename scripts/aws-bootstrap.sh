#!/usr/bin/env bash
#
# scripts/aws-bootstrap.sh [--dry-run]
#
# Idempotent AWS bootstrap for the ephemeral-ci EC2 spill path.
# Creates or reconciles all spill-path infrastructure in account 189923011121,
# region us-west-2. A second run against the same account reports no changes.
#
# What this creates:
#   VPC (no-inbound-SG), subnet, IGW, route table
#   Security group: zero ingress, all egress (SSM needs no open ports)
#   EC2 instance role + profile: AmazonSSMManagedInstanceCore only
#   GitHub Actions OIDC provider (token.actions.githubusercontent.com)
#   Spill role (ephemeral-ci-spill): EC2 run/terminate/describe + SSM, tagged resources only
#   CI test role (ephemeral-ci-ci-test): read-only + iam:SimulatePrincipalPolicy
#   Budget alert: $100/month on tag spill:owner=ephemeral-ci
#   Launch template: IMDSv2 required, gp3 root, tags propagated to instance+volume
#
# Outputs (shell key=value, sourced by later spill scripts):
#   scripts/aws-bootstrap-outputs.sh
#
# Prerequisites: AWS CLI v2 with admin credentials (SSO session for bootstrap).
# After bootstrap, CI authenticates via GitHub OIDC only -- no stored keys.
#
# CAUTION: the bootstrap SSO session is revoked by the operator after this
# lands. Never print, copy, or store the session credentials.
#
set -euo pipefail

ACCOUNT_ID="189923011121"
REGION="us-west-2"
TAG_KEY="spill:owner"
TAG_VALUE="ephemeral-ci"

VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.0.0/24"
SUBNET_AZ="${REGION}a"

INSTANCE_ROLE_NAME="ephemeral-ci-runner"
INSTANCE_PROFILE_NAME="ephemeral-ci-runner"
SPILL_ROLE_NAME="ephemeral-ci-spill"
CI_TEST_ROLE_NAME="ephemeral-ci-ci-test"
BUDGET_NAME="ephemeral-ci-spill"
LAUNCH_TEMPLATE_NAME="ephemeral-ci-spill"
GITHUB_REPO="DeckDumpster/ephemeral-ci"
OIDC_URL="https://token.actions.githubusercontent.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUTS_FILE="${SCRIPT_DIR}/aws-bootstrap-outputs.sh"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    printf 'aws-bootstrap.sh: dry-run mode — no resources will be created or modified\n' >&2
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# aws_w runs an aws command that WRITES (create/put/modify). In dry-run mode
# it prints the intended call and returns a placeholder string on stdout.
aws_w() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] aws %s\n' "$*" >&2
        printf 'dry-run-placeholder'
        return 0
    fi
    aws "$@"
}

tag_filter() {
    printf 'Name=tag:%s,Values=%s' "$TAG_KEY" "$TAG_VALUE"
}

tag_spec() {
    local resource_type="$1"
    printf 'ResourceType=%s,Tags=[{Key=%s,Value=%s},{Key=Name,Value=ephemeral-ci-spill}]' \
        "$resource_type" "$TAG_KEY" "$TAG_VALUE"
}

# ---------------------------------------------------------------------------
# verify_account: refuse if the active session is not the spill account.
# ---------------------------------------------------------------------------
verify_account() {
    local actual
    actual="$(aws sts get-caller-identity --query Account --output text)"
    if [ "$actual" != "$ACCOUNT_ID" ]; then
        printf 'aws-bootstrap.sh: wrong account: got %s, expected %s\n' "$actual" "$ACCOUNT_ID" >&2
        printf 'aws-bootstrap.sh: establish an SSO session for account %s before running this script\n' "$ACCOUNT_ID" >&2
        return 1
    fi
    printf 'account: %s (correct)\n' "$ACCOUNT_ID" >&2
}

# ---------------------------------------------------------------------------
# ensure_vpc: create or find the spill VPC; returns vpc-id on stdout.
# ---------------------------------------------------------------------------
ensure_vpc() {
    local vpc_id
    vpc_id="$(aws ec2 describe-vpcs \
        --filters "$(tag_filter)" "Name=state,Values=available" \
        --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null)" || true
    if [ "$vpc_id" != "None" ] && [ -n "$vpc_id" ]; then
        printf 'no-change: vpc %s\n' "$vpc_id" >&2
        printf '%s' "$vpc_id"
        return 0
    fi
    local id
    id="$(aws_w ec2 create-vpc \
        --cidr-block "$VPC_CIDR" \
        --region "$REGION" \
        --tag-specifications "$(tag_spec vpc)" \
        --query 'Vpc.VpcId' --output text)"
    if [ "$DRY_RUN" -eq 0 ]; then
        aws ec2 modify-vpc-attribute --vpc-id "$id" --enable-dns-hostnames --region "$REGION"
        aws ec2 modify-vpc-attribute --vpc-id "$id" --enable-dns-support --region "$REGION"
    fi
    printf 'created: vpc %s\n' "$id" >&2
    printf '%s' "$id"
}

# ---------------------------------------------------------------------------
# ensure_subnet: create or find the spill subnet; returns subnet-id on stdout.
# ---------------------------------------------------------------------------
ensure_subnet() {
    local vpc_id="$1"
    local subnet_id
    subnet_id="$(aws ec2 describe-subnets \
        --filters "$(tag_filter)" "Name=vpc-id,Values=${vpc_id}" \
        --query 'Subnets[0].SubnetId' --output text --region "$REGION" 2>/dev/null)" || true
    if [ "$subnet_id" != "None" ] && [ -n "$subnet_id" ]; then
        printf 'no-change: subnet %s\n' "$subnet_id" >&2
        printf '%s' "$subnet_id"
        return 0
    fi
    local id
    id="$(aws_w ec2 create-subnet \
        --vpc-id "$vpc_id" \
        --cidr-block "$SUBNET_CIDR" \
        --availability-zone "$SUBNET_AZ" \
        --region "$REGION" \
        --tag-specifications "$(tag_spec subnet)" \
        --query 'Subnet.SubnetId' --output text)"
    if [ "$DRY_RUN" -eq 0 ]; then
        aws ec2 modify-subnet-attribute --subnet-id "$id" \
            --map-public-ip-on-launch --region "$REGION"
    fi
    printf 'created: subnet %s\n' "$id" >&2
    printf '%s' "$id"
}

# ---------------------------------------------------------------------------
# ensure_igw: attach or create internet gateway; returns igw-id on stdout.
# ---------------------------------------------------------------------------
ensure_igw() {
    local vpc_id="$1"
    local igw_id
    igw_id="$(aws ec2 describe-internet-gateways \
        --filters "$(tag_filter)" "Name=attachment.vpc-id,Values=${vpc_id}" \
        --query 'InternetGateways[0].InternetGatewayId' --output text --region "$REGION" 2>/dev/null)" || true
    if [ "$igw_id" != "None" ] && [ -n "$igw_id" ]; then
        printf 'no-change: igw %s\n' "$igw_id" >&2
        printf '%s' "$igw_id"
        return 0
    fi
    local id
    id="$(aws_w ec2 create-internet-gateway \
        --region "$REGION" \
        --tag-specifications "$(tag_spec internet-gateway)" \
        --query 'InternetGateway.InternetGatewayId' --output text)"
    if [ "$DRY_RUN" -eq 0 ]; then
        aws ec2 attach-internet-gateway --internet-gateway-id "$id" \
            --vpc-id "$vpc_id" --region "$REGION"
        local rt_id
        rt_id="$(aws ec2 describe-route-tables \
            --filters "Name=vpc-id,Values=${vpc_id}" "Name=association.main,Values=true" \
            --query 'RouteTables[0].RouteTableId' --output text --region "$REGION")"
        aws ec2 create-route --route-table-id "$rt_id" \
            --destination-cidr-block "0.0.0.0/0" --gateway-id "$id" --region "$REGION" >/dev/null
    fi
    printf 'created: igw %s\n' "$id" >&2
    printf '%s' "$id"
}

# ---------------------------------------------------------------------------
# ensure_security_group: zero ingress, all egress; returns sg-id on stdout.
# ---------------------------------------------------------------------------
ensure_security_group() {
    local vpc_id="$1"
    local sg_id
    sg_id="$(aws ec2 describe-security-groups \
        --filters "$(tag_filter)" "Name=vpc-id,Values=${vpc_id}" \
        --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null)" || true
    if [ "$sg_id" != "None" ] && [ -n "$sg_id" ]; then
        printf 'no-change: security-group %s\n' "$sg_id" >&2
        printf '%s' "$sg_id"
        return 0
    fi
    local id
    id="$(aws_w ec2 create-security-group \
        --group-name "ephemeral-ci-spill" \
        --description "ephemeral-ci spill runners — no inbound, egress only" \
        --vpc-id "$vpc_id" \
        --region "$REGION" \
        --tag-specifications "$(tag_spec security-group)" \
        --query 'GroupId' --output text)"
    if [ "$DRY_RUN" -eq 0 ]; then
        # New non-default SGs have no ingress rules by default. Remove the
        # default egress rule and add an explicit allow-all-egress so the
        # intent is visible in the rule list rather than implied by absence.
        aws ec2 revoke-security-group-egress --group-id "$id" --region "$REGION" \
            --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' 2>/dev/null || true
        aws ec2 authorize-security-group-egress --group-id "$id" --region "$REGION" \
            --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"egress only; SSM needs no inbound port"}]}]' >/dev/null
    fi
    printf 'created: security-group %s\n' "$id" >&2
    printf '%s' "$id"
}

# ---------------------------------------------------------------------------
# ensure_instance_role: AmazonSSMManagedInstanceCore, nothing else.
# ---------------------------------------------------------------------------
ensure_instance_role() {
    local existing
    existing="$(aws iam get-role --role-name "$INSTANCE_ROLE_NAME" \
        --query 'Role.RoleName' --output text 2>/dev/null)" || true
    if [ "$existing" = "$INSTANCE_ROLE_NAME" ]; then
        printf 'no-change: iam-role %s\n' "$INSTANCE_ROLE_NAME" >&2
        return 0
    fi
    local trust
    trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws_w iam create-role \
        --role-name "$INSTANCE_ROLE_NAME" \
        --assume-role-policy-document "$trust" \
        --description "ephemeral-ci runner: SSM access, no AWS API rights" \
        --tags "[{\"Key\":\"${TAG_KEY}\",\"Value\":\"${TAG_VALUE}\"}]" >/dev/null
    if [ "$DRY_RUN" -eq 0 ]; then
        aws iam attach-role-policy --role-name "$INSTANCE_ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    fi
    printf 'created: iam-role %s\n' "$INSTANCE_ROLE_NAME" >&2
}

# ---------------------------------------------------------------------------
# ensure_instance_profile: wraps the instance role for EC2 attachment.
# ---------------------------------------------------------------------------
ensure_instance_profile() {
    local existing
    existing="$(aws iam get-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --query 'InstanceProfile.InstanceProfileName' --output text 2>/dev/null)" || true
    if [ "$existing" = "$INSTANCE_PROFILE_NAME" ]; then
        printf 'no-change: instance-profile %s\n' "$INSTANCE_PROFILE_NAME" >&2
        return 0
    fi
    aws_w iam create-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --tags "[{\"Key\":\"${TAG_KEY}\",\"Value\":\"${TAG_VALUE}\"}]" >/dev/null
    if [ "$DRY_RUN" -eq 0 ]; then
        aws iam add-role-to-instance-profile \
            --instance-profile-name "$INSTANCE_PROFILE_NAME" \
            --role-name "$INSTANCE_ROLE_NAME"
    fi
    printf 'created: instance-profile %s\n' "$INSTANCE_PROFILE_NAME" >&2
}

# ---------------------------------------------------------------------------
# ensure_oidc_provider: GitHub Actions OIDC; returns provider ARN on stdout.
#
# AWS now manages thumbprints for well-known OIDC providers automatically,
# but the CLI still requires at least one thumbprint in the request.
# ---------------------------------------------------------------------------
ensure_oidc_provider() {
    local arn="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
    local existing
    existing="$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" \
        --query 'Url' --output text 2>/dev/null)" || true
    if [ -n "$existing" ] && [ "$existing" != "None" ]; then
        printf 'no-change: oidc-provider %s\n' "$arn" >&2
        printf '%s' "$arn"
        return 0
    fi
    aws_w iam create-open-id-connect-provider \
        --url "$OIDC_URL" \
        --client-id-list "sts.amazonaws.com" \
        --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" \
        --tags "[{\"Key\":\"${TAG_KEY}\",\"Value\":\"${TAG_VALUE}\"}]" >/dev/null
    printf 'created: oidc-provider %s\n' "$arn" >&2
    printf '%s' "$arn"
}

# ---------------------------------------------------------------------------
# ensure_spill_role: GitHub Actions role for the spill path.
#
# Permissions:
#   ec2:RunInstances on instance/* requires ec2:RequestTag/spill:owner=ephemeral-ci
#   ec2:RunInstances on ancillary resources (AMI, subnet, SG, volume, etc.)
#   ec2:TerminateInstances requires aws:ResourceTag/spill:owner=ephemeral-ci
#   ec2:Describe* (no resource-level conditions, Describe doesn't support them)
#   ec2:CreateTags only when action is RunInstances (tag-on-create)
#   ssm:SendCommand on instance/* and document/* with spill tag on instances
#   ssm:GetCommandInvocation, ssm:ListCommandInvocations
#
# Returns role ARN on stdout.
# ---------------------------------------------------------------------------
ensure_spill_role() {
    local oidc_provider_arn="$1"
    local existing
    existing="$(aws iam get-role --role-name "$SPILL_ROLE_NAME" \
        --query 'Role.RoleName' --output text 2>/dev/null)" || true
    if [ "$existing" = "$SPILL_ROLE_NAME" ]; then
        local arn
        arn="$(aws iam get-role --role-name "$SPILL_ROLE_NAME" \
            --query 'Role.Arn' --output text)"
        printf 'no-change: spill-role %s\n' "$arn" >&2
        printf '%s' "$arn"
        return 0
    fi

    local trust
    trust="$(printf '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "%s"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:%s:*"
      }
    }
  }]
}' "$oidc_provider_arn" "$GITHUB_REPO")"

    local policy
    policy="$(printf '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RunInstancesTagged",
      "Effect": "Allow",
      "Action": "ec2:RunInstances",
      "Resource": "arn:aws:ec2:%s:%s:instance/*",
      "Condition": {
        "StringEquals": {
          "ec2:RequestTag/spill:owner": "ephemeral-ci"
        }
      }
    },
    {
      "Sid": "RunInstancesAncillary",
      "Effect": "Allow",
      "Action": "ec2:RunInstances",
      "Resource": [
        "arn:aws:ec2:%s::image/*",
        "arn:aws:ec2:%s:%s:subnet/*",
        "arn:aws:ec2:%s:%s:security-group/*",
        "arn:aws:ec2:%s:%s:network-interface/*",
        "arn:aws:ec2:%s:%s:volume/*",
        "arn:aws:ec2:%s:%s:launch-template/*"
      ]
    },
    {
      "Sid": "TagOnCreate",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": "*",
      "Condition": {"StringEquals": {"ec2:CreateAction": "RunInstances"}}
    },
    {
      "Sid": "TerminateTagged",
      "Effect": "Allow",
      "Action": "ec2:TerminateInstances",
      "Resource": "*",
      "Condition": {
        "StringEquals": {"aws:ResourceTag/spill:owner": "ephemeral-ci"}
      }
    },
    {
      "Sid": "Describe",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeImages",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeLaunchTemplateVersions"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SSMSendCommandInstance",
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": "arn:aws:ec2:%s:%s:instance/*",
      "Condition": {
        "StringEquals": {"aws:ResourceTag/spill:owner": "ephemeral-ci"}
      }
    },
    {
      "Sid": "SSMSendCommandDocument",
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": "arn:aws:ssm:%s::document/*"
    },
    {
      "Sid": "SSMDescribe",
      "Effect": "Allow",
      "Action": [
        "ssm:GetCommandInvocation",
        "ssm:ListCommandInvocations"
      ],
      "Resource": "*"
    }
  ]
}' "$REGION" "$ACCOUNT_ID" \
   "$REGION" \
   "$REGION" "$ACCOUNT_ID" \
   "$REGION" "$ACCOUNT_ID" \
   "$REGION" "$ACCOUNT_ID" \
   "$REGION" "$ACCOUNT_ID" \
   "$REGION" "$ACCOUNT_ID" \
   "$REGION" "$ACCOUNT_ID" \
   "$REGION")"

    aws_w iam create-role \
        --role-name "$SPILL_ROLE_NAME" \
        --assume-role-policy-document "$trust" \
        --description "ephemeral-ci: GitHub Actions spill role (EC2 + SSM, tagged resources only)" \
        --tags "[{\"Key\":\"${TAG_KEY}\",\"Value\":\"${TAG_VALUE}\"}]" >/dev/null
    if [ "$DRY_RUN" -eq 0 ]; then
        aws iam put-role-policy \
            --role-name "$SPILL_ROLE_NAME" \
            --policy-name "ephemeral-ci-spill" \
            --policy-document "$policy"
    fi

    local arn="arn:aws:iam::${ACCOUNT_ID}:role/${SPILL_ROLE_NAME}"
    printf 'created: spill-role %s\n' "$arn" >&2
    printf '%s' "$arn"
}

# ---------------------------------------------------------------------------
# ensure_ci_test_role: read-only + simulate-principal-policy for CI tests.
# Returns role ARN on stdout.
# ---------------------------------------------------------------------------
ensure_ci_test_role() {
    local oidc_provider_arn="$1"
    local existing
    existing="$(aws iam get-role --role-name "$CI_TEST_ROLE_NAME" \
        --query 'Role.RoleName' --output text 2>/dev/null)" || true
    if [ "$existing" = "$CI_TEST_ROLE_NAME" ]; then
        local arn
        arn="$(aws iam get-role --role-name "$CI_TEST_ROLE_NAME" \
            --query 'Role.Arn' --output text)"
        printf 'no-change: ci-test-role %s\n' "$arn" >&2
        printf '%s' "$arn"
        return 0
    fi

    local trust
    trust="$(printf '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "%s"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:%s:*"
      }
    }
  }]
}' "$oidc_provider_arn" "$GITHUB_REPO")"

    local policy
    policy="$(printf '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadOnly",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:DescribeInternetGateways",
        "iam:GetRole",
        "iam:GetInstanceProfile",
        "iam:GetRolePolicy",
        "iam:GetOpenIDConnectProvider",
        "iam:SimulatePrincipalPolicy",
        "budgets:DescribeBudgets",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}')"

    aws_w iam create-role \
        --role-name "$CI_TEST_ROLE_NAME" \
        --assume-role-policy-document "$trust" \
        --description "ephemeral-ci: CI test role (read-only + simulate, aws-bootstrap tests only)" \
        --tags "[{\"Key\":\"${TAG_KEY}\",\"Value\":\"${TAG_VALUE}\"}]" >/dev/null
    if [ "$DRY_RUN" -eq 0 ]; then
        aws iam put-role-policy \
            --role-name "$CI_TEST_ROLE_NAME" \
            --policy-name "ephemeral-ci-ci-test" \
            --policy-document "$policy"
    fi

    local arn="arn:aws:iam::${ACCOUNT_ID}:role/${CI_TEST_ROLE_NAME}"
    printf 'created: ci-test-role %s\n' "$arn" >&2
    printf '%s' "$arn"
}

# ---------------------------------------------------------------------------
# ensure_budget: $100/month alert on the spill tag.
#
# NOTE: Cost Allocation Tags must be activated separately in the Billing
# console (Cost Allocation Tags → Activate) before tag-filtered budgets
# match any spend. Run once after first resources are tagged.
# ---------------------------------------------------------------------------
ensure_budget() {
    local existing
    existing="$(aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
        --query "Budgets[?BudgetName=='${BUDGET_NAME}'].BudgetName" \
        --output text 2>/dev/null)" || true
    if [ -n "$existing" ] && [ "$existing" != "None" ]; then
        printf 'no-change: budget %s\n' "$BUDGET_NAME" >&2
        return 0
    fi

    local budget
    budget="$(printf '{
  "BudgetName": "%s",
  "BudgetLimit": {"Amount": "100", "Unit": "USD"},
  "CostFilters": {"TagKeyValue": ["%s$%s"]},
  "CostTypes": {
    "IncludeTax": true,
    "IncludeSubscription": true,
    "UseBlended": false,
    "IncludeRefund": false,
    "IncludeCredit": false,
    "IncludeUpfront": true,
    "IncludeRecurring": true,
    "IncludeOtherSubscription": true,
    "IncludeSupport": true,
    "IncludeDiscount": true,
    "UseAmortized": false
  },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}' "$BUDGET_NAME" "$TAG_KEY" "$TAG_VALUE")"

    # Budget created without subscribers; add an SNS topic or email address via
    # the Billing console once the budget exists. Subscribers require a valid
    # address so they are not wired here.
    aws_w budgets create-budget \
        --account-id "$ACCOUNT_ID" \
        --budget "$budget" >/dev/null
    # shellcheck disable=SC2016 -- $100 is a literal dollar amount in the format string, not a variable
    printf 'created: budget %s ($100/month on %s=%s)\n' "$BUDGET_NAME" "$TAG_KEY" "$TAG_VALUE" >&2
}

# ---------------------------------------------------------------------------
# ensure_launch_template: IMDSv2 required, gp3 root, tags propagated.
# Returns launch-template-id on stdout.
# ---------------------------------------------------------------------------
ensure_launch_template() {
    local sg_id="$1"
    local lt_id
    lt_id="$(aws ec2 describe-launch-templates \
        --filters "Name=launch-template-name,Values=${LAUNCH_TEMPLATE_NAME}" \
        --query 'LaunchTemplates[0].LaunchTemplateId' --output text \
        --region "$REGION" 2>/dev/null)" || true
    if [ "$lt_id" != "None" ] && [ -n "$lt_id" ]; then
        printf 'no-change: launch-template %s\n' "$lt_id" >&2
        printf '%s' "$lt_id"
        return 0
    fi

    # No AMI specified: AMI is provided at RunInstances time (db-ohr5, part 2).
    local lt_data
    lt_data="$(printf '{
  "MetadataOptions": {
    "HttpTokens": "required",
    "HttpPutResponseHopLimit": 1,
    "HttpEndpoint": "enabled"
  },
  "BlockDeviceMappings": [{
    "DeviceName": "/dev/xvda",
    "Ebs": {
      "VolumeType": "gp3",
      "DeleteOnTermination": true,
      "Encrypted": true
    }
  }],
  "SecurityGroupIds": ["%s"],
  "IamInstanceProfile": {"Name": "%s"},
  "TagSpecifications": [
    {
      "ResourceType": "instance",
      "Tags": [{"Key": "%s", "Value": "%s"}, {"Key": "Name", "Value": "ephemeral-ci-runner"}]
    },
    {
      "ResourceType": "volume",
      "Tags": [{"Key": "%s", "Value": "%s"}]
    }
  ]
}' "$sg_id" "$INSTANCE_PROFILE_NAME" "$TAG_KEY" "$TAG_VALUE" "$TAG_KEY" "$TAG_VALUE")"

    local id
    id="$(aws_w ec2 create-launch-template \
        --launch-template-name "$LAUNCH_TEMPLATE_NAME" \
        --version-description "ephemeral-ci spill: IMDSv2, gp3, tag-propagated" \
        --launch-template-data "$lt_data" \
        --region "$REGION" \
        --tag-specifications "$(tag_spec launch-template)" \
        --query 'LaunchTemplate.LaunchTemplateId' --output text)"
    printf 'created: launch-template %s\n' "$id" >&2
    printf '%s' "$id"
}

# ---------------------------------------------------------------------------
# write_outputs: write IDs/ARNs to the outputs file.
# ---------------------------------------------------------------------------
write_outputs() {
    local vpc_id="$1" subnet_id="$2" sg_id="$3" oidc_arn="$4" \
          spill_role_arn="$5" ci_test_role_arn="$6" lt_id="$7"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'dry-run: skipping outputs file write\n' >&2
        return 0
    fi
    cat >"$OUTPUTS_FILE" <<EOF
# Generated by aws-bootstrap.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ) — do not edit by hand
AWS_ACCOUNT_ID=${ACCOUNT_ID}
AWS_REGION=${REGION}
VPC_ID=${vpc_id}
SUBNET_ID=${subnet_id}
SECURITY_GROUP_ID=${sg_id}
INSTANCE_PROFILE_NAME=${INSTANCE_PROFILE_NAME}
OIDC_PROVIDER_ARN=${oidc_arn}
SPILL_ROLE_ARN=${spill_role_arn}
CI_TEST_ROLE_ARN=${ci_test_role_arn}
LAUNCH_TEMPLATE_ID=${lt_id}
EOF
    printf 'outputs: %s\n' "$OUTPUTS_FILE" >&2
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
verify_account

vpc_id="$(ensure_vpc)"
subnet_id="$(ensure_subnet "$vpc_id")"
ensure_igw "$vpc_id" >/dev/null
sg_id="$(ensure_security_group "$vpc_id")"

ensure_instance_role
ensure_instance_profile

oidc_arn="$(ensure_oidc_provider)"
spill_role_arn="$(ensure_spill_role "$oidc_arn")"
ci_test_role_arn="$(ensure_ci_test_role "$oidc_arn")"

ensure_budget

lt_id="$(ensure_launch_template "$sg_id")"

write_outputs "$vpc_id" "$subnet_id" "$sg_id" "$oidc_arn" \
    "$spill_role_arn" "$ci_test_role_arn" "$lt_id"

printf 'aws-bootstrap.sh: done\n' >&2

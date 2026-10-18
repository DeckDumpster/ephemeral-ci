#!/usr/bin/env bash
#
# Make every resource of a CDK stack survive the stack, then (optionally)
# delete the stack. Run by the Concierge, with an admin MFA session, only after
# `terraform plan` shows no changes for the resources the stack owned.
#
#   scripts/tf-retire-stack.sh <stack>            set DeletionPolicy/UpdateReplacePolicy
#                                                 Retain on every resource; deletes nothing
#   scripts/tf-retire-stack.sh <stack> --delete   same, then delete the stack
#
# The stack's own deployed template is the input: no CDK code is needed, which
# is what lets the CDK app go. The update changes only policies, so
# CloudFormation touches no resource. Deleting the stack afterwards removes
# CloudFormation's record and nothing real.

set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
STACK="${1:-}"
MODE="${2:-}"

case "$STACK" in
    EphemeralCiSpill | EphemeralCiBackup | BootstrapIdentity) ;;
    *) printf 'usage: %s <EphemeralCiSpill|EphemeralCiBackup|BootstrapIdentity> [--delete]\n' "$0" >&2; exit 2 ;;
esac
case "$MODE" in '' | --delete) ;; *) printf 'unknown option: %s\n' "$MODE" >&2; exit 2 ;; esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

aws cloudformation get-template --region "$REGION" --stack-name "$STACK" \
    --template-stage Original --query TemplateBody --output json >"$work/deployed.json"

jq '.Resources |= with_entries(.value += {DeletionPolicy: "Retain", UpdateReplacePolicy: "Retain"})' \
    "$work/deployed.json" >"$work/retained.json"

# A template over 51,200 bytes cannot be passed inline.
size="$(wc -c <"$work/retained.json")"
if [ "$size" -gt 51200 ]; then
    printf 'template is %s bytes; upload it to S3 and use --template-url\n' "$size" >&2
    exit 1
fi

if ! out="$(aws cloudformation update-stack --region "$REGION" --stack-name "$STACK" \
    --template-body "file://$work/retained.json" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM 2>&1)"; then
    case "$out" in
        *"No updates are to be performed"*) printf '%s: already retaining everything\n' "$STACK" ;;
        *) printf '%s\n' "$out" >&2; exit 1 ;;
    esac
else
    aws cloudformation wait stack-update-complete --region "$REGION" --stack-name "$STACK"
fi

# Refuse to delete unless the deployed template now retains every resource.
aws cloudformation get-template --region "$REGION" --stack-name "$STACK" \
    --template-stage Original --query TemplateBody --output json >"$work/after.json"
unretained="$(jq -r '.Resources | to_entries[] | select(.value.DeletionPolicy != "Retain") | .key' "$work/after.json")"
if [ -n "$unretained" ]; then
    printf 'refusing: these resources would be destroyed with the stack:\n%s\n' "$unretained" >&2
    exit 1
fi
printf '%s: every resource is DeletionPolicy Retain\n' "$STACK"

if [ "$MODE" = --delete ]; then
    aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
    aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
    printf '%s: deleted; its resources remain\n' "$STACK"
fi

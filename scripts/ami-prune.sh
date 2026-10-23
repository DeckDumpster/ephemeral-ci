#!/usr/bin/env bash
#
# scripts/ami-prune.sh [--keep N] [--dry-run]
#
# Deregister superseded ephemeral-ci-runner AMIs and delete their snapshots,
# so EBS snapshot storage (billed per stored GiB-month) stops growing with
# every build (sp-iko19d).
#
# Kept, never removed:
#   - the newest N images by CreationDate (default 2: current + rollback)
#   - the newest probe-passed image (spill:probe=passed): the one
#     provision.sh selects, even when newer builds are still unproven
#   - the image matching each published tag's recipe (PUBLISHED_TAGS)
#   - any image used by a non-terminated instance or by the $Latest/$Default
#     version of a launch template
# Only images tagged spill:owner=ephemeral-ci and named ephemeral-ci-runner-*
# are considered.
#
# FAIL CLOSED: if the image, instance or launch-template lookup fails, nothing
# is removed and the script exits non-zero. A lookup that cannot be made is
# not an empty in-use list.
#
# Each removal logs the AMI, its snapshots and the GiB freed; the total is
# written to $GITHUB_STEP_SUMMARY when set.
#
set -euo pipefail

REGION="${REGION:-us-west-2}"
TAG_KEY="spill:owner"
TAG_VALUE="ephemeral-ci"
AMI_NAME_PREFIX="ephemeral-ci-runner"
KEEP=2
DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)    KEEP="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) printf 'usage: ami-prune.sh [--keep N] [--dry-run]\n' >&2; exit 2 ;;
    esac
done

note() { printf 'ami-prune: %s\n' "$*" >&2; }
die() { printf 'ami-prune: %s; nothing removed\n' "$*" >&2; exit 1; }

# shellcheck source=ami-wait.sh
. "${SCRIPT_DIR}/ami-wait.sh"

images_json="$(aws ec2 describe-images --owners self \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=name,Values=${AMI_NAME_PREFIX}-*" \
    --region "$REGION" --output json)" || die "describe-images failed"

instances_json="$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --region "$REGION" --output json)" || die "describe-instances failed"
in_use="$(jq -r '[.Reservations[].Instances[].ImageId] | .[]' <<<"$instances_json")"

lts_json="$(aws ec2 describe-launch-templates --region "$REGION" --output json)" \
    || die "describe-launch-templates failed"
for lt in $(jq -r '.LaunchTemplates[].LaunchTemplateId' <<<"$lts_json"); do
    v_json="$(aws ec2 describe-launch-template-versions --launch-template-id "$lt" \
        --versions '$Latest' '$Default' --region "$REGION" --output json)" \
        || die "describe-launch-template-versions $lt failed"
    in_use+=$'\n'"$(jq -r '[.LaunchTemplateVersions[].LaunchTemplateData.ImageId // empty] | .[]' <<<"$v_json")"
done
in_use_json="$(printf '%s\n' "$in_use" | jq -R -s 'split("\n") | map(select(length > 0)) | unique')"

protected_shas="$(published_tag_shas "${AMI_BUILD_REPO:-$SCRIPT_DIR/..}")"
protected_json="$(printf '%s\n' "$protected_shas" | jq -R -s 'split("\n") | map(select(length > 0))')"

plan="$(jq -c --argjson n "$KEEP" --argjson used "$in_use_json" --argjson prot "$protected_json" '
    [.Images[] | {
        id: .ImageId, created: .CreationDate,
        sha: ((.Tags // []) | map(select(.Key == "substrate-sha")) | .[0].Value // ""),
        passed: ((.Tags // []) | any(.Key == "spill:probe" and .Value == "passed")),
        snaps: [(.BlockDeviceMappings // [])[] | select(.Ebs.SnapshotId != null)
                | {id: .Ebs.SnapshotId, gib: (.Ebs.VolumeSize // 0)}]
    }] | sort_by(.created) | reverse
    | (map(select(.passed)) | .[0].id) as $newest_passed
    | to_entries
    | map(select(.key >= $n)
          | .value
          | select(.id != $newest_passed
                   and ((.id | IN($used[])) | not)
                   and ((.sha | IN($prot[])) | not)))' <<<"$images_json" 2>/dev/null)" || die "could not compute the plan"

total="$(jq 'length' <<<"$plan")"
all="$(jq '.Images | length' <<<"$images_json")"
note "found $all image(s); keeping newest $KEEP + newest probe-passed + published/in-use; removing $total"

freed=0
while IFS= read -r row; do
    [ -z "$row" ] && continue
    ami="$(jq -r '.id' <<<"$row")"
    gib="$(jq '[.snaps[].gib] | add // 0' <<<"$row")"
    snaps="$(jq -r '.snaps[].id' <<<"$row")"
    if [ "$DRY_RUN" -eq 1 ]; then
        note "[dry-run] would deregister $ami and delete $(echo $snaps) (${gib} GiB)"
    else
        note "deregistering $ami"
        aws ec2 deregister-image --image-id "$ami" --region "$REGION" >/dev/null
        for s in $snaps; do
            note "deleting snapshot $s (of $ami)"
            aws ec2 delete-snapshot --snapshot-id "$s" --region "$REGION" >/dev/null
        done
        note "removed $ami: freed ${gib} GiB"
    fi
    freed=$((freed + gib))
done < <(jq -c '.[]' <<<"$plan")

note "total: $total image(s), ${freed} GiB freed"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf 'AMI prune: removed %s image(s), freed %s GiB\n' "$total" "$freed" >> "$GITHUB_STEP_SUMMARY" || true
fi

#!/usr/bin/env bash
# Sourced. Reads the spill infrastructure ids that infra/terraform writes as SSM
# parameters under /ephemeral-ci/spill/ (infra/terraform/ssm.tf), in one call:
#
#   spill_params_load <region>   -> 0 and fills SPILL_PARAMS; 1 with the reason in SPILL_PARAMS_ERR
#                                   (call it directly, not in $(...): the globals would be lost)
#   spill_param <Name>           -> the value of /ephemeral-ci/spill/<Name>, empty if absent
#
# Names match the former EphemeralCiSpill stack outputs: SubnetIds,
# SecurityGroupId, LaunchTemplateId, LaunchTemplateName, InstanceProfileName,
# DeliverDocumentName, DiagnoseDocumentName.

SPILL_PARAMS_PATH="/ephemeral-ci/spill/"
SPILL_PARAMS=""
SPILL_PARAMS_ERR=""

spill_params_load() {
    local raw
    raw="$(aws ssm get-parameters-by-path \
               --region "$1" \
               --path "$SPILL_PARAMS_PATH" \
               --query 'Parameters[].[Name,Value]' \
               --output text 2>&1)" || {
        SPILL_PARAMS_ERR="cannot read SSM parameters under $SPILL_PARAMS_PATH: $raw"
        return 1
    }
    case "$raw" in
        '' | None)
            SPILL_PARAMS_ERR="no SSM parameters under $SPILL_PARAMS_PATH (terraform apply in infra/terraform writes them)"
            return 1 ;;
    esac
    SPILL_PARAMS="$raw"
}

spill_param() {
    printf '%s\n' "$SPILL_PARAMS" \
        | awk -F'\t' -v n="${SPILL_PARAMS_PATH}$1" '$1 == n { print $2; exit }'
}

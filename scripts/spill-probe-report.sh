#!/usr/bin/env bash
#
# scripts/spill-probe-report.sh <ami> <run-url> <log-tail>
#
# Files the P0 for a failed spill probe. The P0 label may not exist in the
# repo, which made `gh issue create --label P0` fail and silenced the alarm:
# create it if missing, and if that still fails file the issue without it.
# `gh` can be replaced by $GH for testing.
set -uo pipefail

ami="$1" url="$2" tail="${3:-}"
gh="${GH:-gh}"

body="$(printf 'Spill AMI %s FAILED its probe and was NOT promoted.\n\nRun: %s\n\nLog tail:\n```\n%s\n```\n' "$ami" "$url" "$tail")"
title="P0: spill AMI ${ami} failed its probe"

label_args=(--label P0)
if ! "$gh" label create P0 --color B60205 --description "Production-blocking" --force >&2; then
    echo "::warning::could not create the P0 label; filing without it" >&2
    label_args=()
fi

if ! printf '%s' "$body" | "$gh" issue create --title "$title" "${label_args[@]}" --body-file -; then
    if [ "${#label_args[@]}" -gt 0 ]; then
        echo "::warning::issue create with the label failed; retrying without it" >&2
        printf '%s' "$body" | "$gh" issue create --title "$title" --body-file - || exit 1
    else
        exit 1
    fi
fi

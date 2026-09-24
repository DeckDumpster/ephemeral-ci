#!/usr/bin/env bash
set -euo pipefail
# check-action-inputs.sh ACTION_YML WORKFLOW_YML [WORKFLOW_YML ...]
#
# Reads required inputs (required: true) from ACTION_YML, derives the action
# name from its parent directory, then for each WORKFLOW_YML finds every step
# whose `uses:` names that action and reports any required input absent from
# the step's `with:` block.
#
# A composite action does not enforce `required:` — GitHub silently supplies
# nothing when a caller omits an input. This check is the enforcement that the
# action declaration itself cannot provide.
#
# Exit 0 — all required inputs are present in every matching step.
# Exit 1 — at least one required input is absent in at least one step.
# Exit 2 — usage error.

if [ $# -lt 2 ]; then
    echo "Usage: check-action-inputs.sh ACTION_YML WORKFLOW_YML [...]" >&2
    exit 2
fi

python3 - "$@" <<'PY'
import sys, re, yaml, pathlib

action_yml = pathlib.Path(sys.argv[1])
workflow_paths = [pathlib.Path(p) for p in sys.argv[2:]]

with open(action_yml) as f:
    action = yaml.safe_load(f)

required = {
    name for name, spec in (action.get('inputs') or {}).items()
    if (spec or {}).get('required', False)
}
action_name = action_yml.parent.name

bad = 0
for wf_path in workflow_paths:
    with open(wf_path) as f:
        workflow = yaml.safe_load(f)
    for job_name, job in (workflow.get('jobs') or {}).items():
        for step in (job.get('steps') or []):
            uses = step.get('uses') or ''
            # Match ./teardown, org/repo/teardown@v1, etc.
            uses_name = re.sub(r'@.*$', '', uses).rstrip('/').rsplit('/', 1)[-1]
            if uses_name != action_name:
                continue
            passed = set((step.get('with') or {}).keys())
            for inp in sorted(required - passed):
                step_label = step.get('name') or uses
                print(f"{wf_path}: job '{job_name}' step '{step_label}' missing required input '{inp}'")
                bad += 1

sys.exit(1 if bad else 0)
PY

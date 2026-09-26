#!/usr/bin/env bash
# check-advance-inputs.sh <v1-action.yml> <candidate-action.yml>
#
# Compares action inputs between a v1 baseline and a candidate.
# Reports all new inputs; exits 1 if any new required input lacks a default,
# naming each one and the way through.
#
# Exit 0 — no blocking changes.
# Exit 1 — new required input(s) without a default found.
# Exit 2 — usage error.

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: check-advance-inputs.sh V1_ACTION_YML CANDIDATE_ACTION_YML" >&2
    exit 2
fi

python3 - "$1" "$2" <<'PY'
import sys, yaml

with open(sys.argv[1]) as f:
    v1 = yaml.safe_load(f)
with open(sys.argv[2]) as f:
    cand = yaml.safe_load(f)

v1_inputs = set((v1.get("inputs") or {}).keys())
cand_inputs = cand.get("inputs") or {}

new_optional = []
new_required = []

for name, spec in cand_inputs.items():
    if name in v1_inputs:
        continue
    spec = spec or {}
    if spec.get("required") is True and "default" not in spec:
        new_required.append(name)
    else:
        new_optional.append(name)

if new_optional:
    for name in sorted(new_optional):
        print(f"  new input (optional/defaulted): {name}")

if new_required:
    for name in sorted(new_required):
        print(f"  new required input without default: {name}", file=sys.stderr)
        print(f"  way through: add default: '' to this input, or update all consumers to pass '{name}' before advancing v1", file=sys.stderr)
    sys.exit(1)
PY

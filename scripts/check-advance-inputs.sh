#!/usr/bin/env bash
# check-advance-inputs.sh <v1-action.yml> <candidate-action.yml>
#
# Classifies the interface diff between a baseline action.yml and a candidate.
#
# Breaking (stderr, one "breaking <class>: <name>" line each; exit 1):
#   removed input            a consumer passing it now gets a warning at best
#   removed output           a consumer reading it now gets an empty string
#   new required input       new input with required: true and no default
#   input became required    existing input gained required: true, no default
#   changed default          existing input's default differs from the baseline
#
# Safe (stdout, one "safe <class>: <name>" line each):
#   new optional input       required is not true, or a default is present
#   new output               no consumer can depend on it yet
#
# Exit 0 — no breaking changes.
# Exit 1 — at least one breaking change.
# Exit 2 — usage error.

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: check-advance-inputs.sh V1_ACTION_YML CANDIDATE_ACTION_YML" >&2
    exit 2
fi

python3 - "$1" "$2" <<'PY'
import sys, yaml

with open(sys.argv[1]) as f:
    v1 = yaml.safe_load(f) or {}
with open(sys.argv[2]) as f:
    cand = yaml.safe_load(f) or {}

def section(doc, key):
    return {k: (v or {}) for k, v in (doc.get(key) or {}).items()}

def required_no_default(spec):
    return spec.get("required") is True and "default" not in spec

v1_in, cand_in = section(v1, "inputs"), section(cand, "inputs")
v1_out, cand_out = section(v1, "outputs"), section(cand, "outputs")

breaking, safe = [], []

for name in sorted(v1_in.keys() - cand_in.keys()):
    breaking.append(("removed input", name))
for name in sorted(v1_out.keys() - cand_out.keys()):
    breaking.append(("removed output", name))

for name, spec in sorted(cand_in.items()):
    if name not in v1_in:
        if required_no_default(spec):
            breaking.append(("new required input without default", name))
        else:
            safe.append(("new optional input", name))
        continue
    old = v1_in[name]
    if required_no_default(spec) and not required_no_default(old):
        breaking.append(("input became required", name))
    if old.get("default") != spec.get("default") or ("default" in old) != ("default" in spec):
        breaking.append(("changed default", name))

for name in sorted(cand_out.keys() - v1_out.keys()):
    safe.append(("new output", name))

for cls, name in safe:
    print(f"safe {cls}: {name}")
for cls, name in breaking:
    print(f"breaking {cls}: {name}", file=sys.stderr)
if breaking:
    print("  way through: restore the interface, or update all consumers and re-run with consumers-updated", file=sys.stderr)
    sys.exit(1)
PY
